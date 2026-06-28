// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {POLend} from "../../src/polend/POLend.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {
    MockPOLForPOLend,
    MintableToken,
    BurnableMockERC20,
    HookedBurnableMockERC20,
    ReentrantClaimMockERC20
} from "../mocks/polend/POLendMocks.sol";
import {POLendStorageHelper} from "../mocks/polend/POLendStorageHelper.sol";
import {MockGenesisCreditFactory} from "../mocks/credit/MockGenesisCreditFactory.sol";

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

    function redeemMemecoinLiquidity(uint256, uint256, bool) external pure returns (uint256) {
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

contract POLendTest is Test, POLendStorageHelper {
    uint256 internal constant VERSE_ID = 1;
    uint256 internal constant OTHER_VERSE_ID = 2;
    uint256 internal constant MAX_SETTLEMENT_DUST = 1e9;
    uint256 internal constant MAX_LEVERAGED_DEBT_FACTOR = uint256(type(uint128).max) * 1e18;
    bytes4 internal constant INVALID_INITIALIZATION_SELECTOR = bytes4(keccak256("InvalidInitialization()"));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCAFE);

    event ProtocolTreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event DefaultInterestRateChanged(uint256 oldRate, uint256 newRate);
    event LeveragedDebtFactorChanged(uint256 oldFactor, uint256 newFactor);
    event LeveragedGenesis(uint256 indexed verseId, address indexed user, uint256 interestAmount);
    event PreRedeemPTFee(
        uint256 indexed verseId, address indexed uAsset, uint256 ptAmount, uint256 uAssetBacking, address mintTo
    );
    event SettlementDustReserveConfigured(address indexed uAsset, uint128 oldMaxReserve, uint128 newMaxReserve);
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
    event LeveragedGenesisWithCredit(uint256 indexed verseId, address indexed user, uint256 creditAmount);
    event CreditBurned(uint256 indexed verseId, address indexed uAsset, uint256 totalCreditInterest);
    event ClaimRefund(uint256 indexed verseId, address indexed user, address indexed to, uint256 refundedAmount);
    event CreditRefunded(uint256 indexed verseId, address indexed user, address indexed to, uint256 amount);

    BurnableMockERC20 internal uAsset;
    BurnableMockERC20 internal otherUAsset;
    MintableToken internal yt;
    MintableToken internal pt;
    MockERC20 internal memecoin;
    MockPOLForPOLend internal pol;
    MockLauncherForPOLend internal launcher;
    MockSplitterForPOLend internal splitter;
    POLend internal polend;

    function setUp() external {
        uAsset = new BurnableMockERC20("UASSET", "UASSET");
        otherUAsset = new BurnableMockERC20("OTHER", "OTHER");
        yt = new MintableToken("YT", "YT");
        pt = new MintableToken("PT", "PT");
        memecoin = new MockERC20("MEME", "MEME", 18);
        pol = new MockPOLForPOLend(address(memecoin));
        launcher = new MockLauncherForPOLend();
        splitter = new MockSplitterForPOLend();
        splitter.setTokens(address(pt), address(yt));
        splitter.setSplitInfo(address(pol), address(memecoin), address(uAsset));

        polend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(splitter));
        uAsset.mint(address(this), 10_000 ether);
        otherUAsset.mint(address(this), 10_000 ether);
        uAsset.approve(address(polend), type(uint256).max);
        otherUAsset.approve(address(polend), type(uint256).max);

        launcher.setGenesisFunds(VERSE_ID, 1_000 ether);
        launcher.setGenesisFunds(OTHER_VERSE_ID, 1_000 ether);
        launcher.setVerseUAsset(VERSE_ID, address(uAsset));
        launcher.setVerseUAsset(OTHER_VERSE_ID, address(otherUAsset));
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        launcher.setFundMetaData(address(otherUAsset), 1_000 ether, 1);
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        polend.setMaxSettlementDustReserve(address(otherUAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        polend.registerLendMarket(VERSE_ID);
        vm.prank(address(launcher));
        polend.registerLendMarket(OTHER_VERSE_ID);
    }

    function _deployPOLend(
        uint256 interestRate,
        uint256 leveragedDebtFactor,
        address treasury,
        address launcher_,
        address splitter_
    ) internal returns (POLend deployed) {
        POLend implementation = new POLend();
        return _deployPOLendWithImplementation(
            implementation, interestRate, leveragedDebtFactor, treasury, launcher_, splitter_, address(this)
        );
    }

    function _deployPOLendWithImplementation(
        POLend implementation,
        uint256 interestRate,
        uint256 leveragedDebtFactor,
        address treasury,
        address launcher_,
        address splitter_,
        address creditFactory_
    ) internal returns (POLend deployed) {
        bytes memory data = abi.encodeCall(
            POLend.initialize,
            (address(this), interestRate, leveragedDebtFactor, treasury, launcher_, splitter_, creditFactory_)
        );
        return POLend(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _fundDustReserveFromAlice(uint256 amount) internal {
        uAsset.mint(ALICE, amount);
        vm.prank(ALICE);
        uAsset.approve(address(polend), amount);
        vm.prank(ALICE);
        polend.fundSettlementDustReserve(address(uAsset), amount);
    }

    function testInitialize_RevertsWhenInterestRateZeroOrAboveOne() external {
        POLend implementation = new POLend();

        vm.expectRevert(IPOLend.ZeroInput.selector);
        _deployPOLendWithImplementation(
            implementation, 0, 10e18, address(this), address(launcher), address(splitter), address(this)
        );

        implementation = new POLend();

        vm.expectRevert(IPOLend.InvalidConfig.selector);
        _deployPOLendWithImplementation(
            implementation, 1e18 + 1, 10e18, address(this), address(launcher), address(splitter), address(this)
        );

        implementation = new POLend();

        vm.expectRevert(IPOLend.ZeroInput.selector);
        _deployPOLendWithImplementation(
            implementation, 1e18, 0, address(this), address(launcher), address(splitter), address(this)
        );

        implementation = new POLend();

        POLend deployed = _deployPOLendWithImplementation(
            implementation,
            1e18,
            MAX_LEVERAGED_DEBT_FACTOR,
            address(this),
            address(launcher),
            address(splitter),
            address(this)
        );
        assertEq(deployed.leveragedDebtFactor(), MAX_LEVERAGED_DEBT_FACTOR, "max factor stored");
    }

    function testInitialize_RevertsWhenLeveragedDebtFactorExceedsMax() external {
        POLend implementation = new POLend();

        vm.expectRevert(IPOLend.InvalidConfig.selector);
        _deployPOLendWithImplementation(
            implementation,
            1e18,
            MAX_LEVERAGED_DEBT_FACTOR + 1,
            address(this),
            address(launcher),
            address(splitter),
            address(this)
        );
    }

    function testInitialize_RevertsWhenRequiredAddressesAreZero() external {
        POLend implementation = new POLend();

        vm.expectRevert(IPOLend.ZeroInput.selector);
        _deployPOLendWithImplementation(
            implementation, 1e17, 10e18, address(0), address(launcher), address(splitter), address(this)
        );

        implementation = new POLend();

        vm.expectRevert(IPOLend.ZeroInput.selector);
        _deployPOLendWithImplementation(
            implementation, 1e17, 10e18, address(this), address(0), address(splitter), address(this)
        );

        implementation = new POLend();

        vm.expectRevert(IPOLend.ZeroInput.selector);
        _deployPOLendWithImplementation(
            implementation, 1e17, 10e18, address(this), address(launcher), address(0), address(this)
        );
    }

    function testImplementationInitializerIsDisabled() external {
        POLend implementation = new POLend();

        vm.expectRevert(INVALID_INITIALIZATION_SELECTOR);
        implementation.initialize(
            address(this), 1e17, 10e18, address(this), address(launcher), address(splitter), address(this)
        );
    }

    function testSetMaxSettlementDustReserve_ConfiguresGlobalState() external {
        BurnableMockERC20 extraUAsset = new BurnableMockERC20("EXTRA", "EXTRA");

        vm.expectEmit(true, false, false, true);
        emit SettlementDustReserveConfigured(address(extraUAsset), 0, uint128(MAX_SETTLEMENT_DUST));
        polend.setMaxSettlementDustReserve(address(extraUAsset), uint128(MAX_SETTLEMENT_DUST));

        (uint128 reserve, uint128 maxReserve) = polend.settlementDustStates(address(extraUAsset));
        assertEq(reserve, 0, "reserve");
        assertEq(maxReserve, uint128(MAX_SETTLEMENT_DUST), "max reserve");
    }

    function testSetMaxSettlementDustReserve_RevertsWhenLoweringBelowReserve() external {
        _fundDustReserveFromAlice(MAX_SETTLEMENT_DUST);

        vm.expectRevert(IPOLend.InvalidConfig.selector);
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST - 1));
    }

    function testRegisterLendMarket_RevertsWhenSettlementDustReserveUnconfigured() external {
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(splitter));
        uint256 verseId = 98;
        launcher.setVerseUAsset(verseId, address(uAsset));

        vm.expectRevert(IPOLend.InvalidConfig.selector);
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);
    }

    function testLeveragedGenesis_AccumulatesInterestAndDebt() external {
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        uint256 borrowed = polend.leveragedGenesis(VERSE_ID, 10 ether);
        assertEq(borrowed, 100 ether, "borrowed");

        uint256 interestPaid = polend.leveragedInterestPaid(VERSE_ID, ALICE);
        assertEq(interestPaid, 10 ether, "interest");
        assertEq(polend.getUserLeveragedDebt(VERSE_ID, ALICE), 100 ether, "debt");
        assertEq(polend.getTotalLeveragedDebt(VERSE_ID), 100 ether, "total debt");
    }

    function testLeveragedGenesis_EmitsLeveragedGenesis() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.expectEmit(true, true, false, true);
        emit LeveragedGenesis(VERSE_ID, ALICE, 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);
    }

    function testLeveragedGenesis_ReentrantTransferKeepsAccumulatedInterest() external {
        HookedBurnableMockERC20 hookedUAsset = new HookedBurnableMockERC20("HOOK", "HOOK");
        polend.setMaxSettlementDustReserve(address(hookedUAsset), uint128(MAX_SETTLEMENT_DUST));
        hookedUAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        hookedUAsset.approve(address(polend), 10 ether);

        launcher.setVerseUAsset(VERSE_ID, address(hookedUAsset));
        launcher.setFundMetaData(address(hookedUAsset), 1_000 ether, 1);
        seedMarketUAssetForTest(address(polend), VERSE_ID, address(hookedUAsset));
        hookedUAsset.enableLeveragedGenesisReentry(address(polend), VERSE_ID, 5 ether);

        vm.prank(ALICE);
        uint256 borrowed = polend.leveragedGenesis(VERSE_ID, 10 ether);

        assertEq(borrowed, 100 ether, "borrowed");
        assertEq(hookedUAsset.balanceOf(address(polend)), 15 ether, "transferred");
        assertEq(polend.leveragedInterestPaid(VERSE_ID, ALICE), 10 ether, "interest");
        assertEq(polend.leveragedInterestPaid(VERSE_ID, address(hookedUAsset)), 5 ether, "reentry interest");
        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), 15 ether, "total interest");
        assertEq(polend.getTotalLeveragedDebt(VERSE_ID), 150 ether, "total debt");
    }

    function testLeveragedGenesis_UsesFullPrecisionDebtMathForLargeInterest() external {
        uint256 largeInterest = uint256(type(uint128).max) / 2;
        uint256 verseId = 101;
        POLend localPolend = _deployPOLend(1e18, 1e18, address(this), address(launcher), address(splitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), largeInterest, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        uAsset.mint(ALICE, largeInterest);
        vm.prank(ALICE);
        uAsset.approve(address(localPolend), largeInterest);

        vm.prank(ALICE);
        uint256 borrowed = localPolend.leveragedGenesis(verseId, largeInterest);

        assertEq(borrowed, largeInterest, "borrowed");
        assertEq(localPolend.getUserLeveragedDebt(verseId, ALICE), largeInterest, "user debt");
        assertEq(localPolend.getTotalLeveragedDebt(verseId), largeInterest, "total debt");
    }

    function testLeveragedGenesis_RevertsOutsideLauncherGenesisWithoutStateOrTransfer() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        launcher.setVerseStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidState.selector);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(uAsset.balanceOf(address(polend)), 0, "no transfer");
        assertEq(market.totalLeveragedInterest, 0, "interest unchanged");
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.None), "state unchanged");
        assertEq(polend.leveragedInterestPaid(VERSE_ID, ALICE), 0, "position unchanged");
    }

    function testLeveragedGenesis_UsesMinTotalFundForDebtCapWhenNormalFundsAreZero() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        launcher.setGenesisFunds(VERSE_ID, 0);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        uAsset.mint(ALICE, 1_001 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 1_001 ether);

        vm.prank(ALICE);
        assertEq(polend.leveragedGenesis(VERSE_ID, 1_000 ether), 10_000 ether, "within cap");

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.DebtCapExceeded.selector);
        polend.leveragedGenesis(VERSE_ID, 1 ether);
    }

    // --- leveragedGenesisWithCredit ---

    /// @dev Stand up a fresh MockGenesisCreditFactory + credit token, register the
    ///      (uAsset -> credit) pair, fund `user` with `amount` and approve POLend.
    function _setupCreditPath(address user, uint256 amount)
        internal
        returns (BurnableMockERC20 credit, MockGenesisCreditFactory factory)
    {
        factory = new MockGenesisCreditFactory();
        credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(uAsset), address(credit));
        polend.setCreditFactory(address(factory));
        credit.mint(user, amount);
        vm.prank(user);
        credit.approve(address(polend), amount);
    }

    function test_LeveragedGenesisWithCredit_TransfersCreditAndAccumulates() external {
        (BurnableMockERC20 credit,) = _setupCreditPath(ALICE, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit LeveragedGenesisWithCredit(VERSE_ID, ALICE, 10 ether);
        vm.prank(ALICE);
        uint256 borrowed = polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);

        assertEq(borrowed, 100 ether, "borrowed");
        assertEq(credit.balanceOf(address(polend)), 10 ether, "polend escrows credit");
        assertEq(credit.balanceOf(ALICE), 0, "user credit consumed");

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(market.totalLeveragedInterest, 10 ether, "aggregate interest");
        assertEq(market.totalCreditInterest, 10 ether, "credit interest tally");
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Genesis), "state genesis");
        // Aggregate debt view sees real + credit interest converted through the same rate.
        assertEq(polend.getUserLeveragedDebt(VERSE_ID, ALICE), 100 ether, "user debt");
    }

    function test_RevertWhen_NoCreditForUAsset() external {
        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        polend.setCreditFactory(address(factory));
        // Factory has no credit registered for `uAsset` => factory.creditOf returns address(0).

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.NoCreditForUAsset.selector);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);
    }

    function test_RevertWhen_LeveragedGenesisWithCredit_ZeroAmount() external {
        _setupCreditPath(ALICE, 0);

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.ZeroInput.selector);
        polend.leveragedGenesisWithCredit(VERSE_ID, 0);
    }

    function test_RevertWhen_LeveragedGenesisWithCredit_NotGenesisStage() external {
        _setupCreditPath(ALICE, 10 ether);
        launcher.setVerseStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidState.selector);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);
    }

    /// @dev GenesisCredit is fixed at 18 decimals, so a 6-dec uAsset must not enter the credit path:
    ///     its raw credit units would be treated as raw uAsset interest, scaling debt / launch gate /
    ///     YT / residual by 1e12. POLend must reject the mismatch on first credit-token resolution
    ///     (after `creditOf` succeeds, before caching) with `CreditDecimalsMismatch(uAsset, credit)`.
    function test_RevertWhen_LeveragedGenesisWithCredit_CreditDecimalsMismatch() external {
        uint256 verseId = 300;
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        launcher.setVerseUAsset(verseId, address(usdc));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(usdc), 1_000 ether, 1);
        polend.setMaxSettlementDustReserve(address(usdc), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        polend.registerLendMarket(verseId);

        // 18-dec GenesisCredit mapped to a 6-dec uAsset — exactly the misconfiguration the check
        // guards against. The check fires before any transferFrom, so no credit funding is needed.
        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        BurnableMockERC20 credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(usdc), address(credit));
        polend.setCreditFactory(address(factory));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IPOLend.CreditDecimalsMismatch.selector, uint8(6), uint8(18)));
        polend.leveragedGenesisWithCredit(verseId, 10 ether);
    }

    function test_LeveragedGenesisWithCredit_RespectsDebtCap() external {
        // Configure tight debt cap: interestRate=1e18, factor=2e18, minTotalFund=100 → cap=200 debt.
        uint256 verseId = 250;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), 100, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        BurnableMockERC20 credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(uAsset), address(credit));
        localPolend.setCreditFactory(address(factory));

        credit.mint(ALICE, 201);
        vm.prank(ALICE);
        credit.approve(address(localPolend), 201);

        // 200 credit interest => previewDebt = 200 == cap, accepted.
        vm.prank(ALICE);
        localPolend.leveragedGenesisWithCredit(verseId, 200);

        // 1 more credit => previewDebt = 201 > 200 => DebtCapExceeded.
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.DebtCapExceeded.selector);
        localPolend.leveragedGenesisWithCredit(verseId, 1);
    }

    function test_LeveragedGenesisWithCredit_RevertsWhenAggregateTotalGenesisFundsWouldExceedSupportedMaximum()
        external
    {
        // normalFunds at the uint128 ceiling => aggregate genesis cap = 0. With
        // actualNormalFunds == MAX the strict-`>` L233 guard is false, and the huge
        // capBase keeps L238 (_debtCap) out of reach, so any credit debt hits only
        // the L237 MAX_SUPPORTED guard => InvalidConfig (not DebtCapExceeded).
        // Mirrors the real-uAsset aggregate case (testLeveragedGenesis_...Aggregate...).
        uint256 verseId = 251;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, type(uint128).max);
        launcher.setFundMetaData(address(uAsset), 1, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        BurnableMockERC20 credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(uAsset), address(credit));
        localPolend.setCreditFactory(address(factory));

        credit.mint(ALICE, 1);
        vm.prank(ALICE);
        credit.approve(address(localPolend), 1);

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        localPolend.leveragedGenesisWithCredit(verseId, 1);
    }

    function test_LeveragedGenesisWithCredit_RevertsWhenCumulativeAggregateTotalGenesisFundsWouldExceedSupportedMaximum()
        external
    {
        // normalFunds = MAX - 10 => aggregate genesis cap = 10. capBase = max(1,
        // MAX-10) is huge, so L238 (_debtCap) never binds; the L237 MAX guard is the
        // sole gate. First credit(10) fits exactly (previewDebt == cap); a further
        // credit(1) pushes cumulative debt to 11 > 10 => InvalidConfig.
        // Mirrors the real-uAsset cumulative case (testLeveragedGenesis_...Cumulative...).
        uint256 verseId = 252;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, uint256(type(uint128).max) - 10);
        launcher.setFundMetaData(address(uAsset), 1, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        BurnableMockERC20 credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(address(uAsset), address(credit));
        localPolend.setCreditFactory(address(factory));

        credit.mint(ALICE, 11);
        vm.prank(ALICE);
        credit.approve(address(localPolend), 11);

        // First credit(10): previewDebt 10 == aggregate cap 10, accepted.
        vm.prank(ALICE);
        localPolend.leveragedGenesisWithCredit(verseId, 10);

        // Second credit(1): cumulative previewDebt 11 > aggregate cap 10 => InvalidConfig.
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        localPolend.leveragedGenesisWithCredit(verseId, 1);
    }

    function test_LeveragedGenesisWithCredit_MixedWithRealGenesis() external {
        // Real leveraged genesis first.
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        // Then credit-funded leveraged genesis for the same verse & user.
        (BurnableMockERC20 credit,) = _setupCreditPath(BOB, 4 ether);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(VERSE_ID, 4 ether);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(market.totalLeveragedInterest, 14 ether, "aggregate interest");
        assertEq(market.totalCreditInterest, 4 ether, "credit-only tally");
        assertEq(uAsset.balanceOf(address(polend)), 10 ether, "uAsset escrow unchanged");
        assertEq(credit.balanceOf(address(polend)), 4 ether, "credit escrow");
        assertEq(polend.leveragedInterestPaid(VERSE_ID, ALICE), 10 ether, "alice real interest");
        // Getter now returns the view-layer aggregate (real + credit): BOB has 0 real + 4e18 credit.
        assertEq(polend.leveragedInterestPaid(VERSE_ID, BOB), 4 ether, "bob combined real+credit interest");
        // BOB's debt comes from credit ledger only; aggregate user debt view sums both ledgers.
        assertEq(polend.getUserLeveragedDebt(VERSE_ID, BOB), 40 ether, "bob debt via credit");
        assertEq(polend.getUserLeveragedDebt(VERSE_ID, ALICE), 100 ether, "alice debt via real");
        assertEq(polend.getTotalLeveragedDebt(VERSE_ID), 140 ether, "total debt aggregates");
    }

    function testRegisterLendMarket_TargetABIReadsUAssetAndDoesNotInitializeTokens() external {
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(localSplitter));
        uint256 verseId = 99;
        launcher.setVerseUAsset(verseId, address(uAsset));
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));

        vm.prank(address(launcher));
        (bool success,) = address(localPolend).call(abi.encodeWithSignature("registerLendMarket(uint256)", verseId));

        assertTrue(success, "one-arg register");
        IPOLend.LendMarket memory market = localPolend.getLendMarket(verseId);
        assertEq(market.uAsset, address(uAsset), "uAsset from launcher");
        assertEq(localSplitter.deployTokensCallCount(), 0, "no deployTokens during register");
        assertEq(localSplitter.initializeVerseCallCount(), 0, "no initializeVerse during register");
    }

    function testRegisterLendMarket_RevertsOnDuplicateVerse() external {
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(localSplitter));
        uint256 verseId = 100;
        launcher.setVerseUAsset(verseId, address(uAsset));
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));

        vm.startPrank(address(launcher));
        (bool first,) = address(localPolend).call(abi.encodeWithSignature("registerLendMarket(uint256)", verseId));
        (bool second,) = address(localPolend).call(abi.encodeWithSignature("registerLendMarket(uint256)", verseId));
        vm.stopPrank();

        assertTrue(first, "first register");
        assertFalse(second, "duplicate register");
    }

    function testRegisterLendMarket_TreatsExistingUAssetAsRegisteredWhenRateIsZero() external {
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(localSplitter));
        uint256 verseId = 101;
        launcher.setVerseUAsset(verseId, address(uAsset));
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        seedMarketUAssetForTest(address(localPolend), verseId, address(uAsset));

        vm.prank(address(launcher));
        vm.expectRevert(IPOLend.InvalidState.selector);
        localPolend.registerLendMarket(verseId);
    }

    function testRegisterLendMarket_RevertsWhenLauncherReturnsZeroUAsset() external {
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(localSplitter));
        uint256 verseId = 102;

        vm.prank(address(launcher));
        vm.expectRevert(IPOLend.ZeroInput.selector);
        localPolend.registerLendMarket(verseId);
    }

    function testSetDefaultInterestRate_RevertsWhenDebtFactorAndRateCannotReachThreshold() external {
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 1e18, address(this), address(launcher), address(localSplitter));

        vm.expectRevert(IPOLend.InvalidConfig.selector);
        localPolend.setDefaultInterestRate(1);

        assertEq(localPolend.defaultInterestRate(), 1e18, "rate unchanged");
    }

    function testDebtCapacityAndLeveragedGenesis_DoNotPanicAtLargeFactorAndLargeFundBase() external {
        uint256 largeFactor = 2e18;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, largeFactor, address(this), address(launcher), address(localSplitter));
        uint256 verseId = 103;
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), type(uint128).max, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        IPOLend.LeveragedDebtInfo memory info = localPolend.getLeveragedDebtInfo(verseId);

        assertEq(info.totalLeveragedInterest, 0, "interest");
        assertEq(info.debtCap, type(uint128).max, "debt cap clamped by aggregate cap");
        assertGt(info.remainingAdditionalInterest, 0, "remaining");
    }

    function testDebtCapacity_SaturatedDebtCapDoesNotReportUnreachableRemainingInterest() external {
        uint256 verseId = 107;
        uint256 rate = 5e17;
        uint256 largeFactor = MAX_LEVERAGED_DEBT_FACTOR;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(rate, largeFactor, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), type(uint128).max, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        IPOLend.LeveragedDebtInfo memory info = localPolend.getLeveragedDebtInfo(verseId);
        uint256 clampedDebtCap = type(uint128).max;
        uint256 expectedMaxTotalInterest = Math.mulDiv(clampedDebtCap + 1, rate, 1e18, Math.Rounding.Ceil) - 1;

        assertEq(info.debtCap, type(uint128).max, "debt cap clamped by aggregate cap");
        assertEq(info.remainingAdditionalInterest, expectedMaxTotalInterest, "bounded remaining interest");
    }

    function testLeveragedGenesis_RevertsWhenAggregateTotalGenesisFundsWouldExceedSupportedMaximum() external {
        uint256 verseId = 108;
        uint256 rate = 1e18;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(rate, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, type(uint128).max);
        launcher.setFundMetaData(address(uAsset), 1, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        uAsset.mint(ALICE, 1);
        vm.prank(ALICE);
        uAsset.approve(address(localPolend), 1);
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        localPolend.leveragedGenesis(verseId, 1);
    }

    function testLeveragedGenesis_RevertsWhenCumulativeAggregateTotalGenesisFundsWouldExceedSupportedMaximum()
        external
    {
        uint256 verseId = 109;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, uint256(type(uint128).max) - 10);
        launcher.setFundMetaData(address(uAsset), 1, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        uAsset.mint(ALICE, 11);
        vm.prank(ALICE);
        uAsset.approve(address(localPolend), 11);

        vm.prank(ALICE);
        assertEq(localPolend.leveragedGenesis(verseId, 10), 10, "first debt");
        assertEq(localPolend.getTotalLeveragedDebt(verseId), 10, "total debt");

        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        localPolend.leveragedGenesis(verseId, 1);
    }

    /// @notice Verifies leveragedGenesis reverts with DebtCapExceeded when interest pushes debt exactly 1 unit over the debt cap.
    function testLeveragedGenesis_RevertsWhenDebtExceedsCapByOne() external {
        // Setup: interestRate = 1e18 (1:1 mapping), debtFactor = 2e18, minTotalFund = 100
        // debtCap = debtFactor * capBase / 1e18 = 2e18 * 100 / 1e18 = 200
        // With interestRate = 1e18: previewTotalDebt = interest * 1e18 / 1e18 = interest
        // So: borrow 200 interest => debt = 200 = debtCap => succeeds
        // Then: borrow 1 more interest => debt would be 201 > 200 => reverts
        uint256 verseId = 150;
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), 100, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        // Verify debt cap = 200
        IPOLend.LeveragedDebtInfo memory info = localPolend.getLeveragedDebtInfo(verseId);
        assertEq(info.debtCap, 200, "debt cap");

        // Borrow exactly up to the cap: 200 interest => previewTotalDebt = 200 = debtCap
        uAsset.mint(ALICE, 200);
        vm.prank(ALICE);
        uAsset.approve(address(localPolend), 200);
        vm.prank(ALICE);
        localPolend.leveragedGenesis(verseId, 200);

        // Borrow 1 more => previewTotalDebt = 201 > 200 => revert
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.DebtCapExceeded.selector);
        localPolend.leveragedGenesis(verseId, 1);
    }

    function testGetLeveragedDebtInfo_UsesCeilDerivedRemainingInterestCapacity() external {
        uint256 verseId = 106;
        POLend localPolend = _deployPOLend(0.7 ether, 2 ether, address(this), address(launcher), address(splitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 0);
        launcher.setFundMetaData(address(uAsset), 1, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        IPOLend.LeveragedDebtInfo memory info = localPolend.getLeveragedDebtInfo(verseId);

        assertEq(info.debtCap, 2, "debt cap");
        assertEq(info.remainingAdditionalInterest, 2, "ceil-derived capacity");
    }

    function testGetLeveragedDebtInfo_ReturnsZeroCapacityWhenDustCapUnset() external {
        seedSettlementDustStateForTest(address(polend), address(uAsset), 0, 0);
        (uint256 totalInterest, uint256 totalDebt, uint256 rate, uint256 debtCap, uint256 remaining) =
            _getLeveragedDebtInfo(VERSE_ID);

        assertEq(totalInterest, 0, "interest");
        assertEq(totalDebt, 0, "debt");
        assertEq(rate, 1e17, "rate");
        assertEq(debtCap, 0, "debt cap");
        assertEq(remaining, 0, "remaining");
    }

    function testFinalizeLeveragedGenesis_LocksMarketMintsDebtAndSweepsInterest() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        vm.prank(address(launcher));
        (bool success,) = address(polend).call(abi.encodeWithSignature("finalizeLeveragedGenesis(uint256)", VERSE_ID));

        assertTrue(success, "finalize");
        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(uint256(market.state), 2, "state locked");
        assertEq(uAsset.balanceOf(address(launcher)), 100 ether, "minted debt to launcher");
        assertEq(uAsset.balanceOf(address(this)) - treasuryBefore, 10 ether, "interest swept to treasury");
    }

    function testFinalizeLeveragedGenesis_SweepsFullInterestToTreasuryNoReserveCredit() external {
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);
        uint256 treasuryBefore = uAsset.balanceOf(address(this));

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserve, 0, "no reserve credit from interest");
        assertEq(uAsset.balanceOf(address(this)), treasuryBefore + 10 ether, "full treasury sweep");
        assertEq(uAsset.balanceOf(address(polend)), 0, "all interest swept out of polend");
    }

    // --- finalizeLeveragedGenesis: credit-aware split & burn ---

    /// @notice Mixed-source finalize: the full real-uAsset slice sweeps to the treasury; the
    ///         credit-funded slice is burned in-place from POLend's escrow.
    function test_Finalize_RealInterestSweepsToTreasuryCreditBurned() external {
        // Real 100e18 (uAsset) + credit 50e18 (mock credit) => aggregate 150e18 interest,
        // debt = 150e18 / 0.1e18 = 1_500e18.
        uAsset.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 100 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 100 ether);

        (BurnableMockERC20 credit,) = _setupCreditPath(BOB, 50 ether);
        vm.prank(BOB);
        polend.leveragedGenesisWithCredit(VERSE_ID, 50 ether);

        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        uint256 polendCreditBefore = credit.balanceOf(address(polend));
        assertEq(polendCreditBefore, 50 ether, "polend escrows credit pre-finalize");

        vm.expectEmit(true, true, false, true);
        emit CreditBurned(VERSE_ID, address(uAsset), 50 ether);
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        // Aggregate debt still minted to launcher.
        assertEq(uAsset.balanceOf(address(launcher)), 1_500 ether, "aggregate debt minted");
        // Full real interest sweeps to treasury; no reserve credit from interest.
        assertEq(uAsset.balanceOf(address(this)) - treasuryBefore, 100 ether, "full real interest to treasury");
        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserve, 0, "no reserve credit from interest");
        // Credit escrow burned to zero; no credit transferred elsewhere.
        assertEq(credit.balanceOf(address(polend)), 0, "credit burned from escrow");
        assertEq(credit.totalSupply(), 0, "credit supply reduced by burn");
    }

    /// @notice A second credit entry after a factory swap must still escrow into the token cached
    ///     at first entry. The finalize/claimRefund factory-swap tests enter only once, so they
    ///     cannot catch a regression that re-resolves and overwrites the cache on every entry
    ///     (which would strand the first entrant's credit once the factory mapping changes).
    function test_LeveragedGenesisWithCredit_SecondEntryUsesCachedCreditTokenAfterFactoryChange() external {
        // First entry locks the cache to creditA.
        (BurnableMockERC20 creditA,) = _setupCreditPath(ALICE, 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);

        // Swap the factory mapping to a different token for the same uAsset.
        MockGenesisCreditFactory factoryB = new MockGenesisCreditFactory();
        BurnableMockERC20 creditB = new BurnableMockERC20("CREDIT_B", "CREDIT_B");
        factoryB.setCreditOf(address(uAsset), address(creditB));
        polend.setCreditFactory(address(factoryB));

        // BOB approves both tokens so the entry succeeds whichever token it pulls; the balance
        // assertions below discriminate, rather than relying on a transferFrom revert.
        creditA.mint(BOB, 10 ether);
        creditB.mint(BOB, 10 ether);
        vm.startPrank(BOB);
        creditA.approve(address(polend), 10 ether);
        creditB.approve(address(polend), 10 ether);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);
        vm.stopPrank();

        // Second entry must escrow into the cached creditA, not re-resolve to creditB.
        assertEq(creditA.balanceOf(address(polend)), 20 ether, "both entries escrowed in creditA");
        assertEq(creditB.balanceOf(address(polend)), 0, "creditB not pulled");
        assertEq(polend.getLendMarket(VERSE_ID).creditToken, address(creditA), "cache still creditA");
    }

    /// @notice Finalize burns the credit token cached at entry even if the factory mapping changes.
    function test_Finalize_ReadsCachedCreditTokenAfterFactoryChange() external {
        (BurnableMockERC20 creditA,) = _setupCreditPath(ALICE, 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);

        MockGenesisCreditFactory factoryB = new MockGenesisCreditFactory();
        BurnableMockERC20 creditB = new BurnableMockERC20("CREDIT_B", "CREDIT_B");
        factoryB.setCreditOf(address(uAsset), address(creditB));
        polend.setCreditFactory(address(factoryB));
        creditB.mint(address(polend), 10 ether);

        uint256 polendCreditABefore = creditA.balanceOf(address(polend));
        uint256 creditASupplyBefore = creditA.totalSupply();
        uint256 polendCreditBBefore = creditB.balanceOf(address(polend));
        uint256 creditBSupplyBefore = creditB.totalSupply();

        // Factory changes after entry must not redirect the cached credit escrow.
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        assertEq(creditA.burnedAmount(), polendCreditABefore, "creditA burned");
        assertEq(creditA.balanceOf(address(polend)), 0, "creditA escrow cleared");
        assertEq(creditA.totalSupply(), creditASupplyBefore - polendCreditABefore, "creditA supply burned");
        assertEq(creditB.burnedAmount(), 0, "creditB not burned");
        assertEq(creditB.balanceOf(address(polend)), polendCreditBBefore, "creditB decoy unchanged");
        assertEq(creditB.totalSupply(), creditBSupplyBefore, "creditB supply unchanged");
    }

    /// @notice Pure-credit finalize: real slice is zero, so no dust/treasury movement; only burn.
    function test_Finalize_PureCredit_NoReserveTreasury_OnlyBurn() external {
        (BurnableMockERC20 credit,) = _setupCreditPath(ALICE, 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);

        uint256 treasuryBefore = uAsset.balanceOf(address(this));
        (uint128 reserveBefore,) = polend.settlementDustStates(address(uAsset));

        vm.expectEmit(true, true, false, true);
        emit CreditBurned(VERSE_ID, address(uAsset), 10 ether);
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        assertEq(uAsset.balanceOf(address(this)), treasuryBefore, "no treasury sweep");
        (uint128 reserveAfter,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserveAfter, reserveBefore, "no reserve credit");
        // Debt = 10e18 / 0.1e18 = 100e18, still minted from credit-only interest.
        assertEq(uAsset.balanceOf(address(launcher)), 100 ether, "debt minted from credit");
        assertEq(credit.balanceOf(address(polend)), 0, "credit fully burned");
        assertEq(credit.totalSupply(), 0, "credit supply zero");
    }

    /// @notice Pure-real finalize: no credit participants => no burn call, behavior matches
    ///         pre-credit-feature finalize.
    function test_Finalize_PureReal_NoBurn() external {
        // Register a credit factory + token so any errant burn would be observable.
        (BurnableMockERC20 credit,) = _setupCreditPath(BOB, 0);
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        uint256 creditSupplyBefore = credit.totalSupply();
        uint256 polendCreditBefore = credit.balanceOf(address(polend));
        uint256 treasuryBefore = uAsset.balanceOf(address(this));

        // No CreditBurned fires; the full real interest sweeps to treasury.
        vm.recordLogs();
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 creditBurnedTopic = keccak256("CreditBurned(uint256,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != creditBurnedTopic, "no CreditBurned");
        }

        assertEq(credit.totalSupply(), creditSupplyBefore, "credit supply unchanged");
        assertEq(credit.balanceOf(address(polend)), polendCreditBefore, "no credit escrow change");
        assertEq(uAsset.balanceOf(address(launcher)), 100 ether, "debt minted");
        assertEq(uAsset.balanceOf(address(this)) - treasuryBefore, 10 ether, "treasury swept real interest");
    }

    function testClaimRefund_ReturnsInterestOnlyInRefund() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        uAsset.mint(address(polend), 10 ether);

        vm.prank(ALICE);
        uint256 refunded = _claimRefund(VERSE_ID, CAROL);
        assertEq(refunded, 10 ether, "refund interest only");
        assertEq(uAsset.balanceOf(CAROL), 10 ether, "recipient refunded");
        assertEq(uAsset.balanceOf(ALICE), 0, "caller not recipient");
    }

    function testClaimRefund_MarksCallerAndRejectsZeroRecipient() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 5 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        uAsset.mint(address(polend), 15 ether);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimRefund(uint256,address)", VERSE_ID, address(0)), IPOLend.ZeroInput.selector
        );

        vm.prank(ALICE);
        assertEq(_claimRefund(VERSE_ID, CAROL), 10 ether, "alice refund");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimRefund(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );

        vm.prank(BOB);
        assertEq(_claimRefund(VERSE_ID, ALICE), 5 ether, "bob refund");
        assertEq(uAsset.balanceOf(ALICE), 5 ether, "bob recipient");
    }

    function testClaimRefund_BlocksReentrantClaim() external {
        ReentrantClaimMockERC20 hookedUAsset = new ReentrantClaimMockERC20("HOOK", "HOOK");
        POLend localPolend = _deployPOLend(1e17, 10e18, address(this), address(launcher), address(splitter));
        uint256 verseId = 201;
        launcher.setVerseUAsset(verseId, address(hookedUAsset));
        localPolend.setMaxSettlementDustReserve(address(hookedUAsset), uint128(MAX_SETTLEMENT_DUST));

        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);
        seedLeveragedPositionForTest(address(localPolend), verseId, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(localPolend), verseId, BOB, 5 ether);
        setRefundStateForTest(address(localPolend), verseId);
        hookedUAsset.mint(address(localPolend), 15 ether);
        hookedUAsset.armReentry(
            address(localPolend),
            abi.encodeWithSignature("claimRefund(uint256,address)", verseId, BOB),
            bytes4(keccak256("ReentrancyGuardReentrantCall()"))
        );

        vm.prank(ALICE);
        localPolend.claimRefund(verseId, CAROL);

        assertTrue(hookedUAsset.sawExpectedRevert(), "reentrant refund blocked");
    }

    /// @dev Mixed participant: holds both real-uAsset and credit interest. Refund must pay out
    ///      both ledgers and emit both events.
    function test_ClaimRefund_RefundsCreditAndUAsset() external {
        BurnableMockERC20 credit = _wireCreditFactoryForUAsset(address(uAsset));
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 100 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 50 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        // Direct-seeded credit position bypasses leveragedGenesisWithCredit, so cache the credit token
        // the production claimRefund reads; otherwise it reverts NoCreditForUAsset.
        seedMarketCreditTokenForTest(address(polend), VERSE_ID, address(credit));
        uAsset.mint(address(polend), 100 ether);
        credit.mint(address(polend), 50 ether);

        vm.expectEmit(true, true, true, true);
        emit ClaimRefund(VERSE_ID, ALICE, CAROL, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit CreditRefunded(VERSE_ID, ALICE, CAROL, 50 ether);
        vm.prank(ALICE);
        uint256 refunded = _claimRefund(VERSE_ID, CAROL);

        assertEq(refunded, 100 ether, "returns real-uAsset amount only");
        assertEq(uAsset.balanceOf(CAROL), 100 ether, "uAsset refunded");
        assertEq(credit.balanceOf(CAROL), 50 ether, "credit refunded");
    }

    /// @notice Refund pays the credit token cached at entry even if the factory mapping changes.
    function test_ClaimRefund_ReadsCachedCreditTokenAfterFactoryChange() external {
        (BurnableMockERC20 creditA,) = _setupCreditPath(ALICE, 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesisWithCredit(VERSE_ID, 10 ether);

        MockGenesisCreditFactory factoryB = new MockGenesisCreditFactory();
        BurnableMockERC20 creditB = new BurnableMockERC20("CREDIT_B", "CREDIT_B");
        factoryB.setCreditOf(address(uAsset), address(creditB));
        polend.setCreditFactory(address(factoryB));
        creditB.mint(address(polend), 10 ether);

        uint256 polendCreditBBefore = creditB.balanceOf(address(polend));

        vm.prank(address(launcher));
        polend.markRefundable(VERSE_ID);

        // Factory changes after entry must not redirect the cached credit refund.
        vm.prank(ALICE);
        _claimRefund(VERSE_ID, CAROL);

        assertEq(creditA.balanceOf(CAROL), 10 ether, "carol got creditA");
        assertEq(creditB.balanceOf(CAROL), 0, "carol got no creditB");
        assertEq(creditA.balanceOf(address(polend)), 0, "creditA escrow cleared");
        assertEq(creditB.balanceOf(address(polend)), polendCreditBBefore, "creditB decoy unchanged");
        assertEq(creditB.burnedAmount(), 0, "creditB not burned");
    }

    /// @dev Pure credit participant: realPaid == 0 must not revert; only credit branch fires.
    function test_ClaimRefund_PureCreditUser_GetsNoUAsset_OnlyCredit() external {
        BurnableMockERC20 credit = _wireCreditFactoryForUAsset(address(uAsset));
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 50 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        // Direct-seeded credit position bypasses leveragedGenesisWithCredit, so cache the credit token
        // the production claimRefund reads; otherwise it reverts NoCreditForUAsset.
        seedMarketCreditTokenForTest(address(polend), VERSE_ID, address(credit));
        credit.mint(address(polend), 50 ether);

        vm.recordLogs();
        vm.prank(ALICE);
        uint256 refunded = _claimRefund(VERSE_ID, CAROL);

        assertEq(refunded, 0, "no real-uAsset refunded");
        assertEq(uAsset.balanceOf(CAROL), 0, "no uAsset transferred");
        assertEq(credit.balanceOf(CAROL), 50 ether, "credit refunded");

        // No `ClaimRefund` event should fire when realPaid == 0; `CreditRefunded` must fire exactly once.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 claimRefundSig = keccak256("ClaimRefund(uint256,address,address,uint256)");
        bytes32 creditRefundedSig = keccak256("CreditRefunded(uint256,address,address,uint256)");
        uint256 claimRefundCount;
        uint256 creditRefundedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(polend)) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == claimRefundSig) ++claimRefundCount;
            else if (logs[i].topics[0] == creditRefundedSig) ++creditRefundedCount;
        }
        assertEq(claimRefundCount, 0, "no ClaimRefund event");
        assertEq(creditRefundedCount, 1, "one CreditRefunded event");
    }

    /// @dev Back-compat: pure real-uAsset participant matches legacy behaviour exactly (no credit
    ///      branch, no factory call, ClaimRefund only).
    function test_ClaimRefund_PureRealUser_BackCompat() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        uAsset.mint(address(polend), 10 ether);

        vm.expectEmit(true, true, true, true);
        emit ClaimRefund(VERSE_ID, ALICE, CAROL, 10 ether);
        vm.prank(ALICE);
        uint256 refunded = _claimRefund(VERSE_ID, CAROL);

        assertEq(refunded, 10 ether, "refund returns real amount");
        assertEq(uAsset.balanceOf(CAROL), 10 ether, "uAsset refunded");
    }

    function test_RevertWhen_ClaimRefund_BothLedgersZero() external {
        setRefundStateForTest(address(polend), VERSE_ID);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimRefund(uint256,address)", VERSE_ID, CAROL), IPOLend.InvalidClaim.selector
        );
    }

    function test_RevertWhen_ClaimRefund_AlreadyClaimedAcrossBothLedgers() external {
        BurnableMockERC20 credit = _wireCreditFactoryForUAsset(address(uAsset));
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 5 ether);
        setRefundStateForTest(address(polend), VERSE_ID);
        // Direct-seeded credit position bypasses leveragedGenesisWithCredit, so cache the credit token
        // the production claimRefund reads; otherwise it reverts NoCreditForUAsset.
        seedMarketCreditTokenForTest(address(polend), VERSE_ID, address(credit));
        uAsset.mint(address(polend), 10 ether);
        credit.mint(address(polend), 5 ether);

        vm.prank(ALICE);
        _claimRefund(VERSE_ID, CAROL);

        // Second claim must revert via the `CLAIM_REFUND` flag, regardless of remaining balance.
        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimRefund(uint256,address)", VERSE_ID, CAROL), IPOLend.InvalidClaim.selector
        );
    }

    /// @dev Stand up a fresh MockGenesisCreditFactory + credit token for the given uAsset and
    ///      wire it into POLend. Returns the credit token so tests can mint/inspect balances.
    function _wireCreditFactoryForUAsset(address uAsset_) internal returns (BurnableMockERC20 credit) {
        MockGenesisCreditFactory factory = new MockGenesisCreditFactory();
        credit = new BurnableMockERC20("CREDIT", "CREDIT");
        factory.setCreditOf(uAsset_, address(credit));
        polend.setCreditFactory(address(factory));
    }

    function testClaimLeveragedYT_MarksCallerAndTransfersToRecipient() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 30 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 40 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 400 ether);
        yt.mint(address(polend), 400 ether);

        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 100 ether, "alice yt");
        assertEq(yt.balanceOf(CAROL), 100 ether, "recipient yt");
        assertEq(yt.balanceOf(ALICE), 0, "caller not recipient");

        vm.prank(BOB);
        assertEq(_claimLeveragedYT(VERSE_ID, ALICE), 300 ether, "bob yt");
        assertEq(yt.balanceOf(ALICE), 300 ether, "bob can still claim");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
    }

    function testClaimLeveragedYT_RevertsWhenRecipientIsZero() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 100 ether);
        yt.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, address(0)),
            IPOLend.ZeroInput.selector
        );
    }

    function testClaimLeveragedYT_UsesInterestShareInsteadOfRoundedDebtShare() external {
        uint256 verseId = 104;
        POLend localPolend = _deployPOLend(3, 1e36, address(this), address(launcher), address(splitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);
        seedLeveragedPositionForTest(address(localPolend), verseId, ALICE, 1);
        seedLeveragedPositionForTest(address(localPolend), verseId, BOB, 2);
        seedMarketForTest(address(localPolend), verseId, address(yt), 3);
        setLockedStateForTest(address(localPolend), verseId, 300 ether);
        yt.mint(address(localPolend), 300 ether);

        vm.prank(ALICE);
        (bool success, bytes memory data) =
            address(localPolend).call(abi.encodeWithSignature("claimLeveragedYT(uint256,address)", verseId, CAROL));

        assertTrue(success, "claim");
        assertEq(abi.decode(data, (uint256)), 100 ether, "interest-proportional yt");
        assertEq(yt.balanceOf(CAROL), 100 ether, "recipient yt");
    }

    /// @dev Pure-credit participant: real==0, credit==50e18, total=100e18 (BOB holds 50e18 real).
    ///      Credit user must receive YT pro-rata to their credit interest share.
    function test_ClaimLeveragedYT_CreditUserGetsProRataYT() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 50 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 100 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 400 ether);
        yt.mint(address(polend), 400 ether);

        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 200 ether, "credit-only YT share");
        assertEq(yt.balanceOf(CAROL), 200 ether, "recipient yt");
    }

    /// @dev Mixed participant: real=30, credit=20, total=100 (BOB holds 50 real).
    ///      Claim must use real+credit aggregate as the numerator.
    function test_ClaimLeveragedYT_MixedUser_GetsAggregatedShare() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 30 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 20 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 100 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 400 ether);
        yt.mint(address(polend), 400 ether);

        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 200 ether, "aggregated YT share");
        assertEq(yt.balanceOf(CAROL), 200 ether, "recipient yt");
    }

    /// @dev Both ledgers zero must revert via InvalidClaim, even when totalLeveragedInterest > 0.
    function test_RevertWhen_ClaimLeveragedYT_BothZero() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 50 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 100 ether);
        yt.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, CAROL), IPOLend.InvalidClaim.selector
        );
    }

    /// @dev Backward-compat: pure-real user (credit==0) keeps identical behavior.
    function test_ClaimLeveragedYT_PureReal_BackCompat() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 30 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 40 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 400 ether);
        yt.mint(address(polend), 400 ether);

        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 100 ether, "pure-real unchanged");
    }

    function testClaimLeveragedYT_BlocksReentrantClaim() external {
        ReentrantClaimMockERC20 hookedYT = new ReentrantClaimMockERC20("HOOKYT", "HOOKYT");
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 5 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(hookedYT), 15 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 150 ether);
        hookedYT.mint(address(polend), 150 ether);
        hookedYT.armReentry(
            address(polend),
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, BOB),
            bytes4(keccak256("ReentrancyGuardReentrantCall()"))
        );

        vm.prank(ALICE);
        polend.claimLeveragedYT(VERSE_ID, CAROL);

        assertTrue(hookedYT.sawExpectedRevert(), "reentrant yt claim blocked");
    }

    function testClaimResidual_MarksCallerAndTransfersToRecipient() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 30 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 40 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 50 ether, "uAsset");
        assertEq(memecoinAmount, 25 ether, "memecoin");
        assertEq(uAsset.balanceOf(CAROL), 50 ether, "recipient uAsset");
        assertEq(memecoin.balanceOf(CAROL), 25 ether, "recipient memecoin");
        assertEq(uAsset.balanceOf(ALICE), 0, "caller not recipient uAsset");
        assertEq(memecoin.balanceOf(ALICE), 0, "caller not recipient memecoin");

        vm.prank(BOB);
        (uAssetAmount, memecoinAmount) = _claimResidual(VERSE_ID, ALICE);
        assertEq(uAssetAmount, 150 ether, "bob uAsset");
        assertEq(memecoinAmount, 75 ether, "bob memecoin");
        assertEq(uAsset.balanceOf(ALICE), 150 ether, "bob can still claim");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
    }

    function testClaimResidual_RevertsWhenRecipientIsZero() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedResidualForTest(address(polend), VERSE_ID, 50 ether, 25 ether, 10 ether);
        uAsset.mint(address(polend), 50 ether);
        memecoin.mint(address(polend), 25 ether);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, address(0)), IPOLend.ZeroInput.selector
        );
    }

    function testClaimResidual_UsesInterestShareInsteadOfRoundedDebtShare() external {
        uint256 verseId = 105;
        POLend localPolend = _deployPOLend(3, 1e36, address(this), address(launcher), address(splitter));
        launcher.setVerseUAsset(verseId, address(uAsset));
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);
        seedLeveragedPositionForTest(address(localPolend), verseId, ALICE, 1);
        seedLeveragedPositionForTest(address(localPolend), verseId, BOB, 2);
        seedResidualForTest(address(localPolend), verseId, 300 ether, 600 ether, 3);
        uAsset.mint(address(localPolend), 300 ether);
        memecoin.mint(address(localPolend), 600 ether);

        vm.prank(ALICE);
        (bool success, bytes memory data) =
            address(localPolend).call(abi.encodeWithSignature("claimResidual(uint256,address)", verseId, CAROL));

        assertTrue(success, "claim");
        (uint256 uAssetAmount, uint256 memecoinAmount) = abi.decode(data, (uint256, uint256));
        assertEq(uAssetAmount, 100 ether, "interest-proportional uAsset");
        assertEq(memecoinAmount, 200 ether, "interest-proportional memecoin");
        assertEq(uAsset.balanceOf(CAROL), 100 ether, "recipient uAsset");
        assertEq(memecoin.balanceOf(CAROL), 200 ether, "recipient memecoin");
    }

    function testClaimResidual_BlocksReentrantClaim() external {
        ReentrantClaimMockERC20 hookedUAsset = new ReentrantClaimMockERC20("HOOK", "HOOK");
        seedMarketUAssetForTest(address(polend), VERSE_ID, address(hookedUAsset));
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 5 ether);
        seedResidualForTest(address(polend), VERSE_ID, 150 ether, 0, 15 ether);
        hookedUAsset.mint(address(polend), 150 ether);
        hookedUAsset.armReentry(
            address(polend),
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, BOB),
            bytes4(keccak256("ReentrancyGuardReentrantCall()"))
        );

        vm.prank(ALICE);
        polend.claimResidual(VERSE_ID, CAROL);

        assertTrue(hookedUAsset.sawExpectedRevert(), "reentrant residual claim blocked");
    }

    /// @dev Pure-credit participant: real==0, credit==50e18, total=100e18 (BOB holds 50e18 real).
    ///      Credit user must receive residual uAsset+memecoin pro-rata to their credit interest share
    ///      (spec docs/spec/polend/leveraged-lending.md §6.5; denominator totalLeveragedInterest already includes credit).
    function test_ClaimResidual_PureCreditUser_CanClaim() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 50 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 100 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 100 ether, "credit-only uAsset share");
        assertEq(memecoinAmount, 50 ether, "credit-only memecoin share");
        assertEq(uAsset.balanceOf(CAROL), 100 ether, "recipient uAsset");
        assertEq(memecoin.balanceOf(CAROL), 50 ether, "recipient memecoin");
    }

    /// @dev Mixed participant: real=30, credit=20, total=100 (BOB holds 50 real).
    ///      Claim must use real+credit aggregate as the numerator.
    function test_ClaimResidual_CreditUserGetsProRataResidual() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 30 ether);
        seedCreditPositionForTest(address(polend), VERSE_ID, ALICE, 20 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 100 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 100 ether, "aggregated uAsset share");
        assertEq(memecoinAmount, 50 ether, "aggregated memecoin share");
    }

    /// @dev Both ledgers zero must revert via InvalidClaim, even when totalLeveragedInterest > 0.
    function test_RevertWhen_ClaimResidual_BothZero() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 50 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 100 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, CAROL), IPOLend.InvalidClaim.selector
        );
    }

    /// @dev Backward-compat: pure-real user (credit==0) keeps identical behavior.
    function test_ClaimResidual_PureReal_BackCompat() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedLeveragedPositionForTest(address(polend), VERSE_ID, BOB, 30 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 40 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 50 ether, "pure-real uAsset unchanged");
        assertEq(memecoinAmount, 25 ether, "pure-real memecoin unchanged");
    }

    function testOwnerSetters_ValidateOwnerBoundsAndEmitEvents() external {
        vm.prank(ALICE);
        _expectLowLevelRevert(abi.encodeWithSignature("setProtocolTreasury(address)", CAROL), bytes4(0));

        _expectLowLevelRevert(
            abi.encodeWithSignature("setProtocolTreasury(address)", address(0)), IPOLend.ZeroInput.selector
        );

        vm.expectEmit(true, true, false, true);
        emit ProtocolTreasuryChanged(address(this), CAROL);
        (bool treasurySuccess,) = address(polend).call(abi.encodeWithSignature("setProtocolTreasury(address)", CAROL));
        assertTrue(treasurySuccess, "set treasury");
        assertEq(polend.treasury(), CAROL, "treasury");

        // setCreditFactory mirrors setProtocolTreasury: owner-only, rejects zero, emits CreditFactoryChanged.
        vm.prank(ALICE);
        _expectLowLevelRevert(abi.encodeWithSignature("setCreditFactory(address)", CAROL), bytes4(0));

        _expectLowLevelRevert(
            abi.encodeWithSignature("setCreditFactory(address)", address(0)), IPOLend.ZeroInput.selector
        );

        address oldFactory = polend.creditFactory();
        vm.expectEmit(true, true, false, true);
        emit IPOLend.CreditFactoryChanged(oldFactory, CAROL);
        (bool factorySuccess,) = address(polend).call(abi.encodeWithSignature("setCreditFactory(address)", CAROL));
        assertTrue(factorySuccess, "set creditFactory");
        assertEq(polend.creditFactory(), CAROL, "creditFactory");

        vm.prank(ALICE);
        _expectLowLevelRevert(abi.encodeWithSignature("setDefaultInterestRate(uint256)", 2e17), bytes4(0));

        _expectLowLevelRevert(abi.encodeWithSignature("setDefaultInterestRate(uint256)", 0), IPOLend.ZeroInput.selector);
        _expectLowLevelRevert(
            abi.encodeWithSignature("setDefaultInterestRate(uint256)", 1e18 + 1), IPOLend.InvalidConfig.selector
        );

        vm.expectEmit(false, false, false, true);
        emit DefaultInterestRateChanged(1e17, 2e17);
        (bool rateSuccess,) = address(polend).call(abi.encodeWithSignature("setDefaultInterestRate(uint256)", 2e17));
        assertTrue(rateSuccess, "set rate");
        assertEq(polend.defaultInterestRate(), 2e17, "default rate");

        assertEq(polend.getLendMarket(VERSE_ID).interestRate, 1e17, "existing market rate");

        uint256 newVerseId = 3;
        launcher.setVerseUAsset(newVerseId, address(uAsset));
        launcher.setGenesisFunds(newVerseId, 1_000 ether);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        polend.registerLendMarket(newVerseId);

        assertEq(polend.getLendMarket(newVerseId).interestRate, 2e17, "new market rate");
    }

    function testSetDefaultInterestRate_RevertsWhenCurrentDebtFactorDoesNotSupportRate() external {
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        polend.setDefaultInterestRate(1);

        assertEq(polend.defaultInterestRate(), 1e17, "rate unchanged");
    }

    function testSetLeveragedDebtFactor_OnlyOwnerAndValidatesBounds() external {
        bytes4 ownableUnauthorizedAccount = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

        vm.prank(ALICE);
        (bool ownerSuccess, bytes memory ownerRevertData) =
            address(polend).call(abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", 20e18));
        assertFalse(ownerSuccess, "owner-only");
        assertGe(ownerRevertData.length, 4, "owner revert selector length");
        assertEq(bytes4(ownerRevertData), ownableUnauthorizedAccount, "owner revert selector");

        _expectLowLevelRevert(abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", 0), IPOLend.ZeroInput.selector);
        _expectLowLevelRevert(
            abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", 1e18), IPOLend.InvalidConfig.selector
        );
        _expectLowLevelRevert(
            abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", MAX_LEVERAGED_DEBT_FACTOR + 1),
            IPOLend.InvalidConfig.selector
        );

        vm.expectEmit(false, false, false, true);
        emit LeveragedDebtFactorChanged(10e18, 20e18);
        (bool success,) = address(polend).call(abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", 20e18));
        assertTrue(success, "set factor");
        assertEq(polend.leveragedDebtFactor(), 20e18, "factor");
    }

    function testSetLeveragedDebtFactor_UpdatesGenesisCapacityWithoutChangingRegisteredRates() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));

        IPOLend.LendMarket memory existingMarket = polend.getLendMarket(VERSE_ID);
        IPOLend.LeveragedDebtInfo memory beforeInfo = polend.getLeveragedDebtInfo(VERSE_ID);
        assertEq(existingMarket.interestRate, 1e17, "existing rate before");
        assertEq(beforeInfo.debtCap, 10_000 ether, "debt cap before");

        (bool success,) = address(polend).call(abi.encodeWithSignature("setLeveragedDebtFactor(uint256)", 20e18));
        assertTrue(success, "set factor");

        existingMarket = polend.getLendMarket(VERSE_ID);
        IPOLend.LeveragedDebtInfo memory afterInfo = polend.getLeveragedDebtInfo(VERSE_ID);
        assertEq(existingMarket.interestRate, 1e17, "existing rate after");
        assertEq(afterInfo.debtCap, 20_000 ether, "debt cap after");

        uint256 newVerseId = 3;
        launcher.setVerseUAsset(newVerseId, address(uAsset));
        launcher.setGenesisFunds(newVerseId, 1_000 ether);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        vm.prank(address(launcher));
        polend.registerLendMarket(newVerseId);

        IPOLend.LendMarket memory newMarket = polend.getLendMarket(newVerseId);
        IPOLend.LeveragedDebtInfo memory newInfo = polend.getLeveragedDebtInfo(newVerseId);
        assertEq(newMarket.interestRate, 1e17, "new market rate");
        assertEq(newInfo.debtCap, 20_000 ether, "new debt cap");
    }

    function testGetLeveragedDebtInfo_DebtCapTracksLauncherCurrentCapBase() external {
        uint256 verseId = 190;
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 100 ether);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        polend.registerLendMarket(verseId);

        assertEq(polend.getLeveragedDebtInfo(verseId).debtCap, 10_000 ether, "initial min fund cap");

        launcher.setGenesisFunds(verseId, 2_000 ether);
        assertEq(polend.getLeveragedDebtInfo(verseId).debtCap, 20_000 ether, "normal funds cap");

        launcher.setFundMetaData(address(uAsset), 3_000 ether, 1);
        assertEq(polend.getLeveragedDebtInfo(verseId).debtCap, 30_000 ether, "updated min fund cap");
    }

    /// @notice Verifies that lowering leveragedDebtFactor blocks new leveragedGenesis that was
    /// within the old debt cap but exceeds the new one, while existing interest is unaffected.
    function testSetLeveragedDebtFactor_ReducingFactorBlocksNewLeverageForGenesisMarket() external {
        // interestRate = 1e18 (1:1), debtFactor = 2e18
        // minDebtFactor = 1e36 / 1e18 = 1e18,  debtFactor=2e18 >= 1e18 ✔
        // normalFunds = 1_000 ether, minTotalFund = 1_000 ether
        // debtCap = 2e18 * 1_000 ether / 1e18 = 2_000 ether
        MockSplitterForPOLend localSplitter = new MockSplitterForPOLend();
        localSplitter.setTokens(address(pt), address(yt));
        localSplitter.setSplitInfo(address(pol), address(memecoin), address(uAsset));
        POLend localPolend = _deployPOLend(1e18, 2e18, address(this), address(launcher), address(localSplitter));

        uint256 verseId = 200;
        launcher.setVerseUAsset(verseId, address(uAsset));
        launcher.setGenesisFunds(verseId, 1_000 ether);
        launcher.setFundMetaData(address(uAsset), 1_000 ether, 1);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(verseId);

        assertEq(localPolend.getLeveragedDebtInfo(verseId).debtCap, 2_000 ether, "initial cap");

        // Deposit 1_500 ether interest → debt = 1_500 ether, below initial cap of 2_000
        uAsset.mint(ALICE, 1_500 ether);
        vm.prank(ALICE);
        uAsset.approve(address(localPolend), 1_500 ether);
        vm.prank(ALICE);
        localPolend.leveragedGenesis(verseId, 1_500 ether);

        // Lower debtFactor from 2e18 to 1e18 → new debtCap = 1_000 ether
        // minDebtFactor = 1e36 / 1e18 = 1e18,  1e18 >= 1e18 ✔
        localPolend.setLeveragedDebtFactor(1e18);
        assertEq(localPolend.getLeveragedDebtInfo(verseId).debtCap, 1_000 ether, "lowered cap");

        // New leveragedGenesis of 1 ether interest → previewDebt = 1_501 > 1_000 → DebtCapExceeded
        uAsset.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.DebtCapExceeded.selector);
        localPolend.leveragedGenesis(verseId, 1 ether);

        // New market registered after lowering uses the new factor
        uint256 newVerseId = 201;
        launcher.setVerseUAsset(newVerseId, address(uAsset));
        launcher.setGenesisFunds(newVerseId, 1_000 ether);
        localPolend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        vm.prank(address(launcher));
        localPolend.registerLendMarket(newVerseId);
        assertEq(localPolend.getLeveragedDebtInfo(newVerseId).debtCap, 1_000 ether, "new market uses lowered factor");
    }

    function testSetMaxSettlementDustReserve_OnlyOwnerAndEmits() external {
        BurnableMockERC20 extraUAsset = new BurnableMockERC20("EXTRA", "EXTRA");

        vm.expectEmit(true, false, false, true);
        emit SettlementDustReserveConfigured(address(extraUAsset), 0, uint128(MAX_SETTLEMENT_DUST));
        polend.setMaxSettlementDustReserve(address(extraUAsset), uint128(MAX_SETTLEMENT_DUST));

        (, uint128 maxReserve) = polend.settlementDustStates(address(extraUAsset));
        assertEq(maxReserve, uint128(MAX_SETTLEMENT_DUST), "max reserve");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), ALICE));
        polend.setMaxSettlementDustReserve(address(extraUAsset), 1);
    }

    function testSetMaxSettlementDustReserve_RevertsForZeroUAsset() external {
        vm.expectRevert(IPOLend.ZeroInput.selector);
        polend.setMaxSettlementDustReserve(address(0), uint128(MAX_SETTLEMENT_DUST));
    }

    function testSetMaxSettlementDustReserve_RevertsForZeroDust() external {
        vm.expectRevert(IPOLend.ZeroInput.selector);
        polend.setMaxSettlementDustReserve(address(uAsset), 0);
    }

    function testPauseUnpause_CallableThroughIPOLendInterface() external {
        IPOLend polendInterface = IPOLend(address(polend));

        polendInterface.pause();
        assertTrue(polend.paused(), "paused");

        polendInterface.unpause();
        assertFalse(polend.paused(), "unpaused");
    }

    /// @notice Test leveragedGenesis reverts when paused.
    function testLeveragedGenesis_RevertsWhenPaused() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        polend.pause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        polend.leveragedGenesis(VERSE_ID, 10 ether);
    }

    function testDebtByUAssetTracksFinalizePreRedeemBackingAndSettlement() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);
        assertEq(_getTotalDebtByUAsset(address(uAsset)), 100 ether, "finalized debt");
        assertEq(_getTotalDebtByUAsset(address(otherUAsset)), 0, "other asset debt");

        setLockedStateForTest(address(polend), VERSE_ID, 0);
        vm.prank(address(launcher));
        polend.preRedeemPTFee(VERSE_ID, 25 ether, BOB);
        assertEq(_getTotalDebtByUAsset(address(uAsset)), 125 ether, "preRedeem debt");

        uAsset.mint(address(splitter), 25 ether);
        vm.prank(address(splitter));
        polend.burnPreRedeemedBacking(VERSE_ID, 25 ether);
        assertEq(_getTotalDebtByUAsset(address(uAsset)), 100 ether, "backing repaid");

        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether);
        uAsset.mint(address(polend), 100 ether);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);
        assertEq(_getTotalDebtByUAsset(address(uAsset)), 0, "settlement repaid");

        _expectLowLevelRevert(
            abi.encodeWithSignature("getTotalDebtByUAsset(address)", address(0)), IPOLend.ZeroInput.selector
        );
    }

    function testGetLeveragedDebtInfo_CoversGenesisCapAndClosedStates() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        (uint256 totalInterest, uint256 totalDebt, uint256 rate, uint256 debtCap, uint256 remaining) =
            _getLeveragedDebtInfo(VERSE_ID);
        assertEq(totalInterest, 0, "none interest");
        assertEq(totalDebt, 0, "none debt");
        assertEq(rate, 1e17, "rate");
        assertEq(debtCap, 10_000 ether, "none cap");
        assertEq(remaining, 1_000 ether, "none remaining");

        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        (totalInterest, totalDebt, rate, debtCap, remaining) = _getLeveragedDebtInfo(VERSE_ID);
        assertEq(totalInterest, 10 ether, "genesis interest");
        assertEq(totalDebt, 100 ether, "genesis debt");
        assertEq(rate, 1e17, "genesis rate");
        assertEq(debtCap, 10_000 ether, "genesis cap");
        assertEq(remaining, 990 ether, "genesis remaining");

        setLockedStateForTest(address(polend), VERSE_ID, 0);
        (,,, debtCap, remaining) = _getLeveragedDebtInfo(VERSE_ID);
        assertEq(debtCap, 0, "locked cap");
        assertEq(remaining, 0, "locked remaining");

        setRefundStateForTest(address(polend), VERSE_ID);
        (,,, debtCap, remaining) = _getLeveragedDebtInfo(VERSE_ID);
        assertEq(debtCap, 0, "refund cap");
        assertEq(remaining, 0, "refund remaining");

        _expectLowLevelRevert(
            abi.encodeWithSignature("getLeveragedDebtInfo(uint256)", 999), IPOLend.InvalidState.selector
        );
    }

    function testGetUserLeveragedDebt_RevertsForUnregisteredOrZeroUser() external {
        vm.expectRevert(IPOLend.InvalidState.selector);
        polend.getUserLeveragedDebt(999, ALICE);

        vm.expectRevert(IPOLend.ZeroInput.selector);
        polend.getUserLeveragedDebt(VERSE_ID, address(0));
    }

    function testFundSettlementDustReserve_ManualFundingCreditsReserveAndEmitsZeroExcess() external {
        polend.pause();

        uAsset.mint(ALICE, MAX_SETTLEMENT_DUST);
        vm.prank(ALICE);
        uAsset.approve(address(polend), MAX_SETTLEMENT_DUST);

        vm.expectEmit(true, true, false, true);
        emit SettlementDustReserveFunded(address(uAsset), ALICE, MAX_SETTLEMENT_DUST, MAX_SETTLEMENT_DUST, 0);
        vm.prank(ALICE);
        polend.fundSettlementDustReserve(address(uAsset), MAX_SETTLEMENT_DUST);

        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserve, uint128(MAX_SETTLEMENT_DUST), "reserve");
        assertEq(uAsset.balanceOf(address(polend)), MAX_SETTLEMENT_DUST, "balance");
        assertEq(polend.leveragedInterestPaid(VERSE_ID, ALICE), 0, "no interest claim");
        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        assertEq(residualUAsset, 0, "no residual uasset claim");
        assertEq(residualMemecoin, 0, "no residual memecoin claim");
    }

    function testFundSettlementDustReserve_ManualFundingOverCapacityRevertsBeforeTransfer() external {
        uint256 amount = MAX_SETTLEMENT_DUST + 1;
        uAsset.mint(ALICE, amount);
        vm.prank(ALICE);
        uAsset.approve(address(polend), amount);

        vm.expectRevert(
            abi.encodeWithSelector(IPOLend.SettlementDustReserveExceeded.selector, amount, MAX_SETTLEMENT_DUST)
        );
        vm.prank(ALICE);
        polend.fundSettlementDustReserve(address(uAsset), amount);

        assertEq(uAsset.balanceOf(ALICE), amount, "no transfer");
        assertEq(uAsset.balanceOf(address(polend)), 0, "polend unchanged");
    }

    function testFundSettlementDustReserve_LauncherExcessGoesToTreasury() external {
        uint256 amount = MAX_SETTLEMENT_DUST + 7;
        uAsset.mint(address(launcher), amount);
        vm.prank(address(launcher));
        uAsset.approve(address(polend), amount);
        uint256 treasuryBefore = uAsset.balanceOf(address(this));

        vm.expectEmit(true, true, false, true);
        emit SettlementDustReserveFunded(address(uAsset), address(launcher), amount, MAX_SETTLEMENT_DUST, 7);
        vm.prank(address(launcher));
        polend.fundSettlementDustReserve(address(uAsset), amount);

        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserve, uint128(MAX_SETTLEMENT_DUST), "reserve");
        assertEq(uAsset.balanceOf(address(this)), treasuryBefore + 7, "treasury excess");
    }

    function testFundSettlementDustReserve_RevertsForUnconfiguredOrZeroAmount() external {
        vm.expectRevert(IPOLend.ZeroInput.selector);
        polend.fundSettlementDustReserve(address(uAsset), 0);

        BurnableMockERC20 extraUAsset = new BurnableMockERC20("EXTRA", "EXTRA");
        extraUAsset.mint(ALICE, 1);
        vm.prank(ALICE);
        extraUAsset.approve(address(polend), 1);
        vm.prank(ALICE);
        vm.expectRevert(IPOLend.InvalidConfig.selector);
        polend.fundSettlementDustReserve(address(extraUAsset), 1);
    }

    function testExecuteGlobalSettlement_RepaysDebtAndLeavesOnlyRecoveredResidual() external {
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 150 ether);

        uAsset.mint(address(polend), 150 ether);

        vm.expectEmit(true, true, false, true);
        emit GlobalSettlementExecuted(VERSE_ID, address(uAsset), 100 ether, 150 ether, 0, 0, 50 ether, 0);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        assertEq(uAsset.repaidAmount(), 100 ether, "debt repaid");
        assertEq(uAsset.lastRepayAccount(), address(polend), "repay account");
        assertEq(uAsset.burnedAmount(), 0, "burn not used");
        assertEq(polend.globalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
        assertEq(residualUAsset, 50 ether, "residual uasset");
        assertEq(residualMemecoin, 0, "residual memecoin");
        assertEq(uAsset.balanceOf(address(polend)), 50 ether, "only recovered residual kept");
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Settled), "state settled");
    }

    function testExecuteGlobalSettlement_RevertsWithoutDebtStateChangeWhenRepayFails() external {
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 150 ether);
        uAsset.mint(address(polend), 150 ether);
        uAsset.setRevertRepay(true);

        vm.prank(address(launcher));
        vm.expectRevert(bytes("repay failed"));
        polend.executeGlobalSettlement(VERSE_ID);

        assertEq(polend.globalDebtByUAsset(address(uAsset)), 100 ether, "global debt unchanged");
        assertEq(uAsset.repaidAmount(), 0, "repay reverted");
        assertEq(uAsset.burnedAmount(), 0, "burn not used");
        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Locked), "state unchanged");
    }

    function testExecuteGlobalSettlement_ConsumesReserveForBoundedDustDeficit() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether - 1);
        uAsset.mint(address(polend), 100 ether - 1 + MAX_SETTLEMENT_DUST);
        seedSettlementDustStateForTest(
            address(polend), address(uAsset), uint128(MAX_SETTLEMENT_DUST), uint128(MAX_SETTLEMENT_DUST)
        );
        uint256 treasuryBefore = uAsset.balanceOf(address(this));

        uint256 consumedSettlementDustReserve = 1;
        uint256 settlementDustReserveBeforeSettlement = MAX_SETTLEMENT_DUST;
        assertLe(consumedSettlementDustReserve, MAX_SETTLEMENT_DUST, "dust cap");
        assertLe(consumedSettlementDustReserve, settlementDustReserveBeforeSettlement, "reserve cap");

        vm.expectEmit(true, true, false, true);
        emit SettlementDustReserveConsumed(VERSE_ID, address(uAsset), 1, MAX_SETTLEMENT_DUST - 1);
        vm.expectEmit(true, true, false, true);
        emit GlobalSettlementExecuted(
            VERSE_ID, address(uAsset), 100 ether, 100 ether - 1, 1, MAX_SETTLEMENT_DUST - 1, 0, 0
        );
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(polend.globalDebtByUAsset(address(uAsset)), 0, "global debt");
        assertEq(reserve, uint128(MAX_SETTLEMENT_DUST - 1), "remaining reserve");
        assertEq(uAsset.repaidAmount(), 100 ether, "full debt repaid");
        assertEq(residualUAsset, 0, "no uasset residual");
        assertEq(residualMemecoin, 0, "memecoin residual");
        assertEq(uAsset.balanceOf(address(this)), treasuryBefore, "unused reserve not swept");
    }

    function testExecuteGlobalSettlement_ConsumesPubliclyFundedDustReserve() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether - 2);
        uAsset.mint(address(polend), 100 ether - 2);

        uAsset.mint(ALICE, 2);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 2);
        vm.prank(ALICE);
        polend.fundSettlementDustReserve(address(uAsset), 2);

        vm.expectEmit(true, true, false, true);
        emit GlobalSettlementExecuted(VERSE_ID, address(uAsset), 100 ether, 100 ether - 2, 2, 0, 0, 0);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        (uint256 residualUAsset, uint256 residualMemecoin) = polend.residualStates(VERSE_ID);
        (uint128 reserve,) = polend.settlementDustStates(address(uAsset));
        assertEq(polend.globalDebtByUAsset(address(uAsset)), 0, "global debt");
        assertEq(reserve, 0, "reserve consumed");
        assertEq(uAsset.repaidAmount(), 100 ether, "full debt repaid");
        assertEq(residualUAsset, 0, "no uasset residual");
        assertEq(residualMemecoin, 0, "memecoin residual");
        assertEq(uAsset.balanceOf(address(polend)), 0, "no polend uasset residual");
    }

    function testExecuteGlobalSettlement_RevertsWhenDeficitExceedsGlobalReserve() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether - MAX_SETTLEMENT_DUST - 1);
        uAsset.mint(address(polend), 100 ether);
        seedSettlementDustStateForTest(
            address(polend), address(uAsset), uint128(MAX_SETTLEMENT_DUST), uint128(MAX_SETTLEMENT_DUST)
        );

        vm.prank(address(launcher));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPOLend.SettlementDustInsufficient.selector, MAX_SETTLEMENT_DUST + 1, MAX_SETTLEMENT_DUST
            )
        );
        polend.executeGlobalSettlement(VERSE_ID);
    }

    function testExecuteGlobalSettlement_RevertsWhenReserveIsUnderfunded() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether - 2);
        uAsset.mint(address(polend), 100 ether);
        seedSettlementDustStateForTest(address(polend), address(uAsset), 1, uint128(MAX_SETTLEMENT_DUST));

        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(IPOLend.SettlementDustInsufficient.selector, 2, 1));
        polend.executeGlobalSettlement(VERSE_ID);
    }

    function testExecuteGlobalSettlement_RevertsWhenReserveUnfunded() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        seedGlobalDebtForTest(address(polend), address(uAsset), 100 ether);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 100 ether - 1);
        uAsset.mint(address(polend), 100 ether);
        seedSettlementDustStateForTest(address(polend), address(uAsset), 0, uint128(MAX_SETTLEMENT_DUST));

        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(IPOLend.SettlementDustInsufficient.selector, 1, 0));
        polend.executeGlobalSettlement(VERSE_ID);
    }

    function testPreRedeemPTFee_MintsToTargetAndIncreasesGlobalDebt() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        splitter.setPreRedeemBacking(10 ether);

        vm.prank(address(launcher));
        (bool success,) = address(polend)
            .call(abi.encodeWithSignature("preRedeemPTFee(uint256,uint256,address)", VERSE_ID, 25 ether, BOB));

        assertTrue(success, "preRedeemPTFee");
        assertEq(splitter.preRedeemCallCount(), 1, "splitter preRedeem called");
        assertEq(splitter.lastPreRedeemVerseId(), VERSE_ID, "verse id");
        assertEq(splitter.lastPreRedeemPTAmount(), 25 ether, "pt amount");
        assertEq(uAsset.balanceOf(BOB), 10 ether, "minted uAsset");
        assertEq(polend.globalDebtByUAsset(address(uAsset)), 10 ether, "global debt increased");
    }

    function testPreRedeemPTFee_EmitsPreRedeemPTFee() external {
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        splitter.setPreRedeemBacking(10 ether);

        vm.expectEmit(true, true, false, true);
        emit PreRedeemPTFee(VERSE_ID, address(uAsset), 25 ether, 10 ether, BOB);
        vm.prank(address(launcher));
        polend.preRedeemPTFee(VERSE_ID, 25 ether, BOB);
    }

    function testPreRedeemPTFee_MintHookObservesDebtAlreadyIncreased() external {
        HookedBurnableMockERC20 hookedUAsset = new HookedBurnableMockERC20("HOOK", "HOOK");
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        seedMarketUAssetForTest(address(polend), VERSE_ID, address(hookedUAsset));
        splitter.setPreRedeemBacking(10 ether);
        hookedUAsset.expectMintDebt(address(polend), 10 ether);

        vm.prank(address(launcher));
        polend.preRedeemPTFee(VERSE_ID, 25 ether, BOB);

        assertEq(hookedUAsset.balanceOf(BOB), 10 ether, "minted uAsset");
        assertEq(polend.getTotalDebtByUAsset(address(hookedUAsset)), 10 ether, "global debt");
    }

    function testBurnPreRedeemedBacking_RepaysSplitterBackingAndReducesGlobalDebt() external {
        seedGlobalDebtForTest(address(polend), address(uAsset), 40 ether);
        uAsset.mint(address(splitter), 40 ether);

        vm.prank(address(splitter));
        (bool success,) =
            address(polend).call(abi.encodeWithSignature("burnPreRedeemedBacking(uint256,uint256)", VERSE_ID, 40 ether));

        assertTrue(success, "burnPreRedeemedBacking");
        assertEq(uAsset.repaidAmount(), 40 ether, "backing repaid");
        assertEq(uAsset.lastRepayAccount(), address(splitter), "repay account");
        assertEq(polend.globalDebtByUAsset(address(uAsset)), 0, "global debt reduced");
    }

    function testBurnPreRedeemedBacking_RepayHookObservesDebtAlreadyDecreased() external {
        HookedBurnableMockERC20 hookedUAsset = new HookedBurnableMockERC20("HOOK", "HOOK");
        seedMarketUAssetForTest(address(polend), VERSE_ID, address(hookedUAsset));
        seedGlobalDebtForTest(address(polend), address(hookedUAsset), 40 ether);
        hookedUAsset.mint(address(splitter), 40 ether);
        hookedUAsset.expectRepayDebt(address(polend), 0);

        vm.prank(address(splitter));
        polend.burnPreRedeemedBacking(VERSE_ID, 40 ether);

        assertEq(hookedUAsset.repaidAmount(), 40 ether, "backing repaid");
        assertEq(polend.getTotalDebtByUAsset(address(hookedUAsset)), 0, "global debt");
    }

    function testExecuteGlobalSettlement_DoesNotCountInterestTowardDebtCoverage() external {
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 0);
        launcher.setSettlementResult(VERSE_ID, 0, 0, 90 ether);

        uAsset.mint(address(polend), 100 ether);

        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(IPOLend.SettlementDustInsufficient.selector, 10 ether, 0));
        polend.executeGlobalSettlement(VERSE_ID);
    }

    function testLeveragedGenesis_DifferentVersesUseTheirOwnUAsset() external {
        polend.setMaxSettlementDustReserve(address(otherUAsset), uint128(MAX_SETTLEMENT_DUST));
        otherUAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        otherUAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        polend.leveragedGenesis(OTHER_VERSE_ID, 10 ether);

        assertEq(otherUAsset.balanceOf(address(polend)), 10 ether, "other verse interest escrowed in its own asset");
        assertEq(uAsset.balanceOf(address(polend)), 0, "default uAsset untouched");
    }

    function testMarkRefundable_OnlyMovesGenesisMarketToRefund() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        vm.prank(address(launcher));
        polend.markRefundable(VERSE_ID);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Refund), "refund state");
        assertEq(uAsset.balanceOf(address(polend)), 10 ether, "interest remains refundable");
    }

    function testRecordLeveragedYT_RecordsOnceAfterFinalize() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);

        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);

        vm.prank(address(launcher));
        polend.recordLeveragedYT(VERSE_ID, address(yt), 100 ether);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(market.yt, address(yt), "yt");
        assertEq(market.totalLeveragedYT, 100 ether, "total yt");

        vm.prank(address(launcher));
        vm.expectRevert(IPOLend.InvalidState.selector);
        polend.recordLeveragedYT(VERSE_ID, address(yt), 100 ether);
    }

    function testClaimLeveragedYT_SucceedsInSettledStateAfterGlobalSettlement() external {
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));
        uAsset.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        uAsset.approve(address(polend), 10 ether);
        vm.prank(ALICE);
        polend.leveragedGenesis(VERSE_ID, 10 ether);

        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(VERSE_ID);
        vm.prank(address(launcher));
        polend.recordLeveragedYT(VERSE_ID, address(yt), 100 ether);

        launcher.setSettlementResult(VERSE_ID, 0, 0, 150 ether);
        uAsset.mint(address(polend), 150 ether);
        vm.prank(address(launcher));
        polend.executeGlobalSettlement(VERSE_ID);

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Settled), "settled");

        yt.mint(address(polend), 100 ether);
        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 100 ether, "settled yt claim");
        assertEq(yt.balanceOf(CAROL), 100 ether, "recipient");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
    }

    function testClaimResidual_SucceedsWithZeroPayoutAndMarksClaim() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 1);
        seedResidualForTest(address(polend), VERSE_ID, 1, 0, 2);
        uAsset.mint(address(polend), 1);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 0, "zero uAsset payout");
        assertEq(memecoinAmount, 0, "zero memecoin payout");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
    }

    function testClaimLeveragedYTAndClaimResidual_AreIndependentForSameUser() external {
        seedLeveragedPositionForTest(address(polend), VERSE_ID, ALICE, 10 ether);
        seedMarketForTest(address(polend), VERSE_ID, address(yt), 10 ether);
        setLockedStateForTest(address(polend), VERSE_ID, 100 ether);
        seedResidualForTest(address(polend), VERSE_ID, 200 ether, 100 ether, 10 ether);
        uAsset.mint(address(polend), 200 ether);
        memecoin.mint(address(polend), 100 ether);
        yt.mint(address(polend), 100 ether);

        vm.prank(ALICE);
        assertEq(_claimLeveragedYT(VERSE_ID, CAROL), 100 ether, "yt");
        assertEq(yt.balanceOf(CAROL), 100 ether, "yt recipient");

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 memecoinAmount) = _claimResidual(VERSE_ID, CAROL);
        assertEq(uAssetAmount, 200 ether, "residual uAsset");
        assertEq(memecoinAmount, 100 ether, "residual memecoin");
        assertEq(uAsset.balanceOf(CAROL), 200 ether, "uAsset recipient");
        assertEq(memecoin.balanceOf(CAROL), 100 ether, "memecoin recipient");

        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimLeveragedYT(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
        vm.prank(ALICE);
        _expectLowLevelRevert(
            abi.encodeWithSignature("claimResidual(uint256,address)", VERSE_ID, BOB), IPOLend.InvalidClaim.selector
        );
    }

    function _claimLeveragedYT(uint256 verseId, address to) internal returns (uint256 amount) {
        (bool success, bytes memory data) =
            address(polend).call(abi.encodeWithSignature("claimLeveragedYT(uint256,address)", verseId, to));
        assertTrue(success, "claimLeveragedYT call");
        amount = abi.decode(data, (uint256));
    }

    function _claimRefund(uint256 verseId, address to) internal returns (uint256 amount) {
        (bool success, bytes memory data) =
            address(polend).call(abi.encodeWithSignature("claimRefund(uint256,address)", verseId, to));
        assertTrue(success, "claimRefund call");
        amount = abi.decode(data, (uint256));
    }

    function _claimResidual(uint256 verseId, address to)
        internal
        returns (uint256 uAssetAmount, uint256 memecoinAmount)
    {
        (bool success, bytes memory data) = address(polend)
            .call(abi.encodeWithSignature("claimResidual(uint256,address)", verseId, to));
        assertTrue(success, "claimResidual call");
        (uAssetAmount, memecoinAmount) = abi.decode(data, (uint256, uint256));
    }

    function _getTotalDebtByUAsset(address uAsset_) internal returns (uint256 amount) {
        (bool success, bytes memory data) =
            address(polend).call(abi.encodeWithSignature("getTotalDebtByUAsset(address)", uAsset_));
        assertTrue(success, "getTotalDebtByUAsset call");
        amount = abi.decode(data, (uint256));
    }

    function _getLeveragedDebtInfo(uint256 verseId)
        internal
        returns (
            uint256 totalLeveragedInterest,
            uint256 totalLeveragedDebt,
            uint256 interestRate,
            uint256 debtCap,
            uint256 remainingAdditionalInterest
        )
    {
        (bool success, bytes memory data) =
            address(polend).call(abi.encodeWithSignature("getLeveragedDebtInfo(uint256)", verseId));
        assertTrue(success, "getLeveragedDebtInfo call");
        (totalLeveragedInterest, totalLeveragedDebt, interestRate, debtCap, remainingAdditionalInterest) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
    }

    function _expectLowLevelRevert(bytes memory callData, bytes4 selector) internal {
        (bool success, bytes memory revertData) = address(polend).call(callData);
        assertFalse(success, "call reverted");
        if (selector != bytes4(0)) {
            assertGe(revertData.length, 4, "revert selector length");
            assertEq(bytes4(revertData), selector, "revert selector");
        }
    }
}
