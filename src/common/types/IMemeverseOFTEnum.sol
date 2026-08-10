// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IMemeverseOFTEnum {
    /// @dev Asset type that selects the cross-chain settlement route for an OFT payload.
    ///      `UASSET` = unified asset (Outrun UniversalAssets), the verse's funding token
    ///      (see GLOSSARY `uAsset`); routes settlement to the governor's treasury.
    ///      `MEMECOIN` = the verse's main memecoin; routes settlement to the yield vault.
    enum TokenType {
        UASSET,
        MEMECOIN
    }
}
