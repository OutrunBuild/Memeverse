//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin Proof Of Liquidity(POL) Token Interface
 */
interface IMemeLiquidProof is IERC20 {
    /**
     * @notice Get the memeverse launcher.
     * @return memeverseLauncher - The address of the memeverse launcher.
     */
    function memeverseLauncher() external view returns (address);

    /**
     * @notice Initialize the memeverse proof.
     * @param _name - The name of the memeverse proof.
     * @param _symbol - The symbol of the memeverse proof.
     * @param _decimals - The decimals of the memeverse proof.
     * @param _memecoin - The address of the memecoin.
     * @param _memeverseLauncher - The address of the memeverse launcher.
     */
    function initialize(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals, 
        address _memecoin, 
        address _memeverseLauncher
    ) external;

    /**
     * @notice Mint the memeverse proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memeverse proof.
     */
    function mint(address account, uint256 amount) external;

    /**
     * @notice Burn the memeverse proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memeverse proof.
     */
    function burn(address account, uint256 amount) external;

    /**
     * @notice Permission denied.
     */
    error PermissionDenied();

    /**
     * @notice Insufficient balance.
     */
    error InsufficientBalance();

    event MemeLiquidProofFlashLoan(address receiver, uint256 value, uint256 fee, bytes data);
}