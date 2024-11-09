//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memeverse Liquidity proof Token Interface
 */
interface IMemeLiquidProof is IERC20 {
    function memeverse() external view returns (address);

    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;

    error PermissionDenied();

    error InsufficientBalance();
}