// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FeeMath} from "src/swap/libraries/FeeMath.sol";
import {DynamicFeeMath} from "src/swap/libraries/DynamicFeeMath.sol";
import {IDynamicFeeFacet} from "src/swap/interfaces/IDynamicFeeFacet.sol";

/// @title FeeLibraryProperties
/// @notice Property-based tests for the pure fee math in FeeMath / DynamicFeeMath.
/// @dev Split-fee conservation is intentionally NOT duplicated here — it is
///      already covered by test/swap/FeeMath.t.sol (testFuzzSplitSumInvariant,
///      testFuzzProtocolFeeRatio) over the reachable domain (feeBps <= 10_000).
///      Oracles are algebraic identities or differently-composed expressions, never a
///      copy of the implementation formula (anti-tautology).
contract FeeLibraryProperties is Test {
    // ---------------------------------------------------------------------------------
    // composite dynamic fee selection
    // ---------------------------------------------------------------------------------

    /// @dev Fills DynamicFeeState fields inside their storage-type domains; `view`
    ///      because it uses bound()/block.timestamp.
    function _dynamicState(uint256 seed, uint160 anchor)
        internal
        view
        returns (IDynamicFeeFacet.DynamicFeeState memory s)
    {
        s.weightedVolume0 = bound(seed, 0, 1e36); // 0 explores the no-history branch
        s.weightedPriceVolume0 = bound(seed >> 32, 0, 1e60);
        s.ewVWAPX18 = bound(seed >> 64, 1, 1e36);
        s.volAnchorSqrtPriceX96 = anchor;
        s.volLastMoveTs = uint40(bound(seed >> 96, 0, block.timestamp + 1));
        s.volDeviationAccumulator = uint24(bound(seed >> 128, 0, type(uint24).max));
        s.volCarryAccumulator = uint24(bound(seed >> 152, 0, type(uint24).max));
        s.shortImpactPpm = uint24(bound(seed >> 176, 0, type(uint24).max));
        s.shortLastTs = uint40(bound(seed >> 200, 0, block.timestamp + 1));
    }

    function _batchState(uint256 seed) internal view returns (IDynamicFeeFacet.AddressBatchState memory b) {
        // Domain precondition: batchStartTs is written at batch-open time so it can never
        // exceed block.timestamp — populateDynamicFeeQuoteFromState computes
        // `block.timestamp - batchStartTs` unchecked, so a future timestamp would panic.
        b.batchStartTs = uint64(bound(seed, 0, block.timestamp)); // both in/out of the 3s window
        b.batchAccumPpm = uint192(bound(seed >> 32, 0, type(uint192).max));
    }

    /// @notice over the validated launch config domain (launchFeeBps <= BPS_BASE,
    ///         enforced by MemeverseUniswapHookUpgradeable::setDefaultLaunchFeeConfig)
    ///         and every storage-typed state/batch field, fee selection never reverts
    ///         and stays within [FEE_BASE_BPS, FEE_MAX_BPS].
    /// @dev Failure would mean: the FEE_MAX_BPS clamp was removed, a component sum
    ///      overflows in-domain, or the final launch raise escaped the cap.
    function testFuzz_SelectDynamicFeeBoundedAndPanicFree(
        uint256 stateSeed,
        uint256 batchSeed,
        uint160 preSeed,
        uint160 postSeed,
        int128 amountRaw,
        uint24 launchFeeBps
    ) external view {
        uint160 pre = uint160(bound(preSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 post = uint160(bound(postSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint256 launch = bound(launchFeeBps, 0, FeeMath.BPS_BASE);
        IDynamicFeeFacet.DynamicFeeState memory state = _dynamicState(stateSeed, pre);
        IDynamicFeeFacet.AddressBatchState memory batch = _batchState(batchSeed);

        DynamicFeeMath.DynamicFeeQuote memory quote =
            DynamicFeeMath.selectDynamicFee(state, batch, pre, post, int256(amountRaw), launch);

        assertGe(quote.feeBps, DynamicFeeMath.FEE_BASE_BPS, "fee below base");
        assertLe(quote.feeBps, DynamicFeeMath.FEE_MAX_BPS, "fee above cap");
        assertLe(quote.pifPpm, FeeMath.PIF_CAP_PPM, "pif uncapped");
    }

    // ---------------------------------------------------------------------------------
    // price-move (PIF) range over the whole TickMath domain
    // ---------------------------------------------------------------------------------

    /// @notice priceMovePpmCapped never reverts for valid sqrt prices, stays in
    ///         [0, PIF_CAP_PPM], and is zero exactly when prices are equal.
    /// @dev Up/down rounding asymmetry is documented behavior and deliberately NOT
    ///      asserted as a symmetry property.
    function testFuzz_PriceMoveCappedRange(uint160 preSeed, uint160 postSeed) external pure {
        uint160 pre = uint160(bound(preSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 post = uint160(bound(postSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint256 move = FeeMath.priceMovePpmCapped(pre, post);
        assertLe(move, FeeMath.PIF_CAP_PPM, "move above cap");
        if (pre == post) {
            assertEq(move, 0, "identical prices must give zero move");
        }
    }

    // ---------------------------------------------------------------------------------
    // volatility sqrt fee oracle, saturation semantics, overflow domain
    // ---------------------------------------------------------------------------------

    /// @notice the direct-multiply implementation matches an overflow-safe
    ///         recomposition (floor(sqrt(floor(x))) == floor(sqrt(x)) for integer x),
    ///         is <= 50 below the saturation marker and keeps growing (>= 50) past it —
    ///         "saturates" means "reaches 50", NOT clamping; the composite-cap property
    ///         carries the absolute bound.
    /// @dev Domain contract: accumulator <= (2^256-1)/2500 keeps `acc * 2500` inside
    ///      uint256. Larger values panic inside the library — the reachable uint24
    ///      storage domain sits 67 orders of magnitude below that boundary.
    function testFuzz_VolatilityFeeOracle(uint256 accHigh) external pure {
        uint256 acc = bound(accHigh, 0, (type(uint256).max / 2_500) - 1);
        uint256 fee = FeeMath.volatilitySqrtFeeBps(acc);
        assertEq(
            fee,
            Math.sqrt(
                FullMath.mulDiv(acc, uint256(FeeMath.VOL_MAX_FEE_BPS) ** 2, FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR)
            ),
            "oracle mismatch"
        );
        if (acc <= FeeMath.VOL_MAX_DEVIATION_ACCUMULATOR) {
            assertLe(fee, FeeMath.VOL_MAX_FEE_BPS, "pre-saturation fee above 50");
        } else {
            assertGe(fee, FeeMath.VOL_MAX_FEE_BPS, "post-marker fee below 50");
        }
    }

    /// @notice monotone non-decreasing over ordered pairs within the uint24
    ///         storage domain (the only reachable runtime domain).
    function testFuzz_VolatilityFeeMonotone(uint24 smallAcc, uint24 largeAcc) external pure {
        uint256 a = bound(smallAcc, 0, type(uint24).max);
        uint256 b = bound(largeAcc, a, type(uint24).max);
        assertLe(FeeMath.volatilitySqrtFeeBps(a), FeeMath.volatilitySqrtFeeBps(b), "not monotone");
    }

    // ---------------------------------------------------------------------------------
    // spot conversion exact oracle
    // ---------------------------------------------------------------------------------

    /// @notice spotX18FromSqrtPrice(p) == floor(p^2 * 1e18 / 2^192) for the full
    ///         uint160 domain, with the oracle computed by a differently-composed
    ///         expression (p * 1e18 fits 256 bits; mulDiv handles the 512-bit product),
    ///         so equality cross-checks squareWide's carry path.
    function testFuzz_SpotX18ExactOracle(uint160 p) external pure {
        assertEq(FeeMath.spotX18FromSqrtPrice(p), FullMath.mulDiv(uint256(p), uint256(p) * 1e18, 1 << 192), "spot off");
    }

    // ---------------------------------------------------------------------------------
    // launch-fee decay monotonicity, endpoints, bounds
    // ---------------------------------------------------------------------------------

    /// @notice the launch fee decays monotonically from exactly startFeeBps at
    ///         launch to exactly minFeeBps after the window, and never leaves
    ///         [minFeeBps, startFeeBps] for validated configs (min <= start <= BPS_BASE).
    function testFuzz_LaunchFeeMonotoneBounded(uint24 start, uint24 min, uint32 duration, uint40 nowOffset) external {
        start = uint24(bound(start, 1, FeeMath.BPS_BASE));
        min = uint24(bound(min, 1, start));
        duration = uint32(bound(duration, 1, 365 days));
        uint40 launchTs = 1_700_000_000;
        uint40 now_ = uint40(bound(nowOffset, launchTs, launchTs + duration + 1));
        vm.warp(now_);

        IDynamicFeeFacet.LaunchFeeConfig memory config =
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: start, minFeeBps: min, decayDurationSeconds: duration});
        uint256 fee = DynamicFeeMath.quoteLaunchFeeBps(config, launchTs);

        assertGe(fee, min, "fee below min");
        assertLe(fee, start, "fee above start");
        uint40 elapsedTotal = now_ - launchTs;
        if (elapsedTotal == 0) {
            assertEq(fee, start, "decay endpoint at t=0 must equal start");
        } else if (elapsedTotal >= duration) {
            assertEq(fee, min, "post-window must equal min");
        }
        // Monotonicity: one step later in time never yields a higher fee.
        vm.warp(uint40(Math.min(uint256(now_) + 1, uint256(launchTs) + duration + 1)));
        uint256 feeLater = DynamicFeeMath.quoteLaunchFeeBps(config, launchTs);
        assertLe(feeLater, fee, "decay not monotone");
    }

    /// @notice the normalized decay weight is exactly 1e18 at elapsed = 0,
    ///         exactly 0 at elapsed = duration, and within [0, 1e18] in between.
    function testFuzz_NormalizedDecayWadBounds(uint256 elapsed, uint256 duration) external pure {
        duration = bound(duration, 1, 365 days);
        elapsed = bound(elapsed, 0, duration);
        uint256 wad = DynamicFeeMath.normalizedLaunchDecayWad(elapsed, duration);
        assertLe(wad, 1e18, "wad above 1e18");
        if (elapsed == 0) assertEq(wad, 1e18, "endpoint at 0");
        if (elapsed == duration) assertEq(wad, 0, "endpoint at duration");
    }

    // ---------------------------------------------------------------------------------
    // Supporting: linear decay bounded and window-terminating
    // ---------------------------------------------------------------------------------

    /// @notice Supporting property: decayLinearPpm never exceeds the accumulator and hits zero once
    ///         the window has fully elapsed.
    function testFuzz_DecayLinearPpmBounded(uint96 acc, uint64 lastTsOffset, uint32 window) external {
        acc = uint96(bound(acc, 1, type(uint96).max));
        window = uint32(bound(window, 1, 1 days));
        uint40 nowFixed = 2 ** 32; // fixed clock; lastTs derived backwards so nothing overflows
        uint64 lastTs = uint64(bound(lastTsOffset, nowFixed - window - 1, nowFixed));
        vm.warp(nowFixed);
        uint256 decayed = DynamicFeeMath.decayLinearPpm(acc, lastTs, window);
        assertLe(decayed, acc, "decayed above accumulator");
        if (nowFixed - lastTs >= window) {
            assertEq(decayed, 0, "must be zero past the window");
        }
    }
}
