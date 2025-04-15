// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin interface
 */
interface IMemecoin is IERC20 {
    /**
     * @notice Get the memeverse launcher.
     * @return memeverseLauncher - The address of the memeverse launcher.
     */
    function memeverseLauncher() external view returns (address);

    /**
     * @notice Initialize the memecoin.
     * @param name_ - The name of the memecoin.
     * @param symbol_ - The symbol of the memecoin.
     * @param decimals_ - The decimals of the memecoin.
     * @param _memeverseLauncher - The address of the memeverse launcher.
     * @param _lzEndpoint - The address of the LayerZero endpoint.
     * @param _delegate - The address of the delegate.
     */
    function initialize(
        string memory name_, 
        string memory symbol_,
        uint8 decimals_, 
        address _memeverseLauncher, 
        address _lzEndpoint,
        address _delegate
    ) external;

    /**
     * @notice Mint the memecoin.
     * @param account - The address of the account.
     * @param amount - The amount of the memecoin.
     */
    function mint(address account, uint256 amount) external;

    /**
     * @notice Burn the memecoin.
     * @param amount - The amount of the memecoin.
     */
    function burn(uint256 amount) external;

    /**
     * @notice Insufficient balance.
     */
    error InsufficientBalance();
}