// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {IMemecoinDaoGovernor} from "../../src/governance/interfaces/IMemecoinDaoGovernor.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";
import {MockGovernorIncentivizer, MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";
import {MemecoinDaoGovernorUpgradeableV2} from "../mocks/upgrade/MemecoinDaoGovernorUpgradeableV2.sol";

contract MemecoinDaoGovernorUpgradeableTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MemecoinDaoGovernorUpgradeable internal implementation;
    MemecoinDaoGovernorUpgradeable internal governor;
    MockGovernorVotesToken internal votesToken;
    MockGovernorIncentivizer internal incentivizer;
    MockERC20 internal treasuryToken;

    /// @notice Set up.
    function setUp() external {
        implementation = new MemecoinDaoGovernorUpgradeable();
        votesToken = new MockGovernorVotesToken();
        incentivizer = new MockGovernorIncentivizer();
        treasuryToken = new MockERC20("Treasury", "TRY", 18);

        votesToken.setVotes(ALICE, 100 ether);
        votesToken.setVotes(BOB, 80 ether);

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                MemecoinDaoGovernorUpgradeable.initialize,
                (
                    "Memecoin DAO",
                    IVotes(address(votesToken)),
                    0,
                    5,
                    1 ether,
                    10,
                    address(incentivizer),
                    0,
                    0,
                    1000,
                    6000
                )
            )
        );
        governor = MemecoinDaoGovernorUpgradeable(payable(address(proxy)));
        incentivizer.setGovernor(address(governor));
    }

    /// @notice Test initialize exposes incentivizer and governor metadata.
    function testInitializeExposesIncentivizerAndGovernorMetadata() external view {
        assertEq(governor.governanceCycleIncentivizer(), address(incentivizer));
        assertEq(governor.name(), "Memecoin DAO");
        assertEq(governor.votingDelay(), 0);
        assertEq(governor.votingPeriod(), 5);
        assertEq(governor.proposalThreshold(), 1 ether);
        assertEq(governor.minQuorum(), 0);
        assertEq(governor.governanceStartTime(), block.timestamp);
        assertEq(governor.maxTreasurySpendRatio(), 1000);
        assertEq(governor.upgradeSupermajorityRatio(), 6000);
    }

    /// @notice Test receive treasury income notifies incentivizer and pulls tokens.
    function testReceiveTreasuryIncomeNotifiesIncentivizerAndPullsTokens() external {
        treasuryToken.mint(address(this), 10 ether);
        treasuryToken.approve(address(governor), type(uint256).max);

        governor.receiveTreasuryIncome(address(treasuryToken), 10 ether);

        assertEq(incentivizer.lastReceiveToken(), address(treasuryToken));
        assertEq(incentivizer.lastReceiveAmount(), 10 ether);
        assertEq(incentivizer.lastReceiveGovernorBalance(), 10 ether);
        assertEq(treasuryToken.balanceOf(address(governor)), 10 ether);
    }

    /// @notice Test propose blocks second unfinalized proposal and allows after defeat.
    function testProposeBlocksSecondUnfinalizedProposalAndAllowsAfterDefeat() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();

        vm.prank(ALICE);
        uint256 firstProposalId = governor.propose(targets, values, calldatas, "proposal-1");

        vm.prank(ALICE);
        vm.expectRevert(IMemecoinDaoGovernor.UserHasUnfinalizedProposal.selector);
        governor.propose(targets, values, calldatas, "proposal-2");

        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint8(governor.state(firstProposalId)), uint8(IGovernor.ProposalState.Defeated));

        vm.prank(ALICE);
        uint256 secondProposalId = governor.propose(targets, values, calldatas, "proposal-3");
        assertTrue(secondProposalId != 0);
    }

    /// @notice Test propose allows new proposal after unfinalized proposal reaches Succeeded state.
    function testProposeAllowsNewProposalAfterSucceededState() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();

        vm.prank(ALICE);
        uint256 firstProposalId = governor.propose(targets, values, calldatas, "proposal-1");

        // Vote and pass the proposal → Succeeded state
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(firstProposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(uint8(governor.state(firstProposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // Proposer should be able to submit a new proposal while the first is still Succeeded
        vm.prank(ALICE);
        uint256 secondProposalId = governor.propose(targets, values, calldatas, "proposal-2");
        assertTrue(secondProposalId != firstProposalId, "new proposal id differs");
    }

    /// @notice Test cast vote accumulates cycle votes on incentivizer.
    function testCastVoteAccumulatesCycleVotesOnIncentivizer() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();

        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, "vote-proposal");

        vm.roll(block.number + 1);
        vm.prank(BOB);
        governor.castVote(proposalId, 1);

        assertEq(incentivizer.lastVoteAccount(), BOB);
        assertEq(incentivizer.lastVoteAmount(), 80 ether);
    }

    /// @notice Test send treasury assets requires governance executor and transfers tokens.
    function testSendTreasuryAssetsRequiresGovernanceExecutorAndTransfersTokens() external {
        treasuryToken.mint(address(governor), 10 ether);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.sendTreasuryAssets(address(treasuryToken), BOB, 3 ether);

        vm.prank(address(governor));
        governor.sendTreasuryAssets(address(treasuryToken), BOB, 3 ether);

        assertEq(incentivizer.lastSentToken(), address(treasuryToken));
        assertEq(incentivizer.lastSentTo(), BOB);
        assertEq(incentivizer.lastSentAmount(), 3 ether);
        assertEq(incentivizer.lastSentGovernorBalance(), 10 ether);
        assertEq(treasuryToken.balanceOf(BOB), 3 ether);
    }

    /// @notice Test disburse reward is restricted to incentivizer and pays from governor custody.
    function testDisburseRewardOnlyIncentivizerAndTransfersTokens() external {
        treasuryToken.mint(address(governor), 10 ether);

        vm.expectRevert(IMemecoinDaoGovernor.UnauthorizedRewardPayout.selector);
        governor.disburseReward(address(treasuryToken), BOB, 4 ether);

        vm.prank(address(incentivizer));
        governor.disburseReward(address(treasuryToken), BOB, 4 ether);

        assertEq(treasuryToken.balanceOf(BOB), 4 ether);
        assertEq(treasuryToken.balanceOf(address(governor)), 6 ether);
    }

    /// @notice Test UUPS upgrade requires governance executor and upgrades the proxy implementation.
    function testUpgradeToAndCallRequiresGovernanceExecutorAndUpgradesProxy() external {
        MemecoinDaoGovernorUpgradeableV2 newImplementation = new MemecoinDaoGovernorUpgradeableV2();

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.upgradeToAndCall(address(newImplementation), bytes(""));

        // V2 shell does not inherit the governor, so the incentivizer pointer is read directly from its
        // erc7201 storage slot (MemecoinDaoGovernorStorage._governanceCycleIncentivizer, offset 0).
        bytes32 incentivizerSlot = bytes32(uint256(0x268497fe5dd9452fe73d6476bb0f21165f748dafac6b1c2687b0261939d22c00));
        bytes32 incentivizerBefore = vm.load(address(governor), incentivizerSlot);

        vm.prank(address(governor));
        governor.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(MemecoinDaoGovernorUpgradeableV2(payable(address(governor))).upgradeVersion(), 2);
        // Storage must survive the upgrade: same slot, same value.
        assertEq(vm.load(address(governor), incentivizerSlot), incentivizerBefore);
        // Address is right-aligned (low 160 bits) in the slot.
        assertEq(address(uint160(uint256(incentivizerBefore))), address(incentivizer));
    }

    /// @notice Test propose reverts during bootstrap period.
    function testProposeRevertsDuringBootstrapPeriod() external {
        ERC1967Proxy bootstrapProxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                MemecoinDaoGovernorUpgradeable.initialize,
                (
                    "Bootstrap DAO",
                    IVotes(address(votesToken)),
                    0,
                    5,
                    1 ether,
                    10,
                    address(incentivizer),
                    50 ether,
                    7 days,
                    1000,
                    6000
                )
            )
        );
        MemecoinDaoGovernorUpgradeable bootstrapGovernor =
            MemecoinDaoGovernorUpgradeable(payable(address(bootstrapProxy)));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();

        vm.prank(ALICE);
        vm.expectRevert(IMemecoinDaoGovernor.GovernanceNotStarted.selector);
        bootstrapGovernor.propose(targets, values, calldatas, "too-early");

        // Warp past the bootstrap period — propose should succeed.
        vm.warp(block.timestamp + 7 days);
        vm.prank(ALICE);
        uint256 proposalId = bootstrapGovernor.propose(targets, values, calldatas, "on-time");
        assertTrue(proposalId != 0);
    }

    /// @notice Test quorum returns the maximum of staked quorum and minQuorum floor.
    function testQuorumReturnsMaxOfStakedQuorumAndMinQuorumFloor() external view {
        // Mock token getPastTotalSupply returns 1000 ether, quorumNumerator = 10 → staked quorum = 100 ether
        // minQuorum = 0 (from setUp) → staked quorum is larger
        assertEq(governor.quorum(block.number), 100 ether);
    }

    /// @notice Test quorum floor takes effect when staked quorum is low.
    function testQuorumFloorTakesEffectWhenStakedQuorumIsLow() external {
        // Deploy with minQuorum = 50 ether and quorumNumerator = 1
        // staked quorum = 1000 ether * 1 / 100 = 10 ether → floor wins
        ERC1967Proxy floorProxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                MemecoinDaoGovernorUpgradeable.initialize,
                (
                    "Floor DAO",
                    IVotes(address(votesToken)),
                    0,
                    5,
                    1 ether,
                    1,
                    address(incentivizer),
                    50 ether,
                    0,
                    1000,
                    6000
                )
            )
        );
        MemecoinDaoGovernorUpgradeable floorGovernor = MemecoinDaoGovernorUpgradeable(payable(address(floorProxy)));

        assertEq(floorGovernor.quorum(block.number), 50 ether);
    }

    function _proposalPayload()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(0x1234);
        values[0] = 0;
        calldatas[0] = bytes("");
    }

    function _proposePassAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address voter
    ) internal returns (uint256 proposalId) {
        vm.prank(voter);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _proposeAndPassForExpectedRevert(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address voter
    ) internal {
        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
    }

    function _transferPayload(address token, address to, uint256 amount)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = token;
        values[0] = 0;
        calldatas[0] = abi.encodeCall(IERC20.transfer, (to, amount));
    }

    function _selfCallPayload(bytes memory data)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = data;
    }

    function testTreasurySpendWithinLimitSucceeds() external {
        treasuryToken.mint(address(governor), 1000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(treasuryToken);
        incentivizer.setTreasuryTokens(tokens);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _transferPayload(address(treasuryToken), BOB, 50 ether);

        _proposePassAndExecute(targets, values, calldatas, "spend-within-limit", ALICE);

        assertEq(treasuryToken.balanceOf(BOB), 50 ether);
        assertEq(treasuryToken.balanceOf(address(governor)), 950 ether);
    }

    /// @notice Treasury-token registration cannot share an execution with a treasury spend.
    function testTreasuryTokenRegistrationMustBeStandaloneBeforeTreasurySpend() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);
        newToken.mint(address(governor), 100 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(incentivizer);
        calldatas[0] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(newToken)));
        targets[1] = address(governor);
        calldatas[1] = abi.encodeCall(IMemecoinDaoGovernor.sendTreasuryAssets, (address(newToken), BOB, 10 ether));

        _proposeAndPassForExpectedRevert(targets, values, calldatas, "register-and-spend", ALICE);

        vm.expectRevert(IMemecoinDaoGovernor.RegistrationMustBeStandalone.selector);
        governor.execute(targets, values, calldatas, keccak256("register-and-spend"));

        (,,, address[] memory treasuryTokens,) = incentivizer.metaData();
        assertEq(treasuryTokens.length, 0);
        assertEq(newToken.balanceOf(address(governor)), 100 ether);
        assertEq(newToken.balanceOf(address(incentivizer)), 0);
        assertEq(newToken.balanceOf(BOB), 0);
        assertEq(incentivizer.lastSentToken(), address(0));
        assertEq(incentivizer.lastSentTo(), address(0));
        assertEq(incentivizer.lastSentAmount(), 0);
    }

    /// @notice Treasury-token registration cannot share an execution with a direct transfer.
    function testTreasuryTokenRegistrationMustBeStandaloneBeforeDirectTransfer() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);
        newToken.mint(address(governor), 100 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(incentivizer);
        calldatas[0] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(newToken)));
        targets[1] = address(newToken);
        calldatas[1] = abi.encodeCall(IERC20.transfer, (BOB, 10 ether));

        _proposeAndPassForExpectedRevert(targets, values, calldatas, "register-and-direct-transfer", ALICE);

        vm.expectRevert(IMemecoinDaoGovernor.RegistrationMustBeStandalone.selector);
        governor.execute(targets, values, calldatas, keccak256("register-and-direct-transfer"));

        (,,, address[] memory treasuryTokens,) = incentivizer.metaData();
        assertEq(treasuryTokens.length, 0);
        assertEq(newToken.balanceOf(address(governor)), 100 ether);
        assertEq(newToken.balanceOf(BOB), 0);

        address[] memory registerTargets = new address[](1);
        uint256[] memory registerValues = new uint256[](1);
        bytes[] memory registerCalldatas = new bytes[](1);
        registerTargets[0] = address(incentivizer);
        registerCalldatas[0] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(newToken)));
        _proposePassAndExecute(registerTargets, registerValues, registerCalldatas, "register-after-revert", ALICE);

        (,,, address[] memory registeredTreasuryTokens,) = incentivizer.metaData();
        assertEq(registeredTreasuryTokens.length, 1);
        assertEq(registeredTreasuryTokens[0], address(newToken));
    }

    /// @notice A direct transfer before registration is also rejected and fully rolled back.
    function testDirectTransferBeforeTreasuryTokenRegistrationReverts() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);
        newToken.mint(address(governor), 100 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(newToken);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (BOB, 10 ether));
        targets[1] = address(incentivizer);
        calldatas[1] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(newToken)));

        _proposeAndPassForExpectedRevert(targets, values, calldatas, "direct-transfer-and-register", ALICE);

        vm.expectRevert(IMemecoinDaoGovernor.RegistrationMustBeStandalone.selector);
        governor.execute(targets, values, calldatas, keccak256("direct-transfer-and-register"));

        (,,, address[] memory treasuryTokens,) = incentivizer.metaData();
        assertEq(treasuryTokens.length, 0);
        assertEq(newToken.balanceOf(address(governor)), 100 ether);
        assertEq(newToken.balanceOf(address(incentivizer)), 0);
        assertEq(newToken.balanceOf(BOB), 0);
    }

    /// @notice A token registered by a prior proposal can be spent within the Governor execution ratio.
    function testTreasuryTokenRegisteredInPriorProposalCanBeSpentWithinExecutionRatio() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);

        address[] memory registerTargets = new address[](1);
        uint256[] memory registerValues = new uint256[](1);
        bytes[] memory registerCalldatas = new bytes[](1);
        registerTargets[0] = address(incentivizer);
        registerCalldatas[0] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(newToken)));
        _proposePassAndExecute(registerTargets, registerValues, registerCalldatas, "register-token", ALICE);

        // This mock path isolates Governor's balance-ratio check; it does not prove Incentivizer ledger accounting.
        newToken.mint(address(governor), 1000 ether);
        (address[] memory spendTargets, uint256[] memory spendValues, bytes[] memory spendCalldatas) = _selfCallPayload(
            abi.encodeCall(IMemecoinDaoGovernor.sendTreasuryAssets, (address(newToken), BOB, 50 ether))
        );
        _proposePassAndExecute(spendTargets, spendValues, spendCalldatas, "spend-token", ALICE);

        assertEq(newToken.balanceOf(BOB), 50 ether);
        assertEq(newToken.balanceOf(address(governor)), 950 ether);
    }

    /// @notice A Governor self-call cannot invoke a nested Governor execution.
    function testNestedGovernorExecuteReverts() external {
        MockERC20 nestedToken = new MockERC20("Nested Treasury", "NTRY", 18);
        nestedToken.mint(address(governor), 100 ether);

        address[] memory innerTargets = new address[](1);
        uint256[] memory innerValues = new uint256[](1);
        bytes[] memory innerCalldatas = new bytes[](1);
        innerTargets[0] = address(incentivizer);
        innerCalldatas[0] = abi.encodeCall(MockGovernorIncentivizer.registerTreasuryToken, (address(nestedToken)));
        string memory innerDescription = "nested-register";

        vm.prank(ALICE);
        uint256 innerProposalId = governor.propose(innerTargets, innerValues, innerCalldatas, innerDescription);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(ALICE);
        governor.castVote(innerProposalId, 1);
        vm.roll(vm.getBlockNumber() + governor.votingPeriod() + 1);

        address[] memory outerTargets = new address[](1);
        uint256[] memory outerValues = new uint256[](1);
        bytes[] memory outerCalldatas = new bytes[](1);
        outerTargets[0] = address(governor);
        outerCalldatas[0] = abi.encodeCall(
            MemecoinDaoGovernorUpgradeable.execute,
            (innerTargets, innerValues, innerCalldatas, keccak256(bytes(innerDescription)))
        );
        string memory outerDescription = "nested-execution";

        vm.prank(ALICE);
        uint256 outerProposalId = governor.propose(outerTargets, outerValues, outerCalldatas, outerDescription);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(ALICE);
        governor.castVote(outerProposalId, 1);
        vm.roll(vm.getBlockNumber() + governor.votingPeriod() + 1);

        vm.expectRevert(IMemecoinDaoGovernor.NestedExecution.selector);
        governor.execute(outerTargets, outerValues, outerCalldatas, keccak256(bytes(outerDescription)));

        (,,, address[] memory treasuryTokens,) = incentivizer.metaData();
        assertEq(treasuryTokens.length, 0);
        assertEq(nestedToken.balanceOf(address(governor)), 100 ether);
        assertEq(nestedToken.balanceOf(address(incentivizer)), 0);
    }

    function testTreasurySpendExceedingLimitReverts() external {
        treasuryToken.mint(address(governor), 1000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(treasuryToken);
        incentivizer.setTreasuryTokens(tokens);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _transferPayload(address(treasuryToken), BOB, 200 ether);

        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, "spend-over-limit");

        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.TreasurySpendExceedsLimit.selector, address(treasuryToken), 200 ether, 100 ether
            )
        );
        governor.execute(targets, values, calldatas, keccak256("spend-over-limit"));
    }

    function testUpgradeWithoutSupermajorityReverts() external {
        // ALICE has 100 votes, BOB has 80 votes — total 180
        // 60% of 180 = 108. ALICE votes For = 100 < 108 → should revert
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _selfCallPayload("");

        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, "upgrade-no-super");

        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1); // For
        vm.prank(BOB);
        governor.castVote(proposalId, 0); // Against

        vm.roll(block.number + governor.votingPeriod() + 1);
        // forVotes=100, totalVotes=180, required=100*10000 >= 180*6000 → 1000000 < 1080000
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UpgradeSupermajorityRequired.selector, 100 ether, 180 ether, 6000
            )
        );
        governor.execute(targets, values, calldatas, keccak256("upgrade-no-super"));
    }

    function testUpgradeWithSupermajoritySucceeds() external {
        // Set ALICE votes = 700, BOB = 300 → total 1000
        // 60% of 1000 = 600. ALICE + BOB both vote For = 1000 >= 600 → should pass
        votesToken.setVotes(ALICE, 700 ether);
        votesToken.setVotes(BOB, 300 ether);

        // Use IGovernor.name() as valid self-call payload — view function succeeds via .call()
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _selfCallPayload(abi.encodeCall(IGovernor.name, ()));

        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, "upgrade-super");

        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);
        vm.prank(BOB);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.execute(targets, values, calldatas, keccak256("upgrade-super"));
    }

    function testNonSelfCallIgnoresSupermajority() external {
        // Simple majority (>50% forVotes) is enough for non-self-call proposals
        // Use treasuryToken.balanceOf as a valid non-self-call target
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(treasuryToken);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(IERC20.balanceOf, (address(governor)));

        _proposePassAndExecute(targets, values, calldatas, "non-self-call", ALICE);
    }

    function testZeroPreBalanceSkipsRateLimit() external {
        // Treasury token has 0 balance before execution — no spend to limit
        address[] memory tokens = new address[](1);
        tokens[0] = address(treasuryToken);
        incentivizer.setTreasuryTokens(tokens);

        // Use treasuryToken.balanceOf as valid non-self-call target (doesn't change balances)
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(treasuryToken);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(IERC20.balanceOf, (address(governor)));

        _proposePassAndExecute(targets, values, calldatas, "zero-balance", ALICE);
    }

    /// @notice Test multi-token rate limit reports the correct token on violation.
    function testMultiTokenRateLimitReportsCorrectToken() external {
        MockERC20 tokenA = treasuryToken;
        MockERC20 tokenB = new MockERC20("TokenB", "B", 18);
        tokenA.mint(address(governor), 1000 ether);
        tokenB.mint(address(governor), 500 ether);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        incentivizer.setTreasuryTokens(tokens);

        // tokenA: transfer 50 (5% <= 10% ok), tokenB: transfer 100 (20% > 10% revert)
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(tokenA);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(IERC20.transfer, (BOB, 50 ether));
        targets[1] = address(tokenB);
        values[1] = 0;
        calldatas[1] = abi.encodeCall(IERC20.transfer, (BOB, 100 ether));

        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, "multi-token");

        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);
        // limit for tokenB = 500 * 1000/10000 = 50, spent = 100
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.TreasurySpendExceedsLimit.selector, address(tokenB), 100 ether, 50 ether
            )
        );
        governor.execute(targets, values, calldatas, keccak256("multi-token"));
    }
}

/// @notice End-to-end integration: the real MemecoinYieldVault drives the real Governor.
/// @dev The standalone governor tests above use a mock votes token, so they never exercise the vault's
///      asset-denomination conversion through propose/quorum. This contract wires the production
///      governance token (a yield vault clone) into the production governor and proves that, after
///      yield, a staker whose raw shares are below the threshold can still propose and reach quorum.
contract VaultGovernorIntegrationTest is Test {
    address internal constant ATTACKER = address(0xA11CE);
    // Matches VIRTUAL_ASSETS in test/yield/MemecoinYieldVault.t.sol so asset-denominated vote
    // assertions stay comparable across the two suites.
    uint256 internal constant VIRTUAL_ASSETS = 100 ether;

    MemecoinDaoGovernorUpgradeable internal governor;
    MemecoinYieldVault internal vault;
    MockERC20 internal asset;
    MockGovernorIncentivizer internal incentivizer;

    function setUp() external {
        // Real governance token: a clone of MemecoinYieldVault (timestamp-based ERC-6372 clock).
        asset = new MockERC20("Memecoin", "MEME", 18);
        MemecoinYieldVault vaultImpl = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(vaultImpl)));
        vault.initialize("Staked MEME", "sMEME", ATTACKER, address(asset), 1, VIRTUAL_ASSETS);

        asset.mint(ATTACKER, 1_000 ether);
        vm.prank(ATTACKER);
        asset.approve(address(vault), type(uint256).max);

        // Real governor wired with the vault as its IVotes token.
        MemecoinDaoGovernorUpgradeable govImpl = new MemecoinDaoGovernorUpgradeable();
        incentivizer = new MockGovernorIncentivizer();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(
                MemecoinDaoGovernorUpgradeable.initialize,
                (
                    "MEME DAO",
                    IVotes(address(vault)),
                    uint48(100), // votingDelay in seconds — governor adopts the vault's timestamp clock
                    uint32(100), // votingPeriod in seconds
                    100 ether, // proposalThreshold
                    10, // quorumNumerator (10 bp = 0.1%)
                    address(incentivizer),
                    uint256(0), // minQuorum
                    uint256(0), // bootstrapPeriod
                    uint256(1000), // maxTreasurySpendRatio
                    uint256(6000) // upgradeSupermajorityRatio
                )
            )
        );
        governor = MemecoinDaoGovernorUpgradeable(payable(address(proxy)));
    }

    /// @notice A sub-threshold staker can propose and reach quorum after yield lifts votes over the threshold.
    /// @dev 60 raw shares are below the 100-ether threshold; under V=100, yielding 60 only lifts
    ///      asset-denominated votes to 82.5 (60 * (120+100)/(60+100)), still below 100. So yield 200 lifts
    ///      votes to 60 * (260+100)/(60+100) = 135 via the vault's IVotes views, which the governor reads at
    ///      clock()-1. Pre-fix, votes stayed at raw 60 and propose reverted GovernorInsufficientProposerVotes.
    function testProposeAndQuorumSucceedAfterYieldLiftsVotes() external {
        vm.warp(1000);
        vm.prank(ATTACKER);
        vault.deposit(60 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        vm.warp(2000);
        vm.prank(ATTACKER);
        vault.accumulateYields(200 ether);

        // Propose at t=3000: governor checks getVotes(ATTACKER, clock()-1 = 2999), which reads the
        // post-yield totalAssets checkpoint and prices 60 shares to 135 asset-votes (over 100).
        vm.warp(3000);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payload();
        vm.prank(ATTACKER);
        uint256 proposalId = governor.propose(targets, values, calldatas, "post-yield");
        assertTrue(proposalId != 0, "propose succeeded once yield crossed threshold");

        // Full lifecycle: vote reaches quorum and the proposal Succeeds.
        vm.warp(3101); // past proposalSnapshot (clock@propose + votingDelay = 3000 + 100)
        vm.prank(ATTACKER);
        governor.castVote(proposalId, 1); // For

        vm.warp(3201); // past proposalDeadline (3100 + votingPeriod 100)
        assertEq(
            uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "quorum reached after yield"
        );
    }

    /// @notice Without yield, votes stay below threshold and propose reverts.
    /// @dev Negative control: 60 shares price to 60 asset-votes at the 1:1 rate, below the 100 threshold.
    function testProposeRevertsWhenVotesBelowThreshold() external {
        vm.warp(1000);
        vm.prank(ATTACKER);
        vault.deposit(60 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        vm.warp(1001); // clock()-1 = 1000 reads the deposit checkpoint (60 asset-votes)
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payload();
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, ATTACKER, 60 ether, 100 ether)
        );
        governor.propose(targets, values, calldatas, "below-threshold");
    }

    function _payload()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(0x1234);
        values[0] = 0;
        calldatas[0] = bytes("");
    }
}
