// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "../../../src/common/access/Initializable.sol";

contract InitializableHarness is Initializable {
    /// @notice Initializer-gated no-op entrypoint so tests can exercise the
    /// `initializer` modifier, e.g. by calling it on the logic instance (deployed
    /// via `new`) to trigger the `AlreadyInitialized` revert path.
    function initialize() external initializer {}

    /// @notice Exposes the `onlyInitializing` guard for invariant testing. All
    /// production `onlyInitializing` helpers are `internal`, so this external
    /// wrapper is the only way to call one outside an initializer window and
    /// assert the `NotInitializing` revert.
    function externalInitOnlyCall() external onlyInitializing {}
}
