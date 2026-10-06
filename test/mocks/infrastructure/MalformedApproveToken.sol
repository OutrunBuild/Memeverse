// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title MalformedApproveToken
/// @notice ERC-20-shaped stub whose `approve` executes successfully but returns non-empty returndata
///         that is not 32 bytes long, modeling tokens that return a malformed payload. Because the
///         payload is non-empty, the trust-rule ternary takes the `abi.decode(data, (bool))` branch
///         and the decoder's own failure is what reaches the caller.
contract MalformedApproveToken {
    address public lastApproveSpender;
    uint256 public lastApproveValue;

    /// @notice Records the approval request, then returns a raw 4-byte payload (0x00000001).
    /// @dev A high-level `return` would ABI-encode the value into a 32-byte slot, so the short
    ///      payload must be produced in assembly. Four bytes is non-empty (so the decode branch is
    ///      taken) yet too short to decode as a `bool`, which needs exactly 32 bytes.
    /// @param spender Spender passed through by the caller.
    /// @param value Amount passed through by the caller.
    function approve(address spender, uint256 value) external {
        lastApproveSpender = spender;
        lastApproveValue = value;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 1))
            return(0x00, 4)
        }
    }
}
