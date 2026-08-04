// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";
import {CountingSnapshotHook} from "../mocks/swap/CountingSnapshotHook.sol";

contract UniswapLPTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;

    address internal immutable OWNER = vm.addr(OWNER_PK);
    address internal immutable OTHER = vm.addr(OTHER_PK);
    address internal constant SPENDER = address(0xBEEF);

    PoolId internal constant TEST_POOL_ID = PoolId.wrap(bytes32(uint256(1)));

    UniswapLP internal implementation;
    UniswapLP internal token;

    function setUp() external {
        implementation = new UniswapLP();
        token = UniswapLP(Clones.clone(address(implementation)));
        token.initialize("Memeverse LP", "MLP", 18, TEST_POOL_ID, address(this));
    }

    function testInitializeRevertsWithZeroAddressHook() external {
        UniswapLP freshClone = UniswapLP(Clones.clone(address(implementation)));

        vm.expectRevert(UniswapLP.ZeroAddressHook.selector);
        freshClone.initialize("Memeverse LP", "MLP", 18, TEST_POOL_ID, address(0));
    }

    function testInitializeSetsCloneStateAndOwner() external view {
        assertGt(address(token).code.length, 0, "clone code");
        assertEq(token.name(), "Memeverse LP", "name");
        assertEq(token.symbol(), "MLP", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(PoolId.unwrap(token.poolId()), PoolId.unwrap(TEST_POOL_ID), "pool id");
        assertEq(token.memeverseUniswapHook(), address(this), "hook");
        assertEq(token.owner(), address(this), "owner");
    }

    function testInitializeRevertsOnSecondCall() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("Other", "OTHER", 6, PoolId.wrap(bytes32(uint256(2))), address(0xBEEF));
    }

    function testImplementationCannotBeInitializedByExternalCaller() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("Implementation", "IMPL", 18, TEST_POOL_ID, address(this));
    }

    function testMintRevertsForNonOwner() external {
        vm.prank(OTHER);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(OTHER, 1 ether);
    }

    function testBurnRevertsForNonOwner() external {
        vm.prank(OTHER);
        vm.expectRevert("UNAUTHORIZED");
        token.burn(OWNER, 1 ether);
    }

    function testOwnerCanMint() external {
        token.mint(OTHER, 1 ether);
        assertEq(token.balanceOf(OTHER), 1 ether);
    }

    function testOwnerCanBurn() external {
        token.mint(OWNER, 1 ether);
        assertEq(token.balanceOf(OWNER), 1 ether);

        token.burn(OWNER, 1 ether);
        assertEq(token.balanceOf(OWNER), 0);
    }

    function testPermitUsesInitializedCloneDomain() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);

        assertEq(token.allowance(OWNER, SPENDER), 7 ether, "allowance");
        assertEq(token.nonces(OWNER), 1, "nonce");
    }

    function testPermitRevertsWithPermitDeadlineExpired() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(UniswapLP.PermitDeadlineExpired.selector, expiredDeadline));
        token.permit(OWNER, SPENDER, 7 ether, expiredDeadline, v, r, s);
    }

    function testPermitRevertsWithInvalidSigner() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_PK, digest);

        vm.expectRevert(abi.encodeWithSelector(UniswapLP.InvalidSigner.selector, OTHER, OWNER));
        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);
    }

    function _permitDigest(address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }
}

/// @dev Dedicated coverage for the `_beforeTokenTransfer` snapshot callback, which `UniswapLPTest` cannot exercise
///      because it wires the hook to `address(this)` (no `updateUserSnapshot`). This harness binds a real
///      `CountingSnapshotHook` so it can mint (hook is owner) and assert callback call counts.
contract UniswapLPSnapshotTransferTest is Test {
    PoolId internal constant TEST_POOL_ID = PoolId.wrap(bytes32(uint256(1)));

    CountingSnapshotHook internal hook;
    UniswapLP internal token;
    address internal holder = address(0xCAFE);

    function setUp() external {
        hook = new CountingSnapshotHook();

        UniswapLP implementation = new UniswapLP();
        token = UniswapLP(Clones.clone(address(implementation)));
        token.initialize("Memeverse LP", "MLP", 18, TEST_POOL_ID, address(hook));

        // mint is onlyOwner (== hook); prank as the hook to seed a balance for transfer tests.
        vm.prank(address(hook));
        token.mint(holder, 10 ether);
    }

    /// @dev Self-transfer must update the snapshot exactly once, not twice (SWAP-002a redundancy removal).
    function testSelfTransferUpdatesSnapshotOnce() external {
        vm.prank(holder);
        token.transfer(holder, 1 ether);

        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 1, "snapshot calls");
        assertEq(token.balanceOf(holder), 10 ether, "balance unchanged");
    }

    /// @dev Distinct-party transfer must update both snapshots once each (behavior preserved).
    function testDistinctTransferUpdatesBothSnapshotsOnce() external {
        address recipient = address(0xB0B);

        vm.prank(holder);
        token.transfer(recipient, 1 ether);

        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 1, "from snapshot calls");
        assertEq(hook.snapshotCallCount(TEST_POOL_ID, recipient), 1, "to snapshot calls");
    }

    /// @dev `transferFrom` is a separate entry point into `_beforeTokenTransfer`; a self-transferFrom must
    ///      also update the snapshot exactly once (locks in LR-001 entry-point coverage).
    function testSelfTransferFromUpdatesSnapshotOnce() external {
        vm.startPrank(holder);
        // Infinite self-allowance skips the finite-allowance decrement; only the snapshot path is under test.
        token.approve(holder, type(uint256).max);
        token.transferFrom(holder, holder, 1 ether);
        vm.stopPrank();

        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 1, "snapshot calls");
        assertEq(token.balanceOf(holder), 10 ether, "balance unchanged");
    }
}
