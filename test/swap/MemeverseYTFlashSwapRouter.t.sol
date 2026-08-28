// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IPOLSplitter} from "../../src/polend/interfaces/IPOLSplitter.sol";
import {IMemeverseYTFlashSwapRouter} from "../../src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol";
import {MemeverseYTFlashSwapRouter} from "../../src/swap/MemeverseYTFlashSwapRouter.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OutrunSafeERC20} from "../../src/common/token/OutrunSafeERC20.sol";
import {
    MockYTManager,
    MockYTHook,
    MockYTHookMissingPoolManager,
    MockLauncher,
    MockLauncherMissingSelector,
    MockYTSplitter,
    YTMockERC20,
    YTFlashSwapRouterHarness
} from "../mocks/swap/YTFlashSwapMocks.sol";

/// @title MemeverseYTFlashSwapRouterTest
/// @notice Task 3 unit tests cover every public entry guard and one-shot callback guard; Task 4 adds the real buy
///         settlement coverage (positive flow, cost/delta/split/residual guards, dust, packed referrer, single swap,
///         and both currency-ordering mappings). Task 5 adds the real exact YT -> POL sell coverage (positive flow,
///         debt/delta/merge/min guards, dust, packed referrer, single swap).
contract MemeverseYTFlashSwapRouterTest is Test {
    uint256 internal constant VERSE_ID = 42;
    uint256 internal constant VERSE_ID_B = 43;
    uint256 internal constant EXACT_YT = 1 ether;
    // Stub phase never reaches a real swap, so the price limit is only stored on FlashContext; any value is safe.
    uint160 internal constant PRICE_LIMIT = type(uint160).max;

    // Task 4 buy fixture: y PT exact-input swaps into R POL, so the payer only pays the actual cost y - R. The mock
    // does not enforce sqrtPriceLimitX96 semantics, so the unlimited limit is only carried on FlashContext.
    uint256 internal constant BUY_Y = 100 ether;
    uint256 internal constant BUY_R = 73 ether;
    uint160 internal constant BUY_PRICE_LIMIT = type(uint160).max;

    // Task 5 sell fixture: exact-output POL -> y PT produces +y PT / -q POL deltas (Q_actual = q). The payer supplies
    // y YT; merge burns y PT + y YT into y POL, of which q POL settle the negative PoolManager delta and out = y - q
    // POL go to the recipient. The mock does not enforce sqrtPriceLimitX96 semantics, so the unlimited limit is only
    // carried on FlashContext.
    uint256 internal constant SELL_Y = 100 ether;
    uint256 internal constant SELL_Q = 61 ether;
    uint160 internal constant SELL_PRICE_LIMIT = type(uint160).max;

    MockYTManager internal manager;
    MockYTHook internal hook;
    MockLauncher internal launcher;
    MockYTSplitter internal splitter;
    YTMockERC20 internal pt;
    YTMockERC20 internal yt;
    YTMockERC20 internal pol;
    MemeverseYTFlashSwapRouter internal router;

    address internal recipient;
    address internal account;
    address internal otherAccount;
    address internal referrer;

    function setUp() public {
        manager = new MockYTManager();
        hook = new MockYTHook();
        launcher = new MockLauncher();
        splitter = new MockYTSplitter();
        pt = new YTMockERC20("PT", "PT");
        yt = new YTMockERC20("YT", "YT");
        pol = new YTMockERC20("POL", "POL");

        // Wire the canonical dependency graph the router re-derives on every call.
        hook.setLauncher(address(launcher));
        hook.setPoolManager(IPoolManager(address(manager)));
        launcher.setCanonicalHook(address(hook));
        launcher.setCanonicalSplitter(address(splitter));
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));

        router = new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );

        recipient = makeAddr("recipient");
        account = makeAddr("account");
        otherAccount = makeAddr("otherAccount");
        referrer = makeAddr("referrer");
    }

    /// @notice Rejects deployment when the pool manager dependency is zero.
    function testConstructor_RevertsWhenManagerIsZero() public {
        vm.expectRevert(IMemeverseYTFlashSwapRouter.ZeroAddress.selector);
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(0)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );
    }

    /// @notice Rejects deployment when the hook dependency is zero.
    function testConstructor_RevertsWhenHookIsZero() public {
        vm.expectRevert(IMemeverseYTFlashSwapRouter.ZeroAddress.selector);
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(0)), IPOLSplitter(address(splitter))
        );
    }

    /// @notice Rejects deployment when the splitter dependency is zero.
    function testConstructor_RevertsWhenSplitterIsZero() public {
        vm.expectRevert(IMemeverseYTFlashSwapRouter.ZeroAddress.selector);
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(0))
        );
    }

    /// @notice Rejects deployment when `hook_` is a non-zero address with no deployed code, so the `poolManager()`
    ///         STATICCALL fails with a named error instead of an opaque ABI-decode revert.
    function testConstructor_RevertsWhenHookHasNoCode() public {
        address noCodeHook = makeAddr("noCodeHook");
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.HookCodeNotReady.selector, noCodeHook));
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(noCodeHook), IPOLSplitter(address(splitter))
        );
    }

    /// @notice Rejects deployment when `manager_` is a non-zero address with no deployed code, even when the hook reports
    ///         the same address as its `poolManager` (which would otherwise pass the diagonal compare). A no-code manager
    ///         cannot service `unlock`/`swap`, and the binding is immutable, so the constructor must fail-closed.
    function testConstructor_RevertsWhenManagerHasNoCode() public {
        address noCodeManager = makeAddr("noCodeManager");
        // Make the hook report the same no-code address so the diagonal compare would pass without the code check.
        hook.setPoolManager(IPoolManager(noCodeManager));
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.PoolManagerCodeNotReady.selector, noCodeManager)
        );
        new MemeverseYTFlashSwapRouter(
            IPoolManager(noCodeManager), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );
    }

    /// @notice Rejects deployment when `splitter_` is a non-zero address with no deployed code. A no-code splitter cannot
    ///         service `getPTAndYTAndPOL` / `split` / `merge`, and the binding is immutable, so the constructor must
    ///         fail-closed instead of letting the deployment succeed and revert opaquely at the first runtime call.
    function testConstructor_RevertsWhenSplitterHasNoCode() public {
        address noCodeSplitter = makeAddr("noCodeSplitter");
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.SplitterCodeNotReady.selector, noCodeSplitter)
        );
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(noCodeSplitter)
        );
    }

    /// @notice Rejects deployment when the router's `manager_` differs from the hook's immutable PoolManager. A
    ///         mismatched binding is immutable and would permanently revert both entrypoints at `onlyPoolManager`.
    function testConstructor_RevertsWhenManagerDiffersFromHookPoolManager() public {
        MockYTManager otherManager = new MockYTManager();
        // The hook's poolManager is `manager`; passing `otherManager` (non-zero, has code) must fail-closed.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.RouterPoolManagerMismatch.selector, address(otherManager), address(manager)
            )
        );
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(otherManager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );
    }

    /// @notice A valid deployment where the router's `manager_` equals the hook's bound PoolManager succeeds.
    function testConstructor_SucceedsWhenManagerMatchesHookPoolManager() public {
        MemeverseYTFlashSwapRouter r = new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );
        assertTrue(address(r) != address(0));
    }

    /// @notice Rejects deployment when `hook_` has code but lacks the `poolManager()` selector, so the constructor's
    ///         STATICCALL reverts instead of deploying a router bound to a hook whose PoolManager cannot be read.
    function testConstructor_RevertsWhenHookMissingPoolManagerSelector() public {
        MockYTHookMissingPoolManager missingSelectorHook = new MockYTHookMissingPoolManager();
        // The address passes the zero-address and `code.length == 0` guards (it has code), then the runtime-cast
        // STATICCALL `IImmutableState(address(hook_)).poolManager()` hits an unknown selector with no fallback. The
        // EVM dispatcher reverts with empty returndata and Solidity's high-level ABI-decode reverts; the empty
        // revert payload is pinned exactly so any other failure mode fails the test.
        vm.expectRevert(bytes(""));
        new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(missingSelectorHook)),
            IPOLSplitter(address(splitter))
        );
    }

    /// @dev No active session: `activeAccountSessionPrincipal()` is address(0). The principal guard fires before
    ///      any POL pull, transferFrom, split, merge, take, or settle.
    function test_RevertWhen_NoSessionBeforeAnyPOLPull() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AccountSessionPrincipalMismatch.selector, address(0), account
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev No active session on the sell entry: `activeAccountSessionPrincipal()` is address(0). The principal guard
    ///      fires before any YT pull. Mirrors `test_RevertWhen_NoSessionBeforeAnyPOLPull` on the sell path so the
    ///      no-session sub-case (`active == address(0)`) is directly covered on both entries, not only inferred from the
    ///      shared `_validateAndResolve` check (src `active != msg.sender`).
    function test_RevertWhen_NoSessionBeforeAnyYTPull() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AccountSessionPrincipalMismatch.selector, address(0), account
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev Active principal is a different address than the caller; the guard fires before any YT pull.
    function test_RevertWhen_ActivePrincipalDiffersBeforeAnyYTPull() public {
        hook.setActivePrincipal(otherAccount);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AccountSessionPrincipalMismatch.selector, otherAccount, account
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev Active principal is a different address than the caller; the guard fires before any POL pull. Mirrors
    ///      `test_RevertWhen_ActivePrincipalDiffersBeforeAnyYTPull` on the buy path so the mismatched-principal sub-case
    ///      (`active != address(0) && active != msg.sender`) is directly covered on both entries, not only inferred from
    ///      the shared `_validateAndResolve` check (src `active != msg.sender`).
    function test_RevertWhen_ActivePrincipalDiffersBeforeAnyPOLPull() public {
        hook.setActivePrincipal(otherAccount);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AccountSessionPrincipalMismatch.selector, otherAccount, account
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The inherited SafeCallback only allows the PoolManager itself to enter `unlockCallback`.
    function test_RevertWhen_NonManagerCallsUnlockCallback() public {
        vm.prank(makeAddr("notManager"));
        vm.expectPartialRevert(ImmutableState.NotPoolManager.selector);
        router.unlockCallback(bytes("non-manager"));
    }

    /// @dev Manager in Tamper mode re-enters with a modified payload; the hash check rejects it before decode.
    function test_RevertWhen_CallbackDataIsTampered() public {
        hook.setActivePrincipal(account);
        manager.setMode(MockYTManager.Mode.Tamper);
        vm.prank(account);
        // Selector-only: `actual` is `keccak256` of the tampered FlashContext payload, re-encoded at runtime
        // with deployed addresses/amounts and brittle to recompute in-test; the selector pins that the tampered
        // payload is rejected before decode. Contrast `test_RevertWhen_ReplayedCallbackAfterSuccessfulBuy`,
        // whose payload is a fixed literal and so asserts the full `(expected, actual)`.
        vm.expectPartialRevert(IMemeverseYTFlashSwapRouter.UnexpectedOrTamperedCallback.selector);
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev Manager in NoCallback mode returns without invoking the callback; the pending hash stays set and `_runFlashSwap`
    ///      reverts before decoding any result.
    function test_RevertWhen_CallbackIsNotConsumed() public {
        uint256 maxPOLIn = EXACT_YT + 1;
        hook.setActivePrincipal(account);
        manager.setMode(MockYTManager.Mode.NoCallback);
        bytes32 expectedPendingHash = keccak256(
            abi.encode(
                uint8(0), // FlashAction.Buy
                account,
                recipient,
                referrer,
                VERSE_ID,
                EXACT_YT,
                maxPOLIn,
                PRICE_LIMIT,
                address(pt),
                address(yt),
                address(pol)
            )
        );
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.CallbackNotConsumed.selector, expectedPendingHash)
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, maxPOLIn, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The hook's launcher never pointed at the router's hook immutable; canonical dependency fails before funds.
    function test_RevertWhen_InitialCanonicalDependenciesMismatchBeforeFunds() public {
        launcher.setCanonicalHook(makeAddr("wrongHook"));
        hook.setActivePrincipal(account);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.CanonicalDependencyMismatch.selector,
                address(hook),
                makeAddr("wrongHook"),
                address(splitter),
                address(splitter)
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The launcher initially matched but its splitter binding is repointed away from the router immutable; the
    ///      router re-reads the launcher every call (no caching), so the mismatch is caught before funds.
    function test_RevertWhen_LauncherConfigChangesBeforeFunds() public {
        hook.setActivePrincipal(account);
        launcher.setCanonicalSplitter(makeAddr("wrongSplitter"));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.CanonicalDependencyMismatch.selector,
                address(hook),
                address(hook),
                address(splitter),
                makeAddr("wrongSplitter")
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The hook's launcher binding points at the zero address (e.g. launcher never set, or `setLauncher(address(0))`
    ///      would-be path) before the `getLauncherContracts()` external read, so the router fails with the named
    ///      `LauncherCodeNotReady` instead of an opaque ABI-decode revert from the empty-return call. Fires inside
    ///      `_validateAndResolve` before any fund action on both entries.
    function test_RevertWhen_LauncherIsZeroOrNoCode() public {
        hook.setActivePrincipal(account);

        // Zero-address launcher: hook.launcher() returns address(0).
        address zeroLauncher = address(0);
        hook.setLauncher(zeroLauncher);
        // Buy path: guard fires before `_runFlashSwap`/swap and before the cost `transferFrom`.
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.LauncherCodeNotReady.selector, zeroLauncher));
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
        // Sell path: guard fires before `_runFlashSwap`/swap and before the payer YT `transferFrom`.
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.LauncherCodeNotReady.selector, zeroLauncher));
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);

        // No-code launcher: hook.launcher() returns a non-zero EOA with no deployed code.
        address noCodeLauncher = makeAddr("noCodeLauncher");
        hook.setLauncher(noCodeLauncher);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.LauncherCodeNotReady.selector, noCodeLauncher)
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.LauncherCodeNotReady.selector, noCodeLauncher)
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);

        // No underlying swap ever ran across all 4 cases.
        assertEq(manager.swapCount(), 0);

        // Restore the setUp launcher binding so the mutation does not leak into sibling tests in this contract.
        hook.setLauncher(address(launcher));
    }

    /// @dev Mirrors `testConstructor_RevertsWhenHookMissingPoolManagerSelector` on the runtime path: the launcher has
    ///      deployed code, so it passes the zero-address and `code.length == 0` -> `LauncherCodeNotReady` guards at the
    ///      `_validateAndResolve` named-error check, then the runtime-cast STATICCALL
    ///      `IMemeverseLauncher(address(launcherAddr)).getLauncherContracts()` hits an unknown selector with no fallback.
    ///      The EVM dispatcher reverts with empty returndata and Solidity's high-level ABI-decode reverts opaquely (no
    ///      named selector applies). This is the symmetric counterpart to the named-error
    ///      `test_RevertWhen_LauncherIsZeroOrNoCode`, covering the launcher-resolution residual sub-path that the named
    ///      guard does not reach. It fires before any fund action, so the behavior is fail-closed. The revert form is
    ///      opaque, so a bare `vm.expectRevert()` locks the fail-closed behavior without over-coupling to the opaque
    ///      revert form.
    function test_RevertWhen_LauncherHasCodeButMissingSelector() public {
        hook.setActivePrincipal(account);

        MockLauncherMissingSelector missingSelectorLauncher = new MockLauncherMissingSelector();
        hook.setLauncher(address(missingSelectorLauncher));

        // Buy path: the STATICCALL reverts before `_runFlashSwap`/swap and before the cost `transferFrom`.
        // The missing-selector revert bubbles as empty data; pin the empty payload exactly.
        vm.prank(account);
        vm.expectRevert(bytes(""));
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Sell path: the STATICCALL reverts before `_runFlashSwap`/swap and before the payer YT `transferFrom`.
        vm.prank(account);
        vm.expectRevert(bytes(""));
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp, referrer);

        // No underlying swap ever ran across both cases.
        assertEq(manager.swapCount(), 0);

        // Restore the setUp launcher binding so the mutation does not leak into sibling tests in this contract.
        hook.setLauncher(address(launcher));
    }

    // Entry-guard: invalid recipient (zero or router)

    /// @dev A zero recipient is rejected at the entry guard (`InvalidRecipient`), which fires inside
    ///      `_validateAndResolve` before any fund action. Buy path.
    function test_RevertWhen_BuyRecipientIsZero() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidRecipient.selector, address(0)));
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, 100 ether, BUY_PRICE_LIMIT, address(0), block.timestamp, referrer);

        // Entry guard fires before `_runFlashSwap`/swap and before the cost `transferFrom`.
        assertEq(manager.swapCount(), 0);
        assertEq(pol.transferFromAsFrom(account), 0);
    }

    /// @dev The router itself is not a valid recipient (would trap output). `InvalidRecipient` fires at the entry guard,
    ///      before any swap or payer POL pull.
    function test_RevertWhen_BuyRecipientIsRouter() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidRecipient.selector, address(router)));
        router.swapPOLForExactYT(
            VERSE_ID, EXACT_YT, 100 ether, BUY_PRICE_LIMIT, address(router), block.timestamp, referrer
        );

        // Entry guard fires before `_runFlashSwap`/swap and before the cost `transferFrom`.
        assertEq(manager.swapCount(), 0);
        assertEq(pol.transferFromAsFrom(account), 0);
    }

    /// @dev A zero recipient is rejected at the entry guard (`InvalidRecipient`), which fires inside
    ///      `_validateAndResolve` before any fund action. Sell path.
    function test_RevertWhen_SellRecipientIsZero() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidRecipient.selector, address(0)));
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, address(0), block.timestamp, referrer);

        // Entry guard fires before `_runFlashSwap`/swap and before the payer YT `transferFrom`.
        assertEq(manager.swapCount(), 0);
        assertEq(yt.transferFromAsFrom(account), 0);
    }

    /// @dev The router itself is not a valid recipient (would trap output). `InvalidRecipient` fires at the entry guard,
    ///      before any swap or payer YT pull.
    function test_RevertWhen_SellRecipientIsRouter() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidRecipient.selector, address(router)));
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, address(router), block.timestamp, referrer);

        // Entry guard fires before `_runFlashSwap`/swap and before the payer YT `transferFrom`.
        assertEq(manager.swapCount(), 0);
        assertEq(yt.transferFromAsFrom(account), 0);
    }

    // =====================================================================================
    // Task 4: POL -> exact YT settlement
    // =====================================================================================

    /// @dev Scripts the buy swap delta for y PT exact-input -> R POL, honoring the canonical currency ordering.
    function _scriptBuyDelta(uint256 y, uint256 r) internal {
        bool ptIsCurrency0 = address(pt) < address(pol);
        if (ptIsCurrency0) {
            manager.scriptSwapDelta(-int128(int256(y)), int128(int256(r)));
        } else {
            manager.scriptSwapDelta(int128(int256(r)), -int128(int256(y)));
        }
    }

    /// @dev Binds the active session principal to `account` and tops up its POL so the router can pull the actual cost.
    function _startSessionAndFund(uint256 polAmount) internal {
        hook.setActivePrincipal(account);
        if (pol.balanceOf(account) < polAmount) {
            pol.mint(account, polAmount - pol.balanceOf(account));
        }
    }

    /// @dev `account` approves the router to pull POL up to `amount`.
    function _approveAccountPOL(uint256 amount) internal {
        vm.prank(account);
        pol.approve(address(router), amount);
    }

    /// @dev The router starts with no PT/YT/POL, so the restored baseline is zero for each.
    function _assertRouterBaseline() internal view {
        assertEq(pt.balanceOf(address(router)), 0);
        assertEq(yt.balanceOf(address(router)), 0);
        assertEq(pol.balanceOf(address(router)), 0);
    }

    /// @dev Reverting calls must not emit either router business event before their final postcondition check.
    function _assertNoRouterFlashSwapEvent(Vm.Log[] memory logs) internal view {
        bytes32 buyEventSignature = keccak256("YTFlashSwapPOLForYT(uint256,address,address,uint256,uint256,address)");
        bytes32 sellEventSignature = keccak256("YTFlashSwapYTForPOL(uint256,address,address,uint256,uint256,address)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != buyEventSignature);
            assertTrue(logs[i].topics[0] != sellEventSignature);
        }
    }

    /// @dev Runs a full successful buy as `account` with the given referrer.
    function _doSuccessfulBuy(uint256 y, uint256 r, address ref) internal {
        _scriptBuyDelta(y, r);
        _startSessionAndFund(y);
        _approveAccountPOL(y - r);
        vm.prank(account);
        router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, ref);
    }

    /// @dev Positive buy: only the actual cost (y - R) is pulled, the split is exact, the splitter POL allowance
    ///      returns to zero, the router baseline is restored, and the event carries the actual POL used.
    function test_Buy_PullsOnlyActualCostSplitsAndRestoresBaseline() public {
        uint256 y = BUY_Y;
        uint256 r = BUY_R;
        _scriptBuyDelta(y, r);
        _startSessionAndFund(y);
        _approveAccountPOL(y - r);
        uint256 before = pol.balanceOf(account);

        vm.expectEmit(true, true, true, true, address(router));
        emit IMemeverseYTFlashSwapRouter.YTFlashSwapPOLForYT(VERSE_ID, account, recipient, y, y - r, referrer);
        vm.prank(account);
        uint256 used =
            router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        assertEq(used, y - r);
        assertEq(before - pol.balanceOf(account), y - r);
        assertEq(yt.balanceOf(recipient), y);
        assertEq(pol.allowance(address(router), address(splitter)), 0);
        _assertRouterBaseline();
    }

    /// @dev r == 0 (zero AMM-leg output) must fail closed at `InvalidBuyCost`, not as a structural delta mismatch;
    ///      r >= y (zero/negative cost) must fail at the same error. Covers both branches. The cost guard
    ///      precedes take/pull/split; two ordering pins are used because they catch different reorders:
    ///      - `armSplitRanBeforeGuard()` pins check-before-split with a differential revert that survives the rollback
    ///        (unlike a rolled-back `splitCount` counter).
    ///      - `manager.armTakeRanBeforeGuard()` pins check-before-take: if `take` were reordered before the guard, the
    ///        mock reverts with `TakeRanBeforeGuard()` instead of `InvalidBuyCost`, so `expectRevert(InvalidBuyCost)`
    ///        fails.
    function test_RevertWhen_BuyCostIsZeroOrNegative() public {
        uint256 y = BUY_Y;
        bool ptIsCurrency0 = address(pt) < address(pol);

        // r == 0: polDelta == 0 passes the structural (< 0) guard and hits `InvalidBuyCost(0, y)`.
        {
            int128 ptDelta = -int128(int256(y));
            int128 polDelta = int128(int256(0));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFund(y);
            splitter.armSplitRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidBuyCost.selector, uint256(0), y));
            router.swapPOLForExactYT(VERSE_ID, y, y, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // r == y: zero cost (cost = y - y = 0).
        {
            int128 ptDelta = -int128(int256(y));
            int128 polDelta = int128(int256(y));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFund(y);
            splitter.armSplitRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidBuyCost.selector, y, y));
            router.swapPOLForExactYT(VERSE_ID, y, y, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // r > y: negative cost (cost = y - (y + 1) would underflow).
        {
            int128 ptDelta = -int128(int256(y));
            int128 polDelta = int128(int256(y + 1));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFund(y);
            splitter.armSplitRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidBuyCost.selector, y + 1, y));
            router.swapPOLForExactYT(VERSE_ID, y, y, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev The actual POL cost exceeds `maxPOLIn` before any take/pull/split; nothing is moved. The merge-style
    ///      counter pin is vacuous across a reverting frame (rollback restores it), so this uses two differential-revert
    ///      pins that catch different reorders:
    ///      - `armSplitRanBeforeGuard()`: a reordered `split` before the guard reverts with `SplitRanBeforeGuard`
    ///        instead of `MaxPOLInExceeded`, so `expectRevert(MaxPOLInExceeded)` fails and catches the reorder.
    ///      - `armTakeRanBeforeGuard()`: if `take` were reordered before the guard, the mock reverts with
    ///        `TakeRanBeforeGuard` instead of `MaxPOLInExceeded`, so `expectRevert(MaxPOLInExceeded)` fails.
    function test_RevertWhen_BuyExceedsMaxPOLIn() public {
        uint256 y = BUY_Y;
        uint256 r = 10 ether; // cost = 90 ether
        uint256 maxPOLIn = 50 ether; // cost > max
        _scriptBuyDelta(y, r);
        _startSessionAndFund(y);
        // Pin checks-before-split-and-take: an inverted split reverts with SplitRanBeforeGuard, an inverted take with
        // TakeRanBeforeGuard, not MaxPOLInExceeded.
        splitter.armSplitRanBeforeGuard();
        manager.armTakeRanBeforeGuard();
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MaxPOLInExceeded.selector, y - r, maxPOLIn));
        router.swapPOLForExactYT(VERSE_ID, y, maxPOLIn, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev A partial PT fill (ptDelta != -y) and a negative POL delta both surface as `FlashDeltaMismatch` before any
    ///      take, pull, split, settle, or transfer.
    function test_RevertWhen_BuyPartialFillOrExtraDelta() public {
        uint256 y = BUY_Y;
        bool ptIsCurrency0 = address(pt) < address(pol);

        // Partial fill: only y-1 PT consumed.
        {
            int128 ptDelta = -int128(int256(y - 1));
            int128 polDelta = int128(int256(BUY_R));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFund(y);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.FlashDeltaMismatch.selector, ptDelta, polDelta)
            );
            router.swapPOLForExactYT(VERSE_ID, y, y, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // Negative POL delta: structurally invalid output direction.
        {
            int128 ptDelta = -int128(int256(y));
            int128 polDelta = -int128(int256(1));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFund(y);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.FlashDeltaMismatch.selector, ptDelta, polDelta)
            );
            router.swapPOLForExactYT(VERSE_ID, y, y, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev The splitter result guard is a disjunction over two clauses (`ptMinted != c.ytAmount` and
    ///      `ytMinted != c.ytAmount`). Each clause is exercised with an exact revert assertion against a script where the
    ///      other leg is correct, so dropping either clause would let its case slip past the guard and break this test.
    ///
    ///      The guard is unreachable for the canonical POLSplitterUpgradeable: real `split` mints exactly `y` PT and `y` YT, and
    ///      `_validateAndResolve` locks the immutable `splitter` to the canonical address on every entry. This test uses
    ///      the mock splitter to deviate from 1:1, simulating a post-upgrade buggy/malicious canonical Splitter or a
    ///      non-canonical malformed one. It is therefore a defense-in-depth / upgrade-safety check, NOT proof that
    ///      split/merge accounting is safe against the real Splitter at runtime.
    function test_RevertWhen_BuySplitResultMismatch() public {
        uint256 y = BUY_Y;
        uint256 r = BUY_R;

        // PT short, YT correct: trips `ptMinted != c.ytAmount`.
        {
            splitter.scriptSplit(VERSE_ID, y - 1, y, 0, 0);
            _scriptBuyDelta(y, r);
            _startSessionAndFund(y);
            _approveAccountPOL(y - r);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.SplitResultMismatch.selector, y - 1, y, y)
            );
            router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // PT correct, YT short: trips `ytMinted != c.ytAmount`.
        {
            splitter.scriptSplit(VERSE_ID, y, y - 1, 0, 0);
            _scriptBuyDelta(y, r);
            _startSessionAndFund(y);
            _approveAccountPOL(y - r);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.SplitResultMismatch.selector, y, y - 1, y)
            );
            router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev A non-standard splitter leaves a non-zero POL allowance; the router fails closed before settling PT or
    ///      sending YT.
    function test_RevertWhen_BuyAllowanceResidual() public {
        uint256 y = BUY_Y;
        uint256 r = BUY_R;
        uint256 residual = 1 ether;
        splitter.scriptSplit(VERSE_ID, y, y, residual, 0);
        _scriptBuyDelta(y, r);
        _startSessionAndFund(y);
        _approveAccountPOL(y - r);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.SplitterAllowanceResidual.selector, residual)
        );
        router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev Entry guards: zero exact YT, exact YT above the int128 safe range, and an unknown verse (zero assets) all
    ///      revert before any fund action.
    function test_RevertWhen_BuyInvalidVerseOrBoundary() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.AmountOutOfRange.selector, uint256(0)));
        router.swapPOLForExactYT(VERSE_ID, 0, 100 ether, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AmountOutOfRange.selector, uint256(uint128(type(int128).max)) + 1
            )
        );
        router.swapPOLForExactYT(
            VERSE_ID,
            uint256(uint128(type(int128).max)) + 1,
            type(uint256).max,
            BUY_PRICE_LIMIT,
            recipient,
            block.timestamp,
            referrer
        );

        vm.prank(account);
        vm.expectPartialRevert(IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector);
        router.swapPOLForExactYT(
            VERSE_ID + 999, 1 ether, 1 ether, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer
        );
    }

    /// @dev The canonical verse-asset guard rejects any duplicate pair among (pt, yt, pol). Each of the three duplicate
    ///      clauses (`pt == yt`, `pt == pol`, `yt == pol`) is exercised with an exact revert assertion, so dropping any
    ///      one clause would let its case slip past the guard and break this test. `InvalidCanonicalVerseAssets` fires
    ///      inside `_validateAndResolve` before any POL is pulled on the buy path, so the fund-move values are unused.
    function test_RevertWhen_BuyDuplicateCanonicalVerseAssets() public {
        hook.setActivePrincipal(account);

        // pt == yt.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(pt), address(pol));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(pt),
                address(pol)
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // pt == pol.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pt));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                address(pt)
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // yt == pol.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(yt));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                address(yt)
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Restore the setUp binding so the mutated VERSE_ID assets do not leak into sibling tests in this contract.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));
    }

    /// @dev The canonical verse-asset guard also rejects a non-contract (EOA) returned by the canonical splitter, e.g. an
    ///      EOA stored as `pol` under launcher misconfiguration. The zero/duplicate check passes (the EOA is nonzero and
    ///      distinct), so without this guard the next `_snapshotBalances` would do an `IERC20.balanceOf` STATICCALL to a
    ///      non-contract and revert opaquely with no selector. Fires inside `_validateAndResolve` before any POL is pulled
    ///      on the buy path, so the fund-move values are unused.
    function test_RevertWhen_BuyCanonicalVerseAssetHasNoCode() public {
        hook.setActivePrincipal(account);

        address eoaPol = makeAddr("eoaPol");
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), eoaPol);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                eoaPol
            )
        );
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Restore the setUp binding so the mutated VERSE_ID assets do not leak into sibling tests in this contract.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));
    }

    /// @dev After a successful buy the one-shot context hash is cleared; re-entering the callback directly (even as the
    ///      manager) sees no pending context and reverts before any settlement.
    function test_RevertWhen_ReplayedCallbackAfterSuccessfulBuy() public {
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        vm.prank(address(manager));
        // Full-payload assertion: after a successful buy the pending context hash is cleared, so
        // `expected == bytes32(0)`; the replay payload is a fixed literal, so
        // `actual == keccak256(bytes("replayed-after-success"))`. This pins the no-pending-context half
        // of the `_unlockCallback` guard (`expected == bytes32(0) || actual != expected`), which a
        // selector-only assertion could not distinguish from the `actual != expected` half.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.UnexpectedOrTamperedCallback.selector,
                bytes32(0),
                keccak256(bytes("replayed-after-success"))
            )
        );
        router.unlockCallback(bytes("replayed-after-success"));
    }

    /// @dev Double-callback mode: the first callback runs the buy and clears the hash; the second callback reverts,
    ///      rolling back the whole unlock so no funds leave the payer.
    function test_RevertWhen_DoubleCallbackAfterSuccessfulBuy() public {
        manager.setMode(MockYTManager.Mode.Double);
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        vm.prank(account);
        // Selector-only: the second callback's `actual` is `keccak256` of the committed FlashContext (re-encoded
        // at runtime with deployed addresses/amounts), brittle to recompute in-test; the selector pins that the
        // double callback reverts and the unlock rolls back so no funds leave the payer.
        vm.expectPartialRevert(IMemeverseYTFlashSwapRouter.UnexpectedOrTamperedCallback.selector);
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev Pre-existing router dust across all three tokens is untouched by a successful buy.
    function test_BuyPreservesDust() public {
        pt.mint(address(router), 1);
        yt.mint(address(router), 1);
        pol.mint(address(router), 1);
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        assertEq(pt.balanceOf(address(router)), 1);
        assertEq(yt.balanceOf(address(router)), 1);
        assertEq(pol.balanceOf(address(router)), 1);
    }

    /// @dev A non-zero referrer is forwarded as packed bytes; a zero referrer is forwarded as empty hookData.
    function test_BuyUsesPackedReferrer() public {
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        assertEq(manager.lastHookData(), abi.encodePacked(referrer));

        _doSuccessfulBuy(BUY_Y, BUY_R, address(0));
        assertEq(manager.lastHookData(), bytes(""));
    }

    /// @dev A successful buy performs exactly one underlying PT/POL swap.
    function test_BuyUsesExactlyOneSwap() public {
        assertEq(manager.swapCount(), 0);
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        assertEq(manager.swapCount(), 1);
    }

    /// @dev A past `deadline` reverts `ExpiredPastDeadline` at `_validateAndResolve`, which is the first precondition
    ///      (before session/recipient/fund checks), so no session setup is needed. Covers the expired-deadline
    ///      requirement on the buy entry. Follows the sibling `MemeverseSwapRouter` pattern: pass
    ///      `block.timestamp - 1` so the deadline is strictly in the past without any `vm.warp`.
    function test_RevertWhen_BuyDeadlineExpired() public {
        // Pre-fund and approve so the post-revert balance/allowance assertion proves nothing was moved before the revert.
        pol.mint(account, EXACT_YT);
        vm.prank(account);
        pol.approve(address(router), EXACT_YT);

        vm.prank(account);
        vm.expectRevert(IMemeverseYTFlashSwapRouter.ExpiredPastDeadline.selector);
        router.swapPOLForExactYT(VERSE_ID, EXACT_YT, EXACT_YT, PRICE_LIMIT, recipient, block.timestamp - 1, referrer);
        // Nothing was pulled: payer balance and allowance are untouched.
        assertEq(pol.balanceOf(account), EXACT_YT);
        assertEq(pol.allowance(account, address(router)), EXACT_YT);
    }

    /// @dev `deadline == block.timestamp` is the inclusive edge of the NatSpec "Latest valid execution timestamp
    ///      (inclusive)"; a buy at exactly the deadline must succeed. Pins the strict `>` semantics so a regression
    ///      to `>=` would be caught.
    function test_BuyAtDeadlineBoundarySucceeds() public {
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        assertEq(yt.balanceOf(recipient), BUY_Y);
    }

    /// @dev `y == type(int128).max` is the inclusive upper bound (`0 < amount <= type(int128).max`). The entry
    ///      guard (`revert AmountOutOfRange` in `_validateAndResolve`)
    ///      uses strict `>`, so MAX is legal. This test pins the `>` semantics: if the guard were wrongly changed to
    ///      `>=`, this test would revert with `AmountOutOfRange` and fail. It mirrors `test_BuyAtDeadlineBoundarySucceeds`
    ///      for the deadline closed-interval edge. Setting R = y - 1 gives an actual cost of `cost = y - R = 1`,
    ///      proving MAX passes through the full take/pull/approve/split/settle/transfer path (mock split/take/transfer
    ///      have no upper bound).
    function test_BuyAtInt128MaxBoundarySucceeds() public {
        uint256 y = uint256(uint128(type(int128).max));
        uint256 r = y - 1; // R = y - 1, so the actual cost = y - R = 1
        _scriptBuyDelta(y, r);
        _startSessionAndFund(y);
        _approveAccountPOL(y - r);

        vm.prank(account);
        uint256 used =
            router.swapPOLForExactYT(VERSE_ID, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        assertEq(used, y - r); // Actual POL cost is exactly 1
        assertEq(yt.balanceOf(recipient), y);
        assertEq(pol.allowance(address(router), address(splitter)), 0);
        _assertRouterBaseline();
    }

    /// @dev Sell-side mirror: `y == type(int128).max` is the inclusive upper bound and the entry guard is likewise
    ///      strict `>`. The signed cast `int128(int256(c.ytAmount))` (inside `_executeSell`) neither truncates nor
    ///      panics for MAX (0.8.x), so MAX is legal. Mirrors `test_BuyAtInt128MaxBoundarySucceeds`. Setting Q = y - 1
    ///      gives a net output of `polOut = y - Q = 1`, proving MAX passes through the full
    ///      take/pull/merge/settle/transfer path.
    function test_SellAtInt128MaxBoundarySucceeds() public {
        uint256 y = uint256(uint128(type(int128).max));
        uint256 q = y - 1; // Q = y - 1, so the net output polOut = y - Q = 1
        _scriptSellDelta(y, q);
        _startSessionAndFundYT(y);
        _approveAccountYT(y);

        uint256 polBefore = pol.balanceOf(recipient);
        uint256 mergeBefore = splitter.mergeCount();

        vm.prank(account);
        uint256 out =
            router.swapExactYTForPOL(VERSE_ID, y, y - q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        assertEq(out, y - q); // Net POL output is exactly 1
        assertEq(pol.balanceOf(recipient) - polBefore, y - q);
        assertEq(splitter.mergeCount() - mergeBefore, 1);
        _assertRouterBaseline();
    }

    /// @dev Pure mapping harness: currency0 is PT (and currency1 is POL) exactly when ptIsCurrency0 is true, and the
    ///      legs swap otherwise. Both branches are exercised without depending on a token-ordering fixture.
    function test_DeltaMapping_MapsBothCurrencyOrders() public {
        YTFlashSwapRouterHarness h = new YTFlashSwapRouterHarness(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );
        int128 ptD = -50;
        int128 polD = 73;
        BalanceDelta d = toBalanceDelta(ptD, polD);

        (int128 pt0, int128 pol0) = h.exposed_deltasForPTAndPOL(d, true);
        assertEq(pt0, ptD);
        assertEq(pol0, polD);

        (int128 pt1, int128 pol1) = h.exposed_deltasForPTAndPOL(d, false);
        assertEq(pt1, polD);
        assertEq(pol1, ptD);
    }

    /// @dev The buy always swaps exact-input y PT (`zeroForOne = ptIsCurrency0`, `amountSpecified = -y`). Two verses
    ///      with swapped pt/pol roles cover both currency orderings via the same underlying token addresses.
    function test_SwapParams_MapsBothCurrencyOrders() public {
        bool ptFirst = address(pt) < address(pol);

        _runBuyCaptureParams(VERSE_ID, address(pt), address(yt), address(pol), BUY_Y, BUY_R);
        assertEq(manager.lastZeroForOne(), ptFirst);
        assertEq(manager.lastAmountSpecified(), -int256(BUY_Y));

        _runBuyCaptureParams(VERSE_ID_B, address(pol), address(yt), address(pt), BUY_Y, BUY_R);
        assertEq(manager.lastZeroForOne(), !ptFirst);
        assertEq(manager.lastAmountSpecified(), -int256(BUY_Y));
    }

    /// @dev Successful buy and sell entries must forward the caller-provided price limit unchanged to PoolManager.swap.
    function test_SqrtPriceLimitX96_IsForwardedOnSuccessfulBuyAndSell() public {
        uint160 buyPriceLimit = 123_456_789;
        uint160 sellPriceLimit = 987_654_321;

        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        vm.prank(account);
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, buyPriceLimit, recipient, block.timestamp, referrer);
        assertEq(manager.lastSqrtPriceLimitX96(), buyPriceLimit);

        _scriptSellDelta(SELL_Y, SELL_Q);
        _startSessionAndFundYT(SELL_Y);
        _approveAccountYT(SELL_Y);
        vm.prank(account);
        router.swapExactYTForPOL(
            VERSE_ID, SELL_Y, SELL_Y - SELL_Q, sellPriceLimit, recipient, block.timestamp, referrer
        );
        assertEq(manager.lastSqrtPriceLimitX96(), sellPriceLimit);
    }

    /// @dev Registers a verse, scripts a matching buy delta, funds and approves `account`, runs the buy, and leaves the
    ///      manager's recorded swap params for the caller to assert. Used for both currency orderings.
    function _runBuyCaptureParams(
        uint256 verseId,
        address ptAddr,
        address ytAddr,
        address polAddr,
        uint256 y,
        uint256 r
    ) internal {
        splitter.setVerseAssets(verseId, ptAddr, ytAddr, polAddr);
        bool ptIsCurrency0 = ptAddr < polAddr;
        if (ptIsCurrency0) {
            manager.scriptSwapDelta(-int128(int256(y)), int128(int256(r)));
        } else {
            manager.scriptSwapDelta(int128(int256(r)), -int128(int256(y)));
        }
        hook.setActivePrincipal(account);
        YTMockERC20(polAddr).mint(account, y);
        vm.prank(account);
        YTMockERC20(polAddr).approve(address(router), y - r);
        vm.prank(account);
        router.swapPOLForExactYT(verseId, y, y - r, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    // =====================================================================================
    // Task 5: exact YT -> POL settlement
    // =====================================================================================

    /// @dev Scripts the sell swap delta for exact-output POL -> y PT, honoring the canonical currency ordering. The
    ///      router receives +y PT (take leg) and owes q POL (settle leg).
    function _scriptSellDelta(uint256 y, uint256 q) internal {
        bool ptIsCurrency0 = address(pt) < address(pol);
        int128 ptDelta = int128(int256(y));
        int128 polDelta = -int128(int256(q));
        if (ptIsCurrency0) {
            manager.scriptSwapDelta(ptDelta, polDelta);
        } else {
            manager.scriptSwapDelta(polDelta, ptDelta);
        }
    }

    /// @dev Binds the active session principal to `account` and tops up its YT so the router can pull the exact sell
    ///      input via `safeTransferFrom`.
    function _startSessionAndFundYT(uint256 ytAmount) internal {
        hook.setActivePrincipal(account);
        if (yt.balanceOf(account) < ytAmount) {
            yt.mint(account, ytAmount - yt.balanceOf(account));
        }
    }

    /// @dev `account` approves the router to pull YT up to `amount`.
    function _approveAccountYT(uint256 amount) internal {
        vm.prank(account);
        yt.approve(address(router), amount);
    }

    /// @dev Runs a full successful sell as `account` with the given referrer.
    function _doSuccessfulSell(uint256 y, uint256 q, address ref) internal {
        _scriptSellDelta(y, q);
        _startSessionAndFundYT(y);
        _approveAccountYT(y);
        vm.prank(account);
        router.swapExactYTForPOL(VERSE_ID, y, y - q, SELL_PRICE_LIMIT, recipient, block.timestamp, ref);
    }

    /// @dev Positive sell: take exactly y PT, pull y YT, merge 1:1 into y POL, settle q POL, send out = y - q POL to
    ///      the recipient, fire the sell event, and restore the router baseline.
    function test_Sell_TakesExactPTMergesAndPaysNetPOL() public {
        uint256 y = SELL_Y;
        uint256 q = SELL_Q;
        _scriptSellDelta(y, q);
        _startSessionAndFundYT(y);
        _approveAccountYT(y);
        uint256 before = pol.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(router));
        emit IMemeverseYTFlashSwapRouter.YTFlashSwapYTForPOL(VERSE_ID, account, recipient, y, y - q, referrer);
        vm.prank(account);
        uint256 out =
            router.swapExactYTForPOL(VERSE_ID, y, y - q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        assertEq(out, y - q);
        assertEq(pol.balanceOf(recipient) - before, y - q);
        assertEq(splitter.mergeCount(), 1);
        // No PT/YT Splitter approval is ever opened on the sell path (merge burns directly, like the real Splitter).
        assertEq(pt.allowance(address(router), address(splitter)), 0);
        assertEq(yt.allowance(address(router), address(splitter)), 0);
        _assertRouterBaseline();
    }

    /// @dev q == 0 (zero AMM-leg input) passes the structural (`> 0`) guard and hits `InvalidSellDebt(0, y)`; q == y
    ///      (zero output) and q > y (negative output) hit the same error. Covers all three sell-debt branches.
    ///      The debt guard precedes take/pull/merge; two ordering pins are used because they catch different reorders:
    ///      - `armMergeRanBeforeGuard()` pins check-before-merge via a differential revert that survives the rollback
    ///        (a rolled-back `mergeCount` counter would be vacuous here).
    ///      - `manager.armTakeRanBeforeGuard()` pins check-before-take: if `take` were reordered before the guard, the
    ///        mock reverts with `TakeRanBeforeGuard()` instead of `InvalidSellDebt`, so `expectRevert(InvalidSellDebt)`
    ///        fails.
    function test_RevertWhen_SellDebtIsZeroOrNotLessThanY() public {
        uint256 y = SELL_Y;
        bool ptIsCurrency0 = address(pt) < address(pol);

        // q == 0: polDelta == 0 passes the `> 0` structural guard and reaches `InvalidSellDebt(0, y)`.
        {
            int128 ptDelta = int128(int256(y));
            int128 polDelta = int128(int256(0));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFundYT(y);
            _approveAccountYT(y);
            splitter.armMergeRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidSellDebt.selector, uint256(0), y));
            router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // q == y: zero output (out = y - y = 0).
        {
            uint256 q = y;
            int128 ptDelta = int128(int256(y));
            int128 polDelta = -int128(int256(q));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFundYT(y);
            _approveAccountYT(y);
            splitter.armMergeRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidSellDebt.selector, q, y));
            router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // q > y: negative output (out = y - (y + 1) would underflow).
        {
            uint256 q = y + 1;
            int128 ptDelta = int128(int256(y));
            int128 polDelta = -int128(int256(q));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFundYT(y);
            _approveAccountYT(y);
            splitter.armMergeRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.InvalidSellDebt.selector, q, y));
            router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev `polOut < minPOLOut` must revert before any take, payer pull, or merge, and `minPOLOut` must keep full
    ///      uint256 comparison semantics with no int128 cap (IMemeverseYTFlashSwapRouter).
    ///      Three ordering pins are used because they catch different reorders:
    ///      - Zero YT allowance pins check-before-pull: an out-of-order pull would fail `transferFrom` with a Panic /
    ///        SafeERC20 error rather than `MinPOLOutNotMet`, so `expectRevert(MinPOLOutNotMet)` fails and catches it.
    ///      - `armMergeRanBeforeGuard()` pins check-before-merge: if `merge` were reordered before the guard, the mock
    ///        reverts with `MergeRanBeforeGuard()` instead of `MinPOLOutNotMet`, so `expectRevert(MinPOLOutNotMet)`
    ///        fails. This survives the revert-frame rollback (it changes the revert reason, not a rolled-back counter),
    ///        unlike a `mergeCount()==0` assertion which is vacuous because the reverting frame restores the counter.
    ///      - `manager.armTakeRanBeforeGuard()` pins check-before-take: if `take` were reordered before the guard, the
    ///        mock reverts with `TakeRanBeforeGuard()` instead of `MinPOLOutNotMet`, so `expectRevert(MinPOLOutNotMet)`
    ///        fails.
    function test_RevertWhen_SellBelowMinBeforeTake() public {
        uint256 y = SELL_Y;
        uint256 q = SELL_Q;

        // Near-bound value: out = 39, min = 40 -> below bound.
        {
            uint256 minOut = (y - q) + 1 ether;
            _scriptSellDelta(y, q);
            _startSessionAndFundYT(y);
            // Pin check-before-pull: zero YT allowance so an inverted pull fails at transferFrom instead of here.
            vm.prank(account);
            yt.approve(address(router), 0);
            // Pin checks-before-merge-and-take: an inverted merge reverts with MergeRanBeforeGuard, an inverted take
            // with TakeRanBeforeGuard, not MinPOLOutNotMet.
            splitter.armMergeRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MinPOLOutNotMet.selector, y - q, minOut));
            router.swapExactYTForPOL(VERSE_ID, y, minOut, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // Full uint256 upper bound: `minPOLOut = type(uint256).max` must still reach the settlement and revert with
        // MinPOLOutNotMet. A regression that caps `minPOLOut` to int128 at entry (mirroring the `ytAmount` guard)
        // would instead surface as AmountOutOfRange; this block fails under that regression. Mirrors the buy side's
        // `maxPOLIn = type(uint256).max` coverage. Zero YT allowance still pins check-before-pull ordering.
        {
            uint256 minOut = type(uint256).max;
            _scriptSellDelta(y, q);
            _startSessionAndFundYT(y);
            vm.prank(account);
            yt.approve(address(router), 0);
            splitter.armMergeRanBeforeGuard();
            manager.armTakeRanBeforeGuard();
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MinPOLOutNotMet.selector, y - q, minOut));
            router.swapExactYTForPOL(VERSE_ID, y, minOut, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev A partial PT fill (ptDelta != +y) and a positive POL delta both surface as `FlashDeltaMismatch` before any
    ///      take, pull, merge, settle, or transfer.
    function test_RevertWhen_SellPartialFillOrExtraDelta() public {
        uint256 y = SELL_Y;
        bool ptIsCurrency0 = address(pt) < address(pol);

        // Partial fill: only y-1 PT produced.
        {
            int128 ptDelta = int128(int256(y - 1));
            int128 polDelta = -int128(int256(SELL_Q));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFundYT(y);
            _approveAccountYT(y);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.FlashDeltaMismatch.selector, ptDelta, polDelta)
            );
            router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }

        // Positive POL delta: structurally invalid input direction.
        {
            int128 ptDelta = int128(int256(y));
            int128 polDelta = int128(int256(1));
            if (ptIsCurrency0) manager.scriptSwapDelta(ptDelta, polDelta);
            else manager.scriptSwapDelta(polDelta, ptDelta);
            _startSessionAndFundYT(y);
            _approveAccountYT(y);
            vm.prank(account);
            vm.expectRevert(
                abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.FlashDeltaMismatch.selector, ptDelta, polDelta)
            );
            router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        }
    }

    /// @dev The splitter returns one-less POL than the merged PT+YT; the result guard fires after the merge.
    ///
    ///      Like its buy-side twin, this guard is unreachable for the canonical POLSplitterUpgradeable: real `merge` returns the
    ///      exact requested POL amount, and `_validateAndResolve` locks the immutable `splitter` to the canonical address
    ///      on every entry. The mock deviates from 1:1 here to simulate a post-upgrade buggy/malicious canonical Splitter
    ///      or a non-canonical malformed one. It is a defense-in-depth / upgrade-safety check, NOT proof that merge
    ///      accounting is safe against the real Splitter at runtime.
    function test_RevertWhen_SellMergeResultMismatch() public {
        uint256 y = SELL_Y;
        uint256 q = SELL_Q;
        splitter.scriptMerge(VERSE_ID, y - 1, 0);
        _scriptSellDelta(y, q);
        _startSessionAndFundYT(y);
        _approveAccountYT(y);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MergeResultMismatch.selector, y - 1, y));
        router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The router's YT pull fails inside `safeTransferFrom`; the entire unlock and the PT take roll back atomically.
    function test_RevertWhen_SellYTAllowanceFails() public {
        uint256 y = SELL_Y;
        uint256 q = SELL_Q;
        _scriptSellDelta(y, q);
        _startSessionAndFundYT(y);
        _approveAccountYT(y);
        yt.setTransferFromOk(false); // router pull of y YT now reverts inside safeTransferFrom
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, address(yt)));
        router.swapExactYTForPOL(VERSE_ID, y, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
        // Atomic rollback: the take-minted PT and the merge leg never persist.
        assertEq(pt.balanceOf(address(router)), 0);
        assertEq(splitter.mergeCount(), 0);
    }

    /// @dev Entry guards: zero exact YT, exact YT above the int128 safe range, and an unknown verse (zero assets) all
    ///      revert before any fund action.
    function test_RevertWhen_SellInvalidVerseOrBoundary() public {
        hook.setActivePrincipal(account);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.AmountOutOfRange.selector, uint256(0)));
        router.swapExactYTForPOL(VERSE_ID, 0, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.AmountOutOfRange.selector, uint256(uint128(type(int128).max)) + 1
            )
        );
        router.swapExactYTForPOL(
            VERSE_ID, uint256(uint128(type(int128).max)) + 1, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer
        );

        vm.prank(account);
        vm.expectPartialRevert(IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector);
        router.swapExactYTForPOL(VERSE_ID + 999, 1 ether, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev The canonical verse-asset guard rejects any duplicate pair among (pt, yt, pol). Each of the three duplicate
    ///      clauses (`pt == yt`, `pt == pol`, `yt == pol`) is exercised with an exact revert assertion, so dropping any
    ///      one clause would let its case slip past the guard and break this test. `InvalidCanonicalVerseAssets` fires
    ///      inside `_validateAndResolve` before any YT is pulled on the sell path, so the fund-move values are unused.
    function test_RevertWhen_SellDuplicateCanonicalVerseAssets() public {
        hook.setActivePrincipal(account);

        // pt == yt.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(pt), address(pol));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(pt),
                address(pol)
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // pt == pol.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pt));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                address(pt)
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // yt == pol.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(yt));
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                address(yt)
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Restore the setUp binding so the mutated VERSE_ID assets do not leak into sibling tests in this contract.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));
    }

    /// @dev Sell-side mirror of `test_RevertWhen_BuyCanonicalVerseAssetHasNoCode`: an EOA `pol` reverts with the named
    ///      error instead of an opaque ABI-decode revert from the `_snapshotBalances` STATICCALL. Fires inside
    ///      `_validateAndResolve` before any YT is pulled on the sell path, so the fund-move values are unused.
    function test_RevertWhen_SellCanonicalVerseAssetHasNoCode() public {
        hook.setActivePrincipal(account);

        address eoaPol = makeAddr("eoaPol");
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), eoaPol);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.InvalidCanonicalVerseAssets.selector,
                VERSE_ID,
                address(pt),
                address(yt),
                eoaPol
            )
        );
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Restore the setUp binding so the mutated VERSE_ID assets do not leak into sibling tests in this contract.
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));
    }

    /// @dev Pre-existing router dust across all three tokens is untouched by a successful sell.
    function test_SellPreservesDust() public {
        pt.mint(address(router), 1);
        yt.mint(address(router), 1);
        pol.mint(address(router), 1);
        _doSuccessfulSell(SELL_Y, SELL_Q, referrer);
        assertEq(pt.balanceOf(address(router)), 1);
        assertEq(yt.balanceOf(address(router)), 1);
        assertEq(pol.balanceOf(address(router)), 1);
    }

    /// @dev A non-zero referrer is forwarded as packed bytes; a zero referrer is forwarded as empty hookData.
    function test_SellUsesPackedReferrer() public {
        _doSuccessfulSell(SELL_Y, SELL_Q, referrer);
        assertEq(manager.lastHookData(), abi.encodePacked(referrer));

        _doSuccessfulSell(SELL_Y, SELL_Q, address(0));
        assertEq(manager.lastHookData(), bytes(""));
    }

    /// @dev A successful sell performs exactly one underlying PT/POL swap.
    function test_SellUsesExactlyOneSwap() public {
        uint256 before = manager.swapCount();
        _doSuccessfulSell(SELL_Y, SELL_Q, referrer);
        assertEq(manager.swapCount() - before, 1);
    }

    /// @dev A past `deadline` reverts `ExpiredPastDeadline` at `_validateAndResolve`, the first precondition (before any
    ///      YT pull). Covers the expired-deadline requirement on the sell entry. Follows the sibling
    ///      `MemeverseSwapRouter` pattern: pass `block.timestamp - 1` so the deadline is strictly in the past without
    ///      any `vm.warp`.
    function test_RevertWhen_SellDeadlineExpired() public {
        // Pre-fund and approve so the post-revert balance/allowance assertion proves nothing was moved before the revert.
        yt.mint(account, EXACT_YT);
        vm.prank(account);
        yt.approve(address(router), EXACT_YT);

        vm.prank(account);
        vm.expectRevert(IMemeverseYTFlashSwapRouter.ExpiredPastDeadline.selector);
        router.swapExactYTForPOL(VERSE_ID, EXACT_YT, 0, PRICE_LIMIT, recipient, block.timestamp - 1, referrer);
        // Nothing was pulled: payer YT balance and allowance are untouched.
        assertEq(yt.balanceOf(account), EXACT_YT);
        assertEq(yt.allowance(account, address(router)), EXACT_YT);
    }

    // =====================================================================================
    // Task 7: reentrancy, postcondition, atomic-rollback, no-refund, one-swap-one-leg
    // =====================================================================================

    /// @dev A token whose transfer callback re-enters a router public entry is blocked by `nonReentrant`. The reentrant
    ///      call reverts with `ReentrancyGuardReentrantCall`; the mock token bubbles that revert via assembly, and
    ///      `OutrunSafeERC20` propagates the returndata, so the outer flash reverts atomically. Buy arms POL (cost pull
    ///      path), sell arms YT (payer pull path).
    function test_RevertWhen_ReentrantTokenCallsPublicEntry() public {
        // Buy path: POL cost `transferFrom` re-enters the buy entry.
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        pol.setReenter(
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer)
            )
        );
        vm.prank(account);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        pol.clearReenter();

        // Sell path: YT payer `transferFrom` re-enters the sell entry.
        _scriptSellDelta(SELL_Y, SELL_Q);
        _startSessionAndFundYT(SELL_Y);
        _approveAccountYT(SELL_Y);
        yt.setReenter(
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer)
            )
        );
        vm.prank(account);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.swapExactYTForPOL(
            VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer
        );
        yt.clearReenter();
    }

    /// @dev A malicious Splitter that calls back into a router public entry during `split`/`merge` is blocked by
    ///      `nonReentrant`. The reentrant call reverts `ReentrancyGuardReentrantCall`; the mock Splitter bubbles that
    ///      revert via assembly, so the outer flash reverts atomically with no asset movement. Covers the Splitter
    ///      reentrancy vector (the sibling token-vector test sits above). Buy arms the
    ///      `split` callback, sell arms the `merge` callback.
    function test_RevertWhen_ReentrantSplitterCallsPublicEntry() public {
        // Buy path: Splitter.split re-enters the buy entry. Arm the hook, then snapshot baselines so the post-revert
        // assertions prove the whole unlock rolled back (no take-minted POL, payer balance/allowance restored).
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        splitter.setReenter(
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer)
            )
        );
        uint256 routerPolBefore = pol.balanceOf(address(router));
        uint256 accountPolBefore = pol.balanceOf(account);
        uint256 accountAllowanceBefore = pol.allowance(account, address(router));
        vm.prank(account);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        // Atomic rollback: no take-minted POL persists on the router, payer balance/allowance restored, split never committed.
        assertEq(pol.balanceOf(address(router)), routerPolBefore);
        assertEq(pol.balanceOf(account), accountPolBefore);
        assertEq(pol.allowance(account, address(router)), accountAllowanceBefore);
        assertEq(yt.balanceOf(recipient), 0);
        splitter.clearReenter();

        // Sell path: Splitter.merge re-enters the sell entry.
        _scriptSellDelta(SELL_Y, SELL_Q);
        _startSessionAndFundYT(SELL_Y);
        _approveAccountYT(SELL_Y);
        splitter.setReenter(
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer)
            )
        );
        uint256 routerPtBefore = pt.balanceOf(address(router));
        uint256 accountYtBefore = yt.balanceOf(account);
        uint256 accountYtAllowanceBefore = yt.allowance(account, address(router));
        vm.prank(account);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.swapExactYTForPOL(
            VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer
        );
        // Atomic rollback: take-minted PT and merge leg never persist, payer YT balance/allowance restored.
        assertEq(pt.balanceOf(address(router)), routerPtBefore);
        assertEq(yt.balanceOf(account), accountYtBefore);
        assertEq(yt.allowance(account, address(router)), accountYtAllowanceBefore);
        assertEq(pol.balanceOf(recipient), 0);
        splitter.clearReenter();
    }

    /// @dev A non-zero `takeBonus` leaves a residual in each path's take token after either direction even though the
    ///      per-currency delta closes; the shared post-entry baseline guard catches it and reverts
    ///      `RouterBalanceMismatch`.
    function test_RevertWhen_BaselineMismatch() public {
        manager.setTakeBonus(1);
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        vm.recordLogs();
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.RouterBalanceMismatch.selector, address(pol), uint256(0), uint256(1)
            )
        );
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        _assertNoRouterFlashSwapEvent(vm.getRecordedLogs());

        _scriptSellDelta(SELL_Y, SELL_Q);
        _startSessionAndFundYT(SELL_Y);
        _approveAccountYT(SELL_Y);
        // Sell `take` mints the bonus PT, while merge burns only `SELL_Y` PT.
        vm.recordLogs();
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.RouterBalanceMismatch.selector, address(pt), uint256(0), uint256(1)
            )
        );
        router.swapExactYTForPOL(
            VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer
        );
        _assertNoRouterFlashSwapEvent(vm.getRecordedLogs());
    }

    /// @dev The PT/POL baseline branches are exercised by `test_RevertWhen_BaselineMismatch` via `takeBonus`, but that
    ///      mechanism can only mint the take-token (POL buy / PT sell), so the YT baseline branch (src `_assertBalancesRestored`
    ///      YT check) is otherwise never reached. This test pins it on both directions using a malformed Splitter:
    ///      buy-side `split` mints surplus YT while still returning `y` (bypasses `SplitResultMismatch`), and sell-side
    ///      `merge` under-burns YT while still returning `y` POL (bypasses `MergeResultMismatch`). Both leave a router-side
    ///      YT residual that only the baseline guard catches. Canonical Splitter is strict 1:1, so this is defense-in-depth /
    ///      upgrade-safety coverage (INV-24), mirroring `SplitResultMismatch`/`MergeResultMismatch` coverage.
    function test_RevertWhen_YTBalanceMismatch() public {
        uint256 ytResidual = 1;

        // Buy: malformed `split` mints `y + 1` YT while returning `y`, leaving 1 YT on the router after the
        // `safeTransfer(recipient, y)` leg.
        splitter.scriptSplit(VERSE_ID, BUY_Y, BUY_Y, 0, ytResidual);
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.RouterBalanceMismatch.selector, address(yt), uint256(0), ytResidual
            )
        );
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Sell: malformed `merge` burns only `y - 1` YT while returning `y` POL, leaving 1 YT on the router after merge.
        splitter.scriptMerge(VERSE_ID, SELL_Y, ytResidual);
        _scriptSellDelta(SELL_Y, SELL_Q);
        _startSessionAndFundYT(SELL_Y);
        _approveAccountYT(SELL_Y);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.RouterBalanceMismatch.selector, address(yt), uint256(0), ytResidual
            )
        );
        router.swapExactYTForPOL(
            VERSE_ID, SELL_Y, SELL_Y - SELL_Q, SELL_PRICE_LIMIT, recipient, block.timestamp, referrer
        );
    }

    /// @dev When the POL `approve` call returns false, `_approveExactly` reverts `ApprovalFailed` before the split runs.
    ///      The guard fires after `take` and the cost pull, proving the router never proceeds on a failed approval.
    function test_RevertWhen_ApprovalReturnsFalse() public {
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        pol.setApproveOk(false);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.ApprovalFailed.selector, address(pol), address(splitter), BUY_Y
            )
        );
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
    }

    /// @dev A failure after `take` (a split that leaves a POL allowance residual) rolls back the whole unlock: the
    ///      take-minted POL never persists on the router, and the payer's POL and router allowance are restored.
    function test_AtomicRollbackAfterTake() public {
        splitter.scriptSplit(VERSE_ID, BUY_Y, BUY_Y, 1 ether, 0); // residual -> SplitterAllowanceResidual after take
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        uint256 routerPolBefore = pol.balanceOf(address(router));
        uint256 accountPolBefore = pol.balanceOf(account);
        uint256 accountAllowanceBefore = pol.allowance(account, address(router));
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.SplitterAllowanceResidual.selector, 1 ether));
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        // Atomic rollback: the take-minted POL never persists on the router, payer balance/allowance are restored.
        // `splitCount` is a mock-internal storage counter that EVM rollback restores regardless of whether `split`
        // ran inside the frame, so asserting it here would not distinguish "split never committed" from "split
        // committed then rolled back" — it is not asserted. The external balance/allowance checks below carry the
        // real rollback evidence.
        assertEq(pol.balanceOf(address(router)), routerPolBefore);
        assertEq(pol.balanceOf(account), accountPolBefore);
        assertEq(pol.allowance(account, address(router)), accountAllowanceBefore);
    }

    /// @dev The router's buy-side POL pull fails inside `safeTransferFrom` right after `take`; the entire unlock rolls
    ///      back so the take-minted POL never persists and the payer balance/allowance are restored. Mirrors
    ///      `test_RevertWhen_SellYTAllowanceFails` on the symmetric buy path.
    function test_RevertWhen_BuyPOLTransferFromFails() public {
        _scriptBuyDelta(BUY_Y, BUY_R);
        _startSessionAndFund(BUY_Y);
        _approveAccountPOL(BUY_Y - BUY_R);
        pol.setTransferFromOk(false); // router pull of `cost` POL now reverts inside safeTransferFrom
        uint256 routerPolBefore = pol.balanceOf(address(router));
        uint256 accountPolBefore = pol.balanceOf(account);
        uint256 accountAllowanceBefore = pol.allowance(account, address(router));
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, address(pol)));
        router.swapPOLForExactYT(VERSE_ID, BUY_Y, BUY_Y - BUY_R, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);
        // Atomic rollback: no take-minted POL on the router, payer balance/allowance restored.
        // The `revert` itself is already asserted by the `expectRevert` above; the balance/allowance assertions below
        // confirm the rollback restored external state, not that any delta-closing logic ran (EVM rollback restores
        // everything, including mock-internal delta bookkeeping, so delta state is not informative).
        assertEq(pol.balanceOf(address(router)), routerPolBefore);
        assertEq(pol.balanceOf(account), accountPolBefore);
        assertEq(pol.allowance(account, address(router)), accountAllowanceBefore);
    }

    /// @dev The buy pulls only the actual cost, never `maxPOLIn`. The payer funds and approves exactly `cost` while
    ///      `maxPOLIn` is unbounded; any maxPOLIn pre-pull would exceed the tight balance/allowance and revert. Success
    ///      plus a balance drop of exactly `cost` and a single payer `transferFrom` prove there is no refund loop and no
    ///      `approve(spender, 0)` reset branch on the hot path.
    function test_NoRefundLoop() public {
        uint256 y = BUY_Y;
        uint256 r = BUY_R;
        uint256 cost = y - r;
        _scriptBuyDelta(y, r);
        hook.setActivePrincipal(account);
        pol.mint(account, cost); // fund exactly cost, not maxPOLIn
        vm.prank(account);
        pol.approve(address(router), cost); // approve exactly cost
        uint256 accountPolBefore = pol.balanceOf(account);
        uint256 allowanceBefore = pol.allowance(account, address(router));

        vm.prank(account);
        router.swapPOLForExactYT(VERSE_ID, y, type(uint256).max, BUY_PRICE_LIMIT, recipient, block.timestamp, referrer);

        // Only `cost` left the payer, the tight allowance was fully consumed, and the payer was pulled exactly once.
        assertEq(accountPolBefore - pol.balanceOf(account), cost);
        assertEq(allowanceBefore - pol.allowance(account, address(router)), cost);
        assertEq(pol.transferFromAsFrom(account), 1);
        _assertRouterBaseline();
    }

    /// @dev A successful buy performs exactly one underlying swap and one split (no merge); a successful sell performs
    ///      exactly one underlying swap and one merge (no further split). Swap/split/merge counters are delta-checked
    ///      around each call. A gasleft() ceiling is also asserted around each call: a path with a Router-internal
    ///      quoting loop would far exceed it (no quoting loop on the success path). The ceiling leaves headroom over
    ///      the single swap+split/merge cost without admitting any multi-round quoting loop.
    function test_OneSwapAndOneSplitOrMerge() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        // Conservative success-path ceiling: one poolManager.swap plus one split/merge. Sibling plain swaps land near
        // 590k (permit2 path ~1M); this covers the extra split/merge step while staying well below any quoting loop.
        uint256 gasCeiling = 1_500_000;

        uint256 swapBeforeBuy = manager.swapCount();
        uint256 splitBeforeBuy = splitter.splitCount();
        uint256 mergeBeforeBuy = splitter.mergeCount();
        uint256 gasBeforeBuy = gasleft();
        _doSuccessfulBuy(BUY_Y, BUY_R, referrer);
        uint256 gasUsedBuy = gasBeforeBuy - gasleft();
        assertEq(manager.swapCount() - swapBeforeBuy, 1);
        assertEq(splitter.splitCount() - splitBeforeBuy, 1);
        assertEq(splitter.mergeCount() - mergeBeforeBuy, 0);
        assertLt(gasUsedBuy, gasCeiling, "buy path gas ceiling");

        uint256 swapBeforeSell = manager.swapCount();
        uint256 splitBeforeSell = splitter.splitCount();
        uint256 mergeBeforeSell = splitter.mergeCount();
        uint256 gasBeforeSell = gasleft();
        _doSuccessfulSell(SELL_Y, SELL_Q, referrer);
        uint256 gasUsedSell = gasBeforeSell - gasleft();
        assertEq(manager.swapCount() - swapBeforeSell, 1);
        assertEq(splitter.splitCount() - splitBeforeSell, 0);
        assertEq(splitter.mergeCount() - mergeBeforeSell, 1);
        assertLt(gasUsedSell, gasCeiling, "sell path gas ceiling");
    }
}
