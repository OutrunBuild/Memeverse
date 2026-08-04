// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IGovernanceCycleIncentivizer} from "../../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";

/// @notice ERC20-shaped reward token that attempts a second claim during transfer.
contract ReentrantRewardToken {
    mapping(address account => uint256) internal balances;

    address public claimTarget;
    bool public reenter;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    function setClaimTarget(address target) external {
        claimTarget = target;
    }

    function setReenter(bool enabled) external {
        reenter = enabled;
    }

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;

        if (reenter) {
            reenter = false;
            callbackAttempted = true;
            (callbackSucceeded,) = claimTarget.call(abi.encodeCall(IGovernanceCycleIncentivizer.claimReward, ()));
        }

        return true;
    }
}
