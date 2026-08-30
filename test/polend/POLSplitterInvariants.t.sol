// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {POLSplitterUpgradeable} from "src/polend/POLSplitterUpgradeable.sol";
import {IMemeverseLauncher} from "src/verse/interfaces/IMemeverseLauncher.sol";
import {MockPOL} from "test/mocks/polend/MockPOL.sol";
import {SimplePOLendMock, StageAwareLauncherMock} from "test/mocks/polend/SplitterInvariantMocks.sol";

/// @title POLSplitterHandler
/// @notice Two-phase ghost-accounted operations for the splitter invariant suite.
/// @dev Phase A (Stage.Locked): one-shot ratio recording, then multi-actor split/merge
///      and optional preRedeemPTFee (burns the launcher mock's PT).
///      Phase B (Stage.Unlocked): settle with a bias coin choosing sufficient or short
///      recovery (short exercises the InvalidClaim gate and leaves state unchanged),
///      then multi-actor redeemPT/redeemYT with partial amounts.
///      Ghost ledger: cumulative per-token payouts, redemption call counts, pools frozen
///      at settle, the (SM, YT supply) snapshot for pro-rata monotonicity, and the
///      floor-sum of preRedeemed conversions.
contract POLSplitterHandler is Test {
    POLSplitterUpgradeable public splitter;
    StageAwareLauncherMock public launcherMock;
    SimplePOLendMock public polendMock;
    MockERC20 public pol;
    MockERC20 public uAsset;
    MockERC20 public memecoin;

    address[3] public actors;
    uint256 public constant VERSE_ID = 1;
    uint256 public constant ACTORS = 3;

    bool public ratioRecorded;
    bool public settled;

    // ghost ledger
    uint256 public ghostPaidPTuAsset;
    uint256 public ghostPaidYT_uAsset;
    uint256 public ghostPaidYTMemecoin;
    uint256 public ghostPtRedemptionCalls;
    uint256 public ghostYtRedemptionCalls;
    uint256 public ghostPreRedeemCalls;
    uint256 public ghostSettlementUAsset0;
    uint256 public ghostSettlementMemecoin0;
    uint256 public ghostPreRedeemedBackingFloorSum;
    uint256 public ghostSmBeforeLastYtRedeem; // SM before the last redeemYT
    uint256 public ghostYtSupplyBeforeLastYtRedeem; // YT supply before the last redeemYT
    bool public ghostSawYtRedeem;

    constructor(
        POLSplitterUpgradeable _splitter,
        StageAwareLauncherMock _launcherMock,
        SimplePOLendMock _polendMock,
        MockERC20 _pol,
        MockERC20 _uAsset,
        MockERC20 _memecoin
    ) {
        splitter = _splitter;
        launcherMock = _launcherMock;
        polendMock = _polendMock;
        pol = _pol;
        uAsset = _uAsset;
        memecoin = _memecoin;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("splitActor", vm.toString(i)));
        }
    }

    // ---- view helpers ------------------------------------------------------------

    function _ratio() internal view returns (uint256 n, uint256 d) {
        (n, d) = splitter.ptBackingRatios(VERSE_ID);
    }

    function _pt() internal view returns (IERC20) {
        return IERC20(splitter.getPT(VERSE_ID));
    }

    function _yt() internal view returns (IERC20) {
        return IERC20(splitter.getYT(VERSE_ID));
    }

    function _pools() internal view returns (uint256 su, uint256 sm) {
        (,,,,,, uint256 suLive, uint256 smLive,,,) = splitter.splitInfos(VERSE_ID);
        return (suLive, smLive);
    }

    function _inPhaseA() internal view returns (bool) {
        return ratioRecorded && !settled && launcherMock.stage() == IMemeverseLauncher.Stage.Locked;
    }

    // ---- Phase A -------------------------------------------------------------------

    /// One-shot ratio recording; (n, d) bounded so n <= d <= 10^4 (backing fraction).
    function recordPTBackingRatio(uint256 numeratorSeed, uint256 denominatorSeed) external {
        if (ratioRecorded) return;
        uint256 n = bound(numeratorSeed, 1, 10_000);
        uint256 d = bound(denominatorSeed, n, 10_000);
        vm.prank(address(launcherMock));
        try splitter.recordPTBackingRatio(VERSE_ID, n, d) {
            ratioRecorded = true;
        } catch {}
    }

    /// split(p) mints p PT + p YT and books p collateral.
    function split(uint256 actorSeed, uint256 amountSeed) external {
        if (!_inPhaseA()) return;
        address who = actors[actorSeed % ACTORS];
        uint256 amount = bound(amountSeed, 1, 1e24);
        pol.mint(who, amount);
        vm.startPrank(who);
        pol.approve(address(splitter), amount);
        try splitter.split(VERSE_ID, amount) {} catch {}
        vm.stopPrank();
    }

    /// merge(a) reverses split symmetrically (1:1, no rounding path).
    function merge(uint256 actorSeed, uint256 amountSeed) external {
        if (!_inPhaseA()) return;
        address who = actors[actorSeed % ACTORS];
        uint256 balance = Math.min(_pt().balanceOf(who), _yt().balanceOf(who));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(who);
        try splitter.merge(VERSE_ID, amount) {} catch {}
    }

    /// preRedeemPTFee burns the launcher's PT and records floored backing.
    /// The launcher mock acquires PT from a split actor first (plain transfer).
    function preRedeemPTFee(uint256 actorSeed, uint256 amountSeed) external {
        if (!ratioRecorded || settled) return;
        IERC20 pt = _pt(); // resolve BEFORE any prank: an external view call consumes it
        uint256 launcherBalance = pt.balanceOf(address(launcherMock));
        if (launcherBalance == 0) {
            // Route one actor's PT to the launcher mock so the burn target exists.
            address who = actors[actorSeed % ACTORS];
            uint256 balance = pt.balanceOf(who);
            if (balance == 0) return;
            uint256 route = bound(amountSeed, 1, balance);
            vm.prank(who);
            pt.transfer(address(launcherMock), route);
            launcherBalance = route;
        }
        uint256 amount = bound(amountSeed, 1, launcherBalance);
        (uint256 n, uint256 d) = _ratio();
        vm.prank(address(polendMock));
        try splitter.preRedeemPTFee(VERSE_ID, amount) returns (uint256) {
            ghostPreRedeemedBackingFloorSum += Math.mulDiv(amount, n, d);
            ++ghostPreRedeemCalls;
        } catch {}
    }

    // ---- Phase B -------------------------------------------------------------------

    /// Unlock + settle with a bias coin: sufficient recovery (reserve + slack) settles;
    /// short recovery (below reserve when reserve > 0) must revert InvalidClaim and
    /// leave state unchanged (retryable with fresh seeds).
    function settle(uint256 uAssetSeed, uint256 memecoinSeed) external {
        if (settled || !ratioRecorded) return;
        uint256 ptSupply = _pt().totalSupply();
        if (ptSupply == 0) return;
        (uint256 n, uint256 d) = _ratio();
        // Remaining PT reserve after any pre-redeemed burns, plus the backing that
        // settle repays to POLend on top (recovered >= backing + reserve is required).
        (, uint256 backingLive) = splitter.preRedeemedStates(VERSE_ID);
        uint256 reserve = Math.mulDiv(ptSupply, n, d);
        uint256 uAssetRecovered;
        if (uAssetSeed % 2 == 0) {
            uAssetRecovered = reserve + backingLive + bound(uAssetSeed, 0, 1e24);
        } else if (reserve > 0) {
            uAssetRecovered = bound(uAssetSeed, 0, reserve - 1);
        } else {
            // Zero reserve: settle succeeds trivially with zero pools (both InvalidClaim
            // checks pass at 0); the short-recovery domain requires reserve > 0.
            uAssetRecovered = 0;
        }
        uint256 memecoinRecovered = bound(memecoinSeed, 0, 1e24);

        launcherMock.setStage(IMemeverseLauncher.Stage.Unlocked);
        launcherMock.seedRedemption(VERSE_ID, uAssetRecovered, memecoinRecovered);

        vm.prank(address(launcherMock));
        try splitter.settle(VERSE_ID) returns (uint256 su, uint256 sm) {
            settled = true;
            ghostSettlementUAsset0 = su;
            ghostSettlementMemecoin0 = sm;
        } catch {
            // Short recovery: revert stage so Phase A ops remain reachable on retry.
            launcherMock.setStage(IMemeverseLauncher.Stage.Locked);
        }
    }

    /// PT redemption (partial amounts explored).
    function redeemPT(uint256 actorSeed, uint256 amountSeed) external {
        if (!settled) return;
        address who = actors[actorSeed % ACTORS];
        uint256 balance = _pt().balanceOf(who);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(who);
        try splitter.redeemPT(VERSE_ID, amount, who) returns (uint256 paid) {
            ghostPaidPTuAsset += paid;
            ++ghostPtRedemptionCalls;
        } catch {}
        vm.stopPrank();
    }

    /// YT redemption (partial amounts explored) with monotonicity snapshot.
    function redeemYT(uint256 actorSeed, uint256 amountSeed) external {
        if (!settled) return;
        address who = actors[actorSeed % ACTORS];
        uint256 balance = _yt().balanceOf(who);
        if (balance == 0) return;
        (uint256 sm, uint256 ytSupply) = _snapshotBeforeYtRedeem();
        ghostSmBeforeLastYtRedeem = sm;
        ghostYtSupplyBeforeLastYtRedeem = ytSupply;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(who);
        try splitter.redeemYT(VERSE_ID, amount, who) returns (uint256 au, uint256 am) {
            ghostPaidYT_uAsset += au;
            ghostPaidYTMemecoin += am;
            ++ghostYtRedemptionCalls;
            ghostSawYtRedeem = true;
        } catch {}
        vm.stopPrank();
    }

    function _snapshotBeforeYtRedeem() internal view returns (uint256 sm, uint256 ytSupply) {
        (, uint256 smLive) = _pools();
        return (smLive, _yt().totalSupply());
    }
}

/// @title POLSplitterInvariants
/// @notice Stateful properties for POLSplitterUpgradeable.
/// @dev The example-based suite (test/polend/POLSplitter.t.sol) pins single paths;
///      these invariants assert the conservation laws across arbitrary op sequences.
///      splitInfos field order for reference: pt, yt, pol, memecoin, uAsset,
///      totalPOLCollateral (6th), settlementUAsset (7th), settlementMemecoin (8th),
///      ptBackingNumerator (9th), ptBackingDenominator (10th), settled (11th).
contract POLSplitterInvariants is StdInvariant, Test {
    POLSplitterUpgradeable internal splitter;
    StageAwareLauncherMock internal launcherMock;
    SimplePOLendMock internal polendMock;
    MockERC20 internal memecoin;
    MockERC20 internal uAsset;
    MockPOL internal pol;
    POLSplitterHandler internal handler;

    uint256 internal constant VERSE_ID = 1;

    function setUp() external {
        memecoin = new MockERC20("MEME", "MEME", 18);
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pol = new MockPOL(address(memecoin));
        launcherMock = new StageAwareLauncherMock(pol, uAsset, memecoin);
        polendMock = new SimplePOLendMock(uAsset);
        launcherMock.setPolend(address(polendMock));

        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();
        bytes memory initData =
            abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), address(launcherMock)));
        splitter = POLSplitterUpgradeable(address(new ERC1967Proxy(address(implementation), initData)));

        vm.prank(address(launcherMock));
        splitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");

        handler = new POLSplitterHandler(splitter, launcherMock, polendMock, pol, uAsset, memecoin);
        targetContract(address(handler));
    }

    /// PT (outstanding + already pre-redeemed) == YT == totalPOLCollateral for
    /// every pre-settle state. preRedeemPTFee legitimately burns PT early, so the
    /// conservation law counts the preRedeemedStates.ptAmount back in.
    /// Failure: unpaired mint/burn or collateral bookkeeping decoupled from transferIn.
    function invariant_ptYtCollateralTripleEquality() external view {
        (address pt, address yt,,,, uint256 collateral,,,,, bool verseSettled) = splitter.splitInfos(VERSE_ID);
        if (verseSettled) return; // settle zeroes collateral; pools take over
        (uint256 preRedeemedPt,) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(IERC20(pt).totalSupply() + preRedeemedPt, IERC20(yt).totalSupply(), "PT != YT");
        assertEq(IERC20(yt).totalSupply(), collateral, "YT != collateral");
        // Transfer leg: the splitter's actual POL holdings must equal the
        // accounting leg — a transfer amount drifting from the burned amount breaks it.
        assertEq(pol.balanceOf(address(splitter)), collateral, "POL holdings != collateral");
    }

    /// settled verses always cover outstanding PT at the recorded ratio, so
    /// every holder can redeem in full (floor subadditivity keeps this preserved).
    /// Failure: ceil rounding in _ptToUAsset (early redeemers over-claim, late revert).
    function invariant_settlementCoversPTRatio() external view {
        (uint256 n, uint256 d) = splitter.ptBackingRatios(VERSE_ID);
        if (n == 0 || !handler.settled()) return;
        (uint256 su,) = _livePools();
        uint256 ptSupply = IERC20(splitter.getPT(VERSE_ID)).totalSupply();
        assertGe(su, Math.mulDiv(ptSupply, n, d), "settlement below PT reserve");
    }

    /// waterfall conservation —
    /// SU + ΣuAssetPaid(PT) + ΣuAssetPaid(YT) == SU0 and
    /// SM + ΣmemecoinPaid(YT) == SM0 (pools frozen at settle; R repaid and cleared).
    /// Failure: double pool deduction, PT-reserve/YT-pool confusion, R not cleared.
    function invariant_settlementWaterfallConserved() external view {
        if (!handler.settled()) return;
        (uint256 su, uint256 sm) = _livePools();
        assertEq(
            su + handler.ghostPaidPTuAsset() + handler.ghostPaidYT_uAsset(),
            handler.ghostSettlementUAsset0(),
            "uAsset waterfall broken"
        );
        assertEq(sm + handler.ghostPaidYTMemecoin(), handler.ghostSettlementMemecoin0(), "memecoin waterfall broken");
    }

    /// YT per-unit redeemable never decreases (floor keeps dust in the pool).
    /// Integer form: SM_now * YT_supply_then >= SM_then * YT_supply_now.
    function invariant_ytPerUnitRedeemableNeverDecreases() external view {
        if (!handler.settled() || !handler.ghostSawYtRedeem()) return;
        (, uint256 smNow) = _livePools();
        uint256 ytNow = IERC20(splitter.getYT(VERSE_ID)).totalSupply();
        assertGe(
            Math.mulDiv(smNow, handler.ghostYtSupplyBeforeLastYtRedeem(), 1),
            Math.mulDiv(handler.ghostSmBeforeLastYtRedeem(), ytNow, 1),
            "YT per-unit redeemable decreased"
        );
    }

    /// full-drain dust bound — with both supplies at zero, the remaining pools
    /// are bounded by the redemption call counts (each floor leaves < 1 wei per call).
    function invariant_finalDustBoundedByRedemptionCount() external view {
        if (!handler.settled()) return;
        uint256 ptSupply = IERC20(splitter.getPT(VERSE_ID)).totalSupply();
        uint256 ytSupply = IERC20(splitter.getYT(VERSE_ID)).totalSupply();
        if (ptSupply != 0 || ytSupply != 0) return;
        (uint256 su, uint256 sm) = _livePools();
        assertLe(
            su,
            handler.ghostPtRedemptionCalls() + handler.ghostPreRedeemCalls() + handler.ghostYtRedemptionCalls(),
            "uAsset dust above call-count bound"
        );
        assertLe(sm, handler.ghostYtRedemptionCalls(), "memecoin dust above call-count bound");
    }

    /// @dev Live settlement pools (splitInfos slots 7/8 of 11).
    function _livePools() internal view returns (uint256 su, uint256 sm) {
        (,,,,,, uint256 suLive, uint256 smLive,,,) = splitter.splitInfos(VERSE_ID);
        return (suLive, smLive);
    }

    /// preRedeemed backing equals the floor-sum of per-burn conversions while
    /// unsettled, is repaid to POLend exactly at settle, and is cleared afterwards.
    function invariant_preRedeemedBackingMatchesBurnedPT() external view {
        (uint256 ptAmount, uint256 uAssetBacking) = splitter.preRedeemedStates(VERSE_ID);
        if (!handler.settled()) {
            assertEq(uAssetBacking, handler.ghostPreRedeemedBackingFloorSum(), "backing != floor sum");
        } else {
            assertEq(ptAmount, 0, "preRedeemed PT not cleared");
            assertEq(uAssetBacking, 0, "preRedeemed backing not cleared");
            assertEq(
                polendMock.totalBurnedPreRedeemedBacking(),
                handler.ghostPreRedeemedBackingFloorSum(),
                "POLend repayment mismatch"
            );
        }
    }
}
