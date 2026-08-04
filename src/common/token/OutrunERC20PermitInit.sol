// SPDX-License-Identifier: GPL-3.0
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/ERC20Permit.sol)
pragma solidity ^0.8.35;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {OutrunNoncesInit} from "./OutrunNoncesInit.sol";
import {OutrunERC20Init} from "./OutrunERC20Init.sol";
import {OutrunEIP712Init} from "../cryptography/OutrunEIP712Init.sol";

/**
 * @dev (Just for minimal proxy)
 * Implementation of the ERC-20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[ERC-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC-20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on `{IERC20-approve}`, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
abstract contract OutrunERC20PermitInit is OutrunERC20Init, IERC20Permit, OutrunEIP712Init, OutrunNoncesInit {
    bytes32 private constant PERMIT_TYPEHASH =
    // solhint-disable-next-line gas-small-strings
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /**
     * @dev Permit deadline has expired.
     */
    error ERC2612ExpiredSignature(uint256 deadline);

    /**
     * @dev Mismatched signature.
     */
    error ERC2612InvalidSigner(address signer, address owner);

    /**
     * @dev Initializes the {EIP712} domain separator using the `name` parameter, and setting `version` to `"1"`.
     *
     * It's a good idea to use the same `name` that is defined as the ERC-20 token name.
     */
    function __OutrunERC20Permit_init(string memory _name) internal onlyInitializing {
        __OutrunEIP712_init(_name, "1");
    }

    function __ERC20Permit_init_unchained(string memory) internal onlyInitializing {}

    /// @notice Sets allowance via an EIP-2612 signature.
    /// @dev Consumes `owner` nonce and reverts on expired or invalid signature.
    /// @param owner Token holder that signed the permit.
    /// @param spender Address receiving allowance.
    /// @param value Allowance amount to set.
    /// @param deadline Expiration timestamp for the signature.
    /// @param v Signature recovery parameter.
    /// @param r Signature field `r`.
    /// @param s Signature field `s`.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
    {
        // EIP-2612: deadline is inclusive — a signature stays valid through `deadline`,
        // not strictly before it. Matches OpenZeppelin and the sibling delegateBySig path.
        require(block.timestamp <= deadline, ERC2612ExpiredSignature(deadline));

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));
        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == owner, ERC2612InvalidSigner(signer, owner));

        _approve(owner, spender, value);
    }

    /// @notice Reads the current permit nonce for `owner`.
    /// @dev Nonce increments after each successful `permit` call.
    /// @param owner Account to query.
    /// @return nonce Current nonce value.
    function nonces(address owner) public view virtual override(IERC20Permit, OutrunNoncesInit) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @inheritdoc IERC20Permit
     */
    // solhint-disable-next-line func-name-mixedcase
    /// @notice Exposes the EIP-712 domain separator used by `permit`.
    /// @dev Domain is derived from token name, version, chain ID, and contract address.
    /// @return separator Domain separator hash.
    function DOMAIN_SEPARATOR() external view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }
}
