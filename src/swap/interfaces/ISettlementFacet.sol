// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMemeverseUniswapHook} from "./IMemeverseUniswapHook.sol";

/// @title ISettlementFacet
/// @notice Diamond facet surface for the preorder settlement swap logic.
/// @dev Both functions execute in the Router's storage context through delegatecall.
interface ISettlementFacet {
    /// @notice Typed payload for the settlement branch of the PoolManager unlock callback.
    struct SettlementCallbackData {
        address recipient;
        address treasury;
        PoolKey key;
        SwapParams swapParams;
        bool protocolFeeOnInput;
    }

    /// @notice Typed result returned from the settlement unlock callback.
    struct SettlementResult {
        BalanceDelta adjustedDelta;
        BalanceDelta swapDelta;
        uint160 preSwapSqrtPriceX96;
        uint160 postSwapSqrtPriceX96;
        uint256 protocolFeeOutputAmount;
    }

    /// @notice Executes the preorder settlement swap through the hook's dedicated settlement path.
    /// @dev Applies fixed settlement economics and returns the net balance delta.
    /// @param params Preorder settlement payload (`{PoolKey key, SwapParams params, address recipient}`).
    /// @return delta Balance delta describing the net token movement after applying settlement economics.
    function executeSettlementLogic(IMemeverseUniswapHook.PreorderSettlementParams calldata params)
        external
        returns (BalanceDelta delta);

    /// @notice Executes the settlement branch of the PoolManager unlock callback.
    /// @dev The Router decodes the explicit callback kind before forwarding this typed payload.
    /// @param data Settlement callback payload.
    /// @return result Settlement result consumed by `executeSettlementLogic`.
    function settlementUnlockCallback(SettlementCallbackData calldata data)
        external
        returns (SettlementResult memory result);
}
