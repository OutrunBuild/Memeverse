// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunOAppCoreInit } from "./OutrunOAppCoreInit.sol";
import { OutrunOAppReceiverInit, Origin } from "./OutrunOAppReceiverInit.sol";
import { OutrunOAppSenderInit, MessagingFee, MessagingReceipt } from "./OutrunOAppSenderInit.sol";

/**
 * @title OutrunOAppInit
 * @dev Abstract contract serving as the base for OutrunOAppInit implementation, combining OutrunOAppSenderInit and OutrunOAppReceiverInit functionality.
 */
abstract contract OutrunOAppInit is OutrunOAppSenderInit, OutrunOAppReceiverInit {
    /**
     * @dev Initializes the OApp with the provided delegate.
     * @param _endpoint The address of the LOCAL LayerZero endpoint.
     * @param _delegate The delegate capable of making OApp configurations inside of the endpoint.
     *
     * @dev The delegate typically should be set as the owner of the contract.
     * @dev Ownable is not initialized here on purpose. It should be initialized in the child contract to
     * accommodate the different version of Ownable.
     */
    function __OutrunOApp_init(address _endpoint, address _delegate) internal onlyInitializing {
        __OutrunOAppCore_init(_endpoint, _delegate);
    }
    
    /**
     * @notice Retrieves the OApp version information.
     * @return senderVersion The version of the OAppSender.sol implementation.
     * @return receiverVersion The version of the OAppReceiver.sol implementation.
     */
    function oAppVersion()
        public
        pure
        virtual
        override(OutrunOAppSenderInit, OutrunOAppReceiverInit)
        returns (uint64 senderVersion, uint64 receiverVersion)
    {
        return (SENDER_VERSION, RECEIVER_VERSION);
    }
}
