// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";

contract MemeverseSwapRouterIntegrationTest is RealisticSwapIntegrationBase {
    using BalanceDeltaLibrary for BalanceDelta;

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));
    }

    function testExactInput_InputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 payer0Before = token0.balanceOf(address(this));
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        (, uint256 fee0PerShareBefore,) = hook.poolInfo(poolId);
        RollbackSnapshot memory dynamicBefore = _rollbackSnapshot(address(this));

        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");

        (, uint256 fee0PerShareAfter,) = hook.poolInfo(poolId);
        RollbackSnapshot memory dynamicAfter = _rollbackSnapshot(address(this));
        IMemeverseUniswapHook.SwapQuote memory followUpQuote = router.quoteSwap(key, params, address(this));

        assertEq(payer0Before - token0.balanceOf(address(this)), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(
            token1.balanceOf(address(this)) - payer1Before, quote.estimatedUserOutputAmount, "exact recipient output"
        );
        assertEq(token0.balanceOf(treasury) - treasury0Before, quote.estimatedProtocolFeeAmount, "exact treasury fee");
        assertEq(
            fee0PerShareAfter - fee0PerShareBefore,
            _expectedLpFeeGrowth(quote.estimatedLpFeeAmount),
            "exact lp fee growth"
        );
        assertEq(delta.amount0(), -int128(int256(quote.estimatedUserInputAmount)), "delta0 exact");
        assertEq(delta.amount1(), int128(int256(quote.estimatedUserOutputAmount)), "delta1 exact");
        assertGt(dynamicAfter.weightedVolume0, dynamicBefore.weightedVolume0, "weightedVolume0 changed");
        assertGt(dynamicAfter.ewVWAPX18, dynamicBefore.ewVWAPX18, "ewvwap changed");
        assertGt(dynamicAfter.volDeviationAccumulator, dynamicBefore.volDeviationAccumulator, "vol deviation changed");
        assertGt(dynamicAfter.shortImpactPpm, dynamicBefore.shortImpactPpm, "short impact changed");
        assertGt(followUpQuote.feeBps, quote.feeBps, "state affects next quote fee");
    }

    function testExactInput_OutputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 payer0Before = token0.balanceOf(address(this));
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        (, uint256 fee0PerShareBefore,) = hook.poolInfo(poolId);

        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");

        (, uint256 fee0PerShareAfter,) = hook.poolInfo(poolId);
        assertEq(payer0Before - token0.balanceOf(address(this)), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(
            token1.balanceOf(address(this)) - payer1Before, quote.estimatedUserOutputAmount, "exact recipient output"
        );
        assertEq(token1.balanceOf(treasury) - treasury1Before, quote.estimatedProtocolFeeAmount, "exact treasury fee");
        assertEq(
            fee0PerShareAfter - fee0PerShareBefore,
            _expectedLpFeeGrowth(quote.estimatedLpFeeAmount),
            "exact lp fee growth"
        );
        assertEq(delta.amount0(), -int128(int256(quote.estimatedUserInputAmount)), "delta0 exact");
        assertEq(delta.amount1(), int128(int256(quote.estimatedUserOutputAmount)), "delta1 exact");
    }

    function testExactInput_OneForZero_InputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 payer0Before = token0.balanceOf(address(this));
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);

        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");

        assertEq(payer1Before - token1.balanceOf(address(this)), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(
            token0.balanceOf(address(this)) - payer0Before, quote.estimatedUserOutputAmount, "exact recipient output"
        );
        assertEq(token1.balanceOf(treasury) - treasury1Before, quote.estimatedProtocolFeeAmount, "exact treasury fee");
        assertEq(delta.amount0(), int128(int256(quote.estimatedUserOutputAmount)), "delta0 exact");
        assertEq(delta.amount1(), -int128(int256(quote.estimatedUserInputAmount)), "delta1 exact");
    }

    function testExactOutput_OneForZero_OutputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 payer0Before = token0.balanceOf(address(this));
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);

        BalanceDelta delta =
            router.swap(key, params, address(this), block.timestamp, 0, quote.estimatedUserInputAmount, "");

        assertEq(payer1Before - token1.balanceOf(address(this)), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(
            token0.balanceOf(address(this)) - payer0Before, quote.estimatedUserOutputAmount, "exact recipient output"
        );
        assertEq(token0.balanceOf(treasury) - treasury0Before, quote.estimatedProtocolFeeAmount, "exact treasury fee");
        assertEq(delta.amount0(), int128(int256(quote.estimatedUserOutputAmount)), "delta0 exact");
    }

    function testExactInput_InputFee_PartialFill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 98 ether);

        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        _assertRollback(address(this), before_);
    }
}
