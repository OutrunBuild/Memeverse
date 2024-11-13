// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemecoin, IERC20 } from "./interfaces/IMemecoin.sol";

/**
 * @title Memecoin contract
 */
contract Memecoin is IMemecoin {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    address public memeverseLauncher;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory _name, 
        string memory _symbol,
        uint8 _decimals, 
        address _memeverseLauncher
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        memeverseLauncher = _memeverseLauncher;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        address msgSender = msg.sender;
        _transfer(msgSender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);

        return true;
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

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        if (to == address(0)) {
            unchecked {
                totalSupply -= amount;
            }
        }

        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;

        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}
