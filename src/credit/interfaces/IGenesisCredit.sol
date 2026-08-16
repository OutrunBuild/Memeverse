// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title IGenesisCredit
/// @notice Interface for the GenesisCredit ERC20 merkle-airdrop token.
/// @dev GenesisCredit is a home-chain-only claimable credit token. It is minted
///      via a merkle airdrop on the home chain and can be burned by holders.
///      Non-home chains must never allow minting through claims.
interface IGenesisCredit {
    error ZeroInput();
    error NotHomeChain(uint32 eid);
    error InvalidProof();
    error AlreadyClaimed();

    /// @notice Emitted when a user claims their merkle-allocation credit on the home chain.
    /// @param user Claimant address.
    /// @param amount Credit amount claimed.
    event Claimed(address indexed user, uint256 amount);

    /// @notice Emitted when the owner updates the merkle root governing valid claims.
    /// @param merkleRoot New merkle root.
    event MerkleRootSet(bytes32 merkleRoot);

    /// @notice Merkle airdrop claim. Only callable on the home chain.
    /// @param amount Allocation amount for msg.sender.
    /// @param merkleProof Merkle proof for (msg.sender, amount) leaf.
    function claim(uint256 amount, bytes32[] calldata merkleProof) external;

    /// @notice Standard self-burn (caller burns own balance).
    /// @param amount Credit amount to burn from msg.sender's balance.
    function burn(uint256 amount) external;

    /// @notice Set the merkle root used to verify claims.
    /// @param newMerkleRoot New merkle root governing valid claims.
    function setMerkleRoot(bytes32 newMerkleRoot) external;

    /// @notice Emergency stop: halts all token state changes (transfers, claims, burns and OFT
    ///         bridging in both directions). Reverts with `EnforcedPause` if already paused.
    function pause() external;

    /// @notice Lifts an existing pause so all token state changes resume. Reverts with
    ///         `ExpectedPause` if not currently paused.
    function unpause() external;

    /// @notice LayerZero endpoint id of the home chain where claims are allowed.
    function homeChainEid() external view returns (uint32);

    /// @notice Current merkle root governing valid claims.
    function merkleRoot() external view returns (bytes32);

    /// @notice Amount already claimed by a given user; guards double claims.
    /// @param user Claimant address.
    /// @return Credit amount the user has already claimed.
    function claimed(address user) external view returns (uint256);

    /// @notice Whether the token is currently paused (all token state changes revert).
    /// @return True when paused.
    function paused() external view returns (bool);
}
