// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {IMemecoinDaoGovernor} from "../../src/governance/interfaces/IMemecoinDaoGovernor.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {IGovernanceCycleIncentivizer} from "../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";
import {MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";

/// @title GovernanceIncentivizerPairIntegrationTest
/// @notice Real Governor + real Incentivizer proxy pair: register → income → spend treasury ledger fund-flow.
contract GovernanceIncentivizerPairIntegrationTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MemecoinDaoGovernorUpgradeable internal governor;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockGovernorVotesToken internal votesToken;

    /// @notice Set up the real Governor/Incentivizer proxy pair with mutual wiring.
    function setUp() external {
        votesToken = new MockGovernorVotesToken();
        votesToken.setVotes(ALICE, 100 ether);

        // Deploy the incentivizer proxy uninitialized first (its initialize needs the governor address).
        incentivizer = GovernanceCycleIncentivizerUpgradeable(
            address(new UnsafeUninitializedProxy(address(new GovernanceCycleIncentivizerUpgradeable()), bytes("")))
        );

        // Deploy the governor proxy wired to the incentivizer address.
        governor = MemecoinDaoGovernorUpgradeable(
            payable(address(
                    new ERC1967Proxy(
                        address(new MemecoinDaoGovernorUpgradeable()),
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
                    )
                ))
        );

        // Complete the mutual wiring: the incentivizer learns its governor.
        address[] memory initTokens = new address[](0);
        incentivizer.initialize(address(governor), initTokens);
    }

    /// @notice A token registered by a prior proposal can be funded and spent, with the real ledger tracking both.
    function testRegisterThenIncomeThenSpendTracksLedger() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);

        // Proposal 1: register the token through the real incentivizer (standalone execution).
        (address[] memory registerTargets, uint256[] memory registerValues, bytes[] memory registerCalldatas) = _singleCallPayload(
            address(incentivizer),
            abi.encodeCall(GovernanceCycleIncentivizerUpgradeable.registerTreasuryToken, (address(newToken)))
        );
        _proposePassAndExecute(registerTargets, registerValues, registerCalldatas, "register-token");

        // Registered on the real incentivizer; the real incentivizer→governor callback ran during execution.
        assertTrue(incentivizer.isTreasuryToken(1, address(newToken)));

        // Fund: pull tokens into the governor treasury and credit the real ledger.
        newToken.mint(address(this), 1000 ether);
        newToken.approve(address(governor), 1000 ether);
        governor.receiveTreasuryIncome(address(newToken), 1000 ether);

        assertEq(incentivizer.getTreasuryBalance(1, address(newToken)), 1000 ether);
        assertEq(newToken.balanceOf(address(governor)), 1000 ether);

        // Proposal 2: spend 50 within the execution ratio via a governor self-call.
        (address[] memory spendTargets, uint256[] memory spendValues, bytes[] memory spendCalldatas) = _selfCallPayload(
            abi.encodeCall(IMemecoinDaoGovernor.sendTreasuryAssets, (address(newToken), BOB, 50 ether))
        );
        _proposePassAndExecute(spendTargets, spendValues, spendCalldatas, "spend-token");

        // Tokens moved and the real ledger decremented.
        assertEq(newToken.balanceOf(BOB), 50 ether);
        assertEq(newToken.balanceOf(address(governor)), 950 ether);
        assertEq(incentivizer.getTreasuryBalance(1, address(newToken)), 950 ether);

        // The two For votes flowed through the real governor into the real incentivizer cycle accounting.
        assertEq(incentivizer.getUserVotesCount(ALICE, 1), 200 ether);
    }

    /// @notice Spending a token whose ledger was never credited reverts even if the governor holds the tokens.
    function testSpendWithoutRecordedIncomeRevertsInsufficientTreasuryBalance() external {
        MockERC20 newToken = new MockERC20("New Treasury", "NTRY", 18);

        (address[] memory registerTargets, uint256[] memory registerValues, bytes[] memory registerCalldatas) = _singleCallPayload(
            address(incentivizer),
            abi.encodeCall(GovernanceCycleIncentivizerUpgradeable.registerTreasuryToken, (address(newToken)))
        );
        _proposePassAndExecute(registerTargets, registerValues, registerCalldatas, "register-token");

        // Tokens sit with the governor but were never recorded as income on the ledger.
        newToken.mint(address(governor), 1000 ether);

        // The real ledger gate is independent of actual holdings: balance passes, ledger balance 0 fails.
        (address[] memory spendTargets, uint256[] memory spendValues, bytes[] memory spendCalldatas) = _selfCallPayload(
            abi.encodeCall(IMemecoinDaoGovernor.sendTreasuryAssets, (address(newToken), BOB, 50 ether))
        );
        _proposeAndPassForExpectedRevert(spendTargets, spendValues, spendCalldatas, "spend-unfunded");
        vm.expectRevert(IGovernanceCycleIncentivizer.InsufficientTreasuryBalance.selector);
        governor.execute(spendTargets, spendValues, spendCalldatas, keccak256("spend-unfunded"));

        // Nothing moved and the ledger stayed at zero.
        assertEq(newToken.balanceOf(BOB), 0);
        assertEq(newToken.balanceOf(address(governor)), 1000 ether);
        assertEq(incentivizer.getTreasuryBalance(1, address(newToken)), 0);
    }

    function _proposePassAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(ALICE);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _proposeAndPassForExpectedRevert(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(ALICE);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
    }

    function _singleCallPayload(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        calldatas[0] = data;
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
}

/// @title UnsafeUninitializedProxy
/// @notice Test-only ERC1967Proxy that may be deployed without an initializer call. The real Governor and
///         Incentivizer initializers each reference the other's proxy address, so one proxy must be deployed
///         uninitialized first and initialized after the pair is wired.
contract UnsafeUninitializedProxy is ERC1967Proxy {
    /// @param implementation Initial implementation address.
    /// @param data Initializer calldata; may be empty for deferred initialization.
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}

    /// @notice Permit an uninitialized deployment so the paired contract can be wired in a later call.
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
