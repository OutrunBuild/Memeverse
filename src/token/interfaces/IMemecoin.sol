// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin interface
 */
interface IMemecoin is IERC20 {
    function memeverse() external view returns (address);

    function transferable() external view returns (bool);

    function enableTransfer() external;

    function addTransferWhiteList(address account) external;

    function mint(address account, uint256 amount) external;

    function burn(uint256 amount) external;

    error PermissionDenied();

    error TransferNotEnable();

    error InsufficientBalance();

    error AlreadyEnableTransfer();
}