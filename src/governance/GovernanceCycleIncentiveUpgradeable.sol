// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

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

    function __GovernanceCycleIncentive_init() internal onlyInitializing {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        $._currentCycleId = 1;
        $._rewardRatio = 5000;
        $._cycles[1].startTime = block.timestamp;
        $._cycles[1].endTime = block.timestamp + CYCLE_DURATION;

        emit CycleStarted(1, block.timestamp, block.timestamp + CYCLE_DURATION);
    }

    /**
     * @dev Get the rewards claimable by the user for the previous cycle
     * @param token - The token address
     * @return The rewards claimable by the user for the previous cycle
     */
    function getClaimableReward(address token) external view returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 prevCycleId = $._currentCycleId - 1;
        Cycle storage prevCycle = $._cycles[prevCycleId];
        
        uint256 totalVotes = prevCycle.totalVotes;
        uint256 userVotes = prevCycle.userVotes[msg.sender];
        uint256 rewardBalance = prevCycle.rewardBalances[token];
        if (totalVotes == 0 || userVotes == 0 || rewardBalance == 0) return 0;

        return rewardBalance * userVotes / totalVotes;
    }
    
    /**
     * @dev Get the treasury balance for the current cycle
     * @param token - The token address
     * @return The treasury balance for the current cycle
     */
    function getCurrentTreasuryBalance(address token) external view returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        return $._cycles[$._currentCycleId].treasuryBalances[token];
    }

    /**
     * @dev Get treasury balance for a specific cycle
     * @param cycleId - The cycle ID
     * @param token - The token address
     * @return The treasury balance for the specific cycle
     */
    function getTreasuryBalance(uint256 cycleId, address token) external view returns (uint256) {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        return $._cycles[cycleId].treasuryBalances[token];
    }

    /**
     * @dev Receive treasury income
     * @param token - The token address
     * @param amount - The amount
     */
    function receiveTreasuryIncome(address token, uint256 amount) external onlyAcceptedToken(token) {
        require(token != address(0) && amount != 0, ZeroInput());

        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 _currentCycleId = $._currentCycleId;
        $._cycles[_currentCycleId].treasuryBalances[token] += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit TreasuryReceived(_currentCycleId, token, msg.sender, amount);
    }

    /**
     * @dev Transfer treasury assets to another address
     * @param token - The token address
     * @param to - The receiver address
     * @param amount - The amount to transfer
     * @notice All actions to transfer assets from the DAO treasury MUST call this function
     */
    function sendTreasuryAssets(address token,address to,uint256 amount) external onlyGovernance onlyAcceptedToken(token) {
        require(token != address(0) && to != address(0) && amount != 0, ZeroInput());
        
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 _currentCycleId = $._currentCycleId;
        Cycle storage currentCycle = $._cycles[_currentCycleId];
        
        require(currentCycle.treasuryBalances[token] >= amount, InsufficientTreasuryBalance());

        currentCycle.treasuryBalances[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        
        emit TreasurySent(_currentCycleId, token, to, amount);
    }

    /**
     * @dev End current cycle and start new cycle
     */
    function finalizeCurrentCycle() external {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 _currentCycleId = $._currentCycleId;
        uint256 newCycleId = _currentCycleId + 1;
        Cycle storage currentCycle = $._cycles[_currentCycleId];
        require(block.timestamp >= currentCycle.endTime, CycleNotEnded());

        // Process reward distribution
        Cycle storage prevCycle = $._cycles[_currentCycleId - 1];
        for (uint256 i = 0; i < $._acceptedTokenList.length; i++) {
            address token = $._acceptedTokenList[i];
            uint256 prevRewardBalance = prevCycle.rewardBalances[token];

            // Transfer remaining reward balance to current cycle treasury
            uint256 treasuryBalance = currentCycle.treasuryBalances[token];
            if (prevRewardBalance > 0) {
                prevCycle.rewardBalances[token] = 0;
                treasuryBalance += prevRewardBalance;
                currentCycle.treasuryBalances[token] = treasuryBalance;
            }

            // Distribute reward to users
            if (treasuryBalance > 0) {
                uint256 rewardAmount = currentCycle.totalVotes == 0 ? 0 : (treasuryBalance * $._rewardRatio) / RATIO;
                if (rewardAmount != 0) {
                    currentCycle.rewardBalances[token] = rewardAmount;
                    treasuryBalance -= rewardAmount;
                }
                $._cycles[newCycleId].treasuryBalances[token] = treasuryBalance;
            }
        }

        emit CycleFinalized(_currentCycleId);

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
    function claimReward() external {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        uint256 prevCycleId = $._currentCycleId - 1;
        Cycle storage prevCycle = $._cycles[prevCycleId];
        
        uint256 userVotes = prevCycle.userVotes[msg.sender];
        require(userVotes != 0, NoRewardsToClaim());

        prevCycle.userVotes[msg.sender] = 0;

        for (uint256 i = 0; i < $._acceptedTokenList.length; i++) {
            address token = $._acceptedTokenList[i];
            uint256 rewardBalance = prevCycle.rewardBalances[token];
            if(rewardBalance > 0) {
                uint256 rewardAmount = rewardBalance * userVotes / prevCycle.totalVotes;
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
    function registerToken(address token) external onlyGovernance {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        require(token != address(0) && !$._acceptedTokens[token], InvalidToken());
        
        $._acceptedTokens[token] = true;
        $._acceptedTokenList.push(token);

        emit TokenRegistered(token);
    }

    /**
     * @dev Unregister for receivable treasury token
     * @param token - The token address
     */
    function unregisterToken(address token) external onlyAcceptedToken(token) onlyGovernance {
        GovernanceCycleIncentiveStorage storage $ = _getGovernanceCycleIncentiveStorage();
        $._acceptedTokens[token] = false;
        for (uint256 i = 0; i < $._acceptedTokenList.length; i++) {
            if ($._acceptedTokenList[i] == token) {
                $._acceptedTokenList[i] = $._acceptedTokenList[$._acceptedTokenList.length - 1];
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
    function updateRewardRatio(uint256 newRatio) external onlyGovernance {
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
        uint256 _currentCycleId = $._currentCycleId;
        $._cycles[_currentCycleId].userVotes[user] += votes;
        $._cycles[_currentCycleId].totalVotes += votes;

        emit AccumCycleVotes(_currentCycleId, user, votes);
    }
}
