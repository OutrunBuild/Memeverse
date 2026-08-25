// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// POLend settlement-reserve and credit-path coverage that the existing POLend.t.sol does not provide:
// (a) a sequence-level reserve monotonicity fuzz (existing tests cover each reserve branch pointwise),
// (b) a mixed real+credit genesis fuzz against the split-ledger credit accounting (existing tests are
//     pure-real / pure-credit / cache-lock cases),
// (c) a two-verse shared-reserve consumption test, and
// (d) mid-revert settle tests asserting the reserve and custody balances that the settlement writes
//     before the failing leg (existing tests assert only debt and market state).

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLendUpgradeable} from "../../src/polend/POLendUpgradeable.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";

import {BurnableMockERC20, MintableToken} from "../mocks/polend/POLendMocks.sol";
import {MockGenesisCreditFactory} from "../mocks/credit/MockGenesisCreditFactory.sol";
import {POLendStorageHelper} from "../mocks/polend/POLendStorageHelper.sol";
import {SettlementResultLauncher} from "../mocks/polend/POLendReserveMocks.sol";

/// @notice Shared fixture: registers three verses on the SAME uAsset so the global (per-uAsset)
///         settlement dust reserve is shared across verses.
abstract contract POLendSharedReserveFixture is Test, POLendStorageHelper {
    uint256 internal constant VERSE_A = 1;
    uint256 internal constant VERSE_B = 2;
    uint256 internal constant VERSE_C = 3;
    uint256 internal constant RESERVE_CAP = 10 ether;
    uint256 internal constant DEBT_PER_VERSE = 100 ether;
    address internal constant ALICE = address(0xB0B);

    BurnableMockERC20 internal uAsset;
    MintableToken internal yt;
    SettlementResultLauncher internal launcher;
    POLendUpgradeable internal polend;

    // Verse-level settlement deficits: each verse recovers DEBT - deficit_i and consumes deficit_i
    // from the shared reserve.
    uint256[3] internal deficits = [1 ether, 2 ether, 3 ether];

    /// @dev globalDebtByUAsset is a per-uAsset GLOBAL ledger shared by all verses, so seeding must
    ///      accumulate per settled verse instead of overwriting per verse.
    uint256 internal seededGlobalDebt;

    function setUp() public virtual {
        uAsset = new BurnableMockERC20("UASSET", "UASSET");
        yt = new MintableToken("YT", "YT");
        launcher = new SettlementResultLauncher();

        POLendUpgradeable implementation = new POLendUpgradeable();
        // The splitter is never reached in these tests: every settlement reports ptAmount = 0, so the
        // stub address only has to be non-zero for the initialize validation.
        bytes memory initData = abi.encodeCall(
            POLendUpgradeable.initialize,
            (
                address(this),
                1e17, // interestRate
                10e18, // leveragedDebtFactor
                address(this), // protocolTreasury
                address(launcher),
                address(0xD12), // polSplitter stub
                address(this) // creditFactory (replaced per-test)
            )
        );
        polend = POLendUpgradeable(address(new ERC1967Proxy(address(implementation), initData)));

        uAsset.mint(address(this), 1_000_000 ether);
        uAsset.approve(address(polend), type(uint256).max);
        uAsset.mint(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), type(uint256).max);
        // The launcher-excess funding op pulls uAsset from the launcher mock, so it needs its own
        // effectively-unbounded balance and allowance (each over-fund permanently moves tokens out,
        // so a cap-sized mint would starve the op after a few calls per run).
        uAsset.mint(address(launcher), 1e30);
        vm.prank(address(launcher));
        uAsset.approve(address(polend), type(uint256).max);

        polend.setMaxSettlementDustReserve(address(uAsset), uint128(RESERVE_CAP));

        _registerVerse(VERSE_A);
        _registerVerse(VERSE_B);
        _registerVerse(VERSE_C);
    }

    function _registerVerse(uint256 verseId) internal {
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 1_000 ether);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        vm.prank(address(launcher));
        polend.registerLendMarket(verseId);
    }

    /// @notice Drives a verse into the Locked state with a fixed debt and recovered amount such that
    ///         settlement consumes `deficit` from the shared reserve.
    function _seedVerseForSettlement(uint256 verseId, uint256 deficit) internal {
        seedMarketForTest(address(polend), verseId, address(yt), 10 ether);
        setLockedStateForTest(address(polend), verseId, 0);
        seededGlobalDebt += DEBT_PER_VERSE;
        seedGlobalDebtForTest(address(polend), address(uAsset), seededGlobalDebt);
        launcher.setSettlementResult(verseId, DEBT_PER_VERSE - deficit);
        uAsset.mint(address(polend), DEBT_PER_VERSE - deficit);
    }

    function _reserve() internal view returns (uint128 reserve) {
        (reserve,) = polend.settlementDustStates(address(uAsset));
    }

    /// @notice Funds the reserve through the real entrypoint so POLend custody actually holds the
    ///         deficit tokens that settlement repays (a storage-seeded reserve has no tokens behind it
    ///         and makes the later `uAsset.repay` burn underflow).
    function _fundReserve(uint256 amount) internal {
        polend.fundSettlementDustReserve(address(uAsset), amount);
    }
}

// ---------------------------------------------------------------------------
// 1. Reserve sequence: the reserve is a one-way pool across interleaved fund/settle ops.
// ---------------------------------------------------------------------------

/// @notice Handler that interleaves reserve funding (anyone / launcher-excess) with per-verse
///         settlements, asserting the directional rules inline after every op.
contract POLendReserveSequenceHandler is Test {
    POLendUpgradeable public polend;
    BurnableMockERC20 public uAsset;
    address public launcher;
    address public funder;
    uint256 public reserveCap;

    /// @notice Verse index of the next unsettled verse (each verse settles exactly once).
    uint256 public nextVerseIndex;
    uint256[3] public verseIds;
    uint256[3] public verseDeficits;

    // Ghost ledgers for the sum-level invariants.
    uint256 public ghostCredited; // total ever credited into the reserve (seed + funds)
    uint256 public ghostConsumed; // total ever consumed by settlements
    uint256 public ghostSettlesExecuted; // settlements that actually ran (non-vacuity guard)

    constructor(
        POLendUpgradeable polend_,
        BurnableMockERC20 uAsset_,
        address launcher_,
        address funder_,
        uint256 reserveCap_,
        uint256[3] memory verseIds_,
        uint256[3] memory verseDeficits_,
        uint256 seededReserve
    ) {
        polend = polend_;
        uAsset = uAsset_;
        launcher = launcher_;
        funder = funder_;
        reserveCap = reserveCap_;
        verseIds = verseIds_;
        verseDeficits = verseDeficits_;
        ghostCredited = seededReserve;
    }

    /// @notice Anyone funds within remaining capacity: reserve grows by exactly `amount`.
    function fundWithinCapacity(uint256 amountSeed) external {
        uint128 reserveBefore = _reserve();
        if (reserveBefore >= reserveCap) return; // saturated: no capacity left to exercise
        uint256 amount = bound(amountSeed, 1, reserveCap - reserveBefore);

        vm.prank(funder);
        polend.fundSettlementDustReserve(address(uAsset), amount);

        assertEq(uint256(_reserve()), uint256(reserveBefore) + amount, "fund: reserve grows by amount");
        ghostCredited += amount;
    }

    /// @notice Launcher over-funds: credited is clipped to capacity, excess spills to treasury.
    /// @dev The bound floor is the remaining capacity, so the spill branch is always reached and the
    ///      saturation assertion below is valid over the whole input domain (at a saturated reserve the
    ///      floor collapses to 1 wei, a pure-spill call with credited == 0).
    function launcherOverFund(uint256 amountSeed) external {
        uint128 reserveBefore = _reserve();
        uint256 remainingCapacity = reserveCap - reserveBefore;
        uint256 amount = bound(amountSeed, remainingCapacity == 0 ? 1 : remainingCapacity, reserveCap);

        vm.prank(launcher);
        polend.fundSettlementDustReserve(address(uAsset), amount);

        uint256 credited = reserveCap - reserveBefore;
        assertEq(uint256(_reserve()), reserveCap, "over-fund: reserve saturates at cap");
        ghostCredited += credited;
    }

    /// @notice Settle the next verse: reserve falls by exactly that verse's deficit, once per verse.
    function settleNextVerse() external {
        if (nextVerseIndex >= verseIds.length) return;

        uint256 verseId = verseIds[nextVerseIndex];
        uint256 deficit = verseDeficits[nextVerseIndex];
        uint128 reserveBefore = _reserve();

        vm.prank(launcher);
        polend.executeGlobalSettlement(verseId);

        assertEq(uint256(_reserve()), uint256(reserveBefore) - deficit, "settle: reserve falls by deficit");
        assertEq(
            uint256(polend.getLendMarket(verseId).state),
            uint256(IPOLend.MarketState.Settled),
            "settle: market reaches Settled"
        );
        ghostConsumed += deficit;
        ghostSettlesExecuted++;
        nextVerseIndex++;
    }

    function _reserve() internal view returns (uint128 reserve) {
        (reserve,) = polend.settlementDustStates(address(uAsset));
    }
}

contract POLendReserveMonotonicityInvariants is POLendSharedReserveFixture {
    POLendReserveSequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Seed every verse for settlement and pre-fund the reserve with exactly the sum of deficits,
        // so every settle op succeeds and consumes its deficit.
        uint256[3] memory verseIds_ = [VERSE_A, VERSE_B, VERSE_C];
        for (uint256 i = 0; i < verseIds_.length; i++) {
            _seedVerseForSettlement(verseIds_[i], deficits[i]);
        }
        uint256 seededReserve = deficits[0] + deficits[1] + deficits[2];
        _fundReserve(seededReserve);

        handler = new POLendReserveSequenceHandler(
            polend, uAsset, address(launcher), ALICE, RESERVE_CAP, verseIds_, deficits, seededReserve
        );
        targetContract(address(handler));
    }

    /// @notice The reserve never exceeds its configured cap across any op sequence.
    function invariant_ReserveNeverExceedsCap() external view {
        assertLe(uint256(_reserve()), RESERVE_CAP, "reserve above cap");
    }

    /// @notice Sum-level conservation: settlements can never consume more than was ever credited.
    function invariant_ConsumedNeverExceedsCredited() external view {
        assertLe(handler.ghostConsumed(), handler.ghostCredited(), "consumed above credited");
    }

    /// @notice Non-vacuity guard: at least one settlement must actually execute per run, otherwise the
    ///         sum-level invariants above would pass on a run where every settle early-returned.
    function afterInvariant() external view {
        assertGt(handler.ghostSettlesExecuted(), 0, "no settlement executed in this run");
    }
}

// ---------------------------------------------------------------------------
// 2. Mixed real+credit genesis fuzz against the split-ledger credit accounting.
// ---------------------------------------------------------------------------

contract POLendMixedCreditPathFuzz is POLendSharedReserveFixture {
    address internal constant BOB = address(0xB0B00);
    address internal constant CAROL = address(0xCAFE);

    /// @notice Random real/credit split across two users; finalize must mint debt from the combined
    ///         interest, sweep only the real slice, and burn exactly the credit slice.
    function testFuzz_MixedRealAndCreditGenesis_FinalizeAccounting(uint128 realAmount, uint128 creditAmount) external {
        realAmount = uint128(bound(realAmount, 0, 50 ether));
        creditAmount = uint128(bound(creditAmount, 0, 50 ether));
        vm.assume(realAmount + creditAmount > 0);

        // Credit path: factory resolves a credit token for this uAsset; CAROL holds it.
        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        BurnableMockERC20 credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(uAsset), address(credit));
        polend.setCreditFactory(address(factory));
        credit.mint(CAROL, creditAmount);
        vm.prank(CAROL);
        credit.approve(address(polend), creditAmount);

        uAsset.mint(BOB, realAmount);
        vm.startPrank(BOB);
        uAsset.approve(address(polend), realAmount);
        if (realAmount > 0) {
            polend.leveragedGenesis(VERSE_A, realAmount);
        }
        vm.stopPrank();
        if (creditAmount > 0) {
            vm.prank(CAROL);
            polend.leveragedGenesisWithCredit(VERSE_A, creditAmount);
        }

        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        uint256 launcherBefore = uAsset.balanceOf(address(launcher)); // fixture also funds the launcher mock
        uint256 creditSupplyBefore = credit.totalSupply();

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_A);

        uint256 totalInterest = uint256(realAmount) + uint256(creditAmount);
        uint256 expectedDebt = (totalInterest * 1e18) / 1e17; // debt = interest * 1e18 / rate

        assertEq(polend.getTotalLeveragedInterest(VERSE_A), totalInterest, "combined interest ledger");
        assertEq(
            uAsset.balanceOf(address(launcher)) - launcherBefore, expectedDebt, "debt minted from combined interest"
        );
        assertEq(uAsset.balanceOf(address(this)) - treasuryBefore, realAmount, "only real slice swept");
        assertEq(credit.burnedAmount(), creditAmount, "credit slice burned");
        assertEq(credit.totalSupply(), creditSupplyBefore - creditAmount, "credit supply shrank by burn");
        assertEq(credit.balanceOf(address(polend)), 0, "no credit escrow left");
    }
}

// ---------------------------------------------------------------------------
// 3. Cross-verse reserve consumption: one shared per-uAsset reserve, two verses.
// ---------------------------------------------------------------------------

contract POLendCrossVerseDustReserveTest is POLendSharedReserveFixture {
    /// @notice Settling verse A decrements the shared reserve; verse B then settles against the
    ///         remainder, and total consumption equals the sum of both deficits.
    function test_SettlementsShareOneReserveAcrossVerses() external {
        _seedVerseForSettlement(VERSE_A, deficits[0]); // deficit 1 ether
        _seedVerseForSettlement(VERSE_B, deficits[1]); // deficit 2 ether
        _fundReserve(deficits[0] + deficits[1]);

        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_A);
        assertEq(uint256(_reserve()), deficits[1], "reserve after verse A");

        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_B);
        assertEq(uint256(_reserve()), 0, "reserve exhausted by both verses");

        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
    }
}

// ---------------------------------------------------------------------------
// 4. Mid-revert settle atomicity: reserve and custody writes roll back with the tx.
// ---------------------------------------------------------------------------

contract POLendSettlementRevertAtomicityTest is POLendSharedReserveFixture {
    /// @notice A deficit-above-reserve revert must leave the reserve, market, global debt, and POLend's
    ///         custody balance exactly as before (existing tests assert only the revert + debt/state).
    function test_RevertWhen_DeficitExceedsReserve_LeavesAllStateUntouched() external {
        _seedVerseForSettlement(VERSE_A, DEBT_PER_VERSE); // deficit 100 ether > reserve
        seedSettlementDustStateForTest(address(polend), address(uAsset), 1 ether, uint128(RESERVE_CAP));

        uint128 reserveBefore = _reserve();
        uint256 debtBefore = polend.getTotalDebtByUAsset(address(uAsset));
        uint256 custodyBefore = uAsset.balanceOf(address(polend));

        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(IPOLend.SettlementDustInsufficient.selector, DEBT_PER_VERSE, 1 ether));
        polend.executeGlobalSettlement(VERSE_A);

        assertEq(uint256(_reserve()), uint256(reserveBefore), "reserve unchanged");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), debtBefore, "global debt unchanged");
        assertEq(uAsset.balanceOf(address(polend)), custodyBefore, "custody unchanged");
        assertEq(
            uint256(polend.getLendMarket(VERSE_A).state), uint256(IPOLend.MarketState.Locked), "market still Locked"
        );
        assertEq(uAsset.repaidAmount(), 0, "no repay happened");
    }

    /// @notice The reserve decrement is written BEFORE the uAsset repay; a repay failure must roll it
    ///         back together with everything else.
    function test_RevertWhen_RepayFailsAfterReserveWrite_LeavesReserveUntouched() external {
        _seedVerseForSettlement(VERSE_A, deficits[0]); // deficit 1 ether, reserve covers it
        seedSettlementDustStateForTest(address(polend), address(uAsset), uint128(deficits[0] + 1), uint128(RESERVE_CAP));
        uAsset.setRevertRepay(true);

        uint128 reserveBefore = _reserve();
        uint256 debtBefore = polend.getTotalDebtByUAsset(address(uAsset));
        uint256 custodyBefore = uAsset.balanceOf(address(polend));

        vm.prank(address(launcher));
        vm.expectRevert(bytes("repay failed"));
        polend.executeGlobalSettlement(VERSE_A);

        assertEq(uint256(_reserve()), uint256(reserveBefore), "reserve write rolled back");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), debtBefore, "global debt unchanged");
        assertEq(uAsset.balanceOf(address(polend)), custodyBefore, "custody unchanged");
        assertEq(
            uint256(polend.getLendMarket(VERSE_A).state), uint256(IPOLend.MarketState.Locked), "market still Locked"
        );
        assertEq(uAsset.repaidAmount(), 0, "no repay happened");
    }
}
