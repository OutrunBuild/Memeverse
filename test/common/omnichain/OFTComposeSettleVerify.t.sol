// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {OFTComposeSettleVerify} from "../../../src/common/omnichain/OFTComposeSettleVerify.sol";
import {IComposeState} from "../../../src/common/types/IComposeState.sol";
import {MockMessagingComposerEndpoint} from "../../mocks/infrastructure/MockMessagingComposerEndpoint.sol";

/// @dev Pins the guard matrix of the shared fund-gate library `OFTComposeSettleVerify.verifySettle` directly, in order:
///      (1) zero queue slot -> NotDelivered, (2) RECEIVED sentinel -> AlreadyExecuted, (3) keccak256(message) mismatch
///      -> InvalidProof, (4) frame < COMPOSE_HEADER_LENGTH (76) -> MalformedComposeMsg, (5) success decodes amountLD
///      ([12:44]) and composeMsg ([76:]) from the verified frame. The composer suites (YieldDispatcherUpgradeable /
///      OmnichainMemecoinStaker) cover this library only through their own `settlePendingCompose` paths; this file
///      isolates the library so a guard regression is attributed to the gate itself, not to a caller-side change.
///      The library's `internal` function cannot be invoked through the test contract directly in a way that
///      preserves the production calling context, so a test-local host contract wraps it: the library inlines into
///      the host, and `address(this)` inside `verifySettle` is the host's address — the endpoint queue slot must be
///      planted under `to = address(host)`, exactly as the composers plant under their own address.
contract OFTComposeSettleVerifyTest is Test {
    /// @dev Key of the composeQueue first dimension (`from`): the bridged token owning the compose payload.
    address internal constant TOKEN = address(0xC0FFEE);

    /// @dev Arbitrary compose guid; each test uses the same one because every test starts from a fresh slot.
    bytes32 internal constant GUID = keccak256("settle-verify-guid");

    MockMessagingComposerEndpoint internal endpoint;
    VerifySettleHost internal host;

    /// @notice Deploy the endpoint mock and the test-local host that inlines `OFTComposeSettleVerify.verifySettle`.
    function setUp() external {
        endpoint = new MockMessagingComposerEndpoint();
        host = new VerifySettleHost();
    }

    /// @notice Guard 1: a zero `composeQueue` slot (never delivered) reverts `NotDelivered` before any other check.
    function test_RevertWhen_NotDelivered() external {
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("payload"));

        // composeQueue[TOKEN][host][GUID][0] defaults to bytes32(0) — never delivered.
        vm.expectRevert(IComposeState.NotDelivered.selector);
        host.verifySettle(address(endpoint), TOKEN, GUID, message);
    }

    /// @notice Guard 2: the RECEIVED sentinel (lzCompose already ran) reverts `AlreadyExecuted`.
    /// @dev The sentinel check precedes the hash check, so the submitted message's hash need not match the slot.
    function test_RevertWhen_AlreadyExecuted() external {
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("payload"));

        endpoint.markReceived(TOKEN, address(host), GUID, 0);

        // Anchor the mock-planted sentinel to the real protocol literal (MessagingComposer.sol's private constant),
        // so a sentinel drift in the library's mirrored copy cannot keep mock + test green together.
        assertEq(
            endpoint.composeQueue(TOKEN, address(host), GUID, 0),
            bytes32(uint256(1)),
            "RECEIVED sentinel must equal MessagingComposer's protocol value"
        );

        vm.expectRevert(IComposeState.AlreadyExecuted.selector);
        host.verifySettle(address(endpoint), TOKEN, GUID, message);
    }

    /// @notice Guard 3: a frame whose keccak256 does not match the planted queue hash reverts `InvalidProof`.
    /// @dev Both frames are >= COMPOSE_HEADER_LENGTH (76): the 44-byte codec prefix plus a 32-byte compose-from
    ///      word plus a short inner payload (80 bytes total). The length guard therefore cannot fire first; only
    ///      the keccak256 binding can reject.
    function test_RevertWhen_InvalidProof() external {
        bytes memory queued = OFTComposeMsgCodec.encode(1, 101, 1 ether, abi.encodePacked(bytes32(0), "real"));
        bytes memory submitted = OFTComposeMsgCodec.encode(1, 101, 2 ether, abi.encodePacked(bytes32(0), "fake"));
        assertGe(queued.length, 76);
        assertGe(submitted.length, 76);

        endpoint.setQueue(TOKEN, address(host), GUID, 0, keccak256(queued));

        vm.expectRevert(IComposeState.InvalidProof.selector);
        host.verifySettle(address(endpoint), TOKEN, GUID, submitted);
    }

    /// @notice Guard 4: a frame below COMPOSE_HEADER_LENGTH (76) reverts `MalformedComposeMsg` with a named error
    ///         instead of an opaque codec slice revert. Also pins the 75-byte boundary: the frame is exactly one
    ///         byte below the threshold.
    /// @dev The queue hash MUST match the short frame's keccak256, otherwise guard 3 fires first and the length
    ///      guard is never reached.
    function test_RevertWhen_MalformedComposeMsg_BelowHeaderLength() external {
        // Zero-filled 75-byte frame (< 76, header incomplete).
        bytes memory message = new bytes(75);
        endpoint.setQueue(TOKEN, address(host), GUID, 0, keccak256(message));

        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        host.verifySettle(address(endpoint), TOKEN, GUID, message);
    }

    /// @notice Success path: a genuine frame (hash-bound to the slot) passes all guards and returns the decoded
    ///         amountLD ([12:44]) and composeMsg ([76:]).
    /// @dev The codec's `encode` emits only the 44-byte prefix (nonce 8 + srcEid 4 + amountLD 32); the 32-byte
    ///      compose-from word is part of the `_composeMsg` argument, matching the production wire format
    ///      `encode(nonce, srcEid, amount, composeFrom || inner)`. `composeMsg` therefore reads [76:] = `inner`.
    function test_VerifySettle_ReturnsAmountAndComposeMsg() external {
        // True full-width value covering all 32 bytes of amountLD: a uint64-truncated read would drop the high
        // bits and fail the assertion below.
        uint256 amount = (uint256(1) << 200) | 12345;
        bytes32 composeFromWord = bytes32(uint256(uint160(0xBEEF)));
        bytes memory innerPayload = abi.encodePacked(hex"deadbeef", bytes32(uint256(42)));
        bytes memory message =
            OFTComposeMsgCodec.encode(7, 30116, amount, abi.encodePacked(composeFromWord, innerPayload));
        assertEq(message.length, 44 + 32 + innerPayload.length);

        endpoint.setQueue(TOKEN, address(host), GUID, 0, keccak256(message));

        (uint256 returnedAmount, bytes memory returnedComposeMsg) =
            host.verifySettle(address(endpoint), TOKEN, GUID, message);

        assertEq(returnedAmount, amount);
        assertEq(returnedComposeMsg, innerPayload);
    }

    /// @notice Boundary: a frame of exactly COMPOSE_HEADER_LENGTH (76) bytes — full header including the 32-byte
    ///         compose-from word, empty inner composeMsg — passes the length guard and decodes successfully.
    /// @dev `encode` emits 44 bytes (nonce 8 + srcEid 4 + amountLD 32); appending only the compose-from word makes
    ///      the frame exactly 76 bytes, the codec's minimum for a complete header.
    function test_VerifySettle_ExactHeaderLengthFrame() external {
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, abi.encodePacked(bytes32(uint256(42))));
        assertEq(message.length, 76);

        endpoint.setQueue(TOKEN, address(host), GUID, 0, keccak256(message));

        (uint256 returnedAmount, bytes memory returnedComposeMsg) =
            host.verifySettle(address(endpoint), TOKEN, GUID, message);

        assertEq(returnedAmount, 1 ether);
        assertEq(returnedComposeMsg.length, 0);
    }
}

/// @notice Test-local host for the `internal` library function `OFTComposeSettleVerify.verifySettle`: an external
///         wrapper with the same parameters and returns, so tests can drive the fund gate through a contract call.
/// @dev The library's `internal view` function inlines into this host, making `address(this)` the host's address —
///      the endpoint's `composeQueue` slot must be planted under `to = address(this)`, mirroring how the production
///      composers read `composeQueue[token][address(this)][guid][0]`.
contract VerifySettleHost {
    /// @notice Wraps `OFTComposeSettleVerify.verifySettle` unchanged.
    /// @param endpoint Local LayerZero endpoint address (the MessagingComposer).
    /// @param token Bridged token address owning the compose payload.
    /// @param guid Compose guid.
    /// @param message The original compose payload.
    /// @return amount Released amount in local decimals.
    /// @return composeMsg The decoded compose payload.
    function verifySettle(address endpoint, address token, bytes32 guid, bytes calldata message)
        external
        view
        returns (uint256 amount, bytes memory composeMsg)
    {
        return OFTComposeSettleVerify.verifySettle(endpoint, token, guid, message);
    }
}
