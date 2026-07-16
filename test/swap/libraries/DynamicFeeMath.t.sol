// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {wadExp} from "solmate/utils/SignedWadMath.sol";

import {DynamicFeeMath} from "../../../src/swap/libraries/DynamicFeeMath.sol";
import {FeeMath} from "../../../src/swap/libraries/FeeMath.sol";
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

    /// @dev Builds a `PreparedSwapFee` with only the fields `populateDynamicFeeQuoteFromState` reads, so the
    ///      populate branch logic can be tested without running the full convergence loop.
    function _quoteWithSpots(uint256 spotBeforeX18, uint256 spotAfterX18, uint256 pifPpm)
        internal
        pure
        returns (IDynamicFeeFacet.PreparedSwapFee memory)
    {
        return IDynamicFeeFacet.PreparedSwapFee({
            feeBps: 0,
            pifPpm: pifPpm,
            adverseImpactPartBps: 0,
            volatilityPartBps: 0,
            shortImpactPartBps: 0,
            estimatedInputAmount: 0,
            estimatedOutputAmount: 0,
            estimatedGrossOutputAmount: 0,
            spotBeforeX18: spotBeforeX18,
            spotAfterX18: spotAfterX18,
            isAdverse: false
        });
    }

    // ===========================================================================
    // estimateDynamicFeeQuote — precise boundaries
    // ===========================================================================
    // Drive the algorithm directly with `state` and `batch` memory arguments so early-return and iteration
    // boundaries are asserted independently of storage wiring.

    /// @notice Zero liquidity short-circuits to the base fee and zero swap amounts, regardless of input.
    function testEstimateDynamicFeeQuoteZeroLiquidityReturnsBaseFeeAndZeroAmounts() external view {
        // launchTimestamp=0 → launchFeeBps = minFeeBps = 100 (no launch surcharge).
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);

        IDynamicFeeFacet.PreparedSwapFee memory quote = DynamicFeeMath.estimateDynamicFeeQuote(
            _emptyState(),
            _emptyBatch(),
            0, // zero liquidity — must short-circuit before any swap math
            SQRT_PRICE_1_1,
            true, // zeroForOne
            -int256(1 ether),
            true, // feeOnInput
            launchFeeBps
        );

        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "zero liquidity base fee");
        assertEq(quote.estimatedInputAmount, 0, "zero liquidity no input");
        assertEq(quote.estimatedOutputAmount, 0, "zero liquidity no output");
        assertEq(quote.estimatedGrossOutputAmount, 0, "zero liquidity no gross output");
    }

    /// @notice Zero amount specified short-circuits to the base fee and zero swap amounts.
    function testEstimateDynamicFeeQuoteZeroAmountSpecifiedReturnsBaseFeeAndZeroAmounts() external view {
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);

        IDynamicFeeFacet.PreparedSwapFee memory quote = DynamicFeeMath.estimateDynamicFeeQuote(
            _emptyState(),
            _emptyBatch(),
            LIQUIDITY,
            SQRT_PRICE_1_1,
            true,
            int256(0), // zero amount — must short-circuit before any swap math
            true,
            launchFeeBps
        );

        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "zero amount base fee");
        assertEq(quote.estimatedInputAmount, 0, "zero amount no input");
        assertEq(quote.estimatedOutputAmount, 0, "zero amount no output");
        assertEq(quote.estimatedGrossOutputAmount, 0, "zero amount no gross output");
    }

    /// @notice Exact-input path iterates so the reported input equals the net-of-fee amount that actually
    ///         reaches the pool, and the reported output / pifPpm reflect that smaller net input.
    function testEstimateDynamicFeeQuoteExactInputUsesNetPoolInputAfterFees() external view {
        // launchTimestamp=0 (pre-launch): launchFeeBps = minFeeBps = 100, so the dynamic fee dominates.
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);
        uint256 userInputAmount = 10_000 ether;

        IDynamicFeeFacet.PreparedSwapFee memory quote = DynamicFeeMath.estimateDynamicFeeQuote(
            _emptyState(),
            _emptyBatch(),
            LIQUIDITY,
            SQRT_PRICE_1_1,
            true,
            -int256(userInputAmount),
            true, // feeOnInput
            launchFeeBps
        );

        // Self-consistent expectation: the net pool input is the user input minus the input-side fee taken at
        // the converged fee rate. The convergence loop's exit condition is exactly `netPoolInput ==
        // estimatedInputAmount`, so this must hold regardless of the precise fee bps.
        uint256 expectedNetPoolInput =
            userInputAmount - FullMath.mulDiv(userInputAmount, quote.feeBps, FeeMath.BPS_BASE);
        uint160 expectedPostSqrtPrice =
            SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_PRICE_1_1, LIQUIDITY, expectedNetPoolInput, true);
        uint256 expectedOutputAmount =
            SqrtPriceMath.getAmount1Delta(expectedPostSqrtPrice, SQRT_PRICE_1_1, LIQUIDITY, false);
        // First-pass post price (from the full user input, before fee) — the loop must move off this.
        uint160 firstPassPostSqrtPrice =
            SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_PRICE_1_1, LIQUIDITY, userInputAmount, true);

        assertLt(quote.estimatedInputAmount, userInputAmount, "not first iteration input");
        assertEq(quote.estimatedInputAmount, expectedNetPoolInput, "net pool input");
        assertLt(quote.estimatedOutputAmount, userInputAmount, "not gross-output shortcut");
        assertEq(quote.estimatedOutputAmount, expectedOutputAmount, "net-input output");
        assertLt(quote.pifPpm, FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, firstPassPostSqrtPrice), "not first pif");
        assertEq(quote.pifPpm, FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, expectedPostSqrtPrice), "net pif");
    }

    /// @notice Exact-output path grosses the requested output up by the output-side protocol fee, so the pool
    ///         receives enough to pay both the user's requested output and the protocol share. The user
    ///         receives exactly the requested net output.
    function testEstimateDynamicFeeQuoteExactOutputGrossesOutputSideProtocolFee() external view {
        uint256 launchFeeBps = DynamicFeeMath.quoteLaunchFeeBps(_launchFeeConfig(), 0);

        IDynamicFeeFacet.PreparedSwapFee memory quote = DynamicFeeMath.estimateDynamicFeeQuote(
            _emptyState(),
            _emptyBatch(),
            LIQUIDITY,
            SQRT_PRICE_1_1,
            true,
            int256(10 ether), // exact output
            false, // feeOnOutput — output side is grossed up
            launchFeeBps
        );

        // 10 ether requested output on 1e6 liquidity moves the price by < 1 ppm, so pifPpm rounds to 0 and the
        // dynamic fee stays at the 100 bps base; the only gross-up is the output-side protocol share
        // (protocolFeeBps(100) = mulDiv(100, 3500, 10000) = 35 bps).
        uint256 expectedGrossOutputAmount = 10_035_122_930_255_895_635;
        uint256 expectedOutputSideProtocolFee = 35_122_930_255_895_635;

        assertEq(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "base fee");
        assertEq(quote.estimatedOutputAmount, 10 ether, "net output");
        assertEq(quote.estimatedGrossOutputAmount, expectedGrossOutputAmount, "gross output includes output-side fee");
        assertEq(
            quote.estimatedGrossOutputAmount - quote.estimatedOutputAmount,
            expectedOutputSideProtocolFee,
            "reserved output-side protocol fee"
        );
        assertGt(quote.estimatedInputAmount, 0, "input estimated");
    }

    /// @notice When the launch-fee schedule yields a bps above the dynamic composition, the launch fee must
    ///         floor the result. Exercises both floors: the initial `quote.feeBps` assignment
    ///         (`launchFeeBps > FEE_BASE_BPS ? launchFeeBps : FEE_BASE_BPS`) and the per-iteration restore
    ///         (`if (launchFeeBps > quote.feeBps) quote.feeBps = launchFeeBps`), which `populate` may have
    ///         lowered toward the dynamic `FEE_BASE_BPS` floor in between.
    /// @dev The four `testEstimateDynamicFeeQuote*` cases above all pass `launchTimestamp=0`, which makes
    ///      `launchFeeBps == minFeeBps == FEE_BASE_BPS`. This case supplies a higher launch fee so both floor
    ///      branches execute.
    function testEstimateDynamicFeeQuoteLaunchFeeFloorsAboveDynamic() external {
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
        IDynamicFeeFacet.PreparedSwapFee memory quote = DynamicFeeMath.estimateDynamicFeeQuote(
            _emptyState(), _emptyBatch(), LIQUIDITY, SQRT_PRICE_1_1, true, -int256(1 ether), true, launchFeeBps
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
    // It is invoked inside the convergence loop with `preVolatilityPartBps` / `preDecayedShortPpm` already
    // precomputed by the caller (they are loop-invariant). Driving it directly with a hand-built quote
    // isolates the two branches: non-adverse early-return, and full adverse composition.

    /// @notice A non-adverse move (spot returning toward the EWVWAP) short-circuits to the base fee and
    ///         zeroes every dynamic part, because such trades are rewarded for reverting mispricing.
    function testPopulateNonAdverseReturnsBaseFee() external {
        vm.warp(1_000);
        IDynamicFeeFacet.DynamicFeeState memory state = _emptyState();
        // Establish EWVWAP history so the adverse check runs (otherwise every move defaults to adverse).
        state.weightedVolume0 = 1;
        state.ewVWAPX18 = 1.0 ether; // spot moving 1.2 → 1.1 approaches 1.0 → non-adverse

        IDynamicFeeFacet.PreparedSwapFee memory quote = _quoteWithSpots(1.2 ether, 1.1 ether, 50_000);

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
        IDynamicFeeFacet.PreparedSwapFee memory adverseQuote = _quoteWithSpots(1.0 ether, 1.2 ether, 50_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(adverseQuote, state, _emptyBatch(), 0, 0);

        assertTrue(adverseQuote.isAdverse, "adverse");
        assertEq(adverseQuote.adverseImpactPartBps, 100, "adverse part");
        assertEq(adverseQuote.volatilityPartBps, 0, "volatility part");
        assertEq(adverseQuote.shortImpactPartBps, 75, "short part");
        assertEq(adverseQuote.feeBps, 275, "adverse fee composition");

        // Reverting: spot 1.2 → 1.1 moves back toward EWVWAP 1.0 → non-adverse → base fee via early return.
        IDynamicFeeFacet.PreparedSwapFee memory revertingQuote = _quoteWithSpots(1.2 ether, 1.1 ether, 50_000);
        DynamicFeeMath.populateDynamicFeeQuoteFromState(revertingQuote, state, _emptyBatch(), 0, 0);

        assertFalse(revertingQuote.isAdverse, "reverting");
        assertEq(revertingQuote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "reverting fee");
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

    /// @notice `estimateSwapFlowAndPostPrice` routes the input/output amount computation by direction and
    ///         swaps between the v4 input-specified and output-specified post-price helpers. Zero amount is
    ///         an early return leaving the price unchanged.
    function testEstimateSwapFlowAndPostPriceBoundaries() external pure {
        uint256 amt = 1 ether;
        int256 exactInput = -int256(amt);
        int256 exactOutput = int256(amt);

        // Zero amount: early return, price unchanged.
        (uint256 in0, uint256 out0, uint256 gross0, uint160 post0) =
            DynamicFeeMath.estimateSwapFlowAndPostPrice(LIQUIDITY, SQRT_PRICE_1_1, true, int256(0));
        assertEq(in0, 0, "zero input");
        assertEq(out0, 0, "zero output");
        assertEq(gross0, 0, "zero gross");
        assertEq(uint256(post0), uint256(SQRT_PRICE_1_1), "zero amount keeps price");

        // Exact input, zeroForOne=true: input drives the post price; output is the amount1 delta (round down).
        uint160 postZfoExp = SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_PRICE_1_1, LIQUIDITY, amt, true);
        uint256 outZfoExp = SqrtPriceMath.getAmount1Delta(postZfoExp, SQRT_PRICE_1_1, LIQUIDITY, false);
        (uint256 inZfo, uint256 outZfo, uint256 grossZfo, uint160 postZfo) =
            DynamicFeeMath.estimateSwapFlowAndPostPrice(LIQUIDITY, SQRT_PRICE_1_1, true, exactInput);
        assertEq(inZfo, amt, "zfo input amount");
        assertEq(outZfo, outZfoExp, "zfo output delta");
        assertEq(grossZfo, outZfoExp, "zfo gross equals output");
        assertEq(uint256(postZfo), uint256(postZfoExp), "zfo post price");

        // Exact input, zeroForOne=false: output is the amount0 delta; the argument order to getAmount0Delta
        // flips relative to the zeroForOne branch above.
        uint160 postOfzExp = SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_PRICE_1_1, LIQUIDITY, amt, false);
        uint256 outOfzExp = SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, postOfzExp, LIQUIDITY, false);
        (, uint256 outOfz,, uint160 postOfz) =
            DynamicFeeMath.estimateSwapFlowAndPostPrice(LIQUIDITY, SQRT_PRICE_1_1, false, exactInput);
        assertEq(outOfz, outOfzExp, "ofz output delta");
        assertEq(uint256(postOfz), uint256(postOfzExp), "ofz post price");

        // Exact output, zeroForOne=true: output drives the post price via getNextSqrtPriceFromOutput; the
        // gross output equals the requested output (no input-side gross-up at this layer).
        uint160 postOutExp = SqrtPriceMath.getNextSqrtPriceFromOutput(SQRT_PRICE_1_1, LIQUIDITY, amt, true);
        uint256 inOutExp = SqrtPriceMath.getAmount0Delta(postOutExp, SQRT_PRICE_1_1, LIQUIDITY, true);
        (uint256 inOut,, uint256 grossOut, uint160 postOut) =
            DynamicFeeMath.estimateSwapFlowAndPostPrice(LIQUIDITY, SQRT_PRICE_1_1, true, exactOutput);
        assertEq(inOut, inOutExp, "exact-output input");
        assertEq(grossOut, amt, "exact-output gross equals requested");
        assertEq(uint256(postOut), uint256(postOutExp), "exact-output post price");
    }

    /// @notice `grossUpFeeFromNetOutput` returns 0 for trivial inputs, saturates at uint256 max once the fee
    ///         reaches 100% (avoiding a divide-by-zero), and otherwise rounds the gross UP so that taking
    ///         `feeBps` off the gross leaves at least the requested net output (payer-favorable rounding).
    function testGrossUpFeeFromNetOutputBoundaries() external pure {
        assertEq(DynamicFeeMath.grossUpFeeFromNetOutput(0, 35), 0, "zero net returns zero");
        assertEq(DynamicFeeMath.grossUpFeeFromNetOutput(10 ether, 0), 0, "zero fee returns zero");
        // feeBps >= FeeMath.BPS_BASE (100%) would divide by zero; the helper saturates instead.
        assertEq(
            DynamicFeeMath.grossUpFeeFromNetOutput(10 ether, FeeMath.BPS_BASE), type(uint256).max, ">=100% saturates"
        );

        // 35 bps on 10 ether: ceil(10e18 * 10000 / 9965) − 10e18. The rounding-up protects the payer's net.
        uint256 expectedFee = FullMath.mulDivRoundingUp(10 ether, FeeMath.BPS_BASE, FeeMath.BPS_BASE - 35) - 10 ether;
        assertEq(DynamicFeeMath.grossUpFeeFromNetOutput(10 ether, 35), expectedFee, "normal gross-up");
        assertEq(expectedFee, 35_122_930_255_895_635, "cross-check 35 bps fee amount");
    }

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
