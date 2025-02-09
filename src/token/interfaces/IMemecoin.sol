// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin interface
 */
interface IMemecoin is IERC20 {
    function memeverseLauncher() external view returns (address);

    function initialize(
        string memory _name, 
        string memory _symbol,
        uint8 _decimals, 
        address _memeverseLauncher, 
        address _lzEndpoint,
        address _delegate
    ) external;

    function mint(address account, uint256 amount) external;

    function burn(uint256 amount) external;

    error PermissionDenied();

    error InsufficientBalance();
}