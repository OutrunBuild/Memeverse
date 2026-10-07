// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {OutrunSafeERC20} from "./OutrunSafeERC20.sol";

abstract contract TokenHelper is ReentrancyGuardTransient {
    using OutrunSafeERC20 for IERC20;

    address internal constant NATIVE = address(0);

    error NativeValueMismatch(uint256 expected, uint256 actual);
    error NativeTransferFailed();
    error NativeTransferToZeroAddress();
    error SafeApproveFailed(address token, address spender, uint256 value);
    error TransferFromNotCaller(address from, address caller);

    /// @notice Single entry point for all inbound token pulls (ERC20 `safeTransferFrom`, native `msg.value`).
    /// @dev Unlike `_transferOut`, this inbound pull carries no `nonReentrant`: `safeTransferFrom` is an
    ///      external call, so a token with transfer hooks (ERC-777 / ERC-1363 style callbacks) could re-enter
    ///      the caller before its effects are complete. Inbound reentrancy safety therefore rests on the trust
    ///      precondition that every asset pulled in here is a plain ERC20 without transfer hooks — a
    ///      per-asset precondition.
    ///      All pulls are caller-funded: `from` must equal `msg.sender`, otherwise reverts.
    function _transferIn(address token, address from, uint256 amount) internal {
        if (from != msg.sender) revert TransferFromNotCaller(from, msg.sender);
        if (token == NATIVE) require(msg.value == amount, NativeValueMismatch(amount, msg.value));
        else if (amount != 0) IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    /// @notice Single exit point for all outbound token transfers.
    /// @dev `nonReentrant` here is the centralized reentrancy defense for contracts using TokenHelper.
    ///      Entry-point functions in these contracts intentionally omit `nonReentrant` to avoid double-locking
    ///      with ReentrancyGuardTransient: its transient `bool` lock (not a counter) cannot be acquired twice
    ///      in the same transaction, so a caller-level `nonReentrant` would hold the lock for the whole outer
    ///      call and make every nested `_transferOut` revert with `ReentrancyGuardReentrantCall`.
    ///      Note the lock is released when `_transferOut` returns, so the inter-call window between two
    ///      `_transferOut`s is NOT covered by this lock — defense across that gap relies on the caller's own
    ///      CEI ordering, not on this modifier.
    ///      The native branch also rejects a zero-address recipient: a CALL to the codeless zero address
    ///      always succeeds, so without that guard a sweep whose receiver was mistakenly set to the zero
    ///      address would permanently send the contract's entire native balance there.
    function _transferOut(address token, address to, uint256 amount) internal nonReentrant {
        if (amount == 0) return;
        if (token == NATIVE) {
            if (to == address(0)) revert NativeTransferToZeroAddress();
            (bool success,) = to.call{value: amount}("");
            require(success, NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Sets allowance for `to` on `token` using a low-level approve call.
    /// @dev Returndata trust rule is single-sourced in `OutrunSafeERC20._safeApprove`: empty returndata
    ///      is only trusted when the token has code, since a CALL to an EOA succeeds with empty data and
    ///      would otherwise be a false-positive approve. Keeps the richer revert context.
    function _safeApprove(address token, address to, uint256 value) internal {
        if (!OutrunSafeERC20._safeApprove(IERC20(token), to, value)) revert SafeApproveFailed(token, to, value);
    }
}
