// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {BurnableMockERC20Base} from "../common/BurnableMockERC20Base.sol";

/// @notice Test helpers for the yield vault suite, kept mock-only (no test-file import).
/// @dev Implements the single-arg `burn(uint256)` shape the vault's burn path calls (solmate's MockERC20 only
///      exposes the two-arg `burn(address,uint256)`), so it doubles as a stand-in asset for burn-on-empty tests.
contract MockComposeAsset is BurnableMockERC20Base {
    constructor() BurnableMockERC20Base("Compose Memecoin", "cMEME", 18, BurnMode.Plain) {}
}
