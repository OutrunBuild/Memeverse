// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseOFTEnum} from "../../common/types/IMemeverseOFTEnum.sol";
import {ICrossChainSendErrors} from "../../common/types/ICrossChainSendErrors.sol";

/**
 * @title MemeverseLauncher interface
 */
interface IMemeverseLauncher is IMemeverseOFTEnum, ICrossChainSendErrors {
    enum Stage {
        Genesis,
        Refund,
        Locked,
        Unlocked
    }

    event BootstrapUnusedAssetsHandled(
        uint256 indexed verseId,
        address indexed uAsset,
        address indexed memecoin,
        uint256 unusedUAsset,
        uint256 creditedSettlementDustReserve,
        uint256 treasuryExcess,
        uint256 burnedMemecoin
    );

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct AuxiliaryLiquidity {
        uint256 polUAssetLpAmount;
        uint256 ptUAssetLpAmount;
        uint256 ptPolLpAmount;
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    /// PT here denotes the Principal Token minted by `POLSplitter` (the principal half of a POL split; the yield
    /// half is the YT, Yield Token).
    struct BootstrapResidualClaims {
        uint256 normalResidualPOL;
        uint256 normalResidualPT;
        uint256 leveragedResidualPOL;
        uint256 leveragedResidualPT;
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct Memeverse {
        string name; // Token name
        string symbol; // Token symbol
        string uri; // Token icon uri
        string desc; // Description
        address uAsset; // Historical field name for the verse uAsset
        address memecoin; // Omnichain memecoin address
        address pol; // POL token address
        address yieldVault; // Memecoin yield vault
        address governor; // Memecoin DAO governor
        address incentivizer; // Governance cycle incentivizer
        uint128 endTime; // End time of Genesis stage
        uint128 unlockTime; // UnlockTime of liquidity
        uint32[] omnichainIds; // ChainIds of the token's omnichain(EVM),The first chainId is main governance chain
        Stage currentStage; // Current stage
        bool flashGenesis; // Allowing the transition to the liquidity lock stage once the minimum funding requirement is met, without waiting for the genesis stage to end.
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct FundMetaData {
        uint256 minTotalFund; // The minimum participation genesis fund corresponding to uAsset
        uint256 fundBasedAmount; // The number of Memecoins minted per unit of Memecoin genesis fund
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct GenesisData {
        uint256 genesisFund; // The amount of uAsset user has contributed to the genesis fund
        bool isRefunded; // Whether the user has refunded the uAsset contribution
        bool isRedeemed; // Whether the user has redeemed the POL liquidity
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct PreorderData {
        uint256 funds; // The amount of uAsset user has contributed to the preorder pool
        uint256 claimedMemecoin; // The amount of preorder memecoin already claimed by the user
        bool isRefunded; // Whether the user has refunded the preorder contribution
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct PreorderState {
        uint256 totalFunds;
        uint256 settledMemecoin;
        uint40 settlementTimestamp;
    }

    /// @notice Allocation plan for the POL raised at genesis. Splits total POL into four bootstrap buckets
    /// (see `MemeverseLiquidityImpl._buildBootstrapPolPlan`): POL/uAsset pool, normal + leveraged PT split, PT/POL pool.
    struct BootstrapPolPlan {
        uint256 polForPolUAsset;
        uint256 normalPolToSplit;
        uint256 leveragedPolToSplit;
        uint256 polForPtPol;
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct NormalFeeState {
        uint256 accUAssetFee;
        uint256 accPTFee;
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct UserNormalFeeClaim {
        uint256 claimedUAssetFee;
        uint256 claimedPTFee;
    }

    /// @notice Storage struct. When adding fields in upgrades, append only at the end.
    struct PendingAuxiliaryGovFeeState {
        uint256 pendingUAssetFee;
        uint256 pendingPTFee;
    }

    struct RedeemedFeeState {
        uint256 uAssetFee;
        uint256 memecoinFee;
        uint256 polFee;
        uint256 auxiliaryGovUAssetFee;
        uint256 auxiliaryGovPTFee;
    }

    /// @notice Bundle of launcher-configured contract addresses returned by `getLauncherContracts`.
    struct LauncherContracts {
        address localLzEndpoint;
        address lzEndpointRegistry;
        address yieldDispatcher;
        address memeverseRegistrar;
        address memeverseProxyDeployer;
        address memeverseSwapRouter;
        address polSplitter;
        address launchImpl;
        address memeverseUniswapHook;
        address settlementImpl;
        address feePreviewReader;
        address liquidityImpl;
    }

    /// @notice Bundle of launcher-configured numeric parameters returned by `getLauncherParameters`.
    struct LauncherParameters {
        uint256 executorRewardRate;
        uint256 preorderCapRatio;
        uint256 preorderVestingDuration;
        uint128 oftReceiveGasLimit;
        uint128 yieldDispatcherGasLimit;
    }

    /// @notice Returns all launcher-configured contract addresses in a single call.
    /// @dev Aggregates the previously separate address getters; intended for off-chain readers.
    /// @return contracts Launcher contract address bundle.
    function getLauncherContracts() external view returns (LauncherContracts memory contracts);

    /// @notice Returns all launcher-configured numeric parameters in a single call.
    /// @dev Aggregates the previously separate numeric getters; intended for off-chain readers.
    /// @return parameters Launcher numeric parameter bundle.
    function getLauncherParameters() external view returns (LauncherParameters memory parameters);

    /// @notice Returns the configured POLend contract.
    /// @return polend The POLend contract address.
    function polend() external view returns (address polend);

    /// @notice Returns total normal genesis funds for a verse.
    /// @param verseId Verse id to inspect.
    /// @return totalFunds Total non-leveraged uAsset funds recorded by the launcher.
    function totalNormalFunds(uint256 verseId) external view returns (uint256 totalFunds);

    /// @notice Returns the pending auxiliary governance fees accumulated for a verse.
    /// @dev Consumed by the fee preview reader to merge pending accumulated fees with live pool previews.
    /// @param verseId Verse id to inspect.
    /// @return pendingUAssetFee Pending uAsset-denominated governance fee.
    /// @return pendingPTFee Pending PT-denominated governance fee.
    function pendingAuxiliaryGovFeeStates(uint256 verseId)
        external
        view
        returns (uint256 pendingUAssetFee, uint256 pendingPTFee);

    /// @notice Returns fundraising metadata for a uAsset.
    /// @param uAsset Fundraising token address.
    /// @return minTotalFund Minimum total fund required for launch.
    /// @return fundBasedAmount Memecoin amount minted per unit of fundraising token.
    function fundMetaDatas(address uAsset) external view returns (uint256 minTotalFund, uint256 fundBasedAmount);

    /// @notice Returns the base amount POLend should use for verse debt capacity.
    /// @dev Reverts when the verse id does not map to a registered memeverse.
    /// @param verseId Verse id to inspect.
    /// @return debtCapBase Greater of current normal funds and the uAsset minimum total fund.
    function getDebtCapBaseByVerseId(uint256 verseId) external view returns (uint256 debtCapBase);

    /// @notice Returns how much aggregate Genesis funding capacity remains before launch accounting becomes unsupported.
    /// @dev Reverts when the verse id does not map to a registered memeverse.
    /// @param verseId Verse id to inspect.
    /// @return remaining Remaining aggregate capacity for `totalNormalFunds + totalLeveragedDebt`.
    function remainingGenesisCapacity(uint256 verseId) external view returns (uint256 remaining);

    /// @notice Resolves a memecoin back to its registered verse id.
    /// @dev Returns zero when the memecoin has never been registered through the launcher.
    /// @param memecoin Memecoin address to resolve.
    /// @return verseId Registered verse id, or zero when the memecoin is unknown.
    function getVerseIdByMemecoin(address memecoin) external view returns (uint256 verseId);

    /// @notice Loads the full launcher metadata for a verse id.
    /// @dev Reverts when the verse id does not map to a registered memeverse.
    /// @param verseId Verse id to inspect.
    /// @return verse Stored memeverse metadata.
    function getMemeverseByVerseId(uint256 verseId) external view returns (Memeverse memory verse);

    /// @notice Resolves the uAsset configured for a verse id.
    /// @dev Reverts when the verse id does not map to a registered memeverse.
    /// @param verseId Verse id to inspect.
    /// @return uAsset Stored verse uAsset.
    function getUAssetByVerseId(uint256 verseId) external view returns (address uAsset);

    /// @notice Loads launcher metadata by memecoin address.
    /// @dev Reverts when `memecoin` is zero or does not belong to a registered verse.
    /// @param memecoin Memecoin address to inspect.
    /// @return verse Stored memeverse metadata.
    function getMemeverseByMemecoin(address memecoin) external view returns (Memeverse memory verse);

    /// @notice Reads the current lifecycle stage for a verse id.
    /// @dev Reverts when the verse id is unknown.
    /// @param verseId Verse id to inspect.
    /// @return stage Current launcher stage.
    function getStageByVerseId(uint256 verseId) external view returns (Stage stage);

    /// @notice Reads the current lifecycle stage for a memecoin.
    /// @dev Resolves the memecoin into its verse id before reading launcher state.
    /// @param memecoin Memecoin address to inspect.
    /// @return stage Current launcher stage.
    function getStageByMemecoin(address memecoin) external view returns (Stage stage);

    /// @notice Resolves the yield vault configured for a verse id.
    /// @dev Reverts when the verse id is unknown.
    /// @param verseId Verse id to inspect.
    /// @return yieldVault Configured yield-vault address.
    function getYieldVaultByVerseId(uint256 verseId) external view returns (address yieldVault);

    /// @notice Resolves the governor configured for a verse id.
    /// @dev Reverts when the verse id is unknown.
    /// @param verseId Verse id to inspect.
    /// @return governor Configured governor address.
    function getGovernorByVerseId(uint256 verseId) external view returns (address governor);

    /// @notice Claims the caller's normal-genesis YT allocation after the verse reaches Locked.
    /// @dev Derived from the caller's genesis participation share and `totalNormalClaimableYT`.
    /// @param verseId Verse id to inspect.
    /// @return amount Claimable YT amount for the caller.
    function claimNormalYT(uint256 verseId) external returns (uint256 amount);

    /// @notice Claims the caller's accumulated normal-side auxiliary-pool fees.
    /// @dev Concrete fee accounting is launcher-defined.
    /// @param verseId Verse id to inspect.
    /// @return uAssetAmount Claimed uAsset amount.
    /// @return ptAmount Claimed PT amount.
    function claimNormalFees(uint256 verseId) external returns (uint256 uAssetAmount, uint256 ptAmount);

    /// @notice Redeems the caller's post-settlement auxiliary liquidity share.
    /// @dev Concrete redemption accounting is launcher-defined.
    /// @param verseId Verse id to inspect.
    /// @return polUAssetLpAmount Claimed POL/uAsset LP amount.
    /// @return ptUAssetLpAmount Claimed PT/uAsset LP amount.
    /// @return ptPolLpAmount Claimed PT/POL LP amount.
    function redeemAuxiliaryLiquidity(uint256 verseId)
        external
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount);

    /// @notice Settles the leveraged auxiliary-liquidity portion for POLend.
    /// @dev Concrete settlement accounting is launcher-defined.
    /// @param verseId Verse id to inspect.
    /// @return polAmount Settled POL amount.
    /// @return ptAmount Settled PT amount.
    /// @return uAssetAmount Settled uAsset amount.
    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount);

    /// @notice Quotes how much preorder memecoin the caller can unlock right now.
    /// @dev Uses the caller's settled preorder share and the linear vesting schedule.
    /// @param verseId Verse id to inspect.
    /// @return amount Currently claimable preorder memecoin amount.
    function claimablePreorderMemecoin(uint256 verseId) external view returns (uint256 amount);

    /// @notice Contributes uAsset into a verse during Genesis.
    /// @dev Records a normal Genesis contribution by increasing total normal funds and user genesis funds.
    ///      Liquidity split happens when the verse transitions to Locked.
    /// @param verseId Target verse id.
    /// @param amountInUAsset uAsset amount being contributed.
    /// @param user Account credited for the contribution.
    function genesis(uint256 verseId, uint256 amountInUAsset, address user) external;

    /// @notice Contributes uAsset into the preorder pool during Genesis.
    /// @dev Preorder capacity scales with the current memecoin-side genesis funding.
    /// @param verseId Target verse id.
    /// @param amountInUAsset uAsset amount being contributed.
    /// @param user Account credited for the preorder participation.
    function preorder(uint256 verseId, uint256 amountInUAsset, address user) external;

    /// @notice Atomically contribute uAsset to genesis then preorder for the same `user` in one transaction.
    /// @dev Runs genesis first to enlarge the preorder base, then preorder against the enlarged capacity,
    ///      removing the two-tx race where a standalone preorder could be front-run and fill the capacity the
    ///      genesis just opened. Both legs emit their own events and re-check the Genesis stage; a preorder cap
    ///      revert rolls back the genesis leg too.
    /// @param verseId Target verse id.
    /// @param genesisAmount uAsset contributed to the genesis pool.
    /// @param preorderAmount uAsset contributed to the preorder pool.
    /// @param user Account credited for both the genesis and the preorder participation.
    function genesisAndPreorder(uint256 verseId, uint256 genesisAmount, uint256 preorderAmount, address user) external;

    /// @notice Advances a verse to the next valid launcher stage.
    /// @dev Depending on timing and funding, this may settle Genesis, deploy liquidity, or move into Refund/Unlocked.
    /// @param verseId Target verse id.
    /// @return currentStage Stage after the transition attempt.
    function changeStage(uint256 verseId) external returns (Stage currentStage);

    /// @notice Refunds the caller's Genesis contribution in Refund stage.
    /// @dev Returns the exact uAsset amount previously recorded for the caller.
    /// @param verseId Verse id being refunded.
    /// @return userFunds Refunded uAsset amount.
    function refund(uint256 verseId) external returns (uint256 userFunds);

    /// @notice Refunds the caller's preorder contribution in Refund stage.
    /// @dev Returns the exact preorder uAsset amount previously recorded for the caller.
    /// @param verseId Verse id being refunded.
    /// @return preorderFund Refunded preorder uAsset amount.
    function refundPreorder(uint256 verseId) external returns (uint256 preorderFund);

    /// @notice Claims the caller's unlocked preorder memecoin allocation.
    /// @dev Transfers the caller's currently unlocked preorder memecoin amount.
    /// @param verseId The memeverse id.
    /// @return amount The claimed preorder memecoin amount.
    function claimUnlockedPreorderMemecoin(uint256 verseId) external returns (uint256 amount);

    /// @notice Redeems launcher-managed fees and distributes them to protocol recipients.
    /// @dev May perform same-chain transfers or cross-chain dispatches depending on verse configuration.
    ///      Requires exactly the native fee quoted by `IMemeverseFeePreviewReader.quoteDistributionLzFee`;
    ///      local/no-fee paths require zero.
    /// @param verseId The memeverse id.
    /// @param rewardReceiver The receiver of the executor reward.
    /// @return govFee The distributed governor fee amount.
    /// @return memecoinFee The distributed memecoin fee amount.
    /// @return polFee The distributed POL fee amount.
    /// @return executorReward The distributed executor reward amount.
    function redeemAndDistributeFees(uint256 verseId, address rewardReceiver)
        external
        payable
        returns (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward);

    /// @notice Redeems memecoin-side LP using POL, optionally unwrapping the LP into underlying assets.
    /// @dev When `unwrap` is false, transfers LP shares. When true, removes liquidity through the router and forwards the underlying.
    /// @param verseId The memeverse id.
    /// @param amountInPOL The POL amount to redeem.
    /// @param unwrap Whether to remove liquidity into underlying assets instead of transferring LP shares.
    /// @return amountInLP The redeemed memecoin LP amount.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        returns (uint256 amountInLP);

    /// @notice Mints POL against supplied uAsset and memecoin liquidity.
    /// @dev Uses the verse's router configuration to source the exact liquidity requirements.
    /// @param verseId The memeverse id.
    /// @param amountInUAssetDesired The desired uAsset budget.
    /// @param amountInMemecoinDesired The desired memecoin budget.
    /// @param amountInUAssetMin The minimum accepted uAsset spend.
    /// @param amountInMemecoinMin The minimum accepted memecoin spend.
    /// @param amountOutDesired The desired POL output amount.
    /// @param deadline The latest valid execution timestamp.
    /// @return amountInUAsset The actual uAsset amount spent.
    /// @return amountInMemecoin The actual memecoin amount spent.
    /// @return amountOut The POL amount minted.
    function mintPOLToken(
        uint256 verseId,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    ) external returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut);

    /// @notice Registers a new memeverse.
    /// @dev Deploys and stores verse metadata for a new memecoin launch.
    /// @param name The memecoin name.
    /// @param symbol The memecoin symbol.
    /// @param uniqueId The unique identifier used to derive the verse id.
    /// @param endTime The Genesis end timestamp.
    /// @param unlockTime The liquidity unlock timestamp.
    /// @param omnichainIds The supported omnichain ids with governance chain first.
    /// @param uAsset The verse uAsset address.
    /// @param flashGenesis Whether early stage transition is enabled once minimum funding is met.
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

    /// @notice Withdraws stranded native gas dust from the launcher.
    /// @dev Intended for owner cleanup of residual native balances.
    /// @param receiver The recipient of the dust amount.
    function removeGasDust(address receiver) external;

    /// @notice Repoints the launcher to a new swap router.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param memeverseSwapRouter The new router address.
    function setMemeverseSwapRouter(address memeverseSwapRouter) external;

    /// @notice Initializes the launcher's hook binding.
    /// @dev The hook binding is write-once because live pool identities include the hook address.
    /// @param memeverseHook The hook address to bind permanently.
    function setMemeverseUniswapHook(address memeverseHook) external;

    /// @notice Repoints the launcher to a new LayerZero endpoint registry.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param lzEndpointRegistry The new endpoint registry contract address.
    function setLzEndpointRegistry(address lzEndpointRegistry) external;

    /// @notice Replaces the registrar contract reference used by the launcher.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param memeverseRegistrar The new registrar address.
    function setMemeverseRegistrar(address memeverseRegistrar) external;

    /// @notice Replaces the proxy deployer used for verse module deployment.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param memeverseProxyDeployer The new proxy deployer address.
    function setMemeverseProxyDeployer(address memeverseProxyDeployer) external;

    /// @notice Replaces the yield dispatcher contract reference.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param yieldDispatcher The new yield dispatcher address.
    function setYieldDispatcher(address yieldDispatcher) external;

    /// @notice Sets the MemeverseLaunchImpl sibling implementation that runs verse registration, genesis/preorder
    ///         deposits, and adaptive stage transitions.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param launchImpl The MemeverseLaunchImpl sibling address.
    function setLaunchImpl(address launchImpl) external;

    /// @notice Sets the MemeverseSettlementImpl sibling implementation invoked via delegatecall for fee
    ///         collection and distribution.
    /// @dev Implementations are expected to guard this with their admin or owner flow. The facade
    ///      delegatecalls into this sibling, so a zero address would delegatecall into address(0).
    /// @param settlementImpl The MemeverseSettlementImpl sibling address.
    function setSettlementImpl(address settlementImpl) external;

    /// @notice Sets the independent fee-preview reader contract used for off-chain fee previews.
    /// @dev Implementations are expected to guard this with their admin or owner flow. The reader is a
    ///      standalone view contract (not a delegatecall target).
    /// @param feePreviewReader The fee-preview reader contract address.
    function setFeePreviewReader(address feePreviewReader) external;

    /// @notice Sets the MemeverseLiquidityImpl sibling implementation invoked via delegatecall for POL minting.
    /// @dev Implementations are expected to guard this with their admin or owner flow. The facade
    ///      delegatecalls into this sibling, so a zero address would delegatecall into address(0).
    /// @param liquidityImpl The MemeverseLiquidityImpl sibling address.
    function setLiquidityImpl(address liquidityImpl) external;

    /// @notice Sets the fund metadata used for a verse uAsset token.
    /// @dev `fundBasedAmount` controls launcher-side bootstrap pricing and may be bounded by the implementation.
    /// @param uAsset The fundraising token address.
    /// @param minTotalFund The minimum total genesis fund required for the token.
    /// @param fundBasedAmount The memecoin amount minted per unit of fundraising token.
    function setFundMetaData(address uAsset, uint256 minTotalFund, uint256 fundBasedAmount) external;

    /// @notice Updates the executor reward rate used by fee distribution.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param executorRewardRate The new reward rate in protocol ratio units.
    function setExecutorRewardRate(uint256 executorRewardRate) external;

    /// @notice Updates the launcher-wide preorder cap and vesting configuration.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param preorderCapRatio The preorder capacity ratio in `RATIO` precision.
    /// @param preorderVestingDuration The linear vesting duration for preorder memecoin.
    function setPreorderConfig(uint256 preorderCapRatio, uint256 preorderVestingDuration) external;

    /// @notice Updates the gas budgets used for launcher cross-chain calls.
    /// @dev Implementations are expected to guard this with their admin or owner flow.
    /// @param oftReceiveGasLimit The gas limit used for OFT receives.
    /// @param yieldDispatcherGasLimit The gas limit used for yield dispatcher compose dispatches.
    function setGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit) external;

    /// @notice Updates the external metadata for a verse.
    /// @dev Stores presentation metadata and community links for the verse.
    /// @param verseId The memeverse id.
    /// @param uri The external metadata URI.
    /// @param description The external description text.
    /// @param communities The community link list.
    function setExternalInfo(
        uint256 verseId,
        string calldata uri,
        string calldata description,
        string[] calldata communities
    ) external;

    /// @notice Quotes the preorder capacity still open for a verse.
    /// @dev Capacity is derived from the current memecoin-side genesis funds and the configured cap ratio.
    /// @param verseId The memeverse id.
    /// @return remaining The remaining preorder uAsset capacity.
    function previewPreorderCapacity(uint256 verseId) external view returns (uint256 remaining);

    error ZeroInput();

    error InvalidLength();

    error InvalidClaim();

    error NoPOLAvailable();

    error InvalidPreorderSettlementConfig();

    error HookAlreadyConfigured();

    error NotRefundStage();

    error InvalidVerseId();

    error NotGenesisStage();

    error FeeRateOverFlow();

    error PermissionDenied();

    error NotUnlockedStage();

    error InvalidLzFee(uint256 expected, uint256 actual);

    error ReachedFinalStage();

    error InsufficientLPBalance();

    error NotReachedLockedStage();

    error StillInGenesisStage(uint256 endTime);

    error InvalidOmnichainId(uint32 omnichainId);

    error FundBasedAmountTooHigh(uint256 fundBasedAmount, uint256 maxSupportedFundBasedAmount);
    error TotalGenesisFundsTooHigh(uint256 totalGenesisFunds, uint256 maxSupportedTotalGenesisFunds);

    /// @dev Reverted when the derived yield-vault virtual buffer
    ///      `V = minTotalFund * fundBasedAmount * 7 / 1000` would round to zero; such a config makes
    ///      `MemecoinYieldVault.initialize` revert `ZeroVirtualAssets()` and DoS governance-chain deploy.
    error VirtualAssetsTooLow();

    /// @dev Reverted when the owner has not configured the launch sibling the facade delegatecalls into.
    error LaunchImplNotSet();

    /// @dev Reverted when the owner has not configured the settlement sibling the facade delegatecalls into.
    error SettlementImplNotSet();

    /// @dev Reverted when the owner has not configured the liquidity sibling the facade delegatecalls into.
    error LiquidityImplNotSet();

    event Genesis(uint256 indexed verseId, address indexed depositer, uint256 amount);

    event ChangeStage(uint256 indexed verseId, Stage currentStage);

    event Refund(uint256 indexed verseId, address indexed receiver, uint256 refundAmount);

    event RefundPreorder(uint256 indexed verseId, address indexed receiver, uint256 refundAmount);

    event ClaimNormalYT(uint256 indexed verseId, address indexed receiver, uint256 claimedAmount);

    event ClaimNormalFees(uint256 indexed verseId, address indexed receiver, uint256 uAssetAmount, uint256 ptAmount);

    event RedeemAndDistributeFees(
        uint256 indexed verseId, uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward
    );

    event RedeemMemecoinLiquidity(uint256 indexed verseId, address indexed receiver, uint256 memecoinLiquidity);

    event MintPOLToken(
        uint256 indexed verseId, address indexed memecoin, address indexed pol, address receiver, uint256 amount
    );

    event RegisterMemeverse(uint256 indexed verseId, Memeverse verse);

    event RemoveGasDust(address indexed receiver, uint256 dust);

    event SetMemeverseSwapRouter(address memeverseSwapRouter);

    event SetMemeverseUniswapHook(address memeverseHook);

    event SetLzEndpointRegistry(address lzEndpointRegistry);

    event SetMemeverseRegistrar(address memeverseRegistrar);

    event SetMemeverseProxyDeployer(address memeverseProxyDeployer);

    event SetYieldDispatcher(address yieldDispatcher);

    /// @dev Emitted when the owner repoints the facade to a new launch sibling implementation.
    event SetLaunchImpl(address indexed launchImpl);

    /// @dev Emitted when the owner repoints the facade to a new settlement sibling implementation.
    event SetSettlementImpl(address indexed settlementImpl);

    /// @dev Emitted when the owner repoints the facade to a new fee-preview reader contract.
    event SetFeePreviewReader(address indexed feePreviewReader);

    /// @dev Emitted when the owner repoints the facade to a new liquidity sibling implementation.
    event SetLiquidityImpl(address indexed liquidityImpl);

    event SetFundMetaData(address indexed uAsset, uint256 minTotalFund, uint256 fundBasedAmount);

    event SetExecutorRewardRate(uint256 executorRewardRate);

    event SetPreorderConfig(uint256 preorderCapRatio, uint256 preorderVestingDuration);

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit);

    event SetExternalInfo(uint256 indexed verseId, string uri, string description, string[] community);

    event Preorder(uint256 indexed verseId, address indexed caller, address indexed user, uint256 amountInUAsset);

    event ClaimPreorderMemecoin(uint256 indexed verseId, address indexed user, uint256 amount);

    event RedeemAuxiliaryLiquidity(
        uint256 indexed verseId,
        address indexed user,
        uint256 polUAssetLpAmount,
        uint256 ptUAssetLpAmount,
        uint256 ptPolLpAmount
    );
}
