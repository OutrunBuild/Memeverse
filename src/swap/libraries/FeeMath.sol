// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title FeeMath
/// @notice Shared fee split math and pure dynamic-fee math primitives for Memeverse swap fees.
/// @dev Basis points (bps) use 10_000 as 100%. The protocol receives 35% of the total fee and LPs receive the rest.
///      All pure math primitives are `internal` so they inline into callers; the library itself is never deployed.
library FeeMath {
    uint256 internal constant BPS_BASE = 10_000;
    uint256 internal constant PROTOCOL_FEE_SHARE_BPS = 3_500;

    /// @notice Q128 fixed-point scaling used by per-share LP fee growth (1 << 128). Single source of
    ///         truth shared by `MemeverseSwapFeeBase._accrueLpFee` (write side) and `claimableFee`
    ///         below (read side) so the per-share accumulator cannot drift.
    uint256 internal constant FEE_GROWTH_Q128 = uint256(1) << 128;

    /// @notice LP fee crystallized for an LP balance given per-share growth and the user's offset.
    /// @dev Round-down floor shared by `MemeverseUniswapHookLens.claimableFees` (off-chain preview) and
    ///      `SwapFacet._updateUserSnapshot` (on-chain crystallize truth) so the two cannot drift on
    ///      rounding semantics. `unchecked`: `fee*PerShare` is monotonically non-decreasing — the sole
    ///      write-site `MemeverseSwapFeeBase._accrueLpFee` only adds a positive delta — so `feePerShare`
    ///      is always `>= feeOffset` and the subtraction cannot underflow. Callers keep their own
    ///      zero-growth / zero-balance early-returns and `>` guards; this only owns the arithmetic.
    function claimableFee(uint256 balance, uint256 feePerShare, uint256 feeOffset) internal pure returns (uint256) {
        unchecked {
            return FullMath.mulDiv(balance, feePerShare - feeOffset, FEE_GROWTH_Q128);
        }
    }

    // Constants used by the dynamic-fee pure math primitives below. They live here as the single source of truth so
    // both the engine and any importer (tests) reference the same value.
    // EWVWAP = Exponentially-Weighted Volume-weighted Average Price: the dynamic-fee reference spot price that
    // adverse/decay logic compares against. X18 fixed-point, so its precision base is 1e18.
    uint256 internal constant EWVWAP_PRECISION = 1e18;
    uint256 internal constant Q192 = uint256(1) << 192;
    uint256 internal constant Q192_MASK = Q192 - 1;
    uint256 internal constant PPM_BASE = 1_000_000;
    // PIF = price move: the ppm difference between two sqrt prices, capped here (`priceMovePpmCapped`).
    uint24 internal constant PIF_CAP_PPM = 150_000;
    uint24 internal constant VOL_MAX_FEE_BPS = 50;
    uint24 internal constant VOL_MAX_DEVIATION_ACCUMULATOR = 1_500_000;
    // Sqrt-price ratio (X18) at which an up/down move saturates exactly at `PIF_CAP_PPM` (150_000 ppm = 15%):
    // `UP_SHORT_BUCKET = sqrt(1 + 15%) * 1e18 ≈ 1.0723...e18`, `DOWN_SHORT_BUCKET = sqrt(1 - 15%) * 1e18 ≈ 0.9219...e18`.
    // Beyond these thresholds `priceMovePpmCapped` short-circuits to `PIF_CAP_PPM`, so the linear-ppm branch only
    // runs inside the ±15% window where the wide-int rounding correction is valid.
    uint256 internal constant UP_SHORT_BUCKET = 1072380529476360830;
    uint256 internal constant DOWN_SHORT_BUCKET = 921954445729288731;

    /// @notice Returns the protocol-owned portion of a total fee value.
    /// @dev Uses FullMath.mulDiv so rounding stays identical anywhere the split is applied.
    /// @param feeBps Total fee in basis points.
    /// @return protocolFeeBps_ Protocol fee in basis points.
    function protocolFeeBps(uint256 feeBps) internal pure returns (uint256 protocolFeeBps_) {
        return FullMath.mulDiv(feeBps, PROTOCOL_FEE_SHARE_BPS, BPS_BASE);
    }

    /// @notice Returns both LP and protocol portions of a total fee value.
    /// @dev Computes the protocol share once for call sites that need both split values.
    /// @param feeBps Total fee in basis points.
    /// @return lpFeeBps_ LP fee in basis points.
    /// @return protocolFeeBps_ Protocol fee in basis points.
    function splitFeeBps(uint256 feeBps) internal pure returns (uint256 lpFeeBps_, uint256 protocolFeeBps_) {
        protocolFeeBps_ = protocolFeeBps(feeBps);
        unchecked {
            // Safe: protocol share is below BPS_BASE, so protocol fee bps cannot exceed total fee bps.
            lpFeeBps_ = feeBps - protocolFeeBps_;
        }
    }

    /// @notice Scales `amount` by a basis-points fee rate for fixed/preorder settlement, rounding down toward the payer.
    /// @dev Fee primitive for fixed/preorder settlement. Ordinary dynamic settlement uses `OrdinarySwapMath`.
    /// @param amount Base amount to apply the fee rate to.
    /// @param feeBps Fee rate in basis points (1 bps = 0.01%).
    /// @return Fee amount rounded down.
    function feeOnAmount(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, feeBps, BPS_BASE);
    }

    /// @notice Converts a Uniswap v4 sqrtPriceX96 into a spot price scaled to 1e18 (X18).
    /// @dev Squares the 256-bit sqrt price without overflow via `_squareWide`, then extracts the integer part
    ///      (top bits) and fractional part (Q192 mask) and scales both to 1e18.
    /// @param sqrtPriceX96 Uniswap v4 sqrt price in X96 fixed-point.
    /// @return Spot price in X18 fixed-point.
    function spotX18FromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        (uint256 squareHi, uint256 squareLo) = squareWide(sqrtPriceX96);
        // Squaring X96 yields X192: the 320-bit `squareHi||squareLo` has its binary point at bit 192 of the low
        // word. The integer part is the top 128 bits above that point — `squareHi` (64 bits) concatenated with the
        // top 64 bits of `squareLo` (`squareLo >> 192`), reassembled as `(squareHi << 64) | (squareLo >> 192)`.
        // The fractional part is the low 192 bits below the point (`squareLo & Q192_MASK`).
        uint256 integerPart = (squareHi << 64) | (squareLo >> 192);
        uint256 fractionalPart = squareLo & Q192_MASK;
        return integerPart * EWVWAP_PRECISION + FullMath.mulDiv(fractionalPart, EWVWAP_PRECISION, Q192);
    }

    /// @notice Price-move (PIF) ppm between two sqrt prices, capped at `PIF_CAP_PPM`.
    /// @dev Rounds the candidate ppm up (up-move) or down (down-move) to the nearest whole ppm using exact wide
    ///      integer comparison against `(post/pre)^2`, avoiding any floating-point drift. When the squared ratio
    ///      moves beyond the short buckets, the result is clamped to `PIF_CAP_PPM`.
    /// @param preSqrtPrice Sqrt price before the move.
    /// @param postSqrtPrice Sqrt price after the move.
    /// @return Capped price-move ppm in [0, PIF_CAP_PPM].
    function priceMovePpmCapped(uint160 preSqrtPrice, uint160 postSqrtPrice) internal pure returns (uint256) {
        if (preSqrtPrice == postSqrtPrice) return 0;
        uint256 sqrtRatioX18 = FullMath.mulDiv(uint256(postSqrtPrice), EWVWAP_PRECISION, uint256(preSqrtPrice));
        if (postSqrtPrice > preSqrtPrice) {
            if (sqrtRatioX18 > UP_SHORT_BUCKET) return PIF_CAP_PPM;
            uint256 upSquaredRatioX18 = FullMath.mulDiv(sqrtRatioX18, sqrtRatioX18, EWVWAP_PRECISION);
            uint256 candidate = (upSquaredRatioX18 - EWVWAP_PRECISION) / 1e12;
            if (
                candidate < PIF_CAP_PPM
                    && wideSquareTimesSmallGte(postSqrtPrice, PPM_BASE, preSqrtPrice, PPM_BASE + candidate + 1)
            ) ++candidate;
            return candidate;
        }
        if (sqrtRatioX18 < DOWN_SHORT_BUCKET) return PIF_CAP_PPM;
        uint256 downSquaredRatioX18 = FullMath.mulDiv(sqrtRatioX18, sqrtRatioX18, EWVWAP_PRECISION);
        uint256 candidatePpm = (EWVWAP_PRECISION - downSquaredRatioX18) / 1e12;
        if (
            candidatePpm != 0
                && !wideSquareTimesSmallLte(postSqrtPrice, PPM_BASE, preSqrtPrice, PPM_BASE - candidatePpm)
        ) --candidatePpm;
        return candidatePpm;
    }

    /// @notice Maps the volatility deviation accumulator to a sqrt-shaped fee in basis points.
    /// @dev Quadratic growth: `sqrt(accumulator / VOL_MAX_DEVIATION_ACCUMULATOR) * VOL_MAX_FEE_BPS`. Saturates at
    ///      `VOL_MAX_FEE_BPS` once the accumulator reaches `VOL_MAX_DEVIATION_ACCUMULATOR`.
    /// @param accumulator Volatility deviation accumulator.
    /// @return Volatility fee in basis points.
    function volatilitySqrtFeeBps(uint256 accumulator) internal pure returns (uint256) {
        if (accumulator == 0) return 0;
        return Math.sqrt(accumulator * uint256(VOL_MAX_FEE_BPS) ** 2 / uint256(VOL_MAX_DEVIATION_ACCUMULATOR));
    }

    /// @notice 256-bit square of a 160-bit value, returned as (hi, lo) wide integer.
    /// @dev Splits the input at 128 bits and composes hi/lo via the lower square, cross term, and upper square.
    ///      Caller must read the carry adjustment into `hi` when `lo` overflows past `lowerSquared`.
    /// @param value 160-bit input.
    /// @return hi High 256 bits of the 320-bit square.
    /// @return lo Low 256 bits of the square.
    function squareWide(uint160 value) internal pure returns (uint256 hi, uint256 lo) {
        uint256 upper = uint256(value) >> 128;
        uint256 lower = uint128(value);
        uint256 lowerSquared = lower * lower;
        uint256 cross = (lower * upper) << 1;
        unchecked {
            lo = lowerSquared + (cross << 128);
        }
        hi = (upper * upper) + (cross >> 128);
        if (lo < lowerSquared) ++hi;
    }

    /// @notice Wide-int multiplication of a (hi, lo) 320-bit value by a small (<=128-bit) factor.
    /// @dev Used to scale squared sqrt prices by an integer ppm factor for exact price-move comparisons.
    /// @param hi High 256 bits of the wide value.
    /// @param lo Low 256 bits of the wide value.
    /// @param factor Small integer factor.
    /// @return outHi High 256 bits of the product.
    /// @return outLo Low 256 bits of the product.
    function mulWideBySmall(uint256 hi, uint256 lo, uint256 factor)
        internal
        pure
        returns (uint256 outHi, uint256 outLo)
    {
        uint256 loLower = uint128(lo);
        uint256 loUpper = lo >> 128;
        uint256 lowerProduct = loLower * factor;
        uint256 upperProduct = loUpper * factor;
        unchecked {
            outLo = lowerProduct + (upperProduct << 128);
        }
        outHi = (hi * factor) + (upperProduct >> 128);
        if (outLo < lowerProduct) ++outHi;
    }

    /// @notice Exact comparison `left^2 * leftFactor >= right^2 * rightFactor` using wide integers.
    /// @dev Avoids floating-point when deciding whether a price-move candidate should round up.
    function wideSquareTimesSmallGte(uint160 left, uint256 leftFactor, uint160 right, uint256 rightFactor)
        internal
        pure
        returns (bool)
    {
        (uint256 leftSquareHi, uint256 leftSquareLo) = squareWide(left);
        (uint256 rightSquareHi, uint256 rightSquareLo) = squareWide(right);
        (uint256 leftHi, uint256 leftLo) = mulWideBySmall(leftSquareHi, leftSquareLo, leftFactor);
        (uint256 rightHi, uint256 rightLo) = mulWideBySmall(rightSquareHi, rightSquareLo, rightFactor);
        return leftHi > rightHi || (leftHi == rightHi && leftLo >= rightLo);
    }

    /// @notice Exact comparison `left^2 * leftFactor <= right^2 * rightFactor` using wide integers.
    /// @dev Counterpart to `wideSquareTimesSmallGte` for the down-move rounding branch.
    function wideSquareTimesSmallLte(uint160 left, uint256 leftFactor, uint160 right, uint256 rightFactor)
        internal
        pure
        returns (bool)
    {
        (uint256 leftSquareHi, uint256 leftSquareLo) = squareWide(left);
        (uint256 rightSquareHi, uint256 rightSquareLo) = squareWide(right);
        (uint256 leftHi, uint256 leftLo) = mulWideBySmall(leftSquareHi, leftSquareLo, leftFactor);
        (uint256 rightHi, uint256 rightLo) = mulWideBySmall(rightSquareHi, rightSquareLo, rightFactor);
        return leftHi < rightHi || (leftHi == rightHi && leftLo <= rightLo);
    }
}
