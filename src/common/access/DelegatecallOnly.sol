// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title DelegatecallOnly
/// @notice Mixin that rejects direct (non-delegatecall) entry to a contract that is meant to run in a
///         proxy's storage context. Used by the MemeverseLauncher delegatecall siblings
///         (`MemeverseLaunchImpl` / `MemeverseSettlementImpl` / `MemeverseLiquidityImpl`): under normal use
///         the facade `functionDelegateCall`s into them, so `address(this)` is the launcher proxy and every
///         storage read/write lands on the proxy. A direct call instead runs against the sibling's own
///         permanently uninitialized storage; this mixin turns that implicit safety into an explicit
///         entry guard that reverts before any storage access.
/// @dev `_SELF` is captured where the contract is constructed (when `address(this)` is the sibling's real
///      deployed address) and stored as `immutable`. Immutable values are embedded directly in the
///      sibling's own runtime bytecode — they occupy no storage slot — so under delegatecall, where the
///      running code is still the sibling's, `_SELF` keeps its true address even though `address(this)`
///      becomes the proxy and any storage read would resolve to the proxy's slots. Hence a direct call has
///      `address(this) == _SELF` and reverts, while a delegatecall has `address(this) != _SELF` and passes.
abstract contract DelegatecallOnly {
    /// @dev Reverted when a `DelegatecallOnly` entrypoint is called directly instead of via delegatecall.
    error DelegatecallOnlyCall();

    /// @dev The sibling's own deployed address, captured at construction and embedded in its bytecode.
    address private immutable _SELF = address(this);

    /// @dev Reverts on direct calls (`address(this) == _SELF`); passes under delegatecall.
    modifier onlyDelegatecall() {
        if (address(this) == _SELF) revert DelegatecallOnlyCall();
        _;
    }
}
