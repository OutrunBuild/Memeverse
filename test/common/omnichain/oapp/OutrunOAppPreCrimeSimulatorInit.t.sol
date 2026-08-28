// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {InboundPacket} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";
import {IOAppPreCrimeSimulator} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";

import {OutrunOwnable} from "../../../../src/common/access/OutrunOwnable.sol";
import {OAppPreCrimeSimulatorHarness} from "../../../mocks/infrastructure/OAppPreCrimeSimulatorHarness.sol";
import {MockPreCrimeCaller} from "../../../mocks/common/PreCrimeMocks.sol";

/// @title OutrunOAppPreCrimeSimulatorInitTest
/// @notice Coverage for the PreCrime simulator adapter. The simulator's pure logic (peer-skip, OnlySelf guard,
///         SimulationResult revert) is verbatim from LayerZero's `OAppPreCrimeSimulator`; this suite targets the
///         adapter-divergence surface unique to this repo — ERC-7201 storage reads/writes, `OutrunOwnableInit`-
///         based `onlyOwner`, and the init hook — plus thin regression on the inherited branches now wired into
///         the production OFT inheritance chain.
contract OutrunOAppPreCrimeSimulatorInitTest is Test {
    using Clones for address;

    address internal constant OWNER = address(0xABCD);
    address internal constant NON_OWNER = address(0xDEAD);
    uint32 internal constant SRC_EID = 101;
    bytes32 internal constant PEER = bytes32(uint256(uint160(address(0xBEEF))));
    bytes32 internal constant UNTRUSTED_SENDER = bytes32(uint256(uint160(address(0x9999))));

    OAppPreCrimeSimulatorHarness internal implementation;
    OAppPreCrimeSimulatorHarness internal harness;
    MockPreCrimeCaller internal preCrimeCaller;

    /// @notice Set up: clone the harness (exercises the minimal-proxy init path the production OFT uses) and a
    ///         mock verifier whose `buildSimulationResult` feeds the terminal revert.
    /// @dev `vm.startPrank`/`vm.stopPrank` brackets the `lzReceiveAndRevert` calls. Empirically, pairing a
    ///      single-shot `vm.prank` with `vm.expectRevert` around a high-level call into a clone proxy leaves
    ///      `msg.sender` as the test contract at the terminal `buildSimulationResult()` call; `startPrank` holds
    ///      the impersonation for the whole call. `stopPrank` is called after each (the expected revert ends the
    ///      call before `stopPrank`, but the bracket keeps the cheatcode balanced across tests).
    function setUp() external {
        implementation = new OAppPreCrimeSimulatorHarness();
        harness = OAppPreCrimeSimulatorHarness(address(implementation).clone());
        harness.initialize(OWNER);
        preCrimeCaller = new MockPreCrimeCaller(bytes("sim-result"));
    }

    // ----------------------------------------------------------------------------------------------
    // Adapter-divergence surface (high value: repo-specific ERC-7201 storage + OutrunOwnableInit wiring)
    // ----------------------------------------------------------------------------------------------

    /// @notice `preCrime()` reads the simulator's dedicated storage slot, so it must return address(0) before
    ///         any set. Guards against a slot-collision or init bug silently seeding a non-zero value.
    function testPreCrimeReadsZeroBeforeSet() external {
        assertEq(harness.preCrime(), address(0));
    }

    /// @notice `oApp()` returns the clone's own address. The adapter inherits this verbatim, but it is the
    ///         value the PreCrime implementation uses as the simulation target, so a proxy-storage bug here
    ///         would misroute simulation.
    function testOAppReturnsSelfAddress() external {
        assertEq(harness.oApp(), address(harness));
    }

    /// @notice `setPreCrime` is `onlyOwner` resolved through `OutrunOwnableInit` (not OZ Ownable). A non-owner
    ///         must revert with the ownable error; this confirms the adapter's owner check is wired to the
    ///         initialized owner, not a stale/zero owner.
    function testSetPreCrimeRevertsForNonOwner() external {
        vm.prank(NON_OWNER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, NON_OWNER));
        harness.setPreCrime(address(preCrimeCaller));
    }

    /// @notice Owner sets the preCrime address: storage-slot write + `PreCrimeSet` event + getter reflects it.
    ///         This is the core adapter write path — the slot must be the simulator's dedicated location, not a
    ///         collided one.
    function testOwnerSetPreCrimeWritesSlotAndEmits() external {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit IOAppPreCrimeSimulator.PreCrimeSet(address(preCrimeCaller));
        harness.setPreCrime(address(preCrimeCaller));

        assertEq(harness.preCrime(), address(preCrimeCaller));
    }

    /// @notice Owner can re-set (incl. to address(0)); confirms the slot write is idempotent and not locked to
    ///         a one-shot init.
    function testOwnerCanResetPreCrimeToZero() external {
        vm.startPrank(OWNER);
        harness.setPreCrime(address(preCrimeCaller));
        harness.setPreCrime(address(0));
        vm.stopPrank();

        assertEq(harness.preCrime(), address(0));
    }

    // ----------------------------------------------------------------------------------------------
    // Inherited-branch regression (thin: pure logic is verbatim upstream; here it is first wired into the
    // production OFT inheritance chain, so we assert the branches behave as documented)
    // ----------------------------------------------------------------------------------------------

    /// @notice `lzReceiveSimulate` rejects any caller that is not `address(this)`. The guard is inherited from
    ///         upstream; this asserts it survives the adapter's storage/init reshape.
    function testLzReceiveSimulateRevertsWhenCallerIsNotSelf() external {
        Origin memory origin = _origin(PEER);
        vm.expectRevert(IOAppPreCrimeSimulator.OnlySelf.selector);
        harness.lzReceiveSimulate(origin, bytes32("guid"), bytes("msg"), address(0), "");
    }

    /// @notice `lzReceiveAndRevert` always reverts with `SimulationResult(IPreCrime(msg.sender).buildSimulationResult())`.
    ///         With no trusted peer seeded, every packet is skipped and the terminal revert still fires with the
    ///         verifier's bytes — proving the adapter forwards the current `IPreCrime(msg.sender)` result and the
    ///         skip path still reaches the terminal revert.
    function testLzReceiveAndRevertSkipsUntrustedPeer() external {
        // No trusted peer seeded for (SRC_EID, UNTRUSTED_SENDER).
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = _packet(UNTRUSTED_SENDER, bytes("msg"));

        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(_expectedSimulationResult());
        harness.lzReceiveAndRevert{value: 0}(packets);
        vm.stopPrank();
    }

    /// @notice A trusted-peer packet is replayed through `_lzReceiveSimulate`. Because `lzReceiveAndRevert`
    ///         always reverts (rolling back any storage the replay wrote), replay-vs-skip is proven via the
    ///         sentinel: arming `failReplayWithSentinel` flips the terminal revert to `ReplayObserved` only if
    ///         the packet actually reached `_lzReceiveSimulate`. A skipped packet would still revert with
    ///         `SimulationResult`. The sentinel carries `(srcEid, sender, value)`, asserted to be the trusted
    ///         peer — so the test fails under both a skip-bug (surfaces `SimulationResult`) and a replay-all bug
    ///         (would surface the wrong sender).
    function testLzReceiveAndRevertReplaysTrustedPeerPacket() external {
        harness.setTrustedPeer(SRC_EID, PEER);
        harness.setFailReplayWithSentinel(true);

        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = _packet(PEER, bytes("payload"));

        // Sentinel with the trusted peer's identity proves that packet was replayed, not skipped.
        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(
            abi.encodeWithSelector(OAppPreCrimeSimulatorHarness.ReplayObserved.selector, SRC_EID, PEER, uint256(0))
        );
        harness.lzReceiveAndRevert{value: 0}(packets);
        vm.stopPrank();
    }

    /// @notice Mixed-trust batch: the untrusted packet is skipped (no replay), the trusted one is replayed.
    ///         The sentinel carries packet identity, so asserting `(SRC_EID, PEER)` proves the per-packet skip
    ///         is selective — a replay-all bug would surface `(SRC_EID, UNTRUSTED_SENDER)` (the first packet)
    ///         and fail this assertion. If both were skipped the revert would be `SimulationResult`.
    function testLzReceiveAndRevertSkipsUntrustedButReplaysTrustedInSameBatch() external {
        harness.setTrustedPeer(SRC_EID, PEER);
        harness.setFailReplayWithSentinel(true);

        InboundPacket[] memory packets = new InboundPacket[](2);
        packets[0] = _packet(UNTRUSTED_SENDER, bytes("skipped"));
        packets[1] = _packet(PEER, bytes("replayed"));

        // Identity must be the trusted peer (second packet); a replay-all bug would surface the untrusted one.
        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(
            abi.encodeWithSelector(OAppPreCrimeSimulatorHarness.ReplayObserved.selector, SRC_EID, PEER, uint256(0))
        );
        harness.lzReceiveAndRevert{value: 0}(packets);
        vm.stopPrank();
    }

    /// @notice `lzReceiveAndRevert` forwards `packet.value` into `this.lzReceiveSimulate{value: packet.value}`
    ///         (src line 83). The sentinel echoes the forwarded `msg.value`, so funding the pranked caller and
    ///         sending value through a trusted packet lets us assert the exact amount round-trips into the
    ///         replayed call. Covers the value-forwarding path that storage asserts cannot reach (revert rolls
    ///         back writes).
    function testLzReceiveAndRevertForwardsPacketValueToReplayedCall() external {
        harness.setTrustedPeer(SRC_EID, PEER);
        harness.setFailReplayWithSentinel(true);

        uint256 forwardedValue = 0.5 ether;
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = _packetWithValue(PEER, bytes("payload"), forwardedValue);

        vm.deal(address(preCrimeCaller), forwardedValue);
        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(
            abi.encodeWithSelector(OAppPreCrimeSimulatorHarness.ReplayObserved.selector, SRC_EID, PEER, forwardedValue)
        );
        harness.lzReceiveAndRevert{value: forwardedValue}(packets);
        vm.stopPrank();
    }

    /// @notice `buildSimulationResult` is read live from `msg.sender` at revert time, not cached. Changing the
    ///         verifier's bytes between calls changes the revert payload — confirms the adapter forwards the
    ///         current `IPreCrime(msg.sender)` result, not a stale copy. Untrusted packets are used so the
    ///         terminal revert (not a replay-side revert) carries the verifier bytes.
    function testSimulationResultReflectsLiveCallerBytes() external {
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = _packet(UNTRUSTED_SENDER, bytes("payload"));

        bytes memory first = bytes("first-result");
        preCrimeCaller.setSimulationResult(first);
        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, first));
        harness.lzReceiveAndRevert{value: 0}(packets);
        vm.stopPrank();

        bytes memory second = bytes("second-result");
        preCrimeCaller.setSimulationResult(second);
        vm.startPrank(address(preCrimeCaller));
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, second));
        harness.lzReceiveAndRevert{value: 0}(packets);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------------

    /// @dev Expected terminal revert payload for the verifier's current `simulationResult`.
    function _expectedSimulationResult() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, preCrimeCaller.simulationResult());
    }

    function _origin(bytes32 sender) internal pure returns (Origin memory) {
        return Origin({srcEid: SRC_EID, sender: sender, nonce: 1});
    }

    function _packet(bytes32 sender, bytes memory message) internal view returns (InboundPacket memory) {
        return _packetWithValue(sender, message, 0);
    }

    function _packetWithValue(bytes32 sender, bytes memory message, uint256 value)
        internal
        view
        returns (InboundPacket memory)
    {
        return InboundPacket({
            origin: Origin({srcEid: SRC_EID, sender: sender, nonce: 1}),
            dstEid: SRC_EID,
            receiver: address(harness),
            guid: bytes32("guid"),
            value: value,
            executor: address(0),
            message: message,
            extraData: ""
        });
    }
}
