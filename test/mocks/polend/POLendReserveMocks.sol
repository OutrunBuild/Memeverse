// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";

/// @notice Minimal launcher mock for POLend settlement-reserve / credit-path tests.
/// @dev Mirrors the subset of MockLauncherForPOLend (test/polend/POLend.t.sol) that the exercised
///      POLend paths call, with the settlement callback result made configurable per verse. Kept in
///      test/mocks/ per the test-code conventions.
contract SettlementResultLauncher {
    mapping(uint256 verseId => address uAsset) internal verseUAssets;
    mapping(uint256 verseId => IMemeverseLauncher.Stage) internal verseStages;
    mapping(uint256 verseId => uint256 normalFunds) internal genesisFunds;
    mapping(address uAsset => IMemeverseLauncher.FundMetaData) internal fundMetaData;
    mapping(uint256 verseId => uint256 recoveredUAsset) internal settlementRecovered;

    function setVerseUAsset(uint256 verseId, address uAsset) external {
        verseUAssets[verseId] = uAsset;
    }

    function setVerseStage(uint256 verseId, IMemeverseLauncher.Stage stage) external {
        verseStages[verseId] = stage;
    }

    function setGenesisFunds(uint256 verseId, uint256 normalFunds) external {
        genesisFunds[verseId] = normalFunds;
    }

    function setFundMetaData(address uAsset, uint256 minTotalFund, uint256 fundBasedAmount) external {
        fundMetaData[uAsset] =
            IMemeverseLauncher.FundMetaData({minTotalFund: minTotalFund, fundBasedAmount: fundBasedAmount});
    }

    /// @notice Configures what `settleLeveragedAuxiliaryLiquidity` reports for a verse: POL legs are
    ///         always zero in these tests, only the recovered uAsset amount matters.
    function setSettlementResult(uint256 verseId, uint256 recoveredUAsset) external {
        settlementRecovered[verseId] = recoveredUAsset;
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return verseUAssets[verseId];
    }

    function getStageByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Stage) {
        return verseStages[verseId];
    }

    function totalNormalFunds(uint256 verseId) external view returns (uint256) {
        return genesisFunds[verseId];
    }

    function getDebtCapBaseByVerseId(uint256 verseId) external view returns (uint256 debtCapBase) {
        address uAsset = verseUAssets[verseId];
        uint256 minTotalFund = fundMetaData[uAsset].minTotalFund;
        uint256 normalFunds = genesisFunds[verseId];
        return normalFunds > minTotalFund ? normalFunds : minTotalFund;
    }

    function fundMetaDatas(address uAsset) external view returns (uint256 minTotalFund, uint256 fundBasedAmount) {
        IMemeverseLauncher.FundMetaData memory metadata = fundMetaData[uAsset];
        return (metadata.minTotalFund, metadata.fundBasedAmount);
    }

    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        view
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        return (0, 0, settlementRecovered[verseId]);
    }
}
