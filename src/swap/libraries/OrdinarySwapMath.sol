// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FeeMath} from "./FeeMath.sol";
import {MemeversePoolKeyLib} from "./MemeversePoolKeyLib.sol";

/// @title OrdinarySwapMath
/// @notice Pure fee, capacity, and quote math for ordinary dynamic swaps.
/// @dev The library has no storage or external calls. Amounts sent to v4 use its native zero-fee swap math;
///      Memeverse LP and protocol fees are derived separately from the original user request.
library OrdinarySwapMath {
    struct FeeSplit {
        uint256 totalFeeBps;
        uint256 lpFeeBps;
        uint256 protocolFeeBps;
    }

    struct SettlementPlan {
        uint256 coreInputTarget;
        uint256 coreOutputTarget;
        uint256 knownLpInputFee;
        uint256 knownProtocolInputFee;
    }

    struct CurveResult {
        uint256 coreInput;
        uint256 coreGrossOutput;
        uint160 postSqrtPriceX96;
    }

    struct CapacityResult {
        uint256 inputCapacity;
        uint256 outputCapacity;
        uint160 effectiveSqrtPriceStopX96;
        bool stopsAtFullRangeEndpoint;
    }

    struct FinalSettlement {
        uint256 userInput;
        uint256 userNetOutput;
        uint256 lpFee;
        uint256 protocolFee;
    }

    error InvalidFeeBps();
    error ZeroCoreInput();
    error ExactOutputAtFullFee();
    error InvalidRawSqrtPriceLimit();
    error InvalidActiveLiquidity();
    error InvalidPreSqrtPrice();
    error FinalTargetNotExecutable();
    error AmountNotRepresentable();
    error FinalTargetNotMet();

    function deriveFeeSplit(uint256 totalFeeBps) internal pure returns (FeeSplit memory feeSplit) {
        if (totalFeeBps > FeeMath.BPS_BASE) revert InvalidFeeBps();
        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(totalFeeBps);
        feeSplit = FeeSplit({totalFeeBps: totalFeeBps, lpFeeBps: lpFeeBps, protocolFeeBps: protocolFeeBps});
    }

    /// @notice Derives the transformed core swap target (the amount v4 actually moves) and, when the fee leg is on
    ///         the input side, the known LP/protocol input fees. One call feeds all later capacity/final-curve math.
    /// @dev Settlement conservativeness by path (rounding invariant: the fee leg is never under-funded):
    ///      - exact-input (amountSpecified < 0): the user's gross input is known, so the fee is charged on input.
    ///        `coreInputTarget` rounds DOWN (`mulDiv`) so the core swap never moves more than the post-fee residual;
    ///        the surplus (gross - coreInputTarget) always covers the input fee.
    ///      - exact-output, fee-on-input (amountSpecified > 0, protocolFeeOnInput=true): the protocol fee is taken
    ///        on the input side later, so v4 is asked for the user's net output verbatim — `coreOutputTarget` is
    ///        passed through unchanged.
    ///      - exact-output, fee-on-output (amountSpecified > 0, protocolFeeOnInput=false): the fee is charged on
    ///        output, so v4 must over-deliver to leave room for the fee; `coreOutputTarget` rounds UP
    ///        (`mulDivRoundingUp`) on the lp-survival ratio so the requested net output is always achievable.
    ///      Full-fee exact-output (`totalFeeBps == BPS_BASE`, survival ratio 0) is unreachable and reverts early.
    function deriveSettlementPlan(int256 amountSpecified, bool protocolFeeOnInput, FeeSplit memory feeSplit)
        internal
        pure
        returns (SettlementPlan memory settlementPlan)
    {
        if (feeSplit.totalFeeBps > FeeMath.BPS_BASE) revert InvalidFeeBps();
        if (amountSpecified == 0) return settlementPlan;

        if (amountSpecified < 0) {
            uint256 requestedGrossInput = _absoluteExactInput(amountSpecified);
            uint256 inputFeeBps = protocolFeeOnInput ? feeSplit.totalFeeBps : feeSplit.lpFeeBps;
            settlementPlan.coreInputTarget =
                FullMath.mulDiv(requestedGrossInput, FeeMath.BPS_BASE - inputFeeBps, FeeMath.BPS_BASE);
            if (settlementPlan.coreInputTarget == 0) revert ZeroCoreInput();

            uint256 inputFee = requestedGrossInput - settlementPlan.coreInputTarget;
            if (protocolFeeOnInput) {
                (settlementPlan.knownLpInputFee, settlementPlan.knownProtocolInputFee) =
                    _splitRoundedInputFee(inputFee, feeSplit);
            } else {
                settlementPlan.knownLpInputFee = inputFee;
            }
            return settlementPlan;
        }

        if (feeSplit.totalFeeBps == FeeMath.BPS_BASE) revert ExactOutputAtFullFee();
        uint256 requestedNetOutput = uint256(amountSpecified);
        if (protocolFeeOnInput) {
            settlementPlan.coreOutputTarget = requestedNetOutput;
            return settlementPlan;
        }

        uint256 lpSurvivalBps = FeeMath.BPS_BASE - feeSplit.lpFeeBps;
        uint256 totalSurvivalBps = FeeMath.BPS_BASE - feeSplit.totalFeeBps;
        uint256 largestRepresentableRequest =
            FullMath.mulDiv(uint256(type(int256).max), totalSurvivalBps, lpSurvivalBps);
        if (requestedNetOutput > largestRepresentableRequest) revert AmountNotRepresentable();
        settlementPlan.coreOutputTarget = FullMath.mulDivRoundingUp(requestedNetOutput, lpSurvivalBps, totalSurvivalBps);
    }

    function validateRawSqrtPriceLimit(bool zeroForOne, uint160 rawLimitX96, uint160 preSqrtPriceX96) internal pure {
        bool valid = zeroForOne
            ? rawLimitX96 > TickMath.MIN_SQRT_PRICE && rawLimitX96 < preSqrtPriceX96
            : rawLimitX96 > preSqrtPriceX96 && rawLimitX96 < TickMath.MAX_SQRT_PRICE;
        if (!valid) revert InvalidRawSqrtPriceLimit();
    }

    function calculateOriginalRequestCurve(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified
    ) internal pure returns (CurveResult memory curveResult) {
        if (amountSpecified == 0) {
            curveResult.postSqrtPriceX96 = preSqrtPriceX96;
            return curveResult;
        }

        uint160 endpoint = zeroForOne ? _fullRangeLowerSqrtPriceX96() : _fullRangeUpperSqrtPriceX96();
        (curveResult.postSqrtPriceX96, curveResult.coreInput, curveResult.coreGrossOutput,) =
            SwapMath.computeSwapStep(preSqrtPriceX96, endpoint, activeLiquidity, amountSpecified, 0);
        if (amountSpecified > 0 && curveResult.coreGrossOutput != uint256(amountSpecified)) {
            revert FinalTargetNotExecutable();
        }
    }

    function calculateCapacity(uint128 activeLiquidity, uint160 preSqrtPriceX96, bool zeroForOne, uint160 rawLimitX96)
        internal
        pure
        returns (CapacityResult memory capacityResult)
    {
        if (activeLiquidity == 0) revert InvalidActiveLiquidity();

        uint160 lowerEndpoint = _fullRangeLowerSqrtPriceX96();
        uint160 upperEndpoint = _fullRangeUpperSqrtPriceX96();
        if (preSqrtPriceX96 < lowerEndpoint || preSqrtPriceX96 >= upperEndpoint) revert InvalidPreSqrtPrice();
        validateRawSqrtPriceLimit(zeroForOne, rawLimitX96, preSqrtPriceX96);

        if (zeroForOne) {
            capacityResult.effectiveSqrtPriceStopX96 = rawLimitX96 > lowerEndpoint ? rawLimitX96 : lowerEndpoint;
            capacityResult.stopsAtFullRangeEndpoint = capacityResult.effectiveSqrtPriceStopX96 == lowerEndpoint;
            capacityResult.inputCapacity = SqrtPriceMath.getAmount0Delta(
                capacityResult.effectiveSqrtPriceStopX96, preSqrtPriceX96, activeLiquidity, true
            );
            capacityResult.outputCapacity = SqrtPriceMath.getAmount1Delta(
                capacityResult.effectiveSqrtPriceStopX96, preSqrtPriceX96, activeLiquidity, false
            );
            return capacityResult;
        }

        capacityResult.effectiveSqrtPriceStopX96 = rawLimitX96 < upperEndpoint ? rawLimitX96 : upperEndpoint;
        capacityResult.stopsAtFullRangeEndpoint = capacityResult.effectiveSqrtPriceStopX96 == upperEndpoint;
        capacityResult.inputCapacity = SqrtPriceMath.getAmount1Delta(
            preSqrtPriceX96, capacityResult.effectiveSqrtPriceStopX96, activeLiquidity, true
        );
        capacityResult.outputCapacity = SqrtPriceMath.getAmount0Delta(
            preSqrtPriceX96, capacityResult.effectiveSqrtPriceStopX96, activeLiquidity, false
        );
    }

    /// @dev Replays the fee-free final step against the direction-specific capacity stop before v4 narrows its delta.
    function revertIfFinalTargetIsNotExecutable(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        int256 amountSpecified,
        SettlementPlan memory settlementPlan,
        CapacityResult memory capacityResult
    ) internal pure {
        if (amountSpecified == 0) return;
        uint256 target = amountSpecified < 0 ? settlementPlan.coreInputTarget : settlementPlan.coreOutputTarget;
        uint256 capacity = amountSpecified < 0 ? capacityResult.inputCapacity : capacityResult.outputCapacity;
        if (target > capacity || (capacityResult.stopsAtFullRangeEndpoint && target == capacity)) {
            revert FinalTargetNotExecutable();
        }
        if (!capacityResult.stopsAtFullRangeEndpoint) return;

        uint256 finalTarget = amountSpecified < 0 ? settlementPlan.coreInputTarget : settlementPlan.coreOutputTarget;
        int256 amountRemaining = amountSpecified < 0 ? -int256(finalTarget) : int256(finalTarget);
        (uint160 postSqrtPriceX96,,,) = SwapMath.computeSwapStep(
            preSqrtPriceX96, capacityResult.effectiveSqrtPriceStopX96, activeLiquidity, amountRemaining, 0
        );
        // The target/capacity gate above already established capacityResult.stopsAtFullRangeEndpoint == true
        // on this path, so only the post-swap price check remains.
        if (postSqrtPriceX96 == capacityResult.effectiveSqrtPriceStopX96) {
            revert FinalTargetNotExecutable();
        }
    }

    function calculateFinalQuoteCurve(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified,
        SettlementPlan memory settlementPlan,
        CurveResult memory originalCurve,
        CapacityResult memory capacityResult
    ) internal pure returns (CurveResult memory finalCurve) {
        if (amountSpecified == 0) {
            finalCurve.postSqrtPriceX96 = preSqrtPriceX96;
            return finalCurve;
        }
        revertIfFinalTargetIsNotExecutable(
            activeLiquidity, preSqrtPriceX96, amountSpecified, settlementPlan, capacityResult
        );

        uint256 originalTarget = amountSpecified < 0 ? _absoluteExactInput(amountSpecified) : uint256(amountSpecified);
        uint256 finalTarget = amountSpecified < 0 ? settlementPlan.coreInputTarget : settlementPlan.coreOutputTarget;
        bool originalEndsStrictlyInside = zeroForOne
            ? originalCurve.postSqrtPriceX96 > capacityResult.effectiveSqrtPriceStopX96
            : originalCurve.postSqrtPriceX96 < capacityResult.effectiveSqrtPriceStopX96;
        if (finalTarget == originalTarget && originalEndsStrictlyInside) return originalCurve;

        int256 amountRemaining;
        if (amountSpecified < 0) {
            uint256 largestExactInput = uint256(1) << 255;
            if (finalTarget > largestExactInput) revert AmountNotRepresentable();
            amountRemaining = finalTarget == largestExactInput ? type(int256).min : -int256(finalTarget);
        } else {
            if (finalTarget > uint256(type(int256).max)) revert AmountNotRepresentable();
            amountRemaining = int256(finalTarget);
        }

        (finalCurve.postSqrtPriceX96, finalCurve.coreInput, finalCurve.coreGrossOutput,) = SwapMath.computeSwapStep(
            preSqrtPriceX96, capacityResult.effectiveSqrtPriceStopX96, activeLiquidity, amountRemaining, 0
        );
        if (amountSpecified < 0 ? finalCurve.coreInput != finalTarget : finalCurve.coreGrossOutput != finalTarget) {
            revert FinalTargetNotExecutable();
        }
    }

    function deriveFinalSettlement(
        int256 amountSpecified,
        bool protocolFeeOnInput,
        FeeSplit memory feeSplit,
        SettlementPlan memory settlementPlan,
        CurveResult memory finalCurve
    ) internal pure returns (FinalSettlement memory finalSettlement) {
        if (feeSplit.totalFeeBps > FeeMath.BPS_BASE) revert InvalidFeeBps();
        if (amountSpecified == 0) return finalSettlement;

        if (amountSpecified < 0) {
            if (finalCurve.coreInput != settlementPlan.coreInputTarget) revert FinalTargetNotMet();
            finalSettlement.userInput = _absoluteExactInput(amountSpecified);
            finalSettlement.lpFee = settlementPlan.knownLpInputFee;
            if (protocolFeeOnInput) {
                finalSettlement.userNetOutput = finalCurve.coreGrossOutput;
                finalSettlement.protocolFee = settlementPlan.knownProtocolInputFee;
                return finalSettlement;
            }

            finalSettlement.userNetOutput = FullMath.mulDiv(
                finalCurve.coreGrossOutput,
                FeeMath.BPS_BASE - feeSplit.totalFeeBps,
                FeeMath.BPS_BASE - feeSplit.lpFeeBps
            );
            finalSettlement.protocolFee = finalCurve.coreGrossOutput - finalSettlement.userNetOutput;
            return finalSettlement;
        }

        if (finalCurve.coreGrossOutput < settlementPlan.coreOutputTarget) revert FinalTargetNotMet();
        uint256 appliedInputFeeBps = protocolFeeOnInput ? feeSplit.totalFeeBps : feeSplit.lpFeeBps;
        uint256 inputSurvivalBps = FeeMath.BPS_BASE - appliedInputFeeBps;
        uint256 largestCoreInput = FullMath.mulDiv(type(uint256).max, inputSurvivalBps, FeeMath.BPS_BASE);
        if (finalCurve.coreInput > largestCoreInput) revert AmountNotRepresentable();
        finalSettlement.userInput = FullMath.mulDivRoundingUp(finalCurve.coreInput, FeeMath.BPS_BASE, inputSurvivalBps);
        uint256 totalInputFee = finalSettlement.userInput - finalCurve.coreInput;

        if (protocolFeeOnInput) {
            finalSettlement.userNetOutput = finalCurve.coreGrossOutput;
            (finalSettlement.lpFee, finalSettlement.protocolFee) = _splitRoundedInputFee(totalInputFee, feeSplit);
            return finalSettlement;
        }

        finalSettlement.lpFee = totalInputFee;
        uint256 requestedNetOutput = uint256(amountSpecified);
        finalSettlement.protocolFee = settlementPlan.coreOutputTarget - requestedNetOutput;
        // Exact-output overfill is never charged again; it is added to the user's requested net output.
        finalSettlement.userNetOutput = finalCurve.coreGrossOutput - finalSettlement.protocolFee;
    }

    function _splitRoundedInputFee(uint256 totalInputFee, FeeSplit memory feeSplit)
        private
        pure
        returns (uint256 lpFee, uint256 protocolFee)
    {
        if (feeSplit.totalFeeBps == 0) return (0, 0);
        protocolFee = FullMath.mulDiv(totalInputFee, feeSplit.protocolFeeBps, feeSplit.totalFeeBps);
        lpFee = totalInputFee - protocolFee;
    }

    function _absoluteExactInput(int256 amountSpecified) internal pure returns (uint256 absoluteAmount) {
        unchecked {
            // Exact-input uses the negative int256 range, whose minimum magnitude is one larger than int256.max.
            absoluteAmount = uint256(-amountSpecified);
        }
    }

    function _fullRangeLowerSqrtPriceX96() private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK);
    }

    function _fullRangeUpperSqrtPriceX96() private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_UPPER_TICK);
    }
}
