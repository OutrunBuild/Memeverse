// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISignatureTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/ISignatureTransfer.sol";

/// @notice Trusting Permit2 double that records witness transfer requests without signature checks.
/// @dev Focuses on observability of router-supplied payloads rather than signature validity.
contract MockPermit2ForRouterTest {
    using SafeERC20 for IERC20;

    address public lastOwner;
    address public lastRecipient;
    address public lastToken;
    uint256 public lastRequestedAmount;
    address public lastBatchOwner;
    uint256 public lastBatchLength;
    bytes32 public lastWitness;
    string public lastWitnessTypeString;
    bytes public lastSignature;

    /// @notice Mocks Permit2 single-token witness transfers and records the last request.
    /// @dev This test double trusts the payload and focuses on observability rather than signature checks.
    /// @param permit The signed Permit2 transfer payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The mocked signature bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        lastOwner = owner;
        lastRecipient = transferDetails.to;
        lastToken = permit.permitted.token;
        lastRequestedAmount = transferDetails.requestedAmount;
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastSignature = signature;

        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    /// @notice Mocks Permit2 batch witness transfers and records the last request.
    /// @dev This test double trusts the payload and focuses on observability rather than signature checks.
    /// @param permit The signed Permit2 batch payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The mocked signature bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        lastBatchOwner = owner;
        lastBatchLength = transferDetails.length;
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastSignature = signature;

        for (uint256 i = 0; i < transferDetails.length; ++i) {
            IERC20(permit.permitted[i].token)
                .safeTransferFrom(owner, transferDetails[i].to, transferDetails[i].requestedAmount);
        }
    }
}

/// @notice Signature-verifying Permit2 double enforcing EIP-712 witness transfer semantics.
/// @dev Reproduces Permit2 nonce, deadline, amount, and signer checks for negative-path router tests.
contract SignatureVerifyingPermit2ForRouterTest {
    using SafeERC20 for IERC20;

    error InvalidAmount(uint256 maxAmount);
    error InvalidNonce();
    error InvalidSigner();
    error LengthMismatch();
    error SignatureExpired(uint256 deadline);

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_SINGLE_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string internal constant PERMIT_BATCH_WITNESS_TYPEHASH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant EIP712_NAME_HASH = keccak256("Permit2");

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    /// @notice Returns the EIP-712 domain separator used by the mock Permit2 implementation.
    /// @dev The separator binds signatures to the current chain and mock Permit2 address.
    /// @return separator The computed EIP-712 domain separator.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, block.chainid, address(this)));
    }

    /// @notice Verifies and executes a mocked single-token witness transfer.
    /// @dev Enforces nonce, deadline, amount, and EIP-712 signature validity before transfer.
    /// @param permit The signed Permit2 transfer payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The signed permit bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        if (transferDetails.requestedAmount > permit.permitted.amount) revert InvalidAmount(permit.permitted.amount);

        _useUnorderedNonce(owner, permit.nonce);
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_SINGLE_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 dataHash =
            keccak256(abi.encode(typeHash, tokenPermissionsHash, msg.sender, permit.nonce, permit.deadline, witness));
        _verifySignature(signature, owner, dataHash);
        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    /// @notice Verifies and executes a mocked batch witness transfer.
    /// @dev Enforces nonce, deadline, amount, and EIP-712 signature validity before transfer.
    /// @param permit The signed Permit2 batch payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The signed permit bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        if (permit.permitted.length != transferDetails.length) revert LengthMismatch();

        _useUnorderedNonce(owner, permit.nonce);
        bytes32[] memory tokenPermissionHashes = new bytes32[](permit.permitted.length);
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            if (transferDetails[i].requestedAmount > permit.permitted[i].amount) {
                revert InvalidAmount(permit.permitted[i].amount);
            }
            tokenPermissionHashes[i] = keccak256(
                abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i].token, permit.permitted[i].amount)
            );
        }

        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_BATCH_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 dataHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(tokenPermissionHashes)),
                msg.sender,
                permit.nonce,
                permit.deadline,
                witness
            )
        );
        _verifySignature(signature, owner, dataHash);

        for (uint256 i = 0; i < transferDetails.length; ++i) {
            IERC20(permit.permitted[i].token)
                .safeTransferFrom(owner, transferDetails[i].to, transferDetails[i].requestedAmount);
        }
    }

    /// @notice Claims a nonce inside the unordered Permit2 nonce bitmap.
    /// @dev Reproduces Permit2's unordered nonce validation so tests can reject duplicates.
    function _useUnorderedNonce(address from, uint256 nonce) private {
        uint256 wordPos = uint248(nonce >> 8);
        uint256 bitPos = uint8(nonce);
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonceBitmap[from][wordPos] ^= bit;
        if (flipped & bit == 0) revert InvalidNonce();
    }

    /// @notice Checks that the caller-supplied signature recovers the expected owner.
    /// @dev Detects invalid lengths or recovery values just like the production Permit2 reference.
    function _verifySignature(bytes calldata signature, address owner, bytes32 dataHash) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        if (signature.length != 65) revert InvalidSigner();
        (bytes32 r, bytes32 s) = abi.decode(signature, (bytes32, bytes32));
        uint8 v = uint8(signature[64]);
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != owner) revert InvalidSigner();
    }
}
