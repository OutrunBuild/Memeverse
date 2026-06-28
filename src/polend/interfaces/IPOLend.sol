// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IPOLend {
    enum MarketState {
        None,
        Genesis,
        Locked,
        Settled,
        Refund
    }

    struct LendMarket {
        address uAsset;
        address yt;
        uint256 interestRate;
        // totalLeveragedInterest keeps storing the aggregate (real + credit) so existing
        // settlement / claim math is unchanged. real genesis = total - totalCreditInterest.
        uint256 totalLeveragedInterest;
        uint256 totalCreditInterest;
        uint256 totalLeveragedYT;
        MarketState state;
        // Cached GenesisCredit token address for this verse's uAsset, written on first
        // `leveragedGenesisWithCredit`. Locks the credit token identity at entry so finalize
        // burn / claimRefund payout never re-resolve via a mutable creditFactory pointer
        // (which could drift if `setCreditFactory` is changed mid-flight).
        address creditToken;
    }

    struct ResidualState {
        uint256 residualUAsset;
        uint256 residualMemecoin;
    }

    struct LeveragedDebtInfo {
        uint256 totalLeveragedInterest;
        uint256 totalLeveragedDebt;
        uint256 interestRate;
        uint256 debtCap;
        uint256 remainingAdditionalInterest;
    }

    struct SettlementDustState {
        uint128 reserve;
        uint128 maxReserve;
    }

    error InvalidState();
    error InvalidClaim();
    error InvalidConfig();
    error DebtCapExceeded();
    error PermissionDenied();
    error ZeroInput();
    error SettlementDustReserveExceeded(uint256 amount, uint256 capacity);
    error SettlementDustInsufficient(uint256 deficit, uint256 availableReserve);
    /// @notice Reverts when `leveragedGenesisWithCredit` is called for a verse whose uAsset has no
    ///         GenesisCredit token registered on the configured factory.
    error NoCreditForUAsset();

    /// @notice Reverts when the verse uAsset or its resolved GenesisCredit token is not 18 decimals.
    /// @dev GenesisCredit is fixed at 18 decimals, so credit-path raw-unit accounting only stays
    ///      correct when the verse uAsset is also 18 decimals. Checked once when a verse first
    ///      resolves its credit token (`creditOf(uAsset)` succeeds) and before caching it.
    error CreditDecimalsMismatch(uint8 uAssetDecimals, uint8 creditDecimals);

    event ProtocolTreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event DefaultInterestRateChanged(uint256 oldRate, uint256 newRate);
    event LeveragedDebtFactorChanged(uint256 oldFactor, uint256 newFactor);
    event LeveragedGenesis(uint256 indexed verseId, address indexed user, uint256 interestAmount);
    event PreRedeemPTFee(
        uint256 indexed verseId, address indexed uAsset, uint256 ptAmount, uint256 uAssetBacking, address mintTo
    );
    event SettlementDustReserveConfigured(address indexed uAsset, uint128 oldMaxReserve, uint128 newMaxReserve);
    /// @notice Emitted when leveraged-genesis finalization burns the GenesisCredit escrowed by
    ///         POLend for credit-funded participants of `verseId`.
    /// @dev `totalCreditInterest` mirrors `market.totalCreditInterest` at finalization and matches
    ///      the amount burned from POLend's credit balance.
    event CreditBurned(uint256 indexed verseId, address indexed uAsset, uint256 totalCreditInterest);
    event SettlementDustReserveFunded(
        address indexed uAsset, address indexed funder, uint256 amount, uint256 credited, uint256 excess
    );
    event SettlementDustReserveConsumed(
        uint256 indexed verseId, address indexed uAsset, uint256 consumed, uint256 reserveAfter
    );
    event GlobalSettlementExecuted(
        uint256 indexed verseId,
        address indexed uAsset,
        uint256 verseDebt,
        uint256 recoveredUAsset,
        uint256 consumedSettlementDustReserve,
        uint256 settlementDustReserveAfter,
        uint256 residualUAsset,
        uint256 residualMemecoin
    );
    event ClaimRefund(uint256 indexed verseId, address indexed user, address indexed to, uint256 refundedAmount);
    /// @notice Emitted in `claimRefund` when the caller's GenesisCredit interest is refunded.
    /// @dev Independent from `ClaimRefund` so credit-only participants still emit a signal even
    ///      though the real-uAsset branch is skipped (real interest == 0). Mixed participants emit
    ///      both events in a single call.
    event CreditRefunded(uint256 indexed verseId, address indexed user, address indexed to, uint256 amount);
    event ClaimLeveragedYT(uint256 indexed verseId, address indexed user, address indexed to, uint256 amount);
    event ClaimResidual(
        uint256 indexed verseId, address indexed user, address indexed to, uint256 uAssetAmount, uint256 memecoinAmount
    );
    event CreditFactoryChanged(address indexed oldFactory, address indexed newFactory);
    /// @notice Emitted when a user opens (or adds to) a leveraged-genesis position by escrowing
    ///         GenesisCredit (instead of the raw uAsset) as interest.
    /// @dev Escrow only — the credit is not burned here. It is burned later in
    ///      `finalizeLeveragedGenesis` (`CreditBurned`), or returned on the refund path (`claimRefund`, `CreditRefunded`).
    event LeveragedGenesisWithCredit(uint256 indexed verseId, address indexed user, uint256 creditAmount);

    function pause() external;

    function unpause() external;

    function setProtocolTreasury(address newTreasury) external;

    function setDefaultInterestRate(uint256 newRate) external;

    function setLeveragedDebtFactor(uint256 newFactor) external;

    function setMaxSettlementDustReserve(address uAsset, uint128 maxReserve) external;

    function setCreditFactory(address newFactory) external;

    function registerLendMarket(uint256 verseId) external;

    function leveragedGenesis(uint256 verseId, uint256 interestAmount) external returns (uint256 borrowedAmount);

    /// @notice Open or add to a leveraged-genesis position by paying interest in GenesisCredit
    ///         instead of the verse's uAsset. The credit token is escrowed (not burned) by POLend.
    /// @param verseId Memeverse identifier.
    /// @param creditAmount Amount of GenesisCredit to escrow as interest.
    /// @return borrowedAmount uAsset-denominated debt minted against this interest.
    function leveragedGenesisWithCredit(uint256 verseId, uint256 creditAmount) external returns (uint256 borrowedAmount);

    function markRefundable(uint256 verseId) external;

    function finalizeLeveragedGenesis(uint256 verseId) external;

    function recordLeveragedYT(uint256 verseId, address yt, uint256 totalLeveragedYT) external;

    function executeGlobalSettlement(uint256 verseId) external;

    function fundSettlementDustReserve(address uAsset, uint256 amount) external;

    function preRedeemPTFee(uint256 verseId, uint256 ptAmount, address mintTo) external returns (uint256 uAssetBacking);

    function burnPreRedeemedBacking(uint256 verseId, uint256 amount) external;

    function claimRefund(uint256 verseId, address to) external returns (uint256 refundedAmount);

    function claimLeveragedYT(uint256 verseId, address to) external returns (uint256 amount);

    function claimResidual(uint256 verseId, address to) external returns (uint256 uAssetAmount, uint256 memecoinAmount);

    function getTotalLeveragedDebt(uint256 verseId) external view returns (uint256);

    function getUserLeveragedDebt(uint256 verseId, address user) external view returns (uint256);

    function getTotalDebtByUAsset(address uAsset) external view returns (uint256);

    function settlementDustStates(address uAsset) external view returns (uint128 reserve, uint128 maxReserve);

    function getLeveragedDebtInfo(uint256 verseId) external view returns (LeveragedDebtInfo memory);

    function getTotalLeveragedInterest(uint256 verseId) external view returns (uint256);

    function getTotalCreditInterest(uint256 verseId) external view returns (uint256);

    function getLendMarket(uint256 verseId) external view returns (LendMarket memory market);
}
