// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IMemecoinDaoGovernor} from "../../../src/governance/interfaces/IMemecoinDaoGovernor.sol";

/// @title MockIncentivizerGovernor
/// @notice Stand-in governor that receives reward disburseals from the cycle incentivizer for tests.
contract MockIncentivizerGovernor {
    address public incentivizer;
    address public lastRewardToken;
    address public lastRewardTo;
    uint256 public lastRewardAmount;

    /// @notice Set incentivizer.
    /// @param _incentivizer See implementation.
    function setIncentivizer(address _incentivizer) external {
        incentivizer = _incentivizer;
    }

    /// @notice Disburse reward.
    /// @param token See implementation.
    /// @param to See implementation.
    /// @param amount See implementation.
    function disburseReward(address token, address to, uint256 amount) external {
        require(msg.sender == incentivizer, "not incentivizer");
        lastRewardToken = token;
        lastRewardTo = to;
        lastRewardAmount = amount;
        MockERC20(token).transfer(to, amount);
    }

    /// @notice Accepts treasury-token registration callbacks from the incentivizer.
    /// @param token Registered treasury token.
    function recordTreasuryTokenRegistration(address token) external {
        token;
    }
}

/// @title MockGovernorVotesToken
/// @notice Minimal IVotes implementation with configurable per-account vote balances for governance tests.
contract MockGovernorVotesToken is IVotes {
    mapping(address => uint256) internal votes;
    uint256 internal totalSupplyVotes = 1_000 ether;

    /// @notice Set votes.
    /// @param account See implementation.
    /// @param amount See implementation.
    function setVotes(address account, uint256 amount) external {
        votes[account] = amount;
    }

    /// @notice Get votes.
    /// @param account See implementation.
    /// @return See implementation.
    function getVotes(address account) external view returns (uint256) {
        return votes[account];
    }

    /// @notice Get past votes.
    /// @param account See implementation.
    /// @param timepoint See implementation.
    /// @return See implementation.
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        timepoint;
        return votes[account];
    }

    /// @notice Get past total supply.
    /// @param timepoint See implementation.
    /// @return See implementation.
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        timepoint;
        return totalSupplyVotes;
    }

    /// @notice Delegates.
    /// @param account See implementation.
    /// @return See implementation.
    function delegates(address account) external pure returns (address) {
        return account;
    }

    /// @notice Delegate.
    /// @param delegatee See implementation.
    function delegate(address delegatee) external pure {
        delegatee;
    }

    /// @notice Delegate by sig.
    /// @param delegatee See implementation.
    /// @param nonce See implementation.
    /// @param expiry See implementation.
    /// @param v See implementation.
    /// @param r See implementation.
    /// @param s See implementation.
    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        external
        pure
    {
        delegatee;
        nonce;
        expiry;
        v;
        r;
        s;
    }

    /// @notice Clock.
    /// @dev Timestamp domain, matching the production votes clock so governor tests drive the same
    ///      ERC-6372 timepoint semantics the real governance token uses.
    /// @return See implementation.
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice Clock mode.
    /// @return See implementation.
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }
}

/// @title MockGovernorIncentivizer
/// @notice Records governance-cycle-incentivizer callbacks so governor tests can assert inputs.
contract MockGovernorIncentivizer {
    address public lastReceiveToken;
    uint256 public lastReceiveAmount;
    uint256 public lastReceiveGovernorBalance;
    address public lastSentToken;
    address public lastSentTo;
    uint256 public lastSentAmount;
    uint256 public lastSentGovernorBalance;
    address public lastVoteAccount;
    uint256 public lastVoteAmount;
    address public pairedGovernor;
    address[] public treasuryTokens;

    /// @notice Set the paired governor used by registration callbacks.
    /// @param _governor Governor address.
    function setGovernor(address _governor) external {
        pairedGovernor = _governor;
    }

    /// @notice Set treasury tokens.
    /// @param tokens See implementation.
    function setTreasuryTokens(address[] memory tokens) external {
        treasuryTokens = tokens;
    }

    /// @notice Register a treasury token and notify the paired governor.
    /// @param token Treasury token address.
    function registerTreasuryToken(address token) external {
        require(msg.sender == pairedGovernor, "not paired governor");
        treasuryTokens.push(token);
        IMemecoinDaoGovernor(pairedGovernor).recordTreasuryTokenRegistration(token);
    }

    /// @notice Meta data.
    /// @return currentCycleId See implementation.
    /// @return rewardRatio See implementation.
    /// @return pairedGovernorAddress See implementation.
    /// @return treasuryTokenList See implementation.
    /// @return rewardTokenList See implementation.
    function metaData()
        external
        view
        returns (
            uint128 currentCycleId,
            uint128 rewardRatio,
            address pairedGovernorAddress,
            address[] memory treasuryTokenList,
            address[] memory rewardTokenList
        )
    {
        return (0, 0, pairedGovernor, treasuryTokens, new address[](0));
    }

    /// @notice Record treasury income.
    /// @param token See implementation.
    /// @param amount See implementation.
    function recordTreasuryIncome(address token, uint256 amount) external {
        lastReceiveToken = token;
        lastReceiveAmount = amount;
        lastReceiveGovernorBalance = MockERC20(token).balanceOf(msg.sender);
    }

    /// @notice Record treasury asset spend.
    /// @param token See implementation.
    /// @param to See implementation.
    /// @param amount See implementation.
    function recordTreasuryAssetSpend(address token, address to, uint256 amount) external {
        lastSentToken = token;
        lastSentTo = to;
        lastSentAmount = amount;
        lastSentGovernorBalance = MockERC20(token).balanceOf(msg.sender);
    }

    /// @notice Accum cycle votes.
    /// @param account See implementation.
    /// @param votes See implementation.
    function accumCycleVotes(address account, uint256 votes) external {
        lastVoteAccount = account;
        lastVoteAmount = votes;
    }
}
