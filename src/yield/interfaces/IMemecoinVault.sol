// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IERC20 } from "../../common/OutrunERC20Init.sol";

interface IMemecoinVault is IERC20 {
    struct RedeemRequest {
        uint192 amount;     // Requested redeem amount
        uint64 requestTime; // Time when the redeem request was made
    }

    function asset() external view returns (address assetTokenAddress);

    function totalAssets() external view returns (uint256 totalManagedAssets);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function initialize(
        string memory _name, 
        string memory _symbol,
        address _asset,
        address _memeverseLauncher,
        uint256 _verseId
    ) external;

    function accumulateYields(uint256 amount) external;

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function requestRedeem(uint256 shares, address receiver) external returns (uint256 assets);

    function executeRedeem() external returns (uint256 redeemedAmount);


    event AccumulateYields(address indexed yieldSource, uint256 amount);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event RedeemRequested(
        address indexed sender, 
        address indexed receiver, 
        uint256 assets, 
        uint256 shares, 
        uint256 requestTime
    );

    event RedeemExecuted(address indexed receiver, uint256 amount);


    error ZeroAddresss();

    error ZeroRedeemRequest();

    error MaxRedeemRequestsReached();
}
