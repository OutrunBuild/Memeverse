// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MemeverseTransientState
/// @notice Thin wrapper around transient storage used by Memeverse swap flows.
/// @dev Keeps raw `tstore` / `tload` isolated from hook business logic.
library MemeverseTransientState {
    /// @dev Swap context carried between a `beforeSwap` push and its matching `afterSwap` consume. The
    ///      principal is the sole context-presence marker: a `SwapContext` with `principal == address(0)`
    ///      is treated as absent (wrong-pool OR never-written), and consuming it does NOT decrement depth.
    struct SwapContext {
        uint256 encodedFeeBps;
        uint160 preSqrtPriceX96;
        uint256 coreTarget;
        address principal;
    }

    // Swap-context fields share one base slot per (poolId, depth); fields are deterministic offsets from it.
    // Mirrors Solidity's mapping-value struct layout: one keccak for collision resistance, offsets for sibling
    // fields. Saves a keccak256 per field per swap vs per-field tagging. fee sits at offset 0 (base itself),
    // price at offset 1, core target at offset 2, and principal at offset 3 — all four fields share the same
    // base, so no separate collision-domain tag is needed for principal: `base = keccak(TAG, poolId, depth) - 1`
    // is already uniform, and modular `add(base, 3)` preserves that uniformity (collision-equivalent to a
    // distinct tag while removing one keccak per push and one per consume).
    bytes32 private constant SWAP_CONTEXT_TAG = keccak256("mv.ts.swap.context");
    bytes32 private constant SWAP_CONTEXT_DEPTH_TAG = keccak256("mv.ts.swap.depth");
    // Active session principal. Single unkeyed slot: at most one session is active per hook per transaction.
    bytes32 private constant ACTIVE_PRINCIPAL_TAG = keccak256("mv.ts.activePrincipal");
    uint256 private constant OFFSET_PRICE = 1;
    uint256 private constant OFFSET_CORE_TARGET = 2;
    // Principal is the 4th field sharing the swap-context base; it is the sole context-presence marker.
    uint256 private constant OFFSET_PRINCIPAL = 3;

    // Per-pool swap-lifecycle reentrancy lock. A single bit is enough (acquire is exclusive), so the raw
    // keccak slot is used directly — no offset arithmetic, hence no -1 base adjustment.
    bytes32 private constant SWAP_LIFECYCLE_LOCK_TAG = keccak256("mv.ts.swap.lifecycle.lock");

    /// @dev Invariant: every push unconditionally writes offset 0 (encoded fee), offset 1 (pre-swap price),
    ///      offset 2 (transformed core target), AND principal at offset 3 of the SAME base slot, all at the
    ///      same `(poolId, depth)` tuple. `depth` is a single global per-tx LIFO counter (push +1 / consume -1),
    ///      NOT per-pool; the base slot is `keccak(TAG, poolId, depth) - 1`, so it recurs only when that exact
    ///      (poolId, depth) tuple recurs (a different pool at the same depth hashes to a different slot).
    ///      On a non-zero-principal match `consumeCurrentSwapContext` only decrements depth — it does NOT clear
    ///      any field. Leaving the four fields written after a match is safe for three independent reasons:
    ///      (1) any later reuse of the same `(poolId, depth)` tuple is preceded by a push that unconditionally
    ///      overwrites all four fields, so a stale value is never read out;
    ///      (2) a wrong-pool consume targets a different slot, because `_swapContextBaseSlot` mixes `poolId`
    ///      into the keccak — so it cannot read a foreign pool's leftover value at its own tuple;
    ///      (3) on the production path a consume miss is unreachable as a silent read: the only consumer
    ///      (`SwapFacet._loadAndValidateSwapContext`) reverts with `AccountSessionContextMissing` when principal is absent, so
    ///      no stale fee/price/core value can leak past a match gate. Transient storage also auto-clears at
    ///      transaction end, so leftover values never persist across transactions.
    function pushSwapContext(
        PoolId poolId,
        address principal,
        uint256 feeBps,
        uint160 preSqrtPriceX96,
        uint256 coreTarget
    ) internal {
        uint256 depth = _incrementSwapContextDepth();
        bytes32 base = _swapContextBaseSlot(poolId, depth);
        assembly {
            tstore(base, feeBps)
            tstore(add(base, OFFSET_PRICE), preSqrtPriceX96)
            tstore(add(base, OFFSET_CORE_TARGET), coreTarget)
            tstore(add(base, OFFSET_PRINCIPAL), principal)
        }
    }

    /// @dev Consumes the top-of-stack context for `expectedPoolId`. Returns a zero `SwapContext` (all
    ///      fields zero, principal == address(0)) and leaves depth unchanged when (a) depth is 0, or
    ///      (b) the `(expectedPoolId, depth)` tuple holds no principal (wrong-pool OR a zero-principal
    ///      push). Only when a non-zero principal is present does it decrement depth; it deliberately does
    ///      NOT clear the four fields (see the push-invariant note above for why leaving them written is
    ///      safe: push overwrites on reuse, wrong-pool targets a distinct slot, and a miss reverts on the
    ///      production path). The principal presence check is the single context-match signal, so a
    ///      wrong-pool consume is indistinguishable from a missing one — by design, this prevents a stale
    ///      or foreign context from leaking fee/price/core data into the matching afterSwap.
    function consumeCurrentSwapContext(PoolId expectedPoolId) internal returns (SwapContext memory context) {
        uint256 depth = _loadSwapContextDepth();
        if (depth == 0) return context;

        // Compute the base slot ONCE (mirrors `pushSwapContext`) instead of recomputing a keccak per field.
        // Slot addresses are byte-identical to `pushSwapContext`: `base` is offset 0 (encoded fee),
        // `base + OFFSET_PRICE` / `base + OFFSET_CORE_TARGET` / `base + OFFSET_PRINCIPAL` are the
        // price / core-target / principal siblings sharing the same base.
        bytes32 base = _swapContextBaseSlot(expectedPoolId, depth);
        address principal;
        uint256 encodedFeeBps;
        uint160 preSqrtPriceX96;
        uint256 coreTarget;
        assembly {
            principal := tload(add(base, OFFSET_PRINCIPAL))
        }
        // Sole context-match gate: no principal at this tuple ⇒ wrong pool OR never written. Do NOT clear,
        // do NOT decrement; return zero so the caller's own presence check surfaces the miss uniformly.
        if (principal == address(0)) return context;

        assembly {
            encodedFeeBps := tload(base)
            preSqrtPriceX96 := tload(add(base, OFFSET_PRICE))
            coreTarget := tload(add(base, OFFSET_CORE_TARGET))
        }
        context = SwapContext({
            encodedFeeBps: encodedFeeBps, preSqrtPriceX96: preSqrtPriceX96, coreTarget: coreTarget, principal: principal
        });
        _setSwapContextDepth(depth - 1);
    }

    /// @notice Returns the active session principal, or `address(0)` when no session is active.
    /// @dev `activePrincipal != address(0)` is the sole session-active marker (no separate flag word).
    function activePrincipal() internal view returns (address principal) {
        bytes32 slot = _activePrincipalSlot();
        assembly {
            principal := tload(slot)
        }
    }

    /// @notice Sets the active session principal. Called only by the hook's `beginAccountSession`.
    function setActivePrincipal(address principal) internal {
        bytes32 slot = _activePrincipalSlot();
        assembly ("memory-safe") {
            tstore(slot, principal)
        }
    }

    /// @notice Clears the active session principal. Called only by the hook's `endAccountSession`.
    function clearActivePrincipal() internal {
        bytes32 slot = _activePrincipalSlot();
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Returns the current swap-context stack depth (push +1 / consume-on-match -1).
    function swapContextDepth() internal view returns (uint256 depth) {
        return _loadSwapContextDepth();
    }

    /// @dev Acquires the per-pool swap-lifecycle reentrancy lock. Returns whether the lock was already held;
    ///      the caller decides the revert error (the library stays a pure logic shim). Acquired in three places:
    ///      `SwapFacet.beforeSwapLogic` (after `_revertIfPublicSwapBlocked`),
    ///      `SettlementFacet.executeSettlementLogic` (before the Phase 1 transferFrom), and
    ///      `MemeverseUniswapHook._addLiquidityCore` (before the recipient fee snapshot), and released in their
    ///      matching exit points (`SwapFacet.afterSwapLogic`, `SettlementFacet.executeSettlementLogic` tail,
    ///      `MemeverseUniswapHook._addLiquidityCore` after the LP mint and `cachedLpTotalSupply` update).
    ///      Blocks a callback token (ERC-777/1363) from reentering `poolManager.swap` on the SAME poolId
    ///      during the outer swap's lifecycle window, which would advance `dynamicFeeState` while the outer
    ///      swap still settles with the stale fee quoted at its start. On the liquidity-add window the same
    ///      block keeps per-share LP fee growth (`fee0PerShare`/`fee1PerShare`) frozen between the recipient
    ///      snapshot and the LP mint, so minted shares cannot crystallize fees accrued before they existed.
    ///      Returns a bool instead of reverting so the meaningful error (`SwapLifecycleReentrant`) can live on
    ///      the hook interface where errors are centralized.
    function acquireSwapLifecycleLock(PoolId poolId) internal returns (bool alreadyLocked) {
        bytes32 slot = _swapLifecycleLockSlot(poolId);
        assembly ("memory-safe") {
            alreadyLocked := tload(slot)
            if iszero(alreadyLocked) { tstore(slot, 1) }
        }
    }

    /// @dev Releases the per-pool lock acquired in beforeSwapLogic / executeSettlementLogic /
    ///      `MemeverseUniswapHook._addLiquidityCore`. Paired 1:1 with acquire. Transient storage auto-clears at
    ///      tx end, so a revert between acquire and release leaves no stale lock.
    function releaseSwapLifecycleLock(PoolId poolId) internal {
        bytes32 slot = _swapLifecycleLockSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    function _swapLifecycleLockSlot(PoolId poolId) private pure returns (bytes32 slot) {
        return keccak256(abi.encode(SWAP_LIFECYCLE_LOCK_TAG, PoolId.unwrap(poolId)));
    }

    function _activePrincipalSlot() private pure returns (bytes32) {
        return bytes32(uint256(ACTIVE_PRINCIPAL_TAG) - 1);
    }

    function _loadSwapContextDepth() private view returns (uint256 depth) {
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly {
            depth := tload(depthSlot)
        }
    }

    function _setSwapContextDepth(uint256 depth) private {
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly ("memory-safe") {
            tstore(depthSlot, depth)
        }
    }

    function _incrementSwapContextDepth() private returns (uint256 depth) {
        bytes32 depthSlot = _swapContextDepthSlot();
        assembly ("memory-safe") {
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
