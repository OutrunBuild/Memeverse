// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IDynamicFeeFacet
/// @notice Canonical shared storage and ABI types for the swap, dynamic-fee, and settlement facets.
/// @dev Facets and `MemeverseUniswapHookStorage` use these exact struct definitions; field drift changes
///      the ABI or storage layout and can make realized swap state unreadable. Each Router proxy owns one
///      hook namespace, with pool state keyed by `PoolId` and trader state keyed by `trader` and `PoolId`.
interface IDynamicFeeFacet {
    /// @notice Hook-owned launch-fee schedule copied into mutating fee calls.
    struct LaunchFeeConfig {
        uint24 startFeeBps;
        uint24 minFeeBps;
        uint32 decayDurationSeconds;
    }

    /// @notice Per-pool dynamic fee state.
    struct DynamicFeeState {
        uint256 weightedVolume0;
        uint256 weightedPriceVolume0;
        uint256 ewVWAPX18;
        uint160 volAnchorSqrtPriceX96;
        uint40 volLastMoveTs;
        uint24 volDeviationAccumulator;
        uint24 volCarryAccumulator;
        uint24 shortImpactPpm;
        uint40 shortLastTs;
    }

    /// @notice Per-trader, per-pool short batch state.
    struct AddressBatchState {
        uint192 batchAccumPpm;
        uint64 batchStartTs;
    }

    /// @notice Inputs used to prepare one swap fee from the shared hook storage context.
    /// @dev Launch fee config/timestamp are NOT caller-supplied: the facet reads
    ///      `defaultLaunchFeeConfig` and `poolLaunchTimestamp[poolId]` from shared ERC-7201 storage.
    ///      Callers still supply pool/swap/trader context that is not stored on the facet.
    struct PrepareSwapFeeParams {
        PoolId poolId;
        bool zeroForOne;
        int256 amountSpecified;
        address trader;
        uint160 preSqrtPriceX96;
        uint128 liquidity;
        bool protocolFeeOnInput;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Prepared fee quote returned before a swap.
    struct PreparedSwapFee {
        uint256 feeBps;
        uint256 pifPpm;
        uint256 adverseImpactPartBps;
        uint256 volatilityPartBps;
        uint256 shortImpactPartBps;
        uint256 estimatedInputAmount;
        uint256 estimatedOutputAmount;
        uint256 estimatedGrossOutputAmount;
        uint256 spotBeforeX18;
        uint256 spotAfterX18;
        bool isAdverse;
    }

    /// @notice Inputs used to update realized dynamic fee state after an actual swap.
    struct UpdateAfterSwapParams {
        PoolId poolId;
        BalanceDelta delta;
        address trader;
        uint160 preSqrtPriceX96;
        uint160 postSqrtPriceX96;
    }

    // -----------------------------------------------------------------
    // Facet logic surface
    // -----------------------------------------------------------------
    // These functions are the delegatecall targets invoked by the Router. Because a facet runs in the
    // Router's storage context (one hook per proxy), state is keyed directly by `PoolId` and, where needed,
    // `trader` or `referrer`. Selector stability is load-bearing — the Router encodes calls with
    // `abi.encodeCall(IDynamicFeeFacet.<func>, (...))`, so any signature drift breaks the dispatch encoding.

    /// @notice Prepares the dynamic fee for one hot-path swap settlement.
    /// @dev Reads/writes the facet's hook-owned dynamic fee state keyed by `params.poolId`.
    ///      Launch fee config/timestamp come from shared storage (`defaultLaunchFeeConfig`,
    ///      `poolLaunchTimestamp[params.poolId]`). The hot path returns only the selected fee;
    ///      final settlement amounts remain available through `quote`.
    /// @param params Hook-supplied swap and pool state (no launch fields).
    /// @return feeBps Final fee in bps (`max(launch, dynamic, base)`).
    function prepareSwapFee(PrepareSwapFeeParams calldata params) external returns (uint256 feeBps);

    /// @notice Updates realized dynamic fee state after one completed swap.
    /// @param params Hook-supplied realized swap state.
    function updateAfterSwap(UpdateAfterSwapParams calldata params) external;

    /// @notice Returns a read-only dynamic fee quote for a hook-supplied pool context.
    /// @dev The facet reads launch config/timestamp from shared hook storage and returns the full
    ///      `PreparedSwapFee` breakdown for Lens/Router quoting.
    /// @param params Hook-assembled pool and swap state (no launch fields).
    /// @return quote Prepared dynamic fee quote.
    function quote(PrepareSwapFeeParams calldata params) external view returns (PreparedSwapFee memory quote);
}
