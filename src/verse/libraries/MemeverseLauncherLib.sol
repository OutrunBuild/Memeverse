// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IMemeverseOFTEnum} from "../../common/types/IMemeverseOFTEnum.sol";
import {IMemeverseSwapRouter} from "../../swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseLauncher} from "../interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "../interfaces/IMemeverseLauncherStorage.sol";

/// @title MemeverseLauncherLib
/// @notice Internal helpers shared between the MemeverseLauncherUpgradeable facade and its MemeverseLaunchImpl /
///         MemeverseSettlementImpl / MemeverseLiquidityImpl / MemeverseFeePreviewReader siblings: settlement-wiring
///         validation, genesis-funds arithmetic, and the pure fee-mapping / executor-reward split used by both the
///         settlement sibling and the preview reader.
/// @dev Functions are `internal`, so they compile inline into each caller. Under both call paths
///      (facade setters and the sibling's `deployBootstrapLiquidity`) the caller runs in the proxy's
///      delegatecall context, so `address(this)` resolves to the proxy and the wiring check stays
///      consistent. Keep this library to helpers genuinely used by BOTH contracts — do not let it
///      grow into a catch-all dumping ground.
library MemeverseLauncherLib {
    /// @dev Upper bound on combined genesis funds; guards the addition in `checkedTotalGenesisFunds`
    ///      and the remaining-cap projections in the facade.
    uint256 internal constant MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max;

    /// @dev Ratio basis (10000) used by `splitExecutorReward`. Single source of truth shared by the
    ///      distributor and preview reader so the two callers cannot drift.
    uint256 internal constant RATIO = 10000;

    /// @dev Numerator of the fixed 0.7% factor sizing the yield-vault virtual buffer. Single source of
    ///      truth shared by the facade's `setFundMetaData` validation and the launch sibling's vault-deploy
    ///      computation so the two cannot drift.
    uint256 internal constant YIELD_VAULT_VIRTUAL_ASSET_FACTOR = 7;

    /// @dev Denominator paired with `YIELD_VAULT_VIRTUAL_ASSET_FACTOR` to express 0.7%.
    uint256 internal constant YIELD_VAULT_VIRTUAL_ASSET_DIVISOR = 1000;

    /// @notice Reverts unless the swap-router, uniswap-hook, and launcher are mutually wired:
    ///         the router points at the hook, the hook is bound to this launcher, and the hook's
    ///         pool initializer is the router. Guards preorder settlement at both the config gate
    ///         and the bootstrap runtime gate.
    function validateSettlementWiring(address routerAddress, address hookAddress) internal view {
        require(
            routerAddress != address(0) && hookAddress != address(0),
            IMemeverseLauncher.InvalidPreorderSettlementConfig()
        );
        IMemeverseSwapRouter router = IMemeverseSwapRouter(routerAddress);
        IMemeverseUniswapHook hook = IMemeverseUniswapHook(hookAddress);
        require(
            address(router.hook()) == hookAddress && hook.launcher() == address(this)
                && hook.poolInitializer() == routerAddress,
            IMemeverseLauncher.InvalidPreorderSettlementConfig()
        );
    }

    /// @notice Returns `normalFunds + leveragedDebt`, reverting if the sum exceeds the supported cap.
    function checkedTotalGenesisFunds(uint256 normalFunds, uint256 leveragedDebt)
        internal
        pure
        returns (uint256 totalFunds)
    {
        totalFunds = normalFunds + leveragedDebt;
        if (totalFunds > MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) {
            revert IMemeverseLauncher.TotalGenesisFundsTooHigh(totalFunds, MAX_SUPPORTED_TOTAL_GENESIS_FUNDS);
        }
    }

    /// @notice Order two collected pair-fee amounts so the returned tuple matches `(tokenA, tokenB)`
    ///         regardless of pool token0/token1 ordering.
    /// @dev Shared by `MemeverseSettlementImpl._mapPairFees` and `MemeverseFeePreviewReader._mapPairFees`
    ///      so the two callers cannot drift.
    /// @param tokenA First token in the caller-facing pair.
    /// @param tokenB Second token in the caller-facing pair.
    /// @param fee0 Fee amount collected for the pool's token0.
    /// @param fee1 Fee amount collected for the pool's token1.
    /// @return tokenAFee Fee amount attributed to `tokenA`.
    /// @return tokenBFee Fee amount attributed to `tokenB`.
    function mapPairFees(address tokenA, address tokenB, uint256 fee0, uint256 fee1)
        internal
        pure
        returns (uint256 tokenAFee, uint256 tokenBFee)
    {
        if (tokenA < tokenB) {
            return (fee0, fee1);
        }
        return (fee1, fee0);
    }

    /// @notice Splits auxiliary-pool fees into the governance (leveraged) share vs the normal share.
    /// @dev Shared by `MemeverseSettlementImpl._splitAuxiliaryGovFees` (runtime settlement) and
    ///      `MemeverseFeePreviewReader._splitAuxiliaryGovFees` (off-chain preview) so the two cannot drift on
    ///      the split formula. Callers fetch `normalFunds` and `totalLeveragedDebt` themselves (storage vs proxy
    ///      getter) and pass them in; this function is pure (no storage/external reads).
    ///      When `preserveNormalShare` is false the full amount is governance; otherwise the governance share is
    ///      the leveraged-pro-rata slice `amount * totalLeveragedDebt / totalFunds` (totalFunds from
    ///      `checkedTotalGenesisFunds`, short-circuiting to the full amount when totalFunds == 0).
    /// @param normalFunds Non-leveraged genesis funds for the verse (used to derive totalFunds).
    /// @param totalLeveragedDebt Leveraged genesis debt for the verse (used to derive totalFunds and the gov share).
    /// @param totalUAssetFee Total uAsset fee collected from auxiliary pools to split.
    /// @param totalPTFee Total PT fee collected from auxiliary pools to split.
    /// @param preserveNormalShare When false, route the full amount to governance (genesis, no normal share yet).
    /// @return govUAssetFee Governance (leveraged) uAsset fee share.
    /// @return govPTFee Governance (leveraged) PT fee share.
    function splitAuxiliaryGovFees(
        uint256 normalFunds,
        uint256 totalLeveragedDebt,
        uint256 totalUAssetFee,
        uint256 totalPTFee,
        bool preserveNormalShare
    ) internal pure returns (uint256 govUAssetFee, uint256 govPTFee) {
        if (!preserveNormalShare) return (totalUAssetFee, totalPTFee);
        uint256 totalFunds = checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        if (totalFunds == 0) return (totalUAssetFee, totalPTFee);

        govUAssetFee = FullMath.mulDiv(totalUAssetFee, totalLeveragedDebt, totalFunds);
        govPTFee = FullMath.mulDiv(totalPTFee, totalLeveragedDebt, totalFunds);
    }

    /// @notice Split a main-pool uAsset fee into the executor reward and governor share using ratio basis `RATIO`.
    /// @dev Shared by `MemeverseSettlementImpl._splitExecutorReward` and
    ///      `MemeverseFeePreviewReader._splitExecutorReward`; the wrappers only differ in how they read
    ///      `executorRewardRate` (storage vs. proxy getter). Uses `FullMath.mulDiv` so the multiplication
    ///      cannot overflow before the divide.
    /// @param uAssetFee Total uAsset fee collected from the main pool.
    /// @param executorRewardRate Basis-points rate (denominator `RATIO`) of `uAssetFee` paid to the executor.
    /// @return govFee Remaining share routed to governance.
    /// @return executorReward Share paid out as the executor incentive.
    function splitExecutorReward(uint256 uAssetFee, uint256 executorRewardRate)
        internal
        pure
        returns (uint256 govFee, uint256 executorReward)
    {
        executorReward = FullMath.mulDiv(uAssetFee, executorRewardRate, RATIO);
        govFee = uAssetFee - executorReward;
    }

    /// @notice Compute the permanent virtual buffer for a yield vault from its fund metadata.
    /// @dev V = minTotalFund * fundBasedAmount * YIELD_VAULT_VIRTUAL_ASSET_FACTOR / YIELD_VAULT_VIRTUAL_ASSET_DIVISOR
    ///      (0.7% of the minimum main-pool memecoin provision). Shared by the facade `setFundMetaData`
    ///      `> 0` validation and the launch sibling's vault-deploy computation so the two cannot drift.
    ///      Plain multiplication/division (no FullMath) mirrors the original inline implementations; values
    ///      are bounded (`fundBasedAmount <= MAX_FUND_BASED_AMOUNT = 2^64 - 1`, and `minTotalFund *` that
    ///      product `* 7` cannot overflow uint256 in practice), so rounding/gas stay identical to before.
    /// @param minTotalFund Minimum genesis fund for the uAsset (from FundMetaData).
    /// @param fundBasedAmount Memecoins minted per unit of genesis fund (from FundMetaData).
    /// @return virtualAssets The permanent virtual buffer passed to MemecoinYieldVault.initialize.
    function virtualAssetsBuffer(uint256 minTotalFund, uint256 fundBasedAmount)
        internal
        pure
        returns (uint256 virtualAssets)
    {
        return minTotalFund * fundBasedAmount * YIELD_VAULT_VIRTUAL_ASSET_FACTOR / YIELD_VAULT_VIRTUAL_ASSET_DIVISOR;
    }

    /// @notice Build the LayerZero OFT `SendParam` for a fee-distribution send and quote its messaging fee.
    /// @dev Shared by `MemeverseSettlementImpl._buildSendParamAndMessagingFee` and
    ///      `MemeverseFeePreviewReader._buildSendParamAndMessagingFee` so the two callers cannot drift on the
    ///      SendParam structure (dstEid / `to` = yieldDispatcher / composeMsg / extraOptions). Both callers
    ///      already pass every input as a parameter, so the body is identical and inlines without storage reads.
    ///      Load-bearing multichain precondition: `to = yieldDispatcher` is delivered on the destination
    ///      (governance) chain, so the caller-supplied `yieldDispatcher` must equal the governance chain's
    ///      actual YieldDispatcherUpgradeable address. The deployment script satisfies this via CREATE3 same-address
    ///      (OutrunDeployer + `keccak256("YieldDispatcher", nonce)` salt); a mismatch strands fees on the
    ///      governance chain with no recovery path (fail-closed, no third-party theft).
    /// @param govEndpointId Destination LayerZero endpoint id.
    /// @param amount Token amount to bridge (`amountLD`).
    /// @param token OFT token being sent (used to quote).
    /// @param receiver Endpoint-side receiver encoded into `composeMsg`.
    /// @param tokenType Token-type tag encoded into `composeMsg`.
    /// @param yieldDispatcherOptions Executor gas options appended to the send.
    /// @param yieldDispatcher Address the OFT send is addressed to (`SendParam.to`).
    /// @return sendParam The constructed OFT send parameter.
    /// @return messagingFee The quoted native + lzToken messaging fee.
    function buildSendParamAndMessagingFee(
        uint32 govEndpointId,
        uint256 amount,
        address token,
        address receiver,
        IMemeverseOFTEnum.TokenType tokenType,
        bytes memory yieldDispatcherOptions,
        address yieldDispatcher
    ) internal view returns (SendParam memory sendParam, MessagingFee memory messagingFee) {
        sendParam = SendParam({
            dstEid: govEndpointId,
            to: bytes32(uint256(uint160(yieldDispatcher))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: yieldDispatcherOptions,
            composeMsg: abi.encode(receiver, tokenType),
            oftCmd: abi.encode()
        });
        messagingFee = IOFT(token).quoteSend(sendParam, false);
    }

    /// @notice Compute the per-verse preorder capacity ceiling from the current genesis base funds.
    /// @dev Shared by the facade view `previewPreorderCapacity` and the launch sibling's `preorder` so the
    ///      two callers cannot drift on the 70% cap math (`totalBaseFunds * 7 * preorderCapRatio / 10 / RATIO`).
    ///      Reading `preorderCapRatio` from the passed storage pointer `s` works identically in the facade
    ///      (its own `memeverseLauncherStorage`) and the sibling (the proxy's via delegatecall). The literal
    ///      `10` is the cap denominator and `RATIO` is the basis-points denominator; both are kept inline to
    ///      mirror the original facade `_preorderMaxCapacity` byte-for-byte.
    /// @param s The MemeverseLauncherStorage pointer (facade's or proxy's under delegatecall).
    /// @param totalBaseFunds Combined normal genesis funds + leveraged debt (from `checkedTotalGenesisFunds`).
    /// @return capacity Maximum total preorder funds accepted for the verse.
    function preorderMaxCapacity(MemeverseLauncherStorage storage s, uint256 totalBaseFunds)
        internal
        view
        returns (uint256)
    {
        return FullMath.mulDiv(totalBaseFunds, 7 * s.preorderCapRatio, 10 * RATIO);
    }

    /// @notice Compute the currently claimable (vested, unclaimed) preorder memecoin for an account.
    /// @dev Shared by the facade view `claimablePreorderMemecoin(verseId)` and the settlement sibling's
    ///      `claimUnlockedPreorderMemecoin(verseId)` so the two callers cannot drift on the vesting math.
    ///      Reads verse-id validity, stage (`>= Stage.Locked`), preorder state, and user preorder data
    ///      directly from the passed storage pointer `s` so it works identically in the facade (which reads
    ///      its own `memeverseLauncherStorage`) and the sibling (which reads the proxy's
    ///      `memeverseLauncherStorage` via delegatecall). The verse-id check is inlined (no facade-only
    ///      `_versIdValidate` dependency) and the math mirrors the original facade helper byte-for-byte.
    /// @param s The MemeverseLauncherStorage pointer (facade's or proxy's under delegatecall).
    /// @param verseId Memeverse id.
    /// @param account The preorder participant whose vested memecoin is being measured.
    /// @return amount The currently claimable preorder memecoin amount (zero if none vested or already claimed).
    function claimablePreorderMemecoinForAccount(MemeverseLauncherStorage storage s, uint256 verseId, address account)
        internal
        view
        returns (uint256 amount)
    {
        require(s.memeverses[verseId].memecoin != address(0), IMemeverseLauncher.InvalidVerseId());
        require(
            s.memeverses[verseId].currentStage >= IMemeverseLauncher.Stage.Locked,
            IMemeverseLauncher.NotReachedLockedStage()
        );

        IMemeverseLauncher.PreorderState storage preorderState = s.preorderStates[verseId];
        uint40 settlementTimestamp = preorderState.settlementTimestamp;
        if (settlementTimestamp == 0) return 0;

        IMemeverseLauncher.PreorderData storage preorderData = s.userPreorderData[verseId][account];
        uint256 userFunds = preorderData.funds;
        uint256 totalFunds = preorderState.totalFunds;
        if (userFunds == 0 || totalFunds == 0) return 0;

        // Full-precision floor division preserves preorder accounting for large settled amounts.
        uint256 purchasedMemecoin = FullMath.mulDiv(preorderState.settledMemecoin, userFunds, totalFunds);
        if (purchasedMemecoin <= preorderData.claimedMemecoin) return 0;

        uint256 vestingDuration = s.preorderVestingDuration;
        uint256 elapsed = block.timestamp > settlementTimestamp ? block.timestamp - settlementTimestamp : 0;
        if (elapsed >= vestingDuration) {
            return purchasedMemecoin - preorderData.claimedMemecoin;
        }

        uint256 vested = FullMath.mulDiv(purchasedMemecoin, elapsed, vestingDuration);
        if (vested <= preorderData.claimedMemecoin) return 0;
        return vested - preorderData.claimedMemecoin;
    }
}
