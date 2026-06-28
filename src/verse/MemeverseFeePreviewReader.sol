// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IMemeverseOFTEnum} from "../common/types/IMemeverseOFTEnum.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemeverseSwapRouter} from "../swap/interfaces/IMemeverseSwapRouter.sol";
import {ILzEndpointRegistry} from "../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";
import {IMemeverseFeePreviewReader} from "./interfaces/IMemeverseFeePreviewReader.sol";

/// @title MemeverseFeePreviewReader
/// @notice Independent view contract that previews genesis maker fees and quotes the LayerZero fee for
///         fee distribution. Relocated from the MemeverseLauncher facade (Step C).
/// @dev Unlike the delegatecall siblings (MemeverseLaunchImpl, MemeverseSettlementImpl, MemeverseLiquidityImpl), this reader does
///      NOT bind the launcher ERC-7201 slot and does NOT receive delegatecalls. It staticcalls the proxy's
///      public getters to read state, so it cannot mutate proxy storage. `address(this)` in the original
///      facade preview bodies referred to the fee accumulator (the proxy); here it is replaced by the
///       immutable `PROXY`, and every direct `memeverseLauncherStorage.<field>` read is replaced by a
///       proxy getter call. Preview helper parameters that were `Memeverse storage verse` are now
///       `Memeverse memory verse` (value-passed from `getMemeverseByVerseId`), because a `storage` pointer
///       here would resolve to the reader's own empty namespace and silently read zeroes.
contract MemeverseFeePreviewReader is IMemeverseFeePreviewReader {
    using OptionsBuilder for bytes;

    /// @notice The MemeverseLauncher proxy whose fee state this reader previews.
    address public immutable PROXY;

    constructor(address _proxy) {
        require(_proxy != address(0), ZeroInput());
        PROXY = _proxy;
    }

    // === relocated preview chain (from MemeverseLauncher) ===
    //
    // Nested types (Memeverse, Stage, TokenType, LauncherContracts, LauncherParameters) are declared
    // inside interface IMemeverseLauncher / IMemeverseOFTEnum. This contract does not inherit them, so
    // every reference below is qualified as IMemeverseLauncher.X / IMemeverseOFTEnum.X.

    /// @inheritdoc IMemeverseFeePreviewReader
    function previewGenesisMakerFees(uint256 verseId)
        external
        view
        override
        returns (uint256 uAssetFee, uint256 memecoinFee)
    {
        IMemeverseLauncher.Memeverse memory verse = IMemeverseLauncher(PROXY).getMemeverseByVerseId(verseId);
        require(verse.memecoin != address(0), IMemeverseLauncher.InvalidVerseId());
        require(verse.currentStage >= IMemeverseLauncher.Stage.Locked, IMemeverseLauncher.NotReachedLockedStage());

        (memecoinFee, uAssetFee) = _previewPairFees(verse.memecoin, verse.uAsset);
        address _polSplitter = IMemeverseLauncher(PROXY).getLauncherContracts().polSplitter;
        address pt = IPOLSplitter(_polSplitter).getPT(verseId);
        (uint256 govUAssetFee, uint256 govPTFee) = _previewGovFeeWithPending(verseId, verse, pt);
        uAssetFee += govUAssetFee + govPTFee;
    }

    /// @inheritdoc IMemeverseFeePreviewReader
    function quoteDistributionLzFee(uint256 verseId) external view override returns (uint256 lzFee) {
        IMemeverseLauncher.Memeverse memory verse = IMemeverseLauncher(PROXY).getMemeverseByVerseId(verseId);
        require(verse.memecoin != address(0), IMemeverseLauncher.InvalidVerseId());
        require(verse.currentStage >= IMemeverseLauncher.Stage.Locked, IMemeverseLauncher.NotReachedLockedStage());
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;

        address uAsset = verse.uAsset;
        (uint256 memecoinFee, uint256 mainUAssetFee) = _previewPairFees(verse.memecoin, uAsset);
        (uint256 govFee,) = _splitExecutorReward(mainUAssetFee);

        IMemeverseLauncher.LauncherContracts memory contracts = IMemeverseLauncher(PROXY).getLauncherContracts();
        address _polSplitter = contracts.polSplitter;
        address pt = IPOLSplitter(_polSplitter).getPT(verseId);
        (uint256 govUAssetFee, uint256 govPTFee) = _previewGovFeeWithPending(verseId, verse, pt);
        govFee += govUAssetFee + govPTFee;

        uint32 govEndpointId = ILzEndpointRegistry(contracts.lzEndpointRegistry).lzEndpointIdOfChain(govChainId);
        IMemeverseLauncher.LauncherParameters memory parameters = IMemeverseLauncher(PROXY).getLauncherParameters();
        bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(parameters.oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, parameters.yieldDispatcherGasLimit, 0);

        if (govFee != 0) {
            (, MessagingFee memory govMessagingFee) = _buildSendParamAndMessagingFee(
                govEndpointId,
                govFee,
                uAsset,
                verse.governor,
                IMemeverseOFTEnum.TokenType.UASSET,
                yieldDispatcherOptions,
                contracts.yieldDispatcher
            );
            lzFee += govMessagingFee.nativeFee;
        }

        if (memecoinFee != 0) {
            (, MessagingFee memory memecoinMessagingFee) = _buildSendParamAndMessagingFee(
                govEndpointId,
                memecoinFee,
                verse.memecoin,
                verse.yieldVault,
                IMemeverseOFTEnum.TokenType.MEMECOIN,
                yieldDispatcherOptions,
                contracts.yieldDispatcher
            );
            lzFee += memecoinMessagingFee.nativeFee;
        }
    }

    function _previewGovFeeWithPending(uint256 verseId, IMemeverseLauncher.Memeverse memory verse, address pt)
        internal
        view
        returns (uint256 govUAssetFee, uint256 govPTFee)
    {
        (uint256 pendingUAssetFee, uint256 pendingPTFee) =
            IMemeverseLauncher(PROXY).pendingAuxiliaryGovFeeStates(verseId);

        // Preview live auxiliary fees from POL/uAsset and PT/uAsset pools
        (uint256 auxUAssetFee, uint256 auxPTFee) = _previewAuxiliaryGovFees(verseId, verse, pt);

        // Merge pending accumulated fees with live preview
        govUAssetFee = pendingUAssetFee + auxUAssetFee;
        govPTFee = pendingPTFee + auxPTFee;

        // Convert PT-denominated fee to uAsset so the caller can add it directly
        if (govPTFee != 0) {
            govPTFee = IPOLSplitter(IMemeverseLauncher(PROXY).getLauncherContracts().polSplitter)
                .previewPTToUAsset(verseId, govPTFee);
        }
    }

    function _previewAuxiliaryGovFees(uint256 verseId, IMemeverseLauncher.Memeverse memory verse, address pt)
        internal
        view
        returns (uint256 govUAssetFee, uint256 govPTFee)
    {
        (, uint256 polUAssetUAssetFee) = _previewPairFees(verse.pol, verse.uAsset);
        uint256 totalAuxiliaryUAssetFee = polUAssetUAssetFee;
        uint256 totalPTFee;

        if (pt != address(0)) {
            (uint256 ptUAssetPTFee, uint256 ptUAssetUAssetFee) = _previewPairFees(pt, verse.uAsset);
            (uint256 ptPolPTFee,) = _previewPairFees(pt, verse.pol);
            totalAuxiliaryUAssetFee += ptUAssetUAssetFee;
            totalPTFee = ptUAssetPTFee + ptPolPTFee;
        }

        return _splitAuxiliaryGovFees(
            verseId, totalAuxiliaryUAssetFee, totalPTFee, verse.currentStage == IMemeverseLauncher.Stage.Locked
        );
    }

    // Shared via MemeverseLauncherLib.splitAuxiliaryGovFees; the settlement impl uses the same lib helper, so
    // the two callers cannot drift on the split formula (only their input fetch differs: proxy getter vs storage).
    function _splitAuxiliaryGovFees(
        uint256 verseId,
        uint256 totalUAssetFee,
        uint256 totalPTFee,
        bool preserveNormalShare
    ) internal view returns (uint256 govUAssetFee, uint256 govPTFee) {
        // GR-001: short-circuit before the proxy SLOAD + external getTotalLeveragedDebt fetch on the
        // Unlocked-stage path (preserveNormalShare == false). Mirrors the lib helper's own first-line guard;
        // restoring pre-refactor gas. Same return values; only skips the wasted fetch on the false branch.
        if (!preserveNormalShare) return (totalUAssetFee, totalPTFee);
        uint256 normalFunds = IMemeverseLauncher(PROXY).totalNormalFunds(verseId);
        uint256 totalLeveragedDebt = IPOLend(IMemeverseLauncher(PROXY).polend()).getTotalLeveragedDebt(verseId);
        return MemeverseLauncherLib.splitAuxiliaryGovFees(
            normalFunds, totalLeveragedDebt, totalUAssetFee, totalPTFee, preserveNormalShare
        );
    }

    function _previewPairFees(address tokenA, address tokenB)
        internal
        view
        returns (uint256 tokenAFee, uint256 tokenBFee)
    {
        address swapRouter = IMemeverseLauncher(PROXY).getLauncherContracts().memeverseSwapRouter;
        (uint256 fee0, uint256 fee1) = IMemeverseSwapRouter(swapRouter).previewClaimableFees(tokenA, tokenB, PROXY);
        return _mapPairFees(tokenA, tokenB, fee0, fee1);
    }

    // Shared via MemeverseLauncherLib.mapPairFees; the distributor uses the same lib helper.
    function _mapPairFees(address tokenA, address tokenB, uint256 fee0, uint256 fee1)
        internal
        pure
        returns (uint256 tokenAFee, uint256 tokenBFee)
    {
        return MemeverseLauncherLib.mapPairFees(tokenA, tokenB, fee0, fee1);
    }

    // Shared via MemeverseLauncherLib.splitExecutorReward; the distributor uses the same lib helper.
    function _splitExecutorReward(uint256 uAssetFee) internal view returns (uint256 govFee, uint256 executorReward) {
        return MemeverseLauncherLib.splitExecutorReward(
            uAssetFee, IMemeverseLauncher(PROXY).getLauncherParameters().executorRewardRate
        );
    }

    // Shared via MemeverseLauncherLib.buildSendParamAndMessagingFee; the distributor uses the same lib helper.
    function _buildSendParamAndMessagingFee(
        uint32 govEndpointId,
        uint256 amount,
        address token,
        address receiver,
        IMemeverseOFTEnum.TokenType tokenType,
        bytes memory yieldDispatcherOptions,
        address yieldDispatcher
    ) internal view returns (SendParam memory sendParam, MessagingFee memory messagingFee) {
        return MemeverseLauncherLib.buildSendParamAndMessagingFee(
                govEndpointId, amount, token, receiver, tokenType, yieldDispatcherOptions, yieldDispatcher
            );
    }
}
