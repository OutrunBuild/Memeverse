// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Outrun's ReentrancyGuard implementation, support transient variable.
 */
abstract contract ReentrancyGuard {
    // transient = EIP-1153 瞬态存储：值仅在当前交易内有效，交易结束自动清零，
    // 因此重入锁不会跨交易泄漏，也无需在 _nonReentrantAfter 中手动复位（复位仅为同一交易内重入保护）。
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
