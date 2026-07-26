// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MemeverseTransientState
/// @notice Thin wrapper around transient storage used by Memeverse swap flows.
/// @dev Keeps raw `tstore` / `tload` isolated from hook business logic.
library MemeverseTransientState {
    // Swap-context fields share one base slot per (poolId, depth); fields are deterministic offsets from it.
    // Mirrors Solidity's mapping-value struct layout: one keccak for collision resistance, offsets for sibling
    // fields. Saves a keccak256 per field per swap vs per-field tagging. fee sits at offset 0 (base itself).
    bytes32 private constant SWAP_CONTEXT_TAG = keccak256("mv.ts.swap.context");
    bytes32 private constant SWAP_CONTEXT_DEPTH_TAG = keccak256("mv.ts.swap.depth");
    uint256 private constant OFFSET_PRICE = 1;
    uint256 private constant OFFSET_CORE_TARGET = 2;

    // Per-pool swap-lifecycle reentrancy lock. A single bit is enough (acquire is exclusive), so the raw
    // keccak slot is used directly — no offset arithmetic, hence no -1 base adjustment.
    bytes32 private constant SWAP_LIFECYCLE_LOCK_TAG = keccak256("mv.ts.swap.lifecycle.lock");

    /// @dev Invariant: every push unconditionally overwrites offset 0 with the encoded fee, offset 1 with the
    ///      pre-swap price, and offset 2 with the transformed core target. `depth` is a single global per-tx
    ///      LIFO counter (push +1 / consume -1), NOT per-pool; the base slot is `keccak(TAG, poolId, depth)`,
    ///      so the same slot recurs only when that exact (poolId, depth) tuple recurs (a different pool at
    ///      the same depth hashes to a different slot). Two properties keep `consumeCurrentSwapContext` safe
    ///      without zeroing fields: (1) v4 pairs each beforeSwap with its afterSwap, so a consume always
    ///      reads the offsets its own swap's push just wrote; (2) before a slot is reused, encoded fee,
    ///      pre-swap price, and core target are all unconditionally overwritten. Any future optimization
    ///      that makes any of these writes conditional must also clear all three offsets.
    function pushSwapContext(PoolId poolId, uint256 feeBps, uint160 preSqrtPriceX96, uint256 coreTarget) internal {
        uint256 depth = _incrementSwapContextDepth();
        bytes32 base = _swapContextBaseSlot(poolId, depth);
        assembly {
            tstore(base, feeBps)
            tstore(add(base, OFFSET_PRICE), preSqrtPriceX96)
            tstore(add(base, OFFSET_CORE_TARGET), coreTarget)
        }
    }

    function consumeCurrentSwapContext(PoolId poolId)
        internal
        returns (uint256 feeBps, uint160 preSqrtPriceX96, uint256 coreTarget)
    {
        uint256 depth = _loadSwapContextDepth();
        if (depth == 0) return (0, 0, 0);

        bytes32 base = _swapContextBaseSlot(poolId, depth);
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly {
            let priceSlot := add(base, OFFSET_PRICE)
            feeBps := tload(base)
            preSqrtPriceX96 := tload(priceSlot)
            coreTarget := tload(add(base, OFFSET_CORE_TARGET))
            // Consuming only decrements the global LIFO depth. Encoded fee, pre-price, and core target at
            // offsets 0/1/2 are intentionally not cleared: this read targets its matching push, and a later
            // reuse of the same (poolId, depth) tuple unconditionally overwrites all three offsets.
            tstore(depthSlot, sub(depth, 1))
        }
    }

    /// @dev Acquires the per-pool swap-lifecycle reentrancy lock. Returns whether the lock was already held;
    ///      the caller decides the revert error (the library stays a pure logic shim). Acquired in two places:
    ///      `SwapFacet.beforeSwapLogic` (after `_revertIfPublicSwapBlocked`) and
    ///      `SettlementFacet.executeSettlementLogic` (before the Phase 1 transferFrom), and released in their
    ///      matching exit points (`SwapFacet.afterSwapLogic`, `SettlementFacet.executeSettlementLogic` tail).
    ///      Blocks a callback token (ERC-777/1363) from reentering `poolManager.swap` on the SAME poolId
    ///      during the outer swap's lifecycle window, which would advance `dynamicFeeState` while the outer
    ///      swap still settles with the stale fee quoted at its start. Returns a bool instead of reverting so
    ///      the meaningful error (`SwapLifecycleReentrant`) can live on the hook interface where errors are
    ///      centralized.
    function acquireSwapLifecycleLock(PoolId poolId) internal returns (bool alreadyLocked) {
        bytes32 slot = _swapLifecycleLockSlot(poolId);
        assembly ("memory-safe") {
            alreadyLocked := tload(slot)
            if iszero(alreadyLocked) { tstore(slot, 1) }
        }
    }

    /// @dev Releases the per-pool lock acquired in beforeSwapLogic / executeSettlementLogic. Paired 1:1 with
    ///      acquire. Transient storage auto-clears at tx end, so a revert between acquire and release leaves no
    ///      stale lock.
    function releaseSwapLifecycleLock(PoolId poolId) internal {
        bytes32 slot = _swapLifecycleLockSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    function _swapLifecycleLockSlot(PoolId poolId) private pure returns (bytes32 slot) {
        return keccak256(abi.encode(SWAP_LIFECYCLE_LOCK_TAG, PoolId.unwrap(poolId)));
    }

    function _loadSwapContextDepth() private view returns (uint256 depth) {
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly {
            depth := tload(depthSlot)
        }
    }

    function _incrementSwapContextDepth() private returns (uint256 depth) {
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly {
            depth := add(tload(depthSlot), 1)
            tstore(depthSlot, depth)
        }
    }

    function _swapContextDepthSlot() private pure returns (bytes32) {
        return bytes32(uint256(SWAP_CONTEXT_DEPTH_TAG) - 1);
    }

    function _swapContextBaseSlot(PoolId poolId, uint256 depth) private pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(SWAP_CONTEXT_TAG, PoolId.unwrap(poolId), depth))) - 1);
    }
}
