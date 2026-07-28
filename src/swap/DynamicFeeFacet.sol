// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {FacetGuard} from "./FacetGuard.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {DynamicFeeMath} from "./libraries/DynamicFeeMath.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {OrdinarySwapMath} from "./libraries/OrdinarySwapMath.sol";
import {SafeCast} from "./libraries/SafeCast.sol";

/// @title DynamicFeeFacet
/// @notice Diamond facet holding the Memeverse dynamic swap fee logic.
/// @dev This facet is the delegatecall target for dynamic-fee quoting and realized swap state updates.
///      It executes inside the Router (the hook proxy) storage context via delegatecall, so it MUST be
///      routed through the Router and never called directly — `DirectFacetCallForbidden` enforces that.
///
///      Storage layout FROZEN — shared ERC-7201 namespace; field order fixed, append-only.
///      See `IMemeverseHookStorage.MemeverseUniswapHookStorage` for the slot-derivation rationale.
///
///      State is keyed directly by `PoolId` (and `trader` / `referrer`) in the Router's shared storage;
///      the Router is the single trusted dispatcher. The pure/view algorithm bodies (EWVWAP, volatility,
///      short-impact, and launch-decay math) live in `DynamicFeeMath` and inline at each call site.
///      This facet keeps the external
///      entry surface (`prepareSwapFee` / `updateAfterSwap` / `quote`) and the
///      storage-writing helper `_updateVolatilityDeviationAccumulatorAfterSwap`; the shared volatility
///      refresh (`DynamicFeeMath.refreshVolatilityAnchorAndCarry`) and the pure APPLY step
///      (`DynamicFeeMath.volatilityRefreshApply`) live in `DynamicFeeMath`.
// solhint-disable-next-line gas-small-strings
contract DynamicFeeFacet layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    FacetGuard,
    IDynamicFeeFacet,
    ImmutableState
{
    using SafeCast for int256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param poolManager_ PoolManager shared with the hook (bound as immutable implementation bytecode state).
    ///      Trailing underscore resolves the clash with the inherited `ImmutableState.poolManager` immutable.
    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    /// @inheritdoc IDynamicFeeFacet
    /// @dev Selects once from the original request curve. The final settlement geometry is quote-only.
    function prepareSwapFee(PrepareSwapFeeParams calldata params)
        external
        override
        onlyViaRouter
        returns (uint256 feeBps)
    {
        DynamicFeeState storage stored = _memeverseUniswapHookStorage.dynamicFeeState[params.poolId];
        DynamicFeeMath.refreshVolatilityAnchorAndCarry(stored, params.preSqrtPriceX96);
        (DynamicFeeMath.DynamicFeeQuote memory fee,) = _selectDynamicFee(stored, params);
        return fee.feeBps;
    }

    /// @inheritdoc IDynamicFeeFacet
    /// @dev This function MUST depend only on `params` fields (delta, price snapshots,
    ///      trader). It MUST NOT read PoolManager unsettled balances or perform settle/take — the caller
    ///      controls call timing relative to settlement, and balance-dependent logic would create ordering
    ///      coupling.
    function updateAfterSwap(UpdateAfterSwapParams calldata params) external override onlyViaRouter {
        if (params.preSqrtPriceX96 == 0) return;

        uint256 pifPpm = FeeMath.priceMovePpmCapped(params.preSqrtPriceX96, params.postSqrtPriceX96);
        DynamicFeeState storage state = _memeverseUniswapHookStorage.dynamicFeeState[params.poolId];
        AddressBatchState storage batch = _memeverseUniswapHookStorage.addressBatchState[params.trader][params.poolId];

        if (
            batch.batchStartTs > 0
                && block.timestamp - uint256(batch.batchStartTs) < DynamicFeeMath.ADDRESS_BATCH_WINDOW_SEC
        ) {
            batch.batchAccumPpm = uint192(uint256(batch.batchAccumPpm) + pifPpm);
        } else {
            batch.batchAccumPpm = uint192(pifPpm);
            batch.batchStartTs = uint64(block.timestamp);
        }

        uint256 updatedShortPpm = DynamicFeeMath.decayLinearPpm(
            state.shortImpactPpm, state.shortLastTs, DynamicFeeMath.SHORT_DECAY_WINDOW_SEC
        ) + pifPpm;
        if (updatedShortPpm > DynamicFeeMath.SHORT_CAP_PPM) updatedShortPpm = DynamicFeeMath.SHORT_CAP_PPM;
        state.shortImpactPpm = uint24(updatedShortPpm);
        state.shortLastTs = uint40(block.timestamp);

        uint256 spotX18 = FeeMath.spotX18FromSqrtPrice(params.postSqrtPriceX96);
        int256 amount0 = params.delta.amount0();
        uint256 volume0 = amount0.abs();
        _updateVolatilityDeviationAccumulatorAfterSwap(state, params.postSqrtPriceX96);
        if (volume0 == 0 || spotX18 == 0) return;

        uint256 priceVolume = FullMath.mulDiv(volume0, spotX18, FeeMath.EWVWAP_PRECISION);
        // Cache the slot once for the zero-history check and the fusion formula
        // (no intervening write; avoids a second warm SLOAD on the history path).
        uint256 prevWeightedVolume0 = state.weightedVolume0;
        if (prevWeightedVolume0 == 0) {
            state.weightedVolume0 = volume0;
            state.weightedPriceVolume0 = priceVolume;
            state.ewVWAPX18 = spotX18;
            return;
        }

        uint256 alphaR = FeeMath.PPM_BASE - DynamicFeeMath.FEE_ALPHA;
        uint256 newWeightedVolume0 = FullMath.mulDiv(DynamicFeeMath.FEE_ALPHA, volume0, FeeMath.PPM_BASE)
            + FullMath.mulDiv(alphaR, prevWeightedVolume0, FeeMath.PPM_BASE);
        uint256 newWeightedPriceVolume0 = FullMath.mulDiv(DynamicFeeMath.FEE_ALPHA, priceVolume, FeeMath.PPM_BASE)
            + FullMath.mulDiv(alphaR, state.weightedPriceVolume0, FeeMath.PPM_BASE);
        state.weightedVolume0 = newWeightedVolume0;
        state.weightedPriceVolume0 = newWeightedPriceVolume0;
        if (newWeightedVolume0 > 0) {
            state.ewVWAPX18 = FullMath.mulDiv(newWeightedPriceVolume0, FeeMath.EWVWAP_PRECISION, newWeightedVolume0);
        }
    }

    /// @inheritdoc IDynamicFeeFacet
    /// @dev Under delegatecall the hook address is implicit (`address(this) == hook`), so the facet reads
    ///      per-pool state directly from the shared namespace.
    function quote(PrepareSwapFeeParams calldata params)
        external
        view
        override
        onlyViaRouter
        returns (PreparedSwapFee memory result)
    {
        DynamicFeeState memory state = _memeverseUniswapHookStorage.dynamicFeeState[params.poolId];
        // Refresh volatility anchor/carry via the shared plan so preview matches execution exactly.
        if (state.volAnchorSqrtPriceX96 == 0) state.volAnchorSqrtPriceX96 = params.preSqrtPriceX96;
        (bool shouldRefresh, uint24 refreshedCarry) =
            DynamicFeeMath.volatilityRefreshPlan(state.volLastMoveTs, state.volDeviationAccumulator);
        if (shouldRefresh) {
            (state.volAnchorSqrtPriceX96, state.volCarryAccumulator, state.volDeviationAccumulator) =
                DynamicFeeMath.volatilityRefreshApply(params.preSqrtPriceX96, refreshedCarry);
        }

        // slither-disable-next-line uninitialized-local // capacity is read only at calculateFinalQuoteCurve (L156), dominated by the early-return `if (params.amountSpecified == 0) return result;` at L151; when amountSpecified==0 capacity is never read.
        OrdinarySwapMath.CapacityResult memory capacity;
        if (params.amountSpecified != 0) {
            capacity = OrdinarySwapMath.calculateCapacity(
                params.liquidity, params.preSqrtPriceX96, params.zeroForOne, params.sqrtPriceLimitX96
            );
        }

        (DynamicFeeMath.DynamicFeeQuote memory selectedFee, OrdinarySwapMath.CurveResult memory originalCurve) =
            _selectDynamicFee(state, params);
        _copySelectedFee(result, selectedFee);
        if (params.amountSpecified == 0) return result;

        OrdinarySwapMath.FeeSplit memory feeSplit = OrdinarySwapMath.deriveFeeSplit(selectedFee.feeBps);
        OrdinarySwapMath.SettlementPlan memory settlementPlan =
            OrdinarySwapMath.deriveSettlementPlan(params.amountSpecified, params.protocolFeeOnInput, feeSplit);
        OrdinarySwapMath.CurveResult memory finalCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            params.liquidity,
            params.preSqrtPriceX96,
            params.zeroForOne,
            params.amountSpecified,
            settlementPlan,
            originalCurve,
            capacity
        );
        OrdinarySwapMath.FinalSettlement memory finalSettlement = OrdinarySwapMath.deriveFinalSettlement(
            params.amountSpecified, params.protocolFeeOnInput, feeSplit, settlementPlan, finalCurve
        );
        _revertIfQuoteAmountsAreNotRepresentable(finalCurve, finalSettlement);

        result.estimatedInputAmount = finalSettlement.userInput;
        result.estimatedOutputAmount = finalSettlement.userNetOutput;
        result.estimatedGrossOutputAmount = finalCurve.coreGrossOutput;
    }

    /// @dev Computes the original request curve once, then selects the fee from that unmodified curve.
    function _selectDynamicFee(DynamicFeeState memory state, PrepareSwapFeeParams calldata params)
        internal
        view
        returns (DynamicFeeMath.DynamicFeeQuote memory selectedFee, OrdinarySwapMath.CurveResult memory originalCurve)
    {
        originalCurve = OrdinarySwapMath.calculateOriginalRequestCurve(
            params.liquidity, params.preSqrtPriceX96, params.zeroForOne, params.amountSpecified
        );
        selectedFee = DynamicFeeMath.selectDynamicFee(
            state,
            _memeverseUniswapHookStorage.addressBatchState[params.trader][params.poolId],
            params.preSqrtPriceX96,
            originalCurve.postSqrtPriceX96,
            params.amountSpecified,
            DynamicFeeMath.quoteLaunchFeeBps(
                _memeverseUniswapHookStorage.defaultLaunchFeeConfig,
                _memeverseUniswapHookStorage.poolLaunchTimestamp[params.poolId]
            )
        );
    }

    function _copySelectedFee(PreparedSwapFee memory result, DynamicFeeMath.DynamicFeeQuote memory selectedFee)
        internal
        pure
    {
        result.feeBps = selectedFee.feeBps;
        result.pifPpm = selectedFee.pifPpm;
        result.adverseImpactPartBps = selectedFee.adverseImpactPartBps;
        result.volatilityPartBps = selectedFee.volatilityPartBps;
        result.shortImpactPartBps = selectedFee.shortImpactPartBps;
        result.spotBeforeX18 = selectedFee.spotBeforeX18;
        result.spotAfterX18 = selectedFee.spotAfterX18;
        result.isAdverse = selectedFee.isAdverse;
    }

    /// @dev PoolManager and hook callback deltas are int128. Reject known-unrepresentable quotes early.
    // slither-disable-next-line timestamp // pure function with no block.timestamp read; slither mis-attributed (real reads are in updateAfterSwap L76/81/89).
    function _revertIfQuoteAmountsAreNotRepresentable(
        OrdinarySwapMath.CurveResult memory finalCurve,
        OrdinarySwapMath.FinalSettlement memory finalSettlement
    ) internal pure {
        uint256 largestDelta = uint256(uint128(type(int128).max));
        if (
            finalCurve.coreInput > largestDelta || finalCurve.coreGrossOutput > largestDelta
                || finalSettlement.userInput > largestDelta || finalSettlement.userNetOutput > largestDelta
        ) revert OrdinarySwapMath.AmountNotRepresentable();
    }

    /// @dev Updates the post-swap volatility deviation accumulator: computes price-move steps against the
    ///      current anchor, adds incremental deviation, caps at VOL_MAX_DEVIATION_ACCUMULATOR, and stamps
    ///      volLastMoveTs only when the price actually moved (deltaSteps > 0). Anchor initialization on
    ///      first call mirrors DynamicFeeMath.refreshVolatilityAnchorAndCarry.
    function _updateVolatilityDeviationAccumulatorAfterSwap(DynamicFeeState storage state, uint160 postSqrtPriceX96)
        internal
    {
        // Cache packed-slot hot fields once for the zero-check and the non-zero path
        // (no intervening write; avoids a second warm SLOAD on the steady-state path).
        uint160 anchor = state.volAnchorSqrtPriceX96;
        uint24 carry = state.volCarryAccumulator;
        if (anchor == 0) {
            state.volAnchorSqrtPriceX96 = postSqrtPriceX96;
            return;
        }
        uint256 deltaSteps =
            DynamicFeeMath.volatilityDeltaSteps(anchor, postSqrtPriceX96, DynamicFeeMath.VOL_DEVIATION_STEP_BPS);
        uint256 updatedAccumulator = uint256(carry) + deltaSteps * uint256(DynamicFeeMath.VOL_INCREMENT_PER_STEP);
        if (updatedAccumulator > FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR) {
            updatedAccumulator = FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR;
        }
        state.volDeviationAccumulator = uint24(updatedAccumulator);
        if (deltaSteps > 0) state.volLastMoveTs = uint40(block.timestamp);
    }
}
