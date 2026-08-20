// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLSplitterUpgradeable} from "../../src/polend/POLSplitterUpgradeable.sol";
import {IPOLSplitter} from "../../src/polend/interfaces/IPOLSplitter.sol";
import {PrincipalToken} from "../../src/polend/tokens/PrincipalToken.sol";
import {YieldToken} from "../../src/polend/tokens/YieldToken.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {OutrunOwnable} from "../../src/common/access/OutrunOwnable.sol";

import {MockPOL} from "../mocks/polend/MockPOL.sol";
import {
    MarkerSplitterTokenTemplate,
    ReentrantMockERC20,
    POLSplitterReentryProbe
} from "../mocks/polend/POLSplitterMocks.sol";
import {POLSplitterStorageHelper} from "../mocks/polend/POLSplitterStorageHelper.sol";

contract MockLauncher {
    // Boundary note:
    // This mock only drives launcher stage and unwrap selector wiring for POLSplitterUpgradeable unit tests.
    // It does not prove real launcher/router asset-flow semantics.
    struct RedemptionSeed {
        uint256 uAssetAmount;
        uint256 memecoinAmount;
    }

    mapping(uint256 verseId => IMemeverseLauncher.Stage) internal stages;
    mapping(uint256 verseId => address) internal polTokens;
    mapping(uint256 verseId => RedemptionSeed) internal redemptionSeeds;
    mapping(uint256 verseId => IMemeverseLauncher.Memeverse) internal verses;
    address internal polendAddress;

    MockERC20 internal immutable uAsset;
    MockERC20 internal immutable memecoin;

    constructor(MockERC20 uAsset_, MockERC20 memecoin_) {
        uAsset = uAsset_;
        memecoin = memecoin_;
    }

    function setStage(uint256 verseId, IMemeverseLauncher.Stage stage) external {
        stages[verseId] = stage;
    }

    function registerPol(uint256 verseId, address pol) external {
        polTokens[verseId] = pol;
    }

    function setVerseUAsset(uint256 verseId, address uAsset_) external {
        verses[verseId].uAsset = uAsset_;
    }

    function seedRedemption(uint256 verseId, uint256 uAssetAmount, uint256 memecoinAmount) external {
        redemptionSeeds[verseId] = RedemptionSeed({uAssetAmount: uAssetAmount, memecoinAmount: memecoinAmount});
    }

    function setPolend(address polend_) external {
        polendAddress = polend_;
    }

    function getStageByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Stage) {
        return stages[verseId];
    }

    function getMemeverseByVerseId(uint256 verseId) external view returns (IMemeverseLauncher.Memeverse memory verse) {
        return verses[verseId];
    }

    function getUAssetByVerseId(uint256 verseId) external view returns (address) {
        return verses[verseId].uAsset;
    }

    function polend() external view returns (address) {
        return polendAddress;
    }

    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool, uint256, uint256, uint256)
        external
        returns (uint256 amountInLP)
    {
        require(MockPOL(polTokens[verseId]).transferFrom(msg.sender, address(this), amountInPOL), "transfer failed");

        RedemptionSeed memory seed = redemptionSeeds[verseId];
        if (seed.uAssetAmount != 0) uAsset.mint(msg.sender, seed.uAssetAmount);
        if (seed.memecoinAmount != 0) memecoin.mint(msg.sender, seed.memecoinAmount);
        return amountInPOL;
    }
}

contract MockPOLendForSplitter {
    uint256 public burnPreRedeemedBackingCallCount;
    uint256 public lastBurnPreRedeemedBackingVerseId;
    uint256 public lastBurnPreRedeemedBackingAmount;

    function burnPreRedeemedBacking(uint256 verseId, uint256 amount) external {
        burnPreRedeemedBackingCallCount++;
        lastBurnPreRedeemedBackingVerseId = verseId;
        lastBurnPreRedeemedBackingAmount = amount;
    }
}

contract POLSplitterTest is Test, POLSplitterStorageHelper {
    uint256 internal constant VERSE_ID = 1;
    uint256 internal constant OTHER_VERSE_ID = 2;
    bytes4 internal constant ZERO_INPUT_SELECTOR = bytes4(keccak256("ZeroInput()"));
    bytes4 internal constant INVALID_CLAIM_SELECTOR = bytes4(keccak256("InvalidClaim()"));
    bytes4 internal constant INVALID_INITIALIZATION_SELECTOR = bytes4(keccak256("InvalidInitialization()"));
    bytes4 internal constant PANIC_SELECTOR = bytes4(keccak256("Panic(uint256)"));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    event RedeemPT(uint256 indexed verseId, address indexed from, address indexed to, uint256 ptAmount);
    event RedeemYT(
        uint256 indexed verseId,
        address indexed from,
        address indexed to,
        uint256 ytAmount,
        uint256 uAssetAmount,
        uint256 memecoinAmount
    );
    event VerseInitialized(uint256 indexed verseId, address indexed pt, address indexed yt);
    event Split(uint256 indexed verseId, address indexed user, uint256 polAmount, uint256 ptAmount, uint256 ytAmount);
    event Merge(uint256 indexed verseId, address indexed user, uint256 amount, uint256 polAmount);
    event BackingRatioRecorded(uint256 indexed verseId, uint256 numerator, uint256 denominator);
    event VerseSettled(uint256 indexed verseId, uint256 settlementUAsset, uint256 settlementMemecoin);
    event TokenImplementationsUpdated(
        address oldPrincipalToken, address oldYieldToken, address newPrincipalToken, address newYieldToken
    );

    MockERC20 internal memecoin;
    MockERC20 internal uAsset;
    MockERC20 internal otherUAsset;
    MockPOL internal pol;
    MockPOL internal otherPol;
    MockLauncher internal launcher;
    MockPOLendForSplitter internal polend;
    POLSplitterUpgradeable internal splitter;
    PrincipalToken internal pt;
    YieldToken internal yt;

    function setUp() external {
        memecoin = new MockERC20("MEME", "MEME", 18);
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        otherUAsset = new MockERC20("OTHER", "OTHER", 18);
        pol = new MockPOL(address(memecoin));
        otherPol = new MockPOL(address(memecoin));
        launcher = new MockLauncher(uAsset, memecoin);
        polend = new MockPOLendForSplitter();
        launcher.setPolend(address(polend));
        splitter = _deploySplitter(address(launcher));

        launcher.setVerseUAsset(VERSE_ID, address(uAsset));
        launcher.setVerseUAsset(OTHER_VERSE_ID, address(otherUAsset));
        vm.prank(address(launcher));
        splitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
        vm.prank(address(launcher));
        splitter.initializeVerse(
            OTHER_VERSE_ID, address(otherPol), address(memecoin), address(otherUAsset), "Other", "OTH"
        );
        launcher.registerPol(VERSE_ID, address(pol));
        launcher.registerPol(OTHER_VERSE_ID, address(otherPol));
        (address ptAddress, address ytAddress,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        pt = PrincipalToken(ptAddress);
        yt = YieldToken(ytAddress);
    }

    function _deploySplitter(address launcher_) internal returns (POLSplitterUpgradeable deployed) {
        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();
        bytes memory data = abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), launcher_));
        return POLSplitterUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function testDeployTokens_RevertForNonLauncherOrRepeatDeployment() external {
        POLSplitterUpgradeable otherSplitter = _deploySplitter(address(launcher));

        vm.prank(ALICE);
        vm.expectRevert(IPOLSplitter.PermissionDenied.selector);
        otherSplitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");

        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.AlreadyDeployed.selector);
        splitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
    }

    function testGetPOLAndMemecoin_ReturnsStoredAddresses() external view {
        (address storedPol, address storedMemecoin) = splitter.getPOLAndMemecoin(VERSE_ID);

        assertEq(storedPol, address(pol), "pol");
        assertEq(storedMemecoin, address(memecoin), "memecoin");
    }

    function testNarrowGetters_ReturnStoredAddresses() external view {
        address storedPT = splitter.getPT(VERSE_ID);
        address storedYT = splitter.getYT(VERSE_ID);
        address storedMemecoin = splitter.getMemecoin(VERSE_ID);
        (address pairPT, address pairYT) = splitter.getPTAndYT(VERSE_ID);

        assertEq(storedPT, address(pt), "pt");
        assertEq(storedYT, address(yt), "yt");
        assertEq(storedMemecoin, address(memecoin), "memecoin");
        assertEq(pairPT, address(pt), "pair pt");
        assertEq(pairYT, address(yt), "pair yt");
    }

    function testGetPTSettlementState_ReturnsStoredValues() external {
        (address storedPT, bool settled) = splitter.getPTSettlementState(VERSE_ID);
        assertEq(storedPT, address(pt), "pt before settle");
        assertFalse(settled, "settled before settle");

        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        (storedPT, settled) = splitter.getPTSettlementState(VERSE_ID);
        assertEq(storedPT, address(pt), "pt after settle");
        assertTrue(settled, "settled after settle");
    }

    function testRecordPTBackingRatio_StoresRatioAndPreviewConvertsPT() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);

        (uint256 ptBackingNumerator, uint256 ptBackingDenominator) = splitter.ptBackingRatios(VERSE_ID);
        assertEq(ptBackingNumerator, 7 ether, "numerator");
        assertEq(ptBackingDenominator, 14 ether, "denominator");
        assertEq(splitter.previewPTToUAsset(VERSE_ID, 14 ether), 7 ether, "full base");
        assertEq(splitter.previewPTToUAsset(VERSE_ID, 1 ether), 0.5 ether, "pro rata");
    }

    function testRecordPTBackingRatio_RevertsWhenCalledTwice() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.startPrank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        vm.stopPrank();
    }

    function testRecordPTBackingRatio_RevertsForNonLauncher() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.prank(ALICE);
        vm.expectRevert(IPOLSplitter.PermissionDenied.selector);
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
    }

    function testRecordPTBackingRatio_RevertsAfterSplitStarted() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 1 ether);
        pol.approve(address(splitter), 1 ether);
        splitter.split(VERSE_ID, 1 ether);

        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
    }

    function testPreviewPTToUAsset_RevertsBeforeRatioConfigured() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.previewPTToUAsset(VERSE_ID, 1 ether);
    }

    function testInitializeVerse_RejectsConfiguredPOLend() external {
        POLSplitterUpgradeable otherSplitter = _deploySplitter(address(launcher));
        launcher.setPolend(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(IPOLSplitter.PermissionDenied.selector);
        otherSplitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
    }

    function testImplementationInitializerIsDisabled() external {
        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();

        vm.expectRevert(INVALID_INITIALIZATION_SELECTOR);
        implementation.initialize(address(this), address(launcher));
    }

    function testProxyInitialization_RevertsOnZeroLauncher() external {
        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();
        bytes memory data = abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), address(0)));

        vm.expectRevert(ZERO_INPUT_SELECTOR);
        new ERC1967Proxy(address(implementation), data);
    }

    function testSplit_RevertAfterUnlocked() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);

        vm.expectRevert(IPOLSplitter.AlreadyUnlocked.selector);
        splitter.split(VERSE_ID, 100 ether);
    }

    function testSplit_RevertsBeforeRatioConfigured() external {
        pol.mint(address(this), 100 ether);
        pol.approve(address(splitter), 100 ether);

        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.split(VERSE_ID, 100 ether);
    }

    function testRedeemPT_RevertBeforeSettle() external {
        vm.expectRevert(IPOLSplitter.NotSettled.selector);
        splitter.redeemPT(VERSE_ID, 1 ether, address(this));
    }

    function testRedeemPT_RevertsOnZeroRecipientBeforeBurn() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 100 ether, 0);
        uAsset.mint(address(splitter), 100 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 100 ether);

        vm.prank(ALICE);
        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.redeemPT(VERSE_ID, 40 ether, address(0));

        assertEq(pt.balanceOf(ALICE), 100 ether, "pt not burned");
        assertEq(uAsset.balanceOf(address(splitter)), 100 ether, "uAsset not transferred");
    }

    function testRedeemPT_RevertsWithInvalidClaimWhenSettlementUAssetIsInsufficient() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 40 ether, 0);
        uAsset.mint(address(splitter), 40 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 60 ether);

        vm.prank(ALICE);
        vm.expectRevert(INVALID_CLAIM_SELECTOR);
        splitter.redeemPT(VERSE_ID, 60 ether, ALICE);

        (,,,,,, uint256 settlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        assertEq(pt.balanceOf(ALICE), 60 ether, "pt not burned");
        assertEq(uAsset.balanceOf(address(splitter)), 40 ether, "uAsset unchanged");
        assertEq(settlementUAsset, 40 ether, "settlement uAsset unchanged");
    }

    function testSplitMergeRedeemPTAndRedeemYT_RevertOnZeroAmount() external {
        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.split(VERSE_ID, 0);

        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.merge(VERSE_ID, 0);

        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 100 ether, 100 ether);

        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.redeemPT(VERSE_ID, 0, ALICE);

        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.redeemYT(VERSE_ID, 0, ALICE);
    }

    function testPreviewRedeemYTUAsset_UsesSettlementUAssetMinusReservedPT() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(this), 200 ether);
        mintYTForTest(address(splitter), VERSE_ID, address(this), 300 ether);

        uint256 redeemedUAsset = splitter.previewRedeemYTUAsset(VERSE_ID, 150 ether);
        assertEq(redeemedUAsset, 200 ether, "uAsset pool excludes reserved PT");
    }

    function testPreviewRedeemYTUAsset_ReservesConvertedPTBacking() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(this), 200 ether);
        mintYTForTest(address(splitter), VERSE_ID, address(this), 300 ether);

        uint256 redeemedUAsset = splitter.previewRedeemYTUAsset(VERSE_ID, 150 ether);
        assertEq(redeemedUAsset, 250 ether, "uAsset pool excludes converted PT backing");
    }

    function testPreviewRedeemYTUAsset_ReturnsZeroBeforeSettlement() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(this), 300 ether);
        mintYTForTest(address(splitter), VERSE_ID, address(this), 300 ether);

        assertEq(splitter.previewRedeemYTUAsset(VERSE_ID, 150 ether), 0, "pre-settle YT pool is zero");
    }

    function testRedeemYT_UsesFullPrecisionWhenPoolTimesAmountWouldOverflow() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        uint256 pool = type(uint256).max;
        mockSettledForTest(address(splitter), VERSE_ID, pool, 0);
        uAsset.mint(address(splitter), pool);
        mintYTForTest(address(splitter), VERSE_ID, BOB, pool);

        assertEq(splitter.previewRedeemYTUAsset(VERSE_ID, 2), 2, "preview");

        vm.prank(BOB);
        (uint256 uAssetAmount, uint256 memecoinAmount) = splitter.redeemYT(VERSE_ID, 2, BOB);

        assertEq(uAssetAmount, 2, "uAsset");
        assertEq(memecoinAmount, 0, "memecoin");
        assertEq(uAsset.balanceOf(BOB), 2, "received uAsset");
    }

    function testRedeemYT_RevertsWithInvalidClaimWhenRedeemOutputsAreZeroBeforeBurn() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 1, 1);
        uAsset.mint(address(splitter), 1);
        memecoin.mint(address(splitter), 1);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 3);

        vm.prank(BOB);
        vm.expectRevert(INVALID_CLAIM_SELECTOR);
        splitter.redeemYT(VERSE_ID, 1, BOB);

        assertEq(yt.balanceOf(BOB), 3, "yt not burned");
        assertEq(uAsset.balanceOf(address(splitter)), 1, "uAsset not transferred");
        assertEq(memecoin.balanceOf(address(splitter)), 1, "memecoin not transferred");
    }

    function testSplitAndMerge_RoundTripBeforeUnlocked() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 300 ether);
        pol.approve(address(splitter), 300 ether);

        (uint256 ptAmount, uint256 ytAmount) = splitter.split(VERSE_ID, 300 ether);
        assertEq(ptAmount, 300 ether, "pt minted");
        assertEq(ytAmount, 300 ether, "yt minted");
        assertEq(pt.balanceOf(address(this)), 300 ether, "pt balance");
        assertEq(yt.balanceOf(address(this)), 300 ether, "yt balance");

        pt.approve(address(splitter), 100 ether);
        yt.approve(address(splitter), 100 ether);
        uint256 polAmount = splitter.merge(VERSE_ID, 100 ether);
        assertEq(polAmount, 100 ether, "merged pol");
        assertEq(pol.balanceOf(address(this)), 100 ether, "pol refunded");
        assertEq(pt.balanceOf(address(this)), 200 ether, "pt burned");
        assertEq(yt.balanceOf(address(this)), 200 ether, "yt burned");
    }

    function testMerge_BurnsTokensDecrementsCollateralAndReturnsPOL() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 300 ether);
        pol.approve(address(splitter), 300 ether);
        splitter.split(VERSE_ID, 300 ether);

        pt.approve(address(splitter), 100 ether);
        yt.approve(address(splitter), 100 ether);

        uint256 polAmount = splitter.merge(VERSE_ID, 100 ether);
        (,,,,, uint256 totalPOLCollateral,,,,,) = splitter.splitInfos(VERSE_ID);

        assertEq(polAmount, 100 ether, "merged pol");
        assertEq(pt.balanceOf(address(this)), 200 ether, "pt burned");
        assertEq(yt.balanceOf(address(this)), 200 ether, "yt burned");
        assertEq(totalPOLCollateral, 200 ether, "collateral decremented");
        assertEq(pol.balanceOf(address(this)), 100 ether, "pol returned");
        assertEq(pol.balanceOf(address(splitter)), 200 ether, "splitter collateral");
    }

    function testSplit_RevertsOnReentrantTransferFrom() external {
        ReentrantMockERC20 reentrantPol = new ReentrantMockERC20("RPOL", "RPOL");
        POLSplitterReentryProbe probe = _deployReentryVerse(reentrantPol);
        reentrantPol.mint(address(probe), 2 ether);

        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        probe.attackSplit(1 ether);
    }

    function testMerge_RevertsOnReentrantTransfer() external {
        ReentrantMockERC20 reentrantPol = new ReentrantMockERC20("RPOL", "RPOL");
        POLSplitterReentryProbe probe = _deployReentryVerse(reentrantPol);
        reentrantPol.mint(address(probe), 2 ether);
        probe.seedSplit(2 ether);

        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        probe.attackMerge(1 ether);
    }

    function testRedeemPT_RevertsOnReentrantTransfer() external {
        ReentrantMockERC20 reentrantPol = new ReentrantMockERC20("RUASSET", "RUASSET");
        POLSplitterReentryProbe probe = _deployReentryVerse(reentrantPol);
        mockSettledForTest(address(splitter), OTHER_VERSE_ID + 1, 3 ether, 0);
        reentrantPol.mint(address(splitter), 3 ether);
        mintPTForTest(address(splitter), OTHER_VERSE_ID + 1, address(probe), 2 ether);

        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        probe.attackRedeemPT(1 ether);
    }

    function testSettle_StoresSettlementPoolsAndBlocksSecondCall() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);

        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);
        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) = splitter.splitInfos(VERSE_ID);
        assertEq(settlementUAsset, 900 ether, "uAsset");
        assertEq(settlementMemecoin, 400 ether, "memecoin");
        assertTrue(settled, "settled");

        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.AlreadySettled.selector);
        splitter.settle(VERSE_ID);
    }

    function testSettle_AllowsLauncherWhenUnlocked() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);

        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) = splitter.splitInfos(VERSE_ID);
        assertEq(settlementUAsset, 900 ether, "uAsset");
        assertEq(settlementMemecoin, 400 ether, "memecoin");
        assertTrue(settled, "settled");
    }

    function testSettle_RevertsWhenSettlementUAssetCannotCoverPTSupply() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        launcher.seedRedemption(VERSE_ID, 499 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);

        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) = splitter.splitInfos(VERSE_ID);
        assertEq(settlementUAsset, 0, "settlement uAsset not stored");
        assertEq(settlementMemecoin, 0, "settlement memecoin not stored");
        assertFalse(settled, "not settled");
    }

    function testSettle_RevertsWhenNetSettlementCannotCoverPTSupplyAfterPreRedeem() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 120 ether);

        vm.prank(address(polend));
        splitter.preRedeemPTFee(VERSE_ID, 120 ether);

        launcher.seedRedemption(VERSE_ID, 619 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) = splitter.splitInfos(VERSE_ID);
        (uint256 ptAmount, uint256 storedBacking) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(settlementUAsset, 0, "settlement uAsset not stored");
        assertEq(settlementMemecoin, 0, "settlement memecoin not stored");
        assertFalse(settled, "not settled");
        assertEq(ptAmount, 120 ether, "preRedeemed pt retained");
        assertEq(storedBacking, 120 ether, "preRedeemed backing retained");
        assertEq(polend.burnPreRedeemedBackingCallCount(), 0, "backing burn not called");
    }

    function testSettle_SucceedsAtExactNetPTBackingLowerBoundAfterPreRedeem() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 120 ether);

        vm.prank(address(polend));
        splitter.preRedeemPTFee(VERSE_ID, 120 ether);

        launcher.seedRedemption(VERSE_ID, 620 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) = splitter.splitInfos(VERSE_ID);
        (uint256 ptAmount, uint256 storedBacking) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(settlementUAsset, 500 ether, "net settlement uAsset");
        assertEq(settlementMemecoin, 400 ether, "settlement memecoin");
        assertTrue(settled, "settled");
        assertEq(ptAmount, 0, "preRedeemed pt cleared");
        assertEq(storedBacking, 0, "preRedeemed backing cleared");
        assertEq(polend.burnPreRedeemedBackingCallCount(), 1, "backing burn called");
        assertEq(polend.lastBurnPreRedeemedBackingAmount(), 120 ether, "backing burn amount");
    }

    function testSettle_RevertBeforeUnlockedOrForNonLauncher() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);

        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.NotUnlocked.selector);
        splitter.settle(VERSE_ID);

        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(ALICE);
        vm.expectRevert(IPOLSplitter.PermissionDenied.selector);
        splitter.settle(VERSE_ID);
    }

    function testRedeemPTAndRedeemYT_ConsumeCorrectPools() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        uAsset.mint(address(splitter), 600 ether);
        memecoin.mint(address(splitter), 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 200 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.prank(ALICE);
        assertEq(splitter.redeemPT(VERSE_ID, 50 ether, ALICE), 50 ether, "pt 1:1");
        assertEq(uAsset.balanceOf(ALICE), 50 ether, "pt uAsset");

        vm.prank(BOB);
        (uint256 uAssetAmount, uint256 memecoinAmount) = splitter.redeemYT(VERSE_ID, 150 ether, BOB);
        assertEq(uAssetAmount, 200 ether, "yt uAsset");
        assertEq(memecoinAmount, 150 ether, "yt memecoin");
        assertEq(uAsset.balanceOf(BOB), 200 ether, "yt uAsset balance");
        assertEq(memecoin.balanceOf(BOB), 150 ether, "yt memecoin balance");
    }

    function testRedeemPT_UsesFixedBackingRatio() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 7 ether, 0);
        uAsset.mint(address(splitter), 7 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 14 ether);

        vm.prank(ALICE);
        uint256 uAssetAmount = splitter.redeemPT(VERSE_ID, 14 ether, ALICE);

        assertEq(uAssetAmount, 7 ether, "converted uAsset");
        assertEq(pt.balanceOf(ALICE), 0, "pt burned");
        assertEq(uAsset.balanceOf(ALICE), 7 ether, "uAsset received");
        (,,,,,, uint256 settlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        assertEq(settlementUAsset, 0, "settlement debited by converted amount");
    }

    function testRedeemPT_RevertsWhenConvertedBackingIsZero() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1, 2);
        mockSettledForTest(address(splitter), VERSE_ID, 1 ether, 0);
        uAsset.mint(address(splitter), 1 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 1);

        vm.prank(ALICE);
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.redeemPT(VERSE_ID, 1, ALICE);

        assertEq(pt.balanceOf(ALICE), 1, "pt not burned");
        assertEq(uAsset.balanceOf(ALICE), 0, "uAsset not transferred");
    }

    /// @notice Regression guard for `_ptToUAsset`'s Floor rounding (INV-18 PT-solvency). With a
    ///         dust-producing ratio (3/10) and a settlement funded at exactly the floored PT
    ///         reserve, every PT holder — including the last redeemer — redeems in full. This
    ///         holds only because Floor is subadditive (`Σfloor(per-PT) ≤ floor(totalSupply·ratio)`).
    ///         If `_ptToUAsset` were changed to Ceil, each payout becomes ceil(1.2)=2, so the
    ///         first holder's `assertEq(redeemPT(..), 1)` fails immediately (and cumulatively
    ///         Σceil ≥ ceil(total) would also break coverage) — pinning the rounding direction
    ///         as an executable guard.
    function testRedeemPT_FloorRoundingCoversAllHoldersAtDustRatio() external {
        address carol = makeAddr("carol");
        // Ratio 3/10 truncates each 4-PT redemption (4*3/10 = 1.2 -> floor 1).
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 3, 10);
        // Fund the settlement at exactly the floored total reserve floor(12*3/10) = 3 — the
        // tight lower bound where Σfloor(per-PT) = floor(total), so the reserve pays out 1+1+1
        // and is exhausted to 0 (dust would only remain if funded above this floor reserve).
        mockSettledForTest(address(splitter), VERSE_ID, 3, 0);
        uAsset.mint(address(splitter), 3);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 4);
        mintPTForTest(address(splitter), VERSE_ID, BOB, 4);
        mintPTForTest(address(splitter), VERSE_ID, carol, 4);

        // Each holder redeems 4 PT for floor(4 * 3 / 10) = 1 uAsset; all three succeed.
        vm.prank(ALICE);
        assertEq(splitter.redeemPT(VERSE_ID, 4, ALICE), 1, "alice floor share");
        vm.prank(BOB);
        assertEq(splitter.redeemPT(VERSE_ID, 4, BOB), 1, "bob floor share");
        // Last redeemer at the tight boundary: settlementUAsset == uAssetAmount == 1, so this
        // both proves every holder stays redeemable and guards the strict `<` of redeemPT's
        // coverage check (flipping it to `<=` would revert carol here).
        vm.prank(carol);
        assertEq(splitter.redeemPT(VERSE_ID, 4, carol), 1, "carol last redeemer covered");

        assertEq(uAsset.balanceOf(ALICE), 1, "alice balance");
        assertEq(uAsset.balanceOf(BOB), 1, "bob balance");
        assertEq(uAsset.balanceOf(carol), 1, "carol balance");
        // Σfloor(per-PT) = 1+1+1 = 3 = floor(totalSupply*3/10), exhausting the reserve exactly —
        // the equality that only Floor's subadditivity guarantees at this tight boundary.
        assertEq(uAsset.balanceOf(address(splitter)), 0, "settlement exhausted by floored per-PT sums");
    }

    function testRedeemYT_ReservesConvertedPTBacking() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        uAsset.mint(address(splitter), 600 ether);
        memecoin.mint(address(splitter), 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 200 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.prank(BOB);
        (uint256 uAssetAmount, uint256 memecoinAmount) = splitter.redeemYT(VERSE_ID, 150 ether, BOB);

        assertEq(uAssetAmount, 250 ether, "uAsset pool excludes converted PT backing");
        assertEq(memecoinAmount, 150 ether, "memecoin");
        assertEq(uAsset.balanceOf(BOB), 250 ether, "uAsset received");
        assertEq(memecoin.balanceOf(BOB), 150 ether, "memecoin received");
    }

    /// @notice redeemPT emits RedeemPT with verseId/from/to indexed plus the redeemed ptAmount.
    /// @dev Mirrors testRedeemPT_UsesFixedBackingRatio: 7:14 ratio => 14e18 PT converts to 7e18 uAsset.
    function testRedeemPT_EmitsRedeemPTEvent() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 7 ether, 0);
        uAsset.mint(address(splitter), 7 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 14 ether);

        vm.expectEmit(true, true, true, true);
        emit RedeemPT(VERSE_ID, ALICE, ALICE, 14 ether);
        vm.prank(ALICE);
        splitter.redeemPT(VERSE_ID, 14 ether, ALICE);
    }

    /// @notice redeemYT emits RedeemYT with verseId/from/to indexed plus yt/uAsset/memecoin amounts.
    /// @dev Mirrors testRedeemYT_ReservesConvertedPTBacking: 150e18 YT => 250e18 uAsset, 150e18 memecoin.
    function testRedeemYT_EmitsRedeemYTEvent() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        uAsset.mint(address(splitter), 600 ether);
        memecoin.mint(address(splitter), 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 200 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.expectEmit(true, true, true, true);
        emit RedeemYT(VERSE_ID, BOB, BOB, 150 ether, 250 ether, 150 ether);
        vm.prank(BOB);
        splitter.redeemYT(VERSE_ID, 150 ether, BOB);
    }

    /// @notice initializeVerse emits VerseInitialized with verseId/pt/yt indexed.
    /// @dev The expected pt/yt are the deterministic clone addresses for the fresh splitter's
    ///      implementations (Clones.cloneDeterministic with salt bytes32(verseId)), so the
    ///      asserted addresses equal the actually deployed tokens.
    function testInitializeVerse_EmitsVerseInitializedEvent() external {
        POLSplitterUpgradeable otherSplitter = _deploySplitter(address(launcher));
        address expectedPt = Clones.predictDeterministicAddress(
            otherSplitter.principalTokenImplementation(), bytes32(VERSE_ID), address(otherSplitter)
        );
        address expectedYt = Clones.predictDeterministicAddress(
            otherSplitter.yieldTokenImplementation(), bytes32(VERSE_ID), address(otherSplitter)
        );

        vm.expectEmit(true, true, true, true);
        emit VerseInitialized(VERSE_ID, expectedPt, expectedYt);
        vm.prank(address(launcher));
        otherSplitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
    }

    /// @notice split emits Split with verseId/user indexed and pol/pt/yt amounts (all equal pre-launch).
    /// @dev Mirrors testSplitAndMerge_RoundTripBeforeUnlocked: 300e18 POL in => 300e18 PT + 300e18 YT.
    function testSplit_EmitsSplitEvent() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 300 ether);
        pol.approve(address(splitter), 300 ether);

        vm.expectEmit(true, true, true, true);
        emit Split(VERSE_ID, address(this), 300 ether, 300 ether, 300 ether);
        splitter.split(VERSE_ID, 300 ether);
    }

    /// @notice merge emits Merge with verseId/user indexed and amount/polAmount (equal pre-launch).
    /// @dev Mirrors testMerge_BurnsTokensDecrementsCollateralAndReturnsPOL: 100e18 PT+YT => 100e18 POL.
    function testMerge_EmitsMergeEvent() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 300 ether);
        pol.approve(address(splitter), 300 ether);
        splitter.split(VERSE_ID, 300 ether);
        pt.approve(address(splitter), 100 ether);
        yt.approve(address(splitter), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Merge(VERSE_ID, address(this), 100 ether, 100 ether);
        splitter.merge(VERSE_ID, 100 ether);
    }

    /// @notice recordPTBackingRatio emits BackingRatioRecorded with verseId indexed and the stored ratio.
    /// @dev Mirrors testRecordPTBackingRatio_StoresRatioAndPreviewConvertsPT: 7:14 ratio.
    function testRecordPTBackingRatio_EmitsBackingRatioRecordedEvent() external {
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Locked);

        vm.expectEmit(true, true, true, true);
        emit BackingRatioRecorded(VERSE_ID, 7 ether, 14 ether);
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
    }

    /// @notice settle emits VerseSettled with the net settlementUAsset after the pre-redeemed PT
    ///         backing is deducted (must equal the function's return value).
    /// @dev Mirrors testSettle_BurnsPreRedeemedBackingAndDeductsSettlementUAsset: launcher pre-redeems
    ///      120e18 PT (1:1 backing) against a 900e18 uAsset redemption => 780e18 net; settle is
    ///      onlyLauncher, so the call is pranked as the launcher like the other settle tests.
    function testSettle_EmitsVerseSettledEvent() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 120 ether);

        vm.prank(address(polend));
        splitter.preRedeemPTFee(VERSE_ID, 120 ether);

        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);

        vm.expectEmit(true, true, true, true);
        emit VerseSettled(VERSE_ID, 780 ether, 400 ether);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);
    }

    function testRedeemYT_RevertsOnZeroRecipientBeforeBurn() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        uAsset.mint(address(splitter), 600 ether);
        memecoin.mint(address(splitter), 300 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.prank(BOB);
        vm.expectRevert(ZERO_INPUT_SELECTOR);
        splitter.redeemYT(VERSE_ID, 150 ether, address(0));

        assertEq(yt.balanceOf(BOB), 300 ether, "yt not burned");
        assertEq(uAsset.balanceOf(address(splitter)), 600 ether, "uAsset not transferred");
        assertEq(memecoin.balanceOf(address(splitter)), 300 ether, "memecoin not transferred");
    }

    function testRedeemYT_RevertsWithInvalidClaimWhenNoOutstandingYT() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 600 ether, 300 ether);
        uAsset.mint(address(splitter), 600 ether);
        memecoin.mint(address(splitter), 300 ether);

        vm.expectRevert(INVALID_CLAIM_SELECTOR);
        splitter.redeemYT(VERSE_ID, 1 ether, BOB);
    }

    function testPreviewRedeemYTUAsset_RevertsWhenSettlementUAssetCannotReservePTSupply() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 50 ether, 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 100 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.expectRevert(abi.encodeWithSelector(PANIC_SELECTOR, uint256(0x11)));
        splitter.previewRedeemYTUAsset(VERSE_ID, 150 ether);
    }

    function testRedeemYT_RevertsWhenSettlementUAssetCannotReservePTSupply() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 50 ether, 300 ether);
        uAsset.mint(address(splitter), 50 ether);
        memecoin.mint(address(splitter), 300 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 100 ether);
        mintYTForTest(address(splitter), VERSE_ID, BOB, 300 ether);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PANIC_SELECTOR, uint256(0x11)));
        splitter.redeemYT(VERSE_ID, 150 ether, BOB);
    }

    function testPreRedeemPTFee_BurnsLauncherPTWithoutApproveAndRecordsPreRedeemedPT() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 120 ether);

        vm.prank(address(polend));
        (bool success,) =
            address(splitter).call(abi.encodeWithSignature("preRedeemPTFee(uint256,uint256)", VERSE_ID, 120 ether));

        assertTrue(success, "preRedeemPTFee");
        assertEq(pt.balanceOf(address(launcher)), 0, "launcher pt burned");
        (uint256 ptAmount,) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(ptAmount, 120 ether, "preRedeemedPT");
    }

    function testPreRedeemPTFee_RecordsRawPTAndConvertedBacking() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 140 ether);

        vm.prank(address(polend));
        uint256 uAssetBacking = splitter.preRedeemPTFee(VERSE_ID, 140 ether);

        assertEq(uAssetBacking, 70 ether, "returned backing");
        (uint256 ptAmount, uint256 storedBacking) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(ptAmount, 140 ether, "raw pt");
        assertEq(storedBacking, 70 ether, "stored backing");
        assertEq(pt.balanceOf(address(launcher)), 0, "launcher pt burned");
    }

    function testPreRedeemPTFee_RevertsWhenConvertedBackingIsZeroBeforeBurn() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1, 2);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 1);

        vm.prank(address(polend));
        vm.expectRevert(IPOLSplitter.InvalidClaim.selector);
        splitter.preRedeemPTFee(VERSE_ID, 1);

        assertEq(pt.balanceOf(address(launcher)), 1, "pt not burned");
        (uint256 ptAmount, uint256 storedBacking) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(ptAmount, 0, "raw pt not recorded");
        assertEq(storedBacking, 0, "backing not recorded");
    }

    function testSettle_BurnsPreRedeemedBackingAndDeductsSettlementUAsset() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 120 ether);

        vm.prank(address(polend));
        (bool success,) =
            address(splitter).call(abi.encodeWithSignature("preRedeemPTFee(uint256,uint256)", VERSE_ID, 120 ether));
        assertTrue(success, "preRedeemPTFee");

        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        assertEq(polend.burnPreRedeemedBackingCallCount(), 1, "backing burn called");
        assertEq(polend.lastBurnPreRedeemedBackingVerseId(), VERSE_ID, "verse id");
        assertEq(polend.lastBurnPreRedeemedBackingAmount(), 120 ether, "backing amount");
        assertEq(settlementUAsset, 780 ether, "net settlement uAsset");
        (uint256 ptAmount,) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(ptAmount, 0, "preRedeemedPT cleared");
    }

    function testSettle_BurnsPreRedeemedBackingAndDeductsConvertedBacking() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 7 ether, 14 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 140 ether);

        vm.prank(address(polend));
        uint256 uAssetBacking = splitter.preRedeemPTFee(VERSE_ID, 140 ether);
        assertEq(uAssetBacking, 70 ether, "preRedeem backing");

        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        (,,,,,, uint256 settlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        assertEq(polend.burnPreRedeemedBackingCallCount(), 1, "backing burn called");
        assertEq(polend.lastBurnPreRedeemedBackingVerseId(), VERSE_ID, "verse id");
        assertEq(polend.lastBurnPreRedeemedBackingAmount(), 70 ether, "backing amount");
        assertEq(settlementUAsset, 830 ether, "net settlement uAsset");
        (uint256 ptAmount, uint256 storedBacking) = splitter.preRedeemedStates(VERSE_ID);
        assertEq(ptAmount, 0, "raw pt cleared");
        assertEq(storedBacking, 0, "backing cleared");
    }

    /// @notice Verifies preRedeemPTFee reverts with AlreadySettled after settle completes.
    /// @dev The AlreadySettled guard is a defensive safety line: normal flow routes settled PT fees
    /// through redeemPT, so preRedeemPTFee should never be callable post-settle.
    function testPreRedeemPTFee_RevertsAfterSettle() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(splitter), 500 ether);
        splitter.split(VERSE_ID, 500 ether);
        mintPTForTest(address(splitter), VERSE_ID, address(launcher), 100 ether);

        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        splitter.settle(VERSE_ID);

        vm.prank(address(polend));
        vm.expectRevert(IPOLSplitter.AlreadySettled.selector);
        splitter.preRedeemPTFee(VERSE_ID, 100 ether);
    }

    function testDeployTokens_DifferentVersesStoreTheirOwnUAsset() external view {
        (,,,, address verseUAsset,,,,,,) = splitter.splitInfos(VERSE_ID);
        (,,,, address otherVerseUAsset,,,,,,) = splitter.splitInfos(OTHER_VERSE_ID);

        assertEq(verseUAsset, address(uAsset), "verse uAsset");
        assertEq(otherVerseUAsset, address(otherUAsset), "other verse uAsset");
    }

    function testRedeemPT_DifferentVersesDoNotMixUAsset() external {
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(OTHER_VERSE_ID, 1 ether, 1 ether);
        mockSettledForTest(address(splitter), VERSE_ID, 100 ether, 0);
        mockSettledForTest(address(splitter), OTHER_VERSE_ID, 100 ether, 0);
        uAsset.mint(address(splitter), 100 ether);
        otherUAsset.mint(address(splitter), 100 ether);
        mintPTForTest(address(splitter), VERSE_ID, ALICE, 100 ether);

        vm.prank(ALICE);
        splitter.redeemPT(VERSE_ID, 100 ether, ALICE);

        assertEq(uAsset.balanceOf(ALICE), 100 ether, "correct uAsset paid");
        assertEq(otherUAsset.balanceOf(ALICE), 0, "other uAsset untouched");
    }

    /// @notice setTokenImplementations swaps both clone-template pointers and emits
    ///         TokenImplementationsUpdated carrying the old and new pair.
    /// @dev The old pair is read from the getters before the swap; the new pair is freshly deployed
    ///      marker templates, so all four emitted addresses are exact.
    function testSetTokenImplementations_UpdatesPointersAndEmitsEvent() external {
        address oldPt = splitter.principalTokenImplementation();
        address oldYt = splitter.yieldTokenImplementation();
        address newPt = address(new MarkerSplitterTokenTemplate());
        address newYt = address(new MarkerSplitterTokenTemplate());

        vm.expectEmit(true, true, true, true);
        emit TokenImplementationsUpdated(oldPt, oldYt, newPt, newYt);
        splitter.setTokenImplementations(newPt, newYt);

        assertEq(splitter.principalTokenImplementation(), newPt, "pt implementation");
        assertEq(splitter.yieldTokenImplementation(), newYt, "yt implementation");
    }

    /// @notice setTokenImplementations is owner-only: a non-owner call reverts with
    ///         OwnableUnauthorizedAccount before any pointer changes.
    function testSetTokenImplementations_RevertsForNonOwner() external {
        MarkerSplitterTokenTemplate template = new MarkerSplitterTokenTemplate();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, ALICE));
        splitter.setTokenImplementations(address(template), address(template));
    }

    /// @notice setTokenImplementations rejects a zero address for either template pointer.
    /// @dev The other argument is always a valid deployed template so each zero case is isolated.
    function testSetTokenImplementations_RevertsForZeroAddress() external {
        MarkerSplitterTokenTemplate template = new MarkerSplitterTokenTemplate();

        vm.expectRevert(IPOLSplitter.ZeroInput.selector);
        splitter.setTokenImplementations(address(0), address(template));

        vm.expectRevert(IPOLSplitter.ZeroInput.selector);
        splitter.setTokenImplementations(address(template), address(0));
    }

    /// @notice setTokenImplementations rejects codeless (EOA) addresses for either pointer with
    ///         TokenImplementationCodeNotReady naming the offending address.
    function testSetTokenImplementations_RevertsForCodelessAddress() external {
        MarkerSplitterTokenTemplate template = new MarkerSplitterTokenTemplate();

        vm.expectRevert(abi.encodeWithSelector(IPOLSplitter.TokenImplementationCodeNotReady.selector, ALICE));
        splitter.setTokenImplementations(ALICE, address(template));

        vm.expectRevert(abi.encodeWithSelector(IPOLSplitter.TokenImplementationCodeNotReady.selector, ALICE));
        splitter.setTokenImplementations(address(template), ALICE);
    }

    /// @notice Generation isolation: after setTokenImplementations, only verses initialized later
    ///         clone the new templates — existing PT/YT clones stay frozen on the old ones.
    /// @dev EIP-1167 clones bake the template address into their own bytecode at creation, so
    ///      `marker()` (present only on the rotated generation) succeeds on the new verse's clones
    ///      and fails on the old verse's clones, while the old clone still answers the real
    ///      PrincipalToken surface (`name()`) — proving it is alive and un-migrated.
    function testSetTokenImplementations_NewVersesUseNewTemplates_OldVersesFrozen() external {
        POLSplitterUpgradeable fresh = _deploySplitter(address(launcher));
        vm.prank(address(launcher));
        fresh.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
        (address oldPt, address oldYt) = fresh.getPTAndYT(VERSE_ID);

        MarkerSplitterTokenTemplate ptTemplate = new MarkerSplitterTokenTemplate();
        MarkerSplitterTokenTemplate ytTemplate = new MarkerSplitterTokenTemplate();
        fresh.setTokenImplementations(address(ptTemplate), address(ytTemplate));

        vm.prank(address(launcher));
        fresh.initializeVerse(OTHER_VERSE_ID, address(pol), address(memecoin), address(uAsset), "Rotated", "ROT");
        (address newPt, address newYt) = fresh.getPTAndYT(OTHER_VERSE_ID);

        (bool ptOk, uint256 ptMarker) = _marker(newPt);
        (bool ytOk, uint256 ytMarker) = _marker(newYt);
        assertTrue(ptOk, "new pt clone points at marker template");
        assertEq(ptMarker, 42, "pt marker value");
        assertTrue(ytOk, "new yt clone points at marker template");
        assertEq(ytMarker, 42, "yt marker value");

        (bool oldPtOk,) = _marker(oldPt);
        (bool oldYtOk,) = _marker(oldYt);
        assertFalse(oldPtOk, "old pt clone stays on the old template");
        assertFalse(oldYtOk, "old yt clone stays on the old template");
        assertEq(PrincipalToken(oldPt).name(), "PT-Verse", "old pt clone still alive on old template");

        // Replaying an already-deployed verseId must still revert after template rotation: the
        // AlreadyDeployed guard reads splitInfos[verseId].pt, independent of the template pointers.
        vm.prank(address(launcher));
        vm.expectRevert(IPOLSplitter.AlreadyDeployed.selector);
        fresh.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
    }

    /// @notice Full verse lifecycle on rotated templates: split → settle → redeemPT → redeemYT all
    ///         work against marker-template clones (non-regression for the template ABI the
    ///         splitter calls through the clones).
    /// @dev 1:1 backing; 500e18 POL in with a 900e18/400e18 seeded redemption => PT redeems 500e18
    ///      uAsset, YT redeems the remaining 400e18 uAsset plus all 400e18 memecoin.
    function testSetTokenImplementations_NewVerseFullFlowAfterRotation() external {
        POLSplitterUpgradeable fresh = _deploySplitter(address(launcher));
        MarkerSplitterTokenTemplate ptTemplate = new MarkerSplitterTokenTemplate();
        MarkerSplitterTokenTemplate ytTemplate = new MarkerSplitterTokenTemplate();
        fresh.setTokenImplementations(address(ptTemplate), address(ytTemplate));

        vm.prank(address(launcher));
        fresh.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
        (address versePt, address verseYt) = fresh.getPTAndYT(VERSE_ID);
        (bool ptOk,) = _marker(versePt);
        (bool ytOk,) = _marker(verseYt);
        assertTrue(ptOk, "verse pt clone points at marker template");
        assertTrue(ytOk, "verse yt clone points at marker template");

        vm.prank(address(launcher));
        fresh.recordPTBackingRatio(VERSE_ID, 1 ether, 1 ether);
        pol.mint(address(this), 500 ether);
        pol.approve(address(fresh), 500 ether);
        (uint256 ptAmount, uint256 ytAmount) = fresh.split(VERSE_ID, 500 ether);
        assertEq(ptAmount, 500 ether, "pt minted");
        assertEq(ytAmount, 500 ether, "yt minted");

        launcher.seedRedemption(VERSE_ID, 900 ether, 400 ether);
        launcher.setStage(VERSE_ID, IMemeverseLauncher.Stage.Unlocked);
        vm.prank(address(launcher));
        fresh.settle(VERSE_ID);

        uint256 uAssetBefore = uAsset.balanceOf(address(this));
        uint256 redeemedUAsset = fresh.redeemPT(VERSE_ID, 500 ether, address(this));
        assertEq(redeemedUAsset, 500 ether, "pt redemption at 1:1 backing");
        assertEq(uAsset.balanceOf(address(this)) - uAssetBefore, 500 ether, "pt uAsset received");

        uAssetBefore = uAsset.balanceOf(address(this));
        uint256 memecoinBefore = memecoin.balanceOf(address(this));
        (uint256 ytUAsset, uint256 ytMemecoin) = fresh.redeemYT(VERSE_ID, 500 ether, address(this));
        assertEq(ytUAsset, 400 ether, "yt uAsset is settlement minus PT reserve");
        assertEq(ytMemecoin, 400 ether, "yt memecoin");
        assertEq(uAsset.balanceOf(address(this)) - uAssetBefore, 400 ether, "yt uAsset received");
        assertEq(memecoin.balanceOf(address(this)) - memecoinBefore, 400 ether, "yt memecoin received");
    }

    /// @notice Probes `marker()` on a token address via staticcall; `ok == false` means the token's
    ///         template generation has no marker (the pre-rotation templates).
    function _marker(address token) internal view returns (bool ok, uint256 value) {
        bytes memory returned;
        (ok, returned) = token.staticcall(abi.encodeWithSignature("marker()"));
        if (ok) value = abi.decode(returned, (uint256));
    }

    function _deployReentryVerse(ReentrantMockERC20 reentrantToken) internal returns (POLSplitterReentryProbe probe) {
        uint256 reentryVerseId = OTHER_VERSE_ID + 1;
        vm.prank(address(launcher));
        splitter.initializeVerse(
            reentryVerseId, address(reentrantToken), address(memecoin), address(reentrantToken), "Reentrant", "RNT"
        );
        vm.prank(address(launcher));
        splitter.recordPTBackingRatio(reentryVerseId, 1 ether, 1 ether);
        probe = new POLSplitterReentryProbe(splitter, reentrantToken, reentryVerseId);
    }
}
