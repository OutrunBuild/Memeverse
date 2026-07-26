// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FeeMath} from "../../../src/swap/libraries/FeeMath.sol";
import {MemeversePoolKeyLib} from "../../../src/swap/libraries/MemeversePoolKeyLib.sol";
import {OrdinarySwapMath} from "../../../src/swap/libraries/OrdinarySwapMath.sol";

/// @notice Focused tests for ordinary dynamic-swap fee algebra, capacity, and quote curves.
contract OrdinarySwapMathTest is Test {
    uint128 internal constant ACTIVE_LIQUIDITY = 1e18;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function testDeriveFeeSplitUsesSharedProtocolShareAndRejectsFeesAboveOneHundredPercent() external {
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);

        assertEq(split.totalFeeBps, 215, "total fee");
        assertEq(
            split.protocolFeeBps, FullMath.mulDiv(215, FeeMath.PROTOCOL_FEE_SHARE_BPS, FeeMath.BPS_BASE), "protocol"
        );
        assertEq(split.lpFeeBps, split.totalFeeBps - split.protocolFeeBps, "lp remainder");

        vm.expectRevert(OrdinarySwapMath.InvalidFeeBps.selector);
        this.exposedDeriveFeeSplit(FeeMath.BPS_BASE + 1);
    }

    function testExactInputInputFeeUsesFloorCoreTargetAndSplitsRoundedFeeWithLpRemainder() external pure {
        uint256 requestedGrossInput = 10_003;
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(-int256(requestedGrossInput), true, split);
        uint256 expectedCoreInput =
            FullMath.mulDiv(requestedGrossInput, FeeMath.BPS_BASE - split.totalFeeBps, FeeMath.BPS_BASE);
        uint256 totalInputFee = requestedGrossInput - expectedCoreInput;
        uint256 expectedProtocolFee = FullMath.mulDiv(totalInputFee, split.protocolFeeBps, split.totalFeeBps);

        assertEq(plan.coreInputTarget, expectedCoreInput, "core input floor");
        assertEq(plan.coreOutputTarget, 0, "no output target");
        assertEq(plan.knownProtocolInputFee, expectedProtocolFee, "protocol share floor");
        assertEq(plan.knownLpInputFee, totalInputFee - expectedProtocolFee, "lp receives remainder");

        OrdinarySwapMath.FinalSettlement memory settlement = OrdinarySwapMath.deriveFinalSettlement(
            -int256(requestedGrossInput),
            true,
            split,
            plan,
            OrdinarySwapMath.CurveResult({
                coreInput: expectedCoreInput, coreGrossOutput: 8_765, postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
        assertEq(settlement.userInput, requestedGrossInput, "user gross input");
        assertEq(settlement.userNetOutput, 8_765, "core output is user output");
        assertEq(settlement.protocolFee, expectedProtocolFee, "protocol input fee");
        assertEq(settlement.lpFee, totalInputFee - expectedProtocolFee, "lp input fee");
    }

    function testExactInputOutputFeeUsesLpSurvivalAndOutputRemainder() external pure {
        uint256 requestedGrossInput = 10_003;
        uint256 coreGrossOutput = 8_765;
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(-int256(requestedGrossInput), false, split);
        uint256 expectedCoreInput =
            FullMath.mulDiv(requestedGrossInput, FeeMath.BPS_BASE - split.lpFeeBps, FeeMath.BPS_BASE);
        uint256 expectedUserOutput =
            FullMath.mulDiv(coreGrossOutput, FeeMath.BPS_BASE - split.totalFeeBps, FeeMath.BPS_BASE - split.lpFeeBps);

        assertEq(plan.coreInputTarget, expectedCoreInput, "core input after lp fee");
        assertEq(plan.knownLpInputFee, requestedGrossInput - expectedCoreInput, "known lp input fee");
        assertEq(plan.knownProtocolInputFee, 0, "protocol fee is output currency");

        OrdinarySwapMath.FinalSettlement memory settlement = OrdinarySwapMath.deriveFinalSettlement(
            -int256(requestedGrossInput),
            false,
            split,
            plan,
            OrdinarySwapMath.CurveResult({
                coreInput: expectedCoreInput, coreGrossOutput: coreGrossOutput, postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
        assertEq(settlement.userInput, requestedGrossInput, "user gross input");
        assertEq(settlement.userNetOutput, expectedUserOutput, "net output floor");
        assertEq(settlement.lpFee, requestedGrossInput - expectedCoreInput, "lp input fee");
        assertEq(settlement.protocolFee, coreGrossOutput - expectedUserOutput, "protocol receives output remainder");
    }

    function testExactOutputInputFeeGrossesUpInputAndGivesOverfillToUser() external pure {
        uint256 requestedNetOutput = 7_777;
        uint256 coreInput = 8_765;
        uint256 outputOverfill = 11;
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(int256(requestedNetOutput), true, split);
        uint256 expectedUserInput =
            FullMath.mulDivRoundingUp(coreInput, FeeMath.BPS_BASE, FeeMath.BPS_BASE - split.totalFeeBps);
        uint256 totalInputFee = expectedUserInput - coreInput;
        uint256 expectedProtocolFee = FullMath.mulDiv(totalInputFee, split.protocolFeeBps, split.totalFeeBps);

        assertEq(plan.coreOutputTarget, requestedNetOutput, "net output is core target");
        OrdinarySwapMath.FinalSettlement memory settlement = OrdinarySwapMath.deriveFinalSettlement(
            int256(requestedNetOutput),
            true,
            split,
            plan,
            OrdinarySwapMath.CurveResult({
                coreInput: coreInput,
                coreGrossOutput: requestedNetOutput + outputOverfill,
                postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
        assertEq(settlement.userInput, expectedUserInput, "grossed-up user input");
        assertEq(settlement.userNetOutput, requestedNetOutput + outputOverfill, "overfill belongs to user");
        assertEq(settlement.protocolFee, expectedProtocolFee, "protocol share floor");
        assertEq(settlement.lpFee, totalInputFee - expectedProtocolFee, "lp remainder");
    }

    function testExactOutputOutputFeeGrossesUpTargetAndDoesNotChargeOverfill() external pure {
        uint256 requestedNetOutput = 7_777;
        uint256 coreInput = 8_765;
        uint256 outputOverfill = 11;
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(int256(requestedNetOutput), false, split);
        uint256 expectedGrossOutput = FullMath.mulDivRoundingUp(
            requestedNetOutput, FeeMath.BPS_BASE - split.lpFeeBps, FeeMath.BPS_BASE - split.totalFeeBps
        );
        uint256 expectedUserInput =
            FullMath.mulDivRoundingUp(coreInput, FeeMath.BPS_BASE, FeeMath.BPS_BASE - split.lpFeeBps);
        uint256 fixedProtocolFee = expectedGrossOutput - requestedNetOutput;

        assertEq(plan.coreOutputTarget, expectedGrossOutput, "gross output target ceil");
        OrdinarySwapMath.FinalSettlement memory settlement = OrdinarySwapMath.deriveFinalSettlement(
            int256(requestedNetOutput),
            false,
            split,
            plan,
            OrdinarySwapMath.CurveResult({
                coreInput: coreInput,
                coreGrossOutput: expectedGrossOutput + outputOverfill,
                postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
        assertEq(settlement.userInput, expectedUserInput, "input grossed up for lp fee");
        assertEq(settlement.userNetOutput, requestedNetOutput + outputOverfill, "overfill belongs to user");
        assertEq(settlement.lpFee, expectedUserInput - coreInput, "lp input fee");
        assertEq(settlement.protocolFee, fixedProtocolFee, "protocol fee fixed before overfill");
    }

    function testZeroFeeIsIdentityForEverySettlementPath() external pure {
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(0);
        for (uint256 requestKind; requestKind < 2; ++requestKind) {
            for (uint256 feeSide; feeSide < 2; ++feeSide) {
                bool exactInput = requestKind == 0;
                bool protocolFeeOnInput = feeSide == 0;
                int256 amountSpecified = exactInput ? -int256(101) : int256(101);
                OrdinarySwapMath.SettlementPlan memory plan =
                    OrdinarySwapMath.deriveSettlementPlan(amountSpecified, protocolFeeOnInput, split);
                OrdinarySwapMath.CurveResult memory curve = OrdinarySwapMath.CurveResult({
                    coreInput: exactInput ? 101 : 99,
                    coreGrossOutput: exactInput ? 99 : 101,
                    postSqrtPriceX96: SQRT_PRICE_1_1 - 1
                });
                OrdinarySwapMath.FinalSettlement memory settlement =
                    OrdinarySwapMath.deriveFinalSettlement(amountSpecified, protocolFeeOnInput, split, plan, curve);

                assertEq(settlement.userInput, curve.coreInput, "identity input");
                assertEq(settlement.userNetOutput, curve.coreGrossOutput, "identity output");
                assertEq(settlement.lpFee, 0, "zero lp fee");
                assertEq(settlement.protocolFee, 0, "zero protocol fee");
            }
        }
    }

    function testOneWeiAndOneHundredPercentBoundaries() external {
        OrdinarySwapMath.FeeSplit memory zeroFee = OrdinarySwapMath.deriveFeeSplit(0);
        OrdinarySwapMath.SettlementPlan memory oneWeiPlan =
            OrdinarySwapMath.deriveSettlementPlan(-int256(1), true, zeroFee);
        assertEq(oneWeiPlan.coreInputTarget, 1, "one wei core input allowed");

        OrdinarySwapMath.FeeSplit memory dustFee = OrdinarySwapMath.deriveFeeSplit(3);
        OrdinarySwapMath.SettlementPlan memory grossedDust =
            OrdinarySwapMath.deriveSettlementPlan(int256(1), false, dustFee);
        assertEq(grossedDust.coreOutputTarget, 2, "sub-wei output fee rounds gross target up");

        OrdinarySwapMath.FeeSplit memory fullFee = OrdinarySwapMath.deriveFeeSplit(FeeMath.BPS_BASE);
        vm.expectRevert(OrdinarySwapMath.ZeroCoreInput.selector);
        this.exposedDeriveSettlementPlan(-int256(1), true, fullFee);

        OrdinarySwapMath.SettlementPlan memory outputFeePlan =
            OrdinarySwapMath.deriveSettlementPlan(-int256(10_000), false, fullFee);
        OrdinarySwapMath.FinalSettlement memory outputFeeSettlement = OrdinarySwapMath.deriveFinalSettlement(
            -int256(10_000),
            false,
            fullFee,
            outputFeePlan,
            OrdinarySwapMath.CurveResult({
                coreInput: outputFeePlan.coreInputTarget, coreGrossOutput: 1_000, postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
        assertEq(outputFeeSettlement.userNetOutput, 0, "full fee output rounds to zero");
        assertEq(outputFeeSettlement.protocolFee, 1_000, "entire output is protocol fee");

        vm.expectRevert(OrdinarySwapMath.ExactOutputAtFullFee.selector);
        this.exposedDeriveSettlementPlan(int256(1), true, fullFee);
        vm.expectRevert(OrdinarySwapMath.ExactOutputAtFullFee.selector);
        this.exposedDeriveSettlementPlan(int256(1), false, fullFee);
    }

    function testExactOutputTargetMustFitPositiveInt256() external {
        OrdinarySwapMath.FeeSplit memory almostFullFee = OrdinarySwapMath.deriveFeeSplit(FeeMath.BPS_BASE - 1);

        vm.expectRevert(OrdinarySwapMath.AmountNotRepresentable.selector);
        this.exposedDeriveSettlementPlan(type(int256).max, false, almostFullFee);
    }

    function testRawPriceLimitValidationRejectsZeroGlobalEndpointsWrongDirectionAndCurrentPrice() external {
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(true, 0, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(true, TickMath.MIN_SQRT_PRICE, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(true, SQRT_PRICE_1_1 + 1, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(true, SQRT_PRICE_1_1, SQRT_PRICE_1_1);

        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(false, 0, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(false, TickMath.MAX_SQRT_PRICE, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(false, SQRT_PRICE_1_1 - 1, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidRawSqrtPriceLimit.selector);
        this.exposedValidateRawSqrtPriceLimit(false, SQRT_PRICE_1_1, SQRT_PRICE_1_1);
    }

    function testCapacityMatchesV4DeltasForInternalLimitsInBothDirections() external pure {
        uint160 lowerInternalLimit = TickMath.getSqrtPriceAtTick(-200);
        uint160 upperInternalLimit = TickMath.getSqrtPriceAtTick(200);

        OrdinarySwapMath.CapacityResult memory zeroForOneCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, lowerInternalLimit);
        assertEq(
            zeroForOneCapacity.inputCapacity,
            SqrtPriceMath.getAmount0Delta(lowerInternalLimit, SQRT_PRICE_1_1, ACTIVE_LIQUIDITY, true),
            "zeroForOne input round up"
        );
        assertEq(
            zeroForOneCapacity.outputCapacity,
            SqrtPriceMath.getAmount1Delta(lowerInternalLimit, SQRT_PRICE_1_1, ACTIVE_LIQUIDITY, false),
            "zeroForOne output round down"
        );
        assertEq(zeroForOneCapacity.effectiveSqrtPriceStopX96, lowerInternalLimit, "lower internal stop");
        assertFalse(zeroForOneCapacity.stopsAtFullRangeEndpoint, "lower stop is internal");

        OrdinarySwapMath.CapacityResult memory oneForZeroCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, false, upperInternalLimit);
        assertEq(
            oneForZeroCapacity.inputCapacity,
            SqrtPriceMath.getAmount1Delta(SQRT_PRICE_1_1, upperInternalLimit, ACTIVE_LIQUIDITY, true),
            "oneForZero input round up"
        );
        assertEq(
            oneForZeroCapacity.outputCapacity,
            SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, upperInternalLimit, ACTIVE_LIQUIDITY, false),
            "oneForZero output round down"
        );
        assertEq(oneForZeroCapacity.effectiveSqrtPriceStopX96, upperInternalLimit, "upper internal stop");
        assertFalse(oneForZeroCapacity.stopsAtFullRangeEndpoint, "upper stop is internal");
    }

    function testCapacityClipsOutwardLimitsToSharedFullRangeEndpoints() external pure {
        uint160 lowerEndpoint = _lowerEndpoint();
        uint160 upperEndpoint = _upperEndpoint();

        OrdinarySwapMath.CapacityResult memory zeroForOneCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, lowerEndpoint - 1);
        assertEq(zeroForOneCapacity.effectiveSqrtPriceStopX96, lowerEndpoint, "clip to lower endpoint");
        assertTrue(zeroForOneCapacity.stopsAtFullRangeEndpoint, "lower endpoint marker");

        OrdinarySwapMath.CapacityResult memory oneForZeroCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, false, upperEndpoint + 1);
        assertEq(oneForZeroCapacity.effectiveSqrtPriceStopX96, upperEndpoint, "clip to upper endpoint");
        assertTrue(oneForZeroCapacity.stopsAtFullRangeEndpoint, "upper endpoint marker");
    }

    function testCapacityAllowsLowerEndpointPrePriceOnlyForAnInwardMove() external pure {
        uint160 lowerEndpoint = _lowerEndpoint();
        uint160 inwardLimit = TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK + 200);

        OrdinarySwapMath.CapacityResult memory inwardCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, lowerEndpoint, false, inwardLimit);
        assertGt(inwardCapacity.inputCapacity, 0, "inward input capacity");
        assertGt(inwardCapacity.outputCapacity, 0, "inward output capacity");

        OrdinarySwapMath.CapacityResult memory outwardCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, lowerEndpoint, true, lowerEndpoint - 1);
        assertEq(outwardCapacity.inputCapacity, 0, "no outward input capacity");
        assertEq(outwardCapacity.outputCapacity, 0, "no outward output capacity");
        assertTrue(outwardCapacity.stopsAtFullRangeEndpoint, "outward stop is endpoint");
    }

    function testCapacityRejectsZeroLiquidityAndPrePricesOutsideTheActiveFullRange() external {
        uint160 lowerEndpoint = _lowerEndpoint();
        uint160 upperEndpoint = _upperEndpoint();

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        this.exposedCalculateCapacity(0, SQRT_PRICE_1_1, true, lowerEndpoint);
        vm.expectRevert(OrdinarySwapMath.InvalidPreSqrtPrice.selector);
        this.exposedCalculateCapacity(ACTIVE_LIQUIDITY, lowerEndpoint - 1, false, SQRT_PRICE_1_1);
        vm.expectRevert(OrdinarySwapMath.InvalidPreSqrtPrice.selector);
        this.exposedCalculateCapacity(ACTIVE_LIQUIDITY, upperEndpoint, true, SQRT_PRICE_1_1);
    }

    function testInternalCapacityEqualityIsExecutableButFullRangeEqualityReverts() external {
        uint160 internalStop = TickMath.getSqrtPriceAtTick(-200);
        OrdinarySwapMath.CapacityResult memory internalCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, internalStop);
        OrdinarySwapMath.SettlementPlan memory exactInputAtInternal = OrdinarySwapMath.SettlementPlan({
            coreInputTarget: internalCapacity.inputCapacity,
            coreOutputTarget: 0,
            knownLpInputFee: 0,
            knownProtocolInputFee: 0
        });
        OrdinarySwapMath.revertIfFinalTargetIsNotExecutable(
            -int256(internalCapacity.inputCapacity), exactInputAtInternal, internalCapacity
        );

        OrdinarySwapMath.CapacityResult memory endpointCapacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, _lowerEndpoint());
        OrdinarySwapMath.SettlementPlan memory exactInputAtEndpoint = OrdinarySwapMath.SettlementPlan({
            coreInputTarget: endpointCapacity.inputCapacity,
            coreOutputTarget: 0,
            knownLpInputFee: 0,
            knownProtocolInputFee: 0
        });
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        this.exposedRevertIfFinalTargetIsNotExecutable(
            -int256(endpointCapacity.inputCapacity), exactInputAtEndpoint, endpointCapacity
        );

        OrdinarySwapMath.SettlementPlan memory exactOutputAtEndpoint = OrdinarySwapMath.SettlementPlan({
            coreInputTarget: 0,
            coreOutputTarget: endpointCapacity.outputCapacity,
            knownLpInputFee: 0,
            knownProtocolInputFee: 0
        });
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        this.exposedRevertIfFinalTargetIsNotExecutable(
            int256(endpointCapacity.outputCapacity), exactOutputAtEndpoint, endpointCapacity
        );
    }

    function testOriginalExactInputCurveSaturatesAtFullRangeEndpointInBothDirections() external pure {
        for (uint256 direction; direction < 2; ++direction) {
            bool zeroForOne = direction == 0;
            uint160 endpoint = zeroForOne ? _lowerEndpoint() : _upperEndpoint();
            uint256 endpointInputCapacity = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(endpoint, SQRT_PRICE_1_1, ACTIVE_LIQUIDITY, true)
                : SqrtPriceMath.getAmount1Delta(SQRT_PRICE_1_1, endpoint, ACTIVE_LIQUIDITY, true);
            OrdinarySwapMath.CurveResult memory curve = OrdinarySwapMath.calculateOriginalRequestCurve(
                ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, zeroForOne, -int256(endpointInputCapacity + 1)
            );

            assertEq(curve.coreInput, endpointInputCapacity, "input saturates at endpoint capacity");
            assertEq(curve.postSqrtPriceX96, endpoint, "post price saturates at endpoint");
        }
    }

    function testOriginalExactOutputCurveAllowsEndpointEqualityButRejectsExcessCapacity() external {
        for (uint256 direction; direction < 2; ++direction) {
            bool zeroForOne = direction == 0;
            uint160 endpoint = zeroForOne ? _lowerEndpoint() : _upperEndpoint();
            uint256 endpointOutputCapacity = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(endpoint, SQRT_PRICE_1_1, ACTIVE_LIQUIDITY, false)
                : SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, endpoint, ACTIVE_LIQUIDITY, false);
            OrdinarySwapMath.CurveResult memory curve = OrdinarySwapMath.calculateOriginalRequestCurve(
                ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, zeroForOne, int256(endpointOutputCapacity)
            );
            assertEq(curve.coreGrossOutput, endpointOutputCapacity, "endpoint output capacity");
            assertEq(curve.postSqrtPriceX96, endpoint, "selection curve may reach endpoint");

            vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
            this.exposedCalculateOriginalRequestCurve(
                ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, zeroForOne, int256(endpointOutputCapacity + 1)
            );
        }
    }

    function testFinalQuoteReusesStrictlyInternalUnchangedOriginalCurve() external pure {
        int256 amountSpecified = -int256(1e12);
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(0);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(amountSpecified, true, split);
        OrdinarySwapMath.CurveResult memory original =
            OrdinarySwapMath.calculateOriginalRequestCurve(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified);
        uint160 rawLimit = TickMath.getSqrtPriceAtTick(-400);
        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, rawLimit);
        assertGt(original.postSqrtPriceX96, capacity.effectiveSqrtPriceStopX96, "original is strictly internal");

        OrdinarySwapMath.CurveResult memory finalCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified, plan, original, capacity
        );
        assertEq(finalCurve.coreInput, original.coreInput, "reused input");
        assertEq(finalCurve.coreGrossOutput, original.coreGrossOutput, "reused output");
        assertEq(finalCurve.postSqrtPriceX96, original.postSqrtPriceX96, "reused post price");
    }

    function testFinalQuoteUsesV4SwapStepForTransformedTargetAndInternalEquality() external pure {
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);
        int256 amountSpecified = -int256(1e12);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(amountSpecified, true, split);
        OrdinarySwapMath.CurveResult memory original =
            OrdinarySwapMath.calculateOriginalRequestCurve(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified);
        uint160 rawLimit = TickMath.getSqrtPriceAtTick(-400);
        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, rawLimit);
        (uint160 expectedPost, uint256 expectedInput, uint256 expectedOutput,) =
            SwapMath.computeSwapStep(SQRT_PRICE_1_1, rawLimit, ACTIVE_LIQUIDITY, -int256(plan.coreInputTarget), 0);

        OrdinarySwapMath.CurveResult memory finalCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified, plan, original, capacity
        );
        assertEq(finalCurve.coreInput, expectedInput, "swap step input");
        assertEq(finalCurve.coreGrossOutput, expectedOutput, "swap step output");
        assertEq(finalCurve.postSqrtPriceX96, expectedPost, "swap step post price");

        OrdinarySwapMath.SettlementPlan memory equalityPlan = OrdinarySwapMath.SettlementPlan({
            coreInputTarget: capacity.inputCapacity, coreOutputTarget: 0, knownLpInputFee: 0, knownProtocolInputFee: 0
        });
        OrdinarySwapMath.CurveResult memory equalityOriginal = OrdinarySwapMath.calculateOriginalRequestCurve(
            ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, -int256(capacity.inputCapacity)
        );
        OrdinarySwapMath.CurveResult memory equalityCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            ACTIVE_LIQUIDITY,
            SQRT_PRICE_1_1,
            true,
            -int256(capacity.inputCapacity),
            equalityPlan,
            equalityOriginal,
            capacity
        );
        assertEq(equalityCurve.coreInput, capacity.inputCapacity, "internal equality input");
        assertEq(equalityCurve.postSqrtPriceX96, rawLimit, "internal equality reaches limit");
    }

    function testFinalQuoteRejectsExactOutputThatRoundsToFullRangeEndpoint() external {
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(MemeversePoolKeyLib.DEFAULT_TICK_SPACING);
        uint160 lowerEndpoint = _lowerEndpoint();
        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(maxLiquidity, SQRT_PRICE_1_1, true, lowerEndpoint);
        uint256 coreOutputTarget = capacity.outputCapacity - 1;
        OrdinarySwapMath.FeeSplit memory zeroFee = OrdinarySwapMath.deriveFeeSplit(0);
        OrdinarySwapMath.SettlementPlan memory plan =
            OrdinarySwapMath.deriveSettlementPlan(int256(coreOutputTarget), true, zeroFee);
        OrdinarySwapMath.CurveResult memory original = OrdinarySwapMath.calculateOriginalRequestCurve(
            maxLiquidity, SQRT_PRICE_1_1, true, int256(coreOutputTarget)
        );

        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        this.exposedCalculateFinalQuoteCurve(
            maxLiquidity, SQRT_PRICE_1_1, true, int256(coreOutputTarget), plan, original, capacity
        );
    }

    function testFinalQuoteAllowsExactOutputEqualityAtInternalUserLimit() external pure {
        uint160 internalLimit = TickMath.getSqrtPriceAtTick(-200);
        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, internalLimit);
        int256 amountSpecified = int256(capacity.outputCapacity - 1);
        OrdinarySwapMath.SettlementPlan memory plan = OrdinarySwapMath.SettlementPlan({
            coreInputTarget: 0, coreOutputTarget: capacity.outputCapacity, knownLpInputFee: 0, knownProtocolInputFee: 0
        });
        OrdinarySwapMath.CurveResult memory original =
            OrdinarySwapMath.calculateOriginalRequestCurve(ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified);

        OrdinarySwapMath.CurveResult memory finalCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            ACTIVE_LIQUIDITY, SQRT_PRICE_1_1, true, amountSpecified, plan, original, capacity
        );
        assertEq(finalCurve.coreGrossOutput, capacity.outputCapacity, "internal output capacity equality");
        assertEq(finalCurve.postSqrtPriceX96, internalLimit, "internal equality reaches user limit");
    }

    function testFinalSettlementRejectsExactInputMismatchAndExactOutputShortfall() external {
        OrdinarySwapMath.FeeSplit memory split = OrdinarySwapMath.deriveFeeSplit(215);

        OrdinarySwapMath.SettlementPlan memory exactInputPlan =
            OrdinarySwapMath.deriveSettlementPlan(-int256(1_000), true, split);
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotMet.selector);
        this.exposedDeriveFinalSettlement(
            -int256(1_000),
            true,
            split,
            exactInputPlan,
            OrdinarySwapMath.CurveResult({
                coreInput: exactInputPlan.coreInputTarget - 1, coreGrossOutput: 1, postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );

        OrdinarySwapMath.SettlementPlan memory exactOutputPlan =
            OrdinarySwapMath.deriveSettlementPlan(int256(1_000), false, split);
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotMet.selector);
        this.exposedDeriveFinalSettlement(
            int256(1_000),
            false,
            split,
            exactOutputPlan,
            OrdinarySwapMath.CurveResult({
                coreInput: 1,
                coreGrossOutput: exactOutputPlan.coreOutputTarget - 1,
                postSqrtPriceX96: SQRT_PRICE_1_1 - 1
            })
        );
    }

    function exposedDeriveFeeSplit(uint256 totalFeeBps) external pure returns (OrdinarySwapMath.FeeSplit memory) {
        return OrdinarySwapMath.deriveFeeSplit(totalFeeBps);
    }

    function exposedDeriveSettlementPlan(
        int256 amountSpecified,
        bool protocolFeeOnInput,
        OrdinarySwapMath.FeeSplit memory feeSplit
    ) external pure returns (OrdinarySwapMath.SettlementPlan memory) {
        return OrdinarySwapMath.deriveSettlementPlan(amountSpecified, protocolFeeOnInput, feeSplit);
    }

    function exposedValidateRawSqrtPriceLimit(bool zeroForOne, uint160 rawLimitX96, uint160 preSqrtPriceX96)
        external
        pure
    {
        OrdinarySwapMath.validateRawSqrtPriceLimit(zeroForOne, rawLimitX96, preSqrtPriceX96);
    }

    function exposedCalculateOriginalRequestCurve(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified
    ) external pure returns (OrdinarySwapMath.CurveResult memory) {
        return OrdinarySwapMath.calculateOriginalRequestCurve(
            activeLiquidity, preSqrtPriceX96, zeroForOne, amountSpecified
        );
    }

    function exposedCalculateCapacity(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        uint160 rawLimitX96
    ) external pure returns (OrdinarySwapMath.CapacityResult memory) {
        return OrdinarySwapMath.calculateCapacity(activeLiquidity, preSqrtPriceX96, zeroForOne, rawLimitX96);
    }

    function exposedRevertIfFinalTargetIsNotExecutable(
        int256 amountSpecified,
        OrdinarySwapMath.SettlementPlan memory settlementPlan,
        OrdinarySwapMath.CapacityResult memory capacityResult
    ) external pure {
        OrdinarySwapMath.revertIfFinalTargetIsNotExecutable(amountSpecified, settlementPlan, capacityResult);
    }

    function exposedCalculateFinalQuoteCurve(
        uint128 activeLiquidity,
        uint160 preSqrtPriceX96,
        bool zeroForOne,
        int256 amountSpecified,
        OrdinarySwapMath.SettlementPlan memory settlementPlan,
        OrdinarySwapMath.CurveResult memory originalCurve,
        OrdinarySwapMath.CapacityResult memory capacityResult
    ) external pure returns (OrdinarySwapMath.CurveResult memory) {
        return OrdinarySwapMath.calculateFinalQuoteCurve(
            activeLiquidity, preSqrtPriceX96, zeroForOne, amountSpecified, settlementPlan, originalCurve, capacityResult
        );
    }

    function exposedDeriveFinalSettlement(
        int256 amountSpecified,
        bool protocolFeeOnInput,
        OrdinarySwapMath.FeeSplit memory feeSplit,
        OrdinarySwapMath.SettlementPlan memory settlementPlan,
        OrdinarySwapMath.CurveResult memory finalCurve
    ) external pure returns (OrdinarySwapMath.FinalSettlement memory) {
        return OrdinarySwapMath.deriveFinalSettlement(
            amountSpecified, protocolFeeOnInput, feeSplit, settlementPlan, finalCurve
        );
    }

    function _lowerEndpoint() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK);
    }

    function _upperEndpoint() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_UPPER_TICK);
    }
}
