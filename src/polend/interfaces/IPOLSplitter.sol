// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IPOLSplitter {
    struct SplitInfo {
        address pt;
        address yt;
        address pol;
        address memecoin;
        address uAsset;
        uint256 totalPOLCollateral;
        uint256 settlementUAsset;
        uint256 settlementMemecoin;
        uint256 ptBackingNumerator;
        uint256 ptBackingDenominator;
        bool settled;
    }

    struct PreRedeemedState {
        uint256 ptAmount;
        uint256 uAssetBacking;
    }

    error AlreadyUnlocked();
    error AlreadySettled();
    error AlreadyDeployed();
    error NotUnlocked();
    error NotSettled();
    error PermissionDenied();
    error ZeroInput();
    error InvalidClaim();

    event RedeemPT(uint256 indexed verseId, address indexed from, address indexed to, uint256 ptAmount);
    event RedeemYT(
        uint256 indexed verseId,
        address indexed from,
        address indexed to,
        uint256 ytAmount,
        uint256 uAssetAmount,
        uint256 memecoinAmount
    );

    function splitInfos(uint256 verseId)
        external
        view
        returns (
            address pt,
            address yt,
            address pol,
            address memecoin,
            address uAsset,
            uint256 totalPOLCollateral,
            uint256 settlementUAsset,
            uint256 settlementMemecoin,
            uint256 ptBackingNumerator,
            uint256 ptBackingDenominator,
            bool settled
        );

    function preRedeemedStates(uint256 verseId) external view returns (uint256 ptAmount, uint256 uAssetBacking);

    function ptBackingRatios(uint256 verseId) external view returns (uint256 numerator, uint256 denominator);

    function getPT(uint256 verseId) external view returns (address pt);

    function getYT(uint256 verseId) external view returns (address yt);

    function getMemecoin(uint256 verseId) external view returns (address memecoin);

    function getPTAndYT(uint256 verseId) external view returns (address pt, address yt);

    function getPTAndYTAndPOL(uint256 verseId) external view returns (address pt, address yt, address pol);

    function getPTSettlementState(uint256 verseId) external view returns (address pt, bool settled);

    function getPOLAndMemecoin(uint256 verseId) external view returns (address pol, address memecoin);

    function polend() external view returns (address);

    function launcher() external view returns (address);

    function initializeVerse(
        uint256 verseId,
        address pol,
        address memecoin,
        address uAsset,
        string calldata name,
        string calldata symbol
    ) external returns (address pt, address yt);

    function split(uint256 verseId, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount);

    function merge(uint256 verseId, uint256 amount) external returns (uint256 polAmount);

    function settle(uint256 verseId) external returns (uint256 settlementUAsset, uint256 settlementMemecoin);

    function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external;

    function previewPTToUAsset(uint256 verseId, uint256 ptAmount) external view returns (uint256 uAssetAmount);

    function preRedeemPTFee(uint256 verseId, uint256 ptAmount) external returns (uint256 uAssetBacking);

    function redeemPT(uint256 verseId, uint256 ptAmount, address to) external returns (uint256 uAssetAmount);

    function redeemYT(uint256 verseId, uint256 ytAmount, address to)
        external
        returns (uint256 uAssetAmount, uint256 memecoinAmount);

    function previewRedeemYTUAsset(uint256 verseId, uint256 ytAmount) external view returns (uint256 uAssetAmount);
}
