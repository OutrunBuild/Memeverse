// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MemeverseTransientState} from "../../../src/swap/libraries/MemeverseTransientState.sol";

/// @title TransientStateHarness
/// @notice Executes swap-context sequences within one transaction for transient-state regression tests.
/// @dev Thin wrapper over the `MemeverseTransientState` library. Transient storage is scoped per-contract,
///      so every field read/written here lives in THIS harness's transient namespace — it is independent of
///      the hook proxy's transient store. Library-level regression tests use this harness to exercise the
///      push/consume/lock primitives in isolation from the hook callback path.
contract TransientStateHarness {
    // -----------------------------------------------------------------
    // Direct wrappers (new): expose every library primitive so tests can call them with arbitrary args.
    // -----------------------------------------------------------------

    /// @notice Reads the active session principal.
    function activePrincipal() external view returns (address) {
        return MemeverseTransientState.activePrincipal();
    }

    /// @notice Writes the active session principal.
    function setActivePrincipal(address principal) external {
        MemeverseTransientState.setActivePrincipal(principal);
    }

    /// @notice Clears the active session principal.
    function clearActivePrincipal() external {
        MemeverseTransientState.clearActivePrincipal();
    }

    /// @notice Reads the current swap-context stack depth.
    function swapContextDepth() external view returns (uint256) {
        return MemeverseTransientState.swapContextDepth();
    }

    /// @notice Thin wrapper over the 5-arg `pushSwapContext` so tests can push arbitrary principal/fee/price/core.
    function pushSwapContextDirect(
        PoolId poolId,
        address principal,
        uint256 feeBps,
        uint160 preSqrtPriceX96,
        uint256 coreTarget
    ) external {
        MemeverseTransientState.pushSwapContext(poolId, principal, feeBps, preSqrtPriceX96, coreTarget);
    }

    /// @notice Thin wrapper over `consumeCurrentSwapContext` returning the full `SwapContext` struct.
    function consumeCurrentSwapContextDirect(PoolId poolId)
        external
        returns (MemeverseTransientState.SwapContext memory context)
    {
        return MemeverseTransientState.consumeCurrentSwapContext(poolId);
    }

    // -----------------------------------------------------------------
    // Adapted scenario wrappers: push/consume sequences with a non-zero principal so the presence check works.
    // -----------------------------------------------------------------

    /// @notice Pops one same-pool context before pushing and consuming its replacement.
    function samePoolPopThenPush(
        PoolId poolId,
        address account,
        uint256 firstFee,
        uint160 firstPrice,
        uint256 firstCoreTarget,
        uint256 secondFee,
        uint160 secondPrice,
        uint256 secondCoreTarget
    )
        external
        returns (
            uint256 consumedFirstFee,
            uint160 consumedFirstPrice,
            uint256 consumedFirstCoreTarget,
            uint256 consumedSecondFee,
            uint160 consumedSecondPrice,
            uint256 consumedSecondCoreTarget
        )
    {
        MemeverseTransientState.pushSwapContext(poolId, account, firstFee, firstPrice, firstCoreTarget);
        MemeverseTransientState.SwapContext memory first = MemeverseTransientState.consumeCurrentSwapContext(poolId);
        consumedFirstFee = first.encodedFeeBps;
        consumedFirstPrice = first.preSqrtPriceX96;
        consumedFirstCoreTarget = first.coreTarget;

        MemeverseTransientState.pushSwapContext(poolId, account, secondFee, secondPrice, secondCoreTarget);
        MemeverseTransientState.SwapContext memory second = MemeverseTransientState.consumeCurrentSwapContext(poolId);
        consumedSecondFee = second.encodedFeeBps;
        consumedSecondPrice = second.preSqrtPriceX96;
        consumedSecondCoreTarget = second.coreTarget;
    }

    /// @notice Pops nested contexts in last-in-first-out order when the pools differ.
    function nestedDifferentPools(
        PoolId outerPoolId,
        PoolId innerPoolId,
        address account,
        uint256 outerFee,
        uint160 outerPrice,
        uint256 outerCoreTarget,
        uint256 innerFee,
        uint160 innerPrice,
        uint256 innerCoreTarget
    )
        external
        returns (
            uint256 consumedInnerFee,
            uint160 consumedInnerPrice,
            uint256 consumedInnerCoreTarget,
            uint256 consumedOuterFee,
            uint160 consumedOuterPrice,
            uint256 consumedOuterCoreTarget
        )
    {
        MemeverseTransientState.pushSwapContext(outerPoolId, account, outerFee, outerPrice, outerCoreTarget);
        MemeverseTransientState.pushSwapContext(innerPoolId, account, innerFee, innerPrice, innerCoreTarget);

        MemeverseTransientState.SwapContext memory inner =
            MemeverseTransientState.consumeCurrentSwapContext(innerPoolId);
        consumedInnerFee = inner.encodedFeeBps;
        consumedInnerPrice = inner.preSqrtPriceX96;
        consumedInnerCoreTarget = inner.coreTarget;
        MemeverseTransientState.SwapContext memory outer =
            MemeverseTransientState.consumeCurrentSwapContext(outerPoolId);
        consumedOuterFee = outer.encodedFeeBps;
        consumedOuterPrice = outer.preSqrtPriceX96;
        consumedOuterCoreTarget = outer.coreTarget;
    }

    /// @notice Preserves separately encoded fee modes across a pop and replacement push.
    function popThenPushMode(PoolId poolId, address account, uint256 firstEncodedFee, uint256 secondEncodedFee)
        external
        returns (uint256 consumedFirstFee, uint256 consumedSecondFee)
    {
        MemeverseTransientState.pushSwapContext(poolId, account, firstEncodedFee, 1, 11);
        consumedFirstFee = MemeverseTransientState.consumeCurrentSwapContext(poolId).encodedFeeBps;

        MemeverseTransientState.pushSwapContext(poolId, account, secondEncodedFee, 2, 22);
        consumedSecondFee = MemeverseTransientState.consumeCurrentSwapContext(poolId).encodedFeeBps;
    }

    /// @notice Confirms a popped context is unreachable through the public library API.
    function consumeAfterPop(PoolId poolId, address account, uint256 fee, uint160 price)
        external
        returns (uint256 emptyFee, uint160 emptyPrice, uint256 emptyCoreTarget)
    {
        MemeverseTransientState.pushSwapContext(poolId, account, fee, price, 123);
        MemeverseTransientState.consumeCurrentSwapContext(poolId);
        MemeverseTransientState.SwapContext memory empty = MemeverseTransientState.consumeCurrentSwapContext(poolId);
        return (empty.encodedFeeBps, empty.preSqrtPriceX96, empty.coreTarget);
    }

    // -----------------------------------------------------------------
    // Per-pool swap-lifecycle lock wrappers (unchanged).
    // -----------------------------------------------------------------

    /// @notice One acquire; returns whether the lock was already held.
    function acquireOnce(PoolId poolId) external returns (bool alreadyLocked) {
        return MemeverseTransientState.acquireSwapLifecycleLock(poolId);
    }

    /// @notice Two acquires on the same pool; second should see alreadyLocked.
    function acquireTwiceSamePool(PoolId poolId) external returns (bool firstAlreadyLocked, bool secondAlreadyLocked) {
        firstAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolId);
        secondAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolId);
    }

    /// @notice Acquire, release, then acquire again; after release the lock is free.
    function acquireReleaseAcquire(PoolId poolId) external returns (bool firstAlreadyLocked, bool secondAlreadyLocked) {
        firstAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolId);
        MemeverseTransientState.releaseSwapLifecycleLock(poolId);
        secondAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolId);
    }

    /// @notice Locks are per-pool: acquiring pool A does not lock pool B.
    function acquireTwoPools(PoolId poolIdA, PoolId poolIdB)
        external
        returns (bool aAlreadyLocked, bool bAlreadyLocked)
    {
        aAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolIdA);
        bAlreadyLocked = MemeverseTransientState.acquireSwapLifecycleLock(poolIdB);
    }
}
