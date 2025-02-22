// SPDX-License-Identifier: GPL-3.0
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import { GovernorVotesUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import { GovernorStorageUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorStorageUpgradeable.sol";
import { GovernorSettingsUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import { GovernorCountingFractionalUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingFractionalUpgradeable.sol";
import { GovernorVotesQuorumFractionUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";

import { IVotes, IMemecoinDaoGovernor } from "./interfaces/IMemecoinDaoGovernor.sol";

/** 
 * @title Memecoin DAO Governor
 * @notice This contract is a modified version of the GovernorUpgradeable contract from OpenZeppelin.   
 * @dev It is used to manage the DAO of the Memecoin project, also as Memecoin DAO Treasury.
 */
contract MemecoinDaoGovernor is 
    IMemecoinDaoGovernor, 
    Initializable, 
    GovernorUpgradeable, 
    GovernorSettingsUpgradeable, 
    GovernorCountingFractionalUpgradeable, 
    GovernorStorageUpgradeable, 
    GovernorVotesUpgradeable, 
    GovernorVotesQuorumFractionUpgradeable,
    UUPSUpgradeable 
{
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the governor.
     * @param _name - The name of the governor.
     * @param _token - The vote token of the governor.
     * @param _votingDelay - The voting delay.
     * @param _votingPeriod - The voting period.
     * @param _proposalThreshold - The proposal threshold.
     * @param _quorumNumerator - The quorum numerator.
     */
    function initialize(
        string memory _name, 
        IVotes _token,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) initializer override external {
        __Governor_init(_name);
        __GovernorSettings_init(
            _votingDelay,
            _votingPeriod,
            _proposalThreshold
        );
        __GovernorCountingFractional_init();
        __GovernorStorage_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(_quorumNumerator);
        __UUPSUpgradeable_init();
    }

    // The following functions are overrides required by Solidity.

    function votingDelay()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description, address proposer)
        internal
        override(GovernorUpgradeable, GovernorStorageUpgradeable)
        returns (uint256)
    {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}
