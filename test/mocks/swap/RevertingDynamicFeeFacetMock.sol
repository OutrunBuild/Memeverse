// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {FacetGuard} from "../../../src/swap/FacetGuard.sol";
import {IDynamicFeeFacet} from "../../../src/swap/interfaces/IDynamicFeeFacet.sol";

/// @dev Shared failure-point dial (1=prepare, 2=updateAfterSwap, 3=quote). File-level so tests import
///      one source of truth (`Contract.publicConstant` is not TypeName-addressable in this solc).
uint8 constant PREPARE_SWAP_FEE_POINT = 1;
uint8 constant UPDATE_AFTER_SWAP_POINT = 2;
uint8 constant QUOTE_POINT = 3;

/// @notice Dynamic fee facet replacement that injects a deterministic custom error.
contract RevertingDynamicFeeFacetMock layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    FacetGuard,
    IDynamicFeeFacet,
    ImmutableState
{
    error ForcedDynamicFeeFacetRevert(uint8 point);

    uint8 internal immutable failurePoint;

    constructor(IPoolManager poolManager_, uint8 failurePoint_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        failurePoint = failurePoint_;
    }

    function prepareSwapFee(PrepareSwapFeeParams calldata)
        external
        view
        override
        onlyViaRouter
        returns (uint256 feeBps, uint256 estimatedGrossOutputAmount)
    {
        if (failurePoint == PREPARE_SWAP_FEE_POINT) revert ForcedDynamicFeeFacetRevert(failurePoint);
        return (0, 0);
    }

    function updateAfterSwap(UpdateAfterSwapParams calldata params) external override onlyViaRouter {
        if (failurePoint != UPDATE_AFTER_SWAP_POINT) return;

        _memeverseUniswapHookStorage.dynamicFeeState[params.poolId].shortImpactPpm = 77_777;
        revert ForcedDynamicFeeFacetRevert(failurePoint);
    }

    function quote(PrepareSwapFeeParams calldata)
        external
        view
        override
        onlyViaRouter
        returns (PreparedSwapFee memory preparedQuote)
    {
        if (failurePoint == QUOTE_POINT) revert ForcedDynamicFeeFacetRevert(failurePoint);
        return preparedQuote;
    }
}
