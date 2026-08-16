// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {IGovernanceCycleIncentivizer} from "./interfaces/IGovernanceCycleIncentivizer.sol";
import {IMemecoinDaoGovernor} from "./interfaces/IMemecoinDaoGovernor.sol";

/**
 * @dev External expansion of {Governor} for governance cycle incentive.
 */
// solhint-disable-next-line gas-small-strings
contract GovernanceCycleIncentivizerUpgradeable layout at erc7201("outrun.storage.GovernanceCycleIncentivizer")
    is
    IGovernanceCycleIncentivizer,
    Initializable,
    UUPSUpgradeable
{
    using OutrunSafeERC20 for IERC20;

    uint256 public constant BPS_BASE = 10000;
    uint256 public constant CYCLE_DURATION = 90 days;
    uint256 public constant MAX_TOKENS_LIMIT = 50;

    /// @custom:storage-location erc7201:outrun.storage.GovernanceCycleIncentivizer
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

    GovernanceCycleIncentivizerStorage private governanceCycleIncentivizerStorage;

    function __GovernanceCycleIncentivizer_init(address governor, address[] calldata initTreasuryTokens)
        internal
        onlyInitializing
    {
        governanceCycleIncentivizerStorage._currentCycleId = 1;
        governanceCycleIncentivizerStorage._rewardRatio = 2500; // 25% default treasury->reward split (BPS_BASE = 10000)
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        governanceCycleIncentivizerStorage._cycles[1].startTime = startTime;
        governanceCycleIncentivizerStorage._cycles[1].endTime = endTime;
        governanceCycleIncentivizerStorage._governor = governor;

        uint256 length = initTreasuryTokens.length;
        uint256[] memory balances = new uint256[](length);

        for (uint256 i = 0; i < length;) {
            address token = initTreasuryTokens[i];
            // Initialization has no Governor execution context, so only governance-time registration notifies it.
            // Seed the emitted CycleStarted balances from the same value written to storage, mirroring finalizeCurrentCycle.
            balances[i] = _registerTreasuryToken(token);
            unchecked {
                ++i;
            }
        }

        emit CycleStarted(1, startTime, endTime, initTreasuryTokens, balances);
    }

    modifier onlyGovernance() {
        require(msg.sender == governanceCycleIncentivizerStorage._governor, PermissionDenied());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the governanceCycleIncentivizer.
     * @dev Seeds the first cycle metadata and initial treasury token set.
     * @param governor - The DAO Governor
     * @param initFundTokens - The initial DAO fund tokens.
     */
    function initialize(address governor, address[] calldata initFundTokens) external override initializer {
        __GovernanceCycleIncentivizer_init(governor, initFundTokens);
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function currentCycleId() external view override returns (uint256) {
        return governanceCycleIncentivizerStorage._currentCycleId;
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function metaData()
        external
        view
        override
        returns (
            uint128 _currentCycleId,
            uint128 _rewardRatio,
            address _governor,
            address[] memory _treasuryTokenList,
            address[] memory _rewardTokenList
        )
    {
        _currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        _rewardRatio = governanceCycleIncentivizerStorage._rewardRatio;
        _governor = governanceCycleIncentivizerStorage._governor;
        _treasuryTokenList = governanceCycleIncentivizerStorage._treasuryTokenList;
        _rewardTokenList = governanceCycleIncentivizerStorage._rewardTokenList;
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev The finalized rewardTokenList is a filtered subset of the registered reward tokens: only those that had
    /// a positive treasury balance in a cycle with positive total votes (the per-token amount may still round to
    /// zero), not the live list.
    function cycleInfo(uint128 cycleId)
        external
        view
        override
        returns (
            uint128 startTime,
            uint128 endTime,
            uint256 totalVotes,
            address[] memory treasuryTokenList,
            address[] memory rewardTokenList
        )
    {
        Cycle storage cycle = governanceCycleIncentivizerStorage._cycles[cycleId];
        startTime = cycle.startTime;
        endTime = cycle.endTime;
        totalVotes = cycle.totalVotes;
        treasuryTokenList = cycle.treasuryTokenList;
        rewardTokenList = cycle.rewardTokenList;
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function getUserVotesCount(address user, uint128 cycleId) external view override returns (uint256) {
        return governanceCycleIncentivizerStorage._cycles[cycleId].userVotes[user];
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev Uses the active-set shortcut for the current cycle and historical lists for past cycles.
    function isTreasuryToken(uint128 cycleId, address token) external view override returns (bool) {
        if (cycleId == governanceCycleIncentivizerStorage._currentCycleId) {
            return governanceCycleIncentivizerStorage._treasuryTokens[token];
        } else {
            Cycle storage cycle = governanceCycleIncentivizerStorage._cycles[cycleId];
            uint256 length = cycle.treasuryTokenList.length;
            for (uint256 i = 0; i < length;) {
                if (token == cycle.treasuryTokenList[i]) return true;
                unchecked {
                    ++i;
                }
            }
        }

        return false;
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev Uses the active-set shortcut for the current cycle and historical lists for past cycles.
    function isRewardToken(uint128 cycleId, address token) external view override returns (bool) {
        if (cycleId == governanceCycleIncentivizerStorage._currentCycleId) {
            return governanceCycleIncentivizerStorage._rewardTokens[token];
        } else {
            Cycle storage cycle = governanceCycleIncentivizerStorage._cycles[cycleId];
            uint256 length = cycle.rewardTokenList.length;
            for (uint256 i = 0; i < length;) {
                if (token == cycle.rewardTokenList[i]) return true;
                unchecked {
                    ++i;
                }
            }
        }

        return false;
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev Computes the user's pro-rata share from the previous cycle reward balances.
    function getClaimableReward(address user, address token) external view override returns (uint256) {
        Cycle storage prevCycle =
            governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId - 1];

        uint256 userVotes = prevCycle.userVotes[user];
        if (userVotes == 0) return 0;
        uint256 rewardBalance = prevCycle.rewardBalances[token];
        if (rewardBalance == 0) return 0;
        uint256 totalVotes = prevCycle.totalVotes;

        return Math.mulDiv(rewardBalance, userVotes, totalVotes);
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev Computes the user's pro-rata share for each registered reward token.
    function getClaimableReward(address user)
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory rewards)
    {
        Cycle storage prevCycle =
            governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId - 1];

        uint256 userVotes = prevCycle.userVotes[user];
        if (userVotes != 0) {
            uint256 totalVotes = prevCycle.totalVotes;
            tokens = prevCycle.rewardTokenList;
            uint256 length = tokens.length;
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length;) {
                address token = tokens[i];
                uint256 rewardBalance = prevCycle.rewardBalances[token];
                rewards[i] = Math.mulDiv(rewardBalance, userVotes, totalVotes);
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function getRemainingClaimableRewards(address token) external view override returns (uint256 remainingReward) {
        Cycle storage prevCycle =
            governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId - 1];

        uint256 totalVotes = prevCycle.totalVotes;
        if (totalVotes != 0) remainingReward = prevCycle.rewardBalances[token];
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function getRemainingClaimableRewards()
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory rewards)
    {
        Cycle storage prevCycle =
            governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId - 1];

        uint256 totalVotes = prevCycle.totalVotes;
        if (totalVotes != 0) {
            tokens = prevCycle.rewardTokenList;
            uint256 length = tokens.length;
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length;) {
                address token = tokens[i];
                rewards[i] = prevCycle.rewardBalances[token];
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    function getTreasuryBalance(uint128 cycleId, address token) external view override returns (uint256) {
        return governanceCycleIncentivizerStorage._cycles[cycleId].treasuryBalances[token];
    }

    /// @inheritdoc IGovernanceCycleIncentivizer
    /// @dev Uses the live treasury token list for the active cycle and the frozen list for historical cycles.
    function getTreasuryBalances(uint128 cycleId)
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory balances)
    {
        Cycle storage cycle = governanceCycleIncentivizerStorage._cycles[cycleId];
        tokens = cycleId == governanceCycleIncentivizerStorage._currentCycleId
            ? governanceCycleIncentivizerStorage._treasuryTokenList
            : cycle.treasuryTokenList;

        uint256 length = tokens.length;
        balances = new uint256[](length);

        for (uint256 i = 0; i < length;) {
            address token = tokens[i];
            balances[i] = cycle.treasuryBalances[token];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Records treasury income for the current cycle.
     * @dev Updates accounting only; the governor contract remains responsible for the actual token transfer.
     * @param token - The token address
     * @param amount - The amount
     */
    function recordTreasuryIncome(address token, uint256 amount) external override onlyGovernance {
        require(token != address(0) && amount != 0, ZeroInput());
        require(governanceCycleIncentivizerStorage._treasuryTokens[token], NonTreasuryToken());

        uint128 _currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        governanceCycleIncentivizerStorage._cycles[_currentCycleId].treasuryBalances[token] += amount;

        emit TreasuryIncomeRecorded(_currentCycleId, token, msg.sender, amount);
    }

    /**
     * @notice Records a treasury asset transfer for the current cycle.
     * @dev Updates accounting only; the governor contract remains responsible for the actual token transfer. All
     * actions to transfer assets from the DAO treasury must use this entrypoint.
     * @param token - The token address
     * @param to - The receiver address
     * @param amount - The amount to transfer
     */
    function recordTreasuryAssetSpend(address token, address to, uint256 amount) external override onlyGovernance {
        require(token != address(0) && to != address(0) && amount != 0, ZeroInput());
        require(governanceCycleIncentivizerStorage._treasuryTokens[token], NonTreasuryToken());

        uint128 _currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        Cycle storage currentCycle = governanceCycleIncentivizerStorage._cycles[_currentCycleId];
        uint256 currentBalance = currentCycle.treasuryBalances[token];

        require(
            currentBalance >= amount && IERC20(token).balanceOf(governanceCycleIncentivizerStorage._governor) >= amount,
            InsufficientTreasuryBalance()
        );

        // Record
        currentCycle.treasuryBalances[token] = currentBalance - amount;

        emit TreasuryAssetSpendRecorded(_currentCycleId, token, to, amount);
    }

    /**
     * @notice Reconciles the current cycle treasury ledger with the governor's actual token holdings.
     * @dev Pure ledger action: no token transfer occurs, and any caller may call it (permissionless). This
     * is safe because the synced value is deterministically derived from the governor's actual ERC20
     * balance and the previous cycle unclaimed reward reserve — the caller cannot inject or inflate it. The
     * function takes no amount argument because it reads the governor's ERC20 balance itself, removing
     * the error surface of manual rebooking. Conservation G = T + R holds (G = governor custody
     * balance, T = current cycle treasury ledger, R = previous cycle unclaimed reward reserve
     * `_cycles[_currentCycleId - 1].rewardBalances[token]`); this function resets T to max(G - R, 0).
     * When R >= G the ledger is set to 0: a sync cannot heal a custody shortfall.
     * @param token - The treasury token address to reconcile
     */
    function syncTreasuryBalance(address token) external override {
        require(token != address(0), ZeroInput());
        require(governanceCycleIncentivizerStorage._treasuryTokens[token], NonTreasuryToken());

        (uint256 synced, uint128 _currentCycleId) = _computeSyncedTreasuryBalance(token);
        governanceCycleIncentivizerStorage._cycles[_currentCycleId].treasuryBalances[token] = synced;

        emit TreasuryBalanceSynced(_currentCycleId, token, synced);
    }

    /**
     * @notice Finalizes the current cycle and starts the next cycle.
     * @dev Rolls leftover rewards forward, snapshots treasury lists, and computes the new reward balances.
     */
    function finalizeCurrentCycle() external override {
        uint128 _currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        uint128 newCycleId = _currentCycleId + 1;
        Cycle storage currentCycle = governanceCycleIncentivizerStorage._cycles[_currentCycleId];
        require(block.timestamp >= currentCycle.endTime, CycleNotEnded());

        // Process reward distribution
        uint256 treasuryLength = governanceCycleIncentivizerStorage._treasuryTokenList.length;
        address[] memory treasuryTokens = new address[](treasuryLength);
        uint256[] memory balances = new uint256[](treasuryLength);
        uint256 rewardLength = governanceCycleIncentivizerStorage._rewardTokenList.length;
        address[] memory rewardTokens = new address[](rewardLength);
        uint256[] memory rewards = new uint256[](rewardLength);

        Cycle storage prevCycle = governanceCycleIncentivizerStorage._cycles[_currentCycleId - 1];

        uint256 j = 0;
        for (uint256 i = 0; i < treasuryLength;) {
            address token = governanceCycleIncentivizerStorage._treasuryTokenList[i];

            // Transfer remaining reward balance to current cycle treasury
            uint256 treasuryBalance = currentCycle.treasuryBalances[token];
            uint256 prevRewardBalance = prevCycle.rewardBalances[token];
            if (prevRewardBalance > 0) {
                prevCycle.rewardBalances[token] = 0;
                treasuryBalance += prevRewardBalance;
                currentCycle.treasuryBalances[token] = treasuryBalance;
            }

            // Distribute reward
            uint256 rewardAmount;
            if (
                governanceCycleIncentivizerStorage._rewardTokens[token] && treasuryBalance > 0
                    && currentCycle.totalVotes > 0
            ) {
                rewardAmount = treasuryBalance * governanceCycleIncentivizerStorage._rewardRatio / BPS_BASE;
                currentCycle.rewardBalances[token] = rewardAmount;
                treasuryBalance -= rewardAmount;

                rewardTokens[j] = token;
                rewards[j] = rewardAmount;
                unchecked {
                    ++j;
                }
            }

            governanceCycleIncentivizerStorage._cycles[newCycleId].treasuryBalances[token] = treasuryBalance;
            treasuryTokens[i] = token;
            balances[i] = treasuryBalance;
            unchecked {
                ++i;
            }
        }

        // Truncate the reward arrays to the actually-distributed count `j` so no trailing
        // address(0)/0 ghost entries reach storage, the event, or the array-returning views.
        assembly {
            mstore(rewardTokens, j)
            mstore(rewards, j)
        }

        currentCycle.treasuryTokenList = treasuryTokens;
        currentCycle.rewardTokenList = rewardTokens;

        emit CycleFinalized(_currentCycleId, uint128(block.timestamp), treasuryTokens, balances, rewardTokens, rewards);

        // Start new cycle
        governanceCycleIncentivizerStorage._currentCycleId = newCycleId;
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        governanceCycleIncentivizerStorage._cycles[newCycleId].startTime = startTime;
        governanceCycleIncentivizerStorage._cycles[newCycleId].endTime = endTime;

        emit CycleStarted(newCycleId, startTime, endTime, treasuryTokens, balances);
    }

    /**
     * @notice Claims the caller's reward allocation from the previous cycle.
     * @dev The caller claims for itself. Payouts are executed by the governor, which remains the asset custodian.
     */
    function claimReward() external override {
        uint128 prevCycleId = governanceCycleIncentivizerStorage._currentCycleId - 1;
        Cycle storage prevCycle = governanceCycleIncentivizerStorage._cycles[prevCycleId];
        address user = msg.sender;

        uint256 userVotes = prevCycle.userVotes[user];
        require(userVotes != 0, NoRewardsToClaim());

        prevCycle.userVotes[user] = 0;
        uint256 totalVotes = prevCycle.totalVotes;
        address[] memory rewardTokenList = prevCycle.rewardTokenList;
        uint256 length = rewardTokenList.length;

        for (uint256 i = 0; i < length;) {
            address token = rewardTokenList[i];
            unchecked {
                ++i;
            }
            uint256 rewardBalance = prevCycle.rewardBalances[token];
            if (rewardBalance > 0) {
                uint256 rewardAmount = Math.mulDiv(rewardBalance, userVotes, totalVotes);
                if (rewardAmount > 0) {
                    prevCycle.rewardBalances[token] = rewardBalance - rewardAmount;
                    IMemecoinDaoGovernor(governanceCycleIncentivizerStorage._governor)
                        .disburseReward(token, user, rewardAmount);
                    emit RewardClaimed(user, prevCycleId, token, rewardAmount);
                }
            }
        }
    }

    /**
     * @notice Accumulates voting power for a user in the active cycle.
     * @dev Called by the governor after vote casting succeeds.
     * @param user - The user address
     * @param votes - The number of votes
     */
    function accumCycleVotes(address user, uint256 votes) external override onlyGovernance {
        uint128 _currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        governanceCycleIncentivizerStorage._cycles[_currentCycleId].userVotes[user] += votes;
        governanceCycleIncentivizerStorage._cycles[_currentCycleId].totalVotes += votes;

        emit AccumCycleVotes(_currentCycleId, user, votes);
    }

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice Governance must only register reviewed standard ERC20 tokens.
     * @dev This treasury ledger assumes nominal `amount` accounting and does not adapt to fee-on-transfer,
     * rebasing, or other non-standard balance semantics. Registering such a token can distort treasury/reward
     * accounting, and that asset-acceptance risk is borne by governance.
     */
    function registerTreasuryToken(address token) public override onlyGovernance {
        require(token != address(0), ZeroInput());
        require(!governanceCycleIncentivizerStorage._treasuryTokens[token], RegisteredToken());
        require(governanceCycleIncentivizerStorage._treasuryTokenList.length < MAX_TOKENS_LIMIT, OutOfMaxTokensLimit());

        _registerTreasuryToken(token);
        IMemecoinDaoGovernor(governanceCycleIncentivizerStorage._governor).recordTreasuryTokenRegistration(token);
    }

    /**
     * @dev Register for reward token，it MUST first be registered as a treasury token.
     * @param token - The token address
     * @notice Governance must only register reviewed standard ERC20 reward tokens.
     * @dev Reward payout uses nominal `amount` accounting and assumes the recipient receives the quoted amount.
     * Fee-on-transfer, rebasing, or other non-standard balance semantics are unsupported and must not be admitted
     * through governance token registration.
     */
    function registerRewardToken(address token) public override onlyGovernance {
        require(token != address(0), ZeroInput());
        require(!governanceCycleIncentivizerStorage._rewardTokens[token], RegisteredToken());
        require(governanceCycleIncentivizerStorage._treasuryTokens[token], NonTreasuryToken());
        require(governanceCycleIncentivizerStorage._rewardTokenList.length < MAX_TOKENS_LIMIT, OutOfMaxTokensLimit());

        _registerRewardToken(token);
    }

    /**
     * @notice Unregisters a treasury token from the active cycle configuration.
     * @dev Also clears current-cycle accounting and unregisters the reward token if necessary.
     * @param token - The token address
     */
    function unregisterTreasuryToken(address token) external override onlyGovernance {
        require(governanceCycleIncentivizerStorage._treasuryTokens[token], NonRegisteredToken());

        governanceCycleIncentivizerStorage._treasuryTokens[token] = false;
        governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId].treasuryBalances[
            token
        ] = 0;

        uint256 length = governanceCycleIncentivizerStorage._treasuryTokenList.length;
        for (uint256 i = 0; i < length;) {
            if (governanceCycleIncentivizerStorage._treasuryTokenList[i] == token) {
                governanceCycleIncentivizerStorage._treasuryTokenList[i] =
                    governanceCycleIncentivizerStorage._treasuryTokenList[length - 1];
                governanceCycleIncentivizerStorage._treasuryTokenList.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Unregister Reward Token
        if (governanceCycleIncentivizerStorage._rewardTokens[token]) _unregisterRewardToken(token);

        emit TreasuryTokenUnregistered(token);
    }

    /**
     * @notice Unregisters a reward token from the active cycle configuration.
     * @dev Clears current-cycle reward accounting for the token.
     * @param token - The token address
     */
    function unregisterRewardToken(address token) external override onlyGovernance {
        require(governanceCycleIncentivizerStorage._rewardTokens[token], NonRegisteredToken());

        _unregisterRewardToken(token);

        emit RewardTokenUnregistered(token);
    }

    /**
     * @notice Updates the reward ratio used when finalizing a cycle.
     * @dev The ratio is expressed in basis points and capped by `BPS_BASE`.
     * @param newRatio - The new reward ratio (basis points)
     */
    function updateRewardRatio(uint128 newRatio) external override onlyGovernance {
        require(newRatio <= BPS_BASE, InvalidRewardRatio());

        uint128 oldRatio = governanceCycleIncentivizerStorage._rewardRatio;
        governanceCycleIncentivizerStorage._rewardRatio = newRatio;

        emit RewardRatioUpdated(oldRatio, newRatio);
    }

    /**
     * @dev Registers a treasury token and seeds its ledger balance.
     * @notice Seeds the ledger at registration time with max(G - R, 0): G is the governor-held ERC20
     * balance and R is the previous cycle unclaimed reward reserve, matching the syncTreasuryBalance
     * formula so conservation G = T + R holds in the domain G >= R; when R >= G the seed saturates at
     * 0 and the ledger over-records R - G (reward reserve exceeding governor custody). During
     * initialization the governor holds zero tokens and cycle zero has no reward reserve, so the seed
     * is zero.
     * @param token - The token address
     * @return synced - The seeded treasury balance written to storage (returned so the init path can
     * emit it in CycleStarted, mirroring finalizeCurrentCycle).
     */
    function _registerTreasuryToken(address token) internal returns (uint256 synced) {
        uint128 _currentCycleId;
        (synced, _currentCycleId) = _computeSyncedTreasuryBalance(token);
        governanceCycleIncentivizerStorage._treasuryTokenList.push(token);
        governanceCycleIncentivizerStorage._treasuryTokens[token] = true;
        governanceCycleIncentivizerStorage._cycles[_currentCycleId].treasuryBalances[token] = synced;

        emit TreasuryTokenRegistered(token);
    }

    function _registerRewardToken(address token) internal {
        governanceCycleIncentivizerStorage._rewardTokens[token] = true;
        governanceCycleIncentivizerStorage._rewardTokenList.push(token);

        emit RewardTokenRegistered(token);
    }

    function _unregisterRewardToken(address token) internal {
        governanceCycleIncentivizerStorage._rewardTokens[token] = false;
        governanceCycleIncentivizerStorage._cycles[governanceCycleIncentivizerStorage._currentCycleId].rewardBalances[
            token
        ] = 0;

        uint256 length = governanceCycleIncentivizerStorage._rewardTokenList.length;
        for (uint256 i = 0; i < length;) {
            if (governanceCycleIncentivizerStorage._rewardTokenList[i] == token) {
                governanceCycleIncentivizerStorage._rewardTokenList[i] =
                    governanceCycleIncentivizerStorage._rewardTokenList[length - 1];
                governanceCycleIncentivizerStorage._rewardTokenList.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Computes the synced treasury balance for a token: governor custody balance minus the previous
     * cycle unclaimed reward reserve, saturated at zero. Shared by syncTreasuryBalance and
     * _registerTreasuryToken so the max(G - R, 0) ledger formula cannot drift between the two sites.
     * @param token - The token address
     * @return synced - The computed treasury balance for the current cycle
     * @return currentCycleId - The active cycle id
     */
    function _computeSyncedTreasuryBalance(address token)
        internal
        view
        returns (uint256 synced, uint128 currentCycleId)
    {
        // External read first so a reentrant finalize cannot target a stale cycle.
        uint256 governorBalance = IERC20(token).balanceOf(governanceCycleIncentivizerStorage._governor);
        currentCycleId = governanceCycleIncentivizerStorage._currentCycleId;
        uint256 unclaimedReserve = governanceCycleIncentivizerStorage._cycles[currentCycleId - 1].rewardBalances[token];
        synced = governorBalance >= unclaimedReserve ? governorBalance - unclaimedReserve : 0;
    }

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}
