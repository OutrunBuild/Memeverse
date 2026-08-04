// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import {IMemeverseOFTEnum} from "../../common/types/IMemeverseOFTEnum.sol";

interface IYieldDispatcher is IMemeverseOFTEnum, ILayerZeroComposer {
    event OFTProcessed(
        bytes32 indexed guid,
        address indexed token,
        TokenType indexed tokenType,
        address receiver,
        uint256 amount,
        bool isBurned
    );

    error AlreadyExecuted();

    error PermissionDenied();

    error InvalidTokenType();

    /// @notice Settles same-chain fee proceeds routed by the launcher.
    /// @dev The launcher transfers the fee token into this dispatcher first, then calls this entry so the same
    ///      settlement logic that handles bridged compose payloads also serves the local fast path.
    /// @param token Fee token to settle.
    /// @param receiver Yield vault, governor, or EOA burn target.
    /// @param tokenType Whether the token is a memecoin or a uAsset.
    /// @param amount Amount to settle, derived by the launcher from on-chain claimed fees.
    function distributeSameChain(address token, address receiver, TokenType tokenType, uint256 amount) external;
}
