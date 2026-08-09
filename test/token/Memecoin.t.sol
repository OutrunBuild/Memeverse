// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Memecoin} from "../../src/token/Memecoin.sol";
import {IMemecoin} from "../../src/token/interfaces/IMemecoin.sol";

contract MockMemecoinEndpoint {
    address public delegate;

    /// @notice Set delegate.
    /// @param delegate_ See implementation.
    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }
}

contract MemecoinTest is Test {
    using Clones for address;

    address internal constant LAUNCHER = address(0xBEEF);
    address internal constant DELEGATE = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);

    MockMemecoinEndpoint internal endpoint;
    Memecoin internal implementation;
    Memecoin internal memecoin;

    /// @notice Set up.
    function setUp() external {
        endpoint = new MockMemecoinEndpoint();
        implementation = new Memecoin(address(endpoint));
        memecoin = Memecoin(address(implementation).clone());
    }

    /// @notice Test initialize sets metadata launcher owner and delegate.
    function testInitializeSetsMetadataLauncherOwnerAndDelegate() external {
        memecoin.initialize("Memecoin", "MEME", LAUNCHER, DELEGATE);

        assertEq(memecoin.name(), "Memecoin");
        assertEq(memecoin.symbol(), "MEME");
        assertEq(memecoin.memeverseLauncher(), LAUNCHER);
        assertEq(memecoin.owner(), DELEGATE);
        assertEq(endpoint.delegate(), DELEGATE);
    }

    /// @notice Test mint only launcher and burn by holder.
    function testMintOnlyLauncherAndBurnByHolder() external {
        memecoin.initialize("Memecoin", "MEME", LAUNCHER, DELEGATE);

        vm.expectRevert(IMemecoin.PermissionDenied.selector);
        memecoin.mint(ALICE, 1 ether);

        vm.prank(LAUNCHER);
        memecoin.mint(ALICE, 2 ether);
        assertEq(memecoin.balanceOf(ALICE), 2 ether);

        vm.prank(ALICE);
        memecoin.burn(1 ether);
        assertEq(memecoin.balanceOf(ALICE), 1 ether);
    }

    /// @notice Test mint and burn reject zero amount.
    function testMintAndBurnRejectZeroAmount() external {
        memecoin.initialize("Memecoin", "MEME", LAUNCHER, DELEGATE);

        vm.prank(LAUNCHER);
        vm.expectRevert(IMemecoin.ZeroInput.selector);
        memecoin.mint(ALICE, 0);

        vm.prank(ALICE);
        vm.expectRevert(IMemecoin.ZeroInput.selector);
        memecoin.burn(0);
    }
}
