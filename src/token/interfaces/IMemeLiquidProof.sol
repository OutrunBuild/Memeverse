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
     * @notice Initialize the memecoin liquidProof.
     * @param name_ - The name of the memecoin liquidProof.
     * @param symbol_ - The symbol of the memecoin liquidProof.
     * @param memecoin_ - The address of the memecoin.
     * @param memeverseLauncher_ - The address of the memeverse launcher.
     * @param delegate_ - The address of the OFT delegate.
     */
    function initialize(
        string memory name_, 
        string memory symbol_, 
        address memecoin_, 
        address memeverseLauncher_,
        address delegate_
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
}