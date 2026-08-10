// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunOAppCoreInit} from "./OutrunOAppCoreInit.sol";
import {OutrunOAppReceiverInit} from "./OutrunOAppReceiverInit.sol";
import {OutrunOAppSenderInit} from "./OutrunOAppSenderInit.sol";

/**
 * @title OutrunOAppInit (Just for minimal proxy)
 * @dev Abstract contract serving as the base for OutrunOAppInit implementation, combining OutrunOAppSenderInit and OutrunOAppReceiverInit functionality.
 */
abstract contract OutrunOAppInit is OutrunOAppSenderInit, OutrunOAppReceiverInit {
    /**
     * @dev Constructor to initialize the OApp with the provided endpoint and owner.
     * @param _endpoint The address of the LOCAL LayerZero endpoint.
     */
    constructor(address _endpoint) OutrunOAppCoreInit(_endpoint) {}

    /**
     * @dev Initializes the OApp with the provided delegate.
     * @param _delegate The delegate capable of making OApp configurations inside of the endpoint.
     *
     * @dev The delegate typically should be set as the owner of the contract.
     * @dev Ownable is not initialized here on purpose. It should be initialized in the child contract to
     * accommodate the different version of Ownable.
     */
    function __OutrunOApp_init(address _delegate) internal onlyInitializing {
        __OutrunOAppCore_init(_delegate);
        __OutrunOAppReceiver_init_unchained();
        __OutrunOAppSender_init_unchained();
    }

    /// @dev Form-compat stub: mirrors the upstream full/`_unchained` initializer pair convention
    ///      this file ports. Empty and unwired in the production init chain; kept for convention.
    function __OutrunOApp_init_unchained() internal onlyInitializing {}

    /// @notice Exposes the sender and receiver implementation versions for this OApp.
    /// @dev Signals that both OApp sender and receiver modules are enabled.
    /// @return senderVersion OApp sender module version.
    /// @return receiverVersion OApp receiver module version.
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
