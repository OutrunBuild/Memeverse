// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunERC20Init} from "../../common/token/OutrunERC20Init.sol";

/// @title SplitterToken
/// @notice Base ERC20 for a verse's split tokens (see PrincipalToken/YieldToken). Mint and burn
///         are restricted to the deploying splitter (onlySplitter), which moves PT/YT supply to
///         mirror the verse's POL collateral.
contract SplitterToken is OutrunERC20Init {
    error PermissionDenied();
    error ZeroAddress();
    error ZeroInput();

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

    /// @notice Mints PT/YT to `to`. Reverts on zero amount to align with Memecoin/MemePol/GenesisCredit ZeroInput semantics (defense-in-depth; production splitter already guards zero).
    function mint(address to, uint256 amount) external onlySplitter {
        if (amount == 0) revert ZeroInput();
        _mint(to, amount);
    }

    /// @notice Burns PT/YT from `from`. Reverts on zero amount for cross-token consistency.
    function burn(address from, uint256 amount) external onlySplitter {
        if (amount == 0) revert ZeroInput();
        _burn(from, amount);
    }
}
