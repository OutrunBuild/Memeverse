// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FeeMath} from "src/swap/libraries/FeeMath.sol";

/// @notice Focused CPMM simulation tests for the ewVWAP + PIF + DAMM v2-style volatility fee model.
contract MemeverseDynamicFeeSimulation is Test {
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant BPS_BASE = 10_000;
    uint256 internal constant PPM_BASE = 1_000_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant U = 1e18;

    // x = 2e28 COIN, y = 2e22 USDT => full-range equivalent L ~= sqrt(x*y) = 2e25.
    uint128 internal constant INITIAL_LIQUIDITY = 2e25;
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950;

    // Default inputs (raw, decimals=18)
    uint256 internal constant DEFAULT_ATTACK_TOTAL_INPUT_U = 2_000 * U;
    uint256 internal constant DEFAULT_VICTIM_INPUT_U = 100 * U;
    uint256 internal constant DEFAULT_HIGH_FREQUENCY_INPUT_U = 100 * U;
    uint256 internal constant DEFAULT_ATTACK_BATCH_N = 300;
    uint256 internal constant DEFAULT_HIGH_FREQUENCY_SWAPS = 300;
    uint256 internal constant DEFAULT_HIGH_FREQUENCY_INTERVAL_SEC = 1;
    uint256 internal constant DEFAULT_INITIAL_LIQUIDITY_SCALE_X = 1;
    uint256 internal constant DEFAULT_RETAIL_FLOW_DURATION_SEC = 600; // reduced from 3600 to avoid OOG with per-swap batch storage overhead
    uint256 internal constant DEFAULT_RETAIL_FLOW_MIN_TX_PER_SEC = 1;
    uint256 internal constant DEFAULT_RETAIL_FLOW_MAX_TX_PER_SEC = 5;
    uint256 internal constant DEFAULT_RETAIL_FLOW_MAX_FEE_BPS = 500;
    uint256 internal constant DEFAULT_RETAIL_FLOW_BUY_BIAS_PPM = 600_000;
    uint256 internal constant DEFAULT_RETAIL_FLOW_ORDER_SCALE_X = 1;
    uint256 internal constant DEFAULT_RETAIL_FLOW_SEED = 42;

    struct PoolConfig {
        uint24 alpha;
        uint24 dffMaxPpm;
        uint24 baseFeeBps;
        uint24 maxFeeBps;
        uint24 pifCapPpm;
        uint24 volDeviationStepBps;
        uint24 volFilterPeriodSec;
        uint24 volDecayPeriodSec;
        uint24 volDecayFactorBps;
        uint24 shortDecayWindowSec;
        uint24 shortCoeffBps;
        uint24 shortFloorPpm;
        uint24 shortCapPpm;
        uint24 volIncrementPerStep; // matches production VOL_INCREMENT_PER_STEP
    }

    struct EWVWAPParams {
        uint256 weightedVolume0;
        uint256 weightedPriceVolume0;
        uint256 ewVWAPX18;
        uint160 volAnchorSqrtPriceX96;
        uint256 volDeviationAccumulator;
        uint256 volCarryAccumulator;
        uint256 volLastMoveTs;
        uint256 shortImpactPpm;
        uint256 shortLastTs;
    }

    struct MixedObservation {
        uint256 attackerN;
        uint256 attackerTotalInputU;
        uint256 attackerPerSwapInputU;
        uint256 attackerLastSwapInputU;
        uint256 attackerAvgFeeBps;
        uint256 attackerMaxFeeBps;
        uint256 attackerEffectiveFeeBps;
        uint256 attackerAvgImpactBps;
        uint256 attackerMaxImpactBps;
        uint256 victimInputU;
        uint256 baselineVictimFeeBps;
        uint256 victimFeeWithHistoryBps;
        uint256 victimFeeNoHistoryBps;
        uint256 baselineVictimImpactBps;
        uint256 victimImpactWithHistoryBps;
        uint256 victimImpactNoHistoryBps;
    }

    struct RetailFlowObservation {
        uint256 durationSec;
        uint256 minTxPerSec;
        uint256 maxTxPerSec;
        uint256 feeToleranceBps;
        uint256 candidateTrades;
        uint256 executedTrades;
        uint256 rejectedTrades;
        uint256 buyTrades;
        uint256 sellTrades;
        uint256 candidateVolumeU;
        uint256 executedVolumeU;
        uint256 rejectedVolumeU;
        uint256 avgQuotedFeeBps;
        uint256 avgExecutedFeeBps;
        uint256 maxQuotedFeeBps;
        uint256 lastExecutedFeeBps;
        uint256 lastExecutedImpactBps;
    }

    uint256 internal constant ADDRESS_BATCH_WINDOW_SEC = 3;

    address internal constant ADDR_ATTACKER = address(0x1);
    address internal constant ADDR_VICTIM = address(0x2);

    struct AddressBatchState {
        uint192 batchAccumPpm;
        uint64 batchStartTs;
    }

    PoolConfig internal cfg;
    EWVWAPParams internal ewState;
    mapping(address => AddressBatchState) internal addrBatch;
    uint160 internal simPrice;
    uint128 internal simLiquidity;
    uint128 internal initialLiquidity;
    uint256 internal retailFlowOrderScaleX;

    /// @notice Initializes the default CPMM dynamic-fee parameters used by each simulation.
    /// @dev Runs before each test to reset the config to the current baseline tuning.
    function setUp() external {
        uint256 initialLiquidityScaleX =
            vm.envOr("INITIAL_LIQUIDITY_SCALE_X", uint256(DEFAULT_INITIAL_LIQUIDITY_SCALE_X));
        initialLiquidity = uint128(uint256(INITIAL_LIQUIDITY) * initialLiquidityScaleX);
        retailFlowOrderScaleX = vm.envOr("RETAIL_FLOW_ORDER_SCALE_X", uint256(DEFAULT_RETAIL_FLOW_ORDER_SCALE_X));

        cfg = PoolConfig({
            alpha: 500_000,
            dffMaxPpm: 800_000,
            baseFeeBps: 100,
            maxFeeBps: 10_000,
            pifCapPpm: 150_000,
            volDeviationStepBps: 1,
            volFilterPeriodSec: 10,
            volDecayPeriodSec: 60,
            volDecayFactorBps: 5_000,
            shortDecayWindowSec: 15,
            shortCoeffBps: 2_500,
            shortFloorPpm: 20_000,
            shortCapPpm: 100_000,
            volIncrementPerStep: 1_000
        });
    }

    function _resetSimulation() internal {
        simLiquidity = initialLiquidity;
        simPrice = INITIAL_SQRT_PRICE_X96;
        ewState = EWVWAPParams({
            weightedVolume0: 0,
            weightedPriceVolume0: 0,
            ewVWAPX18: 0,
            volAnchorSqrtPriceX96: 0,
            volDeviationAccumulator: 0,
            volCarryAccumulator: 0,
            volLastMoveTs: 0,
            shortImpactPpm: 0,
            shortLastTs: 0
        });
        addrBatch[ADDR_ATTACKER] = AddressBatchState(0, 0);
        addrBatch[ADDR_VICTIM] = AddressBatchState(0, 0);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _spotX18FromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FeeMath.spotX18FromSqrtPrice(sqrtPriceX96);
    }

    function _priceMovePpm(uint160 preSqrtPrice, uint160 postSqrtPrice) internal pure returns (uint256) {
        // Delegates to the production formula so simulation matches FeeMath.priceMovePpmCapped,
        // including the 150_000 ppm cap, the up/down short-bucket fast path, and the wide-int
        // rounding correction. The pure helper only re-exposes it for in-test readability.
        return FeeMath.priceMovePpmCapped(preSqrtPrice, postSqrtPrice);
    }

    function _ppmToBps(uint256 ppm) internal pure returns (uint256) {
        return ppm / (PPM_BASE / BPS_BASE);
    }

    function _decayLinearPpm(uint256 accumulatorPpm, uint256 lastTs) internal view returns (uint256) {
        if (accumulatorPpm == 0 || cfg.shortDecayWindowSec == 0 || lastTs == 0) return 0;
        if (block.timestamp <= lastTs) return accumulatorPpm;
        uint256 elapsed = block.timestamp - lastTs;
        if (elapsed >= cfg.shortDecayWindowSec) return 0;
        return (accumulatorPpm * (uint256(cfg.shortDecayWindowSec) - elapsed)) / uint256(cfg.shortDecayWindowSec);
    }

    function _refreshVolatilityAnchorAndCarry(uint160 prePrice) internal {
        if (ewState.volAnchorSqrtPriceX96 == 0) {
            ewState.volAnchorSqrtPriceX96 = prePrice;
        }

        uint256 elapsed = block.timestamp > ewState.volLastMoveTs ? block.timestamp - ewState.volLastMoveTs : 0;
        if (elapsed < cfg.volFilterPeriodSec) return;

        ewState.volAnchorSqrtPriceX96 = prePrice;
        if (ewState.volLastMoveTs != 0 && elapsed < cfg.volDecayPeriodSec) {
            ewState.volCarryAccumulator = (ewState.volDeviationAccumulator * cfg.volDecayFactorBps) / BPS_BASE;
        } else {
            ewState.volCarryAccumulator = 0;
        }
        ewState.volDeviationAccumulator = ewState.volCarryAccumulator;
    }

    function _volatilityDeltaSteps(uint160 referencePrice, uint160 currentPrice) internal view returns (uint256) {
        if (referencePrice == 0 || currentPrice == 0 || cfg.volDeviationStepBps == 0) return 0;

        (uint256 upper, uint256 lower) = referencePrice > currentPrice
            ? (uint256(referencePrice), uint256(currentPrice))
            : (uint256(currentPrice), uint256(referencePrice));
        uint256 sqrtRatioX18 = (upper * PRECISION) / lower;
        if (sqrtRatioX18 <= PRECISION) return 0;

        return ((sqrtRatioX18 - PRECISION) * BPS_BASE * 2) / (uint256(cfg.volDeviationStepBps) * PRECISION);
    }

    function _volatilitySqrtFeeBps() internal view returns (uint256) {
        // Production formula: same FeeMath.volatilitySqrtFeeBps used by DynamicFeeMath.selectDynamicFee,
        // so simulation and execution cannot drift on the sqrt shape or the VOL_MAX_* constants.
        return FeeMath.volatilitySqrtFeeBps(ewState.volDeviationAccumulator);
    }

    function _predictPostSqrtPrice(uint160 preSqrtPriceX96, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint160)
    {
        if (zeroForOne) {
            uint256 reserveIn = (uint256(simLiquidity) * Q96) / uint256(preSqrtPriceX96);
            uint256 newReserveIn = reserveIn + amountIn;
            uint256 next = FullMath.mulDiv(uint256(simLiquidity), Q96, newReserveIn);
            return next == 0 ? 1 : uint160(next);
        }

        uint256 delta = (amountIn * Q96) / uint256(simLiquidity);
        uint256 candidate = uint256(preSqrtPriceX96) + delta;
        return candidate > type(uint160).max ? type(uint160).max : uint160(candidate);
    }

    function _rand(uint256 seed, uint256 secondIndex, uint256 tradeIndex, uint256 salt)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(seed, secondIndex, tradeIndex, salt)));
    }

    function _sampleRetailTradeInputU(uint256 seed, uint256 secondIndex, uint256 tradeIndex)
        internal
        view
        returns (uint256 inputU)
    {
        uint256 bucket = _rand(seed, secondIndex, tradeIndex, 1) % 100;
        uint256 draw = _rand(seed, secondIndex, tradeIndex, 2);

        if (bucket < 70) {
            return ((10 + (draw % 91)) * U) * retailFlowOrderScaleX;
        }
        if (bucket < 95) {
            return ((100 + (draw % 401)) * U) * retailFlowOrderScaleX;
        }
        return ((500 + (draw % 1_501)) * U) * retailFlowOrderScaleX;
    }

    function _quoteDynamicFeeBps(address sender, uint160 prePrice, uint160 postPrice)
        internal
        view
        returns (uint256 feeBps, uint256 pifPpm)
    {
        feeBps = cfg.baseFeeBps;
        // Argument order is load-bearing: FeeMath.priceMovePpmCapped is direction-aware (up/down
        // short-bucket fast path). pre must stay first.
        pifPpm = _priceMovePpm(prePrice, postPrice);

        bool hasHistory = ewState.weightedVolume0 > 0 && ewState.ewVWAPX18 > 0;
        if (hasHistory) {
            uint256 spotBefore = _spotX18FromSqrtPrice(prePrice);
            uint256 spotAfter = _spotX18FromSqrtPrice(postPrice);
            uint256 distBefore = _absDiff(spotBefore, ewState.ewVWAPX18);
            uint256 distAfter = _absDiff(spotAfter, ewState.ewVWAPX18);
            if (distAfter <= distBefore) return (feeBps, pifPpm);
        }

        uint256 effectivePifPpm = pifPpm;
        AddressBatchState memory bs = addrBatch[sender];
        if (bs.batchStartTs > 0 && block.timestamp - uint256(bs.batchStartTs) < ADDRESS_BATCH_WINDOW_SEC) {
            effectivePifPpm = uint256(bs.batchAccumPpm) + pifPpm;
        }

        uint256 satPpm = (effectivePifPpm * PPM_BASE) / (effectivePifPpm + cfg.pifCapPpm);
        uint256 dffPpm = (uint256(cfg.dffMaxPpm) * satPpm) / PPM_BASE;
        uint256 dynamicPpm = (dffPpm * effectivePifPpm) / PPM_BASE;
        uint256 adverseImpactPartBps = _ppmToBps(dynamicPpm);

        uint256 volatilityPartBps = _volatilitySqrtFeeBps();

        uint256 decayedShortPpm = _decayLinearPpm(ewState.shortImpactPpm, ewState.shortLastTs);
        uint256 projectedShortPpm = decayedShortPpm + pifPpm;
        if (projectedShortPpm > cfg.shortCapPpm) projectedShortPpm = cfg.shortCapPpm;
        uint256 chargeableShortPpm = projectedShortPpm > cfg.shortFloorPpm ? projectedShortPpm - cfg.shortFloorPpm : 0;
        uint256 shortImpactPartBps = (chargeableShortPpm * uint256(cfg.shortCoeffBps)) / PPM_BASE;

        feeBps = uint256(cfg.baseFeeBps) + adverseImpactPartBps + volatilityPartBps + shortImpactPartBps;
        if (feeBps > cfg.maxFeeBps) feeBps = cfg.maxFeeBps;
    }

    function _updateStateAfterSwap(address sender, uint160 postPrice, uint256 volume0, uint256 pifPpm) internal {
        // per-address batch accumulator
        AddressBatchState storage bs = addrBatch[sender];
        if (bs.batchStartTs > 0 && block.timestamp - uint256(bs.batchStartTs) < ADDRESS_BATCH_WINDOW_SEC) {
            bs.batchAccumPpm = uint192(uint256(bs.batchAccumPpm) + pifPpm);
        } else {
            bs.batchAccumPpm = uint192(pifPpm);
            bs.batchStartTs = uint64(block.timestamp);
        }
        uint256 decayedShortPpm = _decayLinearPpm(ewState.shortImpactPpm, ewState.shortLastTs);
        uint256 updatedShortPpm = decayedShortPpm + pifPpm;
        if (updatedShortPpm > cfg.shortCapPpm) updatedShortPpm = cfg.shortCapPpm;
        ewState.shortImpactPpm = updatedShortPpm;
        ewState.shortLastTs = block.timestamp;

        uint256 deltaSteps = _volatilityDeltaSteps(ewState.volAnchorSqrtPriceX96, postPrice);
        uint256 updatedVolAccumulator = ewState.volCarryAccumulator + deltaSteps * uint256(cfg.volIncrementPerStep);
        // Cap mirrors DynamicFeeFacet._updateVolatilityDeviationAccumulatorAfterSwap, which clamps at
        // FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR (1_500_000) rather than a tunable config field.
        if (updatedVolAccumulator > FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR) {
            updatedVolAccumulator = FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR;
        }
        ewState.volDeviationAccumulator = updatedVolAccumulator;
        if (deltaSteps > 0) {
            ewState.volLastMoveTs = block.timestamp;
        }

        uint256 spotX18 = _spotX18FromSqrtPrice(postPrice);
        uint256 priceVolume = (volume0 * spotX18) / PRECISION;

        if (ewState.weightedVolume0 == 0) {
            ewState.weightedVolume0 = volume0;
            ewState.weightedPriceVolume0 = priceVolume;
            ewState.ewVWAPX18 = spotX18;
        } else {
            uint256 alpha = cfg.alpha;
            uint256 alphaR = PPM_BASE - alpha;
            ewState.weightedVolume0 = (alpha * volume0 + alphaR * ewState.weightedVolume0) / PPM_BASE;
            ewState.weightedPriceVolume0 = (alpha * priceVolume + alphaR * ewState.weightedPriceVolume0) / PPM_BASE;
            ewState.ewVWAPX18 = (ewState.weightedPriceVolume0 * PRECISION) / ewState.weightedVolume0;
        }
    }

    function _simulateOneSwap(address sender, uint256 inputU, bool zeroForOne)
        internal
        returns (uint256 feeBps, uint256 impactBps, uint256 feeAmount, uint256 volume0)
    {
        uint160 pre = simPrice;
        uint160 post = _predictPostSqrtPrice(pre, zeroForOne, inputU);
        _refreshVolatilityAnchorAndCarry(pre);

        uint256 pifPpm;
        (feeBps, pifPpm) = _quoteDynamicFeeBps(sender, pre, post);

        feeAmount = (inputU * feeBps) / BPS_BASE;
        impactBps = _ppmToBps(pifPpm);

        if (zeroForOne) {
            volume0 = inputU;
        } else {
            uint256 reserve0Before = (uint256(simLiquidity) * Q96) / uint256(pre);
            uint256 reserve0After = (uint256(simLiquidity) * Q96) / uint256(post);
            volume0 = reserve0Before > reserve0After ? reserve0Before - reserve0After : reserve0After - reserve0Before;
        }

        _updateStateAfterSwap(sender, post, volume0, pifPpm);
        simPrice = post;
    }

    function _simulateRetailFlow(
        uint256 durationSec,
        uint256 minTxPerSec,
        uint256 maxTxPerSec,
        uint256 feeToleranceBps,
        uint256 buyBiasPpm,
        uint256 seed
    ) internal returns (RetailFlowObservation memory out) {
        require(durationSec > 0, "duration=0");
        require(minTxPerSec > 0, "minTx=0");
        require(minTxPerSec <= maxTxPerSec, "txRange");
        require(feeToleranceBps <= cfg.maxFeeBps, "feeTolerance");
        require(buyBiasPpm <= PPM_BASE, "buyBias");

        out.durationSec = durationSec;
        out.minTxPerSec = minTxPerSec;
        out.maxTxPerSec = maxTxPerSec;
        out.feeToleranceBps = feeToleranceBps;

        _resetSimulation();

        uint256 sumQuotedFeeBps;
        uint256 sumExecutedFeeBps;

        for (uint256 secondIndex = 0; secondIndex < durationSec; secondIndex++) {
            if (secondIndex > 0) vm.warp(block.timestamp + 1);

            uint256 txCountThisSecond = minTxPerSec + (_rand(seed, secondIndex, 0, 3) % (maxTxPerSec - minTxPerSec + 1));

            for (uint256 tradeIndex = 0; tradeIndex < txCountThisSecond; tradeIndex++) {
                bool zeroForOne = (_rand(seed, secondIndex, tradeIndex, 4) % PPM_BASE) >= buyBiasPpm;
                uint256 inputU = _sampleRetailTradeInputU(seed, secondIndex, tradeIndex);
                address trader = address(uint160(_rand(seed, secondIndex, tradeIndex, 5)));

                out.candidateTrades++;
                out.candidateVolumeU += inputU;
                if (zeroForOne) out.sellTrades++;
                else out.buyTrades++;

                uint160 prePrice = simPrice;
                uint160 postPrice = _predictPostSqrtPrice(prePrice, zeroForOne, inputU);
                (uint256 quotedFeeBps,) = _quoteDynamicFeeBps(trader, prePrice, postPrice);

                sumQuotedFeeBps += quotedFeeBps;
                if (quotedFeeBps > out.maxQuotedFeeBps) out.maxQuotedFeeBps = quotedFeeBps;

                if (quotedFeeBps > feeToleranceBps) {
                    out.rejectedTrades++;
                    out.rejectedVolumeU += inputU;
                    continue;
                }

                (uint256 feeBps, uint256 impactBps,,) = _simulateOneSwap(trader, inputU, zeroForOne);
                out.executedTrades++;
                out.executedVolumeU += inputU;
                out.lastExecutedFeeBps = feeBps;
                out.lastExecutedImpactBps = impactBps;
                sumExecutedFeeBps += feeBps;
            }
        }

        out.avgQuotedFeeBps = out.candidateTrades == 0 ? 0 : sumQuotedFeeBps / out.candidateTrades;
        out.avgExecutedFeeBps = out.executedTrades == 0 ? 0 : sumExecutedFeeBps / out.executedTrades;
    }

    function _simulateMixedScenario(
        uint256 attackerN,
        uint256 attackerTotalInputU,
        uint256 victimInputU,
        bool perSecond
    ) internal returns (MixedObservation memory out) {
        require(attackerN > 0, "attackerN=0");

        out.attackerN = attackerN;
        out.attackerTotalInputU = attackerTotalInputU;
        out.attackerPerSwapInputU = attackerTotalInputU / attackerN;
        out.attackerLastSwapInputU = out.attackerPerSwapInputU + (attackerTotalInputU % attackerN);
        out.victimInputU = victimInputU;

        _resetSimulation();
        (out.baselineVictimFeeBps, out.baselineVictimImpactBps,,) = _simulateOneSwap(ADDR_VICTIM, victimInputU, false);

        _resetSimulation();
        uint256 sumFee;
        uint256 sumImpact;
        uint256 totalAttackerFee;

        for (uint256 i = 1; i <= attackerN; i++) {
            uint256 thisInput = out.attackerPerSwapInputU;
            if (i == attackerN) thisInput += attackerTotalInputU % attackerN;

            (uint256 feeBps, uint256 impactBps, uint256 feeAmount,) = _simulateOneSwap(ADDR_ATTACKER, thisInput, false);
            totalAttackerFee += feeAmount;
            sumFee += feeBps;
            sumImpact += impactBps;
            if (feeBps > out.attackerMaxFeeBps) out.attackerMaxFeeBps = feeBps;
            if (impactBps > out.attackerMaxImpactBps) out.attackerMaxImpactBps = impactBps;

            if (perSecond && i < attackerN) vm.warp(block.timestamp + 1);
        }

        out.attackerAvgFeeBps = sumFee / attackerN;
        out.attackerAvgImpactBps = sumImpact / attackerN;
        out.attackerEffectiveFeeBps = (totalAttackerFee * BPS_BASE) / attackerTotalInputU;

        if (perSecond) vm.warp(block.timestamp + 1);
        (out.victimFeeWithHistoryBps, out.victimImpactWithHistoryBps,,) =
            _simulateOneSwap(ADDR_VICTIM, victimInputU, false);

        uint160 preservedPrice = simPrice;
        _resetSimulation();
        simPrice = preservedPrice;
        (out.victimFeeNoHistoryBps, out.victimImpactNoHistoryBps,,) = _simulateOneSwap(ADDR_VICTIM, victimInputU, false);
    }

    function _logMixedObservation(string memory title, MixedObservation memory obs, bool verbose) internal pure {
        console.log(title);
        console.log("attackerN:", obs.attackerN);
        console.log("attackerEffectiveFeeBps:", obs.attackerEffectiveFeeBps);
        console.log("attackerAvgFeeBps:", obs.attackerAvgFeeBps);
        console.log("attackerMaxFeeBps:", obs.attackerMaxFeeBps);
        console.log("baselineVictimFeeBps:", obs.baselineVictimFeeBps);
        console.log("victimFeeWithHistoryBps:", obs.victimFeeWithHistoryBps);
        console.log("victimFeeNoHistoryBps:", obs.victimFeeNoHistoryBps);
        if (!verbose) return;
        console.log("attackerTotalInputU:", obs.attackerTotalInputU);
        console.log("attackerPerSwapInputU:", obs.attackerPerSwapInputU);
        console.log("attackerLastSwapInputU:", obs.attackerLastSwapInputU);
        console.log("attackerAvgImpactBps:", obs.attackerAvgImpactBps);
        console.log("attackerMaxImpactBps:", obs.attackerMaxImpactBps);
        console.log("victimInputU:", obs.victimInputU);
        console.log("baselineVictimImpactBps:", obs.baselineVictimImpactBps);
        console.log("victimImpactWithHistoryBps:", obs.victimImpactWithHistoryBps);
        console.log("victimImpactNoHistoryBps:", obs.victimImpactNoHistoryBps);
    }

    function _logRetailFlowObservation(RetailFlowObservation memory obs) internal pure {
        console.log("=== CPMM retail flow ===");
        console.log("durationSec:", obs.durationSec);
        console.log("candidateTrades:", obs.candidateTrades);
        console.log("executedTrades:", obs.executedTrades);
        console.log("rejectedTrades:", obs.rejectedTrades);
        console.log("buyTrades:", obs.buyTrades);
        console.log("sellTrades:", obs.sellTrades);
        console.log("candidateVolumeU:", obs.candidateVolumeU);
        console.log("executedVolumeU:", obs.executedVolumeU);
        console.log("rejectedVolumeU:", obs.rejectedVolumeU);
        console.log("avgQuotedFeeBps:", obs.avgQuotedFeeBps);
        console.log("avgExecutedFeeBps:", obs.avgExecutedFeeBps);
        console.log("maxQuotedFeeBps:", obs.maxQuotedFeeBps);
        console.log("lastExecutedFeeBps:", obs.lastExecutedFeeBps);
        console.log("lastExecutedImpactBps:", obs.lastExecutedImpactBps);
    }

    /// @notice Spec: measures same-block batch splitting and the fee paid by a small victim swap immediately after.
    /// @dev Uses the accumulated short-term state from the attack sequence before quoting the victim swap.
    function testCPMM_Mixed_SameBlockBatchThenVictimSmall() external {
        uint256 attackerN = vm.envOr("ATTACK_BATCH_N", uint256(DEFAULT_ATTACK_BATCH_N));
        uint256 attackerTotalInputU = vm.envOr("ATTACK_TOTAL_INPUT", uint256(DEFAULT_ATTACK_TOTAL_INPUT_U));
        uint256 victimInputU = vm.envOr("VICTIM_INPUT", uint256(DEFAULT_VICTIM_INPUT_U));
        bool verbose = vm.envOr("LOG_VERBOSE", false);

        MixedObservation memory obs = _simulateMixedScenario(attackerN, attackerTotalInputU, victimInputU, false);
        _logMixedObservation("=== CPMM mixed #1: same-block split + victim small ===", obs, verbose);

        assertGe(
            obs.victimFeeWithHistoryBps, obs.victimFeeNoHistoryBps, "victim fee with history should be >= no-history"
        );
    }

    /// @notice Spec: simulates repeated regular high-frequency swaps and observes the steady-state fee level.
    /// @dev Uses a fixed per-swap notional and fixed cadence to expose how the dynamic state builds over time.
    function testCPMM_HighFrequency() external {
        uint256 swaps = vm.envOr("HIGH_FREQUENCY_SWAPS", uint256(DEFAULT_HIGH_FREQUENCY_SWAPS));
        uint256 perSwapInputU = vm.envOr("HIGH_FREQUENCY_INPUT_U", uint256(DEFAULT_HIGH_FREQUENCY_INPUT_U));
        uint256 intervalSec = vm.envOr("HIGH_FREQUENCY_INTERVAL_SEC", uint256(DEFAULT_HIGH_FREQUENCY_INTERVAL_SEC));
        bool logSampleOrders = vm.envOr("LOG_SAMPLE_ORDERS", false);

        _resetSimulation();

        uint256 lastFeeBps;
        uint256 lastImpactBps;
        uint256 sumFeeBps;

        for (uint256 i = 1; i <= swaps; i++) {
            (lastFeeBps, lastImpactBps,,) = _simulateOneSwap(ADDR_ATTACKER, perSwapInputU, false);
            sumFeeBps += lastFeeBps;

            if (logSampleOrders && (swaps <= 200 || i == 1 || i == swaps / 2 || i == swaps)) {
                console.log("order:", i);
                console.log("inputU:", perSwapInputU);
                console.log("impactBps:", lastImpactBps);
                console.log("feeBps:", lastFeeBps);
            }

            if (intervalSec > 0 && i < swaps) vm.warp(block.timestamp + intervalSec);
        }

        console.log("=== CPMM high-frequency ===");
        console.log("swaps:", swaps);
        console.log("perSwapInputU:", perSwapInputU);
        console.log("intervalSec:", intervalSec);
        console.log("totalInputU:", perSwapInputU * swaps);
        console.log("lastImpactBps:", lastImpactBps);
        console.log("lastFeeBps:", lastFeeBps);
        console.log("avgFeeBps:", sumFeeBps / swaps);

        assertGe(lastFeeBps, cfg.baseFeeBps, "last fee should stay >= base");
        assertLe(lastFeeBps, cfg.maxFeeBps, "last fee should stay <= max");
    }

    /// @notice Proves that volatility accumulator decay is applied BEFORE the first post-calm swap's fee quote.
    /// @dev After driving the accumulator high and waiting past VOL_DECAY_PERIOD_SEC, the first trade
    ///      must see a near-zero volatility fee, not the stale high value from the previous swap.
    function testQuoteSwap_VolatilityDecayAppliesBeforeFirstPostCalmTrade() external {
        _resetSimulation();

        // 1. Drive volDeviationAccumulator high through rapid volatile swaps.
        uint256 volatileSwapInput = 500 * U;
        uint256 volatileSwaps = 50;
        uint256 volatileIntervalSec = 1;

        uint256 lastFeeBps;
        uint256 volatileFeeSum;
        for (uint256 i = 0; i < volatileSwaps; i++) {
            (lastFeeBps,,,) = _simulateOneSwap(ADDR_ATTACKER, volatileSwapInput, false);
            volatileFeeSum += lastFeeBps;
            if (i < volatileSwaps - 1) vm.warp(block.timestamp + volatileIntervalSec);
        }
        uint256 accumulatorBeforeCalm = ewState.volDeviationAccumulator;
        assertGt(accumulatorBeforeCalm, 0, "accumulator must be non-zero after volatile swaps");

        // Record volatility part during volatile regime for comparison.
        uint256 volatileVolPartBps = _volatilitySqrtFeeBps();
        assertGt(volatileVolPartBps, 0, "volatility part must be positive during volatile regime");

        // 2. Warp past full decay: 120s > VOL_DECAY_PERIOD_SEC (60).
        vm.warp(block.timestamp + 120);

        // 3. Manually call refresh (simulating _beforeSwap) and verify the accumulator
        //    is immediately zeroed before any fee quote reads it.
        _refreshVolatilityAnchorAndCarry(simPrice);
        assertEq(ewState.volDeviationAccumulator, 0, "accumulator must be zero after full decay and refresh");
        uint256 postCalmVolPartBps = _volatilitySqrtFeeBps();
        assertEq(postCalmVolPartBps, 0, "volatility part must be zero after full decay");

        // 4. Compare: if the bug were present (no sync), the quoted volatility part for the
        //    next swap would use the stale accumulatorBeforeCalm instead of 0. Verify the
        //    decayed value is strictly lower than the stale value.
        assertLt(
            ewState.volDeviationAccumulator,
            accumulatorBeforeCalm,
            "decayed accumulator must be lower than pre-calm value"
        );
    }

    /// @notice Proves that volatility accumulator is non-zero but reduced at volDecayPeriodSec - 1.
    /// @dev Warps to exactly one second before full decay and verifies the carry-based decay path.
    function testQuoteSwap_VolatilityDecayIsPartialAtBoundaryMinusOne() external {
        _resetSimulation();

        uint256 volatileSwapInput = 500 * U;
        uint256 volatileSwaps = 50;
        uint256 volatileIntervalSec = 1;

        for (uint256 i = 0; i < volatileSwaps; i++) {
            _simulateOneSwap(ADDR_ATTACKER, volatileSwapInput, false);
            if (i < volatileSwaps - 1) vm.warp(block.timestamp + volatileIntervalSec);
        }
        uint256 accumulatorBeforeCalm = ewState.volDeviationAccumulator;
        assertGt(accumulatorBeforeCalm, 0, "accumulator must be non-zero after volatile swaps");

        // Warp to volDecayPeriodSec - 1: decay has not completed.
        vm.warp(block.timestamp + cfg.volDecayPeriodSec - 1);

        _refreshVolatilityAnchorAndCarry(simPrice);

        assertGt(ewState.volCarryAccumulator, 0, "carry accumulator must be non-zero before full decay");
        assertEq(
            ewState.volDeviationAccumulator, ewState.volCarryAccumulator, "deviation must equal carry after refresh"
        );
        assertLt(
            ewState.volDeviationAccumulator,
            accumulatorBeforeCalm,
            "decayed accumulator must be lower than pre-calm value"
        );
    }

    /// @notice Spec: simulates one hour of retail-like random flow with 1-5 trades per second and a 5% fee ceiling.
    /// @dev Candidate users refuse any trade whose quoted fee is above `feeToleranceBps`.
    function testCPMM_RetailFlow_OneHour_Random1To5PerSecond_5PctTolerance() external {
        uint256 durationSec = vm.envOr("RETAIL_FLOW_DURATION_SEC", uint256(DEFAULT_RETAIL_FLOW_DURATION_SEC));
        uint256 minTxPerSec = vm.envOr("RETAIL_FLOW_MIN_TX_PER_SEC", uint256(DEFAULT_RETAIL_FLOW_MIN_TX_PER_SEC));
        uint256 maxTxPerSec = vm.envOr("RETAIL_FLOW_MAX_TX_PER_SEC", uint256(DEFAULT_RETAIL_FLOW_MAX_TX_PER_SEC));
        uint256 feeToleranceBps = vm.envOr("RETAIL_FLOW_MAX_FEE_BPS", uint256(DEFAULT_RETAIL_FLOW_MAX_FEE_BPS));
        uint256 buyBiasPpm = vm.envOr("RETAIL_FLOW_BUY_BIAS_PPM", uint256(DEFAULT_RETAIL_FLOW_BUY_BIAS_PPM));
        uint256 seed = vm.envOr("RETAIL_FLOW_SEED", uint256(DEFAULT_RETAIL_FLOW_SEED));

        RetailFlowObservation memory obs =
            _simulateRetailFlow(durationSec, minTxPerSec, maxTxPerSec, feeToleranceBps, buyBiasPpm, seed);
        _logRetailFlowObservation(obs);

        assertEq(obs.candidateTrades, obs.executedTrades + obs.rejectedTrades, "trade accounting mismatch");
        assertGe(obs.candidateTrades, durationSec * minTxPerSec, "candidate trades too low");
        assertGt(obs.executedTrades, 0, "should execute at least one trade");
    }
}
