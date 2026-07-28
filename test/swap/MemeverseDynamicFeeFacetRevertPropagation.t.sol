// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseUniswapHookLens} from "../../src/swap/interfaces/IMemeverseUniswapHookLens.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {
    RevertingDynamicFeeFacetMock,
    PREPARE_SWAP_FEE_POINT,
    UPDATE_AFTER_SWAP_POINT
} from "../mocks/swap/RevertingDynamicFeeFacetMock.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";

/// @notice Regression coverage for DynamicFeeFacet errors crossing public swap and settlement boundaries.
contract MemeverseDynamicFeeFacetRevertPropagationTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    function setUp() public {
        manager = new MockPoolManagerForRouterTest();
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), makeAddr("treasury"));
        hook = MemeverseUniswapHook(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            IMemeverseUniswapHookLens(address(new MemeverseUniswapHookLens(IPoolManager(address(manager))))),
            IPermit2(address(0xBEEF))
        );

        MockERC20 tokenA = new MockERC20("Token0", "TK0", 18);
        MockERC20 tokenB = new MockERC20("Token1", "TK1", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        hook.setLauncher(address(this));
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setPoolInitializer(address(router));
        seedActiveLiquiditySharesForTest(address(hook), key.toId(), address(this), 1e18);
    }

    function test_RevertWhen_DynamicFeeFacetPrepareSwapFeeFailsThroughPublicSwap() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        RevertingDynamicFeeFacetMock replacement =
            new RevertingDynamicFeeFacetMock(IPoolManager(address(manager)), PREPARE_SWAP_FEE_POINT);
        hook.setFacet(hook.DYNAMIC_FEE_FACET_ROLE(), address(replacement));

        // Public swap path: open a session so the swap reaches the facet (session gate precedes facet dispatch).
        hook.beginAccountSession();
        vm.expectRevert(
            abi.encodeWithSelector(
                RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, PREPARE_SWAP_FEE_POINT
            )
        );
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        hook.endAccountSession();
    }

    function test_RevertWhen_DynamicFeeFacetUpdateAfterSwapFailsThroughPublicSwap() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        address originalFacet = hook.dynamicFeeFacet();
        uint256 payerToken0Before = token0.balanceOf(address(this));
        uint256 routerToken0Before = token0.balanceOf(address(router));
        IDynamicFeeFacet.DynamicFeeState memory stateBefore = hook.dynamicFeeStateOf(key.toId());

        RevertingDynamicFeeFacetMock replacement =
            new RevertingDynamicFeeFacetMock(IPoolManager(address(manager)), UPDATE_AFTER_SWAP_POINT);
        hook.setFacet(hook.DYNAMIC_FEE_FACET_ROLE(), address(replacement));

        // Public swap path: one session covers both the reverting swap and the recovery swap. The revert
        // rolls back its own transient context, leaving the session clean for the second swap.
        hook.beginAccountSession();
        vm.expectRevert(
            abi.encodeWithSelector(
                RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, UPDATE_AFTER_SWAP_POINT
            )
        );
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        assertEq(token0.balanceOf(address(this)), payerToken0Before, "payer input rolled back");
        assertEq(token0.balanceOf(address(router)), routerToken0Before, "router input rolled back");
        assertEq(hook.dynamicFeeStateOf(key.toId()).shortImpactPpm, stateBefore.shortImpactPpm, "canary rolled back");

        hook.setFacet(hook.DYNAMIC_FEE_FACET_ROLE(), originalFacet);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        hook.endAccountSession();
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "public swap recovers");
    }

    function test_RevertWhen_DynamicFeeFacetUpdateAfterSwapFailsThroughSettlement() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        token0.approve(address(hook), type(uint256).max);
        address originalFacet = hook.dynamicFeeFacet();
        uint256 payerToken0Before = token0.balanceOf(address(this));
        uint256 hookToken0Before = token0.balanceOf(address(hook));
        IDynamicFeeFacet.DynamicFeeState memory stateBefore = hook.dynamicFeeStateOf(key.toId());

        RevertingDynamicFeeFacetMock replacement =
            new RevertingDynamicFeeFacetMock(IPoolManager(address(manager)), UPDATE_AFTER_SWAP_POINT);
        hook.setFacet(hook.DYNAMIC_FEE_FACET_ROLE(), address(replacement));

        vm.expectRevert(
            abi.encodeWithSelector(
                RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, UPDATE_AFTER_SWAP_POINT
            )
        );
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({
                    zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                recipient: address(this)
            })
        );

        assertEq(token0.balanceOf(address(this)), payerToken0Before, "settlement payer input rolled back");
        assertEq(token0.balanceOf(address(hook)), hookToken0Before, "settlement hook input rolled back");
        assertEq(
            hook.dynamicFeeStateOf(key.toId()).shortImpactPpm,
            stateBefore.shortImpactPpm,
            "settlement canary rolled back"
        );

        hook.setFacet(hook.DYNAMIC_FEE_FACET_ROLE(), originalFacet);
        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({
                    zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                recipient: address(this)
            })
        );
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "settlement recovers");
    }
}
