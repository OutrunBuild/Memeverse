// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {OutrunERC20PermitInit} from "../../../src/common/token/OutrunERC20PermitInit.sol";
import {PermitHarness} from "../../mocks/infrastructure/PermitHarness.sol";

contract OutrunERC20PermitInitTest is Test {
    using Clones for address;

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal immutable OWNER = vm.addr(OWNER_PK);
    uint256 internal constant OTHER_PK = 0xB0B;
    address internal immutable OTHER = vm.addr(OTHER_PK);
    address internal constant SPENDER = address(0xBEEF);

    PermitHarness internal implementation;
    PermitHarness internal token;

    /// @notice Set up.
    function setUp() external {
        implementation = new PermitHarness();
        token = PermitHarness(address(implementation).clone());
        token.initialize("Permit Token", "PRM");
    }

    /// @notice Test initialize sets metadata and domain separator.
    function testInitializeSetsMetadataAndDomainSeparator() external view {
        assertEq(token.name(), "Permit Token");
        assertEq(token.symbol(), "PRM");
        // Anchor the domain separator to a literal EIP-712 recomputation so that any future
        // change to the production domain construction (typehash string or field encoding order)
        // breaks this test instead of silently drifting alongside the harness digest.
        assertEq(
            token.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("Permit Token")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(token)
                )
            )
        );
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(name, "Permit Token");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
    }

    /// @notice Test the cached domain separator stays consistent with the live EIP-712 metadata.
    /// @dev Guards the invariant introduced by the hash cache: `_EIP712Name`/`_EIP712Version`
    ///      must return stable values after init, otherwise the cached `_hashedName`/`_hashedVersion`
    ///      desync from what `eip712Domain()` exposes. This check recomputes the separator from the
    ///      live metadata, so a future dynamic override that diverges from the cache turns red.
    function testDomainSeparatorMatchesLiveEip712Metadata() external view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(
            token.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    chainId,
                    verifyingContract
                )
            )
        );
    }

    /// @notice Test permit sets allowance and consumes nonce.
    function testPermitSetsAllowanceAndConsumesNonce() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = token.permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);

        assertEq(token.allowance(OWNER, SPENDER), 7 ether);
        assertEq(token.nonces(OWNER), 1);
    }

    /// @notice Test permit rejects expired or invalid signer.
    function testPermitRejectsExpiredOrInvalidSigner() external {
        // 1. Boundary inclusive: deadline == block.timestamp is now ACCEPTED by permit
        //    (EIP-2612 treats deadline as inclusive). Regression guard for the fixed boundary bug.
        {
            uint256 deadline = block.timestamp;
            bytes32 digest = token.permitDigest(OWNER, SPENDER, 7 ether, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

            token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);

            assertEq(token.allowance(OWNER, SPENDER), 7 ether);
            assertEq(token.nonces(OWNER), 1);
        }

        // 2. Truly expired: sign and call with deadline == block.timestamp - 1 (digest matches the call arg).
        {
            uint256 expiredDeadline = block.timestamp - 1;
            bytes32 digest = token.permitDigest(OWNER, SPENDER, 7 ether, expiredDeadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

            vm.expectRevert(
                abi.encodeWithSelector(OutrunERC20PermitInit.ERC2612ExpiredSignature.selector, expiredDeadline)
            );
            token.permit(OWNER, SPENDER, 7 ether, expiredDeadline, v, r, s);
        }

        // 3. Invalid signer: signature is produced by a different key (OTHER), so recovery
        //    mismatches `owner`. Precise selector assertion matches test/swap/UniswapLP.t.sol pattern.
        {
            uint256 deadline = block.timestamp + 1 days;
            bytes32 digest = token.permitDigest(OWNER, SPENDER, 7 ether, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OTHER_PK, digest);

            vm.expectRevert(abi.encodeWithSelector(OutrunERC20PermitInit.ERC2612InvalidSigner.selector, OTHER, OWNER));
            token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);
        }
    }

    /// @notice Test permit rejects replay of the same signature.
    function testPermitRejectsReplayOfSameSignature() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = token.permitDigest(OWNER, SPENDER, 7 ether, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);
        assertEq(token.nonces(OWNER), 1);

        vm.expectRevert();
        token.permit(OWNER, SPENDER, 7 ether, deadline, v, r, s);
    }
}
