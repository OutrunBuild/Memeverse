// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {OutrunSafeERC20} from "../../common/token/OutrunSafeERC20.sol";
import {IERC20} from "../../common/token/OutrunERC20Init.sol";

/// @title CurrencySettler
/// @notice Production helper for settling and taking PoolManager deltas.
/// @dev Mirrors the standard Uniswap v4 settle/take behavior without depending on upstream test utilities.
library CurrencySettler {
    error ERC20TransferFromFailed(address payer, address manager, uint256 amount);
    error ERC20TransferFailed(address manager, uint256 amount);
    error ZeroAddress();

    /// @notice Settles an amount owed to the PoolManager.
    /// @param currency The currency being settled.
    /// @param manager The pool manager receiving settlement.
    /// @param payer The address paying the amount.
    /// @param amount The amount to settle.
    /// @param burn If true, burns ERC-6909 balance instead of transferring ERC20/native.
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                require(
                    IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount),
                    ERC20TransferFromFailed(payer, address(manager), amount)
                );
            } else {
                require(
                    IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount),
                    ERC20TransferFailed(address(manager), amount)
                );
            }
            manager.settle();
        }
    }

    /// @notice Takes an amount owed from the PoolManager.
    /// @param currency The currency being taken.
    /// @param manager The pool manager paying out.
    /// @param recipient The address receiving the payout.
    /// @param amount The amount to receive.
    /// @param claims If true, mints ERC-6909 claim tokens instead of transferring out underlying currency.
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }

    /// @notice Transfers ERC20 `currency` to `to`, reverting on zero-address recipient or transfer failure.
    /// @dev Guards (amount==0 early-return, to==0 revert) plus OutrunSafeERC20.safeTransfer, which handles
    ///      non-compliant ERC20s that return no bool. Shared by Hook and Router (CI-010).
    function transferWithGuard(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) revert ZeroAddress();
        OutrunSafeERC20.safeTransfer(IERC20(Currency.unwrap(currency)), to, amount);
    }
}
