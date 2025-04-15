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
        address receiver;   // The emergency receiver of OFTs if the composition call fails
        uint256 amount;     // OFT cross-chain amount
        bool isExecuted;    // Has Been Executed?
    }

    /**
     * @dev Notify the OFT contract that the composition call has been fully executed.
     * @param guid The unique identifier for the received LayerZero message.
     */
    function notifyComposeExecuted(bytes32 guid) external;

    event NotifyComposeExecuted(bytes32 indexed guid);

    error PermissionDenied();
}
