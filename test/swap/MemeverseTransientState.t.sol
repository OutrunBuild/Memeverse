// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract MemeverseTransientStateTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHook internal hook;
    MemeverseUniswapHookLens internal lens;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        hook = _deployHookProxy(address(this), address(this));
        lens = new MemeverseUniswapHookLens(IPoolManager(address(mockManager)));

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

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        mockManager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity();
    }

    function testAfterSwapUsesCachedProtocolFeeSideFromBeforeSwap() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        assertTrue(quote.protocolFeeOnInput, "expected input-side protocol fee");

        uint256 expectedPoolInput =
            quote.estimatedUserInputAmount - quote.estimatedLpFeeAmount - quote.estimatedProtocolFeeAmount;

        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);

        BalanceDelta delta = toBalanceDelta(-int128(int256(expectedPoolInput)), int128(int256(50 ether)));

        vm.prank(address(mockManager));
        (, int128 unspecifiedDelta) = hook.afterSwap(address(this), key, params, delta, bytes(""));

        assertEq(unspecifiedDelta, 0, "input-side exact-input swap should not emit output delta");
    }

    function _deployHookProxy(address owner_, address treasury_) internal returns (MemeverseUniswapHook) {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared helper
        // (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        (address hookProxy,) = deployHookAtFlagAddress(IPoolManager(address(mockManager)), owner_, treasury_);
        return MemeverseUniswapHook(hookProxy);
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
