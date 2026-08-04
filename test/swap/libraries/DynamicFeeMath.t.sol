// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {wadExp} from "solmate/utils/SignedWadMath.sol";

import {DynamicFeeMath} from "../../../src/swap/libraries/DynamicFeeMath.sol";
import {FeeMath} from "../../../src/swap/libraries/FeeMath.sol";
import {OrdinarySwapMath} from "../../../src/swap/libraries/OrdinarySwapMath.sol";
import {IDynamicFeeFacet} from "../../../src/swap/interfaces/IDynamicFeeFacet.sol";

/// @title DynamicFeeMathTest
/// @notice Direct library tests for the algorithms in `DynamicFeeMath`.
/// @dev Every algorithm is `internal`, so this suite calls `DynamicFeeMath.<fn>(...)` directly with the
///      per-pool / per-trader state passed in as `memory` — no facet storage context, no proxy, and no auth
///      wiring. The suite pins per-function boundaries independently of the facet's storage-writing shell.
///      Expected values are derived from each function's documented contract, with calculations shown inline.
contract DynamicFeeMathTest is Test {
    // ── Shared fixtures ───────────────────────────────────────────────────────────
    // v4 sqrt price encoding a 1:1 spot (2^192).
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint128 internal constant LIQUIDITY = 1_000_000 ether;

    // Algorithm constants are referenced directly as `DynamicFeeMath.<CONST>` / `FeeMath.<CONST>`: Solidity
    // exposes `internal constant` library members via the library name at compile time, so duplicating their
    // values here would just create a second source of truth that silently drifts on a retune.

    function setUp() external {
        // Use a non-zero timestamp so `view` decay helpers are deterministic.
        vm.warp(1);
    }

    /// @dev Default launch schedule: 5000 bps at launch, decaying to the 100 bps base fee over 900 seconds.
    function _launchFeeConfig() internal pure returns (IDynamicFeeFacet.LaunchFeeConfig memory) {
        return IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 5000, minFeeBps: 100, decayDurationSeconds: 900});
    }

    /// @dev Empty per-pool state: no EWVWAP history, no volatility accumulator, no short impact. Mirrors the
    ///      storage state of a freshly-initialized pool before any `updateAfterSwap`.
    function _emptyState() internal pure returns (IDynamicFeeFacet.DynamicFeeState memory) {
        return IDynamicFeeFacet.DynamicFeeState({
            weightedVolume0: 0,
            weightedPriceVolume0: 0,
            ewVWAPX18: 0,
            volAnchorSqrtPriceX96: 0,
            volLastMoveTs: 0,
            volDeviationAccumulator: 0,
            volCarryAccumulator: 0,
            shortImpactPpm: 0,
            shortLastTs: 0
        });
    }

    /// @dev Empty per-trader batch state: no in-window PIF accumulation.
    function _emptyBatch() internal pure returns (IDynamicFeeFacet.AddressBatchState memory) {
        return IDynamicFeeFacet.AddressBatchState({batchAccumPpm: 0, batchStartTs: 0});
    }

    /// @dev Builds a dynamic-fee selection result with only the fields
    ///      `populateDynamicFeeQuoteFromState` reads.
    function _quoteWithSpots(uint256 spotBeforeX18, uint256 spotAfterX18, uint256 pifPpm)
        internal
        pure
        returns (DynamicFeeMath.DynamicFeeQuote memory)
    {
        return DynamicFeeMath.DynamicFeeQuote({
            feeBps: 0,
            pifPpm: pifPpm,
            adverseImpactPartBps: 0,
            volatilityPartBps: 0,
            shortImpactPartBps: 0,
            spotBeforeX18: spotBeforeX18,
            spotAfterX18: spotAfterX18,
            isAdverse: false
        });
    }

    // ===========================================================================
    // selectDynamicFee — one selection from the original request curve
    // ===========================================================================
    // The curve is calculated once from the unmodified user request. Fee leg, fee amounts, transformed
    // targets, and price limits do not enter this library API.

    /// @notice Zero amount returns only the launch/base floor and skips all dynamic components.
    function testSelectDynamicFeeZeroAmountReturnsOnlyFeeFloor() external view {
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);

        DynamicFeeMath.DynamicFeeQuote memory quote = DynamicFeeMath.selectDynamicFee(
            _emptyState(),
            _emptyBatch(),
            SQRT_PRICE_1_1,
            SQRT_PRICE_1_1,
            int256(0), // zero amount — must short-circuit before any swap math
            launchFeeBps
        );

        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "zero amount base fee");
        assertEq(quote.pifPpm, 0, "zero amount no pif");
        assertEq(quote.spotBeforeX18, 0, "zero amount no spot before");
        assertEq(quote.spotAfterX18, 0, "zero amount no spot after");
    }

    /// @notice Exact input selects its fee from the full original request curve, not a fee-reduced retry.
    function testSelectDynamicFeeExactInputUsesOriginalRequestCurveOnce() external view {
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);
        uint256 userInputAmount = 10_000 ether;
        OrdinarySwapMath.CurveResult memory originalCurve =
            OrdinarySwapMath.calculateOriginalRequestCurve(LIQUIDITY, SQRT_PRICE_1_1, true, -int256(userInputAmount));

        DynamicFeeMath.DynamicFeeQuote memory quote = DynamicFeeMath.selectDynamicFee(
            _emptyState(),
            _emptyBatch(),
            SQRT_PRICE_1_1,
            originalCurve.postSqrtPriceX96,
            -int256(userInputAmount),
            launchFeeBps
        );

        assertEq(
            quote.pifPpm,
            FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, originalCurve.postSqrtPriceX96),
            "original-request pif"
        );
        assertEq(quote.spotBeforeX18, FeeMath.spotX18FromSqrtPrice(SQRT_PRICE_1_1), "original spot before");
        assertEq(
            quote.spotAfterX18, FeeMath.spotX18FromSqrtPrice(originalCurve.postSqrtPriceX96), "original spot after"
        );
    }

    /// @notice Exact output also selects from the unmodified requested output curve.
    function testSelectDynamicFeeExactOutputUsesOriginalRequestCurveOnce() external view {
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);
        int256 requestedNetOutput = int256(10 ether);
        OrdinarySwapMath.CurveResult memory originalCurve =
            OrdinarySwapMath.calculateOriginalRequestCurve(LIQUIDITY, SQRT_PRICE_1_1, true, requestedNetOutput);

        DynamicFeeMath.DynamicFeeQuote memory quote = DynamicFeeMath.selectDynamicFee(
            _emptyState(),
            _emptyBatch(),
            SQRT_PRICE_1_1,
            originalCurve.postSqrtPriceX96,
            requestedNetOutput,
            launchFeeBps
        );

        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "base fee");
        assertEq(
            quote.pifPpm,
            FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, originalCurve.postSqrtPriceX96),
            "original exact-output pif"
        );
    }

    /// @notice When the launch-fee schedule yields a bps above the dynamic composition, the launch fee must
    ///         floor the result. Exercises both floors: the initial `quote.feeBps` assignment
    ///         (`launchFeeBps > FEE_BASE_BPS ? launchFeeBps : FEE_BASE_BPS`) and the single restore after
    ///         `populate`, which may have lowered the fee toward the dynamic `FEE_BASE_BPS` floor.
    /// @dev The single-selection cases above all pass `launchTimestamp=0`, which makes
    ///      `launchFeeBps == minFeeBps == FEE_BASE_BPS`. This case supplies a higher launch fee so both floor
    ///      branches execute.
    function testSelectDynamicFeeLaunchFeeFloorsAboveDynamic() external {
        // Halfway through the 900s decay window the launch fee is well above FEE_BASE_BPS, so it must
        // dominate the dynamic composition for an empty-state small swap.
        vm.warp(1_000);
        uint40 launchTimestamp = uint40(block.timestamp);
        vm.warp(launchTimestamp + 450);
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), launchTimestamp);
        assertGt(launchFeeBps, DynamicFeeMath.FEE_BASE_BPS, "launch fee above base");

        // Empty state + a 1-ether swap on 1e6 liquidity: the price move is sub-1 ppm, so the dynamic
        // composition stays at FEE_BASE_BPS (adverseImpactPartBps / volatilityPartBps / shortImpactPartBps
        // all round to 0). The launch-fee floor must therefore win.
        OrdinarySwapMath.CurveResult memory originalCurve =
            OrdinarySwapMath.calculateOriginalRequestCurve(LIQUIDITY, SQRT_PRICE_1_1, true, -int256(1 ether));
        DynamicFeeMath.DynamicFeeQuote memory quote = DynamicFeeMath.selectDynamicFee(
            _emptyState(), _emptyBatch(), SQRT_PRICE_1_1, originalCurve.postSqrtPriceX96, -int256(1 ether), launchFeeBps
        );

        // The returned fee equals the launch fee exactly (the dynamic composition never exceeds it), and the
        // launch fee itself matches the normalized exponential decay reference at mid-decay.
        assertEq(quote.feeBps, launchFeeBps, "launch fee floors above dynamic");
        assertEq(quote.feeBps, _expectedLaunchFee(450, 900, 5000, 100), "matches exponential decay curve");
    }

    // ===========================================================================
    // populateDynamicFeeQuoteFromState — branch logic
    // ===========================================================================
    // `populateDynamicFeeQuoteFromState` is the heart of the EWVWAP / volatility / short-impact composition.
    // `selectDynamicFee` invokes it once after precomputing `preVolatilityPartBps` / `preDecayedShortPpm`.
    // Driving it directly with a hand-built quote
    // isolates the two branches: non-adverse early-return, and full adverse composition.

    /// @notice A non-adverse move (spot returning toward the EWVWAP) short-circuits to the base fee and
    ///         zeroes every dynamic part, because such trades are rewarded for reverting mispricing.
    function testPopulateNonAdverseReturnsBaseFee() external {
        vm.warp(1_000);
        IDynamicFeeFacet.DynamicFeeState memory state = _emptyState();
        // Establish EWVWAP history so the adverse check runs (otherwise every move defaults to adverse).
        state.weightedVolume0 = 1;
        state.ewVWAPX18 = 1.0 ether; // spot moving 1.2 → 1.1 approaches 1.0 → non-adverse

        DynamicFeeMath.DynamicFeeQuote memory quote = _quoteWithSpots(1.2 ether, 1.1 ether, 50_000);

        DynamicFeeMath.populateDynamicFeeQuoteFromState(quote, state, _emptyBatch(), 0, 0);

        assertFalse(quote.isAdverse, "non-adverse");
        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "base fee");
        assertEq(quote.adverseImpactPartBps, 0, "no adverse part");
    }

    /// @notice An adverse move (spot moving away from the EWVWAP) composes base + adverse + volatility +
    ///         short-impact parts; a reverting move resets to the base fee via the non-adverse early return.
    function testPopulateAdverseAndRevertingFeeComposition() external {
        vm.warp(1_000);
        IDynamicFeeFacet.DynamicFeeState memory state = _emptyState();
        state.weightedVolume0 = 1;
        state.ewVWAPX18 = 1.0 ether;

        // Adverse: spot 1.0 → 1.2 moves away from EWVWAP 1.0. With effectivePifPpm = 50_000 (no batch
        // augmentation) and empty volatility / short state, the composition is:
        //   satPpm   = mulDiv(50_000, 1e6, 50_000 + 150_000) = 250_000            // PIF saturation curve
        //   dffPpm   = mulDiv(800_000, 250_000, 1e6)        = 200_000            // dynamic-fee ppm ceiling
        //   dynamic  = mulDiv(200_000, 50_000, 1e6)         = 10_000             // × effective PIF
        //   adverseImpactPartBps = 10_000 / (1e6 / 1e4)     = 100                // ppm → bps
        //   short    = mulDiv(30_000, 2_500, 1e6)           = 75                 // (50_000 − 20_000 floor) × coeff
        //   feeBps   = 100 (base) + 100 (adverse) + 0 (vol) + 75 (short) = 275
        DynamicFeeMath.DynamicFeeQuote memory adverseQuote = _quoteWithSpots(1.0 ether, 1.2 ether, 50_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(adverseQuote, state, _emptyBatch(), 0, 0);

        assertTrue(adverseQuote.isAdverse, "adverse");
        assertEq(adverseQuote.adverseImpactPartBps, 100, "adverse part");
        assertEq(adverseQuote.volatilityPartBps, 0, "volatility part");
        assertEq(adverseQuote.shortImpactPartBps, 75, "short part");
        assertEq(adverseQuote.feeBps, 275, "adverse fee composition");

        // Reverting: spot 1.2 → 1.1 moves back toward EWVWAP 1.0 → non-adverse → base fee via early return.
        DynamicFeeMath.DynamicFeeQuote memory revertingQuote = _quoteWithSpots(1.2 ether, 1.1 ether, 50_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(revertingQuote, state, _emptyBatch(), 0, 0);

        assertFalse(revertingQuote.isAdverse, "reverting");
        assertEq(revertingQuote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "reverting fee");
    }

    /// @notice When the projected short impact is at or below `SHORT_FLOOR_PPM`, the short-impact fee part
    ///         is zeroed out — the floor's else branch (`projectedShortPpm <= SHORT_FLOOR_PPM ? 0 : ...`).
    /// @dev The short part is `mulDiv(chargeableShortPpm, SHORT_COEFF_BPS, PPM_BASE)`, and
    ///      `chargeableShortPpm = projectedShortPpm <= SHORT_FLOOR_PPM ? 0 : projectedShortPpm - SHORT_FLOOR_PPM`.
    ///      Here `projectedShortPpm = preDecayedShortPpm(0) + pifPpm(10_000) = 10_000 <= SHORT_FLOOR_PPM(20_000)`,
    ///      so `chargeableShortPpm == 0` and the short part collapses to 0. The trade still runs the full adverse
    ///      path (spot 1.0 → 1.2 away from EWVWAP 1.0), so `feeBps` stays above `FEE_BASE_BPS` — proving the
    ///      zeroed short part came from the floor branch, not the non-adverse early return.
    function testPopulateShortImpact_ZeroWhenProjectedShortAtOrBelowFloor() external {
        vm.warp(1_000);
        IDynamicFeeFacet.DynamicFeeState memory state = _emptyState();
        state.weightedVolume0 = 1;
        state.ewVWAPX18 = 1.0 ether; // spot 1.0 → 1.2 moves away from EWVWAP → adverse

        // pifPpm = 10_000 keeps projectedShortPpm below the floor; preDecayedShortPpm = 0 (5th arg).
        DynamicFeeMath.DynamicFeeQuote memory quote = _quoteWithSpots(1.0 ether, 1.2 ether, 10_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(quote, state, _emptyBatch(), 0, 0);

        assertTrue(quote.isAdverse, "adverse path taken");
        assertEq(quote.shortImpactPartBps, 0, "short floor else-branch zeroes short part");
        assertGt(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "adverse path still ran");
    }

    /// @notice A composed fee above `FEE_MAX_BPS` is truncated to `FEE_MAX_BPS` by the
    ///         `feeBps > FEE_MAX_BPS ? FEE_MAX_BPS : feeBps` ceiling ternary.
    /// @dev `preVolatilityPartBps` is an external input (assigned straight to `quote.volatilityPartBps`), which
    ///      makes it the only clean lever for crossing the ceiling: under normal inputs the real composition
    ///      tops out near 100 (base) + 600 (adverse, pif at the PIF cap) + 50 (vol max) + 200 (short max) = 950,
    ///      well below 10_000. Feeding a deliberately oversized `preVolatilityPartBps` forces the composition
    ///      (100 base + 100 adverse + 10_001 vol + 75 short = 10_276) past the ceiling to exercise this
    ///      defensive (otherwise unreachable) branch.
    function testPopulateFeeBps_TruncatesToCeilingWhenCompositionExceedsMax() external {
        vm.warp(1_000);
        IDynamicFeeFacet.DynamicFeeState memory state = _emptyState();
        state.weightedVolume0 = 1;
        state.ewVWAPX18 = 1.0 ether; // adverse, mirroring the pif=50_000 case above

        // pif=50_000 yields adverseImpactPartBps=100 and shortImpactPartBps=75 (pinned by the adverse test
        // above); the oversized volatility input then drives the sum past FEE_MAX_BPS.
        DynamicFeeMath.DynamicFeeQuote memory quote = _quoteWithSpots(1.0 ether, 1.2 ether, 50_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(quote, state, _emptyBatch(), 10_001, 0);

        assertEq(quote.feeBps, DynamicFeeMath.FEE_MAX_BPS, "composed fee above ceiling truncates to FEE_MAX_BPS");
    }

    // ===========================================================================
    // quoteLaunchFeeBps — exponential decay
    // ===========================================================================

    /// @notice Pre-launch (launchTimestamp=0) charges only the minimum fee — the decay curve is not entered.
    function testQuoteLaunchFeeReturnsMinFeeWhenLaunchTimestampIsZero() external view {
        uint256 feeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);
        assertEq(feeBps, 100, "unlaunched pool charges min fee");
    }

    /// @notice Halfway through the decay window the launch fee follows the normalized exponential curve, not
    ///         a linear ramp: the surcharge is heavier early and tapers toward the minimum.
    function testQuoteLaunchFeeUsesExponentialDecayAtMidDecay() external {
        uint40 launchTimestamp = uint40(block.timestamp); // 1 after setUp
        vm.warp(launchTimestamp + 450); // halfway through the 900-second decay window

        uint256 feeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), launchTimestamp);
        assertEq(feeBps, _expectedLaunchFee(450, 900, 5000, 100), "exponential launch fee");
    }

    // ===========================================================================
    // DynamicFeeMath pure / view helpers — direct boundary coverage
    // ===========================================================================
    // Each helper is pinned at its documented contract edges.

    /// @notice `volatilityDeltaSteps` returns 0 for degenerate inputs and yields symmetric step counts for
    ///         up/down moves of equal magnitude, because it compares the squared-price ratio (direction-agnostic).
    function testVolatilityDeltaStepsBoundaries() external pure {
        assertEq(DynamicFeeMath.volatilityDeltaSteps(0, SQRT_PRICE_1_1, 1), 0, "zero reference");
        assertEq(DynamicFeeMath.volatilityDeltaSteps(SQRT_PRICE_1_1, 0, 1), 0, "zero current");
        assertEq(DynamicFeeMath.volatilityDeltaSteps(SQRT_PRICE_1_1, SQRT_PRICE_1_1, 1), 0, "equal prices");
        assertEq(DynamicFeeMath.volatilityDeltaSteps(SQRT_PRICE_1_1, SQRT_PRICE_1_1, 0), 0, "zero step size");

        // A 1% price move (upper/lower = 101/100) with a 1 bps step:
        //   sqrtRatioX18 = mulDiv(101, 1e18, 100) = 1.01e18
        //   steps        = mulDiv(1.01e18 − 1e18, 2 * 10000, 1 * 1e18)
        //                = mulDiv(1e16, 20000, 1e18) = 200
        // The factor 2 reflects "one step = a 1 bps move on each leg" (see the helper's @dev).
        assertEq(DynamicFeeMath.volatilityDeltaSteps(100, 101, 1), 200, "1% up move step count");
        assertEq(DynamicFeeMath.volatilityDeltaSteps(101, 100, 1), 200, "1% down move step count (symmetric)");
    }

    /// @notice `decayLinearPpm` decays linearly to zero over the window. It returns the full accumulator at
    ///         or before the anchor timestamp (same-block swaps must not decay) and zero once the window ends.
    function testDecayLinearPpmBoundaries() external {
        vm.warp(1_000);
        assertEq(DynamicFeeMath.decayLinearPpm(0, 985, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC), 0, "zero accumulator");
        assertEq(DynamicFeeMath.decayLinearPpm(30_000, 0, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC), 0, "zero anchor ts");
        assertEq(DynamicFeeMath.decayLinearPpm(30_000, 985, 0), 0, "zero window");

        // Elapsed == window → fully decayed.
        assertEq(
            DynamicFeeMath.decayLinearPpm(
                30_000, 1_000 - DynamicFeeMath.SHORT_DECAY_WINDOW_SEC, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC
            ),
            0,
            "elapsed == window fully decayed"
        );
        // block.timestamp == lastTs → no time has passed, full value retained (same-block invariant).
        assertEq(
            DynamicFeeMath.decayLinearPpm(30_000, 1_000, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC),
            30_000,
            "same ts full value"
        );
        // Linear mid-window: elapsed=7s of a 15s window → mulDiv(30_000, 15−7, 15) = mulDiv(30_000, 8, 15) =
        // 16_000 (8/15 of the original accumulator remains).
        assertEq(
            DynamicFeeMath.decayLinearPpm(30_000, 1_000 - 7, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC),
            16_000,
            "linear partial decay"
        );
    }

    /// @notice `volatilityRefreshPlan` gates the anchor refresh on a 10-second filter period and seeds the
    ///         carry accumulator with the half-decayed deviation (50% factor) when the decay window (60s) has
    ///         not yet elapsed, else resets the carry to 0. The refresh decision is shared between `quote`
    ///         (preview) and `_refreshVolatilityAnchorAndCarry` (execution); this pins every branch so the two
    ///         call sites cannot silently diverge.
    function testVolatilityRefreshPlanBoundaries() external {
        vm.warp(1_000);
        uint24 acc = 1_000;
        uint24 halfDecayed = uint24(FullMath.mulDiv(acc, DynamicFeeMath.VOL_DECAY_FACTOR_BPS, FeeMath.BPS_BASE));

        // 1. elapsed < 10 (filter period) → no refresh, zero carry.
        (bool shouldRefresh, uint24 refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(995, acc);
        assertFalse(shouldRefresh, "elapsed 5 no refresh");
        assertEq(refreshedCarry, 0, "elapsed 5 zero carry");

        // 2. elapsed == 10 (filter boundary) → refresh, half-decayed carry.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(990, acc);
        assertTrue(shouldRefresh, "elapsed 10 refresh");
        assertEq(refreshedCarry, halfDecayed, "elapsed 10 half-decayed carry");
        assertEq(refreshedCarry, 500, "elapsed 10 carry value");

        // 3. elapsed == 59 (decay branch end) → refresh, half-decayed carry.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(941, acc);
        assertTrue(shouldRefresh, "elapsed 59 refresh");
        assertEq(refreshedCarry, halfDecayed, "elapsed 59 half-decayed carry");

        // 4. elapsed == 60 (reset boundary) → refresh, zero carry (60 < 60 is false).
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(940, acc);
        assertTrue(shouldRefresh, "elapsed 60 refresh");
        assertEq(refreshedCarry, 0, "elapsed 60 zero carry");

        // 5. elapsed > 60 → refresh, zero carry.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(939, acc);
        assertTrue(shouldRefresh, "elapsed 61 refresh");
        assertEq(refreshedCarry, 0, "elapsed 61 zero carry");

        // 6. lastMoveTs == 0 → refresh (elapsed >= 10), zero carry (lastMoveTs != 0 short-circuit).
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(0, acc);
        assertTrue(shouldRefresh, "zero lastMoveTs refresh");
        assertEq(refreshedCarry, 0, "zero lastMoveTs zero carry");

        // 7. block.timestamp == lastMoveTs (elapsed 0) → no refresh.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(uint40(block.timestamp), acc);
        assertFalse(shouldRefresh, "same ts no refresh");
        assertEq(refreshedCarry, 0, "same ts zero carry");

        // 8. block.timestamp < lastMoveTs (future lastMoveTs, elapsed 0) → no refresh.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(uint40(block.timestamp) + 5, acc);
        assertFalse(shouldRefresh, "future lastMoveTs no refresh");
        assertEq(refreshedCarry, 0, "future lastMoveTs zero carry");

        // 9. volDeviationAccumulator == 0 (decay branch) → refresh, zero carry.
        (shouldRefresh, refreshedCarry) = DynamicFeeMath.volatilityRefreshPlan(990, 0);
        assertTrue(shouldRefresh, "zero accumulator refresh");
        assertEq(refreshedCarry, 0, "zero accumulator zero carry");
    }

    /// @notice `normalizedLaunchDecayWad` is exactly 1e18 at elapsed=0, exactly 0 at elapsed=duration, and
    ///         follows the `wadExp` curve in between. The endpoints are forced by subtracting the end
    ///         exponential and renormalizing, so the launch fee hits `minFeeBps` exactly at the window end.
    function testNormalizedLaunchDecayWadBoundaries() external pure {
        assertEq(DynamicFeeMath.normalizedLaunchDecayWad(0, 900), 1e18, "full weight at start");

        // At elapsed=duration the two exponentials cancel → zero weight.
        assertEq(DynamicFeeMath.normalizedLaunchDecayWad(900, 900), 0, "zero weight at end");

        // Mid-window reference computed from the same wadExp formula the helper uses.
        int256 expAtElapsed = wadExp(-int256(FullMath.mulDiv(450, 4e18, 900))); // wadExp(-2e18)
        int256 expAtEnd = wadExp(-4e18);
        uint256 expectedMid = uint256((expAtElapsed - expAtEnd) * 1e18 / (1e18 - expAtEnd));
        assertEq(DynamicFeeMath.normalizedLaunchDecayWad(450, 900), expectedMid, "exponential mid weight");
    }

    // ===========================================================================
    // Reference helpers
    // ===========================================================================

    /// @dev Independent reference for the launch fee curve, mirroring
    ///      `DynamicFeeMath.normalizedLaunchDecayWad` plus the
    ///      `minFeeBps + mulDiv(startFeeBps − minFeeBps, decayWad, 1e18)` composition.
    function _expectedLaunchFee(uint256 elapsed, uint256 duration, uint256 startFeeBps, uint256 minFeeBps)
        internal
        pure
        returns (uint256)
    {
        if (elapsed >= duration) return minFeeBps;
        int256 expAtElapsedWad = wadExp(-int256(FullMath.mulDiv(elapsed, 4e18, duration)));
        int256 expAtEndWad = wadExp(-4e18);
        uint256 normalizedWad = uint256((expAtElapsedWad - expAtEndWad) * 1e18 / (1e18 - expAtEndWad));
        return minFeeBps + FullMath.mulDiv(startFeeBps - minFeeBps, normalizedWad, 1e18);
    }
}
