// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeSettleVerify} from "../../../src/common/omnichain/OFTComposeSettleVerify.sol";

/// @title MockMessagingComposerEndpoint
/// @notice Stand-in for the LayerZero MessagingComposer's `composeQueue` surface, etched onto a fixed endpoint address.
/// @dev Production contracts (YieldDispatcherUpgradeable.settlePendingCompose, OmnichainMemecoinStaker.settlePendingCompose) read
///      `IMessagingComposer(localEndpoint).composeQueue(...)` to prove a compose was delivered before settling a stuck compose.
///      `sendCompose` mirrors the real composer's write path (`composeQueue[msg.sender][to][guid][index] = keccak256(message)`,
///      MessagingComposer.sol), so an OFT's `_lzReceive` → `endpoint.sendCompose` produces exactly the key the compose-release
///      readers consume. `lzCompose` mirrors the real composer's execute path: it validates `keccak256(message)` against the
///      queue slot, stores the `bytes32(uint256(1))` RECEIVED sentinel, then forwards to `ILayerZeroComposer(to)`. `setQueue`
///      plants a delivered-but-unrun hash (keccak256(message)); `markReceived` manually writes the RECEIVED sentinel for
///      tests that do not drive `lzCompose`. Together these give a complete simulation of the `composeQueue` read/write
///      surface used by the compose-release readers. The event surface (`ComposeSent`/`ComposeDelivered`/`LzComposeAlert`)
///      mirrors MessagingComposer.sol so log-based tests can anchor the ops runbook.
contract MockMessagingComposerEndpoint {
    /// @dev Mirrors IMessagingComposer.sol:6-15 — hand-declared (the mock does not inherit the interface). All params
    ///      NON-indexed for ComposeSent/ComposeDelivered, exactly like the real composer's events.
    event ComposeSent(address from, address to, bytes32 guid, uint16 index, bytes message);

    /// @dev Mirrors IMessagingComposer.sol:8-9 — all params NON-indexed.
    event ComposeDelivered(address from, address to, bytes32 guid, uint16 index);

    /// @dev Mirrors IMessagingComposer.sol:10-19 — from/to/executor indexed, the rest non-indexed.
    event LzComposeAlert(
        address indexed from,
        address indexed to,
        address indexed executor,
        bytes32 guid,
        uint16 index,
        uint256 gas,
        uint256 value,
        bytes message,
        bytes extraData,
        bytes reason
    );

    /// @dev Single source of truth: derived from the production library so this mock's sentinel can never drift from
    ///      the fund-gate check in `OFTComposeSettleVerify.verifySettle` (the real protocol's copy is private).
    bytes32 internal constant RECEIVED = OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH;

    /// @dev A compose slot may only be written once, mirroring the real composer's `LZ_ComposeExists` guard.
    error ComposeExists();

    /// @dev Mirrors the real composer's `LZ_ComposeNotFound` guard: the queue slot must hold keccak256(message).
    error ComposeNotFound();

    // composeQueue[from][to][guid][index]
    mapping(address => mapping(address => mapping(bytes32 => mapping(uint16 => bytes32)))) public composeQueue;

    address public delegate;

    /// @notice Register a compose delivery, mirroring the real composer's authenticated write path.
    /// @dev Only the composing OApp (msg.sender) can write its own queue slot, and each guid/index resolves once:
    ///      a re-send of the same key reverts (real composer guards with `LZ_ComposeExists`).
    /// @param to Receiver of the composed message.
    /// @param guid Message guid.
    /// @param index Compose index (0 for the default OFT single-compose flow).
    /// @param message Raw compose payload; stored as keccak256(message).
    /// @dev Emits `ComposeSent` with from = msg.sender after the slot write, mirroring MessagingComposer.sol:27.
    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        if (composeQueue[msg.sender][to][guid][index] != bytes32(0)) revert ComposeExists();
        composeQueue[msg.sender][to][guid][index] = keccak256(message);
        emit ComposeSent(msg.sender, to, guid, index, message);
    }

    /// @notice Execute a composed message, mirroring the real composer's authenticated execute path.
    /// @dev Mirrors `MessagingComposer.lzCompose` (MessagingComposer.sol): validates `keccak256(message)` against the
    ///      queue slot written by `sendCompose`, writes the RECEIVED sentinel to block replay/reentrancy, then forwards
    ///      to the receiver's `ILayerZeroComposer.lzCompose` with `msg.value` and `msg.sender` as the executor. If the
    ///      receiver reverts, the whole call reverts (CEI order matches the real composer).
    /// @param from Address that sent the composed message (the composing OApp).
    /// @param to Receiver of the composed message.
    /// @param guid Message guid.
    /// @param index Compose index (0 for the default OFT single-compose flow).
    /// @param message Raw compose payload; must hash to the stored queue slot.
    /// @param extraData Untrusted executor-provided data forwarded to the receiver.
    /// @dev Emits `ComposeDelivered` as the LAST statement (post-forward, mirroring MessagingComposer.sol:58): a
    ///      reverting receiver rolls back the emit, so the event marks execution completed, not attempted.
    function lzCompose(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        bytes calldata message,
        bytes calldata extraData
    ) external payable {
        if (keccak256(message) != composeQueue[from][to][guid][index]) revert ComposeNotFound();
        composeQueue[from][to][guid][index] = RECEIVED;
        ILayerZeroComposer(to).lzCompose{value: msg.value}(from, guid, message, msg.sender, extraData);
        emit ComposeDelivered(from, to, guid, index);
    }

    /// @notice Alert that a compose execution failed, mirroring the real composer's executor-notification surface.
    /// @dev Mirrors `MessagingComposer.lzComposeAlert` (MessagingComposer.sol:62-79): a pure notification — no state
    ///      change — with the executor recorded as msg.sender.
    /// @param from Address that sent the composed message (the composing OApp).
    /// @param to Receiver of the composed message.
    /// @param guid Message guid.
    /// @param index Compose index.
    /// @param gas Gas limit the failed execution was given.
    /// @param value Value forwarded with the failed execution.
    /// @param message Raw compose payload.
    /// @param extraData Executor-provided data forwarded to the receiver.
    /// @param reason Failure reason.
    function lzComposeAlert(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        uint256 gas,
        uint256 value,
        bytes calldata message,
        bytes calldata extraData,
        bytes calldata reason
    ) external {
        emit LzComposeAlert(from, to, msg.sender, guid, index, gas, value, message, extraData, reason);
    }

    /// @notice Store the delegate set by an OApp during initialization (the real endpoint tracks it).
    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }

    /// @notice Plant a delivered-but-pending hash (keccak256(message)) for a compose.
    function setQueue(address from, address to, bytes32 guid, uint16 index, bytes32 hash) external {
        composeQueue[from][to][guid][index] = hash;
    }

    /// @notice Mark a compose as executed by the endpoint (lzCompose ran), stored as the RECEIVED sentinel.
    function markReceived(address from, address to, bytes32 guid, uint16 index) external {
        composeQueue[from][to][guid][index] = RECEIVED;
    }
}
