// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice Single source of the cross-chain send error shared by interfaces whose implementations run the same
///         pre-send truncate-to-zero guard: `IMemeverseOmnichainInteroperation` (staking path) and
///         `IMemeverseLauncher` (fee-distribution path). Declared once here so a one-sided rename or parameter
///         change becomes a compile-time failure instead of silently diverging the runtime revert data from the
///         interface ABI — mirrors the single-sourcing convention already established by `IComposeState` for the
///         composer-lifecycle errors. `DustAmount()` lives outside `IComposeState` because that interface owns the
///         composer-lifecycle (lzCompose / settlePendingCompose) error domain, whereas this error belongs to the
///         source-side pre-send guard domain.
interface ICrossChainSendErrors {
    /// @dev Reverted before a cross-chain OFT send when the amount is so small that OFT dust-removal
    ///      (`_removeDust`) truncates it to zero in shared decimals. Sending it would burn nothing, deliver a
    ///      zero-amount compose, strand the full amount at the sender contract (no sweep/withdraw), and charge the
    ///      full LayerZero fee for a zero-position result. Only the truncate-to-ZERO case is rejected; the two
    ///      paths differ in how they handle the non-zero remainder (`amount >= decimalConversionRate` but
    ///      `amount % decimalConversionRate != 0`):
    ///        - Staking path (`MemeverseOmnichainInteroperation.memecoinStaking` / `quoteMemecoinStaking`)
    ///          refunds the un-burnt remainder (`amount - amountSentLD`) to the caller on the source chain, so
    ///          nothing strands.
    ///        - Fee-distribution path (`MemeverseSettlementImpl._sendRedeemedFeesCrossChain`) accepts the
    ///          non-zero remainder as the documented dust-stranding trade-off, since fee amounts are
    ///          protocol-computed (swap-fee accumulation).
    ///      The selector (`0x1d25e4d7`) is unchanged from the two former standalone declarations: Solidity error
    ///      selectors derive purely from the signature, so consolidating the declaration does not alter runtime
    ///      revert data.
    error DustAmount();
}
