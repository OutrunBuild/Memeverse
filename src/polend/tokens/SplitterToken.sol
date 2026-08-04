// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunERC20Init} from "../../common/token/OutrunERC20Init.sol";

contract SplitterToken is OutrunERC20Init {
    error PermissionDenied();
    error ZeroAddress();

    address public splitter;

    modifier onlySplitter() {
        if (msg.sender != splitter) revert PermissionDenied();
        _;
    }

    function initialize(string calldata name_, string calldata symbol_, address splitter_) external initializer {
        if (splitter_ == address(0)) revert ZeroAddress();
        __OutrunERC20_init(name_, symbol_);
        splitter = splitter_;
    }

    function mint(address to, uint256 amount) external onlySplitter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlySplitter {
        _burn(from, amount);
    }
}
