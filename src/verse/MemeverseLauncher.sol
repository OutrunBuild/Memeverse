// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";
import {IMemeverseLaunchImpl} from "./interfaces/IMemeverseLaunchImpl.sol";
import {IMemeverseLiquidityImpl} from "./interfaces/IMemeverseLiquidityImpl.sol";
import {IMemeverseSettlementImpl} from "./interfaces/IMemeverseSettlementImpl.sol";
import {IMemeverseUniswapHook} from "../swap/interfaces/IMemeverseUniswapHook.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";

/**
 * @title Trapping into the memeverse
 * @dev Reentrancy strategy: this contract inherits `ReentrancyGuard` via `TokenHelper` and applies
 *      `nonReentrant` on `_transferOut` — the single exit point for all outbound token transfers.
 *      Public entry-point functions intentionally omit `nonReentrant` to avoid double-locking with
 *      the boolean-based guard. The exception is `changeStage`, which omits it because the
 *      Locked→Unlocked transition triggers cross-contract callbacks (`IPOLSplitter.settle`,
 *      `IPOLend.executeGlobalSettlement`) that must be able to re-enter the launcher.
 */
contract MemeverseLauncher layout at erc7201("outrun.storage.MemeverseLauncher")
    is
    IMemeverseLauncher,
    Initializable,
    OutrunOwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    TokenHelper
{
    using Address for address;

    uint256 public constant RATIO = 10000;
    uint256 internal constant MAX_FUND_BASED_AMOUNT = (1 << 64) - 1;

    /// @dev Namespaced storage. The contract header's `layout at erc7201(...)` binds this struct to
    ///      the ERC-7201 base slot of "outrun.storage.MemeverseLauncher" — identical to the prior
    ///      inline-assembly slot binding, so the on-chain storage layout is unchanged.
    MemeverseLauncherStorage private memeverseLauncherStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice This is the UUPS implementation contract. Do not call directly.
    ///         Use the proxy contract for all interactions.
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the launcher proxy.
     * @dev Deterministic dependencies may be predicted addresses during CREATE3 deployment, so initialization checks
     *      non-zero addresses and config bounds without requiring code to exist yet.
     */
    function initialize(
        address initialOwner,
        address localLzEndpoint_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address lzEndpointRegistry_,
        address polend_,
        address polSplitter_,
        uint256 executorRewardRate_,
        uint128 oftReceiveGasLimit_,
        uint128 yieldDispatcherGasLimit_,
        uint256 preorderCapRatio_,
        uint256 preorderVestingDuration_
    ) external initializer {
        __OutrunOwnable_init(initialOwner);
        __Pausable_init();
        require(
            localLzEndpoint_ != address(0) && memeverseRegistrar_ != address(0) && memeverseProxyDeployer_ != address(0)
                && yieldDispatcher_ != address(0) && lzEndpointRegistry_ != address(0) && polend_ != address(0)
                && polSplitter_ != address(0),
            ZeroInput()
        );
        require(oftReceiveGasLimit_ > 0 && yieldDispatcherGasLimit_ > 0, ZeroInput());
        require(preorderCapRatio_ != 0 && preorderVestingDuration_ != 0, ZeroInput());
        require(preorderCapRatio_ <= RATIO, FeeRateOverFlow());
        require(executorRewardRate_ < RATIO, FeeRateOverFlow());

        _storeInitializedConfig(
            localLzEndpoint_,
            memeverseRegistrar_,
            memeverseProxyDeployer_,
            yieldDispatcher_,
            lzEndpointRegistry_,
            polend_,
            polSplitter_,
            executorRewardRate_,
            oftReceiveGasLimit_,
            yieldDispatcherGasLimit_,
            preorderCapRatio_,
            preorderVestingDuration_
        );
    }

    function _storeInitializedConfig(
        address localLzEndpoint_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address lzEndpointRegistry_,
        address polend_,
        address polSplitter_,
        uint256 executorRewardRate_,
        uint128 oftReceiveGasLimit_,
        uint128 yieldDispatcherGasLimit_,
        uint256 preorderCapRatio_,
        uint256 preorderVestingDuration_
    ) internal {
        memeverseLauncherStorage.localLzEndpoint = localLzEndpoint_;
        memeverseLauncherStorage.memeverseRegistrar = memeverseRegistrar_;
        memeverseLauncherStorage.memeverseProxyDeployer = memeverseProxyDeployer_;
        memeverseLauncherStorage.yieldDispatcher = yieldDispatcher_;
        memeverseLauncherStorage.lzEndpointRegistry = lzEndpointRegistry_;
        memeverseLauncherStorage.polend = polend_;
        memeverseLauncherStorage.polSplitter = polSplitter_;
        memeverseLauncherStorage.executorRewardRate = executorRewardRate_;
        memeverseLauncherStorage.oftReceiveGasLimit = oftReceiveGasLimit_;
        memeverseLauncherStorage.yieldDispatcherGasLimit = yieldDispatcherGasLimit_;
        memeverseLauncherStorage.preorderCapRatio = preorderCapRatio_;
        memeverseLauncherStorage.preorderVestingDuration = preorderVestingDuration_;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    function getLauncherContracts() external view returns (LauncherContracts memory contracts) {
        contracts.localLzEndpoint = memeverseLauncherStorage.localLzEndpoint;
        contracts.lzEndpointRegistry = memeverseLauncherStorage.lzEndpointRegistry;
        contracts.yieldDispatcher = memeverseLauncherStorage.yieldDispatcher;
        contracts.memeverseRegistrar = memeverseLauncherStorage.memeverseRegistrar;
        contracts.memeverseProxyDeployer = memeverseLauncherStorage.memeverseProxyDeployer;
        contracts.memeverseSwapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        contracts.polSplitter = memeverseLauncherStorage.polSplitter;
        contracts.launchImpl = memeverseLauncherStorage.launchImpl;
        contracts.memeverseUniswapHook = memeverseLauncherStorage.memeverseUniswapHook;
        contracts.settlementImpl = memeverseLauncherStorage.settlementImpl;
        contracts.feePreviewReader = memeverseLauncherStorage.feePreviewReader;
        contracts.liquidityImpl = memeverseLauncherStorage.liquidityImpl;
    }

    function getLauncherParameters() external view returns (LauncherParameters memory parameters) {
        parameters.executorRewardRate = memeverseLauncherStorage.executorRewardRate;
        parameters.preorderCapRatio = memeverseLauncherStorage.preorderCapRatio;
        parameters.preorderVestingDuration = memeverseLauncherStorage.preorderVestingDuration;
        parameters.oftReceiveGasLimit = memeverseLauncherStorage.oftReceiveGasLimit;
        parameters.yieldDispatcherGasLimit = memeverseLauncherStorage.yieldDispatcherGasLimit;
    }

    function polend() external view override returns (address) {
        return memeverseLauncherStorage.polend;
    }

    function fundMetaDatas(address uAsset) external view override returns (uint256, uint256) {
        FundMetaData storage meta = memeverseLauncherStorage.fundMetaDatas[uAsset];
        return (meta.minTotalFund, meta.fundBasedAmount);
    }

    function memecoinToIds(address memecoin) external view returns (uint256) {
        return memeverseLauncherStorage.memecoinToIds[memecoin];
    }

    function polToIds(address pol) external view returns (uint256) {
        return memeverseLauncherStorage.polToIds[pol];
    }

    function totalNormalFunds(uint256 verseId) external view override returns (uint256) {
        return memeverseLauncherStorage.totalNormalFunds[verseId];
    }

    function auxiliaryLiquidities(uint256 verseId) external view returns (uint256, uint256, uint256) {
        AuxiliaryLiquidity storage liq = memeverseLauncherStorage.auxiliaryLiquidities[verseId];
        return (liq.polUAssetLpAmount, liq.ptUAssetLpAmount, liq.ptPolLpAmount);
    }

    function bootstrapResidualClaims(uint256 verseId) external view returns (uint256, uint256, uint256, uint256) {
        BootstrapResidualClaims storage claims = memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        return
            (claims.normalResidualPOL, claims.normalResidualPT, claims.leveragedResidualPOL, claims.leveragedResidualPT);
    }

    function totalNormalClaimableYT(uint256 verseId) external view returns (uint256) {
        return memeverseLauncherStorage.totalNormalClaimableYT[verseId];
    }

    function normalYTClaimed(uint256 verseId, address account) external view returns (bool) {
        return memeverseLauncherStorage.normalYTClaimed[verseId][account];
    }

    function userGenesisData(uint256 verseId, address account) external view returns (uint256, bool, bool) {
        GenesisData storage data = memeverseLauncherStorage.userGenesisData[verseId][account];
        return (data.genesisFund, data.isRefunded, data.isRedeemed);
    }

    function userPreorderData(uint256 verseId, address account) external view returns (uint256, uint256, bool) {
        PreorderData storage data = memeverseLauncherStorage.userPreorderData[verseId][account];
        return (data.funds, data.claimedMemecoin, data.isRefunded);
    }

    function communitiesMap(uint256 verseId, uint256 provider) external view returns (string memory) {
        return memeverseLauncherStorage.communitiesMap[verseId][provider];
    }

    function normalFeeStates(uint256 verseId) external view returns (uint256, uint256) {
        NormalFeeState storage state = memeverseLauncherStorage.normalFeeStates[verseId];
        return (state.accUAssetFee, state.accPTFee);
    }

    function userNormalFeeClaims(uint256 verseId, address account) external view returns (uint256, uint256) {
        UserNormalFeeClaim storage claim = memeverseLauncherStorage.userNormalFeeClaims[verseId][account];
        return (claim.claimedUAssetFee, claim.claimedPTFee);
    }

    function pendingAuxiliaryGovFeeStates(uint256 verseId) external view override returns (uint256, uint256) {
        PendingAuxiliaryGovFeeState storage state = memeverseLauncherStorage.pendingAuxiliaryGovFeeStates[verseId];
        return (state.pendingUAssetFee, state.pendingPTFee);
    }

    modifier versIdValidate(uint256 verseId) {
        _versIdValidate(verseId);
        _;
    }

    function _versIdValidate(uint256 verseId) internal view {
        require(memeverseLauncherStorage.memeverses[verseId].memecoin != address(0), InvalidVerseId());
    }

    function _verseIdOfRegisteredMemecoin(address memecoin) internal view returns (uint256 verseId) {
        require(memecoin != address(0), ZeroInput());
        verseId = memeverseLauncherStorage.memecoinToIds[memecoin];
        _versIdValidate(verseId);
    }

    /**
     * @notice Get the verse id by memecoin.
     * @dev Returns 0 when the memecoin has not been registered.
     * @param memecoin -The address of the memecoin.
     * @return verseId The verse id.
     */
    function getVerseIdByMemecoin(address memecoin) external view override returns (uint256 verseId) {
        require(memecoin != address(0), ZeroInput());
        verseId = memeverseLauncherStorage.memecoinToIds[memecoin];
    }

    /**
     * @notice Get the memeverse by verse id.
     * @dev Reverts when `verseId` is not registered.
     * @param verseId - The verse id.
     * @return verse - The memeverse.
     */
    function getMemeverseByVerseId(uint256 verseId) external view override returns (Memeverse memory verse) {
        _versIdValidate(verseId);
        verse = memeverseLauncherStorage.memeverses[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view override returns (address uAsset) {
        _versIdValidate(verseId);
        uAsset = memeverseLauncherStorage.memeverses[verseId].uAsset;
    }

    function getDebtCapBaseByVerseId(uint256 verseId) external view override returns (uint256 debtCapBase) {
        _versIdValidate(verseId);
        address uAsset = memeverseLauncherStorage.memeverses[verseId].uAsset;
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 minTotalFund = memeverseLauncherStorage.fundMetaDatas[uAsset].minTotalFund;
        debtCapBase = normalFunds > minTotalFund ? normalFunds : minTotalFund;
    }

    function remainingGenesisCapacity(uint256 verseId) external view override returns (uint256 remaining) {
        _versIdValidate(verseId);
        uint256 totalFunds = memeverseLauncherStorage.totalNormalFunds[verseId]
            + IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        if (totalFunds >= MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) return 0;
        return MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - totalFunds;
    }

    /**
     * @notice Get the memeverse by memecoin.
     * @dev Reverts when the memecoin is zero or not registered.
     * @param memecoin - The address of the memecoin.
     * @return verse - The memeverse.
     */
    function getMemeverseByMemecoin(address memecoin) external view override returns (Memeverse memory verse) {
        verse = memeverseLauncherStorage.memeverses[_verseIdOfRegisteredMemecoin(memecoin)];
    }

    /**
     * @notice Get the Stage by verse id.
     * @dev Reverts when `verseId` is not registered.
     * @param verseId - The verse id.
     * @return stage - The memeverse current stage.
     */
    function getStageByVerseId(uint256 verseId) external view override returns (Stage stage) {
        _versIdValidate(verseId);
        stage = memeverseLauncherStorage.memeverses[verseId].currentStage;
    }

    /**
     * @notice Get the Stage by memecoin.
     * @dev Returns the current stage for the memecoin's registered verse.
     * @param memecoin - The address of the memecoin.
     * @return stage - The memeverse current stage.
     */
    function getStageByMemecoin(address memecoin) external view override returns (Stage stage) {
        stage = memeverseLauncherStorage.memeverses[_verseIdOfRegisteredMemecoin(memecoin)].currentStage;
    }

    /**
     * @notice Get the yield vault by verse id.
     * @dev Reverts when `verseId` is zero.
     * @param verseId - The verse id.
     * @return yieldVault - The yield vault.
     */
    function getYieldVaultByVerseId(uint256 verseId) external view override returns (address yieldVault) {
        _versIdValidate(verseId);
        yieldVault = memeverseLauncherStorage.memeverses[verseId].yieldVault;
    }

    /**
     * @notice Get the governor by verse id.
     * @dev Reverts when `verseId` is zero.
     * @param verseId - The verse id.
     * @return governor - The governor.
     */
    function getGovernorByVerseId(uint256 verseId) external view override returns (address governor) {
        _versIdValidate(verseId);
        governor = memeverseLauncherStorage.memeverses[verseId].governor;
    }

    /**
     * @notice Preview claimable preorder memecoin of caller after preorder settlement.
     * @dev Uses the caller's stored preorder purchase and claim data as the claim basis.
     * @param verseId Memeverse id.
     * @return amount The currently claimable preorder memecoin amount.
     */
    function claimablePreorderMemecoin(uint256 verseId) public view override returns (uint256 amount) {
        return MemeverseLauncherLib.claimablePreorderMemecoinForAccount(memeverseLauncherStorage, verseId, msg.sender);
    }

    /**
     * @notice Preview the currently remaining preorder capacity for a verse.
     * @dev Capacity is computed from current memecoin-side genesis funds and the configured cap ratio.
     *      Routed through `MemeverseLauncherLib.preorderMaxCapacity` so the cap cannot drift from the
     *      launch sibling's preorder path, which uses the same helper.
     * @param verseId Memeverse id.
     * @return remaining The remaining preorder uAsset capacity.
     */
    function previewPreorderCapacity(uint256 verseId) public view override returns (uint256 remaining) {
        _versIdValidate(verseId);
        uint256 totalLeveragedDebt = IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalBaseFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 maxCapacity = MemeverseLauncherLib.preorderMaxCapacity(memeverseLauncherStorage, totalBaseFunds);
        uint256 usedCapacity = memeverseLauncherStorage.preorderStates[verseId].totalFunds;
        if (usedCapacity >= maxCapacity) return 0;
        return maxCapacity - usedCapacity;
    }

    /**
     * @dev Genesis memeverse by depositing uAsset
     * @param verseId - Memeverse id
     * @param amountInUAsset - Amount of uAsset
     * @param user - Address of user participating in the genesis
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint256 amountInUAsset, address user)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
    {
        // Delegatecall launch sibling: it enforces the stage/cap checks, updates accounting, transfers uAsset
        // in, AND emits Genesis. Facade emits nothing to avoid a double-emit under delegatecall (the sibling's
        // emit writes through this proxy's storage/code).
        address impl = memeverseLauncherStorage.launchImpl;
        require(impl != address(0), LaunchImplNotSet());
        impl.functionDelegateCall(
            abi.encodeWithSelector(IMemeverseLaunchImpl.genesis.selector, verseId, amountInUAsset, user)
        );
    }

    /**
     * @notice Deposit uAsset into the preorder pool during Genesis.
     * @dev The preorder pool is capped relative to the current memecoin-side genesis funds.
     * @param verseId Memeverse id.
     * @param amountInUAsset Amount of uAsset.
     * @param user Address of user participating in preorder.
     */
    function preorder(uint256 verseId, uint256 amountInUAsset, address user)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
    {
        // Delegatecall launch sibling: it enforces the stage/capacity checks, updates accounting, transfers
        // uAsset in, AND emits Preorder. Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.launchImpl;
        require(impl != address(0), LaunchImplNotSet());
        impl.functionDelegateCall(
            abi.encodeWithSelector(IMemeverseLaunchImpl.preorder.selector, verseId, amountInUAsset, user)
        );
    }

    /**
     * @notice Atomically contribute uAsset to genesis then preorder for the same `user` in one transaction.
     * @dev Eliminates the two-tx race where a standalone `preorder` could be front-run and fill the capacity
     *      the standalone `genesis` just opened. Thin delegatecall to the launch sibling, which runs both legs
     *      and emits `Genesis` and `Preorder`; the facade emits nothing (avoiding a double-emit under
     *      delegatecall).
     * @param verseId Memeverse id.
     * @param genesisAmount uAsset contributed to the genesis pool (enlarges the preorder base).
     * @param preorderAmount uAsset contributed to the preorder pool.
     * @param user Address credited for both the genesis and the preorder participation.
     */
    function genesisAndPreorder(uint256 verseId, uint256 genesisAmount, uint256 preorderAmount, address user)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
    {
        address impl = memeverseLauncherStorage.launchImpl;
        require(impl != address(0), LaunchImplNotSet());
        impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseLaunchImpl.genesisAndPreorder.selector, verseId, genesisAmount, preorderAmount, user
            )
        );
    }

    /// @notice Adaptively advance the verse stage (Genesis -> Locked/Refund, Locked -> Unlocked).
    /// @dev Delegatecalls the launch sibling, which owns the eligibility checks, stage transition, nested
    ///      delegatecalls into the liquidity/settlement siblings, and the `ChangeStage` emit. The facade keeps
    ///      only the outer `versIdValidate` guard and emits nothing (avoiding a double-emit under delegatecall).
    ///      Intentionally omits `whenNotPaused` (refund/settlement must remain executable during a pause) and
    ///      `nonReentrant` (the Locked->Unlocked transition relies on cross-contract callbacks from
    ///      `IPOLSplitter.settle` / `IPOLend.executeGlobalSettlement` that must re-enter the launcher).
    function changeStage(uint256 verseId) external override versIdValidate(verseId) returns (Stage currentStage) {
        require(verseId != 0, ZeroInput());
        address impl = memeverseLauncherStorage.launchImpl;
        require(impl != address(0), LaunchImplNotSet());
        currentStage = abi.decode(
            impl.functionDelegateCall(abi.encodeWithSelector(IMemeverseLaunchImpl.changeStage.selector, verseId)),
            (Stage)
        );
    }

    /**
     * @notice Refund uAsset after genesis failed because the omnichain funds did not meet the minimum requirement.
     * @dev Marks the caller as refunded before transferring funds out.
     * @param verseId - Memeverse id
     * @return genesisFund - The refunded genesis contribution amount.
     */
    function refund(uint256 verseId) external override versIdValidate(verseId) returns (uint256 genesisFund) {
        // Delegatecall sibling: it validates stage / claim eligibility, transfers uAsset, AND emits Refund.
        // Facade emits nothing to avoid a double-emit under delegatecall (the sibling's emit writes through
        // this proxy's storage/code).
        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        genesisFund = abi.decode(
            impl.functionDelegateCall(abi.encodeWithSelector(IMemeverseSettlementImpl.refund.selector, verseId)),
            (uint256)
        );
    }

    /**
     * @notice Refund uAsset after preorder became invalid because Genesis failed.
     * @dev Marks the caller as refunded before transferring funds out.
     * @param verseId Memeverse id.
     * @return preorderFund The refunded preorder contribution amount.
     */
    function refundPreorder(uint256 verseId) external override versIdValidate(verseId) returns (uint256 preorderFund) {
        // Delegatecall sibling: it validates stage / claim eligibility, transfers uAsset, AND emits RefundPreorder.
        // Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        preorderFund = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(IMemeverseSettlementImpl.refundPreorder.selector, verseId)
            ),
            (uint256)
        );
    }

    /**
     * @notice Claim the caller's share of normal YT (Yield Token) after Genesis stage resolves to Locked.
     * @dev Reads only pre-committed `totalNormalClaimableYT` and the one-shot `normalYTClaimed` flag.
     * @param verseId Memeverse id.
     * @return amount The claimed YT amount.
     */
    function claimNormalYT(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 amount)
    {
        // Delegatecall sibling: it validates stage / claim eligibility, transfers YT, AND emits ClaimNormalYT.
        // Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        amount = abi.decode(
            impl.functionDelegateCall(abi.encodeWithSelector(IMemeverseSettlementImpl.claimNormalYT.selector, verseId)),
            (uint256)
        );
    }

    /**
     * @notice Claim the caller's accumulated uAsset and PT fee entitlements.
     * @dev Reads pre-committed `feeState.accUAssetFee` and `feeState.accPTFee` accumulators.
     *      Uses CEI pattern (commit `claimedXxx` before external calls)
     *      to prevent double-claim; the trust boundary is the configured POLSplitter.
     * @param verseId Memeverse id.
     * @return uAssetAmount The claimed uAsset fee amount.
     * @return ptAmount The claimed PT fee amount.
     */
    function claimNormalFees(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 uAssetAmount, uint256 ptAmount)
    {
        // Delegatecall sibling: it validates stage / claim eligibility, transfers uAsset/PT, AND emits
        // ClaimNormalFees. Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        (uAssetAmount, ptAmount) = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(IMemeverseSettlementImpl.claimNormalFees.selector, verseId)
            ),
            (uint256, uint256)
        );
    }

    function redeemAuxiliaryLiquidity(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        // Delegatecall sibling: it enforces the Unlocked stage, reads genesis fund / auxiliary liquidity state,
        // transfers LP + residual claims, AND emits RedeemAuxiliaryLiquidity. Facade emits nothing to avoid
        // a double-emit under delegatecall (the sibling's emit writes through this proxy's storage/code).
        address impl = memeverseLauncherStorage.liquidityImpl;
        require(impl != address(0), LiquidityImplNotSet());
        (polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount) = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(IMemeverseLiquidityImpl.redeemAuxiliaryLiquidity.selector, verseId)
            ),
            (uint256, uint256, uint256)
        );
    }

    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        // POLend-callback ABI guard stays enforced on the facade: only POLend may invoke this entrypoint,
        // and only when the verse is Unlocked. The sibling performs the LP removal + residual claim transfer.
        require(msg.sender == memeverseLauncherStorage.polend, PermissionDenied());
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        address impl = memeverseLauncherStorage.liquidityImpl;
        require(impl != address(0), LiquidityImplNotSet());
        (polAmount, ptAmount, uAssetAmount) = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(IMemeverseLiquidityImpl.settleLeveragedAuxiliaryLiquidity.selector, verseId)
            ),
            (uint256, uint256, uint256)
        );
    }

    /**
     * @notice Claim unlocked preorder memecoin after preorder settlement.
     * @dev Transfers the caller's currently vested preorder memecoin balance.
     *      Reads only pre-committed `claimablePreorderMemecoin` and the cumulative `claimedMemecoin` counter.
     * @param verseId Memeverse id.
     * @return amount The claimed preorder memecoin amount.
     */
    function claimUnlockedPreorderMemecoin(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 amount)
    {
        // Delegatecall sibling: it computes the vested amount (via the shared lib helper), transfers memecoin,
        // AND emits ClaimPreorderMemecoin. Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        amount = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(IMemeverseSettlementImpl.claimUnlockedPreorderMemecoin.selector, verseId)
            ),
            (uint256)
        );
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(uAsset) and vault(Memecoin)
     * @param verseId - Memeverse id
     * @param rewardReceiver - Address of executor reward receiver
     * @return govFee - The uAsset-side gov fee.
     * @return memecoinFee - The memecoin fee.
     * @return polFee - The pol fee.
     * @return executorReward  - The executor reward.
     * @notice Anyone who calls this method will be rewarded with executorReward. Provide exactly the required native fee.
     * @dev Reads only pre-committed `RedeemedFeeState` accumulators.
     */
    function redeemAndDistributeFees(uint256 verseId, address rewardReceiver)
        external
        payable
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward)
    {
        require(rewardReceiver != address(0), ZeroInput());
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address impl = memeverseLauncherStorage.settlementImpl;
        require(impl != address(0), SettlementImplNotSet());
        address _polSplitter = memeverseLauncherStorage.polSplitter;
        bytes memory ret = impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseSettlementImpl.collectAndDistributeFees.selector, verseId, rewardReceiver, _polSplitter
            )
        );
        bool hadFees;
        (govFee, memecoinFee, polFee, executorReward, hadFees) =
            abi.decode(ret, (uint256, uint256, uint256, uint256, bool));
        // `hadFees` mirrors the distributor's `_hasNoRedeemedFees` gate, so the emit decision is byte-for-byte
        // equivalent to the original inline implementation (emit iff fees were collected). The no-fee path also
        // reverts InvalidLzFee inside the distributor when msg.value != 0.
        if (!hadFees) {
            return (0, 0, 0, 0);
        }
        emit RedeemAndDistributeFees(verseId, govFee, memecoinFee, polFee, executorReward);
    }

    /// @notice Redeems launcher-managed memecoin-side LP using POL, optionally unwrapping into underlying.
    ///         Approve this launcher proxy as a POL spender first (the burn is executed by the proxy on the
    ///         caller's behalf).
    /// @dev Intentionally omits `whenNotPaused`: users can always redeem their POL to exit the pool (after a
    ///      one-time approval of this launcher proxy as a POL spender, which the POL token never pauses). POL is
    ///      the caller's own asset — pausing this path would trap liquidity holders in an emergency. Protocol
    ///      pathways (polSplitter / polend) also rely on this remaining unpaused for settlement. The burn itself
    ///      is executed by this proxy on the caller's behalf via the POL allowance, not by the caller directly.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        override
        versIdValidate(verseId)
        returns (uint256 amountInLP)
    {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        // Delegatecall sibling: it burns the caller's POL, transfers/removes LP, AND emits
        // RedeemMemecoinLiquidity. Facade emits nothing to avoid a double-emit under delegatecall.
        address impl = memeverseLauncherStorage.liquidityImpl;
        require(impl != address(0), LiquidityImplNotSet());
        amountInLP = abi.decode(
            impl.functionDelegateCall(
                abi.encodeWithSelector(
                    IMemeverseLiquidityImpl.redeemMemecoinLiquidity.selector, verseId, amountInPOL, unwrap
                )
            ),
            (uint256)
        );
    }

    /**
     * @notice Mints POL by adding `uAsset/memecoin` liquidity after the verse reaches `Stage.Locked`.
     * @dev When `amountOutDesired == 0`, the router spends up to the provided budgets and returns the actual
     * `uAsset` and memecoin amounts it consumed. When `amountOutDesired != 0`, the launcher first asks the router
     * for the exact token amounts required for the target LP liquidity and then calls the detailed add-liquidity
     * entrypoint so the minted LP amount still fails closed if execution can no longer reach the requested output.
     * @param verseId Memeverse id.
     * @param amountInUAssetDesired Maximum uAsset budget transferred into the launcher.
     * @param amountInMemecoinDesired Maximum memecoin budget transferred into the launcher.
     * @param amountInUAssetMin Minimum uAsset spend accepted by the router in auto-liquidity mode.
     * @param amountInMemecoinMin Minimum memecoin spend accepted by the router in auto-liquidity mode.
     * @param amountOutDesired Desired POL amount. If zero, the launcher mints the amount implied by the provided budgets.
     * @param deadline Transaction deadline forwarded to the router.
     * @return amountInUAsset The consumed uAsset amount.
     * @return amountInMemecoin The consumed memecoin amount.
     * @return amountOut The minted POL amount.
     */
    function mintPOLToken(
        uint256 verseId,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    )
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut)
    {
        require(amountInUAssetDesired != 0 && amountInMemecoinDesired != 0, ZeroInput());
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address uAsset = verse.uAsset;
        address memecoin = verse.memecoin;
        address pol = verse.pol;

        // Delegatecall the liquidity sibling so all token movement (transfer-in, router liquidity, POL mint,
        // refund) shares one delegatecall boundary and operates on proxy storage/balance. The facade keeps the
        // outer validation (verseId / pause / input non-zero / stage) and emits the event after success.
        address impl = memeverseLauncherStorage.liquidityImpl;
        require(impl != address(0), LiquidityImplNotSet());
        bytes memory ret = impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseLiquidityImpl.mintPOLToken.selector,
                uAsset,
                memecoin,
                pol,
                amountInUAssetDesired,
                amountInMemecoinDesired,
                amountInUAssetMin,
                amountInMemecoinMin,
                amountOutDesired,
                deadline
            )
        );
        (amountInUAsset, amountInMemecoin, amountOut) = abi.decode(ret, (uint256, uint256, uint256));

        emit MintPOLToken(verseId, memecoin, pol, msg.sender, amountOut);
    }

    /**
     * @notice Register a new memeverse.
     * @dev Deploys memecoin and POL proxies, initializes them, and stores verse metadata.
     * @param name - Name of memecoin
     * @param symbol - Symbol of memecoin
     * @param uniqueId - Unique verseId
     * @param endTime - Genesis stage end time
     * @param unlockTime - Unlock time of liquidity
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     * @param uAsset - verse funding asset
     * @param flashGenesis - Enable FlashGenesis mode
     */
    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        address uAsset,
        bool flashGenesis
    ) external override whenNotPaused {
        // Delegatecall launch sibling: it enforces the registrar ACL, deploys memecoin/POL, wires LayerZero
        // peers, stores the verse config, registers the POLend market, AND emits RegisterMemeverse. Facade
        // emits nothing to avoid a double-emit under delegatecall. Under delegatecall `msg.sender` is the
        // original caller (must equal `memeverseRegistrar`) and `address(this)` is the launcher proxy.
        address impl = memeverseLauncherStorage.launchImpl;
        require(impl != address(0), LaunchImplNotSet());
        impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseLaunchImpl.registerMemeverse.selector,
                name,
                symbol,
                uniqueId,
                endTime,
                unlockTime,
                omnichainIds,
                uAsset,
                flashGenesis
            )
        );
    }

    /**
     * @notice Remove native gas dust from the contract.
     * @dev Transfers the full native balance to `receiver`.
     * @param receiver - The recipient of the native dust.
     */
    function removeGasDust(address receiver) external override onlyOwner {
        uint256 dust = address(this).balance;
        _transferOut(NATIVE, receiver, dust);

        emit RemoveGasDust(receiver, dust);
    }

    /**
     * @notice Pause state-changing launcher entrypoints.
     * @dev Only callable by the owner.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause state-changing launcher entrypoints.
     * @dev Only callable by the owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the MemeverseLaunchImpl sibling address used to run verse registration, genesis/preorder
    ///         deposits, and adaptive stage transitions.
    /// @dev Only callable by the owner. `registerMemeverse` / `genesis` / `preorder` / `changeStage`
    ///      delegatecall this sibling, so a zero address would delegatecall into address(0) and burn the call;
    ///      reject it explicitly here. When rotating (not initial wiring), the new implementation must
    ///      inherit `DelegatecallOnly`, match the `IMemeverseLaunchImpl` ABI, and keep the shared
    ///      `outrun.storage.MemeverseLauncher` storage layout; these are owner responsibilities
    ///      (see docs/spec/upgradeability.md §2.3) — none of that is checkable on-chain.
    /// @param impl The MemeverseLaunchImpl sibling address.
    function setLaunchImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.launchImpl = impl;
        emit SetLaunchImpl(impl);
    }

    /// @notice Set the MemeverseSettlementImpl sibling address used to run fee collection and distribution.
    /// @dev Only callable by the owner. `redeemAndDistributeFees` and the Locked->Unlocked branch of
    ///      `changeStage` delegatecall this sibling, so a zero address would delegatecall into address(0)
    ///      and burn the call; reject it explicitly here. When rotating (not initial wiring), the new
    ///      implementation must inherit `DelegatecallOnly`, match the `IMemeverseSettlementImpl` ABI, and
    ///      keep the shared `outrun.storage.MemeverseLauncher` storage layout; these are owner
    ///      responsibilities (see docs/spec/upgradeability.md §2.3) — none of that is checkable on-chain.
    /// @param impl The MemeverseSettlementImpl sibling address.
    function setSettlementImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.settlementImpl = impl;
        emit SetSettlementImpl(impl);
    }

    /// @notice Set the fee-preview reader contract used for off-chain fee previews.
    /// @dev Only callable by the owner. The reader is a standalone view contract (not a delegatecall
    ///      target); a zero address is rejected to keep the wiring explicit.
    /// @param reader The fee-preview reader contract address.
    function setFeePreviewReader(address reader) external override onlyOwner {
        require(reader != address(0), ZeroInput());
        memeverseLauncherStorage.feePreviewReader = reader;
        emit SetFeePreviewReader(reader);
    }

    /// @notice Set the MemeverseLiquidityImpl sibling implementation invoked via delegatecall for POL minting.
    /// @dev Only callable by the owner. `mintPOLToken` delegatecalls this sibling, so a zero address
    ///      would delegatecall into address(0) and burn the call; reject it explicitly here. When rotating
    ///      (not initial wiring), the new implementation must inherit `DelegatecallOnly`, match the
    ///      `IMemeverseLiquidityImpl` ABI, and keep the shared `outrun.storage.MemeverseLauncher` storage
    ///      layout; these are owner responsibilities (see docs/spec/upgradeability.md §2.3) — none of that
    ///      is checkable on-chain.
    /// @param impl The MemeverseLiquidityImpl sibling address.
    function setLiquidityImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.liquidityImpl = impl;
        emit SetLiquidityImpl(impl);
    }

    /**
     * @notice Set the memeverse swap router contract.
     * @dev Only callable by the owner.
     * @param _memeverseSwapRouter - Address of the Memeverse swap router contract.
     */
    function setMemeverseSwapRouter(address _memeverseSwapRouter) external override onlyOwner {
        require(_memeverseSwapRouter != address(0), ZeroInput());
        address hookAddress = memeverseLauncherStorage.memeverseUniswapHook;
        if (hookAddress != address(0)) {
            MemeverseLauncherLib.validateSettlementWiring(_memeverseSwapRouter, hookAddress);
        }

        memeverseLauncherStorage.memeverseSwapRouter = _memeverseSwapRouter;

        emit SetMemeverseSwapRouter(_memeverseSwapRouter);
    }

    /// @notice Set the memeverse hook contract.
    /// @dev Only callable by the owner. The hook is write-once because existing live pools are namespaced by hook.
    /// @param _memeverseUniswapHook Address of the Memeverse hook.
    function setMemeverseUniswapHook(address _memeverseUniswapHook) external override onlyOwner {
        require(_memeverseUniswapHook != address(0), ZeroInput());
        if (memeverseLauncherStorage.memeverseUniswapHook != address(0)) revert HookAlreadyConfigured();
        address routerAddress = memeverseLauncherStorage.memeverseSwapRouter;
        if (routerAddress != address(0)) {
            MemeverseLauncherLib.validateSettlementWiring(routerAddress, _memeverseUniswapHook);
        } else {
            address boundLauncher = IMemeverseUniswapHook(_memeverseUniswapHook).launcher();
            require(boundLauncher == address(this), InvalidPreorderSettlementConfig());
        }

        memeverseLauncherStorage.memeverseUniswapHook = _memeverseUniswapHook;

        emit SetMemeverseUniswapHook(_memeverseUniswapHook);
    }

    /**
     * @notice Set the LayerZero endpoint registry contract.
     * @dev Only callable by the owner.
     * @param _lzEndpointRegistry - Address of LzEndpointRegistry
     */
    function setLzEndpointRegistry(address _lzEndpointRegistry) external override onlyOwner {
        require(_lzEndpointRegistry != address(0), ZeroInput());

        memeverseLauncherStorage.lzEndpointRegistry = _lzEndpointRegistry;

        emit SetLzEndpointRegistry(_lzEndpointRegistry);
    }

    /**
     * @notice Set the memeverse registrar contract.
     * @dev Only callable by the owner.
     * @param _memeverseRegistrar - Address of the Memeverse registrar contract.
     */
    function setMemeverseRegistrar(address _memeverseRegistrar) external override onlyOwner {
        require(_memeverseRegistrar != address(0), ZeroInput());

        memeverseLauncherStorage.memeverseRegistrar = _memeverseRegistrar;

        emit SetMemeverseRegistrar(_memeverseRegistrar);
    }

    /**
     * @notice Set the memeverse proxy deployer contract.
     * @dev Only callable by the owner.
     * @param _memeverseProxyDeployer - Address of the Memeverse proxy deployer contract.
     */
    function setMemeverseProxyDeployer(address _memeverseProxyDeployer) external override onlyOwner {
        require(_memeverseProxyDeployer != address(0), ZeroInput());

        memeverseLauncherStorage.memeverseProxyDeployer = _memeverseProxyDeployer;

        emit SetMemeverseProxyDeployer(_memeverseProxyDeployer);
    }

    /**
     * @notice Set the yield dispatcher contract.
     * @dev Only callable by the owner. Only a non-zero check is enforced; cross-chain address
     *      consistency is a deployment convention, not a contract invariant. In a multichain
     *      deployment this address is the OFT `SendParam.to` for cross-chain fee distribution
     *      (`MemeverseSettlementImpl._sendRedeemedFeesCrossChain` via
     *      `MemeverseLauncherLib.buildSendParamAndMessagingFee`), delivered on the governance chain.
     *      The source-chain value stored here must equal the governance chain's actual
     *      YieldDispatcher address; a mismatch routes fees to a wrong/empty address with no
     *      recovery path (fail-closed, no third-party theft).
     * @param _yieldDispatcher - Address of the yield dispatcher contract.
     */
    function setYieldDispatcher(address _yieldDispatcher) external override onlyOwner {
        require(_yieldDispatcher != address(0), ZeroInput());

        memeverseLauncherStorage.yieldDispatcher = _yieldDispatcher;

        emit SetYieldDispatcher(_yieldDispatcher);
    }

    /**
     * @notice Set fund metadata for a verse uAsset token.
     * @dev Only callable by the owner.
     * @param _uAsset - Genesis fund type
     * @param _minTotalFund - The minimum participation genesis fund corresponding to uAsset
     * @param _fundBasedAmount - // The number of Memecoins minted per unit of Memecoin genesis fund
     */
    function setFundMetaData(address _uAsset, uint256 _minTotalFund, uint256 _fundBasedAmount)
        external
        override
        onlyOwner
    {
        require(_minTotalFund != 0 && _fundBasedAmount != 0, ZeroInput());
        require(
            _fundBasedAmount <= MAX_FUND_BASED_AMOUNT, FundBasedAmountTooHigh(_fundBasedAmount, MAX_FUND_BASED_AMOUNT)
        );
        // Derived virtualAssets = minTotalFund * fundBasedAmount * 7 / 1000 must round up to >= 1,
        // else MemecoinYieldVault.initialize reverts ZeroVirtualAssets() and governance-chain deploy DoSs.
        // Boundary: 142*7=994 -> 0 (rejected); 143*7=1001 -> 1 (accepted).
        require(MemeverseLauncherLib.virtualAssetsBuffer(_minTotalFund, _fundBasedAmount) > 0, VirtualAssetsTooLow());

        memeverseLauncherStorage.fundMetaDatas[_uAsset] = FundMetaData(_minTotalFund, _fundBasedAmount);

        emit SetFundMetaData(_uAsset, _minTotalFund, _fundBasedAmount);
    }

    /**
     * @notice Set the executor reward rate.
     * @dev Only callable by the owner.
     * @param _executorRewardRate - Executor reward rate
     */
    function setExecutorRewardRate(uint256 _executorRewardRate) external override onlyOwner {
        require(_executorRewardRate < RATIO, FeeRateOverFlow());

        memeverseLauncherStorage.executorRewardRate = _executorRewardRate;

        emit SetExecutorRewardRate(_executorRewardRate);
    }

    /**
     * @notice Set preorder cap and vesting parameters.
     * @dev Only callable by the owner.
     * @param _preorderCapRatio Preorder capacity ratio in `RATIO` precision.
     * @param _preorderVestingDuration Vesting duration for preorder memecoin.
     */
    function setPreorderConfig(uint256 _preorderCapRatio, uint256 _preorderVestingDuration)
        external
        override
        onlyOwner
    {
        require(_preorderCapRatio != 0 && _preorderVestingDuration != 0, ZeroInput());
        require(_preorderCapRatio <= RATIO, FeeRateOverFlow());
        memeverseLauncherStorage.preorderCapRatio = _preorderCapRatio;
        memeverseLauncherStorage.preorderVestingDuration = _preorderVestingDuration;

        emit SetPreorderConfig(_preorderCapRatio, _preorderVestingDuration);
    }

    /**
     * @notice Set gas limits for OFT receive and yield dispatcher.
     * @dev Only callable by the owner.
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _yieldDispatcherGasLimit - Gas limit for yield dispatcher
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _yieldDispatcherGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _yieldDispatcherGasLimit > 0, ZeroInput());
        memeverseLauncherStorage.oftReceiveGasLimit = _oftReceiveGasLimit;
        memeverseLauncherStorage.yieldDispatcherGasLimit = _yieldDispatcherGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _yieldDispatcherGasLimit);
    }

    /**
     * @notice Set external metadata for a memeverse.
     * @dev Callable by the verse governor or the registrar.
     * @param verseId - Memeverse id
     * @param uri - IPFS URI of memecoin icon
     * @param description - Description
     * @param communities - Community(Website, X, Discord, Telegram and Others)
     */
    function setExternalInfo(
        uint256 verseId,
        string calldata uri,
        string calldata description,
        string[] calldata communities
    ) external override {
        _versIdValidate(verseId);
        require(
            msg.sender == memeverseLauncherStorage.memeverses[verseId].governor
                || msg.sender == memeverseLauncherStorage.memeverseRegistrar,
            PermissionDenied()
        );
        require(bytes(description).length < 256, InvalidLength());

        if (bytes(uri).length != 0) memeverseLauncherStorage.memeverses[verseId].uri = uri;
        if (bytes(description).length != 0) memeverseLauncherStorage.memeverses[verseId].desc = description;
        if (communities.length != 0) {
            uint256 communitiesLength = communities.length;
            for (uint256 i = 0; i < communitiesLength;) {
                // Empty string deletes the entry; non-empty updates it.
                if (bytes(communities[i]).length == 0) {
                    delete memeverseLauncherStorage.communitiesMap[verseId][i];
                } else {
                    memeverseLauncherStorage.communitiesMap[verseId][i] = communities[i];
                }
                unchecked {
                    ++i;
                }
            }
        }

        emit SetExternalInfo(verseId, uri, description, communities);
    }
}
