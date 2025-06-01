// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @dev Extension of {Governor} for governance cycle incentive.
 */
interface IGovernanceCycleIncentive {
    struct Cycle {
        uint256 startTime;
        uint256 endTime;
        mapping(address => uint256) treasuryBalances;
        mapping(address => uint256) rewardBalances;
        mapping(address => uint256) userVotes; 
        uint256 totalVotes;
        bool isFinalized;
    }

    struct GovernanceCycleIncentiveStorage {
        uint256 _currentCycleId;
        uint256 _rewardRatio;
        mapping(uint256 cycleId => Cycle) _cycles;
        mapping(address token => bool) _acceptedTokens;
        address[] _acceptedTokenList;
    }

    /**
     * @dev Get the rewards claimable by the user for the previous cycle
     * @param token - The token address
     * @return The rewards claimable by the user for the previous cycle
     */
    function getClaimableReward(address token) external view returns (uint256);
    
    /**
     * @dev Get the treasury balance for the current cycle
     * @param token - The token address
     * @return The treasury balance for the current cycle
     */
    function getCurrentTreasuryBalance(address token) external view returns (uint256);

    /**
     * @dev Get treasury balance for a specific cycle
     * @param cycleId - The cycle ID
     * @param token - The token address
     * @return The treasury balance for the specific cycle
     */
    function getTreasuryBalance(uint256 cycleId, address token) external view returns (uint256);

    /**
     * @dev Receive treasury income
     * @param token - The token address
     * @param amount - The amount
     */
    function receiveTreasuryIncome(address token,uint256 amount) external;

    /**
     * @dev Transfer treasury assets to another address
     * @param token - The token address
     * @param to - The receiver address
     * @param amount - The amount to transfer
     * @notice All actions to transfer assets from the DAO treasury MUST call this function
     */
    function sendTreasuryAssets(address token,address to,uint256 amount) external;


    /**
     * @dev End current cycle and start new cycle
     */
    function finalizeCurrentCycle() external;

    /**
     * @dev Claim reward
     */
    function claimReward() external;

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerToken(address token) external;

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterToken(address token) external;

    /**
     * @dev Update reward ratio
     * @param newRatio - The new reward ratio (basis points)
     */
    function updateRewardRatio(uint256 newRatio) external;

    // Events
    event CycleStarted(uint256 indexed cycleId, uint256 startTime, uint256 endTime);
    event CycleFinalized(uint256 indexed cycleId);
    event TokenRegistered(address indexed token);
    event TokenUnregistered(address indexed token);
    event RewardRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event TreasuryReceived(
        uint256 indexed cycleId, 
        address indexed token, 
        address indexed sender, 
        uint256 amount
    );
    event TreasurySent(
        uint256 indexed cycleId, 
        address indexed token, 
        address indexed receiver, 
        uint256 amount
    );
    event RecordVotes(uint256 indexed cycleId, address indexed user, uint256 votes);

    // Errors
    error ZeroInput();
    error InvalidToken();
    error CycleNotEnded();
    error NotGovernance();
    error NoRewardsToClaim();
    error InvalidRewardRatio();
    error CycleAlreadyFinalized();
    error InsufficientTreasuryBalance();
}