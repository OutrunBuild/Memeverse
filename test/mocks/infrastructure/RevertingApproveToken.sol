// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title RevertingApproveToken
/// @notice ERC-20-shaped stub whose `approve` always fails with empty revert data, modeling a
///         code-bearing token whose approval path reverts without a payload. The empty payload is
///         the point: it makes this failure indistinguishable from a code-less address except by
///         the CALL success flag, which is exactly the flag under test.
contract RevertingApproveToken {
    /// @notice Deliberately fails with no revert payload. Parameters are accepted positionally and
    ///         never read, mirroring the ERC-20 approve signature without implementing it.
    function approve(address, uint256) external pure {
        revert();
    }
}
