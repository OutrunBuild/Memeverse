// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {FacetGuard} from "../../../src/swap/FacetGuard.sol";
import {IDynamicFeeFacet} from "../../../src/swap/interfaces/IDynamicFeeFacet.sol";

/// @title StateWritingDynamicFeeFacetMock
/// @notice Replacement fee facet used to prove that quote execution rejects storage writes.
contract StateWritingDynamicFeeFacetMock layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    FacetGuard,
    ImmutableState
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param poolManager_ PoolManager shared with the hook Router.
    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    /// @notice Attempts to write dynamic fee state while serving a quote.
    /// @param params Hook-assembled pool and swap context.
    /// @return preparedQuote Empty quote; static execution must revert before it can be returned.
    function quote(IDynamicFeeFacet.PrepareSwapFeeParams calldata params)
        external
        onlyViaRouter
        returns (IDynamicFeeFacet.PreparedSwapFee memory preparedQuote)
    {
        _memeverseUniswapHookStorage.dynamicFeeState[params.poolId].shortImpactPpm = 1;
        return preparedQuote;
    }
}
