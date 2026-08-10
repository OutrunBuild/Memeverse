// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    IOAppOptionsType3,
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {OptionsType3Harness} from "../../../mocks/infrastructure/OptionsType3Harness.sol";

contract OutrunOAppOptionsType3InitTest is Test {
    using Clones for address;

    address internal constant OWNER = address(0xABCD);
    address internal constant OTHER = address(0xBEEF);

    OptionsType3Harness internal implementation;
    OptionsType3Harness internal harness;

    /// @notice Set up.
    function setUp() external {
        implementation = new OptionsType3Harness();
        harness = OptionsType3Harness(address(implementation).clone());
        harness.initialize(OWNER);
    }

    /// @notice Test set enforced options requires owner and type3 prefix.
    function testSetEnforcedOptionsRequiresOwnerAndType3Prefix() external {
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex"00030011"});

        vm.prank(OTHER);
        vm.expectRevert();
        harness.setEnforcedOptions(params);

        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex"00020011"});
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"00020011"));
        harness.setEnforcedOptions(params);
    }

    /// @notice Test set enforced options rejects empty and short (1-byte) options with typed InvalidOptions.
    function testSetEnforcedOptionsRejectsEmptyOptions() external {
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex""});

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex""));
        harness.setEnforcedOptions(params);

        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex"01"});
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"01"));
        harness.setEnforcedOptions(params);
    }

    /// @notice Test combine options handles no enforced no extra and merging.
    function testCombineOptionsHandlesNoEnforcedNoExtraAndMerging() external {
        assertEq(harness.combineOptions(101, 1, hex"1234"), hex"1234");

        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex"0003aabb"});
        vm.prank(OWNER);
        harness.setEnforcedOptions(params);

        assertEq(harness.enforcedOptions(101, 1), hex"0003aabb");
        assertEq(harness.combineOptions(101, 1, hex""), hex"0003aabb");
        assertEq(harness.combineOptions(101, 1, hex"0003ccdd"), hex"0003aabbccdd");
    }

    /// @notice Test combine options rejects invalid extra options when enforced exists.
    function testCombineOptionsRejectsInvalidExtraOptionsWhenEnforcedExists() external {
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: 101, msgType: 1, options: hex"0003aabb"});
        vm.prank(OWNER);
        harness.setEnforcedOptions(params);

        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0002ccdd"));
        harness.combineOptions(101, 1, hex"0002ccdd");

        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"01"));
        harness.combineOptions(101, 1, hex"01");
    }
}
