// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMemeverseUniswapHook} from "./IMemeverseUniswapHook.sol";

/// @title IMemeverseUniswapHookLens
/// @notice Read-only calculator for Memeverse hook quotes, fee previews, and dynamic fee state.
interface IMemeverseUniswapHookLens {
    /// @notice PoolManager whose pool state is used by this lens.
    /// @return manager Uniswap v4 PoolManager bound to the lens.
    function poolManager() external view returns (IPoolManager manager);

    /// @notice Quotes a swap using hook state and PoolManager state without mutating either.
    /// @dev Calls the non-view hook bridge with `STATICCALL`; EIP-214 propagates the static context through
    ///      the hook's `delegatecall`, so any attempted state write by the delegated facet reverts.
    /// @param hook Hook whose state namespace should be queried.
    /// @param key Pool key being quoted.
    /// @param params Swap parameters that define direction and amount.
    /// @param trader Address whose address-batch state participates in dynamic fee quotes.
    /// @return quote Projected fee side, user amounts, and fee amounts.
    function quoteSwap(IMemeverseUniswapHook hook, PoolKey calldata key, SwapParams calldata params, address trader)
        external
        view
        returns (IMemeverseUniswapHook.SwapQuote memory quote);

    /// @notice Previews current claimable LP fees for one owner.
    /// @param hook Hook whose LP accounting is queried.
    /// @param key Pool key whose fee accounting is queried.
    /// @param owner LP owner being previewed.
    /// @return fee0Amount Claimable currency0 amount.
    /// @return fee1Amount Claimable currency1 amount.
    function claimableFees(IMemeverseUniswapHook hook, PoolKey calldata key, address owner)
        external
        view
        returns (uint256 fee0Amount, uint256 fee1Amount);

    /// @notice Reads the current dynamic fee state for a pool in the hook namespace.
    /// @dev `view` because the read path (`hook.dynamicFeeStateOf`) is itself a `view` direct read of the
    ///      hook's own ERC7201 storage. The 4-byte selector is unchanged (mutability is not part of the
    ///      signature); only the ABI mutability flips to `view`.
    /// @param hook Hook namespace whose dynamic-fee state is queried.
    /// @param poolId Pool being queried.
    /// @return weightedVolume0 Exponentially weighted token0 volume.
    /// @return weightedPriceVolume0 Exponentially weighted price-volume at 1e18 spot precision.
    /// @return ewVWAPX18 Exponentially weighted VWAP spot in X18 precision.
    /// @return volAnchorSqrtPriceX96 Anchor sqrt price used for reference-price deviation.
    /// @return volLastMoveTs Last timestamp when volatility observed a non-zero move.
    /// @return volDeviationAccumulator Accumulated reference-price deviation state.
    /// @return volCarryAccumulator Carried-over accumulator after filter/decay handling.
    /// @return shortImpactPpm Short-term cumulative impact accumulator.
    /// @return shortLastTs Last timestamp for short-term impact decay.
    function poolDynamicFeeState(IMemeverseUniswapHook hook, PoolId poolId)
        external
        view
        returns (
            uint256 weightedVolume0,
            uint256 weightedPriceVolume0,
            uint256 ewVWAPX18,
            uint160 volAnchorSqrtPriceX96,
            uint40 volLastMoveTs,
            uint24 volDeviationAccumulator,
            uint24 volCarryAccumulator,
            uint24 shortImpactPpm,
            uint40 shortLastTs
        );
}
