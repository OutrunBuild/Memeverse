// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DynamicFeeFacet} from "../../src/swap/DynamicFeeFacet.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {DynamicFeeFacetMinRouter} from "../mocks/swap/DynamicFeeFacetMinRouter.sol";

/// @title DynamicFeeFacetTest
/// @notice Drives `DynamicFeeFacet` external entries through the `DynamicFeeFacetMinRouter` mini-Router to
///         assert the dynamic-fee facet's storage post-conditions.
/// @dev The facet is delegatecall-only (its `onlyViaRouter` guard rejects direct CALLs), so a Router-style
///      host that re-declares the shared ERC-7201 namespace is the only way to exercise the storage-writing
///      paths (`updateAfterSwap`, `prepareSwapFee`) without deploying the full diamond stack. The guard
///      uses an immutable `__self`, so under delegatecall it passes with no storage seeding. The mini-Router
///      is the trusted dispatcher and exposes read helpers for the shared `(poolId)` and `(trader, poolId)`
///      state. Pure algorithm assertions live in `FeeMath.t.sol` and `DynamicFeeMath.t.sol`; this file covers
///      the facet's storage transitions only.
contract DynamicFeeFacetTest is Test {
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x1234)));
    address internal constant TRADER_A = address(0xCAFE);
    address internal constant TRADER_B = address(0xBEEF);

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant SQRT_PRICE_UP = 80024378775772204256025656563;

    DynamicFeeFacetMinRouter internal minRouter;

    function setUp() external {
        // The facet's fee logic never calls back into PoolManager, so a stub address satisfies the
        // non-zero constructor check. The facet is injected so sad-path suites can swap a reverting mock.
        minRouter = new DynamicFeeFacetMinRouter(new DynamicFeeFacet(IPoolManager(makeAddr("manager"))));
        vm.warp(1);
    }

    // -----------------------------------------------------------------
    // OPT-013: quote / prepare paths must not write realized state
    // -----------------------------------------------------------------

    /// @notice `prepareSwapFee` only refreshes the volatility anchor in storage; it must not write the
    ///         realized swap fields (`weightedVolume0`, `weightedPriceVolume0`, `ewVWAPX18`,
    ///         `shortImpactPpm`, `shortLastTs`) or the trader batch accumulator (`batchAccumPpm`,
    ///         `batchStartTs`). Strong OPT-013 regression guard: a zero→zero assertion would pass even if
    ///         the facet silently wrote zeros, so every field is seeded non-zero and asserted preserved.
    /// @dev The volatility anchor is intentionally seeded stale (`SQRT_PRICE_UP`, != `params.preSqrtPriceX96`)
    ///      and `volLastMoveTs` is aged past `VOL_FILTER_PERIOD_SEC` so `_refreshVolatilityAnchorAndCarry`
    ///      actually runs — proving the non-mutation invariant holds even when the refresh side-effect fires.
    function testPrepareSwapFeeDoesNotWriteRealizedState() external {
        vm.warp(1_000);

        // Seed non-zero realized state. The stale anchor + aged volLastMoveTs force the refresh branch.
        minRouter.seedDynamicFeeState(
            POOL_ID,
            IDynamicFeeFacet.DynamicFeeState({
                weightedVolume0: 1e18,
                weightedPriceVolume0: 1e18,
                ewVWAPX18: 1e18,
                volAnchorSqrtPriceX96: SQRT_PRICE_UP, // stale, != params.preSqrtPriceX96
                volLastMoveTs: uint40(block.timestamp - 100), // aged past VOL_FILTER_PERIOD_SEC (10s) → refresh fires
                volDeviationAccumulator: 1000,
                volCarryAccumulator: 1000,
                shortImpactPpm: 5000,
                shortLastTs: uint40(block.timestamp - 100)
            })
        );
        minRouter.seedAddressBatchState(
            TRADER_A,
            POOL_ID,
            IDynamicFeeFacet.AddressBatchState({batchAccumPpm: 1000, batchStartTs: uint64(block.timestamp)})
        );

        // launchTimestamp=0 (default seed) zeroes the launch-fee surcharge so the fee floor does not
        // interfere with the non-mutation assertions (the quote path is what we are guarding, not its
        // precise bps output).
        minRouter.prepareSwapFee(_prepareParams(TRADER_A));

        IDynamicFeeFacet.DynamicFeeState memory state = minRouter.readDynamicFeeState(POOL_ID);
        IDynamicFeeFacet.AddressBatchState memory batch = minRouter.readAddressBatchState(TRADER_A, POOL_ID);

        // Realized swap fields MUST be preserved (catches silent writes that a zero→zero guard would miss).
        assertEq(state.weightedVolume0, 1e18, "ewvwap volume preserved");
        assertEq(state.weightedPriceVolume0, 1e18, "ewvwap price-volume preserved");
        assertEq(state.ewVWAPX18, 1e18, "ewvwap preserved");
        assertEq(state.shortImpactPpm, 5000, "short impact preserved");
        assertEq(state.shortLastTs, block.timestamp - 100, "short last ts preserved");
        // Per-trader batch MUST be preserved.
        assertEq(batch.batchAccumPpm, 1000, "batch accum preserved");
        assertEq(batch.batchStartTs, block.timestamp, "batch start ts preserved");
        // Expected side-effect: the volatility anchor was refreshed to `params.preSqrtPriceX96`
        // (SQRT_PRICE_1_1), proving prepareSwapFee ran the refresh path rather than silently skipping it.
        assertEq(state.volAnchorSqrtPriceX96, SQRT_PRICE_1_1, "vol anchor refreshed to preSqrtPriceX96");
    }

    /// @notice The view `quote` forwarder must converge with `prepareSwapFee` on the two settlement
    ///         fields for identical input — the view memory-refresh path mirrors the storage-refresh
    ///         path (OPT-013), both feeding the same `estimateDynamicFeeQuote` core. Activates the
    ///         mini-Router `quote` delegatecall (otherwise dead code).
    /// @dev Refresh-active seed (mirrors `testPrepareSwapFeeDoesNotWriteRealizedState`): a stale
    ///      `volAnchorSqrtPriceX96` plus `volLastMoveTs` aged past `VOL_FILTER_PERIOD_SEC` force the
    ///      volatility refresh to fire on BOTH paths. Non-zero realized state (EWVWAP / short-impact /
    ///      batch accumulator) makes every derived fee component non-trivial, so a memory-vs-storage
    ///      refresh divergence surfaces in the settlement fields rather than hiding behind zeros.
    ///      `quote` is a view, so calling it first leaves storage untouched; `prepareSwapFee` then reads
    ///      the identical pre-refresh state. Hot-path `prepareSwapFee` returns only the two settlement
    ///      fields (`feeBps`, `estimatedGrossOutputAmount`); full-field breakdown stays on `quote`.
    ///      Launch-fee floor dominance above the dynamic floor is covered separately in
    ///      `DynamicFeeMath.t.sol::testEstimateDynamicFeeQuoteLaunchFeeFloorsAboveDynamic`.
    function testQuoteReturnsPreparedSwapFee() external {
        vm.warp(1_000);
        _seedRefreshActiveState();

        IDynamicFeeFacet.PrepareSwapFeeParams memory params = _prepareParams(TRADER_A);

        // `quote` (view, memory volatility refresh) and `prepareSwapFee` (storage refresh) feed identical
        // state into `estimateDynamicFeeQuote`, so the settlement fields must match bit-for-bit.
        IDynamicFeeFacet.PreparedSwapFee memory quoted = minRouter.quote(params);
        (uint256 preparedFeeBps, uint256 preparedGrossOutput) = minRouter.prepareSwapFee(params);

        _assertQuotePrepareConvergence(quoted, preparedFeeBps, preparedGrossOutput, "");
        assertGt(quoted.estimatedInputAmount, 0, "non-zero estimate");
    }

    /// @notice Same memory-vs-storage refresh convergence as `testQuoteReturnsPreparedSwapFee`, but on the
    ///         exact-OUTPUT path (`amountSpecified > 0`, `protocolFeeOnInput = false`). This drives the
    ///         `grossUpFeeFromNetOutput` convergence loop, distinct from the exact-input fee-deduction
    ///         loop covered above. Captures divergence in the gross-up iteration between `quote`'s memory
    ///         refresh and `prepareSwapFee`'s storage refresh.
    /// @dev `protocolFeeOnInput = false` is required to reach the gross-up branch: with `feeOnInput = true`
    ///      the output path short-circuits before grossing up. Same refresh-active seed so the volatility
    ///      refresh fires on both paths.
    function testQuoteExactOutputConverges() external {
        vm.warp(1_000);
        _seedRefreshActiveState();

        IDynamicFeeFacet.PrepareSwapFeeParams memory params = _prepareExactOutputParams(TRADER_A);

        IDynamicFeeFacet.PreparedSwapFee memory quoted = minRouter.quote(params);
        (uint256 preparedFeeBps, uint256 preparedGrossOutput) = minRouter.prepareSwapFee(params);

        _assertQuotePrepareConvergence(quoted, preparedFeeBps, preparedGrossOutput, " exact-output");
        assertGt(quoted.estimatedOutputAmount, 0, "non-zero output");
    }

    /// @notice `quote` (view, memory refresh) and `prepareSwapFee` (storage refresh) must converge
    ///         on the settlement fields ON THE REFRESH BOUNDARY — when elapsed >= VOL_FILTER_PERIOD_SEC
    ///         and a non-zero deviation forces the decay mulDiv to run. `testQuoteReturnsPreparedSwapFee`
    ///         seeds elapsed=100 (>= VOL_DECAY_PERIOD_SEC=60), so its refresh takes the reset-to-zero
    ///         sub-branch and would NOT catch divergence in the decay-mulDiv ternary — the exact OPT-013
    ///         drift hazard this test locks down.
    /// @dev `quote` is a view, so calling it first leaves storage untouched; `prepareSwapFee` then reads the
    ///      same pre-refresh state. `volLastMoveTs = block.timestamp - 50` lands elapsed in [10, 60): the
    ///      refresh fires (>= VOL_FILTER_PERIOD_SEC) AND the decay mulDiv runs (< VOL_DECAY_PERIOD_SEC, not
    ///      the reset-to-zero branch) — the highest-value coverage for the quote/prepare mirror invariant.
    ///      The catching power comes from `volDeviationAccumulator = 1000`: refresh decays it to 500, a skipped
    ///      refresh leaves 1000, so `volatilityPartBps` (and therefore `feeBps`) diverges between the two paths.
    ///      `volCarryAccumulator` is NOT read by `estimateDynamicFeeQuote`, so its seeded value is irrelevant here.
    function testQuoteMatchesPrepareSwapFeeOnRefreshBoundary() external {
        vm.warp(1_000);

        // Stale anchor + aged volLastMoveTs (elapsed=50 in [VOL_FILTER_PERIOD_SEC=10, VOL_DECAY_PERIOD_SEC=60))
        // forces BOTH the refresh and the decay mulDiv. Non-zero deviation makes the decay output non-trivial.
        minRouter.seedDynamicFeeState(
            POOL_ID,
            IDynamicFeeFacet.DynamicFeeState({
                weightedVolume0: 0,
                weightedPriceVolume0: 0,
                ewVWAPX18: 0,
                volAnchorSqrtPriceX96: SQRT_PRICE_UP, // stale, != params.preSqrtPriceX96 (SQRT_PRICE_1_1)
                volLastMoveTs: uint40(block.timestamp - 50), // elapsed=50 -> refresh + decay branch
                volDeviationAccumulator: 1000, // refresh decays to 500; drift surfaces in volatilityPartBps
                volCarryAccumulator: 0, // not read by estimateDynamicFeeQuote; irrelevant to the assertion
                shortImpactPpm: 0,
                shortLastTs: 0
            })
        );

        IDynamicFeeFacet.PrepareSwapFeeParams memory params = _prepareParams(TRADER_A);

        // `quote` is a view: it runs the memory refresh but does not persist, so `prepareSwapFee` next reads
        // the identical pre-refresh state. If the two refresh implementations agree, the quotes must match.
        IDynamicFeeFacet.PreparedSwapFee memory quoted = minRouter.quote(params);
        (uint256 preparedFeeBps, uint256 preparedGrossOutput) = minRouter.prepareSwapFee(params);

        // Settlement-field convergence on the decay sub-branch: feeBps encodes the volatility refresh result.
        _assertQuotePrepareConvergence(quoted, preparedFeeBps, preparedGrossOutput, " on refresh boundary");
    }

    // -----------------------------------------------------------------
    // updateAfterSwap writes realized state
    // -----------------------------------------------------------------

    /// @notice `updateAfterSwap` must persist realized swap state for the trading pool: weighted volume /
    ///         EWVWAP, volatility accumulator, short impact, and the per-trader batch PIF. Other traders
    ///         must remain untouched.
    function testUpdateAfterSwapWritesRealizedState() external {
        // Seed the volatility anchor so the post-swap deviation can accrue (otherwise the first swap just
        // sets volAnchor = postSqrtPriceX96 and accumulates nothing).
        IDynamicFeeFacet.DynamicFeeState memory initialState;
        initialState.volAnchorSqrtPriceX96 = SQRT_PRICE_1_1;
        minRouter.seedDynamicFeeState(POOL_ID, initialState);

        minRouter.updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
                poolId: POOL_ID,
                delta: toBalanceDelta(int128(-10 ether), int128(9 ether)),
                trader: TRADER_A,
                preSqrtPriceX96: SQRT_PRICE_1_1,
                postSqrtPriceX96: SQRT_PRICE_UP
            })
        );

        IDynamicFeeFacet.DynamicFeeState memory state = minRouter.readDynamicFeeState(POOL_ID);
        IDynamicFeeFacet.AddressBatchState memory batch = minRouter.readAddressBatchState(TRADER_A, POOL_ID);
        IDynamicFeeFacet.AddressBatchState memory otherBatch = minRouter.readAddressBatchState(TRADER_B, POOL_ID);

        assertGt(state.weightedVolume0, 0, "ewvwap volume");
        assertGt(state.ewVWAPX18, 0, "ewvwap");
        assertGt(state.shortImpactPpm, 0, "short impact");
        assertGt(state.volDeviationAccumulator, 0, "volatility accumulator");
        assertGt(batch.batchAccumPpm, 0, "trader batch pif");
        assertEq(otherBatch.batchAccumPpm, 0, "other trader untouched");
    }

    /// @notice `updateAfterSwap` early-returns on `preSqrtPriceX96 == 0` (`DynamicFeeFacet :100`), so every
    ///         realized field stays at its zero default. Regression guard against silent state writes when
    ///         the pre-swap price snapshot is missing.
    function testUpdateAfterSwapZeroPreSqrtPriceWritesNoState() external {
        minRouter.updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
                poolId: POOL_ID,
                delta: toBalanceDelta(int128(-10 ether), int128(9 ether)),
                trader: TRADER_A,
                preSqrtPriceX96: 0,
                postSqrtPriceX96: SQRT_PRICE_UP
            })
        );

        IDynamicFeeFacet.DynamicFeeState memory state = minRouter.readDynamicFeeState(POOL_ID);
        IDynamicFeeFacet.AddressBatchState memory batch = minRouter.readAddressBatchState(TRADER_A, POOL_ID);

        assertEq(state.weightedVolume0, 0, "volume stays zero");
        assertEq(state.weightedPriceVolume0, 0, "price volume stays zero");
        assertEq(state.ewVWAPX18, 0, "ewvwap stays zero");
        assertEq(state.volAnchorSqrtPriceX96, 0, "anchor stays zero");
        assertEq(state.volDeviationAccumulator, 0, "deviation stays zero");
        assertEq(state.shortImpactPpm, 0, "short impact stays zero");
        assertEq(state.shortLastTs, 0, "short last ts stays zero");
        assertEq(batch.batchAccumPpm, 0, "batch accum stays zero");
        assertEq(batch.batchStartTs, 0, "batch start ts stays zero");
    }

    // -----------------------------------------------------------------
    // Address-batch accumulation window
    // -----------------------------------------------------------------

    /// @notice Within `ADDRESS_BATCH_WINDOW_SEC` (3s) consecutive `updateAfterSwap` calls from the same
    ///         trader must accumulate the per-trader `batchAccumPpm` instead of resetting it.
    function testBatchAccumulationIncreasesFeeWithinWindow() external {
        IDynamicFeeFacet.UpdateAfterSwapParams memory params = IDynamicFeeFacet.UpdateAfterSwapParams({
            poolId: POOL_ID,
            delta: toBalanceDelta(int128(-10 ether), int128(9 ether)),
            trader: TRADER_A,
            preSqrtPriceX96: SQRT_PRICE_1_1,
            postSqrtPriceX96: SQRT_PRICE_UP
        });

        minRouter.updateAfterSwap(params);
        uint192 firstBatchPpm = minRouter.readAddressBatchState(TRADER_A, POOL_ID).batchAccumPpm;
        assertGt(firstBatchPpm, 0, "first batch accum seeded");

        // Warp within ADDRESS_BATCH_WINDOW_SEC (3s) — second swap must add to the existing batch.
        vm.warp(block.timestamp + 1);
        minRouter.updateAfterSwap(params);
        uint192 secondBatchPpm = minRouter.readAddressBatchState(TRADER_A, POOL_ID).batchAccumPpm;
        assertGt(secondBatchPpm, firstBatchPpm, "batch accumulates within window");
    }

    // -----------------------------------------------------------------
    // Same-block short-impact preservation
    // -----------------------------------------------------------------

    /// @notice Two swaps in the same block (`block.timestamp == shortLastTs`) must NOT decay the existing
    ///         short impact: `decayLinearPpm` short-circuits to the unchanged accumulator, so the second
    ///         swap adds its full PIF on top. Warping past the same block re-enables decay.
    function testSameBlockSwapPreservesFullShortImpact() external {
        vm.warp(1000);

        IDynamicFeeFacet.UpdateAfterSwapParams memory params = IDynamicFeeFacet.UpdateAfterSwapParams({
            poolId: POOL_ID,
            delta: toBalanceDelta(int128(-10 ether), int128(9 ether)),
            trader: TRADER_A,
            preSqrtPriceX96: SQRT_PRICE_1_1,
            postSqrtPriceX96: SQRT_PRICE_UP
        });

        minRouter.updateAfterSwap(params);
        uint24 firstShort = minRouter.readDynamicFeeState(POOL_ID).shortImpactPpm;
        assertGt(firstShort, 0, "first short impact seeded");

        // Same block (no warp): decay must not fire, so the second swap adds the full PIF again.
        minRouter.updateAfterSwap(params);
        uint24 sameBlockShort = minRouter.readDynamicFeeState(POOL_ID).shortImpactPpm;
        assertEq(sameBlockShort, firstShort * 2, "same-block short impact not decayed");

        // Warp 1s: decay fires between swaps, so the third swap adds less than a full PIF.
        vm.warp(block.timestamp + 1);
        minRouter.updateAfterSwap(params);
        uint24 decayedShort = minRouter.readDynamicFeeState(POOL_ID).shortImpactPpm;
        assertLt(decayedShort, sameBlockShort + firstShort, "post-warp short impact decayed before adding");
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _prepareParams(address trader)
        internal
        pure
        returns (IDynamicFeeFacet.PrepareSwapFeeParams memory params)
    {
        params = IDynamicFeeFacet.PrepareSwapFeeParams({
            poolId: POOL_ID,
            zeroForOne: true,
            amountSpecified: -1 ether,
            trader: trader,
            preSqrtPriceX96: SQRT_PRICE_1_1,
            liquidity: 1_000_000 ether,
            protocolFeeOnInput: true
        });
    }

    function _launchFeeConfig() internal pure returns (IDynamicFeeFacet.LaunchFeeConfig memory config) {
        config = IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 5000, minFeeBps: 100, decayDurationSeconds: 900});
    }

    /// @dev Refresh-active seed mirroring `testPrepareSwapFeeDoesNotWriteRealizedState`. Stale anchor
    ///      (`SQRT_PRICE_UP` != `SQRT_PRICE_1_1`) + `volLastMoveTs` aged past `VOL_FILTER_PERIOD_SEC` (10s)
    ///      force `_refreshVolatilityAnchorAndCarry` to fire on both `quote` (memory) and `prepareSwapFee`
    ///      (storage) paths. Non-zero EWVWAP / short-impact / batch accumulator make every fee component
    ///      non-trivial so a refresh divergence surfaces in the asserted settlement fields. Launch fee
    ///      config is seeded into shared storage because the facet self-reads it (not params).
    function _seedRefreshActiveState() internal {
        minRouter.seedDynamicFeeState(
            POOL_ID,
            IDynamicFeeFacet.DynamicFeeState({
                weightedVolume0: 1e18,
                weightedPriceVolume0: 1e18,
                ewVWAPX18: 1e18,
                volAnchorSqrtPriceX96: SQRT_PRICE_UP, // stale, != params.preSqrtPriceX96
                volLastMoveTs: uint40(block.timestamp - 100), // elapsed=100 >= 10 → refresh fires
                volDeviationAccumulator: 1000,
                volCarryAccumulator: 1000,
                shortImpactPpm: 5000,
                shortLastTs: uint40(block.timestamp - 100)
            })
        );
        minRouter.seedAddressBatchState(
            TRADER_A,
            POOL_ID,
            IDynamicFeeFacet.AddressBatchState({batchAccumPpm: 1000, batchStartTs: uint64(block.timestamp)})
        );
        // Default launchTimestamp remains 0 (pre-launch → minFeeBps floor only).
        minRouter.seedDefaultLaunchFeeConfig(_launchFeeConfig());
    }

    /// @dev Exact-OUTPUT variant of `_prepareParams`: `amountSpecified > 0` requests a fixed output, and
    ///      `protocolFeeOnInput = false` routes through `grossUpFeeFromNetOutput` instead of the
    ///      exact-input fee-deduction loop.
    function _prepareExactOutputParams(address trader)
        internal
        pure
        returns (IDynamicFeeFacet.PrepareSwapFeeParams memory params)
    {
        params = IDynamicFeeFacet.PrepareSwapFeeParams({
            poolId: POOL_ID,
            zeroForOne: true,
            amountSpecified: 1 ether,
            trader: trader,
            preSqrtPriceX96: SQRT_PRICE_1_1,
            liquidity: 1_000_000 ether,
            protocolFeeOnInput: false
        });
    }

    /// @dev Asserts settlement-field convergence between the view `quote` (memory refresh, full
    ///      `PreparedSwapFee`) and hot-path `prepareSwapFee` (storage refresh, two settlement fields).
    ///      `suffix` tags every assertion message so the caller's scenario is identifiable on failure.
    ///      Both paths feed identical pre-refresh state into `estimateDynamicFeeQuote`, so the two
    ///      settlement fields must match exactly.
    function _assertQuotePrepareConvergence(
        IDynamicFeeFacet.PreparedSwapFee memory quoted,
        uint256 preparedFeeBps,
        uint256 preparedGrossOutput,
        string memory suffix
    ) internal pure {
        assertEq(quoted.feeBps, preparedFeeBps, string.concat("quote==prepare feeBps", suffix));
        assertEq(
            quoted.estimatedGrossOutputAmount, preparedGrossOutput, string.concat("quote==prepare gross output", suffix)
        );
    }
}
