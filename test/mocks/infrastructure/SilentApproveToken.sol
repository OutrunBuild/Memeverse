// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title SilentApproveToken
/// @notice ERC-20-shaped stub whose `approve` returns no data, modeling non-standard tokens that omit
///         the `bool` return value. Callers must treat the empty returndata as success only because
///         the address carries code.
contract SilentApproveToken {
    address public lastApproveSpender;
    uint256 public lastApproveValue;

    /// @notice Records the approval request and deliberately returns nothing.
    /// @param spender Spender passed through by the caller.
    /// @param value Amount passed through by the caller.
    function approve(address spender, uint256 value) external {
        lastApproveSpender = spender;
        lastApproveValue = value;
    }
}
