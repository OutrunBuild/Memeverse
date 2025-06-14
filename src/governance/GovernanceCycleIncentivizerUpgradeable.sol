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
    uint256 public constant MAX_ACCEPTED_TOKENS = 20;

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.GovernanceCycleIncentivizer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GovernanceCycleIncentivizerStorageLocation = 0x173bbd0db440ff8dcb0efb05aced4279e21e45a07b4974973a371552ef840a00;

    function _getGovernanceCycleIncentivizerStorage() private pure returns (GovernanceCycleIncentivizerStorage storage $) {
        assembly {
            $.slot := GovernanceCycleIncentivizerStorageLocation
        }
    }

    function __GovernanceCycleIncentivizer_init(address governor, address[] calldata initFundTokens) internal onlyInitializing {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        $._currentCycleId = 1;
        $._rewardRatio = 5000;
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        $._cycles[1].startTime = startTime;
        $._cycles[1].endTime = endTime;
        $._governor = governor;

        uint256 length = initFundTokens.length;
        address[] memory tokens = new address[](length);
        uint256[] memory balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = initFundTokens[i];
            registerToken(token);
            tokens[i] = token;
        }

        emit CycleStarted(1, startTime, endTime, tokens, balances);
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
        uint256 currentCycleId, 
        uint256 rewardRatio, 
        address governor, 
        address[] memory acceptedTokenList
    ) {
        currentCycleId = _getGovernanceCycleIncentivizerStorage()._currentCycleId;
        rewardRatio = _getGovernanceCycleIncentivizerStorage()._rewardRatio;
        governor = _getGovernanceCycleIncentivizerStorage()._governor;
        acceptedTokenList = _getGovernanceCycleIncentivizerStorage()._acceptedTokenList;
    }

    /**
     * @dev Get cycle meta info
     */
    function cycleInfo(uint256 cycleId) external view override returns (
        uint128 startTime, 
        uint128 endTime, 
        uint256 totalVotes
    ) {
        Cycle storage cycle = _getGovernanceCycleIncentivizerStorage()._cycles[cycleId];
        startTime = cycle.startTime;
        endTime = cycle.endTime;
        totalVotes = cycle.totalVotes;
    }

    /**
     * @dev Get user votes count
     */
    function getUserVotesCount(address user, uint256 cycleId) external view override returns (uint256) {
        return _getGovernanceCycleIncentivizerStorage()._cycles[cycleId].userVotes[user];
    }

    /**
     * @dev Check accepted token
     */
    function isAcceptedToken(address token) external view override returns (bool) {
        return _getGovernanceCycleIncentivizerStorage()._acceptedTokens[token];
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
            uint256 length = $._acceptedTokenList.length;
            tokens = new address[](length);
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                address token = $._acceptedTokenList[i];
                tokens[i] = token;
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
            uint256 length = $._acceptedTokenList.length;
            tokens = new address[](length);
            rewards = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                address token = $._acceptedTokenList[i];
                tokens[i] = token;
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
        uint256 length = $._acceptedTokenList.length;
        tokens = new address[](length);
        balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = $._acceptedTokenList[i];
            tokens[i] = token;
            balances[i] = $._cycles[cycleId].treasuryBalances[token];
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
        require($._acceptedTokens[token], InvalidToken());

        // Record
        uint256 currentCycleId = $._currentCycleId;
        $._cycles[currentCycleId].treasuryBalances[token] += amount;

        emit TreasuryReceived(currentCycleId, token, msg.sender, amount);
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
        require($._acceptedTokens[token], InvalidToken());

        uint256 currentCycleId = $._currentCycleId;
        Cycle storage currentCycle = $._cycles[currentCycleId];
        uint256 currentBalance = currentCycle.treasuryBalances[token];
        
        require(
            currentBalance >= amount &&
            IERC20(token).balanceOf($._governor) >= amount, 
            InsufficientTreasuryBalance()
        );

        // Record
        currentCycle.treasuryBalances[token] = currentBalance - amount;
        
        emit TreasurySent(currentCycleId, token, to, amount);
    }

    /**
     * @dev End current cycle and start new cycle
     */
    function finalizeCurrentCycle() external override {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        uint256 currentCycleId = $._currentCycleId;
        uint256 newCycleId = currentCycleId + 1;
        Cycle storage currentCycle = $._cycles[currentCycleId];
        require(block.timestamp >= currentCycle.endTime, CycleNotEnded());

        // Process reward distribution
        Cycle storage prevCycle = $._cycles[currentCycleId - 1];
        uint256 length = $._acceptedTokenList.length;
        address[] memory tokens = new address[](length);
        uint256[] memory balances = new uint256[](length);
        uint256[] memory rewards = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = $._acceptedTokenList[i];

            // Transfer remaining reward balance to current cycle treasury
            uint256 prevRewardBalance = prevCycle.rewardBalances[token];
            uint256 treasuryBalance = currentCycle.treasuryBalances[token];
            if (prevRewardBalance > 0) {
                prevCycle.rewardBalances[token] = 0;
                treasuryBalance += prevRewardBalance;
                currentCycle.treasuryBalances[token] = treasuryBalance;
            }

            // Distribute reward
            uint256 rewardAmount;
            if (treasuryBalance > 0 && currentCycle.totalVotes > 0) {
                rewardAmount = treasuryBalance * $._rewardRatio / RATIO;
                currentCycle.rewardBalances[token] = rewardAmount;
                treasuryBalance -= rewardAmount;
                $._cycles[newCycleId].treasuryBalances[token] = treasuryBalance;
            }

            tokens[i] = token;
            balances[i] = treasuryBalance;
            rewards[i] = rewardAmount;
        }

        emit CycleFinalized(currentCycleId, uint128(block.timestamp), tokens, balances, rewards);

        // Start new cycle
        $._currentCycleId++;
        uint128 startTime = uint128(block.timestamp);
        uint128 endTime = uint128(block.timestamp + CYCLE_DURATION);
        $._cycles[newCycleId].startTime = startTime;
        $._cycles[newCycleId].endTime = endTime;

        emit CycleStarted(newCycleId, startTime, endTime, tokens, balances);
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
        uint256 length = $._acceptedTokenList.length;

        for (uint256 i = 0; i < length; i++) {
            address token = $._acceptedTokenList[i];
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
        uint256 currentCycleId = $._currentCycleId;
        $._cycles[currentCycleId].userVotes[user] += votes;
        $._cycles[currentCycleId].totalVotes += votes;

        emit AccumCycleVotes(currentCycleId, user, votes);
    }

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerToken(address token) public override onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require($._acceptedTokenList.length < MAX_ACCEPTED_TOKENS, OutOfMaxAcceptedTokens());
        require(token != address(0) && IERC20(token).totalSupply() > 0 &&! $._acceptedTokens[token],  InvalidToken());

        $._acceptedTokens[token] = true;
        $._acceptedTokenList.push(token);

        emit TokenRegistered(token);
    }

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterToken(address token) external override onlyGovernance {
        GovernanceCycleIncentivizerStorage storage $ = _getGovernanceCycleIncentivizerStorage();
        require($._acceptedTokens[token], InvalidToken());

        $._acceptedTokens[token] = false;
        uint256 length = $._acceptedTokenList.length;
        for (uint256 i = 0; i < length; i++) {
            if ($._acceptedTokenList[i] == token) {
                $._acceptedTokenList[i] = $._acceptedTokenList[length - 1];
                $._acceptedTokenList.pop();
                break;
            }
        }

        emit TokenUnregistered(token);
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

    /**
     * @dev Allowing upgrades to the implementation contract only through governance proposals.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}
