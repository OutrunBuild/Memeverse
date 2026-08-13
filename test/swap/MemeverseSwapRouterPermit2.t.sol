// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/ISignatureTransfer.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {OrdinarySwapMath} from "../../src/swap/libraries/OrdinarySwapMath.sol";

import {
    MockPoolManagerForPermit2RouterTest,
    MockPermit2ForRouterTest,
    SignatureVerifyingPermit2ForRouterTest
} from "../mocks/swap/Permit2Mocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @dev Test boundary:
/// - These cases lock Permit2/router handling under the local manager and Permit2 mocks.
/// - They do not establish real market execution, partial-fill economics, rollback guarantees,
///   or fee-side correctness beyond this deterministic harness.
contract MemeverseSwapRouterPermit2Test is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant ALICE_PK = 0xA11CE;
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_SINGLE_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string internal constant PERMIT_BATCH_WITNESS_TYPEHASH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)"
    );
    bytes32 internal constant ADD_LIQUIDITY_WITNESS_TYPEHASH = keccak256(
        "MemeverseAddLiquidityWitness(address currency0,address currency1,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)"
    );
    bytes32 internal constant REMOVE_LIQUIDITY_WITNESS_TYPEHASH = keccak256(
        "MemeverseRemoveLiquidityWitness(address currency0,address currency1,uint128 liquidity,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)"
    );
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "MemeverseSwapWitness witness)MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)TokenPermissions(address token,uint256 amount)";
    string internal constant ADD_LIQUIDITY_WITNESS_TYPE_STRING =
        "MemeverseAddLiquidityWitness witness)MemeverseAddLiquidityWitness(address currency0,address currency1,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    string internal constant REMOVE_LIQUIDITY_WITNESS_TYPE_STRING =
        "MemeverseRemoveLiquidityWitness witness)MemeverseRemoveLiquidityWitness(address currency0,address currency1,uint128 liquidity,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    bytes4 internal constant PUBLIC_SWAP_DISABLED_SELECTOR = bytes4(keccak256("PublicSwapDisabled()"));

    /// @notice Moves the block timestamp beyond the launch window threshold.
    /// @dev Ensures the Permit2 tests can exercise post-launch paths without real wait.
    function _matureLaunchWindow() internal {
        vm.warp(block.timestamp + 900);
    }

    function _validExecutionPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _dynamicPoolKeyForHook(address hookAddress, Currency currency0, Currency currency1)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(hookAddress)
        });
    }

    MockPoolManagerForPermit2RouterTest internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseUniswapHookLens internal lens;
    MockPermit2ForRouterTest internal mockPermit2;
    SignatureVerifyingPermit2ForRouterTest internal realPermit2;
    MemeverseSwapRouter internal router;
    MemeverseSwapRouter internal realPermit2Router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    address internal alice;
    PoolKey internal key;
    PoolId internal poolId;

    function _setPublicSwapResumeTime(address targetHook, address tokenA, address tokenB, uint40 resumeTime)
        internal
        returns (bool ok, bytes memory data)
    {
        return targetHook.call(
            abi.encodeWithSignature("setPublicSwapResumeTime(address,address,uint40)", tokenA, tokenB, resumeTime)
        );
    }

    function _deployHookProxyForManager(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHookUpgradeable deployed)
    {
        // Deploy the real MemeverseUniswapHookUpgradeable behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHookUpgradeable(hookProxy);
    }

    /// @notice Deploys the permit2 test harness, mocks, and seeded pool state.
    /// @dev Initializes both mock and signature-verifying Permit2 flows against the same pool setup.
    function setUp() public {
        manager = new MockPoolManagerForPermit2RouterTest();
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_PK);
        hook = _deployHookProxyForManager(IPoolManager(address(manager)), address(this), treasury);
        lens = new MemeverseUniswapHookLens(IPoolManager(address(manager)));
        mockPermit2 = new MockPermit2ForRouterTest();
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), lens, IPermit2(address(mockPermit2))
        );
        realPermit2 = new SignatureVerifyingPermit2ForRouterTest();
        realPermit2Router = new MemeverseSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), lens, IPermit2(address(realPermit2))
        );

        MockERC20 tokenA = new MockERC20("Token0", "TK0", 18);
        MockERC20 tokenB = new MockERC20("Token1", "TK1", 18);
        // `token0` and `token1` mean Uniswap currency order here, not deployment order.
        // Proxy deployment changes can move token addresses, so sort once before building the PoolKey.
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);

        vm.prank(alice);
        token0.approve(address(mockPermit2), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(mockPermit2), type(uint256).max);
        vm.prank(alice);
        token0.approve(address(realPermit2), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(realPermit2), type(uint256).max);

        key = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        poolId = key.toId();
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        seedActiveLiquiditySharesForTest(address(hook), poolId, address(this), 1e18);
    }

    /// @notice Verifies single-permit swaps pull input and execute successfully.
    /// @dev Confirms the router requests the expected Permit2 transfer and completes the swap path.
    function testSwapWithPermit2_TransfersInputAndExecutes() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        // The session principal is this test contract; it is independent of the pranked swap caller.
        hook.beginAccountSession();
        vm.prank(alice);
        BalanceDelta delta = router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
        hook.endAccountSession();

        assertEq(address(router.permit2()), address(mockPermit2), "permit2");
        assertEq(mockPermit2.lastOwner(), alice, "owner");
        assertEq(mockPermit2.lastRecipient(), address(router), "recipient");
        assertEq(mockPermit2.lastToken(), address(token0), "token");
        assertEq(mockPermit2.lastRequestedAmount(), 100 ether, "amount");
        assertEq(manager.lastUnlockPayer(), address(router), "router should prefund permit2 swaps");
        assertLt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
        assertLt(token0.balanceOf(alice), balance0Before, "token0 spent");
        assertGt(token1.balanceOf(alice), balance1Before, "token1 received");
    }

    /// @notice Verifies the Permit2 swap path stays below the current gas ceiling (1_000_000).
    /// @dev Covers the Permit2 witness and prefund flow through the hook -> SwapFacet -> DynamicFeeFacet
    ///      delegatecall path. Observed usage is about 980103 gas, leaving about 20000 gas of headroom.
    function testSwapWithPermit2_GasStaysBelowCeiling() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        hook.beginAccountSession();
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        BalanceDelta delta = router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
        hook.endAccountSession();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
        assertLt(gasUsed, 1_000_000, "swapWithPermit2 gas ceiling");
    }

    /// @notice Verifies Permit2 swaps also respect the post-unlock protection window.
    /// @dev Uses hook-local pool protection while still funding the input through Permit2 first.
    function testSwapWithPermit2_RevertsDuringPostUnlockProtectionWindow() external {
        MockPoolManagerForPermit2RouterTest guardedManager = new MockPoolManagerForPermit2RouterTest();
        MemeverseUniswapHookUpgradeable guardedHook =
            _deployHookProxyForManager(IPoolManager(address(guardedManager)), address(this), treasury);
        MemeverseSwapRouter guardedRouter = new MemeverseSwapRouter(
            IPoolManager(address(guardedManager)),
            IMemeverseUniswapHook(address(guardedHook)),
            new MemeverseUniswapHookLens(IPoolManager(address(guardedManager))),
            IPermit2(address(mockPermit2))
        );
        PoolKey memory guardedKey = _dynamicPoolKeyForHook(
            address(guardedHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );

        guardedHook.setPoolInitializer(address(this));
        guardedHook.authorizePoolInitialization(guardedKey, SQRT_PRICE_1_1);
        guardedManager.initialize(guardedKey, SQRT_PRICE_1_1);
        guardedHook.setProtocolFeeCurrency(guardedKey.currency0, true);
        (bool setOk, bytes memory setData) = _setPublicSwapResumeTime(
            address(guardedHook), address(token0), address(token1), uint40(block.timestamp + 1 hours)
        );
        assertTrue(setOk, string(setData));
        token0.mint(address(guardedManager), 1_000_000 ether);
        token1.mint(address(guardedManager), 1_000_000 ether);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = IMemeverseSwapRouter.Permit2SingleParams({
            permit: ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: 100 ether}),
                nonce: 77,
                deadline: block.timestamp
            }),
            transferDetails: ISignatureTransfer.SignatureTransferDetails({
                to: address(guardedRouter), requestedAmount: 100 ether
            }),
            signature: hex"1234"
        });
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        // Open a session on the guarded hook so the swap reaches the public-swap-blocked guard, not the session gate.
        guardedHook.beginAccountSession();
        vm.prank(alice);
        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        guardedRouter.swapWithPermit2(
            singlePermit,
            guardedKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            alice,
            block.timestamp,
            0,
            100 ether,
            ""
        );
        guardedHook.endAccountSession();
    }

    /// @notice Covers the Hook entrypoint's upfront price-limit boundary for Permit2 execution swaps.
    /// @dev Locks that a raw zero limit is rejected before the PoolManager execution path.
    function testSwapWithPermit2_RevertsWhenExecutionPriceLimitIsZero() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);

        // Open a session so the swap reaches the price-limit guard, which runs after the session check.
        hook.beginAccountSession();
        vm.prank(alice);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            alice,
            block.timestamp,
            0,
            100 ether,
            ""
        );
        hook.endAccountSession();
    }

    /// @notice Covers the Permit2 exact-output prefund-and-refund branch under the local router harness.
    /// @dev This locks local budget plumbing parity with the regular router path rather than proving real execution semantics.
    function testSwapWithPermit2_ExactOutputRefundsUnusedPrefundedInput() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 amountInMaximum = 500 ether;
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), amountInMaximum);

        hook.beginAccountSession();
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            0,
            amountInMaximum,
            ""
        );
        hook.endAccountSession();

        assertEq(mockPermit2.lastRequestedAmount(), amountInMaximum, "prefunded amountInMaximum");
        assertEq(manager.lastUnlockPayer(), address(router), "router should pay exact-output input");
        assertEq(balance0Before - token0.balanceOf(alice), 400 ether, "net input after refund");
        assertEq(token0.balanceOf(address(router)), 0, "router should not retain refunded input");
    }

    /// @notice Covers the local fail-closed Permit2 branch for exact-input underfills on output-side fee pools.
    /// @dev Uses the mock harness to witness payer, treasury, and LP-fee rollback when the hook rejects the swap.
    function testSwapWithPermit2_RevertsWhenExactInputPartialFillsOnOutputFeePool() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        IMemeverseSwapRouter.Permit2SingleParams memory seedPermit = _singlePermit(address(token0), 10 ether);
        // One session covers the seed swap and the rollback swap; the revert rolls back its own context.
        hook.beginAccountSession();
        vm.prank(alice);
        router.swapWithPermit2(
            seedPermit,
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);
        uint256 payer0Before = token0.balanceOf(alice);
        uint256 payer1Before = token1.balanceOf(alice);
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);
        (, uint256 fee0PerShareBefore, uint256 fee1PerShareBefore) = hook.poolInfo(poolId);
        (
            uint256 wv0Before,,
            uint256 ewVWAPBefore,
            uint160 volAnchorBefore,,
            uint24 volDevBefore,,
            uint24 shortImpactBefore,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            0,
            100 ether,
            ""
        );

        (, uint256 fee0PerShareAfter, uint256 fee1PerShareAfter) = hook.poolInfo(poolId);
        assertEq(token0.balanceOf(alice), payer0Before, "payer token0 unchanged");
        assertEq(token1.balanceOf(alice), payer1Before, "payer token1 unchanged");
        assertEq(token0.balanceOf(treasury), treasury0Before, "treasury token0 unchanged");
        assertEq(token1.balanceOf(treasury), treasury1Before, "treasury token1 unchanged");
        assertEq(fee0PerShareAfter, fee0PerShareBefore, "fee0 per share unchanged");
        assertEq(fee1PerShareAfter, fee1PerShareBefore, "fee1 per share unchanged");

        (
            uint256 wv0After,,
            uint256 ewVWAPAfter,
            uint160 volAnchorAfter,,
            uint24 volDevAfter,,
            uint24 shortImpactAfter,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
        assertEq(wv0After, wv0Before, "ewvwap weightedVolume0 unchanged");
        assertEq(ewVWAPAfter, ewVWAPBefore, "ewvwap unchanged");
        assertEq(volAnchorAfter, volAnchorBefore, "vol anchor unchanged");
        assertEq(volDevAfter, volDevBefore, "volatility unchanged");
        assertEq(shortImpactAfter, shortImpactBefore, "short impact unchanged");
        hook.endAccountSession();
    }

    /// @notice Covers the mirrored local fail-closed Permit2 branch for one-for-zero exact-input underfills on output-fee pools.
    /// @dev Uses the mock harness to witness rollback symmetry on the Permit2 path rather than proving full production partial-fill semantics.
    function testSwapWithPermit2_RevertsWhenOneForZeroExactInputPartialFillsOnOutputFeePool() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        IMemeverseSwapRouter.Permit2SingleParams memory seedPermit = _singlePermit(address(token1), 10 ether);
        hook.beginAccountSession();
        vm.prank(alice);
        router.swapWithPermit2(
            seedPermit,
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            alice,
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token1), 100 ether);
        uint256 payer0Before = token0.balanceOf(alice);
        uint256 payer1Before = token1.balanceOf(alice);
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);
        (, uint256 fee0PerShareBefore, uint256 fee1PerShareBefore) = hook.poolInfo(poolId);
        (
            uint256 wv0Before,,
            uint256 ewVWAPBefore,
            uint160 volAnchorBefore,,
            uint24 volDevBefore,,
            uint24 shortImpactBefore,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            alice,
            block.timestamp,
            0,
            100 ether,
            ""
        );

        (, uint256 fee0PerShareAfter, uint256 fee1PerShareAfter) = hook.poolInfo(poolId);
        assertEq(token0.balanceOf(alice), payer0Before, "payer token0 unchanged");
        assertEq(token1.balanceOf(alice), payer1Before, "payer token1 unchanged");
        assertEq(token0.balanceOf(treasury), treasury0Before, "treasury token0 unchanged");
        assertEq(token1.balanceOf(treasury), treasury1Before, "treasury token1 unchanged");
        assertEq(fee0PerShareAfter, fee0PerShareBefore, "fee0 per share unchanged");
        assertEq(fee1PerShareAfter, fee1PerShareBefore, "fee1 per share unchanged");

        (
            uint256 wv0After,,
            uint256 ewVWAPAfter,
            uint160 volAnchorAfter,,
            uint24 volDevAfter,,
            uint24 shortImpactAfter,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
        assertEq(wv0After, wv0Before, "ewvwap weightedVolume0 unchanged");
        assertEq(ewVWAPAfter, ewVWAPBefore, "ewvwap unchanged");
        assertEq(volAnchorAfter, volAnchorBefore, "vol anchor unchanged");
        assertEq(volDevAfter, volDevBefore, "volatility unchanged");
        assertEq(shortImpactAfter, shortImpactBefore, "short impact unchanged");
        hook.endAccountSession();
    }

    /// @notice Verifies the single Permit2 path surfaces Permit2's own amount check.
    function testSwapWithPermit2_RevertsWhenPermittedAmountBelowRequestedAmount() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint256 amountIn = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 99) / 100)
        });
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: 50 ether}),
            nonce: 21,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: address(realPermit2Router), requestedAmount: amountIn});
        bytes32 witness = _swapWitnessHash(key, params, alice, deadline, 40 ether, amountIn, bytes(""));
        bytes memory signature =
            _signSingleWitnessPermit(permit, address(realPermit2Router), witness, SWAP_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        vm.expectRevert(abi.encodeWithSelector(SignatureVerifyingPermit2ForRouterTest.InvalidAmount.selector, 50 ether));
        vm.prank(alice);
        realPermit2Router.swapWithPermit2(permitParams, key, params, alice, deadline, 40 ether, amountIn, "");
    }

    /// @notice Verifies the single Permit2 path rejects a permit whose token does not match the swap input.
    /// @dev Locks the named InvalidPermit2Token payload so the token-mismatch site has regression coverage.
    function testSwapWithPermit2_TokenMismatchReverts() external {
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(0xBEEF), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseSwapRouter.InvalidPermit2Token.selector, 0, address(token0), address(0xBEEF)
            )
        );
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 99) / 100)
            }),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
    }

    /// @notice Verifies the single Permit2 path rejects a transfer targeting a recipient other than the router.
    /// @dev Locks the named InvalidPermit2Target payload so the transfer-target site has regression coverage.
    function testSwapWithPermit2_TransferTargetMismatchReverts() external {
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);
        singlePermit.transferDetails.to = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseSwapRouter.InvalidPermit2Target.selector, 0));
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 99) / 100)
            }),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
    }

    /// @notice Verifies the single Permit2 path rejects a requested amount below the swap input budget.
    /// @dev Locks the named InvalidPermit2Amount payload (expected budget first, actual requested amount second).
    function testSwapWithPermit2_RequestedAmountMismatchReverts() external {
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token0), 100 ether);
        singlePermit.transferDetails.requestedAmount = 99 ether;

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseSwapRouter.InvalidPermit2Amount.selector, 0, 100 ether, 99 ether)
        );
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 99) / 100)
            }),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
    }

    /// @notice Verifies the batch Permit2 path surfaces Permit2's own amount check.
    function testAddLiquidityWithPermit2_RevertsWhenPermittedAmountBelowRequestedAmount() external {
        uint256 amount0Desired = 100 ether;
        uint256 amount1Desired = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        ISignatureTransfer.PermitBatchTransferFrom memory permit;
        permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
        permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(token0), amount: 50 ether});
        permit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(token1), amount: amount1Desired});
        permit.nonce = 22;
        permit.deadline = deadline;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails =
            new ISignatureTransfer.SignatureTransferDetails[](2);
        transferDetails[0] = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: amount0Desired
        });
        transferDetails[1] = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: amount1Desired
        });
        bytes32 witness = _addLiquidityWitnessHash(
            key.currency0, key.currency1, amount0Desired, amount1Desired, 90 ether, 90 ether, alice, deadline
        );
        bytes memory signature =
            _signBatchWitnessPermit(permit, address(realPermit2Router), witness, ADD_LIQUIDITY_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2BatchParams memory permitParams = IMemeverseSwapRouter.Permit2BatchParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        vm.expectRevert(abi.encodeWithSelector(SignatureVerifyingPermit2ForRouterTest.InvalidAmount.selector, 50 ether));
        vm.prank(alice);
        realPermit2Router.addLiquidityWithPermit2(
            permitParams,
            key.currency0,
            key.currency1,
            amount0Desired,
            amount1Desired,
            90 ether,
            90 ether,
            alice,
            deadline
        );
    }

    /// @notice Verifies Permit2-routed swaps use the router native-pair selector.
    /// @dev The router must reject native pairs before Permit2 token checks or signature transfer.
    function testSwapWithPermit2FailsClosed_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(0), 100 ether);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            nativeKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
    }

    /// @notice Verifies Permit2-routed ERC20-input swaps also reject native-output pairs at the router.
    /// @dev This proves the native-pair guard checks both currencies, not just the input currency.
    function testSwapWithPermit2FailsClosed_WhenPairUsesNativeOutputCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(address(token1), 100 ether);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        vm.prank(alice);
        router.swapWithPermit2(
            singlePermit,
            nativeKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            alice,
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );
    }

    /// @notice Verifies batch Permit2 funding supports two-ERC20 liquidity adds.
    /// @dev Exercises the two-token batch funding path used by liquidity adds.
    function testAddLiquidityWithPermit2_TwoErc20Inputs() external {
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit =
            _batchPermit(address(token0), 100 ether, address(token1), 100 ether);

        vm.prank(alice);
        uint128 liquidity = router.addLiquidityWithPermit2(
            batchPermit, key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );

        (address liquidityToken,,) = hook.poolInfo(poolId);
        assertGt(liquidity, 0, "liquidity");
        assertEq(mockPermit2.lastBatchOwner(), alice, "owner");
        assertEq(mockPermit2.lastBatchLength(), 2, "batch length");
        assertGt(MockERC20(liquidityToken).balanceOf(alice), 0, "lp balance");
    }

    /// @notice Verifies addLiquidityWithPermit2 fails closed for native pairs.
    function testAddLiquidityWithPermit2Reverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit = _batchPermitSingle(address(token1), 100 ether);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        vm.prank(alice);
        router.addLiquidityWithPermit2(
            batchPermit,
            nativeKey.currency0,
            nativeKey.currency1,
            100 ether,
            100 ether,
            90 ether,
            90 ether,
            alice,
            block.timestamp
        );
    }

    /// @notice Verifies Permit2 native pairs fail closed before token-mismatch logic.
    function testAddLiquidityWithPermit2Reverts_WhenPairUsesNativeCurrencyEvenWithWrongToken() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit = _batchPermitSingle(address(0xBEEF), 100 ether);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        vm.prank(alice);
        router.addLiquidityWithPermit2(
            batchPermit,
            nativeKey.currency0,
            nativeKey.currency1,
            100 ether,
            100 ether,
            90 ether,
            90 ether,
            alice,
            block.timestamp
        );
    }

    /// @notice Verifies single-permit liquidity removal burns LP and returns both assets.
    /// @dev Exercises the LP-token Permit2 flow used by liquidity removals.
    function testRemoveLiquidityWithPermit2() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(mockPermit2), type(uint256).max);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(liquidityToken, uint256(liquidity));
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        BalanceDelta delta = router.removeLiquidityWithPermit2(
            singlePermit, key.currency0, key.currency1, liquidity, 1, 1, alice, block.timestamp
        );

        assertGt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
        assertGt(token0.balanceOf(alice), balance0Before, "token0 returned");
        assertGt(token1.balanceOf(alice), balance1Before, "token1 returned");
        assertEq(MockERC20(liquidityToken).balanceOf(alice), 0, "lp burned");
    }

    /// @notice Verifies Permit2 removal rejects the zero-address recipient before forwarding assets.
    /// @dev Uses the shared removal path so the helper-level defensive check is enforced here too.
    function testRemoveLiquidityWithPermit2_RevertsWhenRecipientIsZeroAddress() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(mockPermit2), type(uint256).max);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(liquidityToken, uint256(liquidity));

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        router.removeLiquidityWithPermit2(
            singlePermit, key.currency0, key.currency1, liquidity, 1, 1, address(0), block.timestamp
        );
    }

    /// @notice Verifies LP-token Permit2 removals resolve pool metadata only once.
    /// @dev The Permit2 path already loads the LP token before entering the shared remove-liquidity flow.
    function testRemoveLiquidityWithPermit2_ReadsPoolInfoOnce() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(mockPermit2), type(uint256).max);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(liquidityToken, uint256(liquidity));

        vm.expectCall(address(hook), abi.encodeCall(IMemeverseUniswapHook.liquidityTokenOf, (poolId)), uint64(1));

        vm.prank(alice);
        BalanceDelta delta = router.removeLiquidityWithPermit2(
            singlePermit, key.currency0, key.currency1, liquidity, 1, 1, alice, block.timestamp
        );

        assertGt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
    }

    /// @notice Verifies Permit2 removals pull the canonical LP token even when currencies are reversed.
    /// @dev Witness inputs remain caller-order while the LP token lookup resolves the canonical pool id.
    function testRemoveLiquidityWithPermit2_UsesCanonicalLpTokenWhenCurrenciesAreReversed() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(mockPermit2), type(uint256).max);

        IMemeverseSwapRouter.Permit2SingleParams memory singlePermit = _singlePermit(liquidityToken, uint256(liquidity));
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        BalanceDelta delta = router.removeLiquidityWithPermit2(
            singlePermit, key.currency1, key.currency0, liquidity, 1, 1, alice, block.timestamp
        );

        assertEq(mockPermit2.lastToken(), liquidityToken, "canonical lp token");
        assertGt(int256(delta.amount0()), 0, "canonical delta0");
        assertGt(int256(delta.amount1()), 0, "canonical delta1");
        assertEq(token0.balanceOf(alice) - balance0Before, uint256(uint128(delta.amount0())), "token0 returned");
        assertEq(token1.balanceOf(alice) - balance1Before, uint256(uint128(delta.amount1())), "token1 returned");
        assertEq(MockERC20(liquidityToken).balanceOf(alice), 0, "lp burned");
    }

    /// @notice Verifies add-liquidity Permit2 calls reject mismatched token ordering.
    /// @dev The router must reject batch entries that do not match the expected pool currencies.
    function testAddLiquidityWithPermit2_TokenMismatchReverts() external {
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit =
            _batchPermit(address(token0), 100 ether, address(0xBEEF), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseSwapRouter.InvalidPermit2Token.selector, 1, address(token1), address(0xBEEF)
            )
        );
        vm.prank(alice);
        router.addLiquidityWithPermit2(
            batchPermit, key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
    }

    /// @notice Verifies the batch Permit2 path rejects a transfer targeting a recipient other than the router.
    /// @dev Locks the named InvalidPermit2Target payload for a batch entry (index 0) with regression coverage.
    function testAddLiquidityWithPermit2_TransferTargetMismatchReverts() external {
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit =
            _batchPermit(address(token0), 100 ether, address(token1), 100 ether);
        batchPermit.transferDetails[0].to = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseSwapRouter.InvalidPermit2Target.selector, 0));
        vm.prank(alice);
        router.addLiquidityWithPermit2(
            batchPermit, key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
    }

    /// @notice Verifies the batch Permit2 path rejects a requested amount below the desired budget.
    /// @dev Locks the named InvalidPermit2Amount payload for a batch entry (index 1), expected budget first.
    function testAddLiquidityWithPermit2_RequestedAmountMismatchReverts() external {
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit =
            _batchPermit(address(token0), 100 ether, address(token1), 100 ether);
        batchPermit.transferDetails[1].requestedAmount = 99 ether;

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseSwapRouter.InvalidPermit2Amount.selector, 1, 100 ether, 99 ether)
        );
        vm.prank(alice);
        router.addLiquidityWithPermit2(
            batchPermit, key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
    }

    /// @notice Verifies Permit2 liquidity adds use the shared prepared-budget executor without leaving router residue.
    /// @dev The runtime size check and residue assertions cover the prepared-budget execution path.
    function testAddLiquidityWithPermit2_UsesPreparedBudgetExecutorWithoutResidualBudget() external {
        uint256 amount0Desired = 100 ether;
        uint256 amount1Desired = 100 ether;
        IMemeverseSwapRouter.Permit2BatchParams memory batchPermit =
            _batchPermit(address(token0), amount0Desired, address(token1), amount1Desired);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.prank(alice);
        uint128 liquidity = router.addLiquidityWithPermit2(
            batchPermit,
            key.currency0,
            key.currency1,
            amount0Desired,
            amount1Desired,
            90 ether,
            90 ether,
            alice,
            block.timestamp
        );

        uint256 token0Spent = aliceToken0Before - token0.balanceOf(alice);
        uint256 token1Spent = aliceToken1Before - token1.balanceOf(alice);
        assertGt(liquidity, 0, "liquidity");
        assertGt(token0Spent, 0, "token0 spent");
        assertGt(token1Spent, 0, "token1 spent");
        assertLt(token0Spent, amount0Desired, "token0 refund");
        assertLt(token1Spent, amount1Desired, "token1 refund");
        assertEq(token0.balanceOf(address(router)), 0, "token0 residual");
        assertEq(token1.balanceOf(address(router)), 0, "token1 residual");
        assertLt(address(router).code.length, 28_000, "runtime should shrink after removing budgetsPrepared");
    }

    /// @notice Verifies canonical Permit2 witness signing works for swaps.
    /// @dev Uses the signature-verifying Permit2 mock to cover the canonical witness format.
    function testSwapWithPermit2_RealPermit2CanonicalWitnessExecutes() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint256 amountIn = 100 ether;
        uint256 amountOutMinimum = 40 ether;
        uint256 deadline = block.timestamp + 1 hours;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: uint160((uint256(SQRT_PRICE_1_1) * 99) / 100)
        });

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: amountIn}),
            nonce: 11,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: address(realPermit2Router), requestedAmount: amountIn});
        bytes32 witness = _swapWitnessHash(key, params, alice, deadline, amountOutMinimum, amountIn, bytes(""));
        bytes memory signature =
            _signSingleWitnessPermit(permit, address(realPermit2Router), witness, SWAP_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        hook.beginAccountSession();
        vm.prank(alice);
        BalanceDelta delta = realPermit2Router.swapWithPermit2(
            permitParams, key, params, alice, deadline, amountOutMinimum, amountIn, bytes("")
        );
        hook.endAccountSession();

        assertLt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
    }

    /// @notice Verifies canonical Permit2 batch witness signing works for liquidity adds.
    /// @dev Uses the signature-verifying Permit2 mock to cover canonical batch witnesses.
    function testAddLiquidityWithPermit2_RealPermit2CanonicalBatchWitnessExecutes() external {
        uint256 amount0Desired = 100 ether;
        uint256 amount1Desired = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        ISignatureTransfer.PermitBatchTransferFrom memory permit;
        permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
        permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: address(token0), amount: amount0Desired});
        permit.permitted[1] = ISignatureTransfer.TokenPermissions({token: address(token1), amount: amount1Desired});
        permit.nonce = 12;
        permit.deadline = deadline;

        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails =
            new ISignatureTransfer.SignatureTransferDetails[](2);
        transferDetails[0] = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: amount0Desired
        });
        transferDetails[1] = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: amount1Desired
        });

        bytes32 witness = _addLiquidityWitnessHash(
            key.currency0, key.currency1, amount0Desired, amount1Desired, 90 ether, 90 ether, alice, deadline
        );
        bytes memory signature =
            _signBatchWitnessPermit(permit, address(realPermit2Router), witness, ADD_LIQUIDITY_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2BatchParams memory permitParams = IMemeverseSwapRouter.Permit2BatchParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        vm.prank(alice);
        uint128 liquidity = realPermit2Router.addLiquidityWithPermit2(
            permitParams,
            key.currency0,
            key.currency1,
            amount0Desired,
            amount1Desired,
            90 ether,
            90 ether,
            alice,
            deadline
        );

        assertGt(liquidity, 0, "liquidity");
    }

    /// @notice Verifies canonical Permit2 witness signing works for liquidity removal.
    /// @dev Uses the signature-verifying Permit2 mock to cover LP-token witness removals.
    function testRemoveLiquidityWithPermit2_RealPermit2CanonicalWitnessExecutes() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(realPermit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: liquidityToken, amount: uint256(liquidity)}),
            nonce: 13,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory transferDetails = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: uint256(liquidity)
        });
        bytes32 witness = _removeLiquidityWitnessHash(key.currency0, key.currency1, liquidity, 1, 1, alice, deadline);
        bytes memory signature =
            _signSingleWitnessPermit(permit, address(realPermit2Router), witness, REMOVE_LIQUIDITY_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        vm.prank(alice);
        BalanceDelta delta = realPermit2Router.removeLiquidityWithPermit2(
            permitParams, key.currency0, key.currency1, liquidity, 1, 1, alice, deadline
        );

        assertGt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
    }

    /// @notice Verifies real Permit2 signatures accept reversed remove-liquidity witnesses in caller order.
    /// @dev The permit token remains the canonical LP token while witness currencies follow the external call order.
    function testRemoveLiquidityWithPermit2_RealPermit2ReversedWitnessExecutes() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(realPermit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: liquidityToken, amount: uint256(liquidity)}),
            nonce: 14,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory transferDetails = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: uint256(liquidity)
        });
        uint256 callerAmount0Min = 2;
        uint256 callerAmount1Min = 1;
        bytes32 witness = _removeLiquidityWitnessHash(
            key.currency1, key.currency0, liquidity, callerAmount0Min, callerAmount1Min, alice, deadline
        );
        bytes memory signature =
            _signSingleWitnessPermit(permit, address(realPermit2Router), witness, REMOVE_LIQUIDITY_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        BalanceDelta delta = realPermit2Router.removeLiquidityWithPermit2(
            permitParams, key.currency1, key.currency0, liquidity, callerAmount0Min, callerAmount1Min, alice, deadline
        );

        assertGt(int256(delta.amount0()), 0, "canonical delta0");
        assertGt(int256(delta.amount1()), 0, "canonical delta1");
        assertEq(token0.balanceOf(alice) - balance0Before, uint256(uint128(delta.amount0())), "token0 returned");
        assertEq(token1.balanceOf(alice) - balance1Before, uint256(uint128(delta.amount1())), "token1 returned");
        assertEq(MockERC20(liquidityToken).balanceOf(alice), 0, "lp burned");
    }

    /// @notice Verifies canonical remove-liquidity witnesses cannot authorize reversed-currency calls.
    /// @dev The signature-verifying Permit2 mock rejects the router-computed reversed witness as InvalidSigner.
    function testRemoveLiquidityWithPermit2_ReversedCurrenciesRejectCanonicalWitness() external {
        uint128 liquidity = _mintAliceLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(alice);
        MockERC20(liquidityToken).approve(address(realPermit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: liquidityToken, amount: uint256(liquidity)}),
            nonce: 15,
            deadline: deadline
        });
        ISignatureTransfer.SignatureTransferDetails memory transferDetails = ISignatureTransfer.SignatureTransferDetails({
            to: address(realPermit2Router), requestedAmount: uint256(liquidity)
        });
        uint256 callerAmount0Min = 2;
        uint256 callerAmount1Min = 1;
        bytes32 witness = _removeLiquidityWitnessHash(
            key.currency0, key.currency1, liquidity, callerAmount0Min, callerAmount1Min, alice, deadline
        );
        bytes memory signature =
            _signSingleWitnessPermit(permit, address(realPermit2Router), witness, REMOVE_LIQUIDITY_WITNESS_TYPE_STRING);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: permit, transferDetails: transferDetails, signature: signature
        });

        vm.prank(alice);
        vm.expectRevert(SignatureVerifyingPermit2ForRouterTest.InvalidSigner.selector);
        realPermit2Router.removeLiquidityWithPermit2(
            permitParams, key.currency1, key.currency0, liquidity, callerAmount0Min, callerAmount1Min, alice, deadline
        );
    }

    /// @notice Builds the normalized pool key wired to the test hook.
    /// @dev Reuses the same hook address and fee configuration for all Permit2 cases.
    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
    }

    /// @notice Mints liquidity on Alice's behalf through the router.
    /// @dev Covers the shared liquidity creation path used by Permit2 removal tests.
    function _mintAliceLiquidity() internal returns (uint128 liquidity) {
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(router), type(uint256).max);

        vm.prank(alice);
        liquidity = router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
    }

    /// @notice Fabricates a minimal single-token Permit2 payload for router tests.
    /// @dev Keeps the signature bytes constant because the router test harness skips verification.
    function _singlePermit(address token, uint256 amount)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2SingleParams memory permitParams)
    {
        permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
                nonce: 1,
                deadline: block.timestamp
            }),
            transferDetails: ISignatureTransfer.SignatureTransferDetails({
                to: address(router), requestedAmount: amount
            }),
            signature: hex"1234"
        });
    }

    /// @notice Fabricates a Permit2 batch payload containing two token legs.
    /// @dev Populates the minimal fields the router expects when bulk funding liquidity.
    function _batchPermit(address token0_, uint256 amount0_, address token1_, uint256 amount1_)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2BatchParams memory permitParams)
    {
        permitParams.permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitParams.permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: token0_, amount: amount0_});
        permitParams.permit.permitted[1] = ISignatureTransfer.TokenPermissions({token: token1_, amount: amount1_});
        permitParams.permit.nonce = 2;
        permitParams.permit.deadline = block.timestamp;
        permitParams.transferDetails = new ISignatureTransfer.SignatureTransferDetails[](2);
        permitParams.transferDetails[0] =
            ISignatureTransfer.SignatureTransferDetails({to: address(router), requestedAmount: amount0_});
        permitParams.transferDetails[1] =
            ISignatureTransfer.SignatureTransferDetails({to: address(router), requestedAmount: amount1_});
        permitParams.signature = hex"1234";
    }

    /// @notice Fabricates a Permit2 batch payload with a single token leg.
    /// @dev Mirrors the native-plus-ERC20 funding branch that uses only one batch entry.
    function _batchPermitSingle(address token, uint256 amount)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2BatchParams memory permitParams)
    {
        permitParams.permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitParams.permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: token, amount: amount});
        permitParams.permit.nonce = 3;
        permitParams.permit.deadline = block.timestamp;
        permitParams.transferDetails = new ISignatureTransfer.SignatureTransferDetails[](1);
        permitParams.transferDetails[0] =
            ISignatureTransfer.SignatureTransferDetails({to: address(router), requestedAmount: amount});
        permitParams.signature = hex"1234";
    }

    /// @notice Computes the canonical witness hash for swap operations.
    /// @dev Matches the Property-based witness format used by the real Permit2 router.
    function _swapWitnessHash(
        PoolKey memory poolKey,
        SwapParams memory params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes memory hookData
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SWAP_WITNESS_TYPEHASH,
                poolKey.toId(),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                recipient,
                deadline,
                amountOutMinimum,
                amountInMaximum,
                keccak256(hookData)
            )
        );
    }

    /// @notice Computes the witness hash used for liquidity adds.
    /// @dev Includes the ordered liquidity parameters that the router signs.
    function _addLiquidityWitnessHash(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ADD_LIQUIDITY_WITNESS_TYPEHASH,
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                amount0Desired,
                amount1Desired,
                amount0Min,
                amount1Min,
                to,
                deadline
            )
        );
    }

    /// @notice Computes the witness hash used for liquidity removals.
    /// @dev Covers the signed view that authorizes Permit2 LP withdrawals.
    function _removeLiquidityWitnessHash(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REMOVE_LIQUIDITY_WITNESS_TYPEHASH,
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                liquidity,
                amount0Min,
                amount1Min,
                to,
                deadline
            )
        );
    }

    /// @notice Signs a swap or LP permit witness with the mock Permit2 key.
    /// @dev Uses the canonical signer key to keep signature-dependent flows deterministic.
    function _signSingleWitnessPermit(
        ISignatureTransfer.PermitTransferFrom memory permit,
        address spender,
        bytes32 witness,
        string memory witnessTypeString
    ) internal view returns (bytes memory signature) {
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_SINGLE_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 permitHash =
            keccak256(abi.encode(typeHash, tokenPermissionsHash, spender, permit.nonce, permit.deadline, witness));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", realPermit2.DOMAIN_SEPARATOR(), permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    /// @notice Signs a batch witness permit using the canonical mock signer.
    /// @dev Reuses the same signer so multi-token witnesses remain consistent across tests.
    function _signBatchWitnessPermit(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        bytes32 witness,
        string memory witnessTypeString
    ) internal view returns (bytes memory signature) {
        bytes32[] memory tokenPermissionHashes = new bytes32[](permit.permitted.length);
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            tokenPermissionHashes[i] = keccak256(
                abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i].token, permit.permitted[i].amount)
            );
        }

        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_BATCH_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 permitHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(tokenPermissionHashes)),
                spender,
                permit.nonce,
                permit.deadline,
                witness
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", realPermit2.DOMAIN_SEPARATOR(), permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        return bytes.concat(r, s, bytes1(v));
    }
}
