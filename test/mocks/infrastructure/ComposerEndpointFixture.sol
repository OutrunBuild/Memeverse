// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {MockMessagingComposerEndpoint} from "./MockMessagingComposerEndpoint.sol";

/// @dev Shared fixture for suites that etch the composer mock onto a fixed endpoint address (EndpointV2 embeds
///      MessagingComposer; the staker/dispatcher immutable `localEndpoint` is fixed at construction time, so the
///      mock must be pre-etched at that address). Single source of truth for the 0x1111 slot and the
///      deploy-then-etch ritual, previously repeated in every suite's setUp with its own comment wording. Each
///      test still etches in its own context, so per-test isolation is unchanged.
abstract contract ComposerEndpointFixture is Test {
    /// @dev Fixed address where the composer surface is etched.
    address internal constant LOCAL_ENDPOINT = address(0x1111);

    /// @notice Deploys the composer mock and etches its code onto LOCAL_ENDPOINT, returning the typed handle.
    function _etchComposer() internal returns (MockMessagingComposerEndpoint composer) {
        MockMessagingComposerEndpoint deployed = new MockMessagingComposerEndpoint();
        vm.etch(LOCAL_ENDPOINT, address(deployed).code);
        composer = MockMessagingComposerEndpoint(LOCAL_ENDPOINT);
    }
}
