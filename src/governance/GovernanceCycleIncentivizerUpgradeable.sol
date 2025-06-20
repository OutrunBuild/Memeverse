// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IGovernanceCycleIncentivizer } from "./interfaces/IGovernanceCycleIncentivizer.sol";

/**
 * @dev External expansion of {Governor} for governance cycle incentive.
 */
contract GovernanceCycleIncentivizerUpgradeable is IGovernanceCycleIncentivizer, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant RATIO = 10000;
    uint256 public constant CYCLE_DURATION = 90 days;
    uint256 public constant MAX_TOKENS_LIMIT = 50;

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.GovernanceCycleIncentivizer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GovernanceCycleIncentivizerStorageLocation = 0x173bbd0db440ff8dcb0efb05aced4279e21e45a07b4974973a371552ef840a00;

    function _getGovernanceCycleIncentivizerStorage() private pure returns (GovernanceCycleIncentivizerStorage storage $) {
        assembly {
            $.slot := GovernanceCycleIncentivizerStorageLocation
        }
    }

    function __GovernanceCycleIncentivizer_init(address governor, address[] calldata initTreasuryTokens) internal onlyInitializing {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        $._currentCycleId = 1;
        $._rewardRatio = 5000;
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        $._cycles[1].startTime = startTime;
        $._cycles[1].endTime = endTime;
        $._governor = governor;

        uint256 length = initTreasuryTokens.length;
        uint256[] memory balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = initTreasuryTokens[i];
            registerTreasuryToken(token);
        }

        emit CycleStarted(1, startTime, endTime, initTreasuryTokens, balances);
    }

    modifier onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require(msg.sender == $._governor, PermissionDenied());
        _;
    }

    /**
     * @notice Initialize the governanceCycleIncentivizer.
     * @param governor - The DAO Governor
     * @param initFundTokens - The initial DAO fund tokens.
     */
    function initialize(address governor, address[] calldata initFundTokens) external override initializer {
        __GovernanceCycleIncentivizer_init(governor, initFundTokens);
        __UUPSUpgradeable_init();
    }

    /**
     * @dev Get current cycle ID
     */
    function currentCycleId() external view override returns (uint256) {
        return _getGovernanceCycleIncentivizerStorage()._currentCycleId;
    }
    
    /**
     * @dev Get the contract meta data
     */
    function metaData() external view override returns (
        uint256 _currentCycleId, 
        uint256 _rewardRatio, 
        address _governor, 
        address[] memory _treasuryTokenList,
        address[] memory _rewardTokenList
    ) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        _currentCycleId = $._currentCycleId;
        _rewardRatio = $._rewardRatio;
        _governor = $._governor;
        _treasuryTokenList = $._treasuryTokenList;
        _rewardTokenList = $._rewardTokenList;
    }

    /**
     * @dev Get cycle meta info
     */
    function cycleInfo(uint256 cycleId) external view override returns (
        uint128 startTime, 
        uint128 endTime, 
        uint256 totalVotes, 
        address[] memory treasuryTokenList,
        address[] memory rewardTokenList
    ) {
        Cycle storage cycle = _getGovernanceCycleIncentivizerStorage()._cycles[cycleId];
        startTime = cycle.startTime;
        endTime = cycle.endTime;
        totalVotes = cycle.totalVotes;
        treasuryTokenList = cycle.treasuryTokenList;
        rewardTokenList = cycle.rewardTokenList;
    }

    /**
     * @dev Get user votes count
     */
    function getUserVotesCount(address user, uint256 cycleId) external view override returns (uint256) {
        return _getGovernanceCycleIncentivizerStorage()._cycles[cycleId].userVotes[user];
    }

    /**
     * @dev Check treasury token
     */
    function isTreasuryToken(uint256 cycleId, address token) external view override returns (bool) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        if (cycleId == $._currentCycleId) {
            return $._treasuryTokens[token];
        } else {
            Cycle storage cycle = $._cycles[cycleId];
            address[] memory treasuryTokenList = cycle.treasuryTokenList;
            for (uint256 i = 0; i < treasuryTokenList.length; i++) {
                if (token == treasuryTokenList[i]) return true;
            }
        }

        return false;
    }

    /**
     * @dev Check reward token
     */
    function isRewardToken(uint256 cycleId, address token) external view override returns (bool) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        if (cycleId == $._currentCycleId) {
            return $._rewardTokens[token];
        } else {
            Cycle storage cycle = $._cycles[cycleId];
            address[] memory rewardTokenList = cycle.rewardTokenList;
            for (uint256 i = 0; i < rewardTokenList.length; i++) {
                if (token == rewardTokenList[i]) return true;
            }
        }

        return false;
    }

    /**
     * @dev Get the specific token rewards claimable by the user for the previous cycle
     * @param user - The user address
     * @param token - The token address
     * @return The specific token rewards claimable by the user for the previous cycle
     */
    function getClaimableReward(address user, address token) external view override returns (uint256) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        Cycle storage prevCycle = $._cycles[$._currentCycleId - 1];

        uint256 userVotes = prevCycle.userVotes[user];
        if (userVotes == 0) return 0;
        uint256 rewardBalance = prevCycle.rewardBalances[token];
        if (rewardBalance == 0) return 0;
        uint256 totalVotes = prevCycle.totalVotes;
        
        return Math.mulDiv(rewardBalance, userVotes, totalVotes);
    }

    /**
     * @dev Get all registered token rewards claimable by the user for the previous cycle
     * @param user - The user address
     * @return tokens - Tokens Array of token addresses
     * @return rewards - All registered token rewards
     */
    function getClaimableReward(address user) external view override returns (address[] memory tokens, uint256[] memory rewards) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        Cycle storage prevCycle = $._cycles[$._currentCycleId - 1];

        uint256 userVotes = prevCycle.userVotes[user];
        if (userVotes != 0) {
            uint256 totalVotes = prevCycle.totalVotes;
            tokens = prevCycle.rewardTokenList;
            uint256 length = tokens.length;
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                address token = tokens[i];
                uint256 rewardBalance = prevCycle.rewardBalances[token];
                rewards[i] = Math.mulDiv(rewardBalance, userVotes, totalVotes);
            }
        }
    }

    /**
     * @dev Get the specific token remaining rewards claimable for the previous cycle
     * @param token - The token address
     * @return remainingReward - The specific token remaining rewards claimable
     */
    function getRemainingClaimableRewards(address token) external view override returns (uint256 remainingReward) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        Cycle storage prevCycle = $._cycles[$._currentCycleId - 1];

        uint256 totalVotes = prevCycle.totalVotes;
        if (totalVotes != 0) remainingReward = prevCycle.rewardBalances[token];
    }

    /**
     * @dev Get all registered token remaining rewards claimable for the previous cycle
     * @return tokens - Tokens Array of token addresses
     * @return rewards - All registered token rewards
     */
    function getRemainingClaimableRewards() external view override returns (address[] memory tokens, uint256[] memory rewards) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        Cycle storage prevCycle = $._cycles[$._currentCycleId - 1];

        uint256 totalVotes = prevCycle.totalVotes;
        if (totalVotes != 0) {
            tokens = prevCycle.rewardTokenList;
            uint256 length = tokens.length;
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                address token = tokens[i];
                rewards[i] = prevCycle.rewardBalances[token];
            }
        }
    }

    /**
     * @dev Get treasury balance for a specific cycle
     * @param cycleId - The cycle ID
     * @param token - The token address
     * @return The treasury balance for the specific cycle
     */
    function getTreasuryBalance(uint256 cycleId, address token) external view override returns (uint256) {
        return _getGovernanceCycleIncentivizerStorage()._cycles[cycleId].treasuryBalances[token];
    }

    /**
     * @dev Get all registered tokens' treasury balances for a specific cycle
     * @param cycleId - The cycle ID
     * @return tokens - Tokens Array of token addresses
     * @return balances - Balances Array of corresponding treasury balances
     */
    function getTreasuryBalances(uint256 cycleId) external view override returns (address[] memory tokens, uint256[] memory balances) {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        Cycle storage cycle = $._cycles[cycleId];
        tokens = cycleId == $._currentCycleId ? $._treasuryTokenList : cycle.treasuryTokenList;

        uint256 length = tokens.length;
        balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            balances[i] = cycle.treasuryBalances[token];
        }
    }

    /**
     * @dev Receive treasury income
     * @param token - The token address
     * @param amount - The amount
     */
    function receiveTreasuryIncome(address token, uint256 amount) external override {
        require(token != address(0) && amount != 0, ZeroInput());
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require($._treasuryTokens[token], NonTreasuryToken());

        // Record
        uint256 _currentCycleId = $._currentCycleId;
        $._cycles[_currentCycleId].treasuryBalances[token] += amount;

        emit TreasuryReceived(_currentCycleId, token, msg.sender, amount);
    }

    /**
     * @dev Transfer treasury assets to another address
     * @param token - The token address
     * @param to - The receiver address
     * @param amount - The amount to transfer
     * @notice All actions to transfer assets from the DAO treasury MUST call this function
     */
    function sendTreasuryAssets(address token, address to, uint256 amount) external override onlyGovernance {
        require(token != address(0) && to != address(0) && amount != 0, ZeroInput());
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require($._treasuryTokens[token], NonTreasuryToken());

        uint256 _currentCycleId = $._currentCycleId;
        Cycle storage currentCycle = $._cycles[_currentCycleId];
        uint256 currentBalance = currentCycle.treasuryBalances[token];
        
        require(
            currentBalance >= amount &&
            IERC20(token).balanceOf($._governor) >= amount, 
            InsufficientTreasuryBalance()
        );

        // Record
        currentCycle.treasuryBalances[token] = currentBalance - amount;
        
        emit TreasurySent(_currentCycleId, token, to, amount);
    }

    /**
     * @dev End current cycle and start new cycle
     */
    function finalizeCurrentCycle() external override {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        uint256 _currentCycleId = $._currentCycleId;
        uint256 newCycleId = _currentCycleId + 1;
        Cycle storage currentCycle = $._cycles[_currentCycleId];
        require(block.timestamp >= currentCycle.endTime, CycleNotEnded());

        // Process reward distribution
        uint256 treasuryLength = $._treasuryTokenList.length;
        address[] memory treasuryTokens = new address[](treasuryLength);
        uint256[] memory balances = new uint256[](treasuryLength);
        uint256 rewardLength = $._rewardTokenList.length;
        address[] memory rewardTokens = new address[](rewardLength);
        uint256[] memory rewards = new uint256[](rewardLength);

        Cycle storage prevCycle = $._cycles[_currentCycleId - 1];

        uint256 j = 0;
        for (uint256 i = 0; i < treasuryLength; i++) {
            address token = $._treasuryTokenList[i];

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
            if ($._rewardTokens[token] && treasuryBalance > 0 && currentCycle.totalVotes > 0) {
                rewardAmount = treasuryBalance * $._rewardRatio / RATIO;
                currentCycle.rewardBalances[token] = rewardAmount;
                treasuryBalance -= rewardAmount;

                rewardTokens[j] = token;
                rewards[j] = rewardAmount;
                j++;
            }

            $._cycles[newCycleId].treasuryBalances[token] = treasuryBalance;
            treasuryTokens[i] = token;
            balances[i] = treasuryBalance;
        }

        currentCycle.treasuryTokenList = treasuryTokens;
        currentCycle.rewardTokenList = rewardTokens;

        emit CycleFinalized(_currentCycleId, uint128(block.timestamp), treasuryTokens, balances, rewardTokens, rewards);

        // Start new cycle
        $._currentCycleId = newCycleId;
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        $._cycles[newCycleId].startTime = startTime;
        $._cycles[newCycleId].endTime = endTime;

        emit CycleStarted(newCycleId, startTime, endTime, treasuryTokens, balances);
    }

    /**
     * @dev Claim reward
     */
    function claimReward() external override onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        uint256 prevCycleId = $._currentCycleId - 1;
        Cycle storage prevCycle = $._cycles[prevCycleId];
        
        uint256 userVotes = prevCycle.userVotes[msg.sender];
        require(userVotes != 0, NoRewardsToClaim());

        prevCycle.userVotes[msg.sender] = 0;
        uint256 totalVotes = prevCycle.totalVotes;
        address[] memory rewardTokenList = prevCycle.rewardTokenList;
        uint256 length = rewardTokenList.length;

        for (uint256 i = 0; i < length; i++) {
            address token = rewardTokenList[i];
            uint256 rewardBalance = prevCycle.rewardBalances[token];
            if(rewardBalance > 0) {
                uint256 rewardAmount = Math.mulDiv(rewardBalance, userVotes, totalVotes);
                if (rewardAmount > 0) {
                    prevCycle.rewardBalances[token] = rewardBalance - rewardAmount;
                    IERC20(token).safeTransfer(msg.sender, rewardAmount);
                    emit RewardClaimed(msg.sender, prevCycleId, token, rewardAmount);
                }
            }
        }
    }

    /**
     * @dev Accumulate cycle votes
     * @param user - The user address
     * @param votes - The number of votes
     */
    function accumCycleVotes(address user, uint256 votes) external override onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        uint256 _currentCycleId = $._currentCycleId;
        $._cycles[_currentCycleId].userVotes[user] += votes;
        $._cycles[_currentCycleId].totalVotes += votes;

        emit AccumCycleVotes(_currentCycleId, user, votes);
    }

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerTreasuryToken(address token) public override onlyGovernance {
        require(token != address(0),  ZeroInput());
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require(!$._treasuryTokens[token],  RegisteredToken());
        require($._treasuryTokenList.length < MAX_TOKENS_LIMIT, OutOfMaxTokensLimit());

        $._treasuryTokenList.push(token);
        $._treasuryTokens[token] = true;
        $._cycles[$._currentCycleId].treasuryBalances[token] = IERC20(token).balanceOf(address(this));

        emit TreasuryTokenRegistered(token);
    }

    /**
     * @dev Register for reward token，it MUST first be registered as a treasury token.
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerRewardToken(address token) public override onlyGovernance {
        require(token != address(0),  ZeroInput());
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require(!$._rewardTokens[token],  RegisteredToken());
        require($._treasuryTokens[token],  NonTreasuryToken());
        require($._rewardTokenList.length < MAX_TOKENS_LIMIT, OutOfMaxTokensLimit());

        $._rewardTokens[token] = true;
        $._rewardTokenList.push(token);

        emit RewardTokenRegistered(token);
    }

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterTreasuryToken(address token) external override onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require($._treasuryTokens[token], NonRegisteredToken());

        $._treasuryTokens[token] = false;
        $._cycles[$._currentCycleId].treasuryBalances[token] = 0;

        uint256 length = $._treasuryTokenList.length;
        for (uint256 i = 0; i < length; i++) {
            if ($._treasuryTokenList[i] == token) {
                $._treasuryTokenList[i] = $._treasuryTokenList[length - 1];
                $._treasuryTokenList.pop();
                break;
            }
        }
        
        // Unregister Reward Token
        if ($._rewardTokens[token]) _unregisterRewardToken(token);

        emit TreasuryTokenUnregistered(token);
    }

    /**
     * @dev Unregister for reward token
     * @param token - The token address
     */
    function unregisterRewardToken(address token) external override onlyGovernance {
        require(_getGovernanceCycleIncentivizerStorage()._rewardTokens[token], NonRegisteredToken());

        _unregisterRewardToken(token);

        emit RewardTokenUnregistered(token);
    }

    /**
     * @dev Update reward ratio
     * @param newRatio - The new reward ratio (basis points)
     */
    function updateRewardRatio(uint256 newRatio) external override onlyGovernance {
        require(newRatio <= RATIO, InvalidRewardRatio());
        
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        uint256 oldRatio = $._rewardRatio;
        $._rewardRatio = newRatio;

        emit RewardRatioUpdated(oldRatio, newRatio);
    }

    function _unregisterRewardToken(address token) internal {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();

        $._rewardTokens[token] = false;
        $._cycles[$._currentCycleId].rewardBalances[token] = 0;

        uint256 length = $._rewardTokenList.length;
        for (uint256 i = 0; i < length; i++) {
            if ($._rewardTokenList[i] == token) {
                $._rewardTokenList[i] = $._rewardTokenList[length - 1];
                $._rewardTokenList.pop();
                break;
            }
        }
    }

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}
