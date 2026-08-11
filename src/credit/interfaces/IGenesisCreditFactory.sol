// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title IGenesisCreditFactory
/// @notice Interface for the factory that deploys GenesisCredit instances via CREATE3.
/// @dev Each (uAsset -> credit) pair maps to a deterministic CREATE3 address derived from
///      `keccak256(abi.encode(uAsset))` where the factory self-inlines CREATE3; the namespace is
///      the factory's own address. The factory deploys the full GenesisCredit contract (not a clone):
///      GenesisCredit is a plain (non-initializable) OFT, so its constructor runs once at CREATE3
///      deployment and the instance is immediately usable with no separate initialize step.
interface IGenesisCreditFactory {
    /// @notice Reverts when a credit token has already been deployed for the given uAsset.
    error AlreadyDeployed();

    /// @notice Reverts when the uAsset argument is the zero address.
    error ZeroUAsset();

    /// @notice Reverts when the factory is constructed with a zero-address endpoint.
    error ZeroAddress();

    /// @notice Reverts when the factory is constructed with a zero home-chain eid.
    error ZeroHomeChainEid();

    /// @notice Reverts when `deployCredit` is called with a zero-address delegate.
    error ZeroDelegate();

    /// @notice Reverts when `deployCredit` is called for a uAsset whose decimals are not 18.
    /// @dev GenesisCredit is fixed at 18 decimals; credit-path raw-unit 1:1 accounting only holds
    ///      when the uAsset is also 18 decimals. Non-18-dec uAssets must not get a GenesisCredit.
    error InvalidUAssetDecimals(uint8 actual, uint8 expected);

    /// @notice Emitted when a new GenesisCredit is deployed for a uAsset.
    /// @param uAsset The underlying asset key the credit token is tied to.
    /// @param credit The deployed GenesisCredit address.
    event CreditDeployed(address indexed uAsset, address indexed credit);

    /// @notice Deploys a new GenesisCredit for `uAsset` via CREATE3.
    /// @dev Reverts with `AlreadyDeployed()` if a credit already exists for `uAsset`,
    ///      `ZeroUAsset()` when `uAsset` is the zero address, and `ZeroDelegate()` when `delegate`
    ///      is the zero address. Deployment is deterministic CREATE3
    ///      where the factory self-inlines CREATE3 (deployer = factory itself), so the resulting
    ///      address matches `predictCredit(uAsset)`. The GenesisCredit constructor runs in-line;
    ///      no initialize step.
    /// @param uAsset Underlying asset key identifying the credit token.
    /// @param name ERC-20 token name.
    /// @param symbol ERC-20 token symbol.
    /// @param delegate Initial owner and LayerZero admin delegate of the credit token.
    /// @return credit The deployed GenesisCredit address.
    function deployCredit(address uAsset, string calldata name, string calldata symbol, address delegate)
        external
        returns (address credit);

    /// @notice Predicts the deterministic CREATE3 address of the GenesisCredit for `uAsset`.
    /// @dev Pure function of `(factory, uAsset)`; stable across calls and chains where the
    ///      factory address coincides.
    /// @param uAsset Underlying asset key.
    /// @return credit The address where the credit token would be deployed, or already is.
    function predictCredit(address uAsset) external view returns (address credit);

    /// @notice Returns the already-deployed GenesisCredit address for `uAsset`, or address(0).
    /// @param uAsset Underlying asset key.
    /// @return credit The deployed GenesisCredit address, or zero if none.
    function creditOf(address uAsset) external view returns (address credit);
}
