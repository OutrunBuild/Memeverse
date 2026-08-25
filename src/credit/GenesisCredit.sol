// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
 *      The owner can also `pause()`/`unpause()` as an emergency switch that blocks every ERC-20
 *      state change, including bridging in both directions.
 */
contract GenesisCredit is OFT, ERC20Pausable, IGenesisCredit {
    /// @notice LayerZero endpoint id where claims (minting) are permitted.
    uint32 public immutable homeChainEid;

    /// @notice Merkle root governing valid (user, amount) allocations.
    bytes32 public merkleRoot;

    /// @notice Amount already claimed by each user; non-zero guards double claims.
    mapping(address => uint256) public claimed;

    /// @notice Reverts when ownership renunciation is attempted.
    /// @dev Repo invariant: ownership is never renounceable.
    error OwnershipRenounceDisabled();

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

    /// @inheritdoc IGenesisCredit
    /// @dev Owner-only (OAppCore Ownable); callable infinitely with no on-chain timelock,
    ///      review window, or finalization flag. Expected to be set after deployment once the
    ///      airdrop tree is finalized; unclaimed allocations can be overwritten by a later
    ///      root while already-claimed entries stay blocked by `claimed` (never cleared by
    ///      `setMerkleRoot`). Use an off-chain multisig/timelock for the owner and monitor
    ///      `MerkleRootSet` for unexpected rotations — chain emits only this event with no
    ///      old-value field.
    function setMerkleRoot(bytes32 newMerkleRoot) external override onlyOwner {
        merkleRoot = newMerkleRoot;
        emit MerkleRootSet(newMerkleRoot);
    }

    /// @inheritdoc IGenesisCredit
    /// @dev Owner-only (same OZ Ownable as `setMerkleRoot`). ERC20Pausable's `_update` is the
    ///      most-derived override of ERC-20's single state-change chokepoint, which `_transfer`,
    ///      `_mint` and `_burn` all route through — so a pause also blocks claims (mint) and OFT
    ///      bridging in both directions (send burns on the source chain, lzReceive mints on the
    ///      destination chain). A paused token cannot move supply anywhere.
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IGenesisCredit
    /// @dev Owner-only (same OZ Ownable as `setMerkleRoot`).
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @inheritdoc IGenesisCredit
    /// @dev Order matters: chain gate -> amount -> double-claim -> proof. Total supply is not
    ///      capped locally; `POLendUpgradeable`'s `MAX_SUPPORTED_TOTAL_GENESIS_FUNDS` +
    ///      `_debtCap` only bounds how much credit-minted *debt* may enter a verse via
    ///      `leveragedGenesisWithCredit` (excess credit is rejected for debt entry, not for
    ///      circulation). Minted credit remains a normal ERC20/OFT token and stays
    ///      transferable/bridgeable even when debt caps are hit. Each user may claim at
    ///      most once (`claimed` guard, never cleared by `setMerkleRoot`).
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

    /// @inheritdoc IGenesisCredit
    function burn(uint256 amount) external override {
        require(amount != 0, ZeroInput());
        _burn(msg.sender, amount);
    }

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev The OZ `Ownable` base (inherited through the OFT stack) exposes `renounceOwnership`;
    ///      this override makes it always revert, keeping the repo-wide never-renounceable
    ///      ownership invariant.
    function renounceOwnership() public override {
        revert OwnershipRenounceDisabled();
    }

    /// @dev Bridges IGenesisCredit.paused() to OZ Pausable's getter. Both an interface branch and
    ///      a contract branch declare `paused()`, so Solidity requires this explicit override.
    function paused() public view override(IGenesisCredit, Pausable) returns (bool) {
        return super.paused();
    }

    /// @dev Solidity requires an explicit disambiguation because `ERC20._update` is reachable via
    ///      both the OFT branch and ERC20Pausable. `super` dispatches to ERC20Pausable's override
    ///      (the pause gate) which then runs ERC20's `_update`. This is what makes the pause a
    ///      total block: `_transfer`, `_mint` (claim / OFT receive) and `_burn` (self-burn / OFT
    ///      send) all funnel through `_update`.
    function _update(address from, address to, uint256 value) internal override(ERC20Pausable, ERC20) {
        super._update(from, to, value);
    }
}
