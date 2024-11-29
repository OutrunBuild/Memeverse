// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IERC20 } from "../../common/ERC20.sol";

interface IMemecoinVault is IERC20 {
    function asset() external view returns (address assetTokenAddress);

    function totalAssets() external view returns (uint256 totalManagedAssets);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function accumulateYields(uint256 amount) external;

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver) external returns (uint256 assets);

    event AccumulateYields(address indexed yieldSource, uint256 amount);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
}
