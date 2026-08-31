// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

/// @notice Adversarial fork fuzz test for large exact-input fee arithmetic on the real V4 singleton.
contract MemeverseSwapForkFuzzLargeInputTest is MemeverseSwapForkBase {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant EXTRA_LIQUIDITY_AMOUNT = 1e24;
    uint256 internal constant LARGE_INPUT_MIN = 1e18;
    uint256 internal constant LARGE_INPUT_MAX = 1e22;

    function setUp() public {
        _setUpBase(IPermit2(address(0)));
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        _addHighLiquidity();
    }

    /// @notice Fuzzes large exact-input swaps to ensure fee deltas stay within the hook's int128 boundary.
    /// @param rawAmount Fuzzer seed mapped into the fillable high-liquidity range.
    function testFuzz_ExactInputLargeAmount_NoUnexpectedRevert(uint256 rawAmount) external {
        uint256 amountIn = bound(rawAmount, LARGE_INPUT_MIN, LARGE_INPUT_MAX);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 inputBefore = token0.balanceOf(address(this));
        uint256 outputBefore = token1.balanceOf(address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);
        (, uint256 fee0Before,) = _hook().poolInfo(poolId);

        BalanceDelta delta = _swapInSession(key, params, 0, amountIn, "");

        (, uint256 fee0After,) = _hook().poolInfo(poolId);
        uint256 actualInput = inputBefore - token0.balanceOf(address(this));
        uint256 actualOutput = token1.balanceOf(address(this)) - outputBefore;

        assertEq(actualInput, quote.estimatedUserInputAmount, "user input spend");
        assertGt(actualOutput, 0, "nonzero output");
        assertEq(token0.balanceOf(treasury) - treasuryBefore, quote.estimatedProtocolFeeAmount, "treasury fee");
        assertEq(fee0After - fee0Before, _expectedLpFeeGrowth(quote.estimatedLpFeeAmount), "lp fee growth");
        assertEq(delta.amount0(), -int128(int256(actualInput)), "delta0");
        assertEq(delta.amount1(), int128(int256(actualOutput)), "delta1");
    }

    function _addHighLiquidity() internal {
        token0.mint(address(this), EXTRA_LIQUIDITY_AMOUNT);
        token1.mint(address(this), EXTRA_LIQUIDITY_AMOUNT);
        _hook()
            .addLiquidityCore(
                IMemeverseUniswapHook.AddLiquidityCoreParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    amount0Desired: EXTRA_LIQUIDITY_AMOUNT,
                    amount1Desired: EXTRA_LIQUIDITY_AMOUNT,
                    to: address(this)
                })
            );
    }
}

/// @notice Adversarial fork fuzz tests for exact-output gross-up boundaries on the base 100-ether pool.
contract MemeverseSwapForkFuzzExactOutputTest is MemeverseSwapForkBase {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant EXACT_OUTPUT_MAX = 50 ether;

    function setUp() public {
        _setUpBase(IPermit2(address(0)));
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
    }

    /// @notice Fuzzes exact-output zero-for-one swaps near the base pool's output boundary.
    /// @param rawOut Fuzzer seed mapped to a fillable requested output.
    /// @param outputSideFee When true, protocol fees are grossed up on the output token.
    function testFuzz_ExactOutputFillable_QuoteMatchesActual_ZeroForOne(uint256 rawOut, bool outputSideFee) external {
        uint256 requestedOutput = bound(rawOut, 1, EXACT_OUTPUT_MAX);
        Currency feeCurrency = outputSideFee ? key.currency1 : key.currency0;
        _assertExactOutputQuoteMatchesActual(true, requestedOutput, feeCurrency);
    }

    /// @notice Fuzzes exact-output one-for-zero swaps near the base pool's output boundary.
    /// @param rawOut Fuzzer seed mapped to a fillable requested output.
    /// @param outputSideFee When true, protocol fees are grossed up on the output token.
    function testFuzz_ExactOutputFillable_QuoteMatchesActual_OneForZero(uint256 rawOut, bool outputSideFee) external {
        uint256 requestedOutput = bound(rawOut, 1, EXACT_OUTPUT_MAX);
        Currency feeCurrency = outputSideFee ? key.currency0 : key.currency1;
        _assertExactOutputQuoteMatchesActual(false, requestedOutput, feeCurrency);
    }

    function _assertExactOutputQuoteMatchesActual(bool zeroForOne, uint256 requestedOutput, Currency feeCurrency)
        internal
    {
        _setOnlyProtocolFeeCurrency(feeCurrency);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(requestedOutput),
            sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 token0Before = token0.balanceOf(address(this));
        uint256 token1Before = token1.balanceOf(address(this));
        uint256 treasuryBefore = _balanceOfCurrency(feeCurrency, treasury);
        (, uint256 fee0Before, uint256 fee1Before) = _hook().poolInfo(poolId);

        // Exact-output pulls the full quoted budget up front, so the quote is the tight maximum input.
        BalanceDelta delta = _swapInSession(key, params, 0, quote.estimatedUserInputAmount, "");

        (, uint256 fee0After, uint256 fee1After) = _hook().poolInfo(poolId);

        uint256 actualInput = zeroForOne
            ? token0Before - token0.balanceOf(address(this))
            : token1Before - token1.balanceOf(address(this));
        uint256 actualOutput = zeroForOne
            ? token1.balanceOf(address(this)) - token1Before
            : token0.balanceOf(address(this)) - token0Before;
        uint256 lpFeeGrowthDelta = zeroForOne ? fee0After - fee0Before : fee1After - fee1Before;

        assertEq(actualInput, quote.estimatedUserInputAmount, "user input spend");
        assertEq(actualOutput, quote.estimatedUserOutputAmount, "user output");
        assertEq(
            _balanceOfCurrency(feeCurrency, treasury) - treasuryBefore, quote.estimatedProtocolFeeAmount, "treasury fee"
        );
        assertEq(lpFeeGrowthDelta, _expectedLpFeeGrowth(quote.estimatedLpFeeAmount), "lp fee growth");
        assertEq(
            delta.amount0(),
            zeroForOne
                ? -int128(int256(quote.estimatedUserInputAmount))
                : int128(int256(quote.estimatedUserOutputAmount)),
            "delta0"
        );
        assertEq(
            delta.amount1(),
            zeroForOne
                ? int128(int256(quote.estimatedUserOutputAmount))
                : -int128(int256(quote.estimatedUserInputAmount)),
            "delta1"
        );
    }

    function _setOnlyProtocolFeeCurrency(Currency feeCurrency) internal {
        Currency otherCurrency =
            Currency.unwrap(feeCurrency) == Currency.unwrap(key.currency0) ? key.currency1 : key.currency0;
        _hook().setProtocolFeeCurrency(otherCurrency, false);
        _hook().setProtocolFeeCurrency(feeCurrency, true);
    }

    function _balanceOfCurrency(Currency currency, address account) internal view returns (uint256) {
        return Currency.unwrap(currency) == address(token0) ? token0.balanceOf(account) : token1.balanceOf(account);
    }
}
