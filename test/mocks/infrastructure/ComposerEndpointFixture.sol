// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OmnichainMemecoinStakerUpgradeable} from "../../../src/interoperation/OmnichainMemecoinStakerUpgradeable.sol";

import {MockMessagingComposerEndpoint} from "./MockMessagingComposerEndpoint.sol";

/// @dev Shared fixture for suites that etch the composer mock onto a fixed endpoint address (EndpointV2 embeds
///      MessagingComposer; the staker/dispatcher `localEndpoint` is fixed at initialize time (dispatcher as namespaced
///      storage, staker likewise), so the mock must be pre-etched at that address). Single source of truth for the 0x1111 slot and the
///      deploy-then-etch ritual, previously repeated in every suite's setUp with its own comment wording. Each
///      test still etches in its own context, so per-test isolation is unchanged. Also hosts the shared staker
///      UUPS deploy helper (`_deployStaker`).
abstract contract ComposerEndpointFixture is Test {
    /// @dev Fixed address where the composer surface is etched.
    address internal constant LOCAL_ENDPOINT = address(0x1111);

    /// @notice Deploys the composer mock and etches its code onto LOCAL_ENDPOINT, returning the typed handle.
    function _etchComposer() internal returns (MockMessagingComposerEndpoint composer) {
        MockMessagingComposerEndpoint deployed = new MockMessagingComposerEndpoint();
        vm.etch(LOCAL_ENDPOINT, address(deployed).code);
        composer = MockMessagingComposerEndpoint(LOCAL_ENDPOINT);
    }

    /// @notice Deploys the staker in its production UUPS shape: a fresh implementation, then an ERC1967Proxy
    ///         whose constructor data carries `initialize(owner, endpoint)`.
    /// @dev Single point of maintenance for the staker's deploy shape and initialize signature drift — this is
    ///      the exact form `MemeverseScript.s.sol::_deployOmnichainMemecoinStaker` CREATE3s (impl, then proxy
    ///      wrapping initializeData), previously copied suite by suite.
    /// @param owner Initial owner recorded by initialize.
    /// @param endpoint Local endpoint the staker binds as its `localEndpoint`.
    /// @return proxy The initialized staker proxy.
    function _deployStaker(address owner, address endpoint)
        internal
        returns (OmnichainMemecoinStakerUpgradeable proxy)
    {
        OmnichainMemecoinStakerUpgradeable implementation = new OmnichainMemecoinStakerUpgradeable();
        proxy = OmnichainMemecoinStakerUpgradeable(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(OmnichainMemecoinStakerUpgradeable.initialize, (owner, endpoint))
                )
            )
        );
    }
}
