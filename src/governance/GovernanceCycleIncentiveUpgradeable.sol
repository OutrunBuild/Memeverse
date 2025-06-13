// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { GovernorUpgradeable } from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

import { IGovernanceCycleIncentive } from "./interfaces/IGovernanceCycleIncentive.sol";

/**
 * @dev Extension of {Governor} for governance cycle incentive.
 */
abstract contract GovernanceCycleIncentiveUpgradeable is IGovernanceCycleIncentive, Initializable, GovernorUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant RATIO = 10000;
    uint256 public constant CYCLE_DURATION = 90 days;
    uint256 public constant MAX_ACCEPTED_TOKENS = 20;

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.GovernanceCycleIncentive")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GovernanceCycleIncentiveStorageLocation = 0x173bbd0db440ff8dcb0efb05aced4279e21e45a07b4974973a371552ef840a00;

    function _getGovernanceCycleIncentiveStorage() private pure returns (GovernanceCycleIncentiveStorage storage $) {
        assembly {
            $.slot := GovernanceCycleIncentiveStorageLocation
        }
    }

    modifier onlyAcceptedToken(address token) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        require($._acceptedTokens[token], InvalidToken());
        _;
    }

    function __GovernanceCycleIncentive_init(address initFundToken) internal onlyInitializing {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        $._currentCycleId = 1;
        $._rewardRatio = 5000;
        $._cycles[1].startTime = block.timestamp;
        $._cycles[1].endTime = block.timestamp + CYCLE_DURATION;

        registerToken(initFundToken);

        emit CycleStarted(1, block.timestamp, block.timestamp + CYCLE_DURATION);
    }

    /**
     * @dev Get the specific token rewards claimable by the user for the previous cycle
     * @param user - The user address
     * @param token - The token address
     * @return The specific token rewards claimable by the user for the previous cycle
     */
    function getClaimableReward(address user, address token) external view override returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
     * @dev Get the treasury balance for the current cycle
     * @param token - The token address
     * @return The treasury balance for the current cycle
     */
    function getCurrentTreasuryBalance(address token) external view override returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        return $._cycles[$._currentCycleId].treasuryBalances[token];
    }

    /**
     * @dev Get all registered tokens' treasury balances for the current cycle
     * @return tokens - Tokens Array of token addresses
     * @return balances - Balances Array of corresponding treasury balances
     */
    function getCurrentTreasuryBalances() external view override returns (address[] memory tokens, uint256[] memory balances) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 length = $._acceptedTokenList.length;
        tokens = new address[](length);
        balances = new uint256[](length);
        uint256 currentCycleId = $._currentCycleId;

        for (uint256 i = 0; i < length; i++) {
            address token = $._acceptedTokenList[i];
            tokens[i] = token;
            balances[i] = $._cycles[currentCycleId].treasuryBalances[token];
        }
    }

    /**
     * @dev Get treasury balance for a specific cycle
     * @param cycleId - The cycle ID
     * @param token - The token address
     * @return The treasury balance for the specific cycle
     */
    function getTreasuryBalance(uint256 cycleId, address token) external view override returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        return $._cycles[cycleId].treasuryBalances[token];
    }

    /**
     * @dev Get all registered tokens' treasury balances for a specific cycle
     * @param cycleId - The cycle ID
     * @return tokens - Tokens Array of token addresses
     * @return balances - Balances Array of corresponding treasury balances
     */
    function getTreasuryBalances(uint256 cycleId) external view override returns (address[] memory tokens, uint256[] memory balances) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
    function receiveTreasuryIncome(address token, uint256 amount) external override onlyAcceptedToken(token) {
        require(token != address(0) && amount != 0, ZeroInput());

        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 currentCycleId = $._currentCycleId;
        $._cycles[currentCycleId].treasuryBalances[token] += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit TreasuryReceived(currentCycleId, token, msg.sender, amount);
    }

    /**
     * @dev Transfer treasury assets to another address
     * @param token - The token address
     * @param to - The receiver address
     * @param amount - The amount to transfer
     * @notice All actions to transfer assets from the DAO treasury MUST call this function
     */
    function sendTreasuryAssets(
        address token,
        address to,
        uint256 amount
    ) external override onlyGovernance onlyAcceptedToken(token) {
        require(token != address(0) && to != address(0) && amount != 0, ZeroInput());
        
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 currentCycleId = $._currentCycleId;
        Cycle storage currentCycle = $._cycles[currentCycleId];
        
        require(
            currentCycle.treasuryBalances[token] >= amount &&
            IERC20(token).balanceOf(address(this)) >= amount, 
            InsufficientTreasuryBalance()
        );

        currentCycle.treasuryBalances[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        
        emit TreasurySent(currentCycleId, token, to, amount);
    }

    /**
     * @dev End current cycle and start new cycle
     */
    function finalizeCurrentCycle() external override {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 currentCycleId = $._currentCycleId;
        uint256 newCycleId = currentCycleId + 1;
        Cycle storage currentCycle = $._cycles[currentCycleId];
        require(block.timestamp >= currentCycle.endTime, CycleNotEnded());

        // Process reward distribution
        Cycle storage prevCycle = $._cycles[currentCycleId - 1];
        uint256 length = $._acceptedTokenList.length;
        for (uint256 i = 0; i < length; i++) {
            address token = $._acceptedTokenList[i];
            uint256 prevRewardBalance = prevCycle.rewardBalances[token];

            // Transfer remaining reward balance to current cycle treasury
            uint256 treasuryBalance = currentCycle.treasuryBalances[token];
            if (prevRewardBalance > 0) {
                prevCycle.rewardBalances[token] = 0;
                treasuryBalance += prevRewardBalance;
                currentCycle.treasuryBalances[token] = treasuryBalance;
            }

            // Distribute reward
            if (treasuryBalance > 0) {
                uint256 rewardAmount = currentCycle.totalVotes == 0 ? 0 : (treasuryBalance * $._rewardRatio) / RATIO;
                if (rewardAmount != 0) {
                    currentCycle.rewardBalances[token] = rewardAmount;
                    treasuryBalance -= rewardAmount;
                }
                $._cycles[newCycleId].treasuryBalances[token] = treasuryBalance;
            }
        }

        emit CycleFinalized(currentCycleId);

        // Start new cycle
        $._currentCycleId++;
        $._cycles[newCycleId].startTime = block.timestamp;
        uint256 endTime = block.timestamp + CYCLE_DURATION;
        $._cycles[newCycleId].endTime = endTime;

        emit CycleStarted(newCycleId, block.timestamp, endTime);
    }

    /**
     * @dev Claim reward
     */
    function claimReward() external override {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
                if (rewardAmount == 0) continue;
                prevCycle.rewardBalances[token] -= rewardAmount;
                IERC20(token).safeTransfer(msg.sender, rewardAmount);
                emit RewardClaimed(msg.sender, prevCycleId, token, rewardAmount);
            }
        }
    }

    /**
     * @dev Register for receivable treasury token
     * @param token - The token address
     * @notice MUST confirm that the registered token is not a malicious token
     */
    function registerToken(address token) public override onlyGovernance {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        require($._acceptedTokenList.length < MAX_ACCEPTED_TOKENS, OutOfMaxAcceptedTokens());
        require(
            token != address(0) &&
            IERC20(token).totalSupply() > 0 &&
            !$._acceptedTokens[token], 
            InvalidToken()
        );

        $._acceptedTokens[token] = true;
        $._acceptedTokenList.push(token);

        emit TokenRegistered(token);
    }

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterToken(address token) external override onlyAcceptedToken(token) onlyGovernance {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
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
        
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 oldRatio = $._rewardRatio;
        $._rewardRatio = newRatio;

        emit RewardRatioUpdated(oldRatio, newRatio);
    }

    /**
     * @dev Accumulate cycle votes
     * @param user - The user address
     * @param votes - The number of votes
     */
    function _accumCycleVotes(address user, uint256 votes) internal {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 currentCycleId = $._currentCycleId;
        $._cycles[currentCycleId].userVotes[user] += votes;
        $._cycles[currentCycleId].totalVotes += votes;

        emit AccumCycleVotes(currentCycleId, user, votes);
    }
}
