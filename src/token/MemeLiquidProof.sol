// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { OutrunOFTInit } from "../common/layerzero/oft/OutrunOFTInit.sol";
import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";

/**
 * @title Omnichain Memeverse Proof Of Liquidity Token
 */
contract MemeLiquidProof is IMemeLiquidProof, OutrunOFTInit {
    address public memecoin;
    address public memeverseLauncher;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    function initialize(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals, 
        address _memecoin, 
        address _memeverseLauncher,
        address _lzEndpoint,
        address _delegate
    ) external override initializer {
        __OutrunOFT_init(_name, _symbol, _decimals, _lzEndpoint, _delegate);
        __OutrunOwnable_init(_delegate);

        memecoin = _memecoin;
        memeverseLauncher = _memeverseLauncher;
    }
    
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyMemeverseLauncher {
        require(balanceOf[account] >= amount, InsufficientBalance());
        _burn(account, amount);
    }
}
