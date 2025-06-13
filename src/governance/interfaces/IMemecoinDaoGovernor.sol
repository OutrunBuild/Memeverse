// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IGovernanceCycleIncentivizer } from "./IGovernanceCycleIncentivizer.sol";

/**
 * @title MemecoinDaoGovernor interface
 */
interface IMemecoinDaoGovernor {
    struct MemecoinDaoGovernorStorage {
        IGovernanceCycleIncentivizer _governanceCycleIncentivizer;
    }

    function initialize(
        string memory _name, 
        IVotes _token,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator,
        address _governanceCycleIncentivizer
    ) external;

    function GovernanceCycleIncentivizer() external view returns (address);

    function receiveTreasuryIncome(address token, uint256 amount) external;

    function sendTreasuryAssets(address token, address to, uint256 amount) external;
}