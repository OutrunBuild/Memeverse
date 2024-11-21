// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunOFT } from "./OutrunOFT.sol";
import { IMemecoin, IERC20 } from "./interfaces/IMemecoin.sol";

/**
 * @title Memecoin contract
 */
contract Memecoin is IMemecoin, OutrunOFT {
    address public memeverseLauncher;

    constructor(
        string memory _name, 
        string memory _symbol,
        uint8 _decimals, 
        address _memeverseLauncher, 
        address _lzEndpoint
    ) OutrunOFT(_name, _symbol, _decimals, _lzEndpoint, _memeverseLauncher) Ownable(_memeverseLauncher) {
        memeverseLauncher = _memeverseLauncher;
    }

    function mint(address account, uint256 amount) external override {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _mint(account, amount);
    }

    function burn(uint256 amount) external override {
        address msgSender = msg.sender;
        require(balanceOf[msgSender] >= amount, InsufficientBalance());
        _burn(msgSender, amount);
    }
}
