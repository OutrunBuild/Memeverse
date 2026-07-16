// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

/// @notice Minimal stand-in bytecode used to spoof a deployed proxy/implementation in reuse-path tests.
/// @dev Only `owner()` is ever reached: the deploy script reverts on the codehash check before any other
///      view is read, except for `owner()` under delegatecall (hook-impl stale test) or direct call
///      (admin-owner test). `fakeOwner` is the first state field (slot 0), so tests seed it via
///      `vm.store(target, bytes32(0), value)` without going through a setter.
contract FakeDeploymentHook {
    address internal fakeOwner;

    function owner() external view returns (address) {
        return fakeOwner;
    }
}
