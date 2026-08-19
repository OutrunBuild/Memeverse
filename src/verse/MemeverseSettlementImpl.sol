// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, OFTReceipt, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {DelegatecallOnly} from "../common/access/DelegatecallOnly.sol";
import {IMemeverseOFTEnum} from "../common/types/IMemeverseOFTEnum.sol";
import {IPol} from "../token/interfaces/IPol.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemeverseUniswapHook} from "../swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeversePoolKeyLib} from "../swap/libraries/MemeversePoolKeyLib.sol";
import {ILzEndpointRegistry} from "../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IYieldDispatcher} from "./interfaces/IYieldDispatcher.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {ICrossChainSendErrors} from "../common/types/ICrossChainSendErrors.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";

/// @title MemeverseSettlementImpl
/// @notice Delegatecall-only sibling that owns the settlement-side flows for MemeverseLauncherUpgradeable: genesis /
///         preorder refunds, normal YT / fee claims, unlocked preorder-memecoin claims, the fee collection
///         and distribution chain, and the Locked -> Unlocked stage transition.
/// @dev Binds the SAME ERC-7201 namespace as the launcher facade
///      (`erc7201("outrun.storage.MemeverseLauncher")`), so under delegatecall every storage read/write lands
///      on the launcher proxy's MemeverseLauncherStorage. The sibling has no initializer, no owner, no own
///      mutable state, and intentionally no `msg.sender == launcher` guard: under delegatecall `msg.sender`
///      is the facade's original caller (user, executor, POLendUpgradeable, or stage advancer) and `address(this)` is
///      the launcher proxy. A direct (non-delegatecall) call reverts via the inherited `onlyDelegatecall`
///      guard (see `DelegatecallOnly`) before any storage access, so the sibling is explicitly guarded.
///
///      Nested types (Memeverse, Stage, PreorderState, GenesisData, PreorderData, NormalFeeState,
///      UserNormalFeeClaim, RedeemedFeeState, PendingAuxiliaryGovFeeState, ...) and the errors live in
///      interface IMemeverseLauncher. Unlike the facade (which inherits IMemeverseLauncher and uses bare
///      names), this sibling only inherits TokenHelper, so every reference below is qualified as
///      `IMemeverseLauncher.X`.
contract MemeverseSettlementImpl layout at erc7201("outrun.storage.MemeverseLauncher")
    is
    TokenHelper,
    DelegatecallOnly
{
    using OptionsBuilder for bytes;

    uint256 internal constant UNLOCK_PROTECTION_WINDOW = 24 hours;

    /// @dev Same ERC-7201 namespace as the launcher facade; under delegatecall this reads/writes the proxy's
    ///      MemeverseLauncherStorage. Do NOT add an initializer, owner, or any setter.
    MemeverseLauncherStorage private memeverseLauncherStorage;

    // =========================================================================================================
    // Refunds + normal claims
    // =========================================================================================================

    /**
     * @notice Refund the caller's uAsset genesis contribution after a verse resolved to `Stage.Refund`.
     * @dev Invoked via delegatecall by the facade's `refund`. The facade keeps the outer `versIdValidate`
     *      guard; this sibling owns the stage check, refund flag, transfer, and emit. Under delegatecall
     *      `msg.sender` is the original caller (refund recipient).
     * @param verseId Memeverse id.
     * @return genesisFund The refunded genesis contribution amount.
     */
    function refund(uint256 verseId) external onlyDelegatecall returns (uint256 genesisFund) {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Refund, IMemeverseLauncher.NotRefundStage());

        address msgSender = msg.sender;
        IMemeverseLauncher.GenesisData storage genesisData =
            memeverseLauncherStorage.userGenesisData[verseId][msgSender];
        genesisFund = genesisData.genesisFund;
        require(genesisFund > 0 && !genesisData.isRefunded, IMemeverseLauncher.InvalidClaim());

        genesisData.isRefunded = true;
        _transferOut(verse.uAsset, msgSender, genesisFund);

        emit IMemeverseLauncher.Refund(verseId, msgSender, genesisFund);
    }

    /**
     * @notice Refund the caller's uAsset preorder contribution after a verse resolved to `Stage.Refund`.
     * @dev Invoked via delegatecall by the facade's `refundPreorder`. Under delegatecall `msg.sender` is
     *      the original caller (refund recipient).
     * @param verseId Memeverse id.
     * @return preorderFund The refunded preorder contribution amount.
     */
    function refundPreorder(uint256 verseId) external onlyDelegatecall returns (uint256 preorderFund) {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Refund, IMemeverseLauncher.NotRefundStage());

        address msgSender = msg.sender;
        IMemeverseLauncher.PreorderData storage preorderData =
            memeverseLauncherStorage.userPreorderData[verseId][msgSender];
        preorderFund = preorderData.funds;
        require(preorderFund > 0 && !preorderData.isRefunded, IMemeverseLauncher.InvalidClaim());

        preorderData.isRefunded = true;
        _transferOut(verse.uAsset, msgSender, preorderFund);

        emit IMemeverseLauncher.RefundPreorder(verseId, msgSender, preorderFund);
    }

    /**
     * @notice Claim the caller's normal YT (Yield Token) share after Genesis resolves to `Locked`.
     * @dev Invoked via delegatecall by the facade's `claimNormalYT`. The facade keeps the outer
     *      `versIdValidate` + `whenNotPaused` guards; this sibling owns the stage check, one-shot flag,
     *      transfer, and emit. Under delegatecall `msg.sender` is the original caller (YT recipient).
     * @param verseId Memeverse id.
     * @return amount The claimed YT amount.
     */
    function claimNormalYT(uint256 verseId) external onlyDelegatecall returns (uint256 amount) {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= IMemeverseLauncher.Stage.Locked, IMemeverseLauncher.NotReachedLockedStage());

        address msgSender = msg.sender;
        require(!memeverseLauncherStorage.normalYTClaimed[verseId][msgSender], IMemeverseLauncher.InvalidClaim());

        uint256 userGenesisFund = memeverseLauncherStorage.userGenesisData[verseId][msgSender].genesisFund;
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        require(userGenesisFund != 0 && normalFunds != 0, IMemeverseLauncher.InvalidClaim());

        amount = FullMath.mulDiv(memeverseLauncherStorage.totalNormalClaimableYT[verseId], userGenesisFund, normalFunds);

        memeverseLauncherStorage.normalYTClaimed[verseId][msgSender] = true;
        if (amount != 0) {
            address _polSplitter = memeverseLauncherStorage.polSplitter;
            address yt = IPOLSplitter(_polSplitter).getYT(verseId);
            _transferOut(yt, msgSender, amount);
        }

        emit IMemeverseLauncher.ClaimNormalYT(verseId, msgSender, amount);
    }

    /**
     * @notice Claim the caller's accumulated uAsset and PT normal-fee entitlements.
     * @dev Invoked via delegatecall by the facade's `claimNormalFees`. The facade keeps the outer
     *      `versIdValidate` + `whenNotPaused` guards; this sibling owns the CEI commit, PT settlement /
     *      transfer, uAsset transfer, and emit. Under delegatecall `msg.sender` is the original caller
     *      (fee recipient). The trust boundary is the configured POLSplitterUpgradeable.
     * @param verseId Memeverse id.
     * @return uAssetAmount The claimed uAsset fee amount.
     * @return ptAmount The PT fee amount: transferred PT, or zero when redeemed to uAsset in place;
     *      on the settled zero-backing dust path it reports the still-pending PT entitlement.
     */
    function claimNormalFees(uint256 verseId)
        external
        onlyDelegatecall
        returns (uint256 uAssetAmount, uint256 ptAmount)
    {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage >= IMemeverseLauncher.Stage.Locked, IMemeverseLauncher.NotReachedLockedStage());

        address _polSplitter = memeverseLauncherStorage.polSplitter;
        (address pt, bool settled) = IPOLSplitter(_polSplitter).getPTSettlementState(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 userFund = memeverseLauncherStorage.userGenesisData[verseId][msg.sender].genesisFund;
        require(userFund != 0 && normalFunds != 0, IMemeverseLauncher.InvalidClaim());
        IMemeverseLauncher.UserNormalFeeClaim storage userClaim =
            memeverseLauncherStorage.userNormalFeeClaims[verseId][msg.sender];
        IMemeverseLauncher.NormalFeeState storage feeState = memeverseLauncherStorage.normalFeeStates[verseId];

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
                    // Dust rounding makes the PT redeemable for zero uAsset: no PT transfer or redeem
                    // occurred this call, so ptAmount keeps reporting the still-pending entitlement.
                    // claimedPTFee is intentionally left untouched so the entitlement self-heals as
                    // future fee accrual grows accPTFee.
                }
            } else {
                userClaim.claimedPTFee = entitledPT;
                _transferOut(pt, msg.sender, pendingPTAmount);
            }
        }
        if (claimableUAssetAmount != 0) {
            _transferOut(verse.uAsset, msg.sender, claimableUAssetAmount);
        }
        emit IMemeverseLauncher.ClaimNormalFees(verseId, msg.sender, uAssetAmount, ptAmount);
    }

    /**
     * @notice Claim the caller's currently vested unlocked preorder memecoin.
     * @dev Invoked via delegatecall by the facade's `claimUnlockedPreorderMemecoin`. Uses the shared
     *      `MemeverseLauncherLib.claimablePreorderMemecoinForAccount` helper. Under delegatecall `msg.sender`
     *      is the original caller (memecoin recipient).
     * @param verseId Memeverse id.
     * @return amount The claimed preorder memecoin amount.
     */
    function claimUnlockedPreorderMemecoin(uint256 verseId) external onlyDelegatecall returns (uint256 amount) {
        amount = MemeverseLauncherLib.claimablePreorderMemecoinForAccount(memeverseLauncherStorage, verseId, msg.sender);
        require(amount != 0, IMemeverseLauncher.NoPOLAvailable());

        address msgSender = msg.sender;
        memeverseLauncherStorage.userPreorderData[verseId][msgSender].claimedMemecoin += amount;
        _transferOut(memeverseLauncherStorage.memeverses[verseId].memecoin, msgSender, amount);
        emit IMemeverseLauncher.ClaimPreorderMemecoin(verseId, msgSender, amount);
    }

    // =========================================================================================================
    // Fee collection and distribution chain
    // =========================================================================================================

    /**
     * @notice Collect redeemed fees, burn POL, split the executor reward, and distribute the rest.
     * @dev Invoked via delegatecall by the facade's `redeemAndDistributeFees`. The facade performs the
     *      `rewardReceiver` / verse-id / stage validation and emits `RedeemAndDistributeFees` after
     *      decoding the return values; this entry only runs the collect -> burn -> split -> distribute
     *      block so both `_transferOut` exits (executor reward + distribution) share one delegatecall
     *      and the `TokenHelper` reentrancy lock's acquire/release lifecycle stays whole.
     *      `msg.value` is the caller-supplied LayerZero native fee and is preserved across the
     *      delegatecall, hence `payable`.
     *      Delegatecall-only is enforced by the inherited `onlyDelegatecall` guard (see `DelegatecallOnly`),
     *      which reverts on direct call before any storage access. A `msg.sender == launcher` guard would
     *      still be wrong here, because under delegatecall `msg.sender` is the facade's caller (arbitrary),
     *      not the facade.
     * @param verseId Memeverse id.
     * @param rewardReceiver Receiver of the executor reward.
     * @param polSplitter The launcher's configured POLSplitterUpgradeable address (forwarded by the facade).
     * @return govFee The distributed governor fee amount.
     * @return memecoinFee The distributed memecoin fee amount.
     * @return polFee The distributed POL fee amount.
     * @return executorReward The distributed executor reward amount.
     * @return hadFees True iff any redeemed fees were collected (the facade emits only when true).
     */
    function collectAndDistributeFees(uint256 verseId, address rewardReceiver, address polSplitter)
        external
        payable
        onlyDelegatecall
        returns (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward, bool hadFees)
    {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        IMemeverseLauncher.RedeemedFeeState memory fees = _collectRedeemedFees(verseId, verse, polSplitter);
        if (_hasNoRedeemedFees(fees)) {
            if (msg.value != 0) revert IMemeverseLauncher.InvalidLzFee(0, msg.value);
            return (0, 0, 0, 0, false);
        }
        if (fees.polFee != 0) IPol(verse.pol).burn(address(this), fees.polFee);

        (govFee, executorReward) =
            MemeverseLauncherLib.splitExecutorReward(fees.uAssetFee, memeverseLauncherStorage.executorRewardRate);
        // Anyone can execute fee redemption; only the uAsset-side fee is split with the caller as an execution incentive.
        if (executorReward != 0) _transferOut(verse.uAsset, rewardReceiver, executorReward);

        memecoinFee = fees.memecoinFee;
        polFee = fees.polFee;
        govFee = _distributeRedeemedFees(verseId, verse, govFee, fees, polSplitter);
        hadFees = true;
    }

    function _collectRedeemedFees(uint256 verseId, IMemeverseLauncher.Memeverse storage verse, address _polSplitter)
        internal
        returns (IMemeverseLauncher.RedeemedFeeState memory fees)
    {
        address _hook = memeverseLauncherStorage.memeverseUniswapHook;
        (fees.memecoinFee, fees.uAssetFee) = _claimPairFees(verse.memecoin, verse.uAsset, _hook);

        address pt = IPOLSplitter(_polSplitter).getPT(verseId);
        // totalLeveragedDebt is discarded here: only `unlockFromLocked` reuses it to skip a duplicate
        // getTotalLeveragedDebt call; `_collectRedeemedFees` (redeemAndDistributeFees path) never needs it.
        (fees.auxiliaryGovUAssetFee, fees.auxiliaryGovPTFee, fees.polFee,) = _claimAndAccrueAuxiliaryFees(
            verseId, verse, pt, verse.currentStage == IMemeverseLauncher.Stage.Locked, _hook
        );

        fees = _mergePendingAuxiliaryGovFees(verseId, fees, _polSplitter);
    }

    function _mergePendingAuxiliaryGovFees(
        uint256 verseId,
        IMemeverseLauncher.RedeemedFeeState memory fees,
        address _polSplitter
    ) internal returns (IMemeverseLauncher.RedeemedFeeState memory) {
        IMemeverseLauncher.PendingAuxiliaryGovFeeState storage pendingGovFeeState =
            memeverseLauncherStorage.pendingAuxiliaryGovFeeStates[verseId];
        uint256 pendingUAssetFee = pendingGovFeeState.pendingUAssetFee;
        uint256 pendingPTFee = pendingGovFeeState.pendingPTFee;
        uint256 auxiliaryGovPTFee = fees.auxiliaryGovPTFee + pendingPTFee;

        fees.auxiliaryGovUAssetFee += pendingUAssetFee;
        if (auxiliaryGovPTFee != 0) {
            if (IPOLSplitter(_polSplitter).previewPTToUAsset(verseId, auxiliaryGovPTFee) == 0) {
                pendingGovFeeState.pendingPTFee = auxiliaryGovPTFee;
                fees.auxiliaryGovPTFee = 0;
            } else {
                fees.auxiliaryGovPTFee = auxiliaryGovPTFee;
                pendingGovFeeState.pendingPTFee = 0;
            }
        }
        if (pendingUAssetFee != 0) pendingGovFeeState.pendingUAssetFee = 0;

        return fees;
    }

    function _hasNoRedeemedFees(IMemeverseLauncher.RedeemedFeeState memory fees) internal pure returns (bool) {
        return fees.uAssetFee == 0 && fees.memecoinFee == 0 && fees.polFee == 0 && fees.auxiliaryGovUAssetFee == 0
            && fees.auxiliaryGovPTFee == 0;
    }

    function _distributeRedeemedFees(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        uint256 govFee,
        IMemeverseLauncher.RedeemedFeeState memory fees,
        address _polSplitter
    ) internal returns (uint256) {
        if (verse.omnichainIds[0] == block.chainid) {
            return _distributeRedeemedFeesSameChain(verseId, verse, govFee, fees, _polSplitter);
        }
        return _distributeRedeemedFeesCrossChain(verseId, verse, govFee, fees, _polSplitter);
    }

    function _distributeRedeemedFeesSameChain(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        uint256 govFee,
        IMemeverseLauncher.RedeemedFeeState memory fees,
        address _polSplitter
    ) internal returns (uint256) {
        if (msg.value != 0) {
            revert IMemeverseLauncher.InvalidLzFee(0, msg.value);
        }
        address _yieldDispatcher = memeverseLauncherStorage.yieldDispatcher;
        address _polend = memeverseLauncherStorage.polend;

        // Snapshot the auxiliary uAsset the launcher physically holds before any PT redemption. The PT-redeem calls
        // below mint/redeem the converted uAsset DIRECTLY to `_yieldDispatcher` (their third arg), so only the
        // pre-redemption amount is still on the launcher's balance and must be `_transferOut`'d separately (line below).
        uint256 auxiliaryGovUAssetHeldByLauncher = fees.auxiliaryGovUAssetFee;
        if (fees.auxiliaryGovPTFee != 0) {
            if (verse.currentStage == IMemeverseLauncher.Stage.Locked) {
                fees.auxiliaryGovUAssetFee += IPOLend(_polend)
                    .preRedeemPTFee(verseId, fees.auxiliaryGovPTFee, _yieldDispatcher);
            } else {
                fees.auxiliaryGovUAssetFee += IPOLSplitter(_polSplitter)
                    .redeemPT(verseId, fees.auxiliaryGovPTFee, _yieldDispatcher);
            }
            fees.auxiliaryGovPTFee = 0;
        }

        // `transferToDispatcher` covers what the launcher physically holds (snapshot + base govFee); the freshly
        // redeemed uAsset already arrived at the dispatcher. `govFee` then reports the TOTAL (held + pre-sent) for
        // accounting via `distributeSameChain`, so the two lines use two deliberately different buckets.
        uint256 transferToDispatcher = govFee + auxiliaryGovUAssetHeldByLauncher;
        govFee += fees.auxiliaryGovUAssetFee;
        // Same-chain governance routes through YieldDispatcherUpgradeable's dedicated same-chain entry so local and remote fee
        // flows share one settlement sink.
        if (govFee != 0) {
            if (transferToDispatcher != 0) {
                _transferOut(verse.uAsset, _yieldDispatcher, transferToDispatcher);
            }
            IYieldDispatcher(_yieldDispatcher)
                .distributeSameChain(verse.uAsset, verse.governor, IMemeverseOFTEnum.TokenType.UASSET, govFee);
        }
        if (fees.memecoinFee != 0) {
            _transferOut(verse.memecoin, _yieldDispatcher, fees.memecoinFee);
            IYieldDispatcher(_yieldDispatcher)
                .distributeSameChain(
                    verse.memecoin, verse.yieldVault, IMemeverseOFTEnum.TokenType.MEMECOIN, fees.memecoinFee
                );
        }

        return govFee;
    }

    function _distributeRedeemedFeesCrossChain(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        uint256 govFee,
        IMemeverseLauncher.RedeemedFeeState memory fees,
        address _polSplitter
    ) internal returns (uint256) {
        if (fees.auxiliaryGovPTFee != 0) {
            uint256 convertedUAssetAmount;
            if (verse.currentStage == IMemeverseLauncher.Stage.Locked) {
                convertedUAssetAmount = IPOLend(memeverseLauncherStorage.polend)
                    .preRedeemPTFee(verseId, fees.auxiliaryGovPTFee, address(this));
            } else {
                convertedUAssetAmount =
                    IPOLSplitter(_polSplitter).redeemPT(verseId, fees.auxiliaryGovPTFee, address(this));
            }
            fees.auxiliaryGovUAssetFee += convertedUAssetAmount;
            fees.auxiliaryGovPTFee = 0;
        }

        govFee += fees.auxiliaryGovUAssetFee;
        _sendRedeemedFeesCrossChain(verse, govFee, fees.memecoinFee);
        return govFee;
    }

    function _sendRedeemedFeesCrossChain(
        IMemeverseLauncher.Memeverse storage verse,
        uint256 govFee,
        uint256 memecoinFee
    ) internal {
        // Cross-chain governance prebuilds both OFT sends, then requires the caller to fund exactly the combined native messaging fee.
        uint32 govEndpointId =
            ILzEndpointRegistry(memeverseLauncherStorage.lzEndpointRegistry).lzEndpointIdOfChain(verse.omnichainIds[0]);
        bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(memeverseLauncherStorage.oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, memeverseLauncherStorage.yieldDispatcherGasLimit, 0);
        // Cache yieldDispatcher once because both OFT send-param builds consume the same address.
        address _yieldDispatcher = memeverseLauncherStorage.yieldDispatcher;

        SendParam memory sendUAssetParam;
        MessagingFee memory govMessagingFee;
        if (govFee != 0) {
            (sendUAssetParam, govMessagingFee) = MemeverseLauncherLib.buildSendParamAndMessagingFee(
                govEndpointId,
                govFee,
                verse.uAsset,
                verse.governor,
                IMemeverseOFTEnum.TokenType.UASSET,
                yieldDispatcherOptions,
                _yieldDispatcher
            );
        }

        SendParam memory sendMemecoinParam;
        MessagingFee memory memecoinMessagingFee;
        if (memecoinFee != 0) {
            (sendMemecoinParam, memecoinMessagingFee) = MemeverseLauncherLib.buildSendParamAndMessagingFee(
                govEndpointId,
                memecoinFee,
                verse.memecoin,
                verse.yieldVault,
                IMemeverseOFTEnum.TokenType.MEMECOIN,
                yieldDispatcherOptions,
                _yieldDispatcher
            );
        }

        uint256 requiredLzFee = govMessagingFee.nativeFee + memecoinMessagingFee.nativeFee;
        if (msg.value != requiredLzFee) revert IMemeverseLauncher.InvalidLzFee(requiredLzFee, msg.value);
        // Reject sub-`decimalConversionRate` fees before sending: a fee truncated to zero by `_removeDust` would burn
        // nothing, deliver a zero-amount compose, strand the fee at the launcher/dispatcher (no sweep), and charge the
        // full LayerZero fee. Fee amounts are protocol-computed (swap-fee accumulation), so only the truncate-to-zero
        // case is rejected — not the non-zero remainder (amount % rate != 0), which is the documented dust-stranding
        // trade-off for the fee path.
        if (govFee != 0) {
            _requireNonZeroDelivery(verse.uAsset, sendUAssetParam);
            // solhint-disable-next-line check-send-result
            IOFT(verse.uAsset).send{value: govMessagingFee.nativeFee}(sendUAssetParam, govMessagingFee, msg.sender);
        }
        if (memecoinFee != 0) {
            _requireNonZeroDelivery(verse.memecoin, sendMemecoinParam);
            // solhint-disable-next-line check-send-result,multiple-sends
            IOFT(verse.memecoin).send{value: memecoinMessagingFee.nativeFee}(
                sendMemecoinParam, memecoinMessagingFee, msg.sender
            );
        }
    }

    /// @dev Pre-send guard for cross-chain fee distribution. Mirrors the staking path's guard but rejects only the
    ///      truncate-to-ZERO case (`amountReceivedLD != 0`), not non-zero remainders — fee amounts are
    ///      protocol-computed, so requiring an exact multiple would revert normal settlement.
    function _requireNonZeroDelivery(address token, SendParam memory sendParam) internal view {
        (,, OFTReceipt memory receipt) = IOFT(token).quoteOFT(sendParam);
        require(receipt.amountReceivedLD != 0, ICrossChainSendErrors.DustAmount());
    }

    function _captureLockedAuxiliaryFees(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        address polSplitterAddress,
        address hook
    ) internal returns (uint256 totalLeveragedDebt) {
        address pt = IPOLSplitter(polSplitterAddress).getPT(verseId);
        (uint256 govUAssetFee, uint256 govPTFee, uint256 burnedPolFee, uint256 leveragedDebt) =
            _claimAndAccrueAuxiliaryFees(verseId, verse, pt, true, hook);
        totalLeveragedDebt = leveragedDebt;
        if (burnedPolFee != 0) IPol(verse.pol).burn(address(this), burnedPolFee);

        IMemeverseLauncher.PendingAuxiliaryGovFeeState storage pendingGovFeeState =
            memeverseLauncherStorage.pendingAuxiliaryGovFeeStates[verseId];
        pendingGovFeeState.pendingUAssetFee += govUAssetFee;
        pendingGovFeeState.pendingPTFee += govPTFee;
    }

    function _claimAndAccrueAuxiliaryFees(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        address pt,
        bool preserveNormalShare,
        address _hook
    ) internal returns (uint256 govUAssetFee, uint256 govPTFee, uint256 burnedPolFee, uint256 totalLeveragedDebt) {
        (uint256 polUAssetPolFee, uint256 polUAssetUAssetFee) = _claimPairFees(verse.pol, verse.uAsset, _hook);
        burnedPolFee = polUAssetPolFee;

        uint256 totalAuxiliaryUAssetFee = polUAssetUAssetFee;
        uint256 totalPTFee;
        if (pt != address(0)) {
            (uint256 ptUAssetPTFee, uint256 ptUAssetUAssetFee) = _claimPairFees(pt, verse.uAsset, _hook);
            (uint256 ptPolPTFee, uint256 ptPolPolFee) = _claimPairFees(pt, verse.pol, _hook);
            totalAuxiliaryUAssetFee += ptUAssetUAssetFee;
            totalPTFee = ptUAssetPTFee + ptPolPTFee;
            burnedPolFee += ptPolPolFee;
        }

        (govUAssetFee, govPTFee, totalLeveragedDebt) =
            _accrueAuxiliaryFeeShares(verseId, totalAuxiliaryUAssetFee, totalPTFee, preserveNormalShare);
    }

    function _accrueAuxiliaryFeeShares(
        uint256 verseId,
        uint256 totalUAssetFee,
        uint256 totalPTFee,
        bool preserveNormalShare
    ) internal returns (uint256 govUAssetFee, uint256 govPTFee, uint256 totalLeveragedDebt) {
        (govUAssetFee, govPTFee, totalLeveragedDebt) =
            _splitAuxiliaryGovFees(verseId, totalUAssetFee, totalPTFee, preserveNormalShare);
        if (!preserveNormalShare) return (govUAssetFee, govPTFee, totalLeveragedDebt);

        IMemeverseLauncher.NormalFeeState storage feeState = memeverseLauncherStorage.normalFeeStates[verseId];
        feeState.accUAssetFee += totalUAssetFee - govUAssetFee;
        feeState.accPTFee += totalPTFee - govPTFee;
    }

    function _splitAuxiliaryGovFees(
        uint256 verseId,
        uint256 totalUAssetFee,
        uint256 totalPTFee,
        bool preserveNormalShare
    ) internal view returns (uint256 govUAssetFee, uint256 govPTFee, uint256 totalLeveragedDebt) {
        // GR-001: short-circuit before the SLOAD + external getTotalLeveragedDebt fetch on the
        // Unlocked-stage path (preserveNormalShare == false), where redeemAndDistributeFees is
        // repeatedly callable. Mirrors the lib helper's own first-line guard; restoring pre-refactor gas.
        // totalLeveragedDebt is left at its default 0 here: only the Locked-capture path consumes it,
        // and that path always passes preserveNormalShare == true (never short-circuits).
        if (!preserveNormalShare) return (totalUAssetFee, totalPTFee, 0);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        totalLeveragedDebt = IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        (govUAssetFee, govPTFee) = MemeverseLauncherLib.splitAuxiliaryGovFees(
            normalFunds, totalLeveragedDebt, totalUAssetFee, totalPTFee, preserveNormalShare
        );
    }

    function _claimPairFees(address tokenA, address tokenB, address _hook)
        internal
        returns (uint256 tokenAFee, uint256 tokenBFee)
    {
        PoolKey memory key = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, _hook);
        (uint256 fee0, uint256 fee1) = IMemeverseUniswapHook(_hook)
            .claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: address(this)}));
        return MemeverseLauncherLib.mapPairFees(tokenA, tokenB, fee0, fee1);
    }

    // =========================================================================================================
    // Locked -> Unlocked stage transition
    // The launch sibling owns the `ChangeStage` emit; this entry owns the state transition and the three
    // external settlement callbacks.
    // =========================================================================================================

    /**
     * @notice Capture locked auxiliary fees, advance the verse to `Stage.Unlocked`, settle POLSplitterUpgradeable /
     *         POLendUpgradeable, and arm post-unlock public-swap protection.
     * @dev Invoked via delegatecall by the launch sibling's `changeStage` Locked->Unlocked branch. The launch
     *      sibling (not the facade) owns the `currentTime > verse.unlockTime` eligibility check and the
     *      `ChangeStage` emit; this entry owns the `Stage.Unlocked` state write and the settlement callbacks,
     *      and performs no eligibility check or emit. Under delegatecall `msg.sender` is the facade's caller
     *      (arbitrary stage advancer) and `address(this)` is the launcher proxy.
     *      Ordering invariant: `verse.currentStage = Stage.Unlocked` is written BEFORE calling
     *      `IPOLend.executeGlobalSettlement`, because POLendUpgradeable re-enters the launcher during global
     *      settlement and must observe the Unlocked stage.
     * @param verseId Memeverse id.
     * @param polSplitter The launcher's configured POLSplitterUpgradeable address (forwarded by the facade).
     * @param hook The launcher's configured MemeverseUniswapHookUpgradeable address (forwarded by the facade).
     */
    function unlockFromLocked(uint256 verseId, address polSplitter, address hook) external onlyDelegatecall {
        address _polend = memeverseLauncherStorage.polend;
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];

        // totalLeveragedDebt is captured here (read once inside _captureLockedAuxiliaryFees) and reused below
        // for the executeGlobalSettlement gate, instead of a second identical getTotalLeveragedDebt STATICCALL.
        // Safe because the intervening `settle` never writes the two slots getTotalLeveragedDebt reads
        // (totalLeveragedInterest / interestRate); see GR-001 note in _splitAuxiliaryGovFees.
        uint256 totalLeveragedDebt = _captureLockedAuxiliaryFees(verseId, verse, polSplitter, hook);
        // Write Stage.Unlocked BEFORE the callbacks: POLendUpgradeable re-enters the launcher during executeGlobalSettlement
        // and must observe the Unlocked stage.
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        IPOLSplitter(polSplitter).settle(verseId);
        if (totalLeveragedDebt != 0) {
            IPOLend(_polend).executeGlobalSettlement(verseId);
        }
        _activatePostUnlockPublicSwapProtection(verseId, verse, polSplitter, hook);
    }

    function _activatePostUnlockPublicSwapProtection(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
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
}
