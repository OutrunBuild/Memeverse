// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

/// @notice Test helpers for the yield vault suite, kept mock-only (no test-file import).
/// @dev Implements the single-arg `burn(uint256)` shape the vault's burn path calls (solmate's MockERC20 only
///      exposes the two-arg `burn(address,uint256)`), so it doubles as a stand-in asset for burn-on-empty tests.
contract MockComposeAsset is MockERC20 {
    constructor() MockERC20("Compose Memecoin", "cMEME", 18) {}

    /// @notice Burns test tokens from the caller.
    /// @dev Used to satisfy the vault path that burns yield when no shares exist.
    /// @param amount The token amount to burn.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
