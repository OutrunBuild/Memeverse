// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FeeMath} from "../../src/swap/libraries/FeeMath.sol";

/// @notice Focused tests for shared fee split math and pure dynamic-fee math primitives.
/// @dev The dynamic-fee boundary cases call `FeeMath` directly to isolate spot conversion, price-move ppm,
///      and volatility square-root fee calculations from facet storage wiring.
contract FeeMathTest is Test {
    // ── sqrt price / price-move constants ──
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant PRICE_MOVE_59_999_UP_POST = 81570347323081481549928488305;
    uint160 internal constant PRICE_MOVE_60_000_UP_POST = 81570385799687631547685037519;
    uint160 internal constant PRICE_MOVE_59_999_DOWN_POST = 76814594370895530393110659596;
    uint160 internal constant PRICE_MOVE_60_000_DOWN_POST = 76814553512101337462432816780;
    uint160 internal constant PRICE_MOVE_149_999_UP_POST = 84962701926156676880859777928;
    uint160 internal constant PRICE_MOVE_150_000_UP_POST = 84962738866485953687210797630;
    uint160 internal constant PRICE_MOVE_149_999_DOWN_POST = 73044799624479866430778194544;
    uint160 internal constant PRICE_MOVE_150_000_DOWN_POST = 73044756656988588048856075193;
    uint160 internal constant PRICE_MOVE_FALLBACK_OUTSIDE_UP_POST = 84962738866485953687210797631;
    uint160 internal constant PRICE_MOVE_FALLBACK_OUTSIDE_DOWN_POST = 73044756656988588048856075192;
    uint160 internal constant PRICE_MOVE_999_UP_POST = 79267727102650874847096721154;
    uint160 internal constant PRICE_MOVE_1000_UP_POST = 79267766696949822951113378805;
    uint160 internal constant PRICE_MOVE_999_DOWN_POST = 79188578158425281008671148299;
    uint160 internal constant PRICE_MOVE_1000_DOWN_POST = 79188538524532033966444101902;
    uint160 internal constant SPOT_VECTOR_128_PLUS_1 = uint160((uint256(1) << 128) + 1);
    uint160 internal constant SPOT_VECTOR_128_127_PLUS_1 = uint160((uint256(1) << 128) + (uint256(1) << 127) + 1);

    function testSharedFeeMathKeepsProtocolAndLpSplitAtSixtyFiveThirtyFive() external pure {
        assertEq(FeeMath.BPS_BASE, 10_000, "bps base");
        assertEq(FeeMath.PROTOCOL_FEE_SHARE_BPS, 3_500, "protocol share");

        uint256[5] memory fees = [uint256(0), 100, 215, 5_000, 10_000];
        for (uint256 i; i < fees.length; ++i) {
            uint256 protocolFeeBps = FeeMath.protocolFeeBps(fees[i]);
            (uint256 lpFeeBps,) = FeeMath.splitFeeBps(fees[i]);
            (uint256 splitLpFeeBps, uint256 splitProtocolFeeBps) = FeeMath.splitFeeBps(fees[i]);
            assertEq(protocolFeeBps, FullMath.mulDiv(fees[i], 3_500, 10_000), "protocol split");
            assertEq(lpFeeBps, fees[i] - protocolFeeBps, "lp split");
            assertEq(protocolFeeBps + lpFeeBps, fees[i], "split sums to fee");
            assertEq(splitProtocolFeeBps, protocolFeeBps, "shared protocol split");
            assertEq(splitLpFeeBps, lpFeeBps, "shared lp split");
        }
    }

    /// @notice Fuzz: LP and protocol shares always sum exactly to the total fee.
    function testFuzzSplitSumInvariant(uint256 feeBps) external pure {
        vm.assume(feeBps <= 10_000);
        uint256 protocolFeeBps = FeeMath.protocolFeeBps(feeBps);
        (uint256 lpFeeBps,) = FeeMath.splitFeeBps(feeBps);
        assertEq(lpFeeBps + protocolFeeBps, feeBps, "split must sum to total fee");
    }

    /// @notice Fuzz: protocol fee matches mulDiv(feeBps, 3500, 10000) with floor rounding.
    function testFuzzProtocolFeeRatio(uint256 feeBps) external pure {
        vm.assume(feeBps <= 10_000);
        uint256 expected = (feeBps * 3_500) / 10_000;
        assertEq(FeeMath.protocolFeeBps(feeBps), expected, "protocol fee must match floor(feeBps*3500/10000)");
    }

    /// @notice Boundary: feeBps=1 gives protocol 0 and LP 1.
    function testFeeBpsOneProtocolGetsZero() external pure {
        assertEq(FeeMath.protocolFeeBps(1), 0, "feeBps=1: protocol rounds to 0");
        (uint256 lpFeeBpsOne,) = FeeMath.splitFeeBps(1);
        assertEq(lpFeeBpsOne, 1, "feeBps=1: LP gets full fee");
    }

    /// @notice Boundary: feeBps=2 gives protocol 0 (floor(0.7)=0) and LP 2.
    function testFeeBpsTwoProtocolGetsZero() external pure {
        assertEq(FeeMath.protocolFeeBps(2), 0, "feeBps=2: protocol rounds to 0");
        (uint256 lpFeeBpsTwo,) = FeeMath.splitFeeBps(2);
        assertEq(lpFeeBpsTwo, 2, "feeBps=2: LP gets full fee");
    }

    /// @notice Boundary: feeBps=7 gives protocol 2 (floor(2.45)=2) and LP 5. Note: feeBps=3 is the first value where protocol is non-zero.
    function testFeeBpsSevenProtocolGetsTwo() external pure {
        assertEq(FeeMath.protocolFeeBps(7), 2, "feeBps=7: protocol gets floor(2.45)=2");
        (uint256 lpFeeBpsSeven,) = FeeMath.splitFeeBps(7);
        assertEq(lpFeeBpsSeven, 5, "feeBps=7: LP gets 5");
    }

    // ── Pure dynamic-fee math boundary cases ──
    // These call FeeMath library functions directly and assert exact wide-integer results. They lock the
    // pure math primitives independently of the facet's storage wiring.

    /// @notice spotX18FromSqrtPrice must reproduce the exact X18 spot price across wide sqrt-price vectors,
    ///         including inputs whose 320-bit square straddles the hi/lo split boundary.
    function testSpotConversionHandlesWideSqrtPriceVectors() external pure {
        assertEq(FeeMath.spotX18FromSqrtPrice(SQRT_PRICE_1_1), 1e18, "one-to-one spot");
        assertEq(
            FeeMath.spotX18FromSqrtPrice(SPOT_VECTOR_128_PLUS_1),
            _expectedSpotX18(SPOT_VECTOR_128_PLUS_1),
            "wide spot low fractional"
        );
        assertEq(
            FeeMath.spotX18FromSqrtPrice(SPOT_VECTOR_128_127_PLUS_1),
            _expectedSpotX18(SPOT_VECTOR_128_127_PLUS_1),
            "wide spot high fractional"
        );
    }

    /// @notice priceMovePpmCapped returns the exact boundary ppm at the up/down rounding edges and clamps at PIF_CAP_PPM.
    function testPriceMovePpmReturnsExactBoundaryValues() external pure {
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_59_999_UP_POST), 59_999, "up 59_999");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_60_000_UP_POST), 60_000, "up 60_000");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_59_999_DOWN_POST), 59_999, "down 59_999");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_60_000_DOWN_POST), 60_000, "down 60_000");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_149_999_UP_POST), 149_999, "up 149_999");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_150_000_UP_POST), FeeMath.PIF_CAP_PPM, "up cap");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_149_999_DOWN_POST), 149_999, "down 149_999");
        assertEq(
            FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_150_000_DOWN_POST), FeeMath.PIF_CAP_PPM, "down cap"
        );
        assertEq(
            FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_FALLBACK_OUTSIDE_UP_POST),
            FeeMath.PIF_CAP_PPM,
            "up outside cap"
        );
        assertEq(
            FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_FALLBACK_OUTSIDE_DOWN_POST),
            FeeMath.PIF_CAP_PPM,
            "down outside cap"
        );
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_999_UP_POST), 999, "up 999");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_1000_UP_POST), 1000, "up 1000");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_999_DOWN_POST), 999, "down 999");
        assertEq(FeeMath.priceMovePpmCapped(SQRT_PRICE_1_1, PRICE_MOVE_1000_DOWN_POST), 1000, "down 1000");
    }

    /// @notice volatilitySqrtFeeBps maps the deviation accumulator to a sqrt-shaped fee, saturating at
    ///         VOL_MAX_FEE_BPS once the accumulator reaches VOL_MAX_DEVIATION_ACCUMULATOR.
    function testVolatilitySqrtFeeAndAccumulatorBoundaries() external pure {
        assertEq(FeeMath.volatilitySqrtFeeBps(0), 0, "zero accumulator");
        assertEq(
            FeeMath.volatilitySqrtFeeBps(uint256(FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR) / 2),
            35,
            "half accumulator sqrt fee"
        );
        assertEq(
            FeeMath.volatilitySqrtFeeBps(uint256(FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR)),
            FeeMath.VOL_MAX_FEE_BPS,
            "max accumulator"
        );
    }

    /// @dev Independent reference implementation of spotX18FromSqrtPrice using the public FeeMath.squareWide
    ///      helper, to cross-check the integer/fractional split and 1e18 scaling.
    function _expectedSpotX18(uint160 sqrtPriceX96) internal pure returns (uint256) {
        (uint256 squareHi, uint256 squareLo) = FeeMath.squareWide(sqrtPriceX96);
        uint256 integerPart = (squareHi << 64) | (squareLo >> 192);
        uint256 fractionalPart = squareLo & (FeeMath.Q192 - 1);
        return integerPart * FeeMath.EWVWAP_PRECISION
            + FullMath.mulDiv(fractionalPart, FeeMath.EWVWAP_PRECISION, FeeMath.Q192);
    }
}
