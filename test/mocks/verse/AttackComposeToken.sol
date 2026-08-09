// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @dev Attacker-controlled token contract: implements approve plus the settle callbacks and reports a mismatching
///      `asset()` so a forged settle with an attacker-controlled token is intercepted by the dispatcher's MEMECOIN
///      token↔vault binding (`TokenVaultMismatch` — `asset()` = 0 never equals the forged token) before any approve
///      or callback; used by the forged-token mutex regression test. The compose mutex must still key on the real
///      bridged token address rather than the guid alone: even a forged settle that passes the binding (a fake vault
///      reporting the fake token as its asset) resolves only the attacker's own (token, guid) slot, leaving the real
///      pair untouched.
contract AttackComposeToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    /// @notice Reports the underlying asset this mock vault would settle; deliberately never matches the forged token
    ///         so the dispatcher's binding reverts with the named `TokenVaultMismatch` instead of an empty-data revert.
    /// @return address Zero, which can never equal the attacker's forged token address.
    function asset() external view returns (address) {
        return address(0);
    }

    function accumulateYields(uint256) external pure {}

    function receiveTreasuryIncome(address, uint256) external pure {}
}
