// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {IMemecoinDaoGovernor} from "../../src/governance/interfaces/IMemecoinDaoGovernor.sol";
import {MemeverseERC1967Proxy} from "../../src/verse/deployment/MemeverseProxyDeployer.sol";
import {MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";

/// @title MaliciousIncentivizer
/// @notice Exploit payload installed as the incentivizer proxy's new implementation. It is UUPS-compatible (inherits
///         the proxiable UUID) so OZ `_upgradeTo` accepts it, then drains the governor treasury via `disburseReward`.
/// @dev Once live behind the incentivizer proxy, `address(this)` is the proxy, so a call to
///      `governor.disburseReward` satisfies the governor's `msg.sender == incentivizer` check directly.
contract MaliciousIncentivizer is UUPSUpgradeable {
    /// @notice Drains the governor's full custody of `token` to `to`.
    /// @param governor The paired governor (asset custodian).
    /// @param token Any token the governor custody (registered or not).
    /// @param to Recipient of the drained funds.
    function drain(address governor, address token, address to) external {
        uint256 balance = IERC20(token).balanceOf(governor);
        IMemecoinDaoGovernor(governor).disburseReward(token, to, balance);
    }

    /// @dev No-op: once the malicious impl is live, the attacker already controls it.
    function _authorizeUpgrade(address) internal override {}
}

/// @title IncentivizerUpgradeTreasuryDrainTest
/// @notice Fix coverage. Pre-fix, a simple-majority coalition upgraded the incentivizer (target != governor),
///         bypassing both the upgrade supermajority (only gated self-calls) and the per-execution treasury
///         cap (only ran inside `_executeOperations` over registered tokens); the swapped impl then called
///         `governor.disburseReward` out-of-band, draining ANY token in full. Root A extends the supermajority gate to
///         incentivizer targets, closing the vector. A residual risk remains: a coalition meeting the supermajority can
///         still upgrade to a malicious impl that drains custody via `disburseReward`; this is documented (not fixed)
///         by `test_ResidualRisk_MaliciousSupermajorityStillDrainsViaDisburseReward`.
contract IncentivizerUpgradeTreasuryDrainTest is Test {
    address internal constant ALICE = address(0xA11CE); // simple-majority coalition (51% of cast votes)
    address internal constant BOB = address(0xB0B); // minority against (49%) in simple-majority scenarios
    address internal constant ATTACKER = address(0xBAAD); // attacker EOA that triggers the drain

    MemecoinDaoGovernorUpgradeable internal governor;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockGovernorVotesToken internal votesToken;
    MockERC20 internal treasuryToken; // registered treasury token (the kind the cap is meant to protect)
    MockERC20 internal donationToken; // unregistered token custodied by the governor (donation / airdrop)

    function setUp() external {
        // A 51%/49% split: a bare simple-majority coalition that FAILS the 60% upgrade supermajority.
        votesToken = new MockGovernorVotesToken();
        votesToken.setVotes(ALICE, 510 ether);
        votesToken.setVotes(BOB, 490 ether);

        treasuryToken = new MockERC20("Treasury", "TRY", 18);
        donationToken = new MockERC20("Donation", "DON", 18);

        // Production wiring: deploy both UUPS proxies uninitialized, then initialize each with the other's address
        // (governor needs incentivizer, incentivizer needs governor — circular, solved by MemeverseERC1967Proxy).
        MemecoinDaoGovernorUpgradeable govImpl = new MemecoinDaoGovernorUpgradeable();
        GovernanceCycleIncentivizerUpgradeable incImpl = new GovernanceCycleIncentivizerUpgradeable();
        ERC1967Proxy govProxy = new MemeverseERC1967Proxy(address(govImpl));
        ERC1967Proxy incProxy = new MemeverseERC1967Proxy(address(incImpl));

        governor = MemecoinDaoGovernorUpgradeable(payable(address(govProxy)));
        incentivizer = GovernanceCycleIncentivizerUpgradeable(payable(address(incProxy)));

        governor.initialize(
            "MEME DAO",
            IVotes(address(votesToken)),
            uint48(0), // votingDelay
            uint32(5), // votingPeriod
            1 ether, // proposalThreshold
            10, // quorumNumerator (quorum = 1000 * 10 / 100 = 100 ether; ALICE's 510 ether meets it)
            address(incentivizer),
            0, // minQuorum
            0, // bootstrapPeriod
            1000, // maxTreasurySpendRatio = 10% per execution
            6000 // upgradeSupermajorityRatio = 60%
        );
        address[] memory noInitTokens = new address[](0);
        incentivizer.initialize(address(governor), noInitTokens);

        vm.label(address(governor), "Governor");
        vm.label(address(incentivizer), "Incentivizer");
        vm.label(ALICE, "Alice(51%-coalition)");
        vm.label(BOB, "Bob(49%-against)");
        vm.label(ATTACKER, "Attacker");
    }

    /// @notice Propose (as `proposer`), advance past snapshot, cast For + Against, advance past deadline.
    function _proposeVoteAdvance(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(ALICE);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1); // For
        vm.prank(BOB);
        governor.castVote(proposalId, 0); // Against
        vm.warp(block.timestamp + governor.votingPeriod() + 1);
    }

    /// @notice Propose (as ALICE), advance past snapshot, cast unanimous For votes, advance past deadline.
    /// @dev Unanimous For (ALICE 510 + BOB 490 = 1000 of 1000) clears the 60% upgrade supermajority, used for
    ///      operations that now require it because they target the incentivizer (registration, upgrade).
    function _proposeVoteAdvanceSupermajority(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(ALICE);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1); // For
        vm.prank(BOB);
        governor.castVote(proposalId, 1); // For (unanimous -> meets 60% supermajority)
        vm.warp(block.timestamp + governor.votingPeriod() + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // ROOT A — incentivizer-target upgrades now require the supermajority (gate previously only
    // matched governor self-calls).
    // ---------------------------------------------------------------------------------------------

    /// @dev Root A fix: a 51% coalition upgrading the INCENTIVIZER (target != governor) used to bypass the
    ///      supermajority because the gate only matched governor self-calls. After the fix, an incentivizer target
    ///      also triggers the supermajority, so this same 51% vote reverts on execution:
    ///      forVotes(510)*10000 = 5,100,000 < totalVotes(1000)*6000 = 6,000,000.
    function test_Negative_IncentivizerUpgradeRequiresSupermajority() external {
        MaliciousIncentivizer malicious = new MaliciousIncentivizer();

        // Target = incentivizer (NOT governor). Pre-fix this was a non-self-call that passed on simple majority.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(incentivizer);
        // OZ v5.5 UUPS exposes only upgradeToAndCall(address,bytes) (UPGRADE_INTERFACE_VERSION="5.0.0"); the classic
        // upgradeTo(address) does not exist. Empty data = no extra call, just the impl swap.
        calldatas[0] =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(malicious), bytes(""));
        _proposeVoteAdvance(targets, values, calldatas, "upgrade-incentivizer");

        // 51% For / 49% Against clears simple-majority, but execution now hits the supermajority gate because the
        // incentivizer is a protected target.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UpgradeSupermajorityRequired.selector, 510 ether, 1000 ether, 6000
            )
        );
        governor.execute(targets, values, calldatas, keccak256("upgrade-incentivizer"));
    }

    /// @dev The fix only raises the threshold for incentivizer upgrades; it does not block them. A coalition meeting
    ///      the 60% supermajority (here unanimous: ALICE + BOB both For) can still swap the incentivizer implementation.
    function test_Positive_SupermajorityCanUpgradeIncentivizer() external {
        MaliciousIncentivizer malicious = new MaliciousIncentivizer();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(incentivizer);
        calldatas[0] =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(malicious), bytes(""));
        uint256 proposalId =
            _proposeVoteAdvanceSupermajority(targets, values, calldatas, "upgrade-incentivizer-supermajority");

        // Unanimous vote clears the 60% supermajority gate; execution succeeds and the proposal is marked Executed.
        governor.execute(targets, values, calldatas, keccak256("upgrade-incentivizer-supermajority"));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // ---------------------------------------------------------------------------------------------
    // CONTROL — the SAME 51% coalition targeting the GOVERNOR (self-call) is correctly blocked by the
    // supermajority. Proves the original gate still works; Root A extends its reach to the incentivizer target.
    // ---------------------------------------------------------------------------------------------

    /// @dev Identical 51% For / 49% Against vote, but target = governor (self-call). The supermajority check fires
    ///      and reverts: forVotes(510)*10000 = 5,100,000 < totalVotes(1000)*6000 = 6,000,000.
    function test_Negative_GovernorSelfCallUpgradeRequiresSupermajority() external {
        MemecoinDaoGovernorUpgradeable dummyGovImpl = new MemecoinDaoGovernorUpgradeable();

        // Self-call: target = governor itself, calldata upgrades the governor's own implementation.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(governor);
        calldatas[0] = abi.encodeWithSelector(
            bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(dummyGovImpl), bytes("")
        );

        _proposeVoteAdvance(targets, values, calldatas, "upgrade-governor-selfcall");

        // Same simple-majority vote that would pass a non-protected target here FAILS the supermajority.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UpgradeSupermajorityRequired.selector, 510 ether, 1000 ether, 6000
            )
        );
        governor.execute(targets, values, calldatas, keccak256("upgrade-governor-selfcall"));
    }

    // ---------------------------------------------------------------------------------------------
    // RESIDUAL RISK — Root A closes the simple-majority vector by extending the upgrade supermajority to
    // incentivizer targets. It does NOT, and cannot, defend against a coalition that already meets that supermajority:
    // such a coalition may upgrade the incentivizer to a malicious impl that drains governor custody via
    // `disburseReward` out-of-band. This is an ACCEPTED residual risk (a supermajority coalition is trusted with
    // treasury-changing power), NOT a bug. The test below documents the boundary so future readers do not assume the
    // path is fully defended, and MUST NOT be "fixed" by re-adding a reward-token gate on `disburseReward` (that gate
    // regressed `claimReward` via snapshot/registry drift and is bypassable by a malicious impl forging `metaData()`).
    // ---------------------------------------------------------------------------------------------

    /// @dev RESIDUAL RISK: after Root A, a coalition that clears the 60% supermajority (here
    ///      unanimous: ALICE + BOB both For, 1000/1000 >= 60%) can still swap the incentivizer impl to
    ///      `MaliciousIncentivizer`. The malicious impl then calls `governor.disburseReward` with
    ///      `msg.sender == incentivizer proxy`, passing the governor's only-sender check, and drains ANY token in
    ///      governor custody (registered or not) in full. Root A raised the bar from simple majority to supermajority;
    ///      it cannot defend against the supermajority itself, and `disburseReward` intentionally has no token gate.
    ///      This is accepted because a supermajority coalition already controls every treasury-changing proposal.
    function test_ResidualRisk_MaliciousSupermajorityStillDrainsViaDisburseReward() external {
        MaliciousIncentivizer malicious = new MaliciousIncentivizer();

        // Unregistered token in governor custody (e.g. a donation / airdrop). Root A does not protect it once a
        // supermajority coalition controls the incentivizer implementation.
        uint256 donationAmount = 500 ether;
        donationToken.mint(address(governor), donationAmount);

        // Supermajority coalition upgrades the incentivizer impl to the malicious payload. Root A's gate accepts this
        // because the 60% supermajority IS met (unanimous For).
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(incentivizer);
        calldatas[0] =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(malicious), bytes(""));
        _proposeVoteAdvanceSupermajority(targets, values, calldatas, "upgrade-incentivizer-malicious");
        governor.execute(targets, values, calldatas, keccak256("upgrade-incentivizer-malicious"));

        // Malicious impl is now live behind the incentivizer proxy. ATTACKER triggers the drain; inside `drain` the
        // caller is the incentivizer proxy, so `governor.disburseReward` sees `msg.sender == incentivizer` and pays out.
        vm.prank(ATTACKER);
        MaliciousIncentivizer(address(incentivizer)).drain(address(governor), address(donationToken), ATTACKER);

        // Residual risk realized: the full custody of an unregistered token left to the attacker. This is the accepted
        // boundary after Root A; do NOT re-add a reward-token gate on `disburseReward` to "fix" this assertion.
        assertEq(
            donationToken.balanceOf(ATTACKER), donationAmount, "RESIDUAL RISK: malicious supermajority drains custody"
        );
        assertEq(donationToken.balanceOf(address(governor)), 0, "governor custody fully drained");
    }
}
