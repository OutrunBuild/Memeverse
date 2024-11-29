// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { OutrunOFT } from "./OutrunOFT.sol";
import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";

/**
 * @title Omnichain Memeverse Liquidity Proof Token
 */
contract MemeLiquidProof is IMemeLiquidProof, OutrunOFT {
    address public immutable memecoin;
    address public immutable memeverseLauncher;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    constructor(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals, 
        address _memecoin, 
        address _memeverseLauncher,
        address _lzEndpoint,
        address _delegate
    ) OutrunOFT(_name, _symbol, _decimals, _lzEndpoint, _delegate) Ownable(_delegate) {
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
