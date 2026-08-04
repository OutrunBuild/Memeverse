// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "../../../src/common/access/Initializable.sol";
import {InitializableHarness} from "../../mocks/infrastructure/InitializableHarness.sol";

contract InitializableTest is Test {
    InitializableHarness internal implementation;

    /// @notice Deploy the logic/implementation instance. Its `Initializable`
    /// constructor runs and sets `initialized = true` in the logic's own storage.
    function setUp() external {
        implementation = new InitializableHarness();
    }

    /// @notice Calling the initializer directly on the logic instance must revert
    /// `AlreadyInitialized`, since the constructor already locked the logic's
    /// own storage. This exercises the logic-constructor lock path that the
    /// clone-side tests in OutrunOAppCoreInit.t.sol do not cover.
    function testInitializeRevertsOnLogicInstance() external {
        vm.expectRevert(Initializable.AlreadyInitialized.selector);
        implementation.initialize();
    }

    /// @notice A `onlyInitializing`-gated function called outside any
    /// initializer window must revert `NotInitializing`. This path is independent
    /// of the constructor lock, so the fresh logic instance is sufficient.
    function testOnlyInitializingRevertsOutsideInitWindow() external {
        vm.expectRevert(Initializable.NotInitializing.selector);
        implementation.externalInitOnlyCall();
    }
}
