// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {OutrunSafeERC20} from "./OutrunSafeERC20.sol";

abstract contract TokenHelper is ReentrancyGuardTransient {
    using OutrunSafeERC20 for IERC20;

    address internal constant NATIVE = address(0);
    uint256 internal constant LOWER_BOUND_APPROVAL = type(uint96).max / 2; // some tokens use 96 bits for approval

    error NativeValueMismatch(uint256 expected, uint256 actual);
    error NativeTransferFailed();
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
    function _transferOut(address token, address to, uint256 amount) internal nonReentrant {
        if (amount == 0) return;
        if (token == NATIVE) {
            (bool success,) = to.call{value: amount}("");
            require(success, NativeTransferFailed());
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Sets allowance for `to` on `token` using a low-level approve call.
    /// @dev Some tokens require resetting allowance to zero before updating to a new value.
    ///      Empty returndata is only trusted when the token has code (mirrors OutrunSafeERC20
    ///      _safeTransfer/_safeTransferFrom extcodesize guard). A CALL to an EOA succeeds with
    ///      empty data and would otherwise be a false-positive approve.
    function _safeApprove(address token, address to, uint256 value) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, to, value));
        require(
            success && (data.length == 0 ? token.code.length > 0 : abi.decode(data, (bool))),
            SafeApproveFailed(token, to, value)
        );
    }

    function _safeApproveInf(address token, address to) internal {
        if (token == NATIVE) return;
        // Cache once. When current allowance is already 0, the reset-to-0 call below would be a
        // same-value no-op external call (~2k gas wasted on a redundant CALL + Approval event), so
        // skip it. USDT-style tokens only need the reset on non-zero -> non-zero; 0 -> max never does.
        uint256 currentAllowance = IERC20(token).allowance(address(this), to);
        if (currentAllowance < LOWER_BOUND_APPROVAL) {
            if (currentAllowance != 0) _safeApprove(token, to, 0);
            _safeApprove(token, to, type(uint256).max);
        }
    }
}
