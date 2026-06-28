// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "../common/token/OutrunERC20Init.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OutrunSafeERC20} from "../yield/libraries/OutrunSafeERC20.sol";
import {ReentrancyGuard} from "../common/access/ReentrancyGuard.sol";
import {IPOLend} from "./interfaces/IPOLend.sol";
import {IPOLSplitter} from "./interfaces/IPOLSplitter.sol";
import {IUniversalAssets} from "./interfaces/IUniversalAssets.sol";
import {IMemeverseLauncher} from "../verse/interfaces/IMemeverseLauncher.sol";
import {IGenesisCreditFactory} from "../credit/interfaces/IGenesisCreditFactory.sol";
import {IGenesisCredit} from "../credit/interfaces/IGenesisCredit.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";

/// @title POLend
/// @notice Leveraged-genesis lend market: escrows leveraged interest (real uAsset and GenesisCredit),
///         mints debt to the launcher, runs global settlement, and distributes YT/residuals pro-rata.
contract POLend layout at erc7201("outrun.storage.POLend")
    is
    Initializable,
    OutrunOwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPOLend
{
    using OutrunSafeERC20 for IERC20;

    uint8 internal constant CLAIM_REFUND = 1 << 0;
    uint8 internal constant CLAIM_LEVERAGED_YT = 1 << 1;
    uint8 internal constant CLAIM_RESIDUAL = 1 << 2;
    uint256 internal constant MIN_LEVERAGED_DEBT_PRODUCT = 1e36;
    uint256 internal constant MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max;
    uint256 internal constant MAX_LEVERAGED_DEBT_FACTOR = uint256(type(uint128).max) * 1e18;

    /// @custom:storage-location erc7201:outrun.storage.POLend
    struct POLendStorage {
        uint256 defaultInterestRate;
        uint256 leveragedDebtFactor;
        address treasury;
        address launcher;
        address splitter;
        // Credit-factory-written interest per user; added on top of leveragedInterestPaid.
        mapping(uint256 => mapping(address => uint256)) creditInterestPaid;
        address creditFactory;
        mapping(uint256 => LendMarket) lendMarkets;
        mapping(uint256 => mapping(address => uint256)) leveragedInterestPaid;
        mapping(uint256 => ResidualState) residualStates;
        mapping(address => uint256) globalDebtByUAsset;
        mapping(address uAsset => SettlementDustState state) settlementDustStates;
        mapping(uint256 => mapping(address => uint8)) claimFlags;
    }

    POLendStorage private polendStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyLauncher() {
        if (msg.sender != polendStorage.launcher) revert PermissionDenied();
        _;
    }

    modifier onlySplitter() {
        if (msg.sender != polendStorage.splitter) revert PermissionDenied();
        _;
    }

    /// @notice One-time proxy initializer. Sets the owner plus all integration pointers and leverage parameters.
    /// @param initialOwner Address to grant contract ownership.
    /// @param interestRate_ Default interest rate (1e18-scaled; (0, 1e18]).
    /// @param leveragedDebtFactor_ Leveraged-debt factor applied to the launcher debt cap.
    /// @param treasury_ Protocol treasury receiving the full real-uAsset leveraged interest slice at finalize, plus dust-reserve overflow from over-capacity funding.
    /// @param launcher_ MemeverseLauncher authorized to drive verse lifecycle.
    /// @param splitter_ POLSplitter authorized to redeem PTs and burn backing.
    /// @param creditFactory_ GenesisCreditFactory issuing credit tokens.
    function initialize(
        address initialOwner,
        uint256 interestRate_,
        uint256 leveragedDebtFactor_,
        address treasury_,
        address launcher_,
        address splitter_,
        address creditFactory_
    ) external initializer {
        if (interestRate_ == 0) revert ZeroInput();
        if (interestRate_ > 1e18) revert InvalidConfig();
        if (treasury_ == address(0) || launcher_ == address(0) || splitter_ == address(0)) revert ZeroInput();
        if (creditFactory_ == address(0)) revert ZeroInput();
        _validateLeverageConfig(interestRate_, leveragedDebtFactor_);

        __OutrunOwnable_init(initialOwner);
        __Pausable_init();

        polendStorage.defaultInterestRate = interestRate_;
        polendStorage.leveragedDebtFactor = leveragedDebtFactor_;
        polendStorage.treasury = treasury_;
        polendStorage.launcher = launcher_;
        polendStorage.splitter = splitter_;
        polendStorage.creditFactory = creditFactory_;
    }

    /// @notice Update the protocol treasury (onlyOwner). Emits `ProtocolTreasuryChanged`.
    /// @param newTreasury New treasury address (must not be zero).
    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroInput();

        address oldTreasury = polendStorage.treasury;
        polendStorage.treasury = newTreasury;
        emit ProtocolTreasuryChanged(oldTreasury, newTreasury);
    }

    /// @notice Update the credit factory that issues GenesisCredit tokens (onlyOwner). Emits `CreditFactoryChanged`.
    /// @param newFactory New credit factory address (must not be zero).
    function setCreditFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroInput();

        address oldFactory = polendStorage.creditFactory;
        polendStorage.creditFactory = newFactory;
        emit CreditFactoryChanged(oldFactory, newFactory);
    }

    /// @notice Update the default interest rate applied to future markets (onlyOwner). Emits `DefaultInterestRateChanged`.
    /// @param newRate New rate (1e18-scaled; (0, 1e18]).
    function setDefaultInterestRate(uint256 newRate) external onlyOwner {
        if (newRate == 0) revert ZeroInput();
        if (newRate > 1e18) revert InvalidConfig();

        _validateLeverageConfig(newRate, polendStorage.leveragedDebtFactor);
        uint256 oldRate = polendStorage.defaultInterestRate;
        polendStorage.defaultInterestRate = newRate;
        emit DefaultInterestRateChanged(oldRate, newRate);
    }

    /// @notice Update the leveraged-debt factor applied to the launcher debt cap (onlyOwner). Emits `LeveragedDebtFactorChanged`.
    /// @param newFactor New factor (must satisfy the leverage-config validation).
    function setLeveragedDebtFactor(uint256 newFactor) external onlyOwner {
        _validateLeverageConfig(polendStorage.defaultInterestRate, newFactor);
        uint256 oldFactor = polendStorage.leveragedDebtFactor;
        polendStorage.leveragedDebtFactor = newFactor;
        emit LeveragedDebtFactorChanged(oldFactor, newFactor);
    }

    /// @notice Configure the settlement-dust reserve cap for a uAsset (onlyOwner). Emits `SettlementDustReserveConfigured`.
    /// @param uAsset Universal-asset address (must not be zero).
    /// @param maxReserve New reserve cap (must be >= the currently funded reserve).
    function setMaxSettlementDustReserve(address uAsset, uint128 maxReserve) external onlyOwner {
        if (uAsset == address(0) || maxReserve == 0) revert ZeroInput();

        SettlementDustState storage state = polendStorage.settlementDustStates[uAsset];
        if (state.reserve > maxReserve) revert InvalidConfig();
        uint128 oldMaxReserve = state.maxReserve;
        state.maxReserve = maxReserve;
        emit SettlementDustReserveConfigured(uAsset, oldMaxReserve, maxReserve);
    }

    /// @notice Register a new lend market for a verse (onlyLauncher). Resolves the uAsset from the launcher
    ///         and seeds a market in `None` state with the default interest rate. The verse's uAsset must
    ///         already have a non-zero settlement-dust reserve configured.
    /// @param verseId Verse identifier to register.
    function registerLendMarket(uint256 verseId) external onlyLauncher {
        if (polendStorage.lendMarkets[verseId].uAsset != address(0)) revert InvalidState();
        _validateLeverageConfig(polendStorage.defaultInterestRate, polendStorage.leveragedDebtFactor);
        address uAsset = IMemeverseLauncher(polendStorage.launcher).getUAssetByVerseId(verseId);
        if (uAsset == address(0)) revert ZeroInput();
        if (polendStorage.settlementDustStates[uAsset].maxReserve == 0) revert InvalidConfig();
        polendStorage.lendMarkets[verseId] = LendMarket({
            uAsset: uAsset,
            yt: address(0),
            interestRate: polendStorage.defaultInterestRate,
            totalLeveragedInterest: 0,
            totalCreditInterest: 0,
            totalLeveragedYT: 0,
            state: MarketState.None,
            creditToken: address(0)
        });
    }

    /// @notice Open or top up a leveraged-genesis position by paying real-uAsset interest.
    ///         Pulls `interestAmount` of uAsset from the caller and accrues the borrowed debt
    ///         (interest / rate) against the verse. Caps enforce the per-verse debt ceiling and
    ///         the aggregate genesis-funds limit.
    /// @param verseId Verse identifier (must be in Genesis stage).
    /// @param interestAmount uAsset interest to pay (must be > 0).
    /// @return borrowedAmount Leveraged debt generated by this interest payment.
    function leveragedGenesis(uint256 verseId, uint256 interestAmount)
        external
        whenNotPaused
        returns (uint256 borrowedAmount)
    {
        if (interestAmount == 0) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.interestRate == 0) revert InvalidState();
        if (market.state != MarketState.None && market.state != MarketState.Genesis) revert InvalidState();
        address marketUAsset = market.uAsset;
        if (IMemeverseLauncher(polendStorage.launcher).getStageByVerseId(verseId) != IMemeverseLauncher.Stage.Genesis) {
            revert InvalidState();
        }
        uint256 actualNormalFunds = IMemeverseLauncher(polendStorage.launcher).totalNormalFunds(verseId);
        if (actualNormalFunds > MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) revert InvalidConfig();

        uint256 nextTotalInterest = market.totalLeveragedInterest + interestAmount;
        uint256 previewTotalDebt = Math.mulDiv(nextTotalInterest, 1e18, market.interestRate);
        // Aggregate genesis funds include all leveraged debt already accumulated for the verse.
        if (previewTotalDebt > MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - actualNormalFunds) revert InvalidConfig();
        if (previewTotalDebt > _debtCap(verseId)) revert DebtCapExceeded();

        borrowedAmount = Math.mulDiv(interestAmount, 1e18, market.interestRate);
        polendStorage.leveragedInterestPaid[verseId][msg.sender] += interestAmount;
        market.totalLeveragedInterest = nextTotalInterest;
        if (market.state == MarketState.None) market.state = MarketState.Genesis;
        IERC20(marketUAsset).safeTransferFrom(msg.sender, address(this), interestAmount);
        emit LeveragedGenesis(verseId, msg.sender, interestAmount);
    }

    /// @notice Same accounting as `leveragedGenesis`, but interest is paid in GenesisCredit
    ///         (escrowed in POLend) instead of the verse's uAsset.
    /// @dev    Credit interest is tracked in a dedicated ledger (`creditInterestPaid` +
    ///         `market.totalCreditInterest`) and also added to `totalLeveragedInterest` so debt
    ///         math and downstream settlement/claim logic stay identical to the real-uAsset path.
    ///         CEI is preserved: state updates happen before the external transferFrom.
    /// @param verseId Verse identifier (must be in Genesis stage).
    /// @param creditAmount GenesisCredit to pay (must be > 0).
    /// @return borrowedAmount Leveraged debt generated by this credit payment.
    function leveragedGenesisWithCredit(uint256 verseId, uint256 creditAmount)
        external
        whenNotPaused
        returns (uint256 borrowedAmount)
    {
        if (creditAmount == 0) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.interestRate == 0) revert InvalidState();
        if (market.state != MarketState.None && market.state != MarketState.Genesis) revert InvalidState();
        if (IMemeverseLauncher(polendStorage.launcher).getStageByVerseId(verseId) != IMemeverseLauncher.Stage.Genesis) {
            revert InvalidState();
        }
        // Read the cached credit token first; only resolve via the factory on first credit
        // entry for this verse. This locks the token identity at first entry and avoids
        // re-resolving through the mutable creditFactory pointer on every subsequent entry.
        address credit = market.creditToken;
        if (credit == address(0)) {
            // Cold path only (first credit entry for this verse): resolves the credit token via
            // creditOf and runs the 18-decimals guard. Declared inside the block rather than at
            // the function top so the warm path — which skips this block — does not pay a cold
            // SLOAD of market.uAsset (slot 0) it would never use.
            address marketUAsset = market.uAsset;
            credit = IGenesisCreditFactory(polendStorage.creditFactory).creditOf(marketUAsset);
            if (credit == address(0)) revert NoCreditForUAsset();
            // GenesisCredit is fixed at 18 decimals, so credit-path raw-unit accounting (creditAmount
            // is summed into totalLeveragedInterest and converted to debt at the same rate as real
            // uAsset interest) only stays correct when the verse uAsset is also 18 decimals. A
            // replaceable creditFactory pointer could map a non-18-dec uAsset to an 18-dec credit, so
            // guard at the use boundary too, before caching. Runs once per verse, on first entry.
            uint8 uAssetDecimals = IERC20Metadata(marketUAsset).decimals();
            uint8 creditDecimals = IERC20Metadata(credit).decimals();
            if (uAssetDecimals != 18 || creditDecimals != 18) {
                revert CreditDecimalsMismatch(uAssetDecimals, creditDecimals);
            }
            market.creditToken = credit;
        }

        uint256 actualNormalFunds = IMemeverseLauncher(polendStorage.launcher).totalNormalFunds(verseId);
        if (actualNormalFunds > MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) revert InvalidConfig();

        uint256 nextTotalInterest = market.totalLeveragedInterest + creditAmount;
        uint256 previewTotalDebt = Math.mulDiv(nextTotalInterest, 1e18, market.interestRate);
        if (previewTotalDebt > MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - actualNormalFunds) revert InvalidConfig();
        if (previewTotalDebt > _debtCap(verseId)) revert DebtCapExceeded();

        borrowedAmount = Math.mulDiv(creditAmount, 1e18, market.interestRate);
        polendStorage.creditInterestPaid[verseId][msg.sender] += creditAmount;
        market.totalCreditInterest += creditAmount;
        market.totalLeveragedInterest = nextTotalInterest;
        if (market.state == MarketState.None) market.state = MarketState.Genesis;
        IERC20(credit).safeTransferFrom(msg.sender, address(this), creditAmount);
        emit LeveragedGenesisWithCredit(verseId, msg.sender, creditAmount);
    }

    /// @notice Mark a verse's market as refundable (onlyLauncher). Transitions a `Genesis`-state
    ///         market to `Refund`, enabling `claimRefund` for participants of a failed verse.
    /// @param verseId Verse identifier to transition.
    function markRefundable(uint256 verseId) external onlyLauncher {
        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Genesis) revert InvalidState();
        market.state = MarketState.Refund;
    }

    /// @notice Finalize a verse's leveraged genesis and lock its debt (onlyLauncher). Sweeps the
    ///         full real-uAsset interest to the treasury, mints the aggregate debt as uAsset to the
    ///         launcher, burns the escrowed GenesisCredit for the credit-funded slice, and accrues
    ///         the verse debt to the per-uAsset global ledger.
    /// @dev The per-uAsset settlement-dust reserve is NOT funded from interest here — it is funded
    ///      solely by the Launcher's bootstrap unused uAsset (`_handleBootstrapResiduals` ->
    ///      `fundSettlementDustReserve`) and manual `fundSettlementDustReserve` calls.
    /// @param verseId Verse identifier to finalize.
    function finalizeLeveragedGenesis(uint256 verseId) external onlyLauncher {
        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Genesis) revert InvalidState();
        uint256 debt = _totalLeveragedDebt(market);
        if (debt == 0) revert InvalidState();

        address marketUAsset = market.uAsset;
        uint256 totalLeveragedInterest = market.totalLeveragedInterest;
        uint256 totalCredit = market.totalCreditInterest;
        // Only the real-uAsset slice was actually escrowed in this contract as `marketUAsset`;
        // sweep it in full to the treasury. Credit-funded interest has no uAsset inflow and is
        // burned below. The settlement-dust reserve is funded solely by the Launcher's bootstrap
        // unused uAsset (`_handleBootstrapResiduals` -> `fundSettlementDustReserve`) and manual
        // `fundSettlementDustReserve` calls — no longer from leveraged interest.
        uint256 realInterest = totalLeveragedInterest - totalCredit;

        market.state = MarketState.Locked;
        polendStorage.globalDebtByUAsset[marketUAsset] += debt;

        // Debt minting uses the aggregate (real + credit) interest via `_totalLeveragedDebt`, so
        // credit interest still backs `debt` for the launcher — the only behavioral change is that
        // the real-uAsset slice now sweeps entirely to treasury instead of being split reserve/treasury.
        IUniversalAssets(marketUAsset).mint(polendStorage.launcher, debt);
        if (realInterest != 0) IERC20(marketUAsset).safeTransfer(polendStorage.treasury, realInterest);

        // Burn the escrowed GenesisCredit so the credit-funded portion exits supply at finalize
        // time. Per-verse `totalCreditInterest` is exclusive of other verses (state machine
        // forbids re-entering `Genesis`), keeping the same-uAsset multi-verse pool conserved.
        if (totalCredit != 0) {
            // Read the cached credit token locked at first credit entry, not the live factory
            // pointer (which setCreditFactory could have changed). Guard against zero as defense
            // in depth — finalize only runs for markets that had credit participation, so the
            // cache is always populated when totalCredit != 0.
            address credit = market.creditToken;
            if (credit == address(0)) revert NoCreditForUAsset();
            IGenesisCredit(credit).burn(totalCredit);
            emit CreditBurned(verseId, marketUAsset, totalCredit);
        }
    }

    /// @notice Record the YT token and its total supply for a locked verse (onlyLauncher). Enables
    ///         `claimLeveragedYT` to distribute YT pro-rata to leveraged participants.
    /// @param verseId Verse identifier (must be in Locked state).
    /// @param yt YT token address (must not be zero).
    /// @param totalLeveragedYT Total YT to distribute (must be > 0).
    function recordLeveragedYT(uint256 verseId, address yt, uint256 totalLeveragedYT) external onlyLauncher {
        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Locked || market.yt != address(0)) revert InvalidState();
        if (yt == address(0) || totalLeveragedYT == 0) revert ZeroInput();
        market.yt = yt;
        market.totalLeveragedYT = totalLeveragedYT;
    }

    /// @notice Execute global settlement for a verse (onlyLauncher). Recovers uAsset from POL and
    ///         PT redemption, repays the verse debt, consumes the settlement-dust reserve to cover any
    ///         deficit, stores the residual uAsset/memecoin for pro-rata claims, and transitions the
    ///         market to `Settled`. Reverts if the reserve cannot cover a deficit.
    /// @param verseId Verse identifier (must be in Locked state).
    function executeGlobalSettlement(uint256 verseId) external onlyLauncher nonReentrant {
        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Locked) revert InvalidState();
        address marketUAsset = market.uAsset;

        (uint256 polAmount, uint256 ptAmount, uint256 lpUAsset) =
            IMemeverseLauncher(polendStorage.launcher).settleLeveragedAuxiliaryLiquidity(verseId);
        (uint256 burnedPolUAsset, uint256 burnedPolMemecoin) = _burnSettledPol(verseId, polAmount);
        uint256 redeemedPtUAsset;
        if (ptAmount != 0) {
            redeemedPtUAsset = IPOLSplitter(polendStorage.splitter).redeemPT(verseId, ptAmount, address(this));
        }

        uint256 totalRecoveredUAsset = lpUAsset + burnedPolUAsset + redeemedPtUAsset;
        uint256 debt = _totalLeveragedDebt(market);
        SettlementDustState storage dustState = polendStorage.settlementDustStates[marketUAsset];
        uint256 reserveBeforeSettlement = dustState.reserve;
        uint256 reserveAfterSettlement = reserveBeforeSettlement;
        uint256 consumedSettlementDustReserve;
        uint256 residualUAsset;

        if (totalRecoveredUAsset >= debt) {
            residualUAsset = totalRecoveredUAsset - debt;
        } else {
            uint256 deficit = debt - totalRecoveredUAsset;
            if (deficit > reserveBeforeSettlement) revert SettlementDustInsufficient(deficit, reserveBeforeSettlement);
            consumedSettlementDustReserve = deficit;
            reserveAfterSettlement = reserveBeforeSettlement - deficit;
            dustState.reserve = uint128(reserveAfterSettlement);
            emit SettlementDustReserveConsumed(verseId, marketUAsset, deficit, reserveAfterSettlement);
        }

        polendStorage.residualStates[verseId] =
            ResidualState({residualUAsset: residualUAsset, residualMemecoin: burnedPolMemecoin});
        market.state = MarketState.Settled;
        if (debt != 0) polendStorage.globalDebtByUAsset[marketUAsset] -= debt;

        if (debt != 0) IUniversalAssets(marketUAsset).repay(address(this), debt);

        emit GlobalSettlementExecuted(
            verseId,
            marketUAsset,
            debt,
            totalRecoveredUAsset,
            consumedSettlementDustReserve,
            reserveAfterSettlement,
            residualUAsset,
            burnedPolMemecoin
        );
    }

    /// @notice Fund the settlement-dust reserve for a uAsset. Pulls `amount` from the caller; the
    ///         in-cap portion is credited to the reserve and any excess is forwarded to the treasury.
    ///         The launcher may over-fund beyond the cap (excess still spills to treasury); other
    ///         callers are rejected if `amount` exceeds the remaining capacity.
    /// @param uAsset Universal-asset address (must have a configured reserve cap).
    /// @param amount uAsset amount to deposit (must be > 0).
    function fundSettlementDustReserve(address uAsset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroInput();

        SettlementDustState storage state = polendStorage.settlementDustStates[uAsset];
        uint256 maxReserve = state.maxReserve;
        if (maxReserve == 0) revert InvalidConfig();

        uint256 reserve = state.reserve;
        uint256 capacity = maxReserve - reserve;
        bool fromLauncher = msg.sender == polendStorage.launcher;
        if (!fromLauncher && amount > capacity) revert SettlementDustReserveExceeded(amount, capacity);

        IERC20(uAsset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = Math.min(amount, capacity);
        uint256 excess = amount - credited;
        // Skip the no-op SSTORE when reserve is already at capacity (launcher path: the
        // full amount spills to treasury as excess, credited == 0, reserve unchanged).
        if (credited != 0) state.reserve = uint128(reserve + credited);
        if (excess != 0) IERC20(uAsset).safeTransfer(polendStorage.treasury, excess);
        emit SettlementDustReserveFunded(uAsset, msg.sender, amount, credited, excess);
    }

    /// @notice Pre-redeem a PT-fee amount and mint its uAsset backing ahead of settlement (onlyLauncher).
    ///         Accrues the resulting uAsset backing to the per-uAsset global debt and mints it as
    ///         uAsset to `mintTo` so the splitter can later redeem/burn it.
    /// @param verseId Verse identifier (must be in Locked state).
    /// @param ptAmount PT amount to pre-redeem (must be > 0).
    /// @param mintTo Recipient of the minted uAsset backing (must not be zero).
    /// @return uAssetBacking uAsset amount minted for the PT fee.
    function preRedeemPTFee(uint256 verseId, uint256 ptAmount, address mintTo)
        external
        onlyLauncher
        returns (uint256 uAssetBacking)
    {
        if (ptAmount == 0 || mintTo == address(0)) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Locked) revert InvalidState();

        uAssetBacking = IPOLSplitter(polendStorage.splitter).preRedeemPTFee(verseId, ptAmount);
        polendStorage.globalDebtByUAsset[market.uAsset] += uAssetBacking;
        IUniversalAssets(market.uAsset).mint(mintTo, uAssetBacking);
        emit PreRedeemPTFee(verseId, market.uAsset, ptAmount, uAssetBacking, mintTo);
    }

    /// @notice Burn previously pre-redeemed uAsset backing (onlySplitter). Reverses the debt accrued
    ///         by `preRedeemPTFee` by repaying the uAsset from the splitter, keeping the global debt
    ///         ledger consistent after PT redemption.
    /// @param verseId Verse identifier whose backing to burn.
    /// @param amount uAsset amount to repay (must be > 0).
    function burnPreRedeemedBacking(uint256 verseId, uint256 amount) external onlySplitter {
        if (amount == 0) revert ZeroInput();

        address marketUAsset = polendStorage.lendMarkets[verseId].uAsset;
        polendStorage.globalDebtByUAsset[marketUAsset] -= amount;
        IUniversalAssets(marketUAsset).repay(polendStorage.splitter, amount);
    }

    /// @notice Refund a caller's leveraged-genesis interest after the verse fails and the market
    ///         enters `Refund`. Returns the real-uAsset interest paid; any GenesisCredit interest
    ///         paid by the same caller is also refunded as the same-denomination credit token.
    /// @dev    F-3: judgement is the conjunction of both ledgers (`realPaid == 0 && creditPaid == 0`)
    ///         and is performed before per-asset routing, so a credit-only participant can claim
    ///         credit back without reverting on the real ledger being empty. Real-uAsset and credit
    ///         payouts are physically isolated: each branch is gated by its own non-zero guard so we
    ///         never transfer an asset we don't actually hold for this caller. `_consumeClaimFlag`
    ///         runs before any external transfer (CEI) and prevents double-claim across both
    ///         branches in a single call. Accumulator state is left intact; the per-verse
    ///         state-machine (Refund is terminal for these ledgers, see spec §6.2) provides the
    ///         non-replay invariant — only the per-user `claimFlags` bit needs to flip.
    /// @param verseId Verse identifier (must be in Refund state).
    /// @param to Recipient of the refunded uAsset and credit (must not be zero).
    /// @return refundedAmount Real-uAsset amount refunded (zero for credit-only participants).
    function claimRefund(uint256 verseId, address to) external nonReentrant returns (uint256 refundedAmount) {
        if (to == address(0)) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Refund) revert InvalidState();

        uint256 realPaid = polendStorage.leveragedInterestPaid[verseId][msg.sender];
        uint256 creditPaid = polendStorage.creditInterestPaid[verseId][msg.sender];
        // Allow any participant with either ledger non-zero to claim; reject only when both are zero.
        if (realPaid == 0 && creditPaid == 0) revert InvalidClaim();

        _consumeClaimFlag(verseId, msg.sender, CLAIM_REFUND);

        // Returned value keeps the historical contract: real-uAsset interest refunded.
        // Credit interest is surfaced through the `CreditRefunded` event.
        refundedAmount = realPaid;

        if (realPaid != 0) {
            IERC20(market.uAsset).safeTransfer(to, realPaid);
            emit ClaimRefund(verseId, msg.sender, to, realPaid);
        }
        if (creditPaid != 0) {
            // Read the cached credit token locked at first credit entry, not the live factory
            // pointer, so a mid-flight setCreditFactory cannot strand escrowed credit.
            address credit = market.creditToken;
            if (credit == address(0)) revert NoCreditForUAsset();
            IERC20(credit).safeTransfer(to, creditPaid);
            emit CreditRefunded(verseId, msg.sender, to, creditPaid);
        }
    }

    /// @notice Claim a caller's pro-rata share of leveraged YT for a locked or settled verse.
    ///         Share is `(real + credit interest paid) / totalLeveragedInterest` of the verse's
    ///         total YT; the per-user claim flag prevents double-claiming.
    /// @param verseId Verse identifier (Locked or Settled state).
    /// @param to Recipient of the YT (must not be zero).
    /// @return amount YT tokens transferred to `to`.
    function claimLeveragedYT(uint256 verseId, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Locked && market.state != MarketState.Settled) revert InvalidState();

        // Aggregate real + credit interest: credit participants share YT pro-rata to combined paid interest
        // (spec docs/spec/polend/genesis.md §7; totalLeveragedInterest = real + credit combined, see core.md §6.3).
        uint256 interestPaid = polendStorage.leveragedInterestPaid[verseId][msg.sender]
            + polendStorage.creditInterestPaid[verseId][msg.sender];
        uint256 totalLeveragedInterest = market.totalLeveragedInterest;
        if (interestPaid == 0 || totalLeveragedInterest == 0) revert InvalidClaim();

        _consumeClaimFlag(verseId, msg.sender, CLAIM_LEVERAGED_YT);
        amount = Math.mulDiv(market.totalLeveragedYT, interestPaid, totalLeveragedInterest);
        IERC20(market.yt).safeTransfer(to, amount);
        emit ClaimLeveragedYT(verseId, msg.sender, to, amount);
    }

    /// @notice Claim a caller's pro-rata share of post-settlement residual uAsset and memecoin.
    ///         Share is `(real + credit interest paid) / totalLeveragedInterest` of the verse's
    ///         residual assets; the per-user claim flag prevents double-claiming.
    /// @param verseId Verse identifier (must be in Settled state).
    /// @param to Recipient of the residual assets (must not be zero).
    /// @return uAssetAmount Residual uAsset transferred to `to`.
    /// @return memecoinAmount Residual memecoin transferred to `to`.
    function claimResidual(uint256 verseId, address to)
        external
        nonReentrant
        returns (uint256 uAssetAmount, uint256 memecoinAmount)
    {
        if (to == address(0)) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.state != MarketState.Settled) revert InvalidState();

        // Aggregate real + credit interest: credit participants share residual pro-rata to combined paid interest
        // (spec docs/spec/polend/settlement-and-fees.md §7; totalLeveragedInterest = real + credit combined, see core.md §6.3).
        uint256 interestPaid = polendStorage.leveragedInterestPaid[verseId][msg.sender]
            + polendStorage.creditInterestPaid[verseId][msg.sender];
        uint256 totalLeveragedInterest = market.totalLeveragedInterest;
        if (interestPaid == 0 || totalLeveragedInterest == 0) revert InvalidClaim();

        _consumeClaimFlag(verseId, msg.sender, CLAIM_RESIDUAL);

        ResidualState storage residual = polendStorage.residualStates[verseId];
        uAssetAmount = Math.mulDiv(residual.residualUAsset, interestPaid, totalLeveragedInterest);
        memecoinAmount = Math.mulDiv(residual.residualMemecoin, interestPaid, totalLeveragedInterest);

        if (uAssetAmount != 0) IERC20(market.uAsset).safeTransfer(to, uAssetAmount);
        if (memecoinAmount != 0) {
            address memecoin = IPOLSplitter(polendStorage.splitter).getMemecoin(verseId);
            IERC20(memecoin).safeTransfer(to, memecoinAmount);
        }
        emit ClaimResidual(verseId, msg.sender, to, uAssetAmount, memecoinAmount);
    }

    // --- View functions (replacing auto-generated public getters) ---

    /// @notice Default per-verse interest rate applied to newly registered lend markets.
    /// @return Configured default interest rate (1e18-scaled).
    function defaultInterestRate() external view returns (uint256) {
        return polendStorage.defaultInterestRate;
    }

    /// @notice Leveraged-debt multiplier factor (1e18-scaled) applied to the launcher debt cap base.
    /// @return Configured leveraged debt factor.
    function leveragedDebtFactor() external view returns (uint256) {
        return polendStorage.leveragedDebtFactor;
    }

    /// @notice Protocol treasury that receives the full real-uAsset leveraged interest slice at finalize, plus dust-reserve overflow from over-capacity funding.
    /// @return Configured treasury address.
    function treasury() external view returns (address) {
        return polendStorage.treasury;
    }

    /// @notice MemeverseLauncher authorized to register markets and drive the verse lifecycle.
    /// @return Configured launcher address.
    function launcher() external view returns (address) {
        return polendStorage.launcher;
    }

    /// @notice POLSplitter authorized to redeem PTs and burn pre-redeemed backing.
    /// @return Configured splitter address.
    function splitter() external view returns (address) {
        return polendStorage.splitter;
    }

    /// @notice Address of the credit factory registered to write per-user credit interest.
    /// @return Registered credit factory address.
    function creditFactory() external view returns (address) {
        return polendStorage.creditFactory;
    }

    /// @notice Full lend-market snapshot for a verse (uAsset, YT, interest rate, accumulators, state).
    /// @param verseId Verse identifier whose market to read.
    /// @return LendMarket struct copy for the verse.
    function lendMarkets(uint256 verseId) external view returns (LendMarket memory) {
        return polendStorage.lendMarkets[verseId];
    }

    /// @notice Aggregate interest (real uAsset + GenesisCredit) a user paid into a verse's leveraged genesis.
    /// @param verseId Verse identifier.
    /// @param user Participant address.
    /// @return Combined real-uAsset and credit interest paid by the user.
    function leveragedInterestPaid(uint256 verseId, address user) external view returns (uint256) {
        // View-layer aggregate (real + credit) per docs/spec/polend/core.md: storage is split,
        // but the public view exposes the combined interest the user paid, matching
        // `getUserLeveragedDebt`'s aggregate accounting. The real-only ledger is internal.
        return polendStorage.leveragedInterestPaid[verseId][user] + polendStorage.creditInterestPaid[verseId][user];
    }

    /// @notice Post-settlement residual assets claimable pro-rata by leveraged participants.
    /// @param verseId Settled verse identifier.
    /// @return residualUAsset Recovered uAsset left after repaying debt.
    /// @return residualMemecoin Recovered memecoin left after settlement.
    function residualStates(uint256 verseId) external view returns (uint256 residualUAsset, uint256 residualMemecoin) {
        ResidualState storage r = polendStorage.residualStates[verseId];
        residualUAsset = r.residualUAsset;
        residualMemecoin = r.residualMemecoin;
    }

    /// @notice Aggregate outstanding uAsset debt across all settled/live verses for one uAsset.
    /// @param uAsset Universal-asset address.
    /// @return Total uAsset debt currently accounted under this uAsset.
    function globalDebtByUAsset(address uAsset) external view returns (uint256) {
        return polendStorage.globalDebtByUAsset[uAsset];
    }

    /// @notice Settlement-dust reserve configuration for a uAsset.
    /// @param uAsset Universal-asset address.
    /// @return reserve Current funded reserve covering settlement deficits.
    /// @return maxReserve Configured cap on the reserve.
    function settlementDustStates(address uAsset) external view returns (uint128 reserve, uint128 maxReserve) {
        SettlementDustState storage state = polendStorage.settlementDustStates[uAsset];
        return (state.reserve, state.maxReserve);
    }

    // --- External view helpers ---

    /// @notice Total leveraged debt owed by a verse (totalLeveragedInterest / interestRate).
    /// @param verseId Verse identifier.
    /// @return Computed leveraged debt for the verse.
    function getTotalLeveragedDebt(uint256 verseId) external view returns (uint256) {
        return _totalLeveragedDebt(polendStorage.lendMarkets[verseId]);
    }

    /// @notice A user's pro-rata share of a verse's leveraged debt (real + credit interest aggregated).
    /// @param verseId Verse identifier.
    /// @param user Participant address (must not be zero).
    /// @return Debt attributable to the user's combined paid interest.
    function getUserLeveragedDebt(uint256 verseId, address user) external view returns (uint256) {
        if (user == address(0)) revert ZeroInput();

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.interestRate == 0) revert InvalidState();
        // Aggregate debt: real leveraged genesis + credit-factory-issued interest share the
        // same interestRate, so we sum interest paid before converting to debt.
        uint256 totalInterest =
            polendStorage.leveragedInterestPaid[verseId][user] + polendStorage.creditInterestPaid[verseId][user];
        return Math.mulDiv(totalInterest, 1e18, market.interestRate);
    }

    /// @notice Alias for `globalDebtByUAsset` with an explicit zero-address guard.
    /// @param uAsset Universal-asset address (must not be zero).
    /// @return Total uAsset debt currently accounted under this uAsset.
    function getTotalDebtByUAsset(address uAsset) external view returns (uint256) {
        if (uAsset == address(0)) revert ZeroInput();
        return polendStorage.globalDebtByUAsset[uAsset];
    }

    /// @notice Consolidated leveraged-debt snapshot for a verse: totals, rate, and remaining capacity.
    /// @param verseId Verse identifier.
    /// @return info LeveragedDebtInfo struct with current debt and headroom figures.
    function getLeveragedDebtInfo(uint256 verseId) external view returns (LeveragedDebtInfo memory info) {
        LendMarket storage market = polendStorage.lendMarkets[verseId];
        if (market.interestRate == 0) revert InvalidState();

        info.totalLeveragedInterest = market.totalLeveragedInterest;
        info.totalLeveragedDebt = _totalLeveragedDebt(market);
        info.interestRate = market.interestRate;
        (info.debtCap, info.remainingAdditionalInterest) = _debtCapacity(verseId, market);
    }

    /// @notice Total interest (real uAsset + GenesisCredit combined) paid into a verse's leveraged genesis.
    /// @param verseId Verse identifier.
    /// @return Aggregate interest backing the verse's leveraged debt.
    function getTotalLeveragedInterest(uint256 verseId) external view returns (uint256) {
        return polendStorage.lendMarkets[verseId].totalLeveragedInterest;
    }

    /// @notice GenesisCredit-funded slice of a verse's total leveraged interest.
    /// @param verseId Verse identifier.
    /// @return Total credit interest paid into the verse.
    function getTotalCreditInterest(uint256 verseId) external view returns (uint256) {
        return polendStorage.lendMarkets[verseId].totalCreditInterest;
    }

    /// @notice Convenience wrapper returning the full lend-market snapshot for a verse.
    /// @param verseId Verse identifier.
    /// @return market LendMarket struct copy for the verse.
    function getLendMarket(uint256 verseId) external view returns (LendMarket memory market) {
        return polendStorage.lendMarkets[verseId];
    }

    // --- Internal ---

    function _totalLeveragedDebt(LendMarket storage market) internal view returns (uint256) {
        if (market.interestRate == 0) revert InvalidState();
        return Math.mulDiv(market.totalLeveragedInterest, 1e18, market.interestRate);
    }

    function _debtCapacity(uint256 verseId, LendMarket storage market)
        internal
        view
        returns (uint256 debtCap, uint256 remainingAdditionalInterest)
    {
        if (market.state != MarketState.None && market.state != MarketState.Genesis) return (0, 0);
        if (polendStorage.settlementDustStates[market.uAsset].maxReserve == 0) return (0, 0);
        if (IMemeverseLauncher(polendStorage.launcher).getStageByVerseId(verseId) != IMemeverseLauncher.Stage.Genesis) {
            return (0, 0);
        }

        debtCap = _debtCap(verseId);
        uint256 actualNormalFunds = IMemeverseLauncher(polendStorage.launcher).totalNormalFunds(verseId);
        if (actualNormalFunds >= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) return (0, 0);
        uint256 aggregateDebtCap = MAX_SUPPORTED_TOTAL_GENESIS_FUNDS - actualNormalFunds;
        if (debtCap > aggregateDebtCap) debtCap = aggregateDebtCap;
        uint256 maxTotalInterest;
        if (debtCap == type(uint256).max) {
            uint256 q = type(uint256).max / 1e18;
            uint256 r = type(uint256).max % 1e18;
            maxTotalInterest =
                q * market.interestRate + Math.mulDiv(r + 1, market.interestRate, 1e18, Math.Rounding.Ceil) - 1;
        } else {
            maxTotalInterest = Math.mulDiv(debtCap + 1, market.interestRate, 1e18, Math.Rounding.Ceil) - 1;
        }
        uint256 totalInterest = market.totalLeveragedInterest;
        if (maxTotalInterest > totalInterest) remainingAdditionalInterest = maxTotalInterest - totalInterest;
    }

    function _validateLeverageConfig(uint256 interestRate, uint256 debtFactor) internal pure {
        if (debtFactor == 0) revert ZeroInput();
        if (debtFactor > MAX_LEVERAGED_DEBT_FACTOR) revert InvalidConfig();

        uint256 minDebtFactor = Math.mulDiv(MIN_LEVERAGED_DEBT_PRODUCT, 1, interestRate, Math.Rounding.Ceil);
        if (debtFactor < minDebtFactor) revert InvalidConfig();
    }

    function _debtCap(uint256 verseId) internal view returns (uint256) {
        uint256 capBase = IMemeverseLauncher(polendStorage.launcher).getDebtCapBaseByVerseId(verseId);
        return _mulDiv1e18Saturating(polendStorage.leveragedDebtFactor, capBase);
    }

    function _mulDiv1e18Saturating(uint256 a, uint256 b) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Saturate when floor(a * b / 1e18) would be >= type(uint256).max.
            // (2^256 - 1) * 1e18 = (1e18 - 1) * 2^256 + (2^256 - 1e18)
            if (prod1 > 1e18 - 1) return type(uint256).max;
            if (prod1 == 1e18 - 1 && prod0 >= type(uint256).max - (1e18 - 1)) return type(uint256).max;

            return Math.mulDiv(a, b, 1e18);
        }
    }

    function _consumeClaimFlag(uint256 verseId, address account, uint8 mask) internal {
        uint8 flags = polendStorage.claimFlags[verseId][account];
        if (flags & mask != 0) revert InvalidClaim();
        polendStorage.claimFlags[verseId][account] = flags | mask;
    }

    function _burnSettledPol(uint256 verseId, uint256 polAmount)
        internal
        returns (uint256 uAssetAmount, uint256 memecoinAmount)
    {
        if (polAmount == 0) return (0, 0);

        LendMarket storage market = polendStorage.lendMarkets[verseId];
        (address pol, address memecoin) = IPOLSplitter(polendStorage.splitter).getPOLAndMemecoin(verseId);
        uint256 beforeUAsset = IERC20(market.uAsset).balanceOf(address(this));
        uint256 beforeMemecoin = IERC20(memecoin).balanceOf(address(this));

        IERC20(pol).approve(polendStorage.launcher, polAmount);
        IMemeverseLauncher(polendStorage.launcher).redeemMemecoinLiquidity(verseId, polAmount, true);

        uAssetAmount = IERC20(market.uAsset).balanceOf(address(this)) - beforeUAsset;
        memecoinAmount = IERC20(memecoin).balanceOf(address(this)) - beforeMemecoin;
    }

    /// @notice Pause leveraged-genesis entry (onlyOwner). Blocks `leveragedGenesis` and
    ///         `leveragedGenesisWithCredit` via `whenNotPaused`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause leveraged-genesis entry (onlyOwner). Re-enables `leveragedGenesis` and
    ///         `leveragedGenesisWithCredit`.
    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
