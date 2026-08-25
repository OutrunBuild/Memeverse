// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MemePol} from "../../src/token/MemePol.sol";
import {IPol} from "../../src/token/interfaces/IPol.sol";
import {MockOAppCoreEndpoint} from "../mocks/common/CommonMocks.sol";

contract MemePolTest is Test {
    using Clones for address;

    address internal constant MEMECOIN = address(0xABCD);
    address internal constant LAUNCHER = address(0xBEEF);
    address internal constant DELEGATE = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockOAppCoreEndpoint internal endpoint;
    MemePol internal implementation;
    MemePol internal memePol;

    /// @notice Set up.
    function setUp() external {
        endpoint = new MockOAppCoreEndpoint();
        implementation = new MemePol(address(endpoint));
        memePol = MemePol(address(implementation).clone());
    }

    /// @notice Test initialize sets config and owner.
    function testInitializeSetsConfigAndOwner() external {
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, LAUNCHER, DELEGATE);

        assertEq(memePol.name(), "POL-MEME");
        assertEq(memePol.symbol(), "POLM");
        assertEq(memePol.memecoin(), MEMECOIN);
        assertEq(memePol.memeverseLauncher(), LAUNCHER);
        assertEq(memePol.owner(), DELEGATE);
        assertEq(endpoint.delegate(), DELEGATE);
    }

    /// @notice Test only launcher can mint.
    function testOnlyLauncherCanMint() external {
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, LAUNCHER, DELEGATE);

        vm.expectRevert(IPol.PermissionDenied.selector);
        memePol.mint(ALICE, 1 ether);

        vm.prank(LAUNCHER);
        memePol.mint(ALICE, 2 ether);
        assertEq(memePol.balanceOf(ALICE), 2 ether);
    }

    /// @notice Test burn supports direct holder and approved spender.
    function testBurnSupportsDirectHolderAndApprovedSpender() external {
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, LAUNCHER, DELEGATE);

        vm.prank(LAUNCHER);
        memePol.mint(ALICE, 3 ether);

        vm.prank(ALICE);
        memePol.burn(1 ether);
        assertEq(memePol.balanceOf(ALICE), 2 ether);

        vm.prank(ALICE);
        memePol.approve(BOB, 1 ether);

        vm.prank(BOB);
        memePol.burn(ALICE, 1 ether);
        assertEq(memePol.balanceOf(ALICE), 1 ether);
        assertEq(memePol.allowance(ALICE, BOB), 0);
    }

    /// @notice Test initialize rejects zero memecoin or launcher.
    function testInitializeRejectsZeroAddresses() external {
        vm.expectRevert(IPol.ZeroInput.selector);
        memePol.initialize("POL-MEME", "POLM", address(0), LAUNCHER, DELEGATE);

        vm.expectRevert(IPol.ZeroInput.selector);
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, address(0), DELEGATE);
    }

    /// @notice Test mint and burn reject zero amount.
    function testMintAndBurnRejectZeroAmount() external {
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, LAUNCHER, DELEGATE);

        vm.prank(LAUNCHER);
        vm.expectRevert(IPol.ZeroInput.selector);
        memePol.mint(ALICE, 0);

        vm.prank(ALICE);
        vm.expectRevert(IPol.ZeroInput.selector);
        memePol.burn(0);

        vm.prank(ALICE);
        vm.expectRevert(IPol.ZeroInput.selector);
        memePol.burn(ALICE, 0);
    }

    /// @notice Test setPoolId has been removed — low-level call must fail and no poolId getter exists.
    function testSetPoolIdRemoved() external {
        memePol.initialize("POL-MEME", "POLM", MEMECOIN, LAUNCHER, DELEGATE);
        // No high-level setPoolId(poolId) exists; low-level call to the old selector must return success=false (function not found)
        bytes4 oldSelector = bytes4(keccak256("setPoolId(bytes32)"));
        (bool success,) = address(memePol).call(abi.encodeWithSelector(oldSelector, bytes32(uint256(1234))));
        assertFalse(success, "setPoolId selector should not exist after deletion");
        // poolId() getter also removed
        bytes4 poolIdSelector = bytes4(keccak256("poolId()"));
        (bool success2,) = address(memePol).call(abi.encodeWithSelector(poolIdSelector));
        assertFalse(success2, "poolId getter should not exist after deletion");
    }
}
