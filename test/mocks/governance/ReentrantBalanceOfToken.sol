// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IGovernanceCycleIncentivizer} from "../../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";

/// @notice ERC20-shaped treasury token that attempts a cycle finalize whenever its balance is read.
contract ReentrantBalanceOfToken {
    mapping(address account => uint256) internal balances;

    address public incentivizer;
    bool public reenter;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    function setIncentivizer(address target) external {
        incentivizer = target;
    }

    function setReenter(bool enabled) external {
        reenter = enabled;
    }

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
    }

    function balanceOf(address account) external returns (uint256) {
        // The caller (incentivizer) must already be past the cycle endTime so the finalize succeeds.
        if (reenter) {
            reenter = false;
            callbackAttempted = true;
            (callbackSucceeded,) =
                incentivizer.call(abi.encodeCall(IGovernanceCycleIncentivizer.finalizeCurrentCycle, ()));
        }
        return balances[account];
    }
}
