// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {LzEndpointRegistry} from "../../../src/common/omnichain/LzEndpointRegistry.sol";
import {ILzEndpointRegistry} from "../../../src/common/omnichain/interfaces/ILzEndpointRegistry.sol";

contract LzEndpointRegistryTest is Test {
    address internal constant OWNER = address(0xABCD);
    address internal constant OTHER = address(0xBEEF);

    LzEndpointRegistry internal registry;

    /// @notice Set up.
    function setUp() external {
        registry = new LzEndpointRegistry(OWNER);
    }

    /// @notice Test set lz endpoint ids stores all pairs and emits them unchanged.
    function testSetLzEndpointIdsStoresAndEmitsAllPairs() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory pairs = new ILzEndpointRegistry.LzEndpointIdPair[](2);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 1, endpointId: 101});
        pairs[1] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 3, endpointId: 303});

        // Expect the event to mirror the input array exactly, since every pair
        // is now validated and stored (no silent skipping).
        ILzEndpointRegistry.LzEndpointIdPair[] memory expected = pairs;
        vm.expectEmit();
        emit ILzEndpointRegistry.SetLzEndpointIds(expected);

        vm.prank(OWNER);
        registry.setLzEndpointIds(pairs);

        assertEq(registry.lzEndpointIdOfChain(1), 101);
        assertEq(registry.lzEndpointIdOfChain(3), 303);
    }

    /// @notice Zero chainId or endpointId reverts the whole batch, so a
    ///         misconfigured pair cannot silently land a partial config.
    function testSetLzEndpointIdsRevertsOnZeroChainId() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory pairs = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 0, endpointId: 202});

        vm.prank(OWNER);
        vm.expectRevert(ILzEndpointRegistry.InvalidEndpointIdPair.selector);
        registry.setLzEndpointIds(pairs);
    }

    /// @notice Zero endpointId reverts too (e.g. an unconfigured chain).
    function testSetLzEndpointIdsRevertsOnZeroEndpointId() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory pairs = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 2, endpointId: 0});

        vm.prank(OWNER);
        vm.expectRevert(ILzEndpointRegistry.InvalidEndpointIdPair.selector);
        registry.setLzEndpointIds(pairs);
    }

    /// @notice A single bad pair among valid ones reverts the whole batch,
    ///         leaving storage untouched (no partial writes).
    function testSetLzEndpointIdsRevertsWholeBatchOnOneBadPair() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory pairs = new ILzEndpointRegistry.LzEndpointIdPair[](3);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 1, endpointId: 101});
        pairs[1] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 2, endpointId: 0});
        pairs[2] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 3, endpointId: 303});

        vm.prank(OWNER);
        vm.expectRevert(ILzEndpointRegistry.InvalidEndpointIdPair.selector);
        registry.setLzEndpointIds(pairs);

        // Nothing written: the valid pair at index 0 was not stored.
        assertEq(registry.lzEndpointIdOfChain(1), 0);
    }

    /// @notice Test set lz endpoint ids only owner.
    function testSetLzEndpointIdsOnlyOwner() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory pairs = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: 1, endpointId: 101});

        vm.prank(OTHER);
        vm.expectRevert();
        registry.setLzEndpointIds(pairs);
    }
}
