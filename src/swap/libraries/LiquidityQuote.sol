// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/// @title LiquidityQuote
/// @notice Shared quote helper for full-range liquidity adds in Memeverse hook-based pools.
/// @dev Used by the hook Core, router, and bootstrap helpers to derive the same liquidity result and actual token
/// usage from a caller's desired token budgets at the current pool price.
library LiquidityQuote {
    // MIN_SQRT_PRICE_X96 / MAX_SQRT_PRICE_X96 are the sqrt-price encoding of the full-range position boundary:
    // each equals TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK / FULL_RANGE_UPPER_TICK),
    // hardcoded so quote paths avoid the runtime TickMath derivation. If either full-range tick is retuned, both
    // values must be re-derived from the new ticks in the same change, else quotes and actual mints diverge.
    uint160 internal constant MIN_SQRT_PRICE_X96 = 4_310_618_292;
    uint160 internal constant MAX_SQRT_PRICE_X96 = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;

    /// @notice Quotes the full-range liquidity add result from desired token budgets.
    /// @dev Returns both the liquidity implied by the desired budgets and the actual token amounts consumed by that
    /// liquidity at `sqrtPriceX96`.
    /// @param sqrtPriceX96 The current pool sqrt price.
    /// @param amount0Desired The caller's budget for currency0.
    /// @param amount1Desired The caller's budget for currency1.
    /// @return liquidity The maximum full-range liquidity supported by the budgets.
    /// @return amount0Used The quoted amount of currency0 consumed by that liquidity.
    /// @return amount1Used The quoted amount of currency1 consumed by that liquidity.
    function quote(uint160 sqrtPriceX96, uint256 amount0Desired, uint256 amount1Desired)
        internal
        pure
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, MIN_SQRT_PRICE_X96, MAX_SQRT_PRICE_X96, amount0Desired, amount1Desired
        );
        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, MIN_SQRT_PRICE_X96, MAX_SQRT_PRICE_X96, liquidity);
    }
}
