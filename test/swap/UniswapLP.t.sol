// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Initializable} from "../../src/common/access/Initializable.sol";
import {OutrunERC20PermitInit} from "../../src/common/token/OutrunERC20PermitInit.sol";
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

    /// @dev Decimals is a per-clone storage override; exercise the non-default path to keep the override honest.
    function testInitializeWithNonDefaultDecimals() external {
        UniswapLP freshClone = UniswapLP(Clones.clone(address(implementation)));
        freshClone.initialize("Memeverse LP", "MLP", 6, TEST_POOL_ID, address(this));

        assertEq(freshClone.decimals(), 6, "decimals");
    }

    function testInitializeRevertsOnSecondCall() external {
        vm.expectRevert(Initializable.AlreadyInitialized.selector);
        token.initialize("Other", "OTHER", 6, PoolId.wrap(bytes32(uint256(2))), address(0xBEEF));
    }

    function testImplementationCannotBeInitializedByExternalCaller() external {
        vm.expectRevert(Initializable.AlreadyInitialized.selector);
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

    /// @dev The common base reverts with the IERC6093 error surface instead of the old `ZeroAddressTransfer`
    ///      custom error / Panic underflow (accepted change).
    function testTransferToZeroAddressReverts() external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
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

        vm.expectRevert(abi.encodeWithSelector(OutrunERC20PermitInit.ERC2612ExpiredSignature.selector, expiredDeadline));
        token.permit(OWNER, SPENDER, 7 ether, expiredDeadline, v, r, s);
    }

    function testPermitRevertsWithInvalidSigner() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_PK, digest);

        vm.expectRevert(abi.encodeWithSelector(OutrunERC20PermitInit.ERC2612InvalidSigner.selector, OTHER, OWNER));
        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);
    }

    /// @dev Permit now routes through OZ ECDSA.recover, which enforces the low-s bound: mirroring a valid
    ///      low-s `s` across the secp256k1 group order yields a high-s value (always > n/2) that must be rejected.
    ///      A bare `ecrecover` implementation would accept this signature, so this test locks in the ECDSA path.
    function testPermitRevertsWithHighS() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        // secp256k1 group order n; n - s is the high-s mirror of low-s `s` (vm.sign always emits low-s).
        bytes32 highS =
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, highS);

        // Revert unwinds the nonce increment performed inside `permit`; nothing was consumed.
        assertEq(token.nonces(OWNER), 0, "nonce untouched");
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

/// @dev Dedicated coverage for the `_update` snapshot callback, which `UniswapLPTest` cannot exercise
///      because it wires the hook to `address(this)` (no `updateUserSnapshot`). This harness binds a real
///      `CountingSnapshotHook` so it can mint (hook is owner), assert callback call counts, and host the
///      transfer revert-path tests (a non-zero-from/to transfer fires the snapshot hook before the base
///      balance revert).
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

        // Mint routes from == address(0) through `_update`, so the snapshot callback must not fire.
        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 0, "mint excludes snapshot");
    }

    /// @dev Burn routes `to == address(0)` through `_update`, so the snapshot callback must not fire.
    function testBurnExcludesSnapshot() external {
        vm.prank(address(hook));
        token.burn(holder, 1 ether);

        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 0, "burn excludes snapshot");
        assertEq(token.balanceOf(holder), 9 ether, "balance after burn");
    }

    /// @dev Self-transfer must update the snapshot exactly once, not twice (redundancy removal).
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

    /// @dev `transferFrom` is a separate entry point into the `_update` snapshot callback; a self-transferFrom must
    ///      also update the snapshot exactly once.
    function testSelfTransferFromUpdatesSnapshotOnce() external {
        vm.startPrank(holder);
        // Infinite self-allowance skips the finite-allowance decrement; only the snapshot path is under test.
        token.approve(holder, type(uint256).max);
        token.transferFrom(holder, holder, 1 ether);
        vm.stopPrank();

        assertEq(hook.snapshotCallCount(TEST_POOL_ID, holder), 1, "snapshot calls");
        assertEq(token.balanceOf(holder), 10 ether, "balance unchanged");
    }

    /// @dev Transfers above the holder balance revert with the IERC6093 error surface; the `holder` snapshot
    ///      fires first and succeeds via `CountingSnapshotHook`, then the base `_update` reverts with data.
    function testTransferInsufficientBalanceReverts() external {
        uint256 balance = token.balanceOf(holder);

        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, balance + 1)
        );
        token.transfer(address(0xB0B), balance + 1);
    }

    /// @dev `transferFrom` spends the allowance before `_update`, so the snapshot never fires and the
    ///      insufficient-allowance revert is the only error surface.
    function testTransferFromInsufficientAllowanceReverts() external {
        address spender = address(0xBEEF);

        vm.prank(holder);
        token.approve(spender, 5);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 5, 6));
        token.transferFrom(holder, address(0xB0B), 6);
    }
}
