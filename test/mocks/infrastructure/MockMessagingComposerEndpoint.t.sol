// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import {OFTComposeSettleVerify} from "../../../src/common/omnichain/OFTComposeSettleVerify.sol";
import {MockMessagingComposerEndpoint} from "./MockMessagingComposerEndpoint.sol";

/// @dev Pins the `ComposeExists` guard of MockMessagingComposerEndpoint: a compose queue slot may only be written once,
///      mirroring the real composer's `LZ_ComposeExists` (MessagingComposer.sol). The guard is keyed by msg.sender, so
///      every resend must use the same prank sender as the original `sendCompose`.
contract MockMessagingComposerEndpointTest is Test {
    address internal constant SENDER = address(0xA11CE);
    address internal constant TO = address(0xBEEF);
    bytes32 internal constant GUID = keccak256("guid");
    bytes internal constant MESSAGE = "compose payload";

    MockMessagingComposerEndpoint internal endpoint;

    /// @notice Deploy the mock (no constructor args, same shape as production usage).
    function setUp() external {
        endpoint = new MockMessagingComposerEndpoint();
    }

    /// @notice First send for a key succeeds and writes keccak256(message) into the queue slot.
    function test_SendCompose_WritesComposeQueueSlot() external {
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);

        assertEq(endpoint.composeQueue(SENDER, TO, GUID, 0), keccak256(MESSAGE));
    }

    /// @notice Resending the same key from the same sender reverts with ComposeExists (guard pinned, not vacuous:
    ///         the slot assert above proves the guard's non-zero precondition held before the resend).
    function test_RevertWhen_SendComposeResendsSameKey() external {
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);
        assertEq(endpoint.composeQueue(SENDER, TO, GUID, 0), keccak256(MESSAGE));

        vm.expectRevert(MockMessagingComposerEndpoint.ComposeExists.selector);
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);
    }

    /// @notice After the compose is executed (slot holds the non-zero RECEIVED sentinel, as lzCompose leaves it),
    ///         resending the same key still reverts with ComposeExists, mirroring the real composer's behavior.
    function test_RevertWhen_SendComposeResendsAfterReceived() external {
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);

        endpoint.markReceived(SENDER, TO, GUID, 0);
        assertEq(endpoint.composeQueue(SENDER, TO, GUID, 0), OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH);

        vm.expectRevert(MockMessagingComposerEndpoint.ComposeExists.selector);
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);
    }

    /// @notice Locks the CEI order of `lzCompose`: the RECEIVED sentinel (EFFECT) must already be visible in the compose
    ///         queue at the moment the receiver's callback (INTERACTION) runs. A forward-then-write reorder would leave the
    ///         slot still holding keccak256(MESSAGE) here, so the assert would fail — pinning effects-before-interactions.
    function test_LzCompose_WritesReceivedBeforeForward() external {
        ReceivedAssertingComposer composer = new ReceivedAssertingComposer(endpoint);

        vm.prank(SENDER);
        endpoint.sendCompose(address(composer), GUID, 0, MESSAGE);

        endpoint.lzCompose(SENDER, address(composer), GUID, 0, MESSAGE, "");
    }

    /// @notice `sendCompose` emits `ComposeSent` with from = msg.sender (the composing OApp), mirroring the real
    ///         composer's event (MessagingComposer.sol:27) so log-based tests can anchor the ops runbook.
    function test_SendCompose_EmitsComposeSent() external {
        vm.expectEmit(true, true, true, true);
        emit MockMessagingComposerEndpoint.ComposeSent(SENDER, TO, GUID, 0, MESSAGE);
        vm.prank(SENDER);
        endpoint.sendCompose(TO, GUID, 0, MESSAGE);
    }

    /// @notice `lzCompose` emits `ComposeDelivered` AFTER the forward succeeds (mirroring MessagingComposer.sol:58),
    ///         with all params non-indexed — topic0 only, payload fully in data.
    function test_LzCompose_EmitsComposeDeliveredAfterForward() external {
        ReceivedAssertingComposer composer = new ReceivedAssertingComposer(endpoint);

        vm.prank(SENDER);
        endpoint.sendCompose(address(composer), GUID, 0, MESSAGE);

        bytes32 composeDeliveredTopic0 = keccak256("ComposeDelivered(address,address,bytes32,uint16)");
        vm.recordLogs();
        endpoint.lzCompose(SENDER, address(composer), GUID, 0, MESSAGE, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            // Zero indexed params -> exactly one topic (topic0); the (from, to, guid, index) payload lives in data.
            if (logs[i].topics.length != 1 || logs[i].topics[0] != composeDeliveredTopic0) continue;
            found = true;
            (address from, address to, bytes32 guid, uint16 index) =
                abi.decode(logs[i].data, (address, address, bytes32, uint16));
            assertEq(from, SENDER, "ComposeDelivered from");
            assertEq(to, address(composer), "ComposeDelivered to");
            assertEq(guid, GUID, "ComposeDelivered guid");
            assertEq(uint256(index), 0, "ComposeDelivered index");
        }
        assertTrue(found, "lzCompose emitted ComposeDelivered after the forward");
    }

    /// @notice A reverting receiver rolls back the `ComposeDelivered` emit (it sits after the forward): the queue slot
    ///         stays keccak256(MESSAGE) (the RECEIVED write rolled back too) and no ComposeDelivered log is recorded.
    function test_LzCompose_RevertingReceiverRollsBackDelivered() external {
        RevertingComposer composer = new RevertingComposer();

        vm.prank(SENDER);
        endpoint.sendCompose(address(composer), GUID, 0, MESSAGE);

        bytes32 composeDeliveredTopic0 = keccak256("ComposeDelivered(address,address,bytes32,uint16)");
        vm.recordLogs();
        vm.expectRevert("compose receiver failed");
        endpoint.lzCompose(SENDER, address(composer), GUID, 0, MESSAGE, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The CEI write rolled back with the call: the slot still holds the delivery hash, not the RECEIVED sentinel.
        assertEq(endpoint.composeQueue(SENDER, address(composer), GUID, 0), keccak256(MESSAGE));
        // No ComposeDelivered log: the emit sits after the forward, so a reverting receiver never reaches it.
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != composeDeliveredTopic0, "reverted lzCompose emitted ComposeDelivered");
        }
    }

    /// @notice `lzComposeAlert` emits `LzComposeAlert` with executor = msg.sender (mirroring MessagingComposer.sol:62-79)
    ///         and changes no mock state — it is a pure notification.
    function test_LzComposeAlert_EmitsWithExecutor() external {
        bytes memory message = "compose payload";
        bytes memory extraData = "executor data";
        bytes memory reason = "execution failed";

        // Pure notification: the compose queue slot is untouched before and after the call.
        assertEq(endpoint.composeQueue(SENDER, TO, GUID, 0), bytes32(0));

        vm.expectEmit(true, true, true, true);
        emit MockMessagingComposerEndpoint.LzComposeAlert(
            SENDER, TO, address(this), GUID, 0, 300_000, 1 ether, message, extraData, reason
        );
        endpoint.lzComposeAlert(SENDER, TO, GUID, 0, 300_000, 1 ether, message, extraData, reason);

        assertEq(endpoint.composeQueue(SENDER, TO, GUID, 0), bytes32(0), "alert left the queue slot untouched");
    }
}

/// @notice Test-local `ILayerZeroComposer` that asserts the mock endpoint's compose-queue slot already holds the RECEIVED
///         sentinel while its own callback is executing (i.e. mid-forward from `MockMessagingComposerEndpoint.lzCompose`).
/// @dev This is a test helper, not a mock of a production contract. It reuses the public `composeQueue` getter and the
///      `OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH` sentinel already imported by the test file above.
contract ReceivedAssertingComposer is StdAssertions, ILayerZeroComposer {
    MockMessagingComposerEndpoint internal immutable endpoint;

    constructor(MockMessagingComposerEndpoint endpoint_) {
        endpoint = endpoint_;
    }

    /// @inheritdoc ILayerZeroComposer
    /// @dev Read the queue slot from inside the forward: if CEI is honored it already equals RECEIVED.
    function lzCompose(address _from, bytes32 _guid, bytes calldata, address, bytes calldata) external payable {
        assertEq(endpoint.composeQueue(_from, address(this), _guid, 0), OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH);
    }
}

/// @notice Test-local `ILayerZeroComposer` that always reverts, so the mock's post-forward `ComposeDelivered` emit can
///         never execute — pinning that a failed forward produces no delivered signal (and rolls back the RECEIVED write).
contract RevertingComposer is ILayerZeroComposer {
    /// @inheritdoc ILayerZeroComposer
    function lzCompose(address, bytes32, bytes calldata, address, bytes calldata) external payable {
        revert("compose receiver failed");
    }
}
