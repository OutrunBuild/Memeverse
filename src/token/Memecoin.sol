// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemecoin } from "./interfaces/IMemecoin.sol";
import { OutrunOFTInit } from "../common/layerzero/oft/OutrunOFTInit.sol";

/**
 * @title Omnichain Memecoin
 */
contract Memecoin is IMemecoin, OutrunOFTInit {
    address public memeverseLauncher;

    function initialize(
        string memory name_, 
        string memory symbol_,
        uint8 decimals_, 
        address _memeverseLauncher, 
        address _lzEndpoint,
        address _delegate
    ) external override initializer {
        __OutrunOFT_init(name_, symbol_, decimals_, _lzEndpoint, _delegate);
        __OutrunOwnable_init(_delegate);

        memeverseLauncher = _memeverseLauncher;
    }

    function mint(address account, uint256 amount) external override {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _mint(account, amount);
    }

    function burn(uint256 amount) external override {
        address msgSender = msg.sender;
        require(balanceOf(msgSender) >= amount, InsufficientBalance());
        _burn(msgSender, amount);
    }
}
