// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseLauncher} from "./IMemeverseLauncher.sol";

/// @title IMemeverseLaunchImpl
/// @notice Selector interface for the MemeverseLaunchImpl delegatecall sibling. The MemeverseLauncher
///         facade encodes these selectors when delegatecalling into the launch sibling, and the sibling
///         uses `IMemeverseLiquidityImpl.deployBootstrapLiquidity.selector` and
///         `IMemeverseSettlementImpl.unlockFromLocked.selector` for its nested delegatecalls. Each
///         signature must match the implementation byte-for-byte so the delegatecall selector resolves
///         correctly.
interface IMemeverseLaunchImpl {
    /// @notice Register a new memeverse: deploy memecoin/POL, wire LayerZero peers, store verse config.
    /// @dev Invoked via delegatecall by the facade's `registerMemeverse`. Under delegatecall `msg.sender`
    ///      is the original caller (must equal `memeverseRegistrar`) and `address(this)` is the launcher
    ///      proxy (token custody, OFT owner, POLend market registration source).
    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        address uAsset,
        bool flashGenesis
    ) external;

    /// @notice Deposit uAsset into the genesis pool on behalf of `user`.
    /// @dev Invoked via delegatecall by the facade's `genesis`. Under delegatecall `msg.sender` is the
    ///      original caller (transfer-in payer) and `address(this)` is the launcher proxy.
    function genesis(uint256 verseId, uint256 amountInUAsset, address user) external;

    /// @notice Deposit uAsset into the preorder pool on behalf of `user` during Genesis.
    /// @dev Invoked via delegatecall by the facade's `preorder`. Under delegatecall `msg.sender` is the
    ///      original caller (transfer-in payer) and `address(this)` is the launcher proxy.
    function preorder(uint256 verseId, uint256 amountInUAsset, address user) external;

    /// @notice Atomically deposit into the genesis pool then the preorder pool for the same `user`.
    /// @dev Invoked via delegatecall by the facade's `genesisAndPreorder`. Runs the genesis leg first so the
    ///      preorder leg's capacity check sees the enlarged `totalNormalFunds`. Signature must match the
    ///      implementation byte-for-byte so the delegatecall selector resolves correctly. Under delegatecall
    ///      `msg.sender` is the original caller (transfer-in payer for both legs) and `address(this)` is the
    ///      launcher proxy.
    function genesisAndPreorder(uint256 verseId, uint256 genesisAmount, uint256 preorderAmount, address user) external;

    /// @notice Adaptively advance the verse stage (Genesis -> Locked/Refund, Locked -> Unlocked).
    /// @dev Invoked via delegatecall by the facade's `changeStage`. Owns the stage transition, the nested
    ///      delegatecalls into the liquidity and settlement siblings, and the `ChangeStage` emit. Under
    ///      delegatecall `msg.sender` is the facade's caller (arbitrary stage advancer) and `address(this)`
    ///      is the launcher proxy.
    function changeStage(uint256 verseId) external returns (IMemeverseLauncher.Stage currentStage);
}
