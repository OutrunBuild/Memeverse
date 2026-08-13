// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

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

    /**
     * @notice Initializes the incentivizer and seeds the first cycle token sets.
     * @dev Must be called once by the paired governor deployment flow.
     * @param governor DAO governor that owns cycle transitions and treasury accounting writes.
     * @param initFundTokens Initial treasury token list tracked from cycle zero.
     */
    function initialize(address governor, address[] calldata initFundTokens) external;

    /**
     * @notice Returns the currently active governance cycle identifier.
     * @dev The identifier is monotonically increasing and increments after each finalization.
     * @return Current active cycle id.
     */
    function currentCycleId() external view returns (uint256);

    /**
     * @notice Returns top-level cycle configuration and token registries.
     * @dev Used by frontends and verifier flows to reconstruct current governance context.
     * @return currentCycleId Active cycle id.
     * @return rewardRatio Reward split ratio applied when a cycle is finalized.
     * @return governor Governor contract authorized to mutate cycle state.
     * @return treasuryTokenList Currently registered treasury token list.
     * @return rewardTokenList Currently registered reward token list.
     */
    function metaData()
        external
        view
        returns (
            uint128 currentCycleId,
            uint128 rewardRatio,
            address governor,
            address[] memory treasuryTokenList,
            address[] memory rewardTokenList
        );

    /**
     * @notice Returns immutable and aggregate metadata for a specific cycle.
     * @dev Exposes cycle boundaries and token registries without user-level balances. Token lists are
     * snapshots written only at finalize time: querying the active (unfinalized) cycle returns empty
     * lists. Use metaData() for the active cycle's live registries. The finalized rewardTokenList is a
     * filtered subset of the registered reward tokens (only those that actually accrued a reward this
     * cycle), not the live registered list.
     * @param cycleId Cycle identifier to inspect.
     * @return startTime Cycle start timestamp.
     * @return endTime Cycle end timestamp.
     * @return totalVotes Total votes accumulated in the cycle.
     * @return treasuryTokenList Treasury token list snapshot for the cycle.
     * @return rewardTokenList Reward token list snapshot for the cycle.
     */
    function cycleInfo(uint128 cycleId)
        external
        view
        returns (
            uint128 startTime,
            uint128 endTime,
            uint256 totalVotes,
            address[] memory treasuryTokenList,
            address[] memory rewardTokenList
        );

    /**
     * @notice Returns votes contributed by a user in a target cycle.
     * @dev Vote totals are consumed for reward distribution after finalization.
     * @param user Account whose votes are queried.
     * @param cycleId Cycle identifier to inspect.
     * @return Votes recorded for the user in the cycle.
     */
    function getUserVotesCount(address user, uint128 cycleId) external view returns (uint256);

    /**
     * @notice Checks whether a token is registered as treasury asset for a cycle.
     * @dev Registry is cycle-scoped to preserve historical accounting context.
     * @param cycleId Cycle identifier to inspect.
     * @param token Token address to verify.
     * @return True when the token is tracked as treasury token for the cycle.
     */
    function isTreasuryToken(uint128 cycleId, address token) external view returns (bool);

    /**
     * @notice Checks whether a token is registered as reward asset for a cycle.
     * @dev Reward eligibility is cycle-scoped and snapshotted during finalization.
     * @param cycleId Cycle identifier to inspect.
     * @param token Token address to verify.
     * @return True when the token is tracked as reward token for the cycle.
     */
    function isRewardToken(uint128 cycleId, address token) external view returns (bool);

    /**
     * @notice Returns claimable reward amount for a user-token pair.
     * @dev Reads finalized cycle accounting; does not mutate claim state.
     * @param user Beneficiary account.
     * @param token Reward token to query.
     * @return Claimable amount for the user in the most recently finalized cycle context.
     */
    function getClaimableReward(address user, address token) external view returns (uint256);

    /**
     * @notice Returns claimable rewards across all registered reward tokens.
     * @dev Token order matches the returned reward array index-by-index.
     * @param user Beneficiary account.
     * @return tokens Registered reward token list considered for the query.
     * @return rewards Claimable reward amounts aligned with `tokens`.
     */
    function getClaimableReward(address user) external view returns (address[] memory tokens, uint256[] memory rewards);

    /**
     * @notice Returns unclaimed reward balance for a specific token.
     * @dev Useful for treasury reconciliation after partial reward claims.
     * @param token Reward token address.
     * @return remainingReward Remaining claimable rewards not yet distributed.
     */
    function getRemainingClaimableRewards(address token) external view returns (uint256 remainingReward);

    /**
     * @notice Returns unclaimed reward balances for all registered reward tokens.
     * @dev Token order matches the returned reward array index-by-index.
     * @return tokens Registered reward token list.
     * @return rewards Remaining claimable rewards aligned with `tokens`.
     */
    function getRemainingClaimableRewards() external view returns (address[] memory tokens, uint256[] memory rewards);

    /**
     * @notice Returns treasury balance snapshot for a token in a cycle.
     * @dev Balance reflects cycle ledger accounting, not live ERC20 balance reads.
     * @param cycleId Cycle identifier to inspect.
     * @param token Treasury token address.
     * @return Treasury balance tracked for the token in the cycle.
     */
    function getTreasuryBalance(uint128 cycleId, address token) external view returns (uint256);

    /**
     * @notice Returns treasury balances for all registered tokens in a cycle.
     * @dev Token order matches the returned balances array index-by-index.
     * @param cycleId Cycle identifier to inspect.
     * @return tokens Registered treasury token list for the cycle.
     * @return balances Treasury balances aligned with `tokens`.
     */
    function getTreasuryBalances(uint128 cycleId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances);

    /**
     * @notice Records incoming treasury assets into the active cycle ledger.
     * @dev Called by governor-controlled treasury inflow paths.
     * @param token Treasury token address credited.
     * @param amount Amount credited to the cycle treasury ledger.
     */
    function recordTreasuryIncome(address token, uint256 amount) external;

    /**
     * @notice Records treasury asset outflow from the active cycle ledger.
     * @dev All governor treasury spend paths must call this hook for consistent accounting.
     * @param token Treasury token address debited.
     * @param to Receiver address of the treasury spend.
     * @param amount Amount debited from the cycle treasury ledger.
     */
    function recordTreasuryAssetSpend(address token, address to, uint256 amount) external;

    /**
     * @notice Reconciles the active cycle treasury ledger with the governor's actual token holdings.
     * @dev Pure ledger action (no token transfer) callable by any account (permissionless); the synced
     * value is deterministically derived from the governor's ERC20 balance and the previous cycle reward
     * reserve, so it is not caller-controllable. Reads the governor's ERC20 balance itself, so no amount
     * argument can be misbooked. Resets the cycle ledger to max(governorBalance -
     * previousCycleUnclaimedRewardReserve, 0).
     * @param token Treasury token address to reconcile.
     */
    function syncTreasuryBalance(address token) external;

    /**
     * @notice Finalizes the current cycle and opens the next one.
     * @dev Settles reward pools, snapshots balances, and advances cycle id.
     */
    function finalizeCurrentCycle() external;

    /**
     * @notice Claims all eligible rewards for `msg.sender`.
     * @dev Uses finalized cycle snapshots to compute and transfer pending rewards.
     */
    function claimReward() external;

    /**
     * @notice Adds vote weight for a user in the active cycle.
     * @dev Called by governance voting hooks during proposal lifecycle.
     * @param user Account whose vote tally is increased.
     * @param votes Vote amount to accumulate.
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
     * @notice Removes a token from the treasury token registry.
     * @dev Caller must ensure removal does not break outstanding accounting assumptions.
     * @param token Treasury token address to unregister.
     */
    function unregisterTreasuryToken(address token) external;

    /**
     * @notice Removes a token from the reward token registry.
     * @dev Caller must ensure no unresolved reward distribution depends on the token.
     * @param token Reward token address to unregister.
     */
    function unregisterRewardToken(address token) external;

    /**
     * @notice Updates cycle reward split ratio.
     * @dev Ratio is expressed in basis points and validated against protocol limits.
     * @param newRatio New reward ratio in basis points.
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
        uint128 indexed cycleId, uint128 startTime, uint128 endTime, address[] tokens, uint256[] balances
    );

    event RewardTokenRegistered(address indexed token);

    event RewardTokenUnregistered(address indexed token);

    event TreasuryTokenRegistered(address indexed token);

    event TreasuryTokenUnregistered(address indexed token);

    event RewardRatioUpdated(uint256 oldRatio, uint256 newRatio);

    event RewardClaimed(address indexed user, uint128 indexed cycleId, address indexed token, uint256 amount);

    event TreasuryIncomeRecorded(
        uint256 indexed cycleId, address indexed token, address indexed sender, uint256 amount
    );

    event TreasuryAssetSpendRecorded(
        uint256 indexed cycleId, address indexed token, address indexed receiver, uint256 amount
    );

    event TreasuryBalanceSynced(uint256 indexed cycleId, address indexed token, uint256 balance);

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
