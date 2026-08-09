// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Single source of the composer lifecycle enum, shared by interfaces that expose the same
///         `lzCompose` / `settlePendingCompose` single-resolution mutex (e.g. IYieldDispatcher,
///         IOmnichainMemecoinStaker). Declared once here to keep the invariant documentation from
///         drifting between copies.
interface IComposeState {
    /// @notice Resolution state of a (bridged token, guid) pair, used as a cross-entry mutex between
    ///         `lzCompose` and `settlePendingCompose`.
    /// @dev `None` is the zero default and MUST remain the first member (value 0): the `composeStates`
    ///      mapping's zero-initialized slots must read as `None` (unresolved). Reordering the enum would
    ///      silently break the `require(composeStates[...][guid] == ComposeState.None)` guards in
    ///      `lzCompose` and `settlePendingCompose`. It advances to `Settled` (lzCompose ran to completion —
    ///      happy-path settlement or `ComposeRejected` consumption of a frame that can never settle) or
    ///      `Released` (settlePendingCompose success) at most once per (bridged token, guid) pair; keying
    ///      on the genuine bridged token prevents a forged-token settle from burning a real guid's mutex.
    ///      Only the value semantics shared by all composers are documented here; each composer's own
    ///      `lzCompose` documents its malformed-payload branch (e.g. one consumes it as a no-settlement
    ///      `Settled`, another reverts and rolls back to `None`).
    ///      Shared rationale (authoritative here): a `Released` pair is absorbed by `lzCompose` as a no-op
    ///      (no state change, no settlement) so a late endpoint retry converges the endpoint state machine
    ///      (RECEIVED sentinel + ComposeDelivered) instead of reverting and pinning the queue for executor
    ///      retries; frames that can never settle are consumed to `Settled` without settlement, which blocks
    ///      no legitimate settlement (see `ComposeRejected` below); funds stranded by sender-built self-harm
    ///      frames are a documented boundary with no owner-recovery entrypoint.
    enum ComposeState {
        None,
        Settled,
        Released
    }

    /// @dev Shared compose-flow errors, single-sourced here. Both composer interfaces
    ///      (`IYieldDispatcher`, `IOmnichainMemecoinStaker`) and the shared verification library
    ///      (`OFTComposeSettleVerify`) used to declare byte-identical copies of each; selectors derive
    ///      purely from signatures, so a one-sided rename or parameter change silently diverged the
    ///      runtime revert data from the interface ABI, with only the tests' `expectRevert(selector)`
    ///      assertions as a guard. Inheriting one declaration makes drift a compile-time failure.
    ///      `NotDelivered` / `InvalidProof` are emitted by the library's `verifySettle`; the composers
    ///      never revert them directly.
    error NotDelivered();

    error AlreadyExecuted();

    error InvalidProof();

    error MalformedComposeMsg();

    /// @notice Emitted when `lzCompose` consumes a compose payload that can never be settled (malformed
    ///         or out-of-range format, or — dispatcher only — a clean parseable frame naming the
    ///         dispatcher itself as receiver). The (bridged token, guid) slot is advanced to `Settled`
    ///         with NO settlement and no funds moved, so the endpoint state machine converges (RECEIVED
    ///         sentinel + ComposeDelivered) instead of pinning the queue for executor retries. `amount`
    ///         is the payload's amountLD when readable (frames >= 44 bytes), 0 otherwise. Monitoring
    ///         signal for sender-side malformed/self-harm messages. Parameter name is `token` for both
    ///         composers (the staker's memecoin is a token too); parameter names do not affect topic0.
    event ComposeRejected(bytes32 indexed guid, address indexed token, uint256 amount);
}
