// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {ERC6372Utils} from "@openzeppelin/contracts/utils/ERC6372Utils.sol";

import {OutrunVotesInit} from "../../../../../src/common/token/extensions/governance/OutrunVotesInit.sol";
import {OutrunERC20VotesInit} from "../../../../../src/common/token/extensions/governance/OutrunERC20VotesInit.sol";
import {
    VotesHarness,
    CappedVotesHarness,
    BlockNumberClockVotesHarness
} from "../../../../mocks/infrastructure/VotesHarness.sol";

contract OutrunERC20VotesInitTest is Test {
    using Clones for address;

    uint256 internal constant ALICE_PK = 0xA11CE;
    address internal immutable ALICE = vm.addr(ALICE_PK);
    address internal constant BOB = address(0xB0B);

    VotesHarness internal implementation;
    VotesHarness internal token;

    /// @notice Set up.
    function setUp() external {
        implementation = new VotesHarness();
        token = VotesHarness(address(implementation).clone());
        token.initialize("Vote Token", "VOTE");
    }

    /// @notice Test initialize sets the EIP-712 domain separator to a literal baseline.
    function testInitializeSetsDomainSeparatorToLiteralBaseline() external view {
        assertEq(
            token.domainSeparator(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("Vote Token")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(token)
                )
            )
        );
    }

    /// @notice Test the cached domain separator stays consistent with the live EIP-712 metadata.
    /// @dev Guards the invariant introduced by the hash cache: `_EIP712Name`/`_EIP712Version`
    ///      must return stable values after init, otherwise the cached `_hashedName`/`_hashedVersion`
    ///      desync from what `eip712Domain()` exposes. This check recomputes the separator from the
    ///      live metadata, so a future dynamic override that diverges from the cache turns red.
    function testDomainSeparatorMatchesLiveEip712Metadata() external view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(
            token.domainSeparator(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    chainId,
                    verifyingContract
                )
            )
        );
    }

    /// @notice Test delegate moves voting power and creates checkpoints.
    function testDelegateMovesVotingPowerAndCreatesCheckpoints() external {
        token.mintTest(ALICE, 10 ether);

        vm.prank(ALICE);
        token.delegate(ALICE);

        assertEq(token.getVotes(ALICE), 10 ether);
        assertEq(token.numCheckpoints(ALICE), 1);

        Checkpoints.Checkpoint208 memory checkpoint = token.checkpoints(ALICE, 0);
        assertEq(checkpoint._value, 10 ether);
    }

    /// @notice Test transfer after delegation updates past votes.
    function testTransferAfterDelegationUpdatesPastVotes() external {
        vm.warp(10);
        token.mintTest(ALICE, 10 ether);

        vm.warp(11);
        vm.prank(ALICE);
        token.delegate(ALICE);

        uint256 snapshotTime = 11;
        vm.warp(12);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 4 ether));

        vm.warp(13);
        assertEq(token.getVotes(ALICE), 6 ether);
        assertEq(token.getPastVotes(ALICE, snapshotTime), 10 ether);
        assertEq(token.getPastTotalSupply(snapshotTime), 10 ether);
    }

    /// @notice Test delegate by sig consumes nonce and assigns votes.
    function testDelegateBySigConsumesNonceAndAssignsVotes() external {
        token.mintTest(ALICE, 5 ether);

        uint256 expiry = block.timestamp + 1 days;
        bytes32 digest = token.delegationDigest(ALICE, token.nonces(ALICE), expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);

        token.delegateBySig(ALICE, token.nonces(ALICE), expiry, v, r, s);

        assertEq(token.delegates(ALICE), ALICE);
        assertEq(token.getVotes(ALICE), 5 ether);
        assertEq(token.nonces(ALICE), 1);
    }

    /// @notice Test get past votes rejects future lookup.
    function testGetPastVotesRejectsFutureLookup() external {
        vm.expectRevert(
            abi.encodeWithSelector(OutrunVotesInit.ERC5805FutureLookup.selector, block.timestamp, token.clock())
        );
        token.getPastVotes(ALICE, block.timestamp);
    }

    /// @notice Test same-second mutations merge into the last checkpoint instead of appending.
    /// @dev The timestamp clock is non-decreasing but not strictly increasing: consecutive fast blocks can
    ///      share a second, and a checkpoint write at an already-recorded timepoint updates the last
    ///      checkpoint in place (equal-key merge) rather than growing the trace.
    function testSameSecondMutationsMergeIntoLastCheckpoint() external {
        vm.warp(10);
        token.mintTest(ALICE, 10 ether);

        vm.warp(11);
        vm.prank(ALICE);
        token.delegate(ALICE);
        assertEq(token.numCheckpoints(ALICE), 1);

        // Two transfers inside the same second (12): the second write lands on an equal checkpoint key.
        vm.warp(12);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 4 ether));
        assertEq(token.numCheckpoints(ALICE), 2);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 2 ether));
        assertEq(token.numCheckpoints(ALICE), 2, "same-second write merges in place");

        Checkpoints.Checkpoint208 memory merged = token.checkpoints(ALICE, 1);
        assertEq(merged._key, 12);
        assertEq(merged._value, 4 ether);

        // Same-second mints exercise the identical equal-key merge on the total-supply trace.
        token.mintTest(BOB, 1 ether);
        token.mintTest(BOB, 2 ether);

        vm.warp(13);
        assertEq(token.getPastVotes(ALICE, 12), 4 ether);
        assertEq(token.getPastTotalSupply(12), 13 ether);
    }

    /// @notice Test CLOCK_MODE returns the exact timestamp mode string without reverting.
    function testClockModeReturnsTimestampMode() external view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    /// @notice Test the base CLOCK_MODE guard rejects a block-number clock override.
    /// @dev The guard lives in the vendored ERC6372Utils helper: a clock that no longer matches the
    ///      timestamp expectation must revert before any mode string is returned. Foundry starts with
    ///      block.number == block.timestamp == 1, where the comparison cannot distinguish the domains, so
    ///      the block number is rolled away from the timestamp to make the mismatch observable.
    function testClockModeRevertsOnBlockNumberClockOverride() external {
        BlockNumberClockVotesHarness blockClock = new BlockNumberClockVotesHarness();

        vm.roll(2);
        vm.expectRevert(ERC6372Utils.ERC6372InconsistentClock.selector);
        blockClock.CLOCK_MODE();
    }

    /// @notice Test mint respects safe supply cap override.
    function testMintRespectsSafeSupplyCapOverride() external {
        CappedVotesHarness cappedImplementation = new CappedVotesHarness();
        CappedVotesHarness capped = CappedVotesHarness(address(cappedImplementation).clone());
        capped.initialize("Cap Token", "CAP");

        capped.mintTest(ALICE, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(OutrunERC20VotesInit.ERC20ExceededSafeSupply.selector, 11 ether, 10 ether)
        );
        capped.mintTest(ALICE, 1 ether);
    }
}
