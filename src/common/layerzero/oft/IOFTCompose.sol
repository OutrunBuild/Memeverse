// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { MessagingReceipt, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

/**
 * @title IOFTCompose
 * @dev Handle the logic related to OFT Compose
 */
interface IOFTCompose {
    struct ComposeTxStatus {
        address composer;   // The Layerzero Composer contract of this tx
        address UBO;        // Ultimate beneficiary owner
        uint256 amount;     // OFT cross-chain amount
        bool isExecuted;    // Has Been Executed?
    }

    /**
     * @dev Get the compose tx executed status by guid.
     * @param guid - The unique identifier for the received LayerZero message.
     */
    function getComposeTxExecutedStatus(bytes32 guid) external view returns (bool);

    /**
     * @dev Notify the OFT contract that the composition call has been executed.
     * @param guid - The unique identifier for the received LayerZero message.
     */
    function notifyComposeExecuted(bytes32 guid) external;

    /**
     * @dev Withdraw OFT if the composition call has not been executed.
     * @param guid - The unique identifier for the received LayerZero message.
     * @param receiver - Address to receive OFT.
     * @return amount - Withdraw amount
     */
    function withdrawIfNotExecuted(bytes32 guid, address receiver) external returns (uint256 amount);

    event NotifyComposeExecuted(bytes32 indexed guid);

    event WithdrawIfNotExecuted(
        bytes32 indexed guid, 
        address indexed composer, 
        address indexed receiver, 
        uint256 amount
    );

    error AlreadyExecuted();

    error PermissionDenied();
}
