// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenHelper} from "../../../src/common/token/TokenHelper.sol";

contract TokenHelperHarness is TokenHelper {
    function transferInNative(uint256 amount) external payable {
        _transferIn(NATIVE, msg.sender, amount);
    }

    function transferInERC20(address token, address from, uint256 amount) external {
        _transferIn(token, from, amount);
    }

    function transferOutNative(address to, uint256 amount) external payable {
        _transferOut(NATIVE, to, amount);
    }

    function transferOutERC20(address token, address to, uint256 amount) external {
        _transferOut(token, to, amount);
    }

    function safeApproveToken(address token, address spender, uint256 value) external {
        _safeApprove(token, spender, value);
    }

    function safeApproveInf(address token, address spender) external {
        _safeApproveInf(token, spender);
    }

    function transferFrom(address token, address from, address to, uint256 amount) external {
        _transferFrom(IERC20(token), from, to, amount);
    }

    receive() external payable {}
}
