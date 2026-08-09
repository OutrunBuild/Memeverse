// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Minimal settle-only view of a compose settlement entry, for callers that only need
///         `settlePendingCompose` without importing the full composer interface.
/// @dev Declares only the settle entry so a caller (e.g. the yield vault's retry path) can depend on
///      the settlement surface without importing the verse-layer composer interface and coupling
///      modules across layers. The full settle semantics are documented once on
///      `IYieldDispatcher.settlePendingCompose`; the shared compose-flow errors and the
///      `ComposeRejected` event are single-sourced in `IComposeState`, and the delivery/authenticity
///      proof semantics are single-sourced in `OFTComposeSettleVerify`.
interface ISettleCompose {
    /// @notice Settles a stuck compose payload to the beneficiary encoded in `message` when `lzCompose` never ran.
    /// @dev Shared semantics (delivery proof via `OFTComposeSettleVerify.verifySettle`, single-resolution
    ///      mutex and errors via `IComposeState`): see `IYieldDispatcher.settlePendingCompose`.
    /// @param token Bridged token to settle.
    /// @param guid LayerZero compose guid.
    /// @param message The original compose payload (reconstructable from the endpoint's `ComposeSent` event log).
    /// @return amount Released amount.
    function settlePendingCompose(address token, bytes32 guid, bytes calldata message) external returns (uint256 amount);
}
