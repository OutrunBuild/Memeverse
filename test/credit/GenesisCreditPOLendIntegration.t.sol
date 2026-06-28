// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLend} from "../../src/polend/POLend.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MockPOLForPOLend, MintableToken, BurnableMockERC20} from "../mocks/polend/POLendMocks.sol";
import {MockGenesisCreditFactory} from "../mocks/credit/MockGenesisCreditFactory.sol";

/// @notice Launcher mock that drives a verse through Genesis -> Locked -> Settled for the
///         mixed real+credit integration test. Unlike the POLend unit-test launcher mock, it
///         implements `redeemMemecoinLiquidity` so the settlement POL-burn path can produce both
///         uAsset and memecoin residuals end-to-end (the unit-test mock reverts on that call).
contract IntegrationLauncher {
    struct RedeemOutput {
        uint256 uAsset;
        uint256 memecoin;
    }

    mapping(uint256 => uint256) internal _normalFunds;
    mapping(uint256 => address) internal _uAssets;
    mapping(address => uint256) internal _minTotalFunds;
    mapping(uint256 => uint256) internal _polAmounts;
    mapping(uint256 => uint256) internal _lpUAssets;
    mapping(uint256 => RedeemOutput) internal _redeemOutputs;
    // Launch-gate simulation state. `_stages` defaults to Genesis (enum index 0), so credit
    // participation (which requires Genesis) works until `changeStage` advances the verse.
    mapping(uint256 => IMemeverseLauncher.Stage) internal _stages;
    mapping(uint256 => bool) internal _flashGenesis;
    mapping(uint256 => uint128) internal _endTimes;
    address internal _polend;

    MockERC20 internal _pol;
    MockERC20 internal _memecoin;

    function setErcTokens(MockERC20 pol, MockERC20 memecoin) external {
        _pol = pol;
        _memecoin = memecoin;
    }

    function setGenesisFunds(uint256 verseId, uint256 amount) external {
        _normalFunds[verseId] = amount;
    }

    function setVerseUAsset(uint256 verseId, address uAsset) external {
        _uAssets[verseId] = uAsset;
    }

    function setMinTotalFund(address uAsset, uint256 minTotalFund) external {
        _minTotalFunds[uAsset] = minTotalFund;
    }

    function setSettlementResult(uint256 verseId, uint256 polAmount, uint256 lpUAsset) external {
        _polAmounts[verseId] = polAmount;
        _lpUAssets[verseId] = lpUAsset;
    }

    function setRedeemOutput(uint256 verseId, uint256 uAssetOut, uint256 memecoinOut) external {
        _redeemOutputs[verseId] = RedeemOutput({uAsset: uAssetOut, memecoin: memecoinOut});
    }

    function setPolend(address polend) external {
        _polend = polend;
    }

    function setFlashGenesis(uint256 verseId, bool flag) external {
        _flashGenesis[verseId] = flag;
    }

    function setEndTime(uint256 verseId, uint128 endTime) external {
        _endTimes[verseId] = endTime;
    }

    // --- IMemeverseLauncher surface exercised by POLend ---

    function totalNormalFunds(uint256 verseId) external view returns (uint256) {
        return _normalFunds[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return _uAssets[verseId];
    }

    /// @dev Returns the tracked stage; defaults to Genesis (enum 0) until `changeStage` advances it.
    ///      POLend reads this during `leveragedGenesis` / `leveragedGenesisWithCredit`, which require
    ///      Genesis, so credit participation must precede `changeStage`.
    function getStageByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Stage) {
        return _stages[verseId];
    }

    /// @dev Mirrors `MemeverseLauncher._handleGenesisStage` launch gate: a verse leaves Genesis when
    ///      `totalNormalFunds >= minTotalFund || totalLeveragedInterest >= minTotalFund`. Credit-funded
    ///      interest counts toward the second clause, so a pure-credit self-bootstrap
    ///      (`totalNormalFunds == 0`) can still lock. Only the gate + stage transition are simulated;
    ///      the real launcher's post-lock deploy/markRefundable paths are out of scope here.
    function changeStage(uint256 verseId) external returns (IMemeverseLauncher.Stage) {
        IMemeverseLauncher.Stage current = _stages[verseId];
        require(
            current != IMemeverseLauncher.Stage.Refund && current != IMemeverseLauncher.Stage.Unlocked,
            IMemeverseLauncher.ReachedFinalStage()
        );
        if (current != IMemeverseLauncher.Stage.Genesis) return current;

        address uAsset = _uAssets[verseId];
        uint256 minTotalFund = _minTotalFunds[uAsset];
        uint256 totalLeveragedInterest = IPOLend(_polend).getTotalLeveragedInterest(verseId);
        // Launch gate OR condition: normal funds OR aggregate leveraged interest (incl. credit) clears
        // the bar. This is the clause that lets credit alone self-bootstrap a launch.
        bool meetMinTotalFund = _normalFunds[verseId] >= minTotalFund || totalLeveragedInterest >= minTotalFund;
        uint128 endTime = _endTimes[verseId];

        if ((_flashGenesis[verseId] && meetMinTotalFund) || (block.timestamp > endTime && meetMinTotalFund)) {
            _stages[verseId] = IMemeverseLauncher.Stage.Locked;
            return IMemeverseLauncher.Stage.Locked;
        }
        require(block.timestamp > endTime, IMemeverseLauncher.StillInGenesisStage(endTime));
        _stages[verseId] = IMemeverseLauncher.Stage.Refund;
        return IMemeverseLauncher.Stage.Refund;
    }

    function getDebtCapBaseByVerseId(uint256 verseId) external view returns (uint256) {
        address uAsset = _uAssets[verseId];
        uint256 funds = _normalFunds[verseId];
        uint256 minFund = _minTotalFunds[uAsset];
        return funds > minFund ? funds : minFund;
    }

    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        view
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        // ptAmount is always zero in these tests so the splitter PT-redeem path is never reached.
        return (_polAmounts[verseId], 0, _lpUAssets[verseId]);
    }

    /// @dev POLend approved `polAmount` of POL to this launcher. Consume it and send the
    ///      pre-configured uAsset + memecoin redemption back to the caller (POLend). The amounts
    ///      transferred become the `_burnSettledPol` deltas POLend measures via balance diffs.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 polAmount, bool) external returns (uint256) {
        require(_pol.transferFrom(msg.sender, address(this), polAmount), "POL transferFrom failed");
        RedeemOutput memory out = _redeemOutputs[verseId];
        if (out.uAsset != 0) {
            require(MockERC20(_uAssets[verseId]).transfer(msg.sender, out.uAsset), "uAsset transfer failed");
        }
        if (out.memecoin != 0) {
            require(_memecoin.transfer(msg.sender, out.memecoin), "memecoin transfer failed");
        }
        return out.uAsset;
    }
}

/// @notice Minimal splitter mock: returns the configured POL and memecoin addresses. Only the
///         methods POLend touches during `executeGlobalSettlement` and `claimResidual` are
///         implemented (`getPOLAndMemecoin`, `getMemecoin`).
contract IntegrationSplitter {
    address internal _pol;
    address internal _memecoin;

    function setSplitInfo(address pol, address memecoin) external {
        _pol = pol;
        _memecoin = memecoin;
    }

    function getPOLAndMemecoin(uint256) external view returns (address, address) {
        return (_pol, _memecoin);
    }

    function getMemecoin(uint256) external view returns (address) {
        return _memecoin;
    }
}

/// @notice End-to-end integration of mixed real-uAsset + GenesisCredit participation across the
///         full POLend lifecycle (Genesis -> Locked -> Settled). Verifies the credit-path
///         invariants that the per-function unit tests in `POLend.t.sol` cannot exercise together:
///         - GenesisCredit escrowed at genesis, burned at finalize (supply reduced, no stray transfer).
///         - Debt minted from the aggregate (real + credit) interest, while the full real-uAsset
///           slice sweeps to treasury; finalize does not fund the settlement dust reserve.
///         - `claimLeveragedYT` and `claimResidual` split pro-rata over the aggregate interest, so a
///           credit-only participant is never blocked by a real-only gate and conservation holds:
///           aliceYT + bobYT == totalLeveragedYT, and aliceResidual + bobResidual == residual per asset.
contract GenesisCreditPOLendIntegration is Test {
    uint256 internal constant VERSE_ID = 1;
    uint128 internal constant MAX_DUST = 1e9;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ALICE_REC = address(0xA11CE01);
    address internal constant BOB_REC = address(0xB0B02);

    BurnableMockERC20 internal uAsset;
    BurnableMockERC20 internal credit;
    MintableToken internal yt;
    MockERC20 internal memecoin;
    MockPOLForPOLend internal pol;
    IntegrationLauncher internal launcher;
    IntegrationSplitter internal splitter;
    MockGenesisCreditFactory internal creditFactory;
    POLend internal polend;

    function setUp() external {
        uAsset = new BurnableMockERC20("UASSET", "UASSET");
        credit = new BurnableMockERC20("CREDIT", "CREDIT");
        yt = new MintableToken("YT", "YT");
        memecoin = new MockERC20("MEME", "MEME", 18);
        pol = new MockPOLForPOLend(address(memecoin));

        launcher = new IntegrationLauncher();
        splitter = new IntegrationSplitter();
        splitter.setSplitInfo(address(pol), address(memecoin));
        launcher.setErcTokens(MockERC20(address(pol)), memecoin);
        launcher.setVerseUAsset(VERSE_ID, address(uAsset));
        launcher.setGenesisFunds(VERSE_ID, 1_000 ether);
        launcher.setMinTotalFund(address(uAsset), 1_000 ether);

        creditFactory = new MockGenesisCreditFactory();
        creditFactory.setCreditOf(address(uAsset), address(credit));

        // interestRate = 0.1e18 => debt = interest * 10; leveragedDebtFactor = 10e18.
        polend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(splitter), address(creditFactory));
        // Wire the launcher mock back to POLend so `changeStage` can read the real aggregate interest
        // for the launch-gate simulation.
        launcher.setPolend(address(polend));

        polend.setMaxSettlementDustReserve(address(uAsset), MAX_DUST);
        vm.prank(address(launcher));
        polend.registerLendMarket(VERSE_ID);
    }

    function _deployPOLend(
        uint256 interestRate,
        uint256 leveragedDebtFactor,
        address treasury,
        address launcher_,
        address splitter_,
        address creditFactory_
    ) internal returns (POLend) {
        POLend impl = new POLend();
        bytes memory data = abi.encodeCall(
            POLend.initialize,
            (address(this), interestRate, leveragedDebtFactor, treasury, launcher_, splitter_, creditFactory_)
        );
        return POLend(address(new ERC1967Proxy(address(impl), data)));
    }

    /// @dev Arm the settlement POL-redeem path: POLend recovers `uAssetOut` uAsset and
    ///      `memecoinOut` memecoin by burning `polAmount` of POL. Mints the POL to POLend (so its
    ///      approve + the launcher's transferFrom succeed) and the redemption output to the launcher
    ///      (so its transfers back to POLend succeed). `uAssetOut` must equal `debt + residualUAsset`.
    function _armSettlement(uint256 polAmount, uint256 uAssetOut, uint256 memecoinOut) internal {
        launcher.setSettlementResult(VERSE_ID, polAmount, 0);
        launcher.setRedeemOutput(VERSE_ID, uAssetOut, memecoinOut);
        pol.mint(address(polend), polAmount);
        uAsset.mint(address(launcher), uAssetOut);
        memecoin.mint(address(launcher), memecoinOut);
    }

    // ===== Mixed real (alice) + credit (bob) full lifecycle =====

    /// @dev alice pays 10 uAsset real interest, bob pays 5 GenesisCredit. Aggregate interest 15,
    ///      debt 150. YT total 150 splits 100/50; residual 45 uAsset + 30 memecoin splits 30/15 and 20/10.
    function test_MixedRealAndCredit_FullLifecycleConservation() external {
        // --- Genesis: real path (alice) + credit path (bob) ---
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        credit.mint(BOB, 5 ether);
        vm.prank(BOB);
        credit.approve(address(polend), 5 ether);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(VERSE_ID, 5 ether);

        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), 15 ether, "aggregate interest");
        assertEq(polend.getTotalCreditInterest(VERSE_ID), 5 ether, "credit interest tally");
        assertEq(polend.getTotalLeveragedDebt(VERSE_ID), 150 ether, "aggregate debt");
        assertEq(credit.balanceOf(address(polend)), 5 ether, "credit escrowed pre-finalize");

        // --- Finalize: full real slice sweeps to treasury, credit slice burns, aggregate debt mints ---
        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        uint256 creditSupplyBefore = credit.totalSupply();

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Locked), "locked");
        // Aggregate debt (real + credit) is minted to the launcher from the real-uAsset token.
        assertEq(uAsset.balanceOf(address(launcher)), 150 ether, "aggregate debt minted to launcher");
        // Treasury receives the full real-uAsset interest sweep; credit funds nothing here.
        assertEq(uAsset.balanceOf(address(this)) - treasuryBefore, 10 ether, "treasury real-only");
        // Credit escrow burned in-place; supply reduced by exactly the credit-funded interest.
        assertEq(credit.balanceOf(address(polend)), 0, "credit escrow burned");
        assertEq(credit.totalSupply(), creditSupplyBefore - 5 ether, "credit supply reduced");
        assertEq(credit.burnedAmount(), 5 ether, "credit burn recorded");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 150 ether, "global debt after finalize");

        // --- recordLeveragedYT + YT claims (pro-rata over aggregate interest) ---
        vm.prank(address(launcher));
        polend.recordLeveragedYT(VERSE_ID, address(yt), 150 ether);
        yt.mint(address(polend), 150 ether);

        vm.prank(ALICE);
        uint256 aliceYT = polend.claimLeveragedYT(VERSE_ID, ALICE_REC);
        vm.prank(BOB);
        uint256 bobYT = polend.claimLeveragedYT(VERSE_ID, BOB_REC);

        // alice 10/15 of 150 = 100; bob 5/15 of 150 = 50. Exact (no rounding dust).
        assertEq(aliceYT, 100 ether, "alice YT share");
        assertEq(bobYT, 50 ether, "bob YT share (credit-only participant not blocked)");
        assertEq(aliceYT + bobYT, 150 ether, "YT conservation");
        assertEq(yt.balanceOf(ALICE_REC), 100 ether, "alice recipient YT");
        assertEq(yt.balanceOf(BOB_REC), 50 ether, "bob recipient YT");
        assertEq(yt.balanceOf(address(polend)), 0, "polend YT drained");

        // --- Global settlement: POL burn recovers uAsset + memecoin; residual split pro-rata ---
        // recovered uAsset = 195 = debt(150) + residual(45); residual memecoin = 30.
        _armSettlement(100 ether, 195 ether, 30 ether);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Settled), "settled");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        assertEq(residualUAsset, 45 ether, "residual uAsset = recovered - debt");
        assertEq(residualMemecoin, 30 ether, "residual memecoin");

        vm.prank(ALICE);
        (uint256 aliceU, uint256 aliceM) = polend.claimResidual(VERSE_ID, ALICE_REC);
        vm.prank(BOB);
        (uint256 bobU, uint256 bobM) = polend.claimResidual(VERSE_ID, BOB_REC);

        // uAsset: alice 30, bob 15 (10/15 and 5/15 of 45). memecoin: alice 20, bob 10 (of 30). Exact.
        assertEq(aliceU, 30 ether, "alice residual uAsset");
        assertEq(bobU, 15 ether, "bob residual uAsset");
        assertEq(aliceU + bobU, residualUAsset, "residual uAsset conservation");
        assertEq(aliceM, 20 ether, "alice residual memecoin");
        assertEq(bobM, 10 ether, "bob residual memecoin");
        assertEq(aliceM + bobM, residualMemecoin, "residual memecoin conservation");
        assertEq(uAsset.balanceOf(ALICE_REC), 30 ether, "alice recipient uAsset");
        assertEq(uAsset.balanceOf(BOB_REC), 15 ether, "bob recipient uAsset");
        assertEq(memecoin.balanceOf(ALICE_REC), 20 ether, "alice recipient memecoin");
        assertEq(memecoin.balanceOf(BOB_REC), 10 ether, "bob recipient memecoin");
    }

    // ===== Pure-credit lifecycle: a credit-only participant completes the full flow unblocked =====

    /// @dev bob pays 15 GenesisCredit only (no real uAsset interest). Before the credit-path fix a
    ///      pure-credit participant would be blocked by real-only judgement in claim paths. Here bob
    ///      receives the full YT and residual, proving the aggregate-interest numerator admits credit-only.
    function test_PureCredit_FullLifecycleConservation() external {
        credit.mint(BOB, 15 ether);
        vm.prank(BOB);
        credit.approve(address(polend), 15 ether);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(VERSE_ID, 15 ether);

        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), 15 ether, "credit-only interest");
        assertEq(polend.getTotalCreditInterest(VERSE_ID), 15 ether, "all interest is credit");
        assertEq(polend.getTotalLeveragedDebt(VERSE_ID), 150 ether, "debt minted from credit");
        assertEq(credit.balanceOf(address(polend)), 15 ether, "credit escrowed");

        uint256 treasuryBefore = uAsset.balanceOf(address(this));

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        // Pure-credit: realInterest = 0 => no treasury sweep, no dust credit; only burn + debt mint.
        assertEq(uAsset.balanceOf(address(this)), treasuryBefore, "no treasury sweep on pure-credit");
        assertEq(uAsset.balanceOf(address(launcher)), 150 ether, "debt minted from credit-only interest");
        assertEq(credit.balanceOf(address(polend)), 0, "credit escrow burned");
        assertEq(credit.burnedAmount(), 15 ether, "credit burn recorded");

        vm.prank(address(launcher));
        polend.recordLeveragedYT(VERSE_ID, address(yt), 150 ether);
        yt.mint(address(polend), 150 ether);

        vm.prank(BOB);
        uint256 bobYT = polend.claimLeveragedYT(VERSE_ID, BOB_REC);
        assertEq(bobYT, 150 ether, "credit-only YT claim not blocked");
        assertEq(yt.balanceOf(BOB_REC), 150 ether, "bob recipient YT");
        assertEq(yt.balanceOf(address(polend)), 0, "polend YT drained");

        _armSettlement(100 ether, 195 ether, 30 ether);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        assertEq(residualUAsset, 45 ether, "residual uAsset");
        assertEq(residualMemecoin, 30 ether, "residual memecoin");

        vm.prank(BOB);
        (uint256 bobU, uint256 bobM) = polend.claimResidual(VERSE_ID, BOB_REC);
        // Sole participant: bob receives the entire residual. Conservation trivially holds.
        assertEq(bobU, 45 ether, "credit-only residual uAsset not blocked");
        assertEq(bobU, residualUAsset, "residual uAsset conservation");
        assertEq(bobM, 30 ether, "credit-only residual memecoin not blocked");
        assertEq(bobM, residualMemecoin, "residual memecoin conservation");
        assertEq(uAsset.balanceOf(BOB_REC), 45 ether, "bob recipient uAsset");
        assertEq(memecoin.balanceOf(BOB_REC), 30 ether, "bob recipient memecoin");
    }

    // ===== Credit-only self-bootstrap: credit interest alone clears the launch gate =====

    /// @dev No normal funds and no real leveraged participation. Two users pay GenesisCredit until
    ///      `totalLeveragedInterest >= minTotalFund`, which satisfies the launch gate's OR condition
    ///      (`totalNormalFunds >= minTotalFund || totalLeveragedInterest >= minTotalFund`) even though
    ///      `totalNormalFunds == 0`. The verse locks, then finalize mints debt from the credit-derived
    ///      interest, skips the real-only dust/treasury sweep (realInterest = 0), and burns the full
    ///      credit. Also asserts the gate rejects while credit interest is still below minTotalFund,
    ///      and that at the minimum leveragedDebtFactor the gate-threshold debt lands exactly on the
    ///      debt cap (capBase collapses to minTotalFund when normalFunds == 0).
    function test_CreditOnlyBootstrap_LocksWhenCreditFillsMinTotalFundThenFinalizes() external {
        // Self-bootstrap config: zero normal funds; credit must alone clear minTotalFund.
        uint256 minTotalFund = 150 ether;
        launcher.setGenesisFunds(VERSE_ID, 0);
        launcher.setMinTotalFund(address(uAsset), minTotalFund);
        uint128 endTime = uint128(block.timestamp + 1 days);
        launcher.setEndTime(VERSE_ID, endTime);
        launcher.setFlashGenesis(VERSE_ID, true);

        // --- Partial credit (50) is below minTotalFund (150): gate not met, changeStage rejects ---
        credit.mint(BOB, 50 ether);
        vm.prank(BOB);
        credit.approve(address(polend), 50 ether);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(VERSE_ID, 50 ether);

        assertEq(launcher.totalNormalFunds(VERSE_ID), 0, "no normal funds");
        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), 50 ether, "partial credit interest");
        // totalNormalFunds=0 and totalLeveragedInterest(50) < minTotalFund(150): neither OR clause holds.
        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.StillInGenesisStage.selector, uint256(endTime)));
        launcher.changeStage(VERSE_ID);
        assertEq(
            uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Genesis), "still genesis"
        );

        // --- Top up credit until totalLeveragedInterest == minTotalFund (gate OR clause met) ---
        credit.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        credit.approve(address(polend), 100 ether);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(VERSE_ID, 100 ether);

        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), minTotalFund, "credit fills minTotalFund");
        assertEq(polend.getTotalCreditInterest(VERSE_ID), minTotalFund, "all interest is credit");

        // capBase = max(normalFunds=0, minTotalFund) = minTotalFund; at the minimum leveragedDebtFactor
        // (10e18 == 1e36/interestRate) the gate-threshold debt equals the debt cap exactly, so the
        // credit that just fills the gate is accepted (previewDebt == cap, strict `>` not triggered).
        IPOLend.LeveragedDebtInfo memory info = polend.getLeveragedDebtInfo(VERSE_ID);
        assertEq(info.totalLeveragedDebt, info.debtCap, "gate-threshold debt lands on cap at min factor");

        // Launch gate satisfied by credit interest alone: Genesis -> Locked.
        assertEq(
            uint256(launcher.changeStage(VERSE_ID)),
            uint256(IMemeverseLauncher.Stage.Locked),
            "credit-only self-bootstrap locks"
        );
        assertEq(
            uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "stage locked"
        );

        // --- Finalize: debt minted from credit-derived interest; real slice = 0 so no sweep; burn credit ---
        uint256 expectedDebt = minTotalFund * 1e18 / 1e17; // interestRate=1e17 => debt = interest * 10 = 1500 ether
        uint256 creditSupplyBefore = credit.totalSupply();
        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        (uint128 reserveBefore,) = polend.settlementDustStates(address(uAsset));

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Locked), "market locked");
        // Aggregate debt is minted to the launcher from the credit-derived interest.
        assertEq(uAsset.balanceOf(address(launcher)), expectedDebt, "debt minted from credit interest");
        // realInterest = totalLeveragedInterest - totalCredit = 0 => no treasury sweep, no dust reserve credit.
        assertEq(uAsset.balanceOf(address(this)), treasuryBefore, "no treasury sweep (real=0)");
        (uint128 reserveAfter,) = polend.settlementDustStates(address(uAsset));
        assertEq(uint256(reserveAfter), uint256(reserveBefore), "no dust reserve credited (real=0)");
        // Full escrowed credit burned in-place; supply reduced by exactly the credit-funded interest.
        assertEq(credit.balanceOf(address(polend)), 0, "credit escrow burned");
        assertEq(credit.totalSupply(), creditSupplyBefore - minTotalFund, "credit supply reduced");
        assertEq(credit.burnedAmount(), minTotalFund, "credit burn recorded");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), expectedDebt, "global debt after finalize");
    }

    // ===== Mixed pool: two verses sharing one uAsset + one GenesisCredit token =====

    /// @dev Two verses A + B share the same uAsset, so the credit factory keys them to a single
    ///      GenesisCredit token (creditOf is keyed by uAsset). POLend escrows both verses' credit
    ///      interest in one balance (the mixed pool). Verse A finalizes, which must burn exactly A's
    ///      `totalCreditInterest` and leave B's escrowed share untouched; verse B then fails into
    ///      Refund and returns B's credit to the user. Conservation: the shared escrow drops by A's
    ///      amount on finalize, by B's amount on refund, and ends at zero — no cross-verse burn.
    function test_MixedPool_MultiVerse_BurnPrecision() external {
        uint256 verseA = VERSE_ID; // 1, registered in setUp
        uint256 verseB = 2;
        // Register verse B against the SAME uAsset so both verses share one GenesisCredit token.
        launcher.setVerseUAsset(verseB, address(uAsset));
        vm.prank(address(launcher));
        polend.registerLendMarket(verseB);

        uint256 aliceCredit = 10 ether; // verse A credit interest
        uint256 bobCredit = 5 ether; // verse B credit interest

        // --- Both verses escrow GenesisCredit into the shared mixed-pool balance ---
        credit.mint(ALICE, aliceCredit);
        vm.prank(ALICE);
        credit.approve(address(polend), aliceCredit);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(verseA, aliceCredit);

        credit.mint(BOB, bobCredit);
        vm.prank(BOB);
        credit.approve(address(polend), bobCredit);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(verseB, bobCredit);

        assertEq(polend.getTotalCreditInterest(verseA), aliceCredit, "verse A credit interest tally");
        assertEq(polend.getTotalCreditInterest(verseB), bobCredit, "verse B credit interest tally");
        // Mixed-pool escrow holds BOTH verses' credit in a single GenesisCredit balance.
        assertEq(credit.balanceOf(address(polend)), aliceCredit + bobCredit, "mixed-pool escrow = A + B");

        // --- Finalize verse A: burn EXACTLY A's totalCreditInterest, never B's share ---
        uint256 creditSupplyBefore = credit.totalSupply();
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(verseA);

        assertEq(credit.burnedAmount(), aliceCredit, "burn == verse A totalCreditInterest only");
        assertEq(credit.balanceOf(address(polend)), bobCredit, "escrow reduced by A; B share intact");
        assertEq(credit.totalSupply(), creditSupplyBefore - aliceCredit, "supply reduced by A only");
        // Verse B's ledger and stage are untouched by A's finalize (no cross-verse contamination).
        assertEq(polend.getTotalCreditInterest(verseB), bobCredit, "verse B credit interest unchanged");
        assertEq(
            uint256(polend.getLendMarket(verseB).state),
            uint256(IPOLend.MarketState.Genesis),
            "verse B still genesis after A finalize"
        );

        // --- Refund verse B: return B's credit to bob, unaffected by A's burn ---
        vm.prank(address(launcher));
        polend.markRefundable(verseB);
        assertEq(uint256(polend.getLendMarket(verseB).state), uint256(IPOLend.MarketState.Refund), "verse B refund");

        uint256 bobRecBefore = credit.balanceOf(BOB_REC);
        vm.prank(BOB);
        polend.claimRefund(verseB, BOB_REC);

        assertEq(credit.balanceOf(BOB_REC) - bobRecBefore, bobCredit, "bob refunded B's credit");
        assertEq(credit.balanceOf(address(polend)), 0, "mixed-pool escrow drained to zero");
        // A's burn is not reversed by B's refund; B's refund is a transfer, not a burn.
        assertEq(credit.burnedAmount(), aliceCredit, "A burn persists after B refund");
        assertEq(credit.totalSupply(), creditSupplyBefore - aliceCredit, "supply unchanged by B refund");
    }
}
