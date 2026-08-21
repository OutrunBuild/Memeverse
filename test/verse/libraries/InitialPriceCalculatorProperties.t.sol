// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {InitialPriceCalculator} from "src/verse/libraries/InitialPriceCalculator.sol";

/// @title InitialPriceCalculatorProperties
/// @notice Success-domain and rounding properties for the launcher initial-price helper
///         (audit batch 2026-08-19, design doc §4 property INV-D4 — the 04a-G-03
///         adjudicator).
/// @dev G-03 claimed fundBasedAmount in (2^48, 2^64-1] is a "legal config, guaranteed
///      pricing revert" dead zone, derived from "MAX_SQRT_PRICE ~ 2^120". The vendored
///      TickMath constant is ~2^159.97, and ratio >= 2^64 is structurally unreachable
///      in this calculator (with amount0 <= 2^192 the fast check reverts
///      PriceRatioTooHigh; with amount0 > 2^192 the skip branch still forces
///      ratio < 2^64 because amount1 must fit uint256). The reachable price window is
///      [2^-128, 2^64) — the config ceiling 2^64 sits exactly on the fast-check edge,
///      so the allowed domain prices successfully and the dead zone is empty.
contract InitialPriceCalculatorProperties is Test {
    address internal constant LOWER = address(0x1000);
    address internal constant HIGHER = address(0x2000);

    /// @notice INV-D4-P1: for every allowed fundBasedAmount (1 .. 2^64-1, the
    ///         setFundMetaData domain) and every uAsset budget (1 .. 2^128-1,
    ///         MAX_SUPPORTED_TOTAL_GENESIS_FUNDS), BOTH address orderings price
    ///         successfully — no InvalidSqrtPrice, no PriceRatioTooHigh.
    /// @dev The calculator sorts the pair by address, so swapping call arguments is a
    ///      no-op: the two price directions (price = fba vs price = 1/fba) are explored
    ///      by placing memecoin at HIGHER vs LOWER. Failing this test anywhere in the
    ///      domain means G-03's dead zone is real.
    function testFuzz_InitialPriceSuccessDomain(uint64 fba, uint128 uAssetBudget, bool memecoinSortsHigh)
        external
        pure
    {
        fba = uint64(bound(fba, 1, type(uint64).max));
        uAssetBudget = uint128(bound(uAssetBudget, 1, type(uint128).max));
        uint256 memecoinBudget = uint256(uAssetBudget) * fba; // <= 2^128 * 2^64 = 2^192, no overflow

        address memecoin = memecoinSortsHigh ? HIGHER : LOWER;
        address uAsset = memecoinSortsHigh ? LOWER : HIGHER;

        uint160 sqrtPrice =
            InitialPriceCalculator.calculateInitialSqrtPriceX96(memecoin, uAsset, memecoinBudget, uAssetBudget);

        // INV-D4-P2: sqrt brackets the exact ratio (price = token1/token0).
        uint256 amount1 = memecoinSortsHigh ? memecoinBudget : uint256(uAssetBudget);
        uint256 amount0 = memecoinSortsHigh ? uint256(uAssetBudget) : memecoinBudget;
        _assertSqrtIsFloorOfRatio(sqrtPrice, amount1, amount0);
    }

    /// @notice INV-D4-P3: the success/failure boundary sits exactly at the config
    ///         ceiling — 2^64-1 succeeds and 2^64 reverts PriceRatioTooHigh (with
    ///         amount0 = 1 the raw ratio equals fba exactly, so the fast check is the
    ///         binding edge and InvalidSqrtPrice is unreachable near the top).
    /// @dev `try` requires an external call, so the probes go through the external
    ///      wrapper (same pattern as InitialPriceCalculator.t.sol).
    function test_InitialPriceBoundaryExactAtConfigCeiling() external {
        // One wei above the config ceiling must fail (PriceRatioTooHigh).
        bool ceilingReverts;
        try this.calculateInitialSqrtPriceX96External(HIGHER, LOWER, uint256(type(uint64).max) + 1, 1) {
            ceilingReverts = false;
        } catch {
            ceilingReverts = true;
        }
        assertTrue(ceilingReverts, "fba = 2^64 must revert");

        // The whole config domain succeeds: bisect down to confirm the largest accepted
        // value is exactly 2^64 - 1 (all probes below the ceiling succeed, so this also
        // double-checks P1 on the price = fba axis).
        uint256 lo = 1;
        uint256 hi = uint256(type(uint64).max) + 1;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            try this.calculateInitialSqrtPriceX96External(HIGHER, LOWER, mid, 1) {
                lo = mid;
            } catch {
                hi = mid;
            }
        }
        assertEq(lo, uint256(type(uint64).max), "largest accepted fba must be 2^64 - 1");
    }

    /// @dev External wrapper so revert probes can use `try` against the internal
    ///      library function (mirrors InitialPriceCalculator.t.sol).
    function calculateInitialSqrtPriceX96External(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external pure returns (uint160) {
        return InitialPriceCalculator.calculateInitialSqrtPriceX96(tokenA, tokenB, amountADesired, amountBDesired);
    }

    /// @dev INV-D4-P2 helper: s must equal floor(sqrt(amount1 * 2^192 / amount0)),
    ///      asserted via the bracketing inequalities s^2 <= q < (s+1)^2 with
    ///      q = mulDiv(amount1, 2^192, amount0) — the definition of floor sqrt,
    ///      expressed independently of Math.sqrt.
    ///      Domain safety: in the P1 domain ratio is in [2^-64, 2^64), so s < 2^128;
    ///      with q <= (2^64-1) * 2^192 = 2^256 - 2^192 < (2^128-1)^2, both squares fit
    ///      256 bits (guaranteed by the fuzz bounds above, not assumed here).
    function _assertSqrtIsFloorOfRatio(uint160 s, uint256 amount1, uint256 amount0) private pure {
        uint256 q = FullMath.mulDiv(amount1, 1 << 192, amount0);
        assertLe(uint256(s) * s, q, "sqrt below floor");
        assertLt(q, (uint256(s) + 1) * (uint256(s) + 1), "sqrt above floor");
    }
}
