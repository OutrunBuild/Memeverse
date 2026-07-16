// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseLauncher} from "./IMemeverseLauncher.sol";

/// @notice Storage layout for the MemeverseLauncher ERC-7201 namespace.
///         Shared between the MemeverseLauncher facade and its delegatecall siblings
///         (MemeverseLaunchImpl, MemeverseSettlementImpl, MemeverseLiquidityImpl) so all bind the same struct to the same
///         ERC-7201 base slot via `layout at erc7201(...)`.
///         Nested value types (Memeverse, FundMetaData, etc.) are members of `IMemeverseLauncher`,
///         so they are referenced via that interface rather than redeclared here.
///         When adding fields in upgrades, append only at the end. Never reorder or insert fields.
/// @custom:storage-location erc7201:outrun.storage.MemeverseLauncher
struct MemeverseLauncherStorage {
    address localLzEndpoint;
    address lzEndpointRegistry;
    address yieldDispatcher;
    address memeverseRegistrar;
    address memeverseProxyDeployer;
    address memeverseSwapRouter;
    address memeverseUniswapHook;
    address polend;
    address polSplitter;
    uint256 executorRewardRate;
    uint256 preorderCapRatio;
    uint256 preorderVestingDuration;
    uint128 oftReceiveGasLimit;
    uint128 yieldDispatcherGasLimit;
    mapping(address pol => uint256) polToIds;
    mapping(address memecoin => uint256) memecoinToIds;
    mapping(uint256 verseId => IMemeverseLauncher.Memeverse) memeverses;
    mapping(address uAsset => IMemeverseLauncher.FundMetaData) fundMetaDatas;
    mapping(uint256 verseId => uint256) totalNormalFunds;
    mapping(uint256 verseId => IMemeverseLauncher.PreorderState) preorderStates;
    mapping(uint256 verseId => IMemeverseLauncher.AuxiliaryLiquidity) auxiliaryLiquidities;
    mapping(uint256 verseId => IMemeverseLauncher.BootstrapResidualClaims) bootstrapResidualClaims;
    mapping(uint256 verseId => uint256) totalNormalClaimableYT;
    mapping(uint256 verseId => mapping(address account => bool)) normalYTClaimed;
    mapping(uint256 verseId => mapping(address account => IMemeverseLauncher.GenesisData)) userGenesisData;
    mapping(uint256 verseId => mapping(address account => IMemeverseLauncher.PreorderData)) userPreorderData;
    mapping(uint256 verseId => mapping(uint256 provider => string)) communitiesMap;
    mapping(uint256 verseId => IMemeverseLauncher.NormalFeeState) normalFeeStates;
    mapping(uint256 verseId => mapping(address account => IMemeverseLauncher.UserNormalFeeClaim)) userNormalFeeClaims;
    mapping(uint256 verseId => IMemeverseLauncher.PendingAuxiliaryGovFeeState) pendingAuxiliaryGovFeeStates;
    address launchImpl; // appended at end — ERC-7201 allows append-only growth
    address settlementImpl; // appended — delegatecall target for fee distribution (Step C)
    address feePreviewReader; // appended — independent view contract for fee previews (Step C)
    address liquidityImpl; // appended — delegatecall target for POL minting (Step D)
}
