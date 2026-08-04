// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal counting mock for the `IMemeverseUniswapHook.updateUserSnapshot` callback.
/// @dev Counts calls per `(poolId, user)` so LP token tests can assert the snapshot callback fires exactly the
///      expected number of times (e.g. once, not twice, on a self-transfer). Implements only the one function the
///      LP token calls; it is intentionally NOT a full `IMemeverseUniswapHook`.
contract CountingSnapshotHook {
    /// @notice Number of times `updateUserSnapshot` was invoked for `(poolId, user)`.
    mapping(PoolId => mapping(address => uint256)) public snapshotCallCount;

    /// @notice Records a snapshot request. Does nothing else; the LP token only needs the call to succeed.
    /// @param id The pool id passed by the LP token.
    /// @param user The user address passed by the LP token.
    function updateUserSnapshot(PoolId id, address user) external {
        // Unchecked bump: this counter is test-only and never overflows in practice.
        unchecked {
            snapshotCallCount[id][user] += 1;
        }
    }
}
