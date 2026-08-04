// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

import {OutrunOAppPreCrimeSimulatorInit} from "../../../src/common/omnichain/oapp/OutrunOAppPreCrimeSimulatorInit.sol";

/// @title OAppPreCrimeSimulatorHarness
/// @notice Minimal host for `OutrunOAppPreCrimeSimulatorInit`, isolating the PreCrime adapter from the OFT
///         credit path. The production inheritance chain (OutrunOFTCoreInit) overrides `_lzReceiveSimulate`
///         to route into OFT mint/credit logic, which would entangle PreCrime coverage with OFT behavior.
///         This harness instead records each simulated receive, so tests assert purely on the simulator's
///         adapter surface: ERC-7201 storage, `OutrunOwnableInit`-based `onlyOwner`, and the `OnlySelf` /
///         peer-skip / `SimulationResult` branches.
contract OAppPreCrimeSimulatorHarness is OutrunOAppPreCrimeSimulatorInit {
    /// @dev Trust table consulted by the inherited `isPeer`; mirrors how `OutrunOFTCoreInit.isPeer` delegates
    ///      to the `peers` mapping, without pulling in the full OApp core.
    mapping(uint32 eid => bytes32 peer) private trustedPeers;

    /// @dev Last packet replayed by `_lzReceiveSimulate`, exposed for assertions. Note: writes here are
    ///      reverted whenever the caller reaches the terminal `SimulationResult` revert in `lzReceiveAndRevert`,
    ///      so these fields are only observable when `_lzReceiveSimulate` is invoked directly (not via the
    ///      always-reverting `lzReceiveAndRevert`).
    uint32 public lastSrcEid;
    bytes32 public lastSender;
    bytes32 public lastGuid;
    bytes public lastMessage;
    address public lastExecutor;
    bytes public lastExtraData;
    uint256 public lastValue;

    /// @dev When true, `_lzReceiveSimulate` reverts with `ReplayObserved` instead of recording. Because
    ///      `lzReceiveAndRevert` propagates the first revert from the replay loop, flipping this sentinel
    ///      changes the terminal revert from `SimulationResult` to `ReplayObserved` — letting a test tell
    ///      whether a packet was actually replayed (vs. skipped by the peer check), even though the
    ///      always-revert semantics would otherwise erase the storage writes. The sentinel carries the
    ///      replayed packet's `(srcEid, sender, value)` so a test can prove WHICH packet was replayed and
    ///      that `msg.value` was forwarded — distinguishing per-packet skip from a replay-all bug.
    bool public failReplayWithSentinel;

    /// @dev Sentinel proving a packet reached `_lzReceiveSimulate`, carrying the packet identity and forwarded
    ///      value. Distinct selector from `SimulationResult` so `vm.expectRevert` can tell replay-happened
    ///      apart from skip-happened, and the payload lets a test assert the right packet was replayed with
    ///      the right value.
    error ReplayObserved(uint32 srcEid, bytes32 sender, uint256 value);

    /// @notice Seed a trusted peer so the inherited `isPeer` returns true for `(eid, peer)`.
    /// @param eid See implementation.
    /// @param peer See implementation.
    function setTrustedPeer(uint32 eid, bytes32 peer) external {
        trustedPeers[eid] = peer;
    }

    /// @notice Arm the replay sentinel so the next `_lzReceiveSimulate` reverts `ReplayObserved`.
    /// @param armed See implementation.
    function setFailReplayWithSentinel(bool armed) external {
        failReplayWithSentinel = armed;
    }

    /// @notice Initialize owner via `OutrunOwnableInit` and the PreCrime init chain.
    /// @dev Mirrors the production pattern where ownable + module inits run inside one `initializer`.
    /// @param owner_ See implementation.
    function initialize(address owner_) external initializer {
        __OutrunOwnable_init(owner_);
        __OutrunOAppPreCrimeSimulator_init();
    }

    /// @notice `isPeer` override backed by `trustedPeers`; matches `OutrunOFTCoreInit.isPeer` semantics
    ///         (trusted when stored peer equals the queried one).
    /// @param _eid See implementation.
    /// @param _peer See implementation.
    /// @return trusted True when `_peer` matches the seeded peer for `_eid`.
    function isPeer(uint32 _eid, bytes32 _peer) public view override returns (bool) {
        return trustedPeers[_eid] == _peer;
    }

    /// @notice Records the simulated packet, or reverts the sentinel when armed. Recording (not executing
    ///         OFT credit logic) keeps this harness focused on the PreCrime adapter surface.
    function _lzReceiveSimulate(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        if (failReplayWithSentinel) revert ReplayObserved(_origin.srcEid, _origin.sender, msg.value);

        lastSrcEid = _origin.srcEid;
        lastSender = _origin.sender;
        lastGuid = _guid;
        lastMessage = _message;
        lastExecutor = _executor;
        lastExtraData = _extraData;
        lastValue = msg.value;
    }
}
