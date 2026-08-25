// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IOAppReceiver, Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

import {OutrunOAppCoreInit} from "./OutrunOAppCoreInit.sol";

/**
 * @title OutrunOAppReceiverInit (Just for minimal proxy)
 * @dev Abstract contract implementing the ILayerZeroReceiver interface and extending OAppCore for OApp receivers.
 */
abstract contract OutrunOAppReceiverInit is IOAppReceiver, OutrunOAppCoreInit {
    error OnlyEndpoint(address addr);

    // @dev The version of the OAppReceiver implementation.
    // @dev Version is bumped when changes are made to this contract.
    uint64 internal constant RECEIVER_VERSION = 2;

    /**
     * @param _delegate The delegate capable of making OApp configurations inside of the endpoint.
     * @dev Ownable is not initialized here; see OutrunOAppCoreInit.
     */
    function __OutrunOAppReceiver_init(address _delegate) internal onlyInitializing {
        __OutrunOAppCore_init(_delegate);
    }

    function __OutrunOAppReceiver_init_unchained() internal onlyInitializing {}

    /**
     * @notice Retrieves the OApp version information.
     * @return senderVersion The version of the OAppSender.sol contract.
     * @return receiverVersion The version of the OAppReceiver.sol contract.
     *
     * @dev Providing 0 as the default for OAppSender version. Indicates that the OAppSender is not implemented.
     * ie. this is a RECEIVE only OApp.
     * @dev If the OApp uses both OAppSender and OAppReceiver, then this needs to be override returning the correct versions.
     */
    function oAppVersion() public view virtual returns (uint64 senderVersion, uint64 receiverVersion) {
        return (0, RECEIVER_VERSION);
    }

    /**
     * @notice Indicates whether an address is an approved composeMsg sender to the Endpoint.
     * @param _origin The origin information for the composed message.
     * @param _message The received LayerZero payload.
     * @param _sender The sender address.
     * @return isSender Is a valid sender.
     *
     * @dev Applications can optionally choose to implement separate composeMsg senders that are NOT the bridging layer.
     * @dev The default sender IS the OAppReceiver implementer.
     */
    function isComposeMsgSender(Origin calldata _origin, bytes calldata _message, address _sender)
        public
        view
        virtual
        returns (bool)
    {
        _origin;
        _message;
        return _sender == address(this);
    }

    /**
     * @notice Checks if the path initialization is allowed based on the provided origin.
     * @param origin The origin information containing the source endpoint and sender address.
     * @return Whether the path has been initialized.
     *
     * @dev This indicates to the endpoint that the OApp has enabled msgs for this particular path to be received.
     * @dev This defaults to assuming if a peer has been set, its initialized.
     * Can be overridden by the OApp if there is other logic to determine this.
     */
    function allowInitializePath(Origin calldata origin) public view virtual returns (bool) {
        return peers(origin.srcEid) == origin.sender;
    }

    /// @notice Exposes the next expected inbound nonce for a source path.
    /// @dev Default implementation is unordered and always returns `0`.
    /// @param _srcEid Source endpoint ID.
    /// @param _sender Encoded sender address on source chain.
    /// @return nonce Next expected inbound nonce for this path.
    function nextNonce(uint32 _srcEid, bytes32 _sender) public view virtual returns (uint64 nonce) {
        _srcEid;
        _sender;
        return 0;
    }

    /// @notice Receives a LayerZero message and dispatches it to `_lzReceive`.
    /// @dev Validates endpoint caller and trusted peer before entering app logic.
    /// @param _origin Message origin metadata.
    /// @param _guid Unique message identifier.
    /// @param _message Encoded application payload.
    /// @param _executor LayerZero executor address.
    /// @param _extraData Extra executor data.
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) public payable virtual {
        if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);

        if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(_origin.srcEid, _origin.sender);

        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    /**
     * @dev Internal function to implement lzReceive logic without needing to copy the basic parameter validation.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual;
}
