// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "../common/token/OutrunERC20Init.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {ReentrancyGuard} from "../common/access/ReentrancyGuard.sol";
import {IPOLend} from "./interfaces/IPOLend.sol";
import {IPOLSplitter} from "./interfaces/IPOLSplitter.sol";
import {PrincipalToken} from "./tokens/PrincipalToken.sol";
import {YieldToken} from "./tokens/YieldToken.sol";
import {IMemeverseLauncher} from "../verse/interfaces/IMemeverseLauncher.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";

/// @title POLSplitter
/// @notice Splits a verse's POL collateral into equal amounts of PrincipalToken (PT) and
///         YieldToken (YT), then after the verse settles redeems the collateral through the
///         launcher and distributes the recovered uAsset and memecoin to PT/YT holders.
///         PT (principal token) claims the fixed uAsset backing; YT (yield token) claims the
///         uAsset left after PT coverage plus all recovered memecoin — see `redeemPT`/`redeemYT`.
///         Access model: the launcher deploys verses and settles them (onlyLauncher); POLend
///         pre-redeems the PT fee for leveraged positions (onlyPOLend).
contract POLSplitter layout at erc7201("outrun.storage.POLSplitter")
    is
    Initializable,
    OutrunOwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IPOLSplitter
{
    using OutrunSafeERC20 for IERC20;
    using Clones for address;

    /// @custom:storage-location erc7201:outrun.storage.POLSplitter
    struct POLSplitterStorage {
        mapping(uint256 verseId => SplitInfo) splitInfos;
        mapping(uint256 verseId => PreRedeemedState state) preRedeemedStates;
        address launcher;
        address polend;
        address principalTokenImplementation;
        address yieldTokenImplementation;
    }

    POLSplitterStorage private polSplitterStorage;

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
        )
    {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        pt = info.pt;
        yt = info.yt;
        pol = info.pol;
        memecoin = info.memecoin;
        uAsset = info.uAsset;
        totalPOLCollateral = info.totalPOLCollateral;
        settlementUAsset = info.settlementUAsset;
        settlementMemecoin = info.settlementMemecoin;
        ptBackingNumerator = info.ptBackingNumerator;
        ptBackingDenominator = info.ptBackingDenominator;
        settled = info.settled;
    }

    function preRedeemedStates(uint256 verseId) external view returns (uint256 ptAmount, uint256 uAssetBacking) {
        PreRedeemedState storage state = polSplitterStorage.preRedeemedStates[verseId];
        return (state.ptAmount, state.uAssetBacking);
    }

    function ptBackingRatios(uint256 verseId) external view returns (uint256 numerator, uint256 denominator) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        return (info.ptBackingNumerator, info.ptBackingDenominator);
    }

    function getPT(uint256 verseId) external view returns (address pt) {
        pt = polSplitterStorage.splitInfos[verseId].pt;
    }

    function getYT(uint256 verseId) external view returns (address yt) {
        yt = polSplitterStorage.splitInfos[verseId].yt;
    }

    function getMemecoin(uint256 verseId) external view returns (address memecoin) {
        memecoin = polSplitterStorage.splitInfos[verseId].memecoin;
    }

    function getPTAndYT(uint256 verseId) external view returns (address pt, address yt) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        pt = info.pt;
        yt = info.yt;
    }

    function getPTAndYTAndPOL(uint256 verseId) external view returns (address pt, address yt, address pol) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        pt = info.pt;
        yt = info.yt;
        pol = info.pol;
    }

    function getPTSettlementState(uint256 verseId) external view returns (address pt, bool settled) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        pt = info.pt;
        settled = info.settled;
    }

    function getPOLAndMemecoin(uint256 verseId) external view returns (address pol, address memecoin) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        pol = info.pol;
        memecoin = info.memecoin;
    }

    function launcher() external view returns (address) {
        return polSplitterStorage.launcher;
    }

    function polend() external view returns (address) {
        return polSplitterStorage.polend;
    }

    function principalTokenImplementation() external view returns (address) {
        return polSplitterStorage.principalTokenImplementation;
    }

    function yieldTokenImplementation() external view returns (address) {
        return polSplitterStorage.yieldTokenImplementation;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyLauncher() {
        if (msg.sender != polSplitterStorage.launcher) revert PermissionDenied();
        _;
    }

    modifier onlyPOLend() {
        if (msg.sender != polSplitterStorage.polend) revert PermissionDenied();
        _;
    }

    /// @notice One-time proxy initializer. Sets the owner, resolves the launcher and POLend
    ///         pointers, and deploys the PT/YT clone implementations used by `initializeVerse`.
    /// @dev Deployment-order dependency: `_launcher` must already be deployed with its `polend()`
    ///      pointer set — the POLend address is read from the launcher here, not passed in.
    function initialize(address initialOwner, address _launcher) external initializer {
        if (_launcher == address(0)) revert ZeroInput();

        __OutrunOwnable_init(initialOwner);

        polSplitterStorage.launcher = _launcher;
        polSplitterStorage.polend = IMemeverseLauncher(_launcher).polend();
        polSplitterStorage.principalTokenImplementation = address(new PrincipalToken());
        polSplitterStorage.yieldTokenImplementation = address(new YieldToken());
    }

    function initializeVerse(
        uint256 verseId,
        address pol,
        address memecoin,
        address uAsset,
        string calldata name,
        string calldata symbol
    ) external onlyLauncher returns (address pt, address yt) {
        if (polSplitterStorage.splitInfos[verseId].pt != address(0)) revert AlreadyDeployed();

        pt = polSplitterStorage.principalTokenImplementation.cloneDeterministic(bytes32(verseId));
        yt = polSplitterStorage.yieldTokenImplementation.cloneDeterministic(bytes32(verseId));

        PrincipalToken(pt).initialize(string.concat("PT-", name), string.concat("PT-", symbol), address(this));
        YieldToken(yt).initialize(string.concat("YT-", name), string.concat("YT-", symbol), address(this));

        polSplitterStorage.splitInfos[verseId] = SplitInfo({
            pt: pt,
            yt: yt,
            pol: pol,
            memecoin: memecoin,
            uAsset: uAsset,
            totalPOLCollateral: 0,
            settlementUAsset: 0,
            settlementMemecoin: 0,
            ptBackingNumerator: 0,
            ptBackingDenominator: 0,
            settled: false
        });
        emit VerseInitialized(verseId, pt, yt);

        return (pt, yt);
    }

    function split(uint256 verseId, uint256 polAmount)
        external
        nonReentrant
        returns (uint256 ptAmount, uint256 ytAmount)
    {
        if (polAmount == 0) revert ZeroInput();
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (_isUnlocked(verseId) || info.settled) revert AlreadyUnlocked();
        _requirePTBackingRatio(info);

        IERC20(info.pol).safeTransferFrom(msg.sender, address(this), polAmount);
        info.totalPOLCollateral += polAmount;
        PrincipalToken(info.pt).mint(msg.sender, polAmount);
        YieldToken(info.yt).mint(msg.sender, polAmount);
        emit Split(verseId, msg.sender, polAmount, polAmount, polAmount);

        return (polAmount, polAmount);
    }

    function merge(uint256 verseId, uint256 amount) external nonReentrant returns (uint256 polAmount) {
        if (amount == 0) revert ZeroInput();
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (_isUnlocked(verseId) || info.settled) revert AlreadyUnlocked();
        _requirePTBackingRatio(info);

        info.totalPOLCollateral -= amount;
        PrincipalToken(info.pt).burn(msg.sender, amount);
        YieldToken(info.yt).burn(msg.sender, amount);
        IERC20(info.pol).safeTransfer(msg.sender, amount);
        emit Merge(verseId, msg.sender, amount, amount);

        return amount;
    }

    function settle(uint256 verseId)
        external
        onlyLauncher
        returns (uint256 settlementUAsset, uint256 settlementMemecoin)
    {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (info.settled) revert AlreadySettled();
        if (!_isUnlocked(verseId)) revert NotUnlocked();

        // Effects: set re-entry guard before external calls
        info.settled = true;

        // Interactions
        (settlementUAsset, settlementMemecoin) = _settlePOLCollateral(verseId, info);
        // `preRedeemPTFee` (called earlier from the launcher) already minted uAsset backing for a
        // PT-fee portion and recorded it here; that backing is not part of the PT-holder redemption
        // pool, so deduct it before checking PT coverage and burn it back to POLend below.
        PreRedeemedState storage state = polSplitterStorage.preRedeemedStates[verseId];
        uint256 preRedeemedUAssetBacking = state.uAssetBacking;
        if (settlementUAsset < preRedeemedUAssetBacking) revert InvalidClaim();
        settlementUAsset -= preRedeemedUAssetBacking;
        // PT-solvency invariant: the remaining settlement uAsset must cover every outstanding PT
        // (total supply) at the recorded backing ratio, so all PT holders can always redeem in full.
        if (settlementUAsset < _ptReservedUAsset(info)) revert InvalidClaim();
        // Reverse the earlier `preRedeemPTFee` accrual: repay the pre-redeemed uAsset to POLend so
        // its global debt ledger stays consistent, then clear the pre-redeemed record.
        if (preRedeemedUAssetBacking != 0) {
            address _polend = polSplitterStorage.polend;
            IERC20(info.uAsset).approve(_polend, preRedeemedUAssetBacking);
            IPOLend(_polend).burnPreRedeemedBacking(verseId, preRedeemedUAssetBacking);
            delete polSplitterStorage.preRedeemedStates[verseId];
        }

        // Effects: write post-interaction state
        info.totalPOLCollateral = 0;
        info.settlementUAsset = settlementUAsset;
        info.settlementMemecoin = settlementMemecoin;
        emit VerseSettled(verseId, settlementUAsset, settlementMemecoin);
    }

    function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external onlyLauncher {
        if (numerator == 0 || denominator == 0) revert ZeroInput();

        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (info.pt == address(0)) revert InvalidClaim();
        if (info.settled) revert AlreadySettled();
        if (info.totalPOLCollateral != 0) revert InvalidClaim();
        if (info.ptBackingNumerator != 0 || info.ptBackingDenominator != 0) revert InvalidClaim();

        info.ptBackingNumerator = numerator;
        info.ptBackingDenominator = denominator;
        emit BackingRatioRecorded(verseId, numerator, denominator);
    }

    function previewPTToUAsset(uint256 verseId, uint256 ptAmount) external view returns (uint256 uAssetAmount) {
        if (ptAmount == 0) return 0;
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        return _ptToUAsset(info, ptAmount);
    }

    /// @notice Pre-redeem a PT-fee amount by burning PT held by the launcher (onlyPOLend). Called
    ///         by POLend's `preRedeemPTFee` while the verse is Locked: POLend mints the uAsset
    ///         backing to the caller-chosen `mintTo` (governance fee sink) and records the amount
    ///         here in `preRedeemedStates`; `settle` later repays that amount to POLend out of the
    ///         settled uAsset, so the PT-holder redemption pool excludes the pre-redeemed portion.
    /// @dev Precondition: the launcher must hold at least `ptAmount` PT — the burn target is
    ///      always `polSplitterStorage.launcher`, so a missing balance reverts silently here.
    ///      The backing uAsset itself is minted by POLend to `mintTo`, not to this contract.
    function preRedeemPTFee(uint256 verseId, uint256 ptAmount) external onlyPOLend returns (uint256 uAssetBacking) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (info.settled) revert AlreadySettled();

        uAssetBacking = _ptToUAsset(info, ptAmount);
        if (uAssetBacking == 0) revert InvalidClaim();
        PrincipalToken(info.pt).burn(polSplitterStorage.launcher, ptAmount);
        PreRedeemedState storage state = polSplitterStorage.preRedeemedStates[verseId];
        state.ptAmount += ptAmount;
        state.uAssetBacking += uAssetBacking;
    }

    function redeemPT(uint256 verseId, uint256 ptAmount, address to)
        external
        nonReentrant
        returns (uint256 uAssetAmount)
    {
        if (ptAmount == 0) revert ZeroInput();
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (!info.settled) revert NotSettled();
        if (to == address(0)) revert ZeroInput();
        uAssetAmount = _ptToUAsset(info, ptAmount);
        if (uAssetAmount == 0) revert InvalidClaim();
        uint256 settlementUAsset = info.settlementUAsset;
        if (settlementUAsset < uAssetAmount) revert InvalidClaim();

        PrincipalToken(info.pt).burn(msg.sender, ptAmount);
        info.settlementUAsset = settlementUAsset - uAssetAmount;
        IERC20(info.uAsset).safeTransfer(to, uAssetAmount);
        emit RedeemPT(verseId, msg.sender, to, ptAmount);

        return uAssetAmount;
    }

    function redeemYT(uint256 verseId, uint256 ytAmount, address to)
        external
        nonReentrant
        returns (uint256 uAssetAmount, uint256 memecoinAmount)
    {
        if (ytAmount == 0) revert ZeroInput();
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        if (!info.settled) revert NotSettled();
        if (to == address(0)) revert ZeroInput();

        uint256 outstandingYT = IERC20(info.yt).totalSupply();
        if (outstandingYT == 0) revert InvalidClaim();
        uint256 ytRedeemableUAssetPool = _ytRedeemableUAssetPool(info);

        uAssetAmount = Math.mulDiv(ytRedeemableUAssetPool, ytAmount, outstandingYT);
        memecoinAmount = Math.mulDiv(info.settlementMemecoin, ytAmount, outstandingYT);
        if (uAssetAmount == 0 && memecoinAmount == 0) revert InvalidClaim();

        YieldToken(info.yt).burn(msg.sender, ytAmount);
        info.settlementUAsset -= uAssetAmount;
        info.settlementMemecoin -= memecoinAmount;

        IERC20(info.uAsset).safeTransfer(to, uAssetAmount);
        IERC20(info.memecoin).safeTransfer(to, memecoinAmount);
        emit RedeemYT(verseId, msg.sender, to, ytAmount, uAssetAmount, memecoinAmount);
    }

    function previewRedeemYTUAsset(uint256 verseId, uint256 ytAmount) external view returns (uint256 uAssetAmount) {
        SplitInfo storage info = polSplitterStorage.splitInfos[verseId];
        uint256 outstandingYT = IERC20(info.yt).totalSupply();
        if (outstandingYT == 0) return 0;

        uint256 ytRedeemableUAssetPool = _ytRedeemableUAssetPool(info);
        return Math.mulDiv(ytRedeemableUAssetPool, ytAmount, outstandingYT);
    }

    function _isUnlocked(uint256 verseId) internal view returns (bool) {
        return
            IMemeverseLauncher(polSplitterStorage.launcher).getStageByVerseId(verseId)
                == IMemeverseLauncher.Stage.Unlocked;
    }

    /// Redeems the verse's POL collateral through the launcher and measures the recovered uAsset
    /// and memecoin by balance delta: `redeemMemecoinLiquidity` returns the burned LP amount, not
    /// the recovered tokens, so the before/after balance diff is the only reliable measurement.
    /// Precondition: this splitter must already hold the POL collateral (transferred in by `split`).
    function _settlePOLCollateral(uint256 verseId, SplitInfo storage info)
        internal
        returns (uint256 settlementUAsset, uint256 settlementMemecoin)
    {
        uint256 polAmount = info.totalPOLCollateral;
        address memecoin = info.memecoin;
        uint256 beforeUAsset = IERC20(info.uAsset).balanceOf(address(this));
        uint256 beforeMemecoin = IERC20(memecoin).balanceOf(address(this));

        IERC20(info.pol).approve(polSplitterStorage.launcher, polAmount);
        IMemeverseLauncher(polSplitterStorage.launcher).redeemMemecoinLiquidity(verseId, polAmount, true);

        settlementUAsset = IERC20(info.uAsset).balanceOf(address(this)) - beforeUAsset;
        settlementMemecoin = IERC20(memecoin).balanceOf(address(this)) - beforeMemecoin;
    }

    function _ptToUAsset(SplitInfo storage info, uint256 ptAmount) internal view returns (uint256 uAssetAmount) {
        uint256 numerator = info.ptBackingNumerator;
        uint256 denominator = info.ptBackingDenominator;
        if (numerator == 0 || denominator == 0) revert InvalidClaim();
        return FullMath.mulDiv(ptAmount, numerator, denominator);
    }

    /// @notice uAsset reserved for all outstanding PT at the recorded backing ratio
    ///         (`reservedUAssetForPT` in spec §3.2). Reverts InvalidClaim if the ratio is unset.
    function _ptReservedUAsset(SplitInfo storage info) internal view returns (uint256) {
        return _ptToUAsset(info, IERC20(info.pt).totalSupply());
    }

    /// @notice YT-redeemable uAsset pool = settlement uAsset minus the PT reserve (spec §3.2).
    ///         `settle` guarantees the settlement uAsset covers the PT reserve, so the
    ///         subtraction cannot underflow on the redemption path (settled verses);
    ///         InvalidClaim / panic are defensive — e.g. `previewRedeemYTUAsset` before
    ///         settlement hits the panic.
    function _ytRedeemableUAssetPool(SplitInfo storage info) internal view returns (uint256) {
        return info.settlementUAsset - _ptReservedUAsset(info);
    }

    function _requirePTBackingRatio(SplitInfo storage info) internal view {
        uint256 numerator = info.ptBackingNumerator;
        uint256 denominator = info.ptBackingDenominator;
        if (numerator == 0 || denominator == 0) revert InvalidClaim();
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
