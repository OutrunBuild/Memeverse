// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev External expansion of {Governor} for governance cycle incentive.
 */
interface IGovernanceCycleIncentivizer {
    struct Cycle {
        uint128 startTime;
        uint128 endTime;
        uint256 totalVotes;
        mapping(address => uint256) treasuryBalances;
        mapping(address => uint256) rewardBalances;
        mapping(address => uint256) userVotes; 
        address[] treasuryTokenList;
        address[] rewardTokenList;
    }

    struct GovernanceCycleIncentivizerStorage {
        uint128 _rewardRatio;
        uint128 _currentCycleId;
        address _governor;
        address[] _rewardTokenList;
        address[] _treasuryTokenList;
        mapping(uint128 cycleId => Cycle) _cycles;
        mapping(address token => bool) _rewardTokens;
        mapping(address token => bool) _treasuryTokens;
    }

    /**
     * @notice Initialize the governanceCycleIncentivizer.
     * @param governor - The DAO Governor
     * @param initFundTokens - The initial DAO fund tokens.
     */
    function initialize(address governor, address[] calldata initFundTokens) external;

    /**
     * @dev Get current cycle ID
     */
    function currentCycleId() external view returns (uint256);

    /**
     * @dev Get the contract meta data
     */
    function metaData() external view returns (
        uint128 currentCycleId, 
        uint128 rewardRatio, 
        address governor, 
        address[] memory treasuryTokenList,
        address[] memory rewardTokenList
    );

    /**
     * @dev Get cycle meta info
     */
    function cycleInfo(uint128 cycleId) external view returns (
        uint128 startTime, 
        uint128 endTime, 
        uint256 totalVotes, 
        address[] memory treasuryTokenList,
        address[] memory rewardTokenList
    );

    /**
     * @dev Get user votes
     */
    function getUserVotesCount(address user, uint128 cycleId) external view returns (uint256);

    /**
     * @dev Check treasury token
     */
    function isTreasuryToken(uint128 cycleId, address token) external view returns (bool);

    /**
     * @dev Check reward token
     */
    function isRewardToken(uint128 cycleId, address token) external view returns (bool);

    /**
     * @dev Get the specific token rewards claimable by the user for the previous cycle
     * @param user - The user address
     * @param token - The token address
     * @return The specific token rewards claimable by the user for the previous cycle
     */
    function getClaimableReward(address user, address token) external view returns (uint256);
    
    /**
     * @dev Get all registered token rewards claimable by the user for the previous cycle
     * @param user - The user address
     * @return tokens - Tokens Array of token addresses
     * @return rewards - All registered token rewards
     */
    function getClaimableReward(address user) external view returns (address[] memory tokens, uint256[] memory rewards);

    /**
     * @dev Get the specific token remaining rewards claimable for the previous cycle
     * @param token - The token address
     * @return remainingReward - The specific token remaining rewards claimable
     */
    function getRemainingClaimableRewards(address token) external view returns (uint256 remainingReward);

    /**
     * @dev Get all registered token remaining rewards claimable for the previous cycle
     * @return tokens - Tokens Array of token addresses
     * @return rewards - All registered token rewards
     */
    function getRemainingClaimableRewards() external view returns (address[] memory tokens, uint256[] memory rewards);
    
    /**
     * @dev Get treasury balance for a specific cycle
     * @param cycleId - The cycle ID
     * @param token - The token address
     * @return The treasury balance for the specific cycle
     */
    function getTreasuryBalance(uint128 cycleId, address token) external view returns (uint256);

    /**
     * @dev Get all registered tokens' treasury balances for a specific cycle
     * @param cycleId - The cycle ID
     * @return tokens - Tokens Array of token addresses
     * @return balances - Balances Array of corresponding treasury balances
     */
    function getTreasuryBalances(uint128 cycleId) external view returns (address[] memory tokens, uint256[] memory balances);

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
     * @dev Accumulate cycle votes
     * @param user - The user address
     * @param votes - The number of votes
     */
    function accumCycleVotes(address user, uint256 votes) external;

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerTreasuryToken(address token) external;

    /**
     * @dev Register for reward token，it MUST first be registered as a treasury token.
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerRewardToken(address token) external;

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterTreasuryToken(address token) external;

    /**
     * @dev Unregister for reward token
     * @param token - The token address
     */
    function unregisterRewardToken(address token) external;

    /**
     * @dev Update reward ratio
     * @param newRatio - The new reward ratio (basis points)
     */
    function updateRewardRatio(uint128 newRatio) external;

    // Events
    event CycleFinalized(
        uint128 indexed cycleId, 
        uint128 endTime, 
        address[] treasuryTokens, 
        uint256[] balances, 
        address[] rewardTokens,
        uint256[] rewards
    );

    event CycleStarted(
        uint128 indexed cycleId, 
        uint128 startTime, 
        uint128 endTime, 
        address[] tokens, 
        uint256[] balances
    );

    event RewardTokenRegistered(address indexed token);

    event RewardTokenUnregistered(address indexed token);

    event TreasuryTokenRegistered(address indexed token);

    event TreasuryTokenUnregistered(address indexed token);

    event RewardRatioUpdated(uint256 oldRatio, uint256 newRatio);

    event RewardClaimed(address indexed user, uint128 indexed cycleId, address indexed token, uint256 amount);

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

    event AccumCycleVotes(uint256 indexed cycleId, address indexed user, uint256 votes);

    // Errors
    error ZeroInput();

    error CycleNotEnded();

    error RegisteredToken();

    error NonTreasuryToken();

    error PermissionDenied();

    error NoRewardsToClaim();

    error NonRegisteredToken();

    error InvalidRewardRatio();

    error OutOfMaxTokensLimit();

    error InsufficientTreasuryBalance();
}