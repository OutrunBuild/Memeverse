// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title Router-side preorder settlement unit tests
/// @notice Launcher-authorized `executePreorderSettlement` behavior under the router test harness:
///         launcher-only access control, fixed 1% settlement economics, single output-side protocol-fee
///         collection, immunity to the configurable launch-fee floor, and dynamic-fee state updates on
///         the settlement path.
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHookLens} from "../../src/swap/interfaces/IMemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract MemeversePreorderSettlementTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant ALICE_PK = 0xA11CE;

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseUniswapHookLens internal lens;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    address internal alice;
    PoolKey internal key;
    PoolId internal poolId;

    function _deployHookProxyForManager(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHookUpgradeable deployed)
    {
        // Deploy the real MemeverseUniswapHookUpgradeable behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHookUpgradeable(hookProxy);
    }

    /// @notice Deploys the mock manager, hook, router, and test tokens.
    /// @dev Seeds balances and approvals used throughout the settlement suite (mirrors the router suite
    ///      harness so settlement flows observe identical fixture state).
    function setUp() public {
        manager = new MockPoolManagerForRouterTest();
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_PK);
        hook = _deployHookProxyForManager(IPoolManager(address(manager)), address(this), treasury);
        lens = new MemeverseUniswapHookLens(IPoolManager(address(manager)));
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            IMemeverseUniswapHookLens(address(lens)),
            IPermit2(address(0xBEEF))
        );

        MockERC20 tokenA = new MockERC20("Token0", "TK0", 18);
        MockERC20 tokenB = new MockERC20("Token1", "TK1", 18);
        // `token0` and `token1` mean Uniswap currency order here, not deployment order.
        // Proxy deployment changes can move token addresses, so sort once before building the PoolKey.
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(router), type(uint256).max);

        key = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        poolId = key.toId();
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setPoolInitializer(address(router));
        seedActiveLiquiditySharesForTest(address(hook), poolId, address(this), 1e18);
    }

    /// @notice Configures which currency the hook should collect protocol fees in.
    /// @dev Helper invoked by tests before settlement so protocol-fee context is consistent.
    function _setProtocolFeeCurrency(Currency feeCurrency) internal {
        hook.setProtocolFeeCurrency(feeCurrency, true);
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

    /// @notice Builds a normalized pool key wired to the test hook.
    /// @dev Encapsulates the pair ordering and hook wiring shared by the settlement tests.
    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
    }

    /// @notice Verifies explicit preorder settlement can only be initiated by the configured launcher.
    /// @dev Settlement uses the hook's launcher-authorized entrypoint.
    function testExecutePreorderSettlement_RevertsWhenCallerIsNotLauncher() external {
        _setProtocolFeeCurrency(key.currency0);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.Unauthorized.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies explicit preorder settlement uses fixed 1% economics.
    /// @dev Confirms the treasury receives the 35% protocol slice of the fixed fee.
    function testExecutePreorderSettlement_UsesFixedOnePercentFee() external {
        _setProtocolFeeCurrency(key.currency0);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        uint256 treasury0Before = token0.balanceOf(treasury);
        token0.approve(address(hook), type(uint256).max);

        IMemeverseUniswapHook.SwapQuote memory quoteAtLaunch = router.quoteSwap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this)
        );
        assertEq(quoteAtLaunch.feeBps, 5000, "public launch fee");

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
        assertEq(token0.balanceOf(treasury) - treasury0Before, 0.35 ether, "fixed 1% protocol fee");
    }

    /// @notice Verifies explicit preorder settlement on an output-fee pool only collects the output-side protocol fee once.
    /// @dev The treasury/output balances should match a single 35 bps output fee on the post-LP-fee swap output.
    function testExecutePreorderSettlement_OutputSideProtocolFeeCollectedExactlyOnce() external {
        _setProtocolFeeCurrency(key.currency1);
        token0.approve(address(hook), type(uint256).max);

        uint256 sender1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertEq(token0.balanceOf(treasury) - treasury0Before, 0, "no input-side protocol fee");
        assertEq(token1.balanceOf(treasury) - treasury1Before, 0.1738625 ether, "single output-side protocol fee");
        assertEq(token1.balanceOf(address(this)) - sender1Before, 49.5011375 ether, "recipient gets net output once");
        assertEq(delta.amount0(), -int128(int256(99.35 ether)), "delta0 tracks post-LP-fee swap input");
        assertEq(delta.amount1(), int128(int256(49.5011375 ether)), "delta1 reduced by one output-side fee");
    }

    /// @notice Verifies changing launch-fee floor does not change explicit settlement pricing.
    /// @dev Settlement remains fixed-fee while public swaps still use launch fee schedule.
    function testExecutePreorderSettlement_IgnoresConfigurableLaunchFeeFloor() external {
        _setProtocolFeeCurrency(key.currency0);
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 4000, minFeeBps: 300, decayDurationSeconds: 900})
        );
        token0.approve(address(hook), type(uint256).max);

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        uint256 treasury0Before = token0.balanceOf(treasury);

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
        assertEq(token0.balanceOf(treasury) - treasury0Before, 0.35 ether, "settlement remains fixed 1%");
    }

    /// @notice Verifies explicit settlement updates dynamic-fee state even though the pool-manager self-call skips hook callbacks.
    /// @dev The immediate follow-up quote should observe carried short/volatility state, not a pristine fee engine.
    function testExecutePreorderSettlement_UpdatesDynamicFeeStateAndSubsequentQuote() external {
        _setProtocolFeeCurrency(key.currency0);
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 100, minFeeBps: 100, decayDurationSeconds: 1})
        );
        token0.approve(address(hook), type(uint256).max);

        uint160 postSettlementPrice = uint160((uint256(SQRT_PRICE_1_1) * 120) / 100);
        manager.setNextSwapSqrtPriceX96(poolId, postSettlementPrice);

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({
                    zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
                }),
                recipient: address(this)
            })
        );

        (
            uint256 weightedVolume0,
            uint256 weightedPriceVolume0,
            uint256 ewVWAPX18,,,
            uint24 volDeviationAccumulator,,
            uint24 shortImpactPpm,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

        assertGt(weightedVolume0, 0, "weighted volume");
        assertGt(weightedPriceVolume0, 0, "weighted price volume");
        assertGt(ewVWAPX18, 0, "ewvwap");
        assertGt(volDeviationAccumulator, 0, "volatility accumulator");
        assertGt(shortImpactPpm, 0, "short impact");

        MockPoolManagerForRouterTest pristineManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHookUpgradeable pristineHook =
            _deployHookProxyForManager(IPoolManager(address(pristineManager)), address(this), treasury);
        PoolKey memory pristineKey = _dynamicPoolKeyForHook(
            address(pristineHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );
        pristineHook.setPoolInitializer(address(this));
        pristineHook.authorizePoolInitialization(pristineKey, postSettlementPrice);
        pristineManager.initialize(pristineKey, postSettlementPrice);
        seedActiveLiquiditySharesForTest(address(pristineHook), pristineKey.toId(), address(this), 1e18);
        pristineHook.setProtocolFeeCurrency(pristineKey.currency0, true);
        pristineHook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 100, minFeeBps: 100, decayDurationSeconds: 1})
        );
        MemeverseUniswapHookLens pristineLens = new MemeverseUniswapHookLens(IPoolManager(address(pristineManager)));

        SwapParams memory followUpParams = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory settledQuote = router.quoteSwap(key, followUpParams, address(this));
        IMemeverseUniswapHook.SwapQuote memory pristineQuote = pristineLens.quoteSwap(
            IMemeverseUniswapHook(address(pristineHook)), pristineKey, followUpParams, address(this)
        );

        assertGt(settledQuote.feeBps, pristineQuote.feeBps, "settlement quote should carry dynamic state");
    }
}
