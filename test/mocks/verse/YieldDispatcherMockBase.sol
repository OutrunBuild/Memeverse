// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {YieldDispatcher} from "../../../src/verse/YieldDispatcher.sol";
import {IYieldDispatcher} from "../../../src/verse/interfaces/IYieldDispatcher.sol";
import {IComposeState} from "../../../src/common/types/IComposeState.sol";

/// @notice Shared failure-switch and mid-call compose-state probe mechanism for the YieldDispatcher settlement mocks.
/// @dev MockDispatcherYieldVault and MockDispatcherGovernor (test/verse/YieldDispatcher.t.sol) must expose identical
///      failure and probe control so the settle-fail rollback and CEI write-order tests pin the same contract. The
///      mechanism lives here once instead of being copy-pasted into each mock, so the two mocks stay in sync by
///      construction. Mirrors MockStakerYieldVault's failure switch (see test/mocks/interoperation/InteroperationMocks.sol).
///      Derived mocks keep their production-mirroring callbacks and recorded-state fields, and call
///      `_checkComposeProbes` before their external pull.
abstract contract YieldDispatcherMockBase {
    address public token;
    bool public shouldRevert;
    address public composeProbeDispatcher;
    bytes32 public composeProbeGuid;
    address public composeProbeReleasedDispatcher;
    bytes32 public composeProbeReleasedGuid;

    constructor(address token_) {
        token = token_;
    }

    /// @notice Set whether settling should revert.
    /// @dev Pins the lzCompose settle-fail rollback-retry contract.
    /// @param shouldRevert_ See implementation.
    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    /// @notice Arm the mid-call compose-state probe: the next settle callback asserts the (token, guid) mutex is
    ///         already Settled mid-call, pinning the CEI write order (Settled before the settle external call).
    /// @param dispatcher_ The YieldDispatcher whose composeStates to read.
    /// @param guid_ The compose guid to probe.
    function setComposeProbe(address dispatcher_, bytes32 guid_) external {
        composeProbeDispatcher = dispatcher_;
        composeProbeGuid = guid_;
    }

    /// @notice Arm the mid-call Released-state probe: the next settle callback asserts the (token, guid) mutex is
    ///         already Released mid-call, pinning the settlePendingCompose CEI write order (Released written before
    ///         the settle external call) — the Released counterpart of setComposeProbe's Settled assertion.
    /// @param dispatcher_ The YieldDispatcher whose composeStates to read.
    /// @param guid_ The compose guid to probe.
    function setComposeProbeReleased(address dispatcher_, bytes32 guid_) external {
        composeProbeReleasedDispatcher = dispatcher_;
        composeProbeReleasedGuid = guid_;
    }

    /// @notice Exists only to satisfy the dispatcher's MEMECOIN-branch token↔vault binding check
    ///         (`TokenVaultMismatch`); only vault-type receivers are ever queried — the governor mock does not
    ///         expose this semantic.
    /// @return The stored token.
    function asset() external view returns (address) {
        return token;
    }

    /// @notice Assert the armed probes hold mid-call. Derived mocks call this before their external pull, pinning
    ///         the CEI write order (Settled/Released written before the settle external call).
    /// @param token_ The token whose composeStates to probe — the derived mock's stored token, or a forged-token
    ///         parameter when the callback mirrors a receiver that takes the token as an argument.
    function _checkComposeProbes(address token_) internal view {
        if (composeProbeDispatcher != address(0)) {
            require(
                YieldDispatcher(composeProbeDispatcher).composeStates(token_, composeProbeGuid)
                    == IComposeState.ComposeState.Settled,
                "settled write not visible mid-call"
            );
        }
        if (composeProbeReleasedDispatcher != address(0)) {
            require(
                YieldDispatcher(composeProbeReleasedDispatcher).composeStates(token_, composeProbeReleasedGuid)
                    == IComposeState.ComposeState.Released,
                "released write not visible mid-call"
            );
        }
    }
}
