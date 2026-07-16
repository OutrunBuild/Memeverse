// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MemeverseTransientState} from "../../../src/swap/libraries/MemeverseTransientState.sol";

/// @title TransientStateHarness
/// @notice Executes swap-context sequences within one transaction for transient-state regression tests.
contract TransientStateHarness {
    /// @notice Pops one same-pool context before pushing and consuming its replacement.
    function samePoolPopThenPush(
        PoolId poolId,
        uint256 firstFee,
        uint160 firstPrice,
        uint256 secondFee,
        uint160 secondPrice
    )
        external
        returns (
            uint256 consumedFirstFee,
            uint160 consumedFirstPrice,
            uint256 consumedSecondFee,
            uint160 consumedSecondPrice
        )
    {
        MemeverseTransientState.pushSwapContext(poolId, firstFee, firstPrice);
        (consumedFirstFee, consumedFirstPrice,) = MemeverseTransientState.consumeCurrentSwapContext(poolId);

        MemeverseTransientState.pushSwapContext(poolId, secondFee, secondPrice);
        (consumedSecondFee, consumedSecondPrice,) = MemeverseTransientState.consumeCurrentSwapContext(poolId);
    }

    /// @notice Pops nested contexts in last-in-first-out order when the pools differ.
    function nestedDifferentPools(
        PoolId outerPoolId,
        PoolId innerPoolId,
        uint256 outerFee,
        uint160 outerPrice,
        uint256 innerFee,
        uint160 innerPrice
    )
        external
        returns (
            uint256 consumedInnerFee,
            uint160 consumedInnerPrice,
            uint256 consumedOuterFee,
            uint160 consumedOuterPrice
        )
    {
        MemeverseTransientState.pushSwapContext(outerPoolId, outerFee, outerPrice);
        MemeverseTransientState.pushSwapContext(innerPoolId, innerFee, innerPrice);

        (consumedInnerFee, consumedInnerPrice,) = MemeverseTransientState.consumeCurrentSwapContext(innerPoolId);
        (consumedOuterFee, consumedOuterPrice,) = MemeverseTransientState.consumeCurrentSwapContext(outerPoolId);
    }

    /// @notice Preserves separately encoded fee modes across a pop and replacement push.
    function popThenPushMode(PoolId poolId, uint256 firstEncodedFee, uint256 secondEncodedFee)
        external
        returns (uint256 consumedFirstFee, uint256 consumedSecondFee)
    {
        MemeverseTransientState.pushSwapContext(poolId, firstEncodedFee, 1);
        (consumedFirstFee,,) = MemeverseTransientState.consumeCurrentSwapContext(poolId);

        MemeverseTransientState.pushSwapContext(poolId, secondEncodedFee, 2);
        (consumedSecondFee,,) = MemeverseTransientState.consumeCurrentSwapContext(poolId);
    }

    /// @notice Confirms a popped context is unreachable through the public library API.
    function consumeAfterPop(PoolId poolId, uint256 fee, uint160 price)
        external
        returns (uint256 emptyFee, uint160 emptyPrice, bytes32 emptyBase)
    {
        MemeverseTransientState.pushSwapContext(poolId, fee, price);
        MemeverseTransientState.consumeCurrentSwapContext(poolId);
        return MemeverseTransientState.consumeCurrentSwapContext(poolId);
    }

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
