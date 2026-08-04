// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {MockGovernorIncentivizer, MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";

contract MemecoinDaoGovernorCancelTest is Test {
    address internal constant ALICE = address(0xA11CE);

    MemecoinDaoGovernorUpgradeable internal implementation;
    MemecoinDaoGovernorUpgradeable internal governor;
    MockGovernorVotesToken internal votesToken;
    MockGovernorIncentivizer internal incentivizer;

    function setUp() external {
        implementation = new MemecoinDaoGovernorUpgradeable();
        votesToken = new MockGovernorVotesToken();
        incentivizer = new MockGovernorIncentivizer();
        votesToken.setVotes(ALICE, 100 ether);

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
    }

    /// @notice Cancelling a pending proposal clears the proposer marker and allows a replacement.
    function testCancelClearsProposerOutstandingAndAllowsReplacement() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();
        bytes32 cancelledDescriptionHash = keccak256("cancelled-proposal");

        vm.prank(ALICE);
        uint256 cancelledProposalId = governor.propose(targets, values, calldatas, "cancelled-proposal");

        vm.prank(ALICE);
        uint256 returnedProposalId = governor.cancel(targets, values, calldatas, cancelledDescriptionHash);

        assertEq(returnedProposalId, cancelledProposalId);
        assertEq(uint8(governor.state(cancelledProposalId)), uint8(IGovernor.ProposalState.Canceled));

        vm.prank(ALICE);
        uint256 replacementProposalId = governor.propose(targets, values, calldatas, "replacement-proposal");
        assertTrue(replacementProposalId != cancelledProposalId);
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
    }
}
