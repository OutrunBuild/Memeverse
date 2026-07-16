// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {FacetGuard} from "../../../src/swap/FacetGuard.sol";
import {IDynamicFeeFacet} from "../../../src/swap/interfaces/IDynamicFeeFacet.sol";

/// @title DynamicFeeFacetReplacementMock
/// @notice Replacement facet that returns a fixed swap fee and exposes a distinctive realized-state marker.
contract DynamicFeeFacetReplacementMock layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    FacetGuard,
    IDynamicFeeFacet,
    ImmutableState
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param poolManager_ PoolManager shared with the hook Router.
    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    /// @inheritdoc IDynamicFeeFacet
    function prepareSwapFee(PrepareSwapFeeParams calldata)
        external
        view
        override
        onlyViaRouter
        returns (uint256 feeBps, uint256 estimatedGrossOutputAmount)
    {
        feeBps = 1_000;
        estimatedGrossOutputAmount = 0;
    }

    /// @inheritdoc IDynamicFeeFacet
    function updateAfterSwap(UpdateAfterSwapParams calldata params) external override onlyViaRouter {
        _memeverseUniswapHookStorage.dynamicFeeState[params.poolId].shortImpactPpm = 77_777;
    }

    /// @inheritdoc IDynamicFeeFacet
    function quote(PrepareSwapFeeParams calldata)
        external
        view
        override
        onlyViaRouter
        returns (PreparedSwapFee memory preparedQuote)
    {
        preparedQuote.feeBps = 1_000;
    }
}
