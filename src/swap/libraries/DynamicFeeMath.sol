// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {wadExp} from "solmate/utils/SignedWadMath.sol";

import {FeeMath} from "./FeeMath.sol";
import {IDynamicFeeFacet} from "../interfaces/IDynamicFeeFacet.sol";

/// @title DynamicFeeMath
/// @notice Dynamic-fee algorithms and the shared volatility refresh helper.
/// @dev This library holds the EWVWAP / volatility-deviation / short-impact / address-batch math, plus the
///      shared storage-writing volatility refresh (`refreshVolatilityAnchorAndCarry`), so the facet stays a
///      thin external entry shell. `FeeMath.BPS_BASE` and `FeeMath.PPM_BASE` remain the single source of
///      truth for common precision constants. Every function is `internal` and inlines into its caller.
///      - `refreshVolatilityAnchorAndCarry` intentionally takes a `storage` reference so both
///        `DynamicFeeFacet` and `SettlementFacet` write directly into the shared hook namespace, avoiding a
///        memory copy and keeping the storage-writing refresh in one place.
///      - Other helpers such as `estimateDynamicFeeQuote` continue to accept `memory` state so the `quote`
///        preview can run read-only without touching storage.
library DynamicFeeMath {
    // -----------------------------------------------------------------
    // Algorithm constants
    // -----------------------------------------------------------------
    // Values are FROZEN by the dynamic-fee invariant; do not retune without re-running the simulation suite.
    uint24 internal constant FEE_ALPHA = 500_000;
    uint24 internal constant FEE_DFF_MAX_PPM = 800_000;
    int256 internal constant LAUNCH_FEE_EXP_SHAPE_WAD = 4e18;
    uint24 internal constant FEE_BASE_BPS = 100;
    uint24 internal constant FEE_MAX_BPS = 10_000;
    uint24 internal constant VOL_DEVIATION_STEP_BPS = 1;
    uint24 internal constant VOL_FILTER_PERIOD_SEC = 10;
    uint24 internal constant VOL_DECAY_PERIOD_SEC = 60;
    uint24 internal constant VOL_DECAY_FACTOR_BPS = 5_000;
    uint24 internal constant SHORT_DECAY_WINDOW_SEC = 15;
    uint24 internal constant SHORT_COEFF_BPS = 2_500;
    uint24 internal constant SHORT_FLOOR_PPM = 20_000;
    uint24 internal constant SHORT_CAP_PPM = 100_000;
    uint24 internal constant VOL_INCREMENT_PER_STEP = 1_000;
    uint256 internal constant ADDRESS_BATCH_WINDOW_SEC = 3;

    // -----------------------------------------------------------------
    // View algorithms
    // -----------------------------------------------------------------

    /// @notice Returns the launch-fee bps for a pool given its launch-fee schedule and launch time.
    /// @dev The fee decays exponentially from `startFeeBps` to `minFeeBps` over `decayDurationSeconds`,
    ///      normalized so the curve hits `minFeeBps` exactly at the end of the window. Pre-launch
    ///      (`launchTimestamp == 0`) and post-decay paths short-circuit to `minFeeBps`.
    function quoteLaunchFeeBps(IDynamicFeeFacet.LaunchFeeConfig memory config, uint40 launchTimestamp)
        internal
        view
        returns (uint256 feeBps)
    {
        if (launchTimestamp == 0) return config.minFeeBps;
        uint256 elapsed = block.timestamp > launchTimestamp ? block.timestamp - launchTimestamp : 0;
        if (elapsed >= config.decayDurationSeconds) return config.minFeeBps;
        // This normalized exponential decay is part of the launch-fee invariant.
        uint256 decayWad = normalizedLaunchDecayWad(elapsed, config.decayDurationSeconds);
        return config.minFeeBps + FullMath.mulDiv(config.startFeeBps - config.minFeeBps, decayWad, 1e18);
    }

    /// @notice Estimates the dynamic swap fee quote by fixed-point iteration of fee-vs-swap-amount coupling.
    /// @dev Entry point for both `prepareSwapFee` (storage-backed) and `quote` (memory-backed) paths.
    ///      Loop-invariant quantities (`preVolatilityPartBps`, `preDecayedShortPpm`) are precomputed once
    ///      because `state.volDeviationAccumulator` and `state.shortImpactPpm` are unchanged inside the loop.
    function estimateDynamicFeeQuote(
        IDynamicFeeFacet.DynamicFeeState memory state,
        IDynamicFeeFacet.AddressBatchState memory senderBatchState,
        uint128 liquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified,
        bool feeOnInput,
        uint256 launchFeeBps
    ) internal view returns (IDynamicFeeFacet.PreparedSwapFee memory quote) {
        quote.feeBps = launchFeeBps > FEE_BASE_BPS ? launchFeeBps : FEE_BASE_BPS;
        if (amountSpecified == 0 || liquidity == 0) return quote;

        int256 workingAmountSpecified = amountSpecified;
        uint256 userInputAmount = amountSpecified < 0 ? uint256(-amountSpecified) : 0;
        uint256 requestedNetOutputAmount = amountSpecified > 0 ? uint256(amountSpecified) : 0;
        uint256 spotBeforeX18 = FeeMath.spotX18FromSqrtPrice(preSqrtPriceX96);
        // preVolatilityPartBps and preDecayedShortPpm are loop-invariant (state.volDeviationAccumulator /
        // state.shortImpactPpm are unchanged inside the loop); precompute once to avoid per-iteration recomputation.
        uint256 preVolatilityPartBps = FeeMath.volatilitySqrtFeeBps(state.volDeviationAccumulator);
        uint256 preDecayedShortPpm = decayLinearPpm(state.shortImpactPpm, state.shortLastTs, SHORT_DECAY_WINDOW_SEC);

        // Fixed-point iteration: fee and swap amount are mutually dependent — fee reduces the
        // net amount reaching the pool (input path) or requires grossing up the requested output
        // (output path). Each iteration re-estimates the swap with the fee-adjusted amount until
        // the pool's actual I/O matches what the fee was computed from. Typically converges in
        // 1–2 rounds; 3 is a safety cap. If still divergent after 3 rounds, the last estimate
        // is returned (the fallback after the loop handles the output-specified case).
        for (uint256 i = 0; i < 3; ++i) {
            bool converged;
            (quote, workingAmountSpecified, converged) = estimateDynamicFeeQuoteIter(
                quote,
                state,
                senderBatchState,
                liquidity,
                preSqrtPriceX96,
                spotBeforeX18,
                preVolatilityPartBps,
                preDecayedShortPpm,
                zeroForOne,
                amountSpecified,
                workingAmountSpecified,
                userInputAmount,
                requestedNetOutputAmount,
                feeOnInput,
                launchFeeBps
            );
            if (quote.estimatedInputAmount == 0) return quote;
            if (converged) return quote;
        }

        if (amountSpecified > 0 && !feeOnInput) quote.estimatedOutputAmount = requestedNetOutputAmount;
    }

    /// @dev Single iteration of the iterative dynamic fee quote convergence loop.
    ///      Returns the updated quote, the next `workingAmountSpecified`, and whether the loop has
    ///      converged (caller should return). A non-converged iteration may still produce a zero
    ///      next `workingAmountSpecified` (e.g. fee consumes the entire input), so convergence is
    ///      signaled explicitly via the bool rather than reusing the amount value.
    function estimateDynamicFeeQuoteIter(
        IDynamicFeeFacet.PreparedSwapFee memory quote,
        IDynamicFeeFacet.DynamicFeeState memory state,
        IDynamicFeeFacet.AddressBatchState memory senderBatchState,
        uint128 liquidity,
        uint160 preSqrtPriceX96,
        uint256 spotBeforeX18,
        uint256 preVolatilityPartBps,
        uint256 preDecayedShortPpm,
        bool zeroForOne,
        int256 amountSpecified,
        int256 workingAmountSpecified,
        uint256 userInputAmount,
        uint256 requestedNetOutputAmount,
        bool feeOnInput,
        uint256 launchFeeBps
    ) internal view returns (IDynamicFeeFacet.PreparedSwapFee memory, int256 nextWorkingAmount, bool converged) {
        uint160 postSqrtPriceX96;
        (quote.estimatedInputAmount, quote.estimatedOutputAmount, quote.estimatedGrossOutputAmount, postSqrtPriceX96) =
            estimateSwapFlowAndPostPrice(liquidity, preSqrtPriceX96, zeroForOne, workingAmountSpecified);
        if (quote.estimatedInputAmount == 0) return (quote, 0, true);

        quote.spotBeforeX18 = spotBeforeX18;
        quote.spotAfterX18 = FeeMath.spotX18FromSqrtPrice(postSqrtPriceX96);
        quote.pifPpm = FeeMath.priceMovePpmCapped(preSqrtPriceX96, postSqrtPriceX96);
        populateDynamicFeeQuoteFromState(quote, state, senderBatchState, preVolatilityPartBps, preDecayedShortPpm);

        if (launchFeeBps > quote.feeBps) quote.feeBps = launchFeeBps;

        if (amountSpecified < 0) {
            uint256 inputSideFeeBps = feeOnInput ? quote.feeBps : FeeMath.lpFeeBps(quote.feeBps);
            uint256 inputSideFeeAmount = FeeMath.feeOnAmount(userInputAmount, inputSideFeeBps);
            uint256 netPoolInputAmount = userInputAmount > inputSideFeeAmount ? userInputAmount - inputSideFeeAmount : 0;
            // Fee fully consuming the input (netPoolInputAmount == 0) is NOT convergence; the loop
            // must continue so the next iteration estimates with zero input and reports failure.
            if (netPoolInputAmount == quote.estimatedInputAmount) return (quote, 0, true);
            return (quote, -int256(netPoolInputAmount), false);
        }

        if (feeOnInput) return (quote, 0, true);
        uint256 grossedOutputAmount = requestedNetOutputAmount
            + grossUpFeeFromNetOutput(requestedNetOutputAmount, FeeMath.protocolFeeBps(quote.feeBps));
        if (grossedOutputAmount == quote.estimatedGrossOutputAmount) {
            quote.estimatedOutputAmount = requestedNetOutputAmount;
            return (quote, 0, true);
        }
        return (quote, int256(grossedOutputAmount), false);
    }

    /// @dev `preVolatilityPartBps` and `preDecayedShortPpm` are loop-invariant: they depend only on
    ///      `state.volDeviationAccumulator` and `state.shortImpactPpm`, which are unchanged inside the
    ///      convergence loop. Callers precompute them once to avoid redundant recomputation per iteration.
    function populateDynamicFeeQuoteFromState(
        IDynamicFeeFacet.PreparedSwapFee memory quote,
        IDynamicFeeFacet.DynamicFeeState memory state,
        IDynamicFeeFacet.AddressBatchState memory senderBatchState,
        uint256 preVolatilityPartBps,
        uint256 preDecayedShortPpm
    ) internal view {
        bool hasHistory = state.weightedVolume0 > 0 && state.ewVWAPX18 > 0;
        quote.isAdverse = hasHistory
            ? absDiff(quote.spotAfterX18, state.ewVWAPX18) > absDiff(quote.spotBeforeX18, state.ewVWAPX18)
            : true;
        if (hasHistory && !quote.isAdverse) {
            quote.feeBps = FEE_BASE_BPS;
            return;
        }

        uint256 effectivePifPpm = quote.pifPpm;
        if (
            senderBatchState.batchStartTs > 0
                && block.timestamp - uint256(senderBatchState.batchStartTs) < ADDRESS_BATCH_WINDOW_SEC
        ) {
            effectivePifPpm = uint256(senderBatchState.batchAccumPpm) + quote.pifPpm;
        }
        uint256 satPpm = FullMath.mulDiv(effectivePifPpm, FeeMath.PPM_BASE, effectivePifPpm + FeeMath.PIF_CAP_PPM);
        uint256 dffPpm = FullMath.mulDiv(FEE_DFF_MAX_PPM, satPpm, FeeMath.PPM_BASE);
        uint256 dynamicPpm = FullMath.mulDiv(dffPpm, effectivePifPpm, FeeMath.PPM_BASE);
        quote.adverseImpactPartBps = dynamicPpm / (FeeMath.PPM_BASE / FeeMath.BPS_BASE);
        quote.volatilityPartBps = preVolatilityPartBps;

        uint256 projectedShortPpm = preDecayedShortPpm + quote.pifPpm;
        if (projectedShortPpm > SHORT_CAP_PPM) projectedShortPpm = SHORT_CAP_PPM;
        uint256 chargeableShortPpm = projectedShortPpm > SHORT_FLOOR_PPM ? projectedShortPpm - SHORT_FLOOR_PPM : 0;
        quote.shortImpactPartBps = FullMath.mulDiv(chargeableShortPpm, SHORT_COEFF_BPS, FeeMath.PPM_BASE);

        uint256 feeBps = FEE_BASE_BPS + quote.adverseImpactPartBps + quote.volatilityPartBps + quote.shortImpactPartBps;
        quote.feeBps = feeBps > FEE_MAX_BPS ? FEE_MAX_BPS : feeBps;
    }

    /// @notice Linear decay of a ppm accumulator over a fixed window, relative to `block.timestamp`.
    /// @dev Returns 0 once the window has fully elapsed. `view` only because it reads `block.timestamp`.
    function decayLinearPpm(uint256 accumulatorPpm, uint256 lastTs, uint256 windowSec) internal view returns (uint256) {
        if (accumulatorPpm == 0 || lastTs == 0 || windowSec == 0) return 0;
        if (block.timestamp <= lastTs) return accumulatorPpm;
        uint256 elapsed = block.timestamp - lastTs;
        if (elapsed >= windowSec) return 0;
        return FullMath.mulDiv(accumulatorPpm, windowSec - elapsed, windowSec);
    }

    /// @notice Decides whether the volatility anchor should be refreshed at this timestamp and, if so,
    ///         the decayed carry accumulator that seeds the next deviation window.
    /// @dev Shared by `quote` (memory-backed preview) and `refreshVolatilityAnchorAndCarry`
    ///      (storage-backed apply) so preview and execution cannot drift on the decay formula or
    ///      filter threshold. `view` only because it reads `block.timestamp`.
    ///      This function provides only the refresh DECISION. The refresh APPLY (three-field write of
    ///      `volAnchorSqrtPriceX96`, `volCarryAccumulator`, `volDeviationAccumulator`) lives in
    ///      `DynamicFeeMath.volatilityRefreshApply()` — a `pure` helper used by both `quote()` (memory)
    ///      and `refreshVolatilityAnchorAndCarry()` (storage). The compiler enforces tuple-element
    ///      alignment, so adding a refresh-reset field causes a compile error at both call sites.
    function volatilityRefreshPlan(uint40 lastMoveTs, uint24 volDeviationAccumulator)
        internal
        view
        returns (bool shouldRefresh, uint24 refreshedCarry)
    {
        uint256 elapsed = block.timestamp > lastMoveTs ? block.timestamp - lastMoveTs : 0;
        if (elapsed < VOL_FILTER_PERIOD_SEC) return (false, 0);
        refreshedCarry = lastMoveTs != 0 && elapsed < VOL_DECAY_PERIOD_SEC
            ? uint24(FullMath.mulDiv(volDeviationAccumulator, VOL_DECAY_FACTOR_BPS, FeeMath.BPS_BASE))
            : 0;
        return (true, refreshedCarry);
    }

    /// @notice Returns post-refresh values for the volatility anchor, carry, and deviation accumulators.
    /// @dev Single source of truth for the refresh APPLY step. `quote()` (memory preview) and
    ///      `refreshVolatilityAnchorAndCarry()` (storage execution) both destructure this function,
    ///      so adding a new refresh-reset field automatically forces both call sites to update —
    ///      the compiler rejects a tuple destructure with mismatched element counts.
    ///      `pure` is always inlined by the optimizer; no gas overhead versus the prior
    ///      duplicated code.
    function volatilityRefreshApply(uint160 priceX96, uint24 refreshedCarry)
        internal
        pure
        returns (uint160 anchor, uint24 carry, uint24 deviation)
    {
        anchor = priceX96;
        // Window-open instant: the decayed seed IS both the new carry baseline and the starting
        // deviation, because no new price delta has accumulated yet at the refresh moment. They
        // diverge after the next swap — see DynamicFeeFacet._updateVolatilityDeviationAccumulatorAfterSwap,
        // where deviation = carry + deltaSteps * VOL_INCREMENT_PER_STEP (carry stays fixed for the window).
        carry = refreshedCarry;
        deviation = refreshedCarry;
    }

    /// @notice One-time anchor initialization on first call (anchor == 0 → set to current price), then
    ///      conditionally refreshes anchor + carry + deviation when the volatilityRefreshPlan signals
    ///      a refresh window. Writes state in place; caller must supply the storage reference.
    function refreshVolatilityAnchorAndCarry(IDynamicFeeFacet.DynamicFeeState storage state, uint160 preSqrtPriceX96)
        internal
    {
        if (state.volAnchorSqrtPriceX96 == 0) state.volAnchorSqrtPriceX96 = preSqrtPriceX96;
        uint40 lastMoveTs = state.volLastMoveTs;
        (bool shouldRefresh, uint24 refreshedCarry) = volatilityRefreshPlan(lastMoveTs, state.volDeviationAccumulator);
        if (!shouldRefresh) return;
        (state.volAnchorSqrtPriceX96, state.volCarryAccumulator, state.volDeviationAccumulator) =
            volatilityRefreshApply(preSqrtPriceX96, refreshedCarry);
    }

    // -----------------------------------------------------------------
    // Pure algorithms
    // -----------------------------------------------------------------

    /// @notice Normalized exponential decay weight in [0, 1e18] over `[0, duration]`.
    /// @dev Shape constant `LAUNCH_FEE_EXP_SHAPE_WAD` controls the steepness; the (elapsed, end)
    ///      exponentials are subtracted and renormalized so the curve is exactly 1e18 at elapsed=0
    ///      and 0 at elapsed=duration.
    function normalizedLaunchDecayWad(uint256 elapsed, uint256 duration) internal pure returns (uint256 decayWad) {
        int256 expAtElapsedWad = wadExp(-int256(FullMath.mulDiv(elapsed, uint256(LAUNCH_FEE_EXP_SHAPE_WAD), duration)));
        int256 expAtEndWad = wadExp(-LAUNCH_FEE_EXP_SHAPE_WAD);
        decayWad = uint256((expAtElapsedWad - expAtEndWad) * 1e18 / (1e18 - expAtEndWad));
    }

    /// @notice Estimates swap I/O amounts and the resulting post-swap sqrt price for a given
    ///         (liquidity, pre-price, direction, amountSpecified) tuple, without touching storage.
    /// @dev Output-specified path grosses the output up before computing the post price; input-specified
    ///      path uses the input directly. Rounding direction is dictated by `SqrtPriceMath` (v4-core).
    function estimateSwapFlowAndPostPrice(
        uint128 liquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified
    )
        internal
        pure
        returns (uint256 inputAmount, uint256 outputAmount, uint256 grossOutputAmount, uint160 postSqrtPriceX96)
    {
        if (amountSpecified == 0) return (0, 0, 0, preSqrtPriceX96);
        if (amountSpecified < 0) {
            inputAmount = uint256(-amountSpecified);
            postSqrtPriceX96 =
                SqrtPriceMath.getNextSqrtPriceFromInput(preSqrtPriceX96, liquidity, inputAmount, zeroForOne);
            outputAmount = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(postSqrtPriceX96, preSqrtPriceX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(preSqrtPriceX96, postSqrtPriceX96, liquidity, false);
            grossOutputAmount = outputAmount;
            return (inputAmount, outputAmount, grossOutputAmount, postSqrtPriceX96);
        }
        outputAmount = uint256(amountSpecified);
        grossOutputAmount = outputAmount;
        postSqrtPriceX96 =
            SqrtPriceMath.getNextSqrtPriceFromOutput(preSqrtPriceX96, liquidity, grossOutputAmount, zeroForOne);
        inputAmount = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(postSqrtPriceX96, preSqrtPriceX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(preSqrtPriceX96, postSqrtPriceX96, liquidity, true);
    }

    /// @notice Returns the fee amount that must be added on top of a requested net output so that,
    ///         after taking `feeBps` off the gross, the payer receives exactly `netOutputAmount`.
    /// @dev Rounds the gross UP (payer-favorable rounding) via `mulDivRoundingUp`. Saturates at
    ///      `type(uint256).max` when `feeBps >= BPS_BASE` (100%) to avoid divide-by-zero.
    function grossUpFeeFromNetOutput(uint256 netOutputAmount, uint256 feeBps)
        internal
        pure
        returns (uint256 feeAmount)
    {
        if (netOutputAmount == 0 || feeBps == 0) return 0;
        if (feeBps >= FeeMath.BPS_BASE) return type(uint256).max;
        uint256 grossOutputAmount =
            FullMath.mulDivRoundingUp(netOutputAmount, FeeMath.BPS_BASE, FeeMath.BPS_BASE - feeBps);
        return grossOutputAmount - netOutputAmount;
    }

    /// @notice Number of volatility-deviation steps between two sqrt prices for a given step size in bps.
    /// @dev Uses the squared ratio (X18) against `EWVWAP_PRECISION` so the step count is symmetric in
    ///      the price direction; `stepBps * 2` reflects that one step equals a `stepBps` move on each leg.
    function volatilityDeltaSteps(uint160 referenceSqrtPriceX96, uint160 currentSqrtPriceX96, uint256 stepBps)
        internal
        pure
        returns (uint256)
    {
        if (referenceSqrtPriceX96 == 0 || currentSqrtPriceX96 == 0 || stepBps == 0) return 0;
        (uint256 upper, uint256 lower) = referenceSqrtPriceX96 > currentSqrtPriceX96
            ? (uint256(referenceSqrtPriceX96), uint256(currentSqrtPriceX96))
            : (uint256(currentSqrtPriceX96), uint256(referenceSqrtPriceX96));
        uint256 sqrtRatioX18 = FullMath.mulDiv(upper, FeeMath.EWVWAP_PRECISION, lower);
        if (sqrtRatioX18 <= FeeMath.EWVWAP_PRECISION) return 0;
        return FullMath.mulDiv(
            sqrtRatioX18 - FeeMath.EWVWAP_PRECISION, FeeMath.BPS_BASE * 2, stepBps * FeeMath.EWVWAP_PRECISION
        );
    }

    /// @notice Absolute difference between two uint256 values.
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
