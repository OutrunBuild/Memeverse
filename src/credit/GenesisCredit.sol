// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IGenesisCredit} from "./interfaces/IGenesisCredit.sol";

/**
 * @title GenesisCredit
 * @notice Home-chain-only merkle-airdrop credit token (ERC-20 + LayerZero OFT).
 * @dev Plain (non-upgradeable) contract inheriting the official LayerZero OFT. Claiming mints
 *      new supply and is gated to the configured home chain eid so that remote-chain OFT
 *      deployments can bridge tokens but never mint via claims. Ownership and the LayerZero
 *      delegate come from OFTCore's plain OZ Ownable; the `_delegate` constructor argument is
 *      set as owner, so `onlyOwner` gates `setMerkleRoot` with no extra access-control wiring.
 */
contract GenesisCredit is OFT, IGenesisCredit {
    /// @notice LayerZero endpoint id where claims (minting) are permitted.
    uint32 public immutable homeChainEid;

    /// @notice Merkle root governing valid (user, amount) allocations.
    bytes32 public merkleRoot;

    /// @notice Amount already claimed by each user; non-zero guards double claims.
    mapping(address => uint256) public claimed;

    /// @notice Constructs a plain GenesisCredit OFT instance.
    /// @dev The home-chain eid is immutable so a deployment cannot be repurposed to mint on a
    ///      foreign chain. ERC-20 metadata and the LayerZero endpoint/delegate are forwarded to
    ///      the OFT constructor. `Ownable(delegate_)` is called explicitly because OFTCore's
    ///      constructor does not forward `_delegate` to its Ownable base; `delegate_` thus becomes
    ///      both the contract owner (gating setMerkleRoot) and the LayerZero admin delegate
    ///      registered on the endpoint.
    /// @param name_ Human-readable token name.
    /// @param symbol_ Token ticker symbol.
    /// @param lzEndpoint_ Local LayerZero endpoint address.
    /// @param delegate_ Initial owner and LayerZero admin delegate.
    /// @param homeChainEid_ LayerZero endpoint id where claims are allowed.
    constructor(
        string memory name_,
        string memory symbol_,
        address lzEndpoint_,
        address delegate_,
        uint32 homeChainEid_
    ) OFT(name_, symbol_, lzEndpoint_, delegate_) Ownable(delegate_) {
        homeChainEid = homeChainEid_;
    }

    /// @notice Sets the merkle root used to verify claims.
    /// @dev Owner-only (OAppCore Ownable); expected to be set after deployment once the airdrop
    ///      tree is finalized.
    /// @param newMerkleRoot Root of the (user, amount) allocation tree.
    function setMerkleRoot(bytes32 newMerkleRoot) external override onlyOwner {
        merkleRoot = newMerkleRoot;
        emit MerkleRootSet(newMerkleRoot);
    }

    /// @notice Merkle airdrop claim. Only callable on the home chain.
    /// @dev Order matters: chain gate -> amount -> double-claim -> proof. Total supply is not
    ///      capped locally; it is bounded upstream by the POLendUpgradeable debt cap + aggregate
    ///      `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` that governs how much credit-minted debt may enter
    ///      a verse. Each user may claim at most once (`claimed` guard).
    /// @param amount Allocation amount for msg.sender.
    /// @param merkleProof Merkle proof for (msg.sender, amount) leaf.
    function claim(uint256 amount, bytes32[] calldata merkleProof) external override {
        // Home-chain gate: remote deployments bridge supply, they must never mint via claims.
        require(endpoint.eid() == homeChainEid, NotHomeChain(homeChainEid));
        require(amount != 0, ZeroInput());
        require(claimed[msg.sender] == 0, AlreadyClaimed());

        // Double-hash leaf defends against second-preimage attacks on the inner node.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        require(MerkleProof.verifyCalldata(merkleProof, merkleRoot, leaf), InvalidProof());

        claimed[msg.sender] = amount;
        _mint(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Standard self-burn (caller burns own balance).
    /// @param amount Amount of tokens to burn.
    function burn(uint256 amount) external override {
        require(amount != 0, ZeroInput());
        _burn(msg.sender, amount);
    }
}
