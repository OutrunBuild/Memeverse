// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";

import {MockPOL} from "./MockPOL.sol";

/// @notice Launcher and splitter dependency mocks shared by the POLendUpgradeable and
///         POLSplitterUpgradeable unit suites. The splitter-side launcher is suffixed
///         `ForPOLSplitter` to stay distinct from the swap-side `MockLauncher`
///         (test/mocks/swap/YTFlashSwapMocks.sol).
contract MockLauncherForPOLend {
    mapping(uint256 verseId => uint256 totalNormalFunds) internal normalFunds;
    mapping(uint256 verseId => uint256 polSettlementAmount) internal polSettlementAmounts;
    mapping(uint256 verseId => uint256 ptSettlementAmount) internal ptSettlementAmounts;
    mapping(uint256 verseId => uint256 uAssetSettlementAmount) internal uAssetSettlementAmounts;
    mapping(uint256 verseId => IMemeverseLauncher.Memeverse) internal verses;
    mapping(address uAsset => IMemeverseLauncher.FundMetaData) internal fundMetaDatas_;
    bool internal legacyDebtCapReadsRevert;

    function setGenesisFunds(uint256 verseId, uint256 totalNormalFunds_) external {
        normalFunds[verseId] = totalNormalFunds_;
    }

    function setSettlementResult(uint256 verseId, uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount) external {
        polSettlementAmounts[verseId] = polAmount;
        ptSettlementAmounts[verseId] = ptAmount;
        uAssetSettlementAmounts[verseId] = uAssetAmount;
    }

    function setVerseUAsset(uint256 verseId, address uAsset) external {
        verses[verseId].uAsset = uAsset;
    }

    function setVerseStage(uint256 verseId, IMemeverseLauncher.Stage stage) external {
        verses[verseId].currentStage = stage;
    }

    function setFundMetaData(address uAsset, uint256 minTotalFund, uint256 fundBasedAmount) external {
        fundMetaDatas_[uAsset] =
            IMemeverseLauncher.FundMetaData({minTotalFund: minTotalFund, fundBasedAmount: fundBasedAmount});
    }

    function setLegacyDebtCapReadsRevert(bool revertReads) external {
        legacyDebtCapReadsRevert = revertReads;
    }

    function totalNormalFunds(uint256 verseId) external view returns (uint256) {
        if (legacyDebtCapReadsRevert) revert("legacy debt cap read");
        return normalFunds[verseId];
    }

    function getMemeverseByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Memeverse memory verse) {
        return verses[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return verses[verseId].uAsset;
    }

    function getStageByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Stage stage) {
        return verses[verseId].currentStage;
    }

    function fundMetaDatas(address uAsset) external view returns (uint256 minTotalFund, uint256 fundBasedAmount) {
        if (legacyDebtCapReadsRevert) revert("legacy debt cap read");
        IMemeverseLauncher.FundMetaData memory metadata = fundMetaDatas_[uAsset];
        return (metadata.minTotalFund, metadata.fundBasedAmount);
    }

    function getDebtCapBaseByVerseId(uint256 verseId) external view returns (uint256 debtCapBase) {
        address uAsset = verses[verseId].uAsset;
        uint256 minTotalFund = fundMetaDatas_[uAsset].minTotalFund;
        uint256 totalNormalFunds_ = normalFunds[verseId];
        return totalNormalFunds_ > minTotalFund ? totalNormalFunds_ : minTotalFund;
    }

    function remainingGenesisCapacity(uint256 verseId) external view returns (uint256 remaining) {
        uint256 totalFunds = normalFunds[verseId];
        if (totalFunds >= type(uint128).max) return 0;
        return type(uint128).max - totalFunds;
    }

    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        view
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        return (polSettlementAmounts[verseId], ptSettlementAmounts[verseId], uAssetSettlementAmounts[verseId]);
    }

    function redeemMemecoinLiquidity(uint256, uint256, bool, uint256, uint256, uint256)
        external
        pure
        returns (uint256)
    {
        revert("unused");
    }
}

contract MockSplitterForPOLend {
    address internal pt;
    address internal yt;
    address internal pol;
    address internal memecoin;
    address internal uAsset;
    uint256 internal redeemPTAmount;
    uint256 public deployTokensCallCount;
    uint256 public initializeVerseCallCount;
    uint256 public preRedeemCallCount;
    uint256 public lastPreRedeemVerseId;
    uint256 public lastPreRedeemPTAmount;
    uint256 public preRedeemBacking = 25 ether;

    function setTokens(address pt_, address yt_) external {
        pt = pt_;
        yt = yt_;
    }

    function setSplitInfo(address pol_, address memecoin_, address uAsset_) external {
        pol = pol_;
        memecoin = memecoin_;
        uAsset = uAsset_;
    }

    function setRedeemPTAmount(uint256 amount) external {
        redeemPTAmount = amount;
    }

    function deployTokens(uint256, address, string calldata, string calldata) external returns (address, address) {
        deployTokensCallCount++;
        return (pt, yt);
    }

    function initializeVerse(uint256, address, address, address, string calldata, string calldata)
        external
        returns (address, address)
    {
        initializeVerseCallCount++;
        return (pt, yt);
    }

    function redeemPT(uint256, uint256, address) external view returns (uint256) {
        return redeemPTAmount;
    }

    function setPreRedeemBacking(uint256 backing) external {
        preRedeemBacking = backing;
    }

    function preRedeemPTFee(uint256 verseId, uint256 ptAmount) external returns (uint256 uAssetBacking) {
        preRedeemCallCount++;
        lastPreRedeemVerseId = verseId;
        lastPreRedeemPTAmount = ptAmount;
        return preRedeemBacking;
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, pol, memecoin, uAsset, 0, 0, 0, 0, 0, false);
    }

    function getPT(uint256) external view returns (address) {
        return pt;
    }

    function getYT(uint256) external view returns (address) {
        return yt;
    }

    function getMemecoin(uint256) external view returns (address) {
        return memecoin;
    }

    function getPTAndYT(uint256) external view returns (address, address) {
        return (pt, yt);
    }

    function getPTSettlementState(uint256) external view returns (address, bool) {
        return (pt, false);
    }

    function getPOLAndMemecoin(uint256) external view returns (address, address) {
        return (pol, memecoin);
    }
}

contract MockLauncherForPOLSplitter {
    // Boundary note:
    // This mock only drives launcher stage and unwrap selector wiring for POLSplitterUpgradeable unit tests.
    // It does not prove real launcher/router asset-flow semantics.
    struct RedemptionSeed {
        uint256 uAssetAmount;
        uint256 memecoinAmount;
    }

    mapping(uint256 verseId => IMemeverseLauncher.Stage) internal stages;
    mapping(uint256 verseId => address) internal polTokens;
    mapping(uint256 verseId => RedemptionSeed) internal redemptionSeeds;
    mapping(uint256 verseId => IMemeverseLauncher.Memeverse) internal verses;
    address internal polendAddress;

    MockERC20 internal immutable uAsset;
    MockERC20 internal immutable memecoin;

    constructor(MockERC20 uAsset_, MockERC20 memecoin_) {
        uAsset = uAsset_;
        memecoin = memecoin_;
    }

    function setStage(uint256 verseId, IMemeverseLauncher.Stage stage) external {
        stages[verseId] = stage;
    }

    function registerPol(uint256 verseId, address pol) external {
        polTokens[verseId] = pol;
    }

    function setVerseUAsset(uint256 verseId, address uAsset_) external {
        verses[verseId].uAsset = uAsset_;
    }

    function seedRedemption(uint256 verseId, uint256 uAssetAmount, uint256 memecoinAmount) external {
        redemptionSeeds[verseId] = RedemptionSeed({uAssetAmount: uAssetAmount, memecoinAmount: memecoinAmount});
    }

    function setPolend(address polend_) external {
        polendAddress = polend_;
    }

    function getStageByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Stage) {
        return stages[verseId];
    }

    function getMemeverseByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Memeverse memory verse) {
        return verses[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return verses[verseId].uAsset;
    }

    function polend() external view returns (address) {
        return polendAddress;
    }

    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool, uint256, uint256, uint256)
        external
        returns (uint256 amountInLP)
    {
        require(MockPOL(polTokens[verseId]).transferFrom(msg.sender, address(this), amountInPOL), "transfer failed");

        RedemptionSeed memory seed = redemptionSeeds[verseId];
        if (seed.uAssetAmount != 0) uAsset.mint(msg.sender, seed.uAssetAmount);
        if (seed.memecoinAmount != 0) memecoin.mint(msg.sender, seed.memecoinAmount);
        return amountInPOL;
    }
}
