// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";
import {IMemeverseBootstrap} from "./interfaces/IMemeverseBootstrap.sol";
import {IMemeverseFeeDistributor} from "./interfaces/IMemeverseFeeDistributor.sol";
import {IMemeversePOLMinter} from "./interfaces/IMemeversePOLMinter.sol";
import {IPol} from "../token/interfaces/IPol.sol";
import {ILzEndpointRegistry} from "../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IMemeverseProxyDeployer} from "./interfaces/IMemeverseProxyDeployer.sol";
import {IMemeverseSwapRouter} from "../swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../swap/interfaces/IMemeverseUniswapHook.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
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
    uint256 internal constant UNLOCK_PROTECTION_WINDOW = 24 hours;
    uint256 internal constant MAX_FUND_BASED_AMOUNT = (1 << 64) - 1;
    /// @dev Numerator of the 0.7% factor used to size the yield-vault virtual buffer V from the minimum
    ///      main-pool memecoin provision. `V = minTotalFund * fundBasedAmount * 7 / 1000`.
    uint256 internal constant YIELD_VAULT_VIRTUAL_ASSET_FACTOR = 7;
    /// @dev Denominator paired with `YIELD_VAULT_VIRTUAL_ASSET_FACTOR` to express 0.7%.
    uint256 internal constant YIELD_VAULT_VIRTUAL_ASSET_DIVISOR = 1000;

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
        contracts.bootstrapImpl = memeverseLauncherStorage.bootstrapImpl;
        contracts.memeverseUniswapHook = memeverseLauncherStorage.memeverseUniswapHook;
        contracts.feeDistributorImpl = memeverseLauncherStorage.feeDistributorImpl;
        contracts.feePreviewReader = memeverseLauncherStorage.feePreviewReader;
        contracts.polMinterImpl = memeverseLauncherStorage.polMinterImpl;
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
        return _claimablePreorderMemecoinForAccount(verseId, msg.sender);
    }

    function _claimablePreorderMemecoinForAccount(uint256 verseId, address account)
        internal
        view
        returns (uint256 amount)
    {
        _versIdValidate(verseId);
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        PreorderState storage preorderState = memeverseLauncherStorage.preorderStates[verseId];
        uint40 settlementTimestamp = preorderState.settlementTimestamp;
        if (settlementTimestamp == 0) return 0;

        PreorderData storage preorderData = memeverseLauncherStorage.userPreorderData[verseId][account];
        uint256 userFunds = preorderData.funds;
        uint256 totalFunds = preorderState.totalFunds;
        if (userFunds == 0 || totalFunds == 0) return 0;

        // Full-precision floor division preserves preorder accounting for large settled amounts.
        uint256 purchasedMemecoin = FullMath.mulDiv(preorderState.settledMemecoin, userFunds, totalFunds);
        if (purchasedMemecoin <= preorderData.claimedMemecoin) return 0;

        uint256 vestingDuration = memeverseLauncherStorage.preorderVestingDuration;
        uint256 elapsed = block.timestamp > settlementTimestamp ? block.timestamp - settlementTimestamp : 0;
        if (elapsed >= vestingDuration) {
            return purchasedMemecoin - preorderData.claimedMemecoin;
        }

        uint256 vested = FullMath.mulDiv(purchasedMemecoin, elapsed, vestingDuration);
        if (vested <= preorderData.claimedMemecoin) return 0;
        return vested - preorderData.claimedMemecoin;
    }

    /**
     * @notice Preview the currently remaining preorder capacity for a verse.
     * @dev Capacity is computed from current memecoin-side genesis funds and the configured cap ratio.
     * @param verseId Memeverse id.
     * @return remaining The remaining preorder uAsset capacity.
     */
    function previewPreorderCapacity(uint256 verseId) public view override returns (uint256 remaining) {
        _versIdValidate(verseId);
        uint256 totalLeveragedDebt = IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalBaseFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 maxCapacity = _preorderMaxCapacity(totalBaseFunds);
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
        require(verseId != 0 && amountInUAsset != 0 && user != address(0), ZeroInput());
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Genesis, NotGenesisStage());
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 currentTotalGenesisFunds =
            normalFunds + IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 projectedTotalGenesisFunds = currentTotalGenesisFunds + amountInUAsset;
        if (projectedTotalGenesisFunds > MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) {
            revert TotalGenesisFundsTooHigh(
                projectedTotalGenesisFunds, MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS
            );
        }

        memeverseLauncherStorage.totalNormalFunds[verseId] = normalFunds + amountInUAsset;
        memeverseLauncherStorage.userGenesisData[verseId][user].genesisFund += amountInUAsset;

        _transferIn(verse.uAsset, msg.sender, amountInUAsset);

        emit Genesis(verseId, user, amountInUAsset);
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
        require(verseId != 0 && amountInUAsset != 0 && user != address(0), ZeroInput());
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Genesis, NotGenesisStage());

        PreorderState storage preorderState = memeverseLauncherStorage.preorderStates[verseId];
        uint256 nextTotalPreorderFunds = preorderState.totalFunds + amountInUAsset;
        uint256 totalLeveragedDebt = IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalBaseFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 maxCapacity = _preorderMaxCapacity(totalBaseFunds);
        require(nextTotalPreorderFunds <= maxCapacity, InvalidLength());

        preorderState.totalFunds = nextTotalPreorderFunds;
        memeverseLauncherStorage.userPreorderData[verseId][user].funds += amountInUAsset;

        _transferIn(verse.uAsset, msg.sender, amountInUAsset);

        emit Preorder(verseId, msg.sender, user, amountInUAsset);
    }

    function _preorderMaxCapacity(uint256 totalBaseFunds) internal view returns (uint256) {
        return FullMath.mulDiv(totalBaseFunds, 7 * memeverseLauncherStorage.preorderCapRatio, 10 * RATIO);
    }

    /**
     * @notice Adaptively change the Memeverse stage.
     * @dev Advances from `Genesis` to `Locked` or `Refund`, and from `Locked` to `Unlocked` when eligible.
     *      Intentionally omits `whenNotPaused`: refund and settlement flows must remain executable during a pause
     *      so users can recover funds and protocol settlement (polSplitter / polend) can proceed to completion.
     *      Intentionally omits `nonReentrant`: the Locked→Unlocked transition calls `IPOLSplitter.settle()`
     *      and `IPOLend.executeGlobalSettlement()`, which rely on cross-contract callbacks into the launcher.
     *      Adding `nonReentrant` would break this callback chain.
     * @param verseId - Memeverse id
     * @return currentStage - The current stage.
     */
    function changeStage(uint256 verseId) external override versIdValidate(verseId) returns (Stage currentStage) {
        require(verseId != 0, ZeroInput());
        uint256 currentTime = block.timestamp;
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        currentStage = verse.currentStage;
        require(currentStage != Stage.Refund && currentStage != Stage.Unlocked, ReachedFinalStage());

        if (currentStage == Stage.Genesis) {
            // Genesis is the only stage that can resolve into either a successful launch or a refund outcome.
            currentStage = _handleGenesisStage(verseId, currentTime, verse);
        } else if (currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            address _polSplitter = memeverseLauncherStorage.polSplitter;
            address _polend = memeverseLauncherStorage.polend;
            address _hook = memeverseLauncherStorage.memeverseUniswapHook;
            address _feeDistributorImpl = memeverseLauncherStorage.feeDistributorImpl;
            require(_feeDistributorImpl != address(0), FeeDistributorImplNotSet());
            _feeDistributorImpl.functionDelegateCall(
                abi.encodeWithSelector(
                    IMemeverseFeeDistributor.captureLockedAuxiliaryFees.selector, verseId, _polSplitter, _hook
                )
            );
            verse.currentStage = Stage.Unlocked;
            IPOLSplitter(_polSplitter).settle(verseId);
            if (IPOLend(_polend).getTotalLeveragedDebt(verseId) != 0) {
                IPOLend(_polend).executeGlobalSettlement(verseId);
            }
            _activatePostUnlockPublicSwapProtection(verseId, verse, _polSplitter, _hook);
            currentStage = Stage.Unlocked;
        }

        emit ChangeStage(verseId, currentStage);
    }

    /**
     * @dev Handle Genesis stage logic
     * @param verseId - Memeverse id
     * @param currentTime - Current timestamp
     * @param verse - Memeverse storage reference
     * @return currentStage - The current stage
     */
    function _handleGenesisStage(uint256 verseId, uint256 currentTime, Memeverse storage verse)
        internal
        returns (Stage currentStage)
    {
        address _polend = memeverseLauncherStorage.polend;
        address _polSplitter = memeverseLauncherStorage.polSplitter;
        address uAsset = verse.uAsset;
        uint256 minTotalFund = memeverseLauncherStorage.fundMetaDatas[uAsset].minTotalFund;
        uint256 totalLeveragedInterest = IPOLend(_polend).getTotalLeveragedInterest(verseId);
        uint256 totalLeveragedDebt = IPOLend(_polend).getTotalLeveragedDebt(verseId);
        bool leveragedLaunchReady = totalLeveragedInterest >= minTotalFund;
        bool meetMinTotalFund =
            memeverseLauncherStorage.totalNormalFunds[verseId] >= minTotalFund || leveragedLaunchReady;
        uint256 endTime = verse.endTime;

        if ((verse.flashGenesis && meetMinTotalFund) || (currentTime > endTime && meetMinTotalFund)) {
            verse.currentStage = Stage.Locked;
            _deployAndSetupMemeverse(verseId, verse, uAsset, totalLeveragedDebt, _polend, _polSplitter);
            return Stage.Locked;
        }

        // Missing the minimum at `endTime` permanently sends the verse into the refund branch; there is no partial launch path.
        require(currentTime > endTime, StillInGenesisStage(endTime));
        verse.currentStage = Stage.Refund;
        if (totalLeveragedDebt != 0) IPOLend(_polend).markRefundable(verseId);
        return Stage.Refund;
    }

    /**
     * @dev Deploy and setup memeverse components
     * @param verseId - Memeverse id
     * @param verse - Memeverse storage reference
     * @param uAsset - verse uAsset address
     */
    function _deployAndSetupMemeverse(
        uint256 verseId,
        Memeverse storage verse,
        address uAsset,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) internal {
        string memory name = verse.name;
        string memory symbol = verse.symbol;
        address memecoin = verse.memecoin;
        address pol = verse.pol;
        uint32 govChainId = verse.omnichainIds[0];

        if (totalLeveragedDebt != 0) IPOLend(_polend).finalizeLeveragedGenesis(verseId);
        IPOLSplitter(_polSplitter).initializeVerse(verseId, pol, memecoin, uAsset, name, symbol);

        _deployLiquidity(verseId, uAsset, memecoin, pol, totalLeveragedDebt, _polend, _polSplitter);

        (address yieldVault, address governor, address incentivizer) =
            _deployGovernanceComponents(verseId, govChainId, name, symbol, uAsset, memecoin, pol);
        verse.yieldVault = yieldVault;
        verse.governor = governor;
        verse.incentivizer = incentivizer;
    }

    /**
     * @dev Deploy governance components
     * @param verseId - Memeverse id
     * @param govChainId - Governance chain id
     * @param name - Token name
     * @param symbol - Token symbol
     * @param uAsset - verse uAsset address
     * @param memecoin - Memecoin address
     * @param pol - POL address
     */
    function _deployGovernanceComponents(
        uint256 verseId,
        uint32 govChainId,
        string memory name,
        string memory symbol,
        address uAsset,
        address memecoin,
        address pol
    ) internal returns (address yieldVault, address governor, address incentivizer) {
        uint256 proposalThreshold = IMemecoin(memecoin).totalSupply() / 50;
        address _proxyDeployer = memeverseLauncherStorage.memeverseProxyDeployer;

        if (govChainId == block.chainid) {
            // On the governance chain we deploy concrete contracts immediately because fee distribution will target them locally.
            yieldVault = IMemeverseProxyDeployer(_proxyDeployer).deployYieldVault(verseId);
            // Size the permanent virtual buffer V from the per-uAsset fund metadata: 0.7% of the minimum
            // main-pool memecoin provision (spec §4). registerMemeverse already enforces both fields are non-zero.
            FundMetaData storage _meta = memeverseLauncherStorage.fundMetaDatas[uAsset];
            uint256 _virtualAssets = _meta.minTotalFund * _meta.fundBasedAmount * YIELD_VAULT_VIRTUAL_ASSET_FACTOR
                / YIELD_VAULT_VIRTUAL_ASSET_DIVISOR;
            IMemecoinYieldVault(yieldVault)
                .initialize(
                    string(abi.encodePacked("Staked ", name)),
                    string(abi.encodePacked("s", symbol)),
                    memeverseLauncherStorage.yieldDispatcher,
                    memecoin,
                    verseId,
                    _virtualAssets
                );
            (governor, incentivizer) = IMemeverseProxyDeployer(_proxyDeployer)
                .deployGovernorAndIncentivizer(name, uAsset, memecoin, pol, yieldVault, verseId, proposalThreshold);
        } else {
            // Remote governance chains receive bridged assets later, so launcher only records the deterministic target addresses here.
            yieldVault = IMemeverseProxyDeployer(_proxyDeployer).predictYieldVaultAddress(verseId);
            (governor, incentivizer) =
                IMemeverseProxyDeployer(_proxyDeployer).computeGovernorAndIncentivizerAddress(verseId);
        }
    }

    /**
     * @dev Deploy liquidity pools
     * @param verseId - Memeverse id
     * @param uAsset - verse uAsset address
     * @param memecoin - Memecoin address
     * @param pol - POL address
     */
    function _deployLiquidity(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) internal {
        address impl = memeverseLauncherStorage.bootstrapImpl;
        require(impl != address(0), IMemeverseLauncher.BootstrapImplNotSet());
        // OZ functionDelegateCall returns bytes memory AND bubbles the sibling's revert reason.
        // deployLiquidity is void; the return value is discarded.
        impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseBootstrap.deployLiquidity.selector,
                verseId,
                uAsset,
                memecoin,
                pol,
                totalLeveragedDebt,
                _polend,
                _polSplitter
            )
        );
    }

    /**
     * @notice Refund uAsset after genesis failed because the omnichain funds did not meet the minimum requirement.
     * @dev Marks the caller as refunded before transferring funds out.
     * @param verseId - Memeverse id
     * @return genesisFund - The refunded genesis contribution amount.
     */
    function refund(uint256 verseId) external override versIdValidate(verseId) returns (uint256 genesisFund) {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Refund, NotRefundStage());

        address msgSender = msg.sender;
        GenesisData storage genesisData = memeverseLauncherStorage.userGenesisData[verseId][msgSender];
        genesisFund = genesisData.genesisFund;
        require(genesisFund > 0 && !genesisData.isRefunded, InvalidClaim());

        genesisData.isRefunded = true;
        _transferOut(verse.uAsset, msgSender, genesisFund);

        emit Refund(verseId, msgSender, genesisFund);
    }

    /**
     * @notice Refund uAsset after preorder became invalid because Genesis failed.
     * @dev Marks the caller as refunded before transferring funds out.
     * @param verseId Memeverse id.
     * @return preorderFund The refunded preorder contribution amount.
     */
    function refundPreorder(uint256 verseId) external override versIdValidate(verseId) returns (uint256 preorderFund) {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Refund, NotRefundStage());

        address msgSender = msg.sender;
        PreorderData storage preorderData = memeverseLauncherStorage.userPreorderData[verseId][msgSender];
        preorderFund = preorderData.funds;
        require(preorderFund > 0 && !preorderData.isRefunded, InvalidClaim());

        preorderData.isRefunded = true;
        _transferOut(verse.uAsset, msgSender, preorderFund);

        emit RefundPreorder(verseId, msgSender, preorderFund);
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
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address msgSender = msg.sender;
        require(!memeverseLauncherStorage.normalYTClaimed[verseId][msgSender], InvalidClaim());

        uint256 userGenesisFund = memeverseLauncherStorage.userGenesisData[verseId][msgSender].genesisFund;
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        require(userGenesisFund != 0 && normalFunds != 0, InvalidClaim());

        amount = FullMath.mulDiv(memeverseLauncherStorage.totalNormalClaimableYT[verseId], userGenesisFund, normalFunds);

        memeverseLauncherStorage.normalYTClaimed[verseId][msgSender] = true;
        if (amount != 0) {
            address _polSplitter = memeverseLauncherStorage.polSplitter;
            address yt = IPOLSplitter(_polSplitter).getYT(verseId);
            _transferOut(yt, msgSender, amount);
        }

        emit ClaimNormalYT(verseId, msgSender, amount);
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
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address _polSplitter = memeverseLauncherStorage.polSplitter;
        (address pt, bool settled) = IPOLSplitter(_polSplitter).getPTSettlementState(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 userFund = memeverseLauncherStorage.userGenesisData[verseId][msg.sender].genesisFund;
        require(userFund != 0 && normalFunds != 0, InvalidClaim());
        UserNormalFeeClaim storage userClaim = memeverseLauncherStorage.userNormalFeeClaims[verseId][msg.sender];
        NormalFeeState storage feeState = memeverseLauncherStorage.normalFeeStates[verseId];

        uint256 entitledUAsset = FullMath.mulDiv(feeState.accUAssetFee, userFund, normalFunds);
        uint256 entitledPT = FullMath.mulDiv(feeState.accPTFee, userFund, normalFunds);
        uAssetAmount = entitledUAsset - userClaim.claimedUAssetFee;
        uint256 pendingPTAmount = entitledPT - userClaim.claimedPTFee;
        uint256 claimableUAssetAmount = uAssetAmount;

        // Commit the launcher-held fee state before any external PT settlement call so a callback cannot
        // reenter and pull the same fee twice.
        if (claimableUAssetAmount != 0) {
            userClaim.claimedUAssetFee = entitledUAsset;
        }

        if (pendingPTAmount != 0) {
            // Report the pending PT entitlement unless this claim either transfers it or redeems it into uAsset.
            ptAmount = pendingPTAmount;
            if (settled) {
                uint256 ptBacking = IPOLSplitter(_polSplitter).previewPTToUAsset(verseId, pendingPTAmount);
                if (ptBacking != 0) {
                    userClaim.claimedPTFee = entitledPT;
                    uAssetAmount += IPOLSplitter(_polSplitter).redeemPT(verseId, pendingPTAmount, msg.sender);
                    ptAmount = 0;
                } else {
                    // Dust rounding makes the PT redeemable for zero uAsset.
                    // Reset ptAmount so the event reflects no actual transfer.
                    // claimedPTFee is intentionally left untouched so the entitlement
                    // stays pending and self-heals as future fee accrual grows accPTFee.
                    ptAmount = 0;
                }
            } else {
                userClaim.claimedPTFee = entitledPT;
                _transferOut(pt, msg.sender, pendingPTAmount);
            }
        }
        if (claimableUAssetAmount != 0) {
            _transferOut(verse.uAsset, msg.sender, claimableUAssetAmount);
        }
        emit ClaimNormalFees(verseId, msg.sender, uAssetAmount, ptAmount);
    }

    function redeemAuxiliaryLiquidity(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        whenNotPaused
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        uint256 userFund = _redeemableGenesisFund(verseId, msg.sender);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];

        address _polSplitter = memeverseLauncherStorage.polSplitter;
        address pt = IPOLSplitter(_polSplitter).getPT(verseId);
        (polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount) =
            _auxiliaryLiquidityRedemptionAmounts(verseId, userFund, normalFunds);

        memeverseLauncherStorage.userGenesisData[verseId][msg.sender].isRedeemed = true;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        _transferRedeemedAuxiliaryLiquidity(
            verse.pol, verse.uAsset, pt, msg.sender, polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount, swapRouter
        );
        _transferNormalResidualClaims(verseId, normalFunds, verse.pol, pt, msg.sender, userFund);
        emit RedeemAuxiliaryLiquidity(verseId, msg.sender, polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount);
    }

    function _transferNormalResidualClaims(
        uint256 verseId,
        uint256 normalFunds,
        address pol,
        address pt,
        address recipient,
        uint256 userFund
    ) internal {
        BootstrapResidualClaims storage claims = memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        uint256 polAmount = FullMath.mulDiv(claims.normalResidualPOL, userFund, normalFunds);
        uint256 ptAmount = FullMath.mulDiv(claims.normalResidualPT, userFund, normalFunds);
        if (polAmount != 0) _transferOut(pol, recipient, polAmount);
        if (ptAmount != 0) _transferOut(pt, recipient, ptAmount);
    }

    function _redeemableGenesisFund(uint256 verseId, address account) internal view returns (uint256 userFund) {
        GenesisData storage genesisData = memeverseLauncherStorage.userGenesisData[verseId][account];
        userFund = genesisData.genesisFund;
        require(userFund > 0 && !genesisData.isRedeemed, InvalidClaim());
    }

    function _auxiliaryLiquidityRedemptionAmounts(uint256 verseId, uint256 userFund, uint256 normalFunds)
        internal
        view
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        AuxiliaryLiquidity storage liq = memeverseLauncherStorage.auxiliaryLiquidities[verseId];
        polUAssetLpAmount = liq.polUAssetLpAmount * userFund / normalFunds;
        ptUAssetLpAmount = liq.ptUAssetLpAmount * userFund / normalFunds;
        ptPolLpAmount = liq.ptPolLpAmount * userFund / normalFunds;
    }

    function _transferRedeemedAuxiliaryLiquidity(
        address pol,
        address uAsset,
        address pt,
        address recipient,
        uint256 polUAssetLpAmount,
        uint256 ptUAssetLpAmount,
        uint256 ptPolLpAmount,
        address swapRouter
    ) internal {
        if (polUAssetLpAmount != 0) {
            _transferOut(_pairLpToken(pol, uAsset, swapRouter), recipient, polUAssetLpAmount);
        }
        if (ptUAssetLpAmount != 0) _transferOut(_pairLpToken(pt, uAsset, swapRouter), recipient, ptUAssetLpAmount);
        if (ptPolLpAmount != 0) _transferOut(_pairLpToken(pt, pol, swapRouter), recipient, ptPolLpAmount);
    }

    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        override
        versIdValidate(verseId)
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        address _polend = memeverseLauncherStorage.polend;
        require(msg.sender == _polend, PermissionDenied());

        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        address pt = IPOLSplitter(memeverseLauncherStorage.polSplitter).getPT(verseId);
        uint128 polUAssetLp;
        uint128 ptUAssetLp;
        uint128 ptPolLp;
        uint256 residualPOL;
        uint256 residualPT;
        {
            uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
            uint256 totalLeveragedDebt = IPOLend(_polend).getTotalLeveragedDebt(verseId);
            uint256 totalFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
            (polUAssetLp, ptUAssetLp, ptPolLp, residualPOL, residualPT) =
                _consumeLeveragedAuxiliaryClaims(verseId, totalLeveragedDebt, totalFunds);
        }

        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address pol = verse.pol;
        address uAsset = verse.uAsset;
        if (polUAssetLp != 0) _safeApprove(_pairLpToken(pol, uAsset, swapRouter), swapRouter, polUAssetLp);
        if (ptUAssetLp != 0) _safeApprove(_pairLpToken(pt, uAsset, swapRouter), swapRouter, ptUAssetLp);
        if (ptPolLp != 0) _safeApprove(_pairLpToken(pt, pol, swapRouter), swapRouter, ptPolLp);

        (BalanceDelta polUAssetDelta, BalanceDelta ptUAssetDelta, BalanceDelta ptPolDelta) =
            _removeLeveragedAuxiliaryLiquidity(pol, uAsset, pt, swapRouter, _polend, polUAssetLp, ptUAssetLp, ptPolLp);

        polAmount = _positiveDeltaAmountForToken(polUAssetDelta, pol, pol, uAsset)
            + _positiveDeltaAmountForToken(ptPolDelta, pol, pt, pol);
        ptAmount = _positiveDeltaAmountForToken(ptUAssetDelta, pt, pt, uAsset)
            + _positiveDeltaAmountForToken(ptPolDelta, pt, pt, pol);
        uAssetAmount = _positiveDeltaAmountForToken(polUAssetDelta, uAsset, pol, uAsset)
            + _positiveDeltaAmountForToken(ptUAssetDelta, uAsset, pt, uAsset);
        if (residualPOL != 0) {
            polAmount += residualPOL;
            _transferOut(pol, _polend, residualPOL);
        }
        if (residualPT != 0) {
            ptAmount += residualPT;
            _transferOut(pt, _polend, residualPT);
        }
    }

    function _removeLeveragedAuxiliaryLiquidity(
        address pol,
        address uAsset,
        address pt,
        address swapRouter,
        address polend_,
        uint128 polUAssetLp,
        uint128 ptUAssetLp,
        uint128 ptPolLp
    ) internal returns (BalanceDelta polUAssetDelta, BalanceDelta ptUAssetDelta, BalanceDelta ptPolDelta) {
        // Rounded-down zero LP shares must not call router removal; default deltas remain zero.
        polUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pol), Currency.wrap(uAsset), polUAssetLp, swapRouter, polend_
        );
        ptUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pt), Currency.wrap(uAsset), ptUAssetLp, swapRouter, polend_
        );
        ptPolDelta =
            _removeAuxiliaryLiquidityIfNonZero(Currency.wrap(pt), Currency.wrap(pol), ptPolLp, swapRouter, polend_);
    }

    function _removeAuxiliaryLiquidityIfNonZero(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        address swapRouter,
        address recipient
    ) internal returns (BalanceDelta delta) {
        if (liquidity == 0) return delta;

        return _removeAuxiliaryLiquidity(swapRouter, currency0, currency1, liquidity, recipient);
    }

    function _removeAuxiliaryLiquidity(
        address swapRouter,
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        address recipient
    ) internal returns (BalanceDelta delta) {
        return IMemeverseSwapRouter(swapRouter)
            .removeLiquidity(currency0, currency1, liquidity, 0, 0, recipient, block.timestamp);
    }

    function _consumeLeveragedAuxiliaryClaims(uint256 verseId, uint256 totalLeveragedDebt, uint256 totalFunds)
        internal
        returns (uint128 polUAssetLp, uint128 ptUAssetLp, uint128 ptPolLp, uint256 residualPOL, uint256 residualPT)
    {
        AuxiliaryLiquidity storage liq = memeverseLauncherStorage.auxiliaryLiquidities[verseId];
        polUAssetLp = uint128(FullMath.mulDiv(liq.polUAssetLpAmount, totalLeveragedDebt, totalFunds));
        ptUAssetLp = uint128(FullMath.mulDiv(liq.ptUAssetLpAmount, totalLeveragedDebt, totalFunds));
        ptPolLp = uint128(FullMath.mulDiv(liq.ptPolLpAmount, totalLeveragedDebt, totalFunds));

        liq.polUAssetLpAmount -= polUAssetLp;
        liq.ptUAssetLpAmount -= ptUAssetLp;
        liq.ptPolLpAmount -= ptPolLp;

        BootstrapResidualClaims storage claims = memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        residualPOL = claims.leveragedResidualPOL;
        residualPT = claims.leveragedResidualPT;
        // Consume leveraged residuals in the same state transition as LP shares to prevent double settlement.
        claims.leveragedResidualPOL = 0;
        claims.leveragedResidualPT = 0;
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
        amount = claimablePreorderMemecoin(verseId);
        require(amount != 0, NoPOLAvailable());

        address msgSender = msg.sender;
        memeverseLauncherStorage.userPreorderData[verseId][msgSender].claimedMemecoin += amount;
        _transferOut(memeverseLauncherStorage.memeverses[verseId].memecoin, msgSender, amount);
        emit ClaimPreorderMemecoin(verseId, msgSender, amount);
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

        address impl = memeverseLauncherStorage.feeDistributorImpl;
        require(impl != address(0), FeeDistributorImplNotSet());
        address _polSplitter = memeverseLauncherStorage.polSplitter;
        bytes memory ret = impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseFeeDistributor.collectAndDistributeFees.selector, verseId, rewardReceiver, _polSplitter
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

    /// @dev Intentionally omits `whenNotPaused`: users can always burn their own POL to exit the pool.
    ///      POL is the caller's own asset — pausing this path would trap liquidity holders in an emergency.
    ///      Protocol pathways (polSplitter / polend) also rely on this remaining unpaused for settlement.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        override
        versIdValidate(verseId)
        returns (uint256 amountInLP)
    {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(amountInPOL != 0, ZeroInput());

        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        IPol(verse.pol).burn(msg.sender, amountInPOL);

        amountInLP = amountInPOL;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address lpToken = _pairLpToken(verse.memecoin, verse.uAsset, swapRouter);
        require(IERC20(lpToken).balanceOf(address(this)) >= amountInLP, InsufficientLPBalance());
        if (!unwrap) {
            _transferOut(lpToken, msg.sender, amountInLP);
        } else {
            _safeApprove(lpToken, swapRouter, amountInLP);
            _removeAuxiliaryLiquidityIfNonZero(
                Currency.wrap(verse.memecoin), Currency.wrap(verse.uAsset), uint128(amountInLP), swapRouter, msg.sender
            );
        }
        emit RedeemMemecoinLiquidity(verseId, msg.sender, amountInLP);
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

        // Delegatecall the POL-minter sibling so all token movement (transfer-in, router liquidity, POL mint,
        // refund) shares one delegatecall boundary and operates on proxy storage/balance. The facade keeps the
        // outer validation (verseId / pause / input non-zero / stage) and emits the event after success.
        address impl = memeverseLauncherStorage.polMinterImpl;
        require(impl != address(0), POLMinterImplNotSet());
        bytes memory ret = impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeversePOLMinter.mintPOLToken.selector,
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
        require(msg.sender == memeverseLauncherStorage.memeverseRegistrar, PermissionDenied());
        require(
            memeverseLauncherStorage.polend != address(0) && memeverseLauncherStorage.polSplitter != address(0),
            PermissionDenied()
        );
        require(uAsset != address(0), ZeroInput());
        require(omnichainIds.length != 0, InvalidLength());
        FundMetaData memory fundMetaData = memeverseLauncherStorage.fundMetaDatas[uAsset];
        require(fundMetaData.minTotalFund != 0 && fundMetaData.fundBasedAmount != 0, ZeroInput());

        (address memecoin, address pol) = _deployAndInitializeVerseTokens(uniqueId, name, symbol);
        _lzConfigure(memecoin, pol, omnichainIds);
        _storeRegisteredMemeverse(
            uniqueId, name, symbol, uAsset, memecoin, pol, endTime, unlockTime, omnichainIds, flashGenesis
        );

        memeverseLauncherStorage.memecoinToIds[memecoin] = uniqueId;
        memeverseLauncherStorage.polToIds[pol] = uniqueId;
        IPOLend(memeverseLauncherStorage.polend).registerLendMarket(uniqueId);

        emit RegisterMemeverse(uniqueId, memeverseLauncherStorage.memeverses[uniqueId]);
    }

    function _storeRegisteredMemeverse(
        uint256 uniqueId,
        string calldata name,
        string calldata symbol,
        address uAsset,
        address memecoin,
        address pol,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        bool flashGenesis
    ) internal {
        Memeverse storage verse = memeverseLauncherStorage.memeverses[uniqueId];
        verse.name = name;
        verse.symbol = symbol;
        verse.uAsset = uAsset;
        verse.memecoin = memecoin;
        verse.pol = pol;
        verse.endTime = endTime;
        verse.unlockTime = unlockTime;
        verse.omnichainIds = omnichainIds;
        verse.flashGenesis = flashGenesis;
    }

    function _deployAndInitializeVerseTokens(uint256 uniqueId, string calldata name, string calldata symbol)
        internal
        returns (address memecoin, address pol)
    {
        IMemeverseProxyDeployer deployer = IMemeverseProxyDeployer(memeverseLauncherStorage.memeverseProxyDeployer);
        memecoin = deployer.deployMemecoin(uniqueId);
        pol = deployer.deployPOL(uniqueId);
        IMemecoin(memecoin).initialize(name, symbol, address(this), address(this));
        IPol(pol)
            .initialize(
                string(abi.encodePacked("POL-", name)),
                string(abi.encodePacked("POL-", symbol)),
                memecoin,
                address(this),
                address(this)
            );
    }

    /**
     * @dev Memecoin Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
     */
    function _lzConfigure(address memecoin, address pol, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);
        uint256 omnichainIdsLength = omnichainIds.length;

        // Use default config
        address _lzEndpointRegistry = memeverseLauncherStorage.lzEndpointRegistry;
        for (uint256 i = 0; i < omnichainIdsLength;) {
            uint32 omnichainId = omnichainIds[i];
            unchecked {
                ++i;
            }
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = ILzEndpointRegistry(_lzEndpointRegistry).lzEndpointIdOfChain(omnichainId);
            require(remoteEndpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
            IOAppCore(pol).setPeer(remoteEndpointId, bytes32(uint256(uint160(pol))));
        }
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

    /// @notice Set the MemeverseBootstrap sibling address used to run bootstrap liquidity deployment.
    /// @dev Only callable by the owner. `_deployLiquidity` delegatecalls this sibling, so a zero address would
    ///      delegatecall into address(0) and burn the call; reject it explicitly here.
    /// @param impl The MemeverseBootstrap sibling address.
    function setBootstrapImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.bootstrapImpl = impl;
        emit SetBootstrapImpl(impl);
    }

    /// @notice Set the MemeverseFeeDistributor sibling address used to run fee collection and distribution.
    /// @dev Only callable by the owner. `redeemAndDistributeFees` and the Locked->Unlocked branch of
    ///      `changeStage` delegatecall this sibling, so a zero address would delegatecall into address(0)
    ///      and burn the call; reject it explicitly here.
    /// @param impl The MemeverseFeeDistributor sibling address.
    function setFeeDistributorImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.feeDistributorImpl = impl;
        emit SetFeeDistributorImpl(impl);
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

    /// @notice Set the POL-minter sibling implementation invoked via delegatecall for POL minting.
    /// @dev Only callable by the owner. `mintPOLToken` delegatecalls this sibling, so a zero address
    ///      would delegatecall into address(0) and burn the call; reject it explicitly here.
    /// @param impl The MemeversePOLMinter sibling address.
    function setPOLMinterImpl(address impl) external override onlyOwner {
        require(impl != address(0), ZeroInput());
        memeverseLauncherStorage.polMinterImpl = impl;
        emit SetPOLMinterImpl(impl);
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

    function _activatePostUnlockPublicSwapProtection(
        uint256 verseId,
        Memeverse storage verse,
        address polSplitterAddress,
        address hook
    ) internal {
        uint40 resumeTime = uint40(block.timestamp + UNLOCK_PROTECTION_WINDOW);
        IMemeverseUniswapHook _hook = IMemeverseUniswapHook(hook);
        address uAsset = verse.uAsset;
        address pol = verse.pol;
        address pt = IPOLSplitter(polSplitterAddress).getPT(verseId);

        _setPublicSwapResumeTimeIfPairExists(_hook, verse.memecoin, uAsset, resumeTime);
        _setPublicSwapResumeTimeIfPairExists(_hook, pol, uAsset, resumeTime);
        _setPublicSwapResumeTimeIfPairExists(_hook, pt, uAsset, resumeTime);
        _setPublicSwapResumeTimeIfPairExists(_hook, pt, pol, resumeTime);
    }

    function _setPublicSwapResumeTimeIfPairExists(
        IMemeverseUniswapHook hook,
        address tokenA,
        address tokenB,
        uint40 resumeTime
    ) internal {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) return;
        hook.setPublicSwapResumeTime(tokenA, tokenB, resumeTime);
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
     * @dev Only callable by the owner.
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
        // Derived virtual buffer V = minTotalFund * fundBasedAmount * 7 / 1000 must round up to >= 1,
        // else MemecoinYieldVault.initialize reverts ZeroVirtualAssets() and governance-chain deploy DoSs.
        // Boundary: 142*7=994 -> 0 (rejected); 143*7=1001 -> 1 (accepted).
        require(
            _minTotalFund * _fundBasedAmount * YIELD_VAULT_VIRTUAL_ASSET_FACTOR / YIELD_VAULT_VIRTUAL_ASSET_DIVISOR > 0,
            VirtualAssetsTooLow()
        );

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

    function _pairLpToken(address tokenA, address tokenB, address swapRouter) internal view returns (address lpToken) {
        return IMemeverseSwapRouter(swapRouter).lpToken(tokenA, tokenB);
    }

    function _positiveDeltaAmountForToken(BalanceDelta delta, address token, address tokenA, address tokenB)
        internal
        pure
        returns (uint256 amount)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        if (token == token0) {
            int128 amount0 = delta.amount0();
            return amount0 > 0 ? uint256(uint128(amount0)) : 0;
        }

        if (token == token1) {
            int128 amount1 = delta.amount1();
            return amount1 > 0 ? uint256(uint128(amount1)) : 0;
        }

        return 0;
    }
}
