// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Self-consistent fake vault for the dispatcher's binding-passing forgery green path: reports the forged
///         token as its `asset()` so the MEMECOIN token↔vault binding passes (`TokenVaultMismatch` can never fire),
///         while both settle callbacks are no-ops — the forged settle succeeds entirely in the attacker's fake-token
///         space (exact approval on the fake token, own (token, guid) slot resolved) and no real token is ever
///         approved or pulled.
/// @dev Dispatcher-side counterpart of StakerTokenVaultBinding.t.sol's EvilVault closure (b)
///      (`evilVault.asset() == fake` passes the binding). Unlike AttackComposeToken — whose `asset()` is zero and
///      deliberately fails the binding — this mock is self-consistent: `asset()` returns the very token the forged
///      frame delivers, so the dispatcher approves only that token (exact amount) and settles the attacker's own
///      (token, guid) slot. The no-op callbacks mean the approval is never consumed; the isolation proof in the
///      test is the real token's untouched balance and zero allowance.
contract BindingPassingFakeVault {
    address public immutable assetToken;

    /// @param assetToken_ The forged token this vault reports as its underlying asset — the token the binding
    ///        compares against the delivered token.
    constructor(address assetToken_) {
        assetToken = assetToken_;
    }

    /// @notice Reports the underlying asset, which equals the forged token — the dispatcher's MEMECOIN binding passes.
    /// @return The forged token.
    function asset() external view returns (address) {
        return assetToken;
    }

    /// @notice No-op settle callback (MEMECOIN branch): nothing is pulled, keeping the forged settle confined to
    ///         fake-token approval bookkeeping.
    function accumulateYields(uint256) external pure {}

    /// @notice No-op settle callback (UASSET branch): kept for interface parity with the dispatcher's settle surface.
    function receiveTreasuryIncome(address, uint256) external pure {}
}
