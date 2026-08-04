// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLend} from "../../src/polend/POLend.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {BurnableMockERC20} from "../mocks/polend/POLendMocks.sol";
import {MockGenesisCreditFactory} from "../mocks/credit/MockGenesisCreditFactory.sol";

/// @notice Minimal launcher mock for the credit-accounting invariant. Only the launcher surface
///         POLend reads during the credit lifecycle is implemented (genesis funds, uAsset lookup,
///         debt-cap base, stage). The stage is pinned to Genesis: POLend's own market state machine
///         (None -> Genesis -> Locked/Refund) gates re-entry, so the launcher stage never needs to
///         advance for these accounting invariants.
contract InvariantLauncher {
    mapping(uint256 => address) internal _uAssets;
    mapping(uint256 => uint256) internal _normalFunds;
    mapping(address => uint256) internal _minTotalFunds;

    function setVerseUAsset(uint256 verseId, address uAsset) external {
        _uAssets[verseId] = uAsset;
    }

    function setGenesisFunds(uint256 verseId, uint256 amount) external {
        _normalFunds[verseId] = amount;
    }

    function setMinTotalFund(address uAsset, uint256 min) external {
        _minTotalFunds[uAsset] = min;
    }

    function totalNormalFunds(uint256 verseId) external view returns (uint256) {
        return _normalFunds[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return _uAssets[verseId];
    }

    function getStageByVerseId(uint256) external pure returns (IMemeverseLauncher.Stage) {
        return IMemeverseLauncher.Stage.Genesis;
    }

    function getDebtCapBaseByVerseId(uint256 verseId) external view returns (uint256) {
        address u = _uAssets[verseId];
        uint256 funds = _normalFunds[verseId];
        uint256 min = _minTotalFunds[u];
        return funds > min ? funds : min;
    }

    // --- Settlement surface (Tier 2) ---
    // POLend calls settleLeveragedAuxiliaryLiquidity during executeGlobalSettlement. The handler
    // pre-loads the uAsset amount to mint to POLend (debt + a fuzzed residual) so recovered uAsset
    // always covers debt — no dust-reserve shortfall — and leaves the chosen residual for
    // claimResidual. polAmount=ptAmount=0 skips the POL/splitter paths this mock does not model.
    BurnableMockERC20 internal _uAsset;
    address internal _polend;
    uint256 public pendingSettlementLpUAsset;

    function setDependencies(address uAsset_, address polend_) external {
        _uAsset = BurnableMockERC20(uAsset_);
        _polend = polend_;
    }

    function setSettlementLpUAsset(uint256 amount) external {
        pendingSettlementLpUAsset = amount;
    }

    function settleLeveragedAuxiliaryLiquidity(
        uint256 /*verseId */
    )
        external
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        polAmount = 0;
        ptAmount = 0;
        uAssetAmount = pendingSettlementLpUAsset;
        if (uAssetAmount != 0) _uAsset.mint(_polend, uAssetAmount);
    }
}

/// @notice Stateful invariant handler exercising mixed-pool credit accounting across two verses
///         that share one uAsset (and therefore one GenesisCredit token). The fuzzer drives a random
///         sequence of credit/real interest participation, finalize, and refund calls; the
///         `invariant_*` functions in `GenesisCreditInvariants` assert INV-21 after every call.
/// @dev One actor per verse keeps per-user credit interest equal to the verse's market total, so the
///      escrow-vs-outstanding accounting stays tight at every transition. All reverting paths (debt
///      cap, double claim, empty ledgers) are swallowed by try/catch so a skipped call never breaks
///      the run; the invariant is re-asserted after every handler call regardless.
contract CreditAccountingHandler is Test {
    uint256 internal constant VERSE_A = 1;
    uint256 internal constant VERSE_B = 2;
    address internal constant ACTOR_A = address(0xA1);
    address internal constant ACTOR_B = address(0xB1);
    address internal constant REC_A = address(0xA2);
    address internal constant REC_B = address(0xB2);

    BurnableMockERC20 internal uAsset;
    BurnableMockERC20 internal credit;
    // Both verses share one YT instance, mirroring the shared uAsset/credit pool; the YT conservation
    // invariant must therefore hold globally across verses, not per-verse.
    BurnableMockERC20 internal yt;
    InvariantLauncher internal launcher;
    MockGenesisCreditFactory internal factory;
    POLend internal polend;

    // Ghost counter incremented on each successful claimLeveragedYT. The canary test
    // (test_ClaimLifecycleReachable) uses it to prove the Locked->claim lifecycle is reachable
    // through the handler, so a future guard regression cannot silently make the fuzz invariants
    // vacuous (asserting 0==0) the way the original None-state deadlock did.
    uint256 public successfulYTClaims;

    // Tier-2 ghosts: residual-claim counters for the Settled-state claim invariant.
    uint256 public successfulResidualClaims;
    uint256 public totalResidualClaimedUAsset;

    constructor() {
        uAsset = new BurnableMockERC20("UASSET", "UASSET");
        credit = new BurnableMockERC20("CREDIT", "CREDIT");
        yt = new BurnableMockERC20("YT", "YT");
        launcher = new InvariantLauncher();
        factory = new MockGenesisCreditFactory();
        factory.setCreditOf(address(uAsset), address(credit));

        // interestRate 0.1e18 => debt = interest * 10; leveragedDebtFactor 10e18.
        polend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(factory));
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(1e9));
        launcher.setDependencies(address(uAsset), address(polend));

        // Two verses share the SAME uAsset => one shared GenesisCredit token (mixed pool).
        launcher.setVerseUAsset(VERSE_A, address(uAsset));
        launcher.setVerseUAsset(VERSE_B, address(uAsset));
        launcher.setMinTotalFund(address(uAsset), 1_000 ether);
        launcher.setGenesisFunds(VERSE_A, 0);
        launcher.setGenesisFunds(VERSE_B, 0);

        vm.prank(address(launcher));
        polend.registerLendMarket(VERSE_A);
        vm.prank(address(launcher));
        polend.registerLendMarket(VERSE_B);
    }

    function _deployPOLend(
        uint256 interestRate,
        uint256 leveragedDebtFactor,
        address treasury,
        address launcher_,
        address creditFactory_
    ) internal returns (POLend) {
        POLend impl = new POLend();
        // Splitter is never exercised by the credit lifecycle (no settlement); a non-zero placeholder
        // satisfies initialize's address(0) validation.
        bytes memory data = abi.encodeCall(
            POLend.initialize,
            (address(this), interestRate, leveragedDebtFactor, treasury, launcher_, address(this), creditFactory_)
        );
        return POLend(address(new ERC1967Proxy(address(impl), data)));
    }

    // --- Fuzzer entry points (called in random order) ---

    /// @dev Add GenesisCredit interest to a fuzzed verse. Allow None OR Genesis: the production
    ///      guard (POLend.sol:207) accepts both and transitions None->Genesis on first call, so a
    ///      Genesis-only filter here would freeze both verses at None and make the whole lifecycle
    ///      (finalize/recordYT/claimYT) unreachable — the invariant would run vacuously.
    ///      Skips once the verse left Genesis (Locked/Refund/Settled); swallows debt-cap reverts.
    function addCreditInterest(uint256 verseSeed, uint256 amountSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        IPOLend.MarketState state_ = polend.getLendMarket(verseId).state;
        if (state_ != IPOLend.MarketState.None && state_ != IPOLend.MarketState.Genesis) return;
        address actor = (verseId == VERSE_A) ? ACTOR_A : ACTOR_B;
        uint256 amount = bound(amountSeed, 1, 50 ether);
        credit.mint(actor, amount);
        vm.prank(actor);
        credit.approve(address(polend), amount);
        vm.prank(actor);
        try polend.leveragedGenesisWithCredit(verseId, amount) {} catch {}
    }

    /// @dev Add real-uAsset leveraged interest to a fuzzed verse. Same None||Genesis guard as
    ///      addCreditInterest (POLend.sol:170 accepts both, transitions None->Genesis); skips once
    ///      the verse left Genesis. try/catch absorbs debt-cap reverts so the run continues.
    function addRealInterest(uint256 verseSeed, uint256 amountSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        IPOLend.MarketState state_ = polend.getLendMarket(verseId).state;
        if (state_ != IPOLend.MarketState.None && state_ != IPOLend.MarketState.Genesis) return;
        address actor = (verseId == VERSE_A) ? ACTOR_A : ACTOR_B;
        uint256 amount = bound(amountSeed, 1, 50 ether);
        uAsset.mint(actor, amount);
        vm.prank(actor);
        uAsset.approve(address(polend), amount);
        vm.prank(actor);
        try polend.leveragedGenesis(verseId, amount) {} catch {}
    }

    /// @dev Finalize a fuzzed verse (Genesis -> Locked), burning its totalCreditInterest. Skips if
    ///      not in Genesis or if no debt has accrued (finalize reverts on zero debt).
    function finalizeVerse(uint256 verseSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        if (polend.getLendMarket(verseId).state != IPOLend.MarketState.Genesis) return;
        if (polend.getTotalLeveragedDebt(verseId) == 0) return;
        vm.prank(address(launcher));
        try polend.finalizeLeveragedGenesis(verseId) {} catch {}
    }

    /// @dev Transition a fuzzed verse to Refund (if still Genesis) and refund the actor's credit.
    ///      markRefundable is guarded to Genesis so it cannot revert; claimRefund is try/caught to
    ///      absorb double-claim or empty-ledger reverts.
    function refundVerse(uint256 verseSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        address actor = (verseId == VERSE_A) ? ACTOR_A : ACTOR_B;
        address recipient = (verseId == VERSE_A) ? REC_A : REC_B;
        IPOLend.MarketState state = polend.getLendMarket(verseId).state;
        if (state == IPOLend.MarketState.Genesis) {
            vm.prank(address(launcher));
            try polend.markRefundable(verseId) {
                state = IPOLend.MarketState.Refund;
            } catch {}
        }
        if (state == IPOLend.MarketState.Refund) {
            vm.prank(actor);
            try polend.claimRefund(verseId, recipient) {} catch {}
        }
    }

    /// @dev Record the leveraged YT token on a fuzzed verse (Locked only, onlyLauncher). Skips
    ///      unless the verse is Locked and YT is unrecorded, so each verse records at most once and
    ///      never trips recordLeveragedYT's InvalidState guard. YT is minted to POLend upfront so
    ///      claimLeveragedYT's safeTransfer has inventory to draw from.
    function recordYT(uint256 verseSeed, uint256 ytSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        if (polend.getLendMarket(verseId).state != IPOLend.MarketState.Locked) return;
        if (polend.getLendMarket(verseId).yt != address(0)) return;
        uint256 total = bound(ytSeed, 1, 200 ether);
        yt.mint(address(polend), total);
        vm.prank(address(launcher));
        try polend.recordLeveragedYT(verseId, address(yt), total) {} catch {}
    }

    /// @dev Claim leveraged YT on a fuzzed verse to the actor's recipient (Locked/Settled). Skips
    ///      if YT has not been recorded. try/catch absorbs double-claim (already-consumed flag),
    ///      no-interest (interestPaid == 0), and empty-ledger reverts so the run continues.
    function claimYT(uint256 verseSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        address actor = (verseId == VERSE_A) ? ACTOR_A : ACTOR_B;
        address recipient = (verseId == VERSE_A) ? REC_A : REC_B;
        if (polend.getLendMarket(verseId).yt == address(0)) return;
        vm.prank(actor);
        try polend.claimLeveragedYT(verseId, recipient) {
            successfulYTClaims++;
        } catch {}
    }

    /// @dev Settle a fuzzed verse (Locked -> Settled). The launcher mock mints debt + a fuzzed
    ///      residual of uAsset to POLend during the call, so recovered uAsset always covers debt
    ///      (no dust-reserve shortfall) and leaves the chosen residual for claimResidual.
    ///      polAmount=ptAmount=0 skips the POL/splitter paths this mock does not model. try/catch
    ///      swallows any revert so the run continues.
    function settleVerse(uint256 verseSeed, uint256 residualSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        if (polend.getLendMarket(verseId).state != IPOLend.MarketState.Locked) return;
        uint256 debt = polend.getTotalLeveragedDebt(verseId);
        if (debt == 0) return;
        uint256 residual = bound(residualSeed, 0, 100 ether);
        launcher.setSettlementLpUAsset(debt + residual);
        vm.prank(address(launcher));
        try polend.executeGlobalSettlement(verseId) {} catch {}
    }

    /// @dev Claim the settlement residual on a fuzzed verse (Settled only) to the actor's recipient.
    ///      try/catch absorbs double-claim, non-participant (interestPaid == 0), and empty-residual
    ///      reverts. On success the returned uAsset amount is accumulated for the residual-bounded
    ///      invariant.
    function claimResidual(uint256 verseSeed) external {
        uint256 verseId = (verseSeed % 2 == 0) ? VERSE_A : VERSE_B;
        if (polend.getLendMarket(verseId).state != IPOLend.MarketState.Settled) return;
        address actor = (verseId == VERSE_A) ? ACTOR_A : ACTOR_B;
        address recipient = (verseId == VERSE_A) ? REC_A : REC_B;
        vm.prank(actor);
        try polend.claimResidual(verseId, recipient) returns (uint256 uAssetAmount, uint256) {
            successfulResidualClaims++;
            totalResidualClaimedUAsset += uAssetAmount;
        } catch {}
    }

    // --- Invariant view helpers ---

    /// @dev Σ totalCreditInterest over verses still in Genesis (un-finalized, un-refunded). These
    ///      are the verses whose escrowed credit has not yet been burned or returned, i.e. the
    ///      outstanding credit debt the escrow must cover.
    function outstandingCreditInterest() public view returns (uint256) {
        uint256 sum;
        if (polend.getLendMarket(VERSE_A).state == IPOLend.MarketState.Genesis) {
            sum += polend.getTotalCreditInterest(VERSE_A);
        }
        if (polend.getLendMarket(VERSE_B).state == IPOLend.MarketState.Genesis) {
            sum += polend.getTotalCreditInterest(VERSE_B);
        }
        return sum;
    }

    function creditEscrowBalance() public view returns (uint256) {
        return credit.balanceOf(address(polend));
    }

    /// @dev Global YT conservation for the shared YT instance: POLend's escrow plus the two
    ///      recipients' claimed balances must equal Σ totalLeveragedYT over recorded verses. Both
    ///      verses share one YT token, so the equation is global — per-verse balances would
    ///      cross-contaminate. Returns (held, expected) for the invariant to assert strictly.
    function ytConservation() public view returns (uint256 held, uint256 expected) {
        held = yt.balanceOf(address(polend)) + yt.balanceOf(REC_A) + yt.balanceOf(REC_B);
        if (polend.getLendMarket(VERSE_A).yt != address(0)) {
            expected += polend.getLendMarket(VERSE_A).totalLeveragedYT;
        }
        if (polend.getLendMarket(VERSE_B).yt != address(0)) {
            expected += polend.getLendMarket(VERSE_B).totalLeveragedYT;
        }
    }

    /// @dev globalDebtByUAsset must equal Σ debt of verses currently in Locked. finalize adds the
    ///      verse's debt on Genesis->Locked; executeGlobalSettlement subtracts it on Locked->Settled.
    ///      No handler path mutates globalDebtByUAsset outside those two, so the equality is strict.
    function globalDebtByUAsset() public view returns (uint256) {
        return polend.getTotalDebtByUAsset(address(uAsset));
    }

    function sumLockedDebt() public view returns (uint256 sum) {
        if (polend.getLendMarket(VERSE_A).state == IPOLend.MarketState.Locked) {
            sum += polend.getTotalLeveragedDebt(VERSE_A);
        }
        if (polend.getLendMarket(VERSE_B).state == IPOLend.MarketState.Locked) {
            sum += polend.getTotalLeveragedDebt(VERSE_B);
        }
    }

    /// @dev Σ residualUAsset over Settled verses. residualStates is set at settlement and not
    ///      decremented by claim, so this is the constant upper bound for claimed residual.
    function sumSettledResidualUAsset() public view returns (uint256 sum) {
        if (polend.getLendMarket(VERSE_A).state == IPOLend.MarketState.Settled) {
            (uint256 r,) = polend.residualStates(VERSE_A);
            sum += r;
        }
        if (polend.getLendMarket(VERSE_B).state == IPOLend.MarketState.Settled) {
            (uint256 r,) = polend.residualStates(VERSE_B);
            sum += r;
        }
    }

    function totalLeveragedA() external view returns (uint256) {
        return polend.getTotalLeveragedInterest(VERSE_A);
    }

    function totalCreditA() external view returns (uint256) {
        return polend.getTotalCreditInterest(VERSE_A);
    }

    function totalLeveragedB() external view returns (uint256) {
        return polend.getTotalLeveragedInterest(VERSE_B);
    }

    function totalCreditB() external view returns (uint256) {
        return polend.getTotalCreditInterest(VERSE_B);
    }
}

/// @notice INV-21 credit-accounting invariants for the mixed-pool GenesisCredit path. Asserted
///         after every fuzzer-driven handler call on the two-verse shared-uAsset pool.
contract GenesisCreditInvariants is StdInvariant, Test {
    CreditAccountingHandler internal handler;

    function setUp() external {
        handler = new CreditAccountingHandler();
        targetContract(address(handler));
    }

    /// @dev POLend's escrowed GenesisCredit balance for the shared uAsset must always cover the
    ///      total credit interest still outstanding (verses in Genesis). Finalize burns a verse's
    ///      share and refund returns it, so both sides move in lockstep; the `>=` admits the excess
    ///      where a Refund verse's credit is still escrowed pending claim.
    function invariant_POLendCreditEscrowCoversOutstanding() external view {
        assertGe(handler.creditEscrowBalance(), handler.outstandingCreditInterest(), "escrow covers outstanding credit");
    }

    /// @dev Per verse, the aggregate leveraged interest (real + credit) must be >= the credit
    ///      sub-accumulator. A break would underflow the realInterest derivation in finalize
    ///      (`totalLeveragedInterest - totalCreditInterest`) and corrupt reserve/treasury/burn math.
    function invariant_TotalLeveragedInterestGeTotalCredit() external view {
        assertGe(handler.totalLeveragedA(), handler.totalCreditA(), "verse A: leveraged >= credit");
        assertGe(handler.totalLeveragedB(), handler.totalCreditB(), "verse B: leveraged >= credit");
    }

    /// @dev Canary proving the Locked->claim lifecycle is reachable end-to-end through the handler.
    ///      Guards against a repeat of the vacuity regression (genesis-entry guards freezing the
    ///      market at None). If this stops passing, the fuzz invariants are asserting 0==0.
    function test_ClaimLifecycleReachable() external {
        handler.addRealInterest(0, 10 ether); // VERSE_A, ACTOR_A participates with 10 real uAsset
        handler.finalizeVerse(0); // Genesis -> Locked
        handler.recordYT(0, 100 ether); // launcher records 100 YT on VERSE_A
        handler.claimYT(0); // ACTOR_A claims YT to REC_A
        assertGt(handler.successfulYTClaims(), 0, "happy-path claim must succeed");
        // Conservation holds on the happy path: 100 YT recorded, all claimed to REC_A, polend holds 0.
        (uint256 held, uint256 expected) = handler.ytConservation();
        assertGt(expected, 0, "YT recorded on happy path");
        assertEq(held, expected, "YT conserved on happy path");
    }

    /// @dev Leveraged YT is conserved globally across the shared-YT mixed pool: POLend's unclaimed
    ///      escrow plus the two recipients' claimed balances equals Σ totalLeveragedYT over recorded
    ///      verses. Strict equality (not >=): in this handler no YT enters or leaves the
    ///      {polend, REC_A, REC_B} set, so a break signals out-of-band mint/burn/transfer or a
    ///      claimLeveragedYT split-accounting bug.
    function invariant_LeveragedYTSplitConserved() external view {
        (uint256 held, uint256 expected) = handler.ytConservation();
        assertEq(held, expected, "YT split conserved");
    }

    /// @dev globalDebtByUAsset(uAsset) == Σ debt of Locked verses. finalizeLeveragedGenesis adds the
    ///      verse's debt on Genesis->Locked; executeGlobalSettlement subtracts it on Locked->Settled.
    ///      No handler path touches globalDebtByUAsset outside those two transitions, so strict.
    function invariant_GlobalDebtByUAssetConserved() external view {
        assertEq(handler.globalDebtByUAsset(), handler.sumLockedDebt(), "globalDebt == sum Locked debt");
    }

    /// @dev Claimed residual uAsset never exceeds the total residual recorded at settlement. mulDiv
    ///      rounds down and the per-actor claimFlag prevents replay, so Σ claimed <= residual; a flag
    ///      bypass would push it over. One-sided (assertLe) because rounding leaves dust unclaimed.
    function invariant_ResidualClaimBounded() external view {
        assertLe(
            handler.totalResidualClaimedUAsset(),
            handler.sumSettledResidualUAsset(),
            "claimed residual <= settled residual"
        );
    }

    /// @dev Canary proving the Locked->Settled->claimResidual lifecycle is reachable end-to-end
    ///      through the handler, and that globalDebtByUAsset tracks the finalize/settle transitions
    ///      non-trivially. Guards against a repeat of the vacuity regression.
    function test_SettlementLifecycleReachable() external {
        handler.addRealInterest(0, 10 ether); // VERSE_A participates with 10 real uAsset
        handler.addRealInterest(1, 20 ether); // VERSE_B participates with 20 real uAsset
        handler.finalizeVerse(0); // A: Genesis -> Locked
        handler.finalizeVerse(1); // B: Genesis -> Locked
        // Both verses Locked: globalDebt == A.debt + B.debt, and non-zero.
        assertEq(handler.globalDebtByUAsset(), handler.sumLockedDebt(), "debt after finalize");
        assertGt(handler.globalDebtByUAsset(), 0, "non-trivial debt after finalize");
        handler.settleVerse(0, 5 ether); // A: Locked -> Settled, residual 5 uAsset
        // Only B remains Locked: globalDebt == B.debt.
        assertEq(handler.globalDebtByUAsset(), handler.sumLockedDebt(), "debt after settle A");
        handler.claimResidual(0); // A claims residual to REC_A
        assertGt(handler.successfulResidualClaims(), 0, "settlement happy-path claim must succeed");
        // Bound holds on the happy path (deterministic, seed-independent): sole claimant A receives
        // the full 5 uAsset residual, so claimed == settled residual.
        assertLe(
            handler.totalResidualClaimedUAsset(), handler.sumSettledResidualUAsset(), "residual bound on happy path"
        );
    }
}
