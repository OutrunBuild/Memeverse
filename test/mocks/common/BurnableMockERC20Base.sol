// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IBurnable} from "../../../src/common/interfaces/IBurnable.sol";

/// @notice Shared single-arg `burn(uint256)` semantics for MockERC20-derived test tokens.
/// @dev solmate's MockERC20 only exposes the two-arg `burn(address,uint256)`; the production burn paths
///      (vault, launcher liquidity, dispatcher) call the single-arg shape. This base centralizes the four
///      variants that used to be copy-pasted across module-local mocks (plain / accumulate / zero-guard /
///      no-op), so a behavior change to one variant no longer silently diverges from the others. Implements
///      `IBurnable` so subclasses that need the interface (staker/dispatcher mocks) avoid a same-signature
///      conflict between the base implementation and the interface declaration.
abstract contract BurnableMockERC20Base is MockERC20, IBurnable {
    /// @notice Single-arg burn variant, fixed at construction time.
    enum BurnMode {
        Plain, // burn moves tokens with no extras
        Accumulate, // burn also records the total in `burnedAmount`
        ZeroGuard, // burn reverts on a zero amount
        NoOp // burn accepts the amount and moves nothing
    }

    BurnMode internal immutable burnMode;

    /// @notice Total amount burned via the single-arg path (Accumulate mode).
    uint256 public burnedAmount;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, BurnMode burnMode_)
        MockERC20(name_, symbol_, decimals_)
    {
        burnMode = burnMode_;
    }

    /// @notice Burns test tokens from the caller, with the variant behavior chosen at construction.
    /// @param amount The token amount to burn.
    function burn(uint256 amount) external virtual {
        if (burnMode == BurnMode.NoOp) return;
        if (burnMode == BurnMode.ZeroGuard) require(amount != 0, "zero");
        if (burnMode == BurnMode.Accumulate) burnedAmount += amount;
        _burn(msg.sender, amount);
    }
}
