// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Outrun omnichain universal assets interface
 * @notice Universal assets keep a per-minter minted-debt ledger: both `mint` and `repay` book the
 *         outstanding minted amount against the caller (`msg.sender`), never against `receiver`
 *         or `account`. Mint rights are granted per minter by the asset's registration and
 *         governance, not open to arbitrary callers.
 */
interface IUniversalAssets {
    /// @notice Mints `amount` to `receiver` and books it as the caller's outstanding minted debt.
    /// @dev Permissioned mint: only minters holding the right granted by the asset's registration
    ///      and governance may call; other callers revert.
    /// @param receiver Address receiving the newly minted tokens.
    /// @param amount Amount to mint.
    function mint(address receiver, uint256 amount) external;

    /// @notice Burns `amount` from `account`'s balance and reduces the caller's outstanding minted
    ///         debt by the same amount; the debt owner is `msg.sender`, never `account`.
    /// @dev burnFrom-style semantics: when `account != msg.sender`, an allowance of at least
    ///      `amount` granted by `account` to `msg.sender` is required and consumed; when
    ///      `account == msg.sender` no allowance is needed. Reverts when `account`'s balance,
    ///      the required allowance, or the caller's outstanding minted debt is insufficient.
    /// @param account Address whose tokens are burned.
    /// @param amount Amount to burn and subtract from the caller's minted debt.
    function repay(address account, uint256 amount) external;
}
