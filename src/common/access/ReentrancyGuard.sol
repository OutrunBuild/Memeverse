// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Outrun's ReentrancyGuard implementation, support transient variable.
 */
abstract contract ReentrancyGuard {
    // transient = EIP-1153 transient storage: values are only valid within the current
    // transaction and auto-clear when it ends, so the reentrancy lock never leaks across
    // transactions and needs no manual reset in _nonReentrantAfter (the reset only guards
    // against reentry within the same transaction).
    bool private transient locked;
    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (locked) revert ReentrancyGuardReentrantCall();
        locked = true;
    }

    function _nonReentrantAfter() private {
        locked = false;
    }
}
