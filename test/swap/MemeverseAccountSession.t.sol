// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {TransientStateHarness} from "../mocks/swap/TransientStateHarness.sol";
import {
    AtomicSessionAccount,
    HandleOpsLikeEntryPoint,
    TargetCallSpy,
    NonCompliantSessionHelper,
    BatchExecutor
} from "../mocks/swap/AccountSessionMocks.sol";

/// @title MemeverseAccountSessionTest
/// @notice Task 2 lifecycle (mock PoolManager) and Task 3 plan-named scenario mappings for the smart-EOA
///         transient session.
/// @dev Lifecycle / callback-principal revert cases run against the mock PoolManager (sufficient for the
///      identity guards since they fire before swap math). The full positive behavior matrix that requires
///      real addressBatchState advancement (EIP-7702 delegation, bundler isolation, multi-hop, no-trader
///      router, external executor, multi-user batch, caught-failure isolation) lives in
///      `MemeverseAccountSessionRealV4Test` below, which deploys the real v4-core PoolManager.
contract MemeverseAccountSessionTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHookUpgradeable internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;
    TransientStateHarness internal transientStateHarness;
    HandleOpsLikeEntryPoint internal entryPoint;
    TargetCallSpy internal spy;

    // Stand-in deployed smart accounts; the hook records each account's own address as the principal.
    AtomicSessionAccount internal account;
    AtomicSessionAccount internal otherAccount;

    // Different caller for the non-principal-end test.
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        hook = _deployHookProxy(address(this), address(this));
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        transientStateHarness = new TransientStateHarness();
        entryPoint = new HandleOpsLikeEntryPoint();
        spy = new TargetCallSpy();
        account = new AtomicSessionAccount();
        otherAccount = new AtomicSessionAccount();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        mockManager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity();
    }

    // -----------------------------------------------------------------
    // begin/end lifecycle (Task 2.B)
    // -----------------------------------------------------------------

    function test_RevertIf_PlainEoaBegin() external {
        // A conventional no-code EOA cannot establish a session: it has no way to atomically run
        // begin → Router → end in one account frame, so begin must reject it.
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.AccountSessionCallerMustHaveCode.selector, outsider)
        );
        hook.beginAccountSession();
    }

    function test_DeployedContractAccountCanBegin() external {
        // An ordinary deployed contract account can begin and end. The hook records the account's own
        // address as the principal (NOT tx.origin, NOT a caller-supplied value).
        address principal = address(account);
        vm.prank(principal);
        hook.beginAccountSession();
        // begin must have written the caller as activePrincipal.
        vm.prank(principal);
        hook.endAccountSession();
    }

    function test_RevertIf_RepeatedBeginDoesNotOverwrite() external {
        address principal = address(account);
        vm.prank(principal);
        hook.beginAccountSession();

        // A second begin (same OR different caller) must revert with the original principal still active;
        // the original principal is NOT overwritten.
        vm.prank(address(otherAccount));
        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.AccountSessionAlreadyActive.selector, principal));
        hook.beginAccountSession();

        // The original principal still owns the session and can end it.
        vm.prank(principal);
        hook.endAccountSession();
    }

    function test_RevertIf_NonPrincipalEnd() external {
        address principal = address(account);
        vm.prank(principal);
        hook.beginAccountSession();

        // Only the active principal can end its session.
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.AccountSessionUnauthorized.selector, outsider, principal)
        );
        hook.endAccountSession();

        // Cleanup so the transient store does not bleed across assertions in the same test.
        vm.prank(principal);
        hook.endAccountSession();
    }

    function test_RevertIf_PendingContextEnd() external {
        address principal = address(account);
        vm.prank(principal);
        hook.beginAccountSession();

        // Synthesize an unconsumed swap context the way production does: a real beforeSwap pushes exactly
        // one context at depth 1 into the hook's own transient store. Skipping the matching afterSwap
        // leaves that context pending, so endAccountSession must observe a non-zero depth and revert.
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(address(mockManager));
        hook.beforeSwap(principal, key, params, bytes(""));

        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.AccountSessionHasPendingContext.selector, 1));
        hook.endAccountSession();
    }

    // -----------------------------------------------------------------
    // Read-only session-principal getter (YT Flash Swap Plan Task 2)
    // -----------------------------------------------------------------

    /// @notice The read-only getter tracks begin/end without touching session lifecycle.
    function test_ActiveAccountSessionPrincipal_TracksBeginAndEnd() external {
        address principal = address(account);
        assertEq(hook.activeAccountSessionPrincipal(), address(0));
        vm.prank(principal);
        hook.beginAccountSession();
        assertEq(hook.activeAccountSessionPrincipal(), principal);
        vm.prank(principal);
        hook.endAccountSession();
        assertEq(hook.activeAccountSessionPrincipal(), address(0));
    }

    // -----------------------------------------------------------------
    // beforeSwap / afterSwap session + context guards (Task 2.C)
    // -----------------------------------------------------------------

    function test_RevertIf_BeforeSwapWithoutSession() external {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        // No begin: the hook must reject beforeSwap with AccountSessionNotActive rather than fall back to
        // tx.origin, Router, or hookData.
        vm.prank(address(mockManager));
        vm.expectRevert(IMemeverseUniswapHook.AccountSessionNotActive.selector);
        hook.beforeSwap(address(this), key, params, bytes(""));
    }

    function test_RevertIf_AfterSwapWithoutMatchingContext() external {
        address principal = address(account);
        vm.prank(principal);
        hook.beginAccountSession();

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        BalanceDelta delta = toBalanceDelta(-int128(int256(5 ether)), int128(int256(2 ether)));

        // No matching beforeSwap pushed a context, so the afterSwap consume sees a zero-principal context
        // and must revert with AccountSessionContextMissing. Depth must remain 0 (no decrement on miss).
        vm.prank(address(mockManager));
        vm.expectRevert(IMemeverseUniswapHook.AccountSessionContextMissing.selector);
        hook.afterSwap(address(this), key, params, delta, bytes(""));

        vm.prank(principal);
        hook.endAccountSession();
    }

    // -----------------------------------------------------------------
    // Task 3 plan-named scenario mappings (lifecycle subset)
    // -----------------------------------------------------------------
    // The plan enumerates several scenarios by exact name that are already fully exercised by the Task 2
    // lifecycle tests above. Rather than duplicate the attack path, each mapping below delegates to the
    // already-passing case so the plan's exact test names exist without weakening the coverage.

    /// @notice Plan name for the plain-EOA-begin attack path; reuses the Task 2 lifecycle assertion.
    function test_plainEoaBeginReverts() external {
        // Delegate to the full Task 2 lifecycle case so there is exactly one implementation of this path.
        this.test_RevertIf_PlainEoaBegin();
    }

    /// @notice Plan name for the deployed-contract-account begin path; reuses the Task 2 lifecycle assertion.
    function test_deployedContractAccountCanBegin() external {
        this.test_DeployedContractAccountCanBegin();
    }

    /// @notice Plan name for the nested-begin guard; reuses the Task 2 lifecycle assertion.
    function test_nestedBeginRevertsWithoutOverwritingPrincipal() external {
        this.test_RevertIf_RepeatedBeginDoesNotOverwrite();
    }

    /// @notice Plan name for the non-principal-end guard; reuses the Task 2 lifecycle assertion.
    function test_nonPrincipalEndReverts() external {
        this.test_RevertIf_NonPrincipalEnd();
    }

    /// @notice Plan name for the pending-context-end guard; reuses the Task 2 lifecycle assertion.
    function test_pendingContextEndReverts() external {
        this.test_RevertIf_PendingContextEnd();
    }

    /// @notice Plan name for the combined before/after-without-session revert pair. Both callbacks must
    ///         reject when no session is active; the before-half is the Task 2 case, the after-half is
    ///         reproduced here against a fresh (no-session) hook state.
    function test_beforeAndAfterWithoutSessionRevert() external {
        // Before-half: no session -> beforeSwap reverts (delegates to the Task 2 case).
        this.test_RevertIf_BeforeSwapWithoutSession();

        // After-half: no session -> afterSwap must also reject with AccountSessionNotActive rather than
        // fall back to tx.origin/Router/hookData. There is still no active session here.
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        BalanceDelta delta = toBalanceDelta(-int128(int256(5 ether)), int128(int256(2 ether)));
        vm.prank(address(mockManager));
        vm.expectRevert(IMemeverseUniswapHook.AccountSessionNotActive.selector);
        hook.afterSwap(address(this), key, params, delta, bytes(""));
    }

    /// @notice Plan name for the no-matching-context afterSwap guard; reuses the Task 2 lifecycle assertion.
    function test_afterWithoutMatchingContextReverts() external {
        this.test_RevertIf_AfterSwapWithoutMatchingContext();
    }

    function _deployHookProxy(address owner_, address treasury_) internal returns (MemeverseUniswapHookUpgradeable) {
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), owner_, treasury_);
        return MemeverseUniswapHookUpgradeable(hookProxy);
    }

    function _addLiquidity() internal {
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }
}

// =====================================================================================
// Task 3 — positive behavior matrix against the REAL v4-core PoolManager.
// The mock PoolManager in `MemeverseAccountSessionTest` cannot advance addressBatchState (its
// swap path does not move slot0), so every test below that asserts a per-trader batch write
// deploys the genuine v4-core PoolManager bytecode via `deployRealPoolManager()` (HookStorageHelper).
// Identity invariant under test: addressBatchState[principal][poolId] is keyed ONLY by the
// session-captured activePrincipal (msg.sender of beginAccountSession), never by tx.origin, the
// Router, hookData, or an external executor.
// =====================================================================================

/// @title SessionSwapIntegrator
/// @notice Minimal no-trader single-account integrator that settles/takes against the REAL v4 PoolManager.
/// @dev Mirrors `RealV4SwapIntegrator` from MemeverseReferralRebateRealV4.t.sol. It takes NO trader
///      parameter, implements NO `IMsgSender`, and is on no allowlist: this is the design's "any Router"
///      acceptance case. The payer is `msg.sender` of `swap(...)`; the hook sees only the PoolManager as
///      the callback caller, and identity flows solely from the active session principal.
contract SessionSwapIntegrator is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager internal immutable manager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Swaps `params` on `key`, pulling input from `msg.sender` and sending output to `recipient`.
    /// @return delta The settled swap delta.
    function swap(PoolKey memory key, SwapParams memory params, address recipient, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Settle negative deltas (input owed): sync -> transferFrom -> settle credits the PoolManager.
        if (delta.amount0() < 0) {
            manager.sync(data.key.currency0);
            IERC20(Currency.unwrap(data.key.currency0))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount0())));
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(data.key.currency1);
            IERC20(Currency.unwrap(data.key.currency1))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount1())));
            manager.settle();
        }
        // Take positive deltas (output owed to recipient).
        if (delta.amount0() > 0) {
            manager.take(data.key.currency0, data.recipient, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(data.key.currency1, data.recipient, uint256(int256(delta.amount1())));
        }
        return abi.encode(delta);
    }
}

/// @title MemeverseAccountSessionRealV4Test
/// @notice Task 3 positive behavior matrix for the smart-EOA transient session on the real v4 PoolManager.
/// @dev Covers the acceptance scenarios that require real swap math / addressBatchState advancement:
///      EIP-7702 delegation, same-Bundler A/V isolation, same-tx end-then-V, missing-end DoS, multi-hop
///      (sequential exact-in / exact-out), no-trader router, external executor (negative), multi-user
///      batch (unsupported), and caught-begin-failure (unsupported isolation boundary).
contract MemeverseAccountSessionRealV4Test is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    // The v4 1:1 sqrt price (2^96).
    uint160 internal constant REAL_SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    SessionSwapIntegrator internal integrator;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    HandleOpsLikeEntryPoint internal entryPoint;
    TargetCallSpy internal spy;
    NonCompliantSessionHelper internal nonCompliant;
    BatchExecutor internal batchExecutor;

    // Stand-in deployed smart accounts A and V; each drives its own atomic session frame.
    AtomicSessionAccount internal accountA;
    AtomicSessionAccount internal accountV;

    // The ERC-4337 Bundler that submits handleOps([A, V]). Both msg.sender and tx.origin are this address
    // when handleOps is pranked with (bundler, bundler) — this is the cross-user pollution path under test.
    address internal bundler = makeAddr("bundler");

    function setUp() public {
        // 1. Deploy the REAL v4-core PoolManager (pinned solc 0.8.26 blocks direct import).
        manager = deployRealPoolManager();
        vm.label(address(manager), "RealPoolManager");

        // 2. Tokens sorted so currency0 < currency1.
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        // 3. Real flag-address hook (UUPS proxy + 3 facets + LP impl), treasury = address(this).
        address hookProxy = deployHookAtFlagAddress(manager, address(this), address(this));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        vm.label(hookProxy, "HookProxy");

        // 4. No-trader real-v4 integrator.
        integrator = new SessionSwapIntegrator(manager);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(integrator), type(uint256).max);
        token1.approve(address(integrator), type(uint256).max);

        // 5. Dynamic-fee pool key bound to the flag-address hook proxy.
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000, // LPFeeLibrary.DYNAMIC_FEE_FLAG
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // 6. Initialize + seed full-range liquidity, then mature past the launch-fee decay window.
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, REAL_SQRT_PRICE_1_1);
        manager.initialize(key, REAL_SQRT_PRICE_1_1);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
        vm.warp(block.timestamp + 900);

        // 7. Test-only actors.
        entryPoint = new HandleOpsLikeEntryPoint();
        spy = new TargetCallSpy();
        nonCompliant = new NonCompliantSessionHelper();
        batchExecutor = new BatchExecutor();
        accountA = new AtomicSessionAccount();
        accountV = new AtomicSessionAccount();

        // 8. Fund A and V directly (each pays its own swap input) and approve the integrator from EACH
        //    account — never from a shared payer. This is the design's "any Router" funding model: the
        //    integrator pulls input via transferFrom from msg.sender inside the unlock callback.
        _fundAndApprove(address(accountA));
        _fundAndApprove(address(accountV));

        vm.label(address(accountA), "AccountA");
        vm.label(address(accountV), "AccountV");
        vm.label(bundler, "Bundler");
    }

    // -----------------------------------------------------------------
    // EIP-7702 Smart EOA
    // -----------------------------------------------------------------

    /// @notice An EIP-7702-delegated EOA can open a session and run a full swap attributed to itself.
    /// @dev The delegated EOA has EXTCODESIZE == 23 (a delegation designation), so the hook's `code.length`
    ///      presence gate accepts it while the EOA address itself is what begin/end capture and what
    ///      addressBatchState is keyed by. Foundry 1.7.1's `vm.signAndAttachDelegation(impl, pk)` designates
    ///      the next call as a type-4 (EIP-7702) transaction that installs the delegation for `pk`'s address.
    function test_eip7702DelegatedEoaCanExecuteSession() external {
        uint256 delegatedPrivateKey = 0xA11CE;
        address delegatedEoa = vm.addr(delegatedPrivateKey);
        vm.label(delegatedEoa, "DelegatedEoa");

        AtomicSessionAccount implementation = new AtomicSessionAccount();
        // Designate the next call as a type-4 tx installing the delegation to `implementation`.
        vm.signAndAttachDelegation(address(implementation), delegatedPrivateKey);

        // Fund the EOA address and approve the integrator from the EOA's own context.
        _fundAndApprove(delegatedEoa);

        // Sanity: the delegated EOA now carries the delegation designation code (EXTCODESIZE == 23), which
        // satisfies the hook's presence gate without the address itself being a deployed contract.
        assertGt(delegatedEoa.code.length, 0, "delegated EOA must carry delegation code");

        SwapParams memory params = _exactInZeroForOne(1 ether);
        bytes memory swapCalldata = abi.encodeCall(SessionSwapIntegrator.swap, (key, params, delegatedEoa, bytes("")));

        // The whole begin -> Router(Integrator.swap) -> end frame runs from the delegated EOA's context.
        // Re-attach per call: each vm.prank must also be a type-4 tx for the delegation to take effect.
        vm.signAndAttachDelegation(address(implementation), delegatedPrivateKey);
        vm.prank(delegatedEoa);
        AtomicSessionAccount(delegatedEoa).executeSession(hook, address(integrator), swapCalldata);

        // The swap attributed to the delegated EOA, NOT to the implementation, the Bundler, or tx.origin.
        IDynamicFeeFacet.AddressBatchState memory bs = hook.addressBatchStateOf(delegatedEoa, poolId);
        assertGt(uint256(bs.batchStartTs), 0, "7702 EOA: swap attributed to delegated EOA");
    }

    // -----------------------------------------------------------------
    // Bundler cross-user isolation
    // -----------------------------------------------------------------

    /// @notice A single Bundler transaction that runs A then V attributes A's swap to [A] and V's swap to
    ///         [V], and NEVER touches [bundler]. Proves tx.origin pollution is gone.
    /// @dev `vm.prank(bundler, bundler)` forces BOTH msg.sender and tx.origin to be the Bundler across the
    ///      whole handleOps call, which is the exact attack surface the old tx.origin model leaked through.
    function test_sameBundlerSeparatesAAndVAndLeavesBundlerBatchStateEmpty() external {
        bytes memory swapForA = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(accountA), bytes(""))
        );
        bytes memory swapForV = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(accountV), bytes(""))
        );

        AtomicSessionAccount[] memory accounts = new AtomicSessionAccount[](2);
        accounts[0] = accountA;
        accounts[1] = accountV;
        address[] memory targets = new address[](2);
        targets[0] = address(integrator);
        targets[1] = address(integrator);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = swapForA;
        calldatas[1] = swapForV;

        // Both msg.sender and tx.origin are the Bundler for the entire outer transaction.
        vm.prank(bundler, bundler);
        entryPoint.handleOps(hook, accounts, targets, calldatas);

        // A and V each received their own batch write; the Bundler never became a state key.
        IDynamicFeeFacet.AddressBatchState memory bsA = hook.addressBatchStateOf(address(accountA), poolId);
        IDynamicFeeFacet.AddressBatchState memory bsV = hook.addressBatchStateOf(address(accountV), poolId);
        IDynamicFeeFacet.AddressBatchState memory bsBundler = hook.addressBatchStateOf(bundler, poolId);
        assertGt(uint256(bsA.batchStartTs), 0, "A's swap attributed to A");
        assertGt(uint256(bsV.batchStartTs), 0, "V's swap attributed to V");
        assertEq(uint256(bsBundler.batchStartTs), 0, "bundler has NO batch state");
        assertEq(uint256(bsBundler.batchAccumPpm), 0, "bundler has NO batch accum");
    }

    // -----------------------------------------------------------------
    // Explicit end lets the next account run in the same outer transaction
    // -----------------------------------------------------------------

    /// @notice After A's full begin -> swap -> end, V can begin -> swap -> end in the SAME outer
    ///         transaction. Proves successful end clears the session so a later account is not blocked.
    function test_successfulEndLetsVRunInTheSameOuterTransaction() external {
        bytes memory swapForA = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(accountA), bytes(""))
        );
        bytes memory swapForV = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(accountV), bytes(""))
        );

        AtomicSessionAccount[] memory accounts = new AtomicSessionAccount[](2);
        accounts[0] = accountA;
        accounts[1] = accountV;
        address[] memory targets = new address[](2);
        targets[0] = address(integrator);
        targets[1] = address(integrator);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = swapForA;
        calldatas[1] = swapForV;

        // Same-tx, sequential A-then-V (no Bundler needed here).
        entryPoint.handleOps(hook, accounts, targets, calldatas);

        assertGt(uint256(hook.addressBatchStateOf(address(accountA), poolId).batchStartTs), 0, "A ran");
        assertGt(uint256(hook.addressBatchStateOf(address(accountV), poolId).batchStartTs), 0, "V ran after A ended");
    }

    /// @notice If A leaves its session open (no end), V's compliant begin -> Router -> end frame reverts
    ///         entirely in the same outer tx, and V's target/callback never execute. Same-tx DoS / unsupported.
    /// @dev `NonCompliantSessionHelper.beginWithoutEnd` leaves A active. The catching entry then runs V's
    ///      full frame and returns (false, reason); the spy proves the target was NOT reached.
    function test_missingEndMakesVCompliantFrameRevertBeforeRouterOrCallback() external {
        // A opens a session and returns without ending it (unsupported begin-without-end path).
        vm.prank(address(accountA));
        nonCompliant.beginWithoutEnd(hook);

        // V's compliant frame must revert at begin (session already active as A) and never reach the spy.
        bytes memory spyCalldata = abi.encodeCall(TargetCallSpy.record, ());
        (bool ok,) = entryPoint.executeFrameCatching(accountV, hook, address(spy), spyCalldata);
        assertFalse(ok, "V frame must revert when A left the session open");
        assertFalse(spy.wasCalled(), "V target must not run (callback never reached)");
    }

    // -----------------------------------------------------------------
    // Multi-hop identity consistency
    // -----------------------------------------------------------------

    /// @notice Proves the identity key is stable across SEQUENTIAL exact-input swaps under SEPARATE A
    ///         sessions: every callback attributes to A, never to the Bundler/tx.origin/Router.
    /// @dev SUBSTITUTION: the current router/integrator cannot express a true multi-hop over one hook in a
    ///         single call (no per-call multi-pool hop path exists), so this runs two independent
    ///         begin → swap → end frames for A back-to-back — each `executeSession` is its OWN session, not
    ///         multiple callbacks inside one session. It still proves the exact-input callback identity
    ///         invariant is direction-stable for A across frames; it does not prove single-session multi-hop.
    function test_exactInMultiHopUsesAForEveryHookCallback() external {
        bytes memory swap1 = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(0.5 ether), address(accountA), bytes(""))
        );
        // Second exact-input swap in its OWN begin → swap → end frame under A — not a callback inside one session.
        bytes memory swap2 = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(0.5 ether), address(accountA), bytes(""))
        );

        AtomicSessionAccount[] memory accounts = new AtomicSessionAccount[](2);
        accounts[0] = accountA;
        accounts[1] = accountA;
        address[] memory targets = new address[](2);
        targets[0] = address(integrator);
        targets[1] = address(integrator);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = swap1;
        calldatas[1] = swap2;

        entryPoint.handleOps(hook, accounts, targets, calldatas);

        IDynamicFeeFacet.AddressBatchState memory bsA = hook.addressBatchStateOf(address(accountA), poolId);
        assertGt(uint256(bsA.batchStartTs), 0, "A batch present after sequential exact-in swaps");
        assertGt(uint256(bsA.batchAccumPpm), 0, "A batchAccumPpm advanced across callbacks");
        // No other address accumulated state.
        assertEq(
            uint256(hook.addressBatchStateOf(address(this), poolId).batchAccumPpm),
            0,
            "no stray attribution to test contract"
        );
    }

    /// @notice Exact-output direction: a callback under a SEPARATE A session still attributes to A.
    /// @dev SUBSTITUTION: as above, the current router cannot express a true multi-hop over one hook in a
    ///         single call, so this runs a single begin → swap → end frame for A. It proves the exact-output
    ///         callback identity key is A under its own session (not Bundler/tx.origin/Router); it does not
    ///         prove single-session multi-hop. The identity invariant is direction-independent.
    function test_exactOutMultiHopUsesAForEveryHookCallback() external {
        bytes memory swapOut = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactOutOneForZero(1 ether), address(accountA), bytes(""))
        );

        AtomicSessionAccount[] memory accounts = new AtomicSessionAccount[](1);
        accounts[0] = accountA;
        address[] memory targets = new address[](1);
        targets[0] = address(integrator);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = swapOut;

        entryPoint.handleOps(hook, accounts, targets, calldatas);

        IDynamicFeeFacet.AddressBatchState memory bsA = hook.addressBatchStateOf(address(accountA), poolId);
        assertGt(uint256(bsA.batchStartTs), 0, "A batch present after exact-out swap");
        assertGt(uint256(bsA.batchAccumPpm), 0, "A batchAccumPpm advanced on exact-out callback");
    }

    // -----------------------------------------------------------------
    // No-trader / no-allowlist Router compatibility
    // -----------------------------------------------------------------

    /// @notice A router/integrator with NO trader parameter, NO IMsgSender, and NOT on any allowlist
    ///         completes a swap for A under A's session. Proves the design's "any Router" compatibility:
    ///         identity flows solely from the session, never from a router-supplied trader.
    function test_untrustedNoTraderRouterWorksForOneEconomicAccount() external {
        bytes memory swapForA = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(accountA), bytes(""))
        );

        AtomicSessionAccount[] memory accounts = new AtomicSessionAccount[](1);
        accounts[0] = accountA;
        address[] memory targets = new address[](1);
        targets[0] = address(integrator);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = swapForA;

        // The integrator is a fresh, untrusted, trader-less contract — yet the swap still attributes to A.
        entryPoint.handleOps(hook, accounts, targets, calldatas);

        assertGt(uint256(hook.addressBatchStateOf(address(accountA), poolId).batchStartTs), 0, "swap attributed to A");
    }

    // -----------------------------------------------------------------
    // External BatchExecutor is NOT A (negative)
    // -----------------------------------------------------------------

    /// @notice A plain external BatchExecutor that calls Hook+Router on A's behalf becomes the principal
    ///         itself; A does NOT receive [A][poolId] attribution. This is a NEGATIVE demonstration: the
    ///         executor opens its own session as itself, proving A cannot get A-keyed state via an executor.
    function test_externalBatchExecutorIsNotA() external {
        // Pre-condition: the executor must carry code (it does) and be funded/approved to pay the swap input.
        _fundAndApprove(address(batchExecutor));

        bytes memory swapCalldata = abi.encodeCall(
            SessionSwapIntegrator.swap, (key, _exactInZeroForOne(1 ether), address(batchExecutor), bytes(""))
        );

        // The executor drives begin -> Integrator.swap -> end from ITS OWN context.
        vm.prank(address(batchExecutor));
        batchExecutor.executeAsSelf(hook, address(integrator), swapCalldata);

        // The hook saw msg.sender == executor at begin, so the session and batch state are keyed to the
        // executor — NOT to the funded owner of the assets (who here is the executor too, but the point is
        // that A would NEVER receive A-keyed attribution through an unrelated executor).
        assertGt(
            uint256(hook.addressBatchStateOf(address(batchExecutor), poolId).batchStartTs),
            0,
            "executor is the recorded principal"
        );
        // Negative assertion that gives the test its name: A received NO batch-state attribution via the
        // external executor (both batchStartTs and batchAccumPpm stayed at their zero baseline).
        IDynamicFeeFacet.AddressBatchState memory bsA = hook.addressBatchStateOf(address(accountA), poolId);
        assertEq(uint256(bsA.batchStartTs), 0, "A never attributed via external executor");
        assertEq(uint256(bsA.batchAccumPpm), 0, "A never attributed via external executor");
    }

    // -----------------------------------------------------------------
    // Multi-user batch Router is UNSUPPORTED
    // -----------------------------------------------------------------

    /// @notice If A's session Router mixes V's order, all callbacks attribute to A — the hook cannot split
    ///         A and V. This is labeled UNSUPPORTED (not an isolation success).
    /// @dev The proof: V's "order" is run INSIDE A's still-active session (A does not end before V's swap),
    ///         so the callback sees activePrincipal == A. V receives no [V][poolId] batch state; everything
    ///         lands under [A][poolId]. This is why multi-user batch routers are out of scope.
    function test_multiUserBatchRouterAttributesCallbacksToAAndIsUnsupported() external {
        // A opens its session and stays active. The "V order" below is dispatched within A's session on
        // purpose, modeling a batch router that mixes users in one active session.
        // Begin A's session WITHOUT ending it, then run the swap directly from A (no end). This leaves A
        // active so the V-targeted swap that follows is forced under [A][poolId].
        vm.prank(address(accountA));
        hook.beginAccountSession();
        vm.prank(address(accountA));
        integrator.swap(key, _exactInZeroForOne(0.5 ether), address(accountA), bytes(""));

        // Now a swap whose economic intent is "for V" runs while A's session is still active: it MUST
        // attribute to A (no per-swap trader split is possible with the current model).
        vm.prank(address(accountA));
        integrator.swap(key, _exactInZeroForOne(0.5 ether), address(accountV), bytes(""));
        vm.prank(address(accountA));
        hook.endAccountSession();

        // RESULT (unsupported, not an isolation success): V gets no attribution, A accumulates both swaps.
        assertEq(
            uint256(hook.addressBatchStateOf(address(accountV), poolId).batchStartTs),
            0,
            "UNSUPPORTED: V order attributed to A, not V"
        );
        assertGt(
            uint256(hook.addressBatchStateOf(address(accountA), poolId).batchStartTs),
            0,
            "A's session absorbed the mixed order"
        );
    }

    // -----------------------------------------------------------------
    // Caught begin failure then target is UNSUPPORTED
    // -----------------------------------------------------------------

    /// @notice If a caller catches a begin failure and then calls the target anyway, the target still runs
    ///         UNDER the already-active (residual) session — NOT without one. This is the unsupported
    ///         boundary: the hook-only model cannot stop a callback from reading residual A.
    /// @dev Mechanism: the test pre-opens a session from `nonCompliant`, so the helper's inner
    ///         `beginAccountSession` reverts with `AccountSessionAlreadyActive` (the nested-begin guard),
    ///         which the helper catches before calling the target. The target runs while
    ///         `activePrincipal == nonCompliant` is still set. The true no-session begin failure
    ///         (`AccountSessionCallerMustHaveCode`, fired by a plain EOA) is structurally unreachable here:
    ///         catching the revert and calling the target both require code, but that error needs none. So
    ///         this test covers only the nested-begin variant of the unsupported path.
    function test_caughtBeginFailureThenTargetIsUnsupportedNotAnIsolationGuarantee() external {
        // Pre-open a session from `nonCompliant` (a deployed contract) so the helper's inner begin hits the
        // nested-begin guard. Without this pre-open the helper's begin would simply succeed (nothing to
        // catch); a contract caller can never trigger the no-code begin failure. The second begin (inside the
        // helper) reverts with `AccountSessionAlreadyActive`, the helper catches it, then calls the target
        // while the residual session is still active — the unsupported boundary.
        vm.prank(address(nonCompliant));
        hook.beginAccountSession();

        bytes memory spyCalldata = abi.encodeCall(TargetCallSpy.record, ());
        vm.prank(address(nonCompliant));
        (bool beginOk,, bool targetOk,) = nonCompliant.catchBeginFailureThenCallTarget(hook, address(spy), spyCalldata);

        assertFalse(beginOk, "second begin was caught as a failure");
        assertTrue(targetOk, "target ran anyway (unsupported path)");
        assertTrue(spy.wasCalled(), "target side effect observed - NOT an isolation guarantee");

        // Cleanup the session the first begin opened so the transient store does not bleed across tests.
        vm.prank(address(nonCompliant));
        hook.endAccountSession();
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Mints both tokens to `account` and approves the real-v4 integrator from `account`. Used for
    ///      A, V, the delegated EOA, and the executor — each pays and approves from its own context.
    function _fundAndApprove(address account_) internal {
        token0.mint(account_, 1000 ether);
        token1.mint(account_, 1000 ether);
        vm.prank(account_);
        token0.approve(address(integrator), type(uint256).max);
        vm.prank(account_);
        token1.approve(address(integrator), type(uint256).max);
    }

    /// @dev Exact-input zeroForOne swap of `amount` token0 -> token1 with a valid full-range price limit.
    function _exactInZeroForOne(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    /// @dev Exact-output oneForZero swap buying `amountOut` of token0 (pay token1). Direction is reversed
    ///      relative to the exact-input case so the afterSwap callback exercises the exact-output branch.
    function _exactOutOneForZero(uint256 amountOut) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
    }

    // -----------------------------------------------------------------
    // Same-principal batch accumulation (CF-006 coverage gap)
    // -----------------------------------------------------------------

    /// @notice Covers the missing "same session principal strictly accumulates within the batch window"
    ///         quadrant: two consecutive swaps by the SAME account, run through the REAL beforeSwap/afterSwap
    ///         session path (executeSession), must make batchAccumPpm strictly increase. This is strictly
    ///         stronger than test_exactInMultiHopUsesAForEveryHookCallback, which only asserts batchAccumPpm
    ///         > 0 and cannot distinguish accumulation from a reset.
    /// @dev Same account, same block (identical block.timestamp), so the second swap lands inside
    ///      ADDRESS_BATCH_WINDOW_SEC (3s) and takes the `if` accumulation branch (batchAccumPpm += pifPpm2),
    ///      making bsAfter2 strictly greater than bsAfter1. This is NOT a direct facet call — it flows through
    ///      begin -> Integrator.swap -> end exactly as production usage does.
    function test_samePrincipalTwoSwapsStrictlyAccumulateBatchPpm() external {
        SwapParams memory params = _exactInZeroForOne(0.5 ether);
        bytes memory swapCalldata =
            abi.encodeCall(SessionSwapIntegrator.swap, (key, params, address(accountA), bytes("")));

        // First swap under A's own session frame (A is both payer and recipient; integrator pulls input from
        // msg.sender == A inside the unlock callback).
        vm.prank(address(accountA));
        accountA.executeSession(hook, address(integrator), swapCalldata);

        uint256 bsAfter1 = uint256(hook.addressBatchStateOf(address(accountA), poolId).batchAccumPpm);

        // Second swap in the SAME block — still inside the 3s batch window, so it accumulates rather than resets.
        vm.prank(address(accountA));
        accountA.executeSession(hook, address(integrator), swapCalldata);

        uint256 bsAfter2 = uint256(hook.addressBatchStateOf(address(accountA), poolId).batchAccumPpm);

        assertGt(bsAfter2, bsAfter1, "same-principal second swap must strictly accumulate within the batch window");
    }

    /// @notice CF-005 REGRESSION DETECTOR (characterization mode). This test currently LOCKS the BUGGY
    ///         behavior of CF-005: rotating fresh principals each reset the batch on their own first swap
    ///         (the `else` branch in DynamicFeeFacet), so they do NOT accumulate across principals. Once
    ///         CF-005 is fixed (batch keying changed to a non-rotatable identity), this assertion MUST flip:
    ///         assert instead that "the rotating shards' total accumulation >= the unsharded single-principal
    ///         accumulation" (or rewrite against the post-fix correct invariant). Until then, this test
    ///         passing means CF-005 is still present.
    /// @dev The batch is keyed by params.trader = session-captured activePrincipal = begin's msg.sender, which
    ///      is each fresh principal's own address. Each rotating principal's FIRST swap hits the `else` reset
    ///      branch (batchAccumPpm = its own single pifPpm), so they never share. The single accountA, running
    ///      three consecutive swaps in the same block, takes the `if` accumulation branch after the first
    ///      (batchAccumPpm = pifPpm_1 + pifPpm_2 + pifPpm_3), so it is strictly larger than any single
    ///      rotating principal's value. All swaps go through the REAL session path (executeSession), not facet
    ///      direct calls.
    function test_rotatingFreshPrincipalsDoNotShareBatch_currentlyCharacterizesCf005() external {
        // Three fresh principals, each funded/approved, each runs one swap as itself.
        AtomicSessionAccount p0 = new AtomicSessionAccount();
        AtomicSessionAccount p1 = new AtomicSessionAccount();
        AtomicSessionAccount p2 = new AtomicSessionAccount();
        _fundAndApprove(address(p0));
        _fundAndApprove(address(p1));
        _fundAndApprove(address(p2));

        SwapParams memory swapHalf = _exactInZeroForOne(0.5 ether);

        // Each rotating principal runs its own single swap (recipient = itself, payer = itself via msg.sender).
        {
            bytes memory cd = abi.encodeCall(SessionSwapIntegrator.swap, (key, swapHalf, address(p0), bytes("")));
            vm.prank(address(p0));
            p0.executeSession(hook, address(integrator), cd);
        }
        {
            bytes memory cd = abi.encodeCall(SessionSwapIntegrator.swap, (key, swapHalf, address(p1), bytes("")));
            vm.prank(address(p1));
            p1.executeSession(hook, address(integrator), cd);
        }
        {
            bytes memory cd = abi.encodeCall(SessionSwapIntegrator.swap, (key, swapHalf, address(p2), bytes("")));
            vm.prank(address(p2));
            p2.executeSession(hook, address(integrator), cd);
        }

        // Reference: the same accountA runs three consecutive swaps in the same block — it accumulates.
        bytes memory swapForA =
            abi.encodeCall(SessionSwapIntegrator.swap, (key, swapHalf, address(accountA), bytes("")));
        vm.prank(address(accountA));
        accountA.executeSession(hook, address(integrator), swapForA);
        vm.prank(address(accountA));
        accountA.executeSession(hook, address(integrator), swapForA);
        vm.prank(address(accountA));
        accountA.executeSession(hook, address(integrator), swapForA);

        // Each rotating principal hit the `else` reset branch on its own first swap (batchAccumPpm = its own
        // single pifPpm), so they do not accumulate across principals. accountA took the `if` accumulation
        // branch three times (batchAccumPpm = pifPpm_1 + pifPpm_2 + pifPpm_3), so it is strictly larger than
        // any single rotating principal's value.
        uint256 accumSingle = uint256(hook.addressBatchStateOf(address(accountA), poolId).batchAccumPpm);
        uint256 rotP0 = uint256(hook.addressBatchStateOf(address(p0), poolId).batchAccumPpm);
        uint256 rotP1 = uint256(hook.addressBatchStateOf(address(p1), poolId).batchAccumPpm);
        uint256 rotP2 = uint256(hook.addressBatchStateOf(address(p2), poolId).batchAccumPpm);
        assertGt(accumSingle, rotP0, "CF-005 char: single principal accumulates 3 slices, rotator p0 only its own");
        assertGt(accumSingle, rotP1, "CF-005 char: single principal accumulates 3 slices, rotator p1 only its own");
        assertGt(accumSingle, rotP2, "CF-005 char: single principal accumulates 3 slices, rotator p2 only its own");
    }

    // -----------------------------------------------------------------
    // R4-F06 characterization: end is a voluntary release, not a mandatory close
    // -----------------------------------------------------------------

    /// @notice R4-F06 characterization: omitting `endAccountSession` on a single-account frame does NOT revert.
    ///         The swap still succeeds and is attributed to the caller; `activePrincipal` remains set for the
    ///         remainder of this test frame (the outer transaction), and EIP-1153 transient storage auto-clears
    ///         it when the frame ends. This locks the code's actual behavior: the spec treats `end` as a
    ///         voluntary release rather than a mandatory close, so a lone account that forgets `end` loses no
    ///         funds and leaves no cross-transaction residue.
    /// @dev The swap is dispatched with begin + a direct Integrator.swap (no end), matching the fragment style
    ///      of `test_multiUserBatchRouterAttributesCallbacksToAAndIsUnsupported`. Within the same Foundry test
    ///      frame `activeAccountSessionPrincipal()` still reads A because transient auto-clear only happens at
    ///      frame (tx) end, not mid-frame.
    function test_omittedEndOnSingleAccountStillSucceeds_r4f06Characterization() external {
        vm.prank(address(accountA));
        hook.beginAccountSession();
        vm.prank(address(accountA));
        integrator.swap(key, _exactInZeroForOne(0.5 ether), address(accountA), bytes(""));
        // end deliberately omitted.

        // The swap succeeded and was attributed to A even though end was never called.
        assertGt(
            uint256(hook.addressBatchStateOf(address(accountA), poolId).batchStartTs),
            0,
            "R4-F06 char: swap succeeds even when end is omitted"
        );

        // Within this test frame the session is still active; transient auto-clear happens at frame (tx) end.
        assertEq(
            hook.activeAccountSessionPrincipal(),
            address(accountA),
            "R4-F06 char: activePrincipal still set within tx when end omitted"
        );
    }

    /// @notice R4-F06 characterization: when `end` is omitted, a later `begin` from another account in the SAME
    ///         transaction reverts with `AccountSessionAlreadyActive`. This is the executable evidence that end
    ///         remains the only clearing entry point within a transaction, so a multi-account serial frame still
    ///         requires the prior account to end before the next can begin.
    /// @dev Overlaps with `test_missingEndMakesVCompliantFrameRevertBeforeRouterOrCallback` in subject but not
    ///      in lens: that test drives V's full frame through the catching entry and asserts the target never
    ///      runs; this test asserts the exact `beginAccountSession` revert selector directly, without depending
    ///      on entryPoint/spy plumbing, for a precise and self-contained regression signal.
    function test_omittedEndBlocksLaterBeginInSameTx_r4f06Characterization() external {
        // A opens a session and omits end.
        vm.prank(address(accountA));
        hook.beginAccountSession();

        // V's begin in the same transaction reverts because A is still active.
        vm.prank(address(accountV));
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.AccountSessionAlreadyActive.selector, address(accountA))
        );
        hook.beginAccountSession();

        // Cleanup so the transient store does not bleed into other tests in this file.
        vm.prank(address(accountA));
        hook.endAccountSession();
    }
}
