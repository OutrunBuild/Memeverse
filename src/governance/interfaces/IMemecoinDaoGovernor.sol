// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title MemecoinDaoGovernor interface
 */
interface IMemecoinDaoGovernor {
    function initialize(
        string memory _name, 
        IVotes _token,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) external;
}