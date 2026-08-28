// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {POLendUpgradeable} from "../../src/polend/POLendUpgradeable.sol";
import {POLSplitterUpgradeable} from "../../src/polend/POLSplitterUpgradeable.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {
    CallRecorder,
    MockHookForPOLendIntegration,
    MockMemecoinForPOLendIntegration,
    MockPolForPOLendIntegration,
    MockPOLendForPOLendIntegration,
    MockPOLSplitterForPOLendIntegration,
    MockProxyDeployerForPOLendIntegration,
    MockRouterForPOLendIntegration
} from "../mocks/verse/LauncherPOLendIntegrationMocks.sol";
import {MockOFTDispatcher} from "../mocks/verse/LauncherLifecycleMocks.sol";
import {MintableToken} from "../mocks/polend/POLendMocks.sol";

contract MemeverseLauncherPOLendIntegrationTest is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockRouterForPOLendIntegration internal router;
    MockHookForPOLendIntegration internal hook;
    MockProxyDeployerForPOLendIntegration internal proxyDeployer;
    MockERC20 internal uAsset;
    MockMemecoinForPOLendIntegration internal memecoin;
    MockPolForPOLendIntegration internal pol;
    MockPOLendForPOLendIntegration internal polend;
    MockPOLSplitterForPOLendIntegration internal splitter;
    MockOFTDispatcher internal dispatcher;
    MintableToken internal pt;
    MintableToken internal yt;
    MockERC20 internal polUAssetLp;
    MockERC20 internal ptUAssetLp;
    MockERC20 internal ptPolLp;
    CallRecorder internal recorder;

    function setUp() external {
        proxyDeployer = new MockProxyDeployerForPOLendIntegration();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        recorder = new CallRecorder();
        polend = new MockPOLendForPOLendIntegration(uAsset, recorder);
        dispatcher = new MockOFTDispatcher();
        pt = new MintableToken("PT", "PT");
        yt = new MintableToken("YT", "YT");
        polUAssetLp = new MockERC20("POL-UASSET-LP", "POL-UASSET-LP", 18);
        ptUAssetLp = new MockERC20("PT-UASSET-LP", "PT-UASSET-LP", 18);
        ptPolLp = new MockERC20("PT-POL-LP", "PT-POL-LP", 18);
        splitter = new MockPOLSplitterForPOLendIntegration(address(pt), address(yt), recorder);
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        address(this),
                        address(0x1),
                        address(0x2),
                        address(0x3),
                        address(0x4),
                        address(0x5),
                        address(polend),
                        address(splitter),
                        25,
                        uint128(115_000),
                        uint128(135_000),
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = IMemeverseLauncher(launcherProxy);
        memecoin = new MockMemecoinForPOLendIntegration(address(launcher));
        pol = new MockPolForPOLendIntegration(address(launcher), address(memecoin));
        splitter.setPolForTest(address(pol));
        splitter.setPolendForTest(address(polend));
        hook = new MockHookForPOLendIntegration(address(launcher), recorder);
        router = new MockRouterForPOLendIntegration(address(hook));

        launcher.setMemeverseUniswapHook(address(hook));
        hook.setPoolInitializer(address(router));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setFundMetaData(address(uAsset), 10 ether, 1);

        polend.setLendMarket(address(pt), address(yt));
        router.setCreateLiquidityResult(1400 ether);
        router.setAddLiquidityResult(100 ether);
        router.setLpToken(address(pol), address(uAsset), address(polUAssetLp));
        router.setLpToken(address(pt), address(uAsset), address(ptUAssetLp));
        router.setLpToken(address(pt), address(pol), address(ptPolLp));
    }

    function _deployRealPOLend() internal returns (POLendUpgradeable realPolend) {
        POLendUpgradeable implementation = new POLendUpgradeable();
        bytes memory data = abi.encodeCall(
            POLendUpgradeable.initialize,
            (address(this), 0.1 ether, 10 ether, address(this), launcherProxy, address(splitter), address(this))
        );
        return POLendUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _deployRealPOLendAndSplitter()
        internal
        returns (POLendUpgradeable realPolend, POLSplitterUpgradeable realSplitter, address realPT)
    {
        POLSplitterUpgradeable splitterImplementation = new POLSplitterUpgradeable();
        bytes memory splitterData = abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), launcherProxy));
        realSplitter = POLSplitterUpgradeable(address(new ERC1967Proxy(address(splitterImplementation), splitterData)));

        POLendUpgradeable polendImplementation = new POLendUpgradeable();
        bytes memory polendData = abi.encodeCall(
            POLendUpgradeable.initialize,
            (address(this), 0.1 ether, 10 ether, address(this), launcherProxy, address(realSplitter), address(this))
        );
        realPolend = POLendUpgradeable(address(new ERC1967Proxy(address(polendImplementation), polendData)));

        setPolendForTest(launcherProxy, address(realPolend));
        setPolSplitterForTest(launcherProxy, address(realSplitter));

        vm.prank(launcherProxy);
        (realPT,) =
            realSplitter.initializeVerse(VERSE_ID, address(pol), address(memecoin), address(uAsset), "Verse", "VRS");
        vm.prank(launcherProxy);
        realSplitter.recordPTBackingRatio(VERSE_ID, 1, 2);
    }

    function _seedLauncherAndPolendFunding(uint256 normalFunds, uint256 leveragedFunds) internal {
        if (normalFunds != 0) uAsset.mint(launcherProxy, normalFunds);
        if (leveragedFunds != 0) uAsset.mint(launcherProxy, leveragedFunds);
    }

    function _sortedTokenAddresses(address a, address b, address c)
        internal
        pure
        returns (address low, address mid, address high)
    {
        low = a;
        mid = b;
        high = c;
        if (low > mid) (low, mid) = (mid, low);
        if (mid > high) (mid, high) = (high, mid);
        if (low > mid) (low, mid) = (mid, low);
    }

    function _setSemanticClaimQuote(address tokenA, address tokenB, uint256 tokenAFee, uint256 tokenBFee) internal {
        (uint256 fee0, uint256 fee1) = tokenA < tokenB ? (tokenAFee, tokenBFee) : (tokenBFee, tokenAFee);
        hook.setClaimQuote(tokenA, tokenB, fee0, fee1);
    }

    function _setGenesisVerse(uint128 endTime, bool flashGenesis) internal {
        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            address(uAsset),
            address(memecoin),
            address(pol),
            address(0xD00D), // yieldVault
            address(0xCAFE), // governor
            address(0), // incentivizer
            endTime,
            endTime + 7 days,
            IMemeverseLauncher.Stage.Genesis,
            flashGenesis
        );
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = uint32(block.chainid + 1);
        setOmnichainIdsForTest(launcherProxy, VERSE_ID, chainIds);
    }

    /// @dev Write a full Memeverse struct back to proxy storage, preserving omnichainIds.
    function _writeVerseBack(IMemeverseLauncher.Memeverse memory verse) internal {
        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            verse.uAsset,
            verse.memecoin,
            verse.pol,
            verse.yieldVault,
            verse.governor,
            verse.incentivizer,
            verse.endTime,
            verse.unlockTime,
            verse.currentStage,
            verse.flashGenesis
        );
        setOmnichainIdsForTest(launcherProxy, VERSE_ID, verse.omnichainIds);
    }

    function testDeployLiquidity_CreatesFourPoolsAndSplitsNormalLeveragedYT() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        _seedLauncherAndPolendFunding(1000 ether, 1000 ether);

        // Drive the real stage transition so the production _deployLiquidity path (not a test-side
        // replica) creates the pools and splits the YT entitlements.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) =
            MemeverseLauncherUpgradeable(launcherProxy).auxiliaryLiquidities(VERSE_ID);
        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertGt(polUAssetLpAmount, 0, "pol/uAsset");
        assertGt(ptUAssetLpAmount, 0, "pt/uAsset");
        assertGt(ptPolLpAmount, 0, "pt/pol");
        assertEq(router.createPoolAndAddLiquidityCallCount(), 4, "four pools created");
        assertEq(MemeverseLauncherUpgradeable(launcherProxy).totalNormalClaimableYT(VERSE_ID), 300 ether, "normal yt");
        assertEq(market.totalLeveragedYT, 300 ether, "leveraged yt");
        assertEq(yt.balanceOf(address(polend)), 300 ether, "leveraged yt moved");
    }

    function testDeployLiquidity_UsesUnifiedTotalFundsForFourPoolAllocation() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 800 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 100 ether);
        _seedLauncherAndPolendFunding(800 ether, 100 ether);

        // Drive the real stage transition so the production allocation math runs end to end.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        (, uint256 mainUAsset) = router.lastCreateAmounts(address(memecoin), address(uAsset));
        (uint256 polUAssetPol, uint256 polUAssetUAsset) = router.lastCreateAmounts(address(pol), address(uAsset));
        (, uint256 ptUAssetUAsset) = router.lastCreateAmounts(address(pt), address(uAsset));
        (, uint256 ptPolPol) = router.lastCreateAmounts(address(pt), address(pol));
        assertEq(mainUAsset, 630 ether, "main uAsset");
        assertEq(polUAssetPol, 400 ether, "pol/uAsset pol");
        assertEq(polUAssetUAsset, 180 ether, "pol/uAsset uAsset");
        assertEq(ptUAssetUAsset, 90 ether, "pt/uAsset uAsset");
        assertEq(ptPolPol, 400 ether, "pt/pol pol");
        uint256 expectedNormalYT = uint256(600 ether) * 800 / 900;
        uint256 expectedLeveragedYT = uint256(600 ether) - expectedNormalYT;
        assertEq(
            MemeverseLauncherUpgradeable(launcherProxy).totalNormalClaimableYT(VERSE_ID), expectedNormalYT, "normal yt"
        );
        assertEq(polend.getLendMarket(VERSE_ID).totalLeveragedYT, expectedLeveragedYT, "leveraged yt");
    }

    function testDeployLiquidity_RecordsActualMainPoolUAssetSpendForPTBacking() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        _seedLauncherAndPolendFunding(1000 ether, 1000 ether);

        uint256 budgetedMainUAsset = 1400 ether;
        uint256 actualMainUAssetUsed = 1000 ether;
        router.setCreateSpend(address(memecoin), address(uAsset), budgetedMainUAsset, actualMainUAssetUsed);

        // Drive the real stage transition so the production path records the PT backing ratio.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        assertEq(splitter.lastPTBackingVerseId(), VERSE_ID, "verse id");
        assertEq(splitter.lastPTBackingNumerator(), actualMainUAssetUsed, "pt backing numerator");
        assertEq(splitter.lastPTBackingDenominator(), 1400 ether, "pt backing denominator");
    }

    function testDeployLiquidity_MainPoolBurnsUnspentDesiredMemecoinBudget() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 800 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 100 ether);
        _seedLauncherAndPolendFunding(800 ether, 100 ether);

        router.setCreateSpend(address(memecoin), address(uAsset), 620 ether, 600 ether);

        // Drive the real stage transition so the production path burns the unspent memecoin budget.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        assertEq(memecoin.burnedAmount(), 10 ether, "unspent memecoin burned");
    }

    function testDeployLiquidity_RoutesUnusedBootstrapUAssetAndBurnsUnusedMemecoin() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 800 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 100 ether);
        // Seed only the normal funds here: the functional mock POLend mints the 100 ether leveraged
        // debt funds to the launcher itself during the changeStage-driven finalize, so pre-minting
        // them would leave an unspent residue and break the zero-balance expectation below.
        _seedLauncherAndPolendFunding(800 ether, 0);

        uint256 polUAssetSpend = uint256(1_200 ether) / 7;
        uint256 ptUAssetSpend = uint256(600 ether) / 7;
        uint256 expectedUnusedUAsset = 900 ether - 600 ether - polUAssetSpend - ptUAssetSpend;

        router.setCreateSpend(address(memecoin), address(uAsset), 620 ether, 600 ether);
        router.setCreateSpend(address(pol), address(uAsset), 400 ether, polUAssetSpend);
        router.setCreateSpend(address(pt), address(uAsset), 200 ether, ptUAssetSpend);

        vm.expectEmit(true, true, true, true);
        emit IMemeverseLauncher.BootstrapUnusedAssetsHandled(
            VERSE_ID, address(uAsset), address(memecoin), expectedUnusedUAsset, expectedUnusedUAsset, 0, 10 ether
        );
        // Drive the real stage transition so the production path routes the unused bootstrap assets.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        assertEq(polend.lastFundSettlementDustReserveUAsset(), address(uAsset), "fund uAsset");
        assertEq(polend.lastFundSettlementDustReserveAmount(), expectedUnusedUAsset, "fund amount");
        assertEq(polend.mockSettlementDustReserve(), expectedUnusedUAsset, "credited reserve");
        assertEq(memecoin.burnedAmount(), 10 ether, "burned memecoin");
        assertEq(uAsset.balanceOf(address(launcher)), 0, "no uAsset left");
    }

    function testDeployLiquidity_RevertWhenLeveragedLiquidityNotFunded() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        // Record genesis funds in storage WITHOUT minting any uAsset to the launcher and keep the
        // leveraged debt at zero (a nonzero debt is always funded by the changeStage-driven finalize
        // on the functional mock, so "recorded but unfunded" can only be constructed on the normal
        // side). The main pool's 700 ether uAsset pull then exceeds the launcher's zero balance and
        // the solmate MockERC20 balance subtraction underflows. Pin that arithmetic panic instead of
        // accepting any revert.
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);

        vm.expectRevert(stdError.arithmeticError);
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);
    }

    function testChangeStage_FinalizesAndInitializesWhenLeveragedInterestMeetsThreshold() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        polend.setTotalLeveragedInterest(VERSE_ID, 100 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        vm.warp(block.timestamp + 1 days + 1);

        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "locked");
        assertEq(splitter.initializeVerseCallCount(), 1, "splitter initialized");
    }

    function testDeployLiquidity_RequiresRealLeveragedFundsFromPOLend() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        _seedLauncherAndPolendFunding(1000 ether, 0);

        POLendUpgradeable realPolend = _deployRealPOLend();
        realPolend.setMaxSettlementDustReserve(address(uAsset), uint128(1e9));
        vm.prank(address(launcher));
        realPolend.registerLendMarket(VERSE_ID);
        setPolendForTest(launcherProxy, address(realPolend));

        uAsset.mint(address(this), 1100 ether);
        uAsset.approve(address(realPolend), type(uint256).max);
        realPolend.leveragedGenesis(VERSE_ID, 100 ether);

        // Drive the real stage transition: changeStage runs finalizeLeveragedGenesis on the real
        // POLend (which mints the debt funds to the launcher), then the production _deployLiquidity
        // path spends exactly those funds — no test-side replica is involved.
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);

        assertEq(uAsset.balanceOf(address(launcher)), 0, "launcher spent funded uAsset");
        assertEq(realPolend.getTotalLeveragedDebt(VERSE_ID), 1000 ether, "real debt tracked");
    }

    function testSettleLeveragedAuxiliaryLiquidity_MapsSortedDeltasToTokens() external {
        MintableToken tokenA = new MintableToken("A", "A");
        MintableToken tokenB = new MintableToken("B", "B");
        MintableToken tokenC = new MintableToken("C", "C");
        (address testUAsset, address testPt, address testPol) =
            _sortedTokenAddresses(address(tokenA), address(tokenB), address(tokenC));
        assertGt(uint160(testPol), uint160(testUAsset), "pol/uAsset caller order reversed");

        MockPOLSplitterForPOLendIntegration testSplitter =
            new MockPOLSplitterForPOLendIntegration(testPt, address(yt), recorder);
        testSplitter.setPolForTest(testPol);
        testSplitter.setPolendForTest(address(polend));
        setPolSplitterForTest(launcherProxy, address(testSplitter));

        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        verse.uAsset = testUAsset;
        verse.pol = testPol;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);

        // Settlement grants the router exact per-pair LP allowances, so each fabricated pair needs a
        // registered LP token; an unregistered pair would resolve to address(0) and revert SafeApproveFailed.
        MockERC20 testPolUAssetLp = new MockERC20("T-POL-UASSET-LP", "T-POL-UASSET-LP", 18);
        MockERC20 testPtUAssetLp = new MockERC20("T-PT-UASSET-LP", "T-PT-UASSET-LP", 18);
        MockERC20 testPtPolLp = new MockERC20("T-PT-POL-LP", "T-PT-POL-LP", 18);
        router.setLpToken(testPol, testUAsset, address(testPolUAssetLp));
        router.setLpToken(testPt, testUAsset, address(testPtUAssetLp));
        router.setLpToken(testPt, testPol, address(testPtPolLp));

        router.setRemoveLiquidityResult(testPol, testUAsset, 30 ether, 15 ether);
        router.setRemoveLiquidityResult(testPt, testUAsset, 12 ether, 6 ether);
        router.setRemoveLiquidityResult(testPt, testPol, 20 ether, 10 ether);

        vm.prank(address(polend));
        (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount) =
            launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        assertEq(polAmount, 40 ether, "pol amount");
        assertEq(ptAmount, 32 ether, "pt amount");
        assertEq(uAssetAmount, 21 ether, "uAsset amount");
    }

    function testSettleLeveragedAuxiliaryLiquidity_AllowsPOLendWhilePaused() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);
        router.setRemoveLiquidityResult(address(pol), address(uAsset), 30 ether, 15 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 12 ether, 6 ether);
        router.setRemoveLiquidityResult(address(pt), address(pol), 20 ether, 10 ether);
        MemeverseLauncherUpgradeable(launcherProxy).pause();

        vm.prank(address(polend));
        (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount) =
            launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        assertEq(polAmount, 40 ether, "pol amount");
        assertEq(ptAmount, 32 ether, "pt amount");
        assertEq(uAssetAmount, 21 ether, "uAsset amount");
    }

    function testSettleLeveragedAuxiliaryLiquidity_DecrementsStorageBeforeExternalRemovals() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);
        router.setRemoveLiquidityResult(address(pol), address(uAsset), 30 ether, 15 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 12 ether, 6 ether);
        router.setRemoveLiquidityResult(address(pt), address(pol), 20 ether, 10 ether);
        router.observeAuxiliaryLiquidity(address(launcher), VERSE_ID);

        vm.prank(address(polend));
        launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        assertEq(router.observedPolUAssetLpByCall(1), 50 ether, "pol/uAsset decremented before first call");
        assertEq(router.observedPtUAssetLpByCall(1), 25 ether, "pt/uAsset decremented before first call");
        assertEq(router.observedPtPolLpByCall(1), 40 ether, "pt/pol decremented before first call");
    }

    function testSettleLeveragedAuxiliaryLiquidity_SkipsZeroLpRemovals() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1);
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 1, 1, 1);
        router.setRejectZeroRemoveLiquidity(true);

        vm.prank(address(polend));
        (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount) =
            launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        assertEq(router.removeLiquidityCallCount(), 0, "zero lp removals skipped");
        assertEq(polAmount, 0, "pol amount");
        assertEq(ptAmount, 0, "pt amount");
        assertEq(uAssetAmount, 0, "uAsset amount");
    }

    function testSettleLeveragedAuxiliaryLiquidity_RevertsForNonPOLendCaller() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);

        vm.prank(address(0xBEEF));
        vm.expectRevert(IMemeverseLauncher.PermissionDenied.selector);
        launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);
    }

    function testRedeemAndDistributeFees_BurnsPolAndRoutesNormalFeesToUsersDaoFeesToTreasury() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds[0] = uint32(block.chainid);
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 1000 ether);
        splitter.setPreviewPTToUAssetResult(1);

        hook.setClaimQuote(address(pol), address(uAsset), 30 ether, 40 ether);
        hook.setClaimQuote(address(pt), address(pol), 50 ether, 20 ether);
        hook.setClaimQuote(address(pt), address(uAsset), 25 ether, 15 ether);

        uint256 initialPolSupply = pol.totalSupply();
        uint256 expectedPolFee =
            (address(pol) < address(uAsset) ? 30 ether : 40 ether) + (address(pt) < address(pol) ? 20 ether : 50 ether);
        launcher.redeemAndDistributeFees(VERSE_ID, address(0xE));

        assertEq(pol.burnedAmount(), expectedPolFee, "pol fees burned");
        (uint256 accUAssetFee, uint256 accPTFee) = MemeverseLauncherUpgradeable(launcherProxy).normalFeeStates(VERSE_ID);
        assertGt(accUAssetFee, 0, "normal fee stored");
        assertGt(accPTFee, 0, "normal pt fee stored");
        assertEq(uAsset.balanceOf(verse.governor), 0, "no direct dao uasset fee");
        assertGt(uAsset.balanceOf(address(dispatcher)), 0, "dao uasset fee dispatched");
        assertEq(dispatcher.composeCallCount(), 1, "governor compose");
        assertEq(pt.balanceOf(verse.governor), 0, "dao raw pt not paid");
        assertGt(polend.preRedeemPTFeeCallCount(), 0, "dao pt fee pre-redeemed");
        assertEq(pol.totalSupply(), initialPolSupply, "net pol supply");
    }

    function testRedeemAndDistributeFees_RealPOLendSplitterRevertsZeroBackingAuxiliaryGovPTFee() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 0);

        (POLendUpgradeable realPolend, POLSplitterUpgradeable realSplitter, address realPT) =
            _deployRealPOLendAndSplitter();
        realPolend.setMaxSettlementDustReserve(address(uAsset), uint128(1 ether));
        vm.prank(address(launcher));
        realPolend.registerLendMarket(VERSE_ID);
        uAsset.mint(address(this), 0.1 ether);
        uAsset.approve(address(realPolend), type(uint256).max);
        realPolend.leveragedGenesis(VERSE_ID, 0.1 ether);
        vm.prank(address(launcher));
        realPolend.finalizeLeveragedGenesis(VERSE_ID);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds[0] = uint32(block.chainid);
        _writeVerseBack(verse);

        pol.mint(address(this), 1);
        pol.approve(address(realSplitter), 1);
        realSplitter.split(VERSE_ID, 1);
        assertTrue(MockERC20(realPT).transfer(address(hook), 1), "pt transfer");
        assertEq(realSplitter.previewPTToUAsset(VERSE_ID, 1), 0, "zero backing");

        _setSemanticClaimQuote(realPT, address(uAsset), 1, 0);

        launcher.redeemAndDistributeFees(VERSE_ID, address(0xE));

        (, uint256 pendingPTFee) = MemeverseLauncherUpgradeable(launcherProxy).pendingAuxiliaryGovFeeStates(VERSE_ID);
        assertEq(pendingPTFee, 1, "pt pending retained");
    }

    function testChangeStage_UnlockedSkipsPolendSettlementWhenDebtIsZero() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp);
        _writeVerseBack(verse);
        vm.warp(block.timestamp + 1);

        // The debt read inside _captureLockedAuxiliaryFees is reused at the executeGlobalSettlement gate
        // (no second identical getTotalLeveragedDebt STATICCALL). Exactly one read per Locked->Unlocked
        // transition, even on the zero-debt branch where executeGlobalSettlement is skipped.
        vm.expectCall(address(polend), abi.encodeCall(IPOLend.getTotalLeveragedDebt, (VERSE_ID)), 1);

        launcher.changeStage(VERSE_ID);

        assertEq(splitter.lastCallIndex(), 1, "splitter settles");
        assertEq(
            uint256(splitter.observedStageAtSettle()),
            uint256(IMemeverseLauncher.Stage.Unlocked),
            "splitter sees Unlocked"
        );
        assertEq(hook.firstProtectionCallIndex(), 2, "protection after splitter");
        assertEq(polend.lastCallIndex(), 0, "polend skipped");
        assertEq(uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
    }

    function testChangeStage_UnlockedCallsSplitterThenPolendWhenDebtExists() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp);
        _writeVerseBack(verse);
        polend.setTotalLeveragedDebt(VERSE_ID, 1 ether);
        vm.warp(block.timestamp + 1);

        // The debt read inside _captureLockedAuxiliaryFees is reused at the executeGlobalSettlement gate
        // (no second identical getTotalLeveragedDebt STATICCALL). Exactly one read per Locked->Unlocked
        // transition, even on the non-zero-debt branch where executeGlobalSettlement runs.
        vm.expectCall(address(polend), abi.encodeCall(IPOLend.getTotalLeveragedDebt, (VERSE_ID)), 1);

        launcher.changeStage(VERSE_ID);

        assertEq(splitter.lastCallIndex(), 1, "splitter first");
        assertEq(polend.lastCallIndex(), 2, "polend second");
        assertEq(hook.firstProtectionCallIndex(), 3, "protection after settlements");
        assertEq(
            uint256(splitter.observedStageAtSettle()),
            uint256(IMemeverseLauncher.Stage.Unlocked),
            "splitter sees Unlocked"
        );
        assertEq(
            uint256(polend.observedStageAtGlobalSettlement()),
            uint256(IMemeverseLauncher.Stage.Unlocked),
            "polend sees Unlocked"
        );
    }

    function testChangeStage_WhenPausedUnlockedCallsSplitterThenPolendWhenDebtExists() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp);
        _writeVerseBack(verse);
        polend.setTotalLeveragedDebt(VERSE_ID, 1 ether);
        vm.warp(block.timestamp + 1);
        MemeverseLauncherUpgradeable(launcherProxy).pause();

        launcher.changeStage(VERSE_ID);

        assertEq(splitter.lastCallIndex(), 1, "splitter first");
        assertEq(polend.lastCallIndex(), 2, "polend second");
        assertEq(hook.firstProtectionCallIndex(), 3, "protection after settlements");
        assertEq(uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
    }

    function testChangeStage_RealPOLendZeroDebtVerseCanUnlock() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp);
        _writeVerseBack(verse);

        POLendUpgradeable realPolend = _deployRealPOLend();
        realPolend.setMaxSettlementDustReserve(address(uAsset), uint128(1e9));
        vm.prank(address(launcher));
        realPolend.registerLendMarket(VERSE_ID);
        setPolendForTest(launcherProxy, address(realPolend));
        vm.warp(block.timestamp + 1);

        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
    }

    function testRedeemAuxiliaryLiquidity_UsesPostSettlementRemainingLp() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        setUserGenesisDataForTest(launcherProxy, VERSE_ID, address(this), 200 ether, false, false);
        polend.setTotalLeveragedDebt(VERSE_ID, 600 ether);

        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);
        router.setRemoveLiquidityResult(address(pol), address(uAsset), 30 ether, 15 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 12 ether, 6 ether);
        router.setRemoveLiquidityResult(address(pt), address(pol), 20 ether, 10 ether);

        vm.prank(address(polend));
        launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        polUAssetLp.mint(address(launcher), 100 ether);
        ptUAssetLp.mint(address(launcher), 50 ether);
        ptPolLp.mint(address(launcher), 80 ether);

        (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) =
            launcher.redeemAuxiliaryLiquidity(VERSE_ID);
        assertEq(polUAssetLpAmount, 12.5 ether, "pol/uAsset lp");
        assertEq(ptUAssetLpAmount, 6.25 ether, "pt/uAsset lp");
        assertEq(ptPolLpAmount, 10 ether, "pt/pol lp");
        assertEq(polUAssetLp.balanceOf(address(this)), 12.5 ether, "caller pol/uAsset lp");
    }

    function testRedeemAuxiliaryLiquidity_DistributesNormalBootstrapResiduals() external {
        _setGenesisVerse(uint128(block.timestamp), false);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        _writeVerseBack(verse);
        setGenesisFundForTest(launcherProxy, VERSE_ID, 1000 ether);
        setUserGenesisDataForTest(launcherProxy, VERSE_ID, address(this), 200 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);
        setBootstrapResidualClaimsForTest(launcherProxy, VERSE_ID, 25 ether, 10 ether, 0, 0);
        polUAssetLp.mint(address(launcher), 100 ether);
        ptUAssetLp.mint(address(launcher), 50 ether);
        ptPolLp.mint(address(launcher), 80 ether);
        pol.mint(address(launcher), 25 ether);
        pt.mint(address(launcher), 10 ether);

        uint256 polBefore = pol.balanceOf(address(this));
        uint256 ptBefore = pt.balanceOf(address(this));

        launcher.redeemAuxiliaryLiquidity(VERSE_ID);

        assertEq(pol.balanceOf(address(this)) - polBefore, 5 ether, "normal residual pol");
        assertEq(pt.balanceOf(address(this)) - ptBefore, 2 ether, "normal residual pt");
    }

    function testPreviewPreorderCapacity_IncreasesAfterLeveragedGenesis() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        POLendUpgradeable realPolend = _deployRealPOLend();
        realPolend.setMaxSettlementDustReserve(address(uAsset), uint128(1e9));
        vm.prank(address(launcher));
        realPolend.registerLendMarket(VERSE_ID);
        setPolendForTest(launcherProxy, address(realPolend));
        setGenesisFundForTest(launcherProxy, VERSE_ID, 100 ether);

        uint256 capacityBefore = launcher.previewPreorderCapacity(VERSE_ID);
        assertEq(capacityBefore, 17.5 ether, "capacity before");

        address caller = address(0xBEE);
        uAsset.mint(caller, 10 ether);
        vm.prank(caller);
        uAsset.approve(address(realPolend), 10 ether);
        vm.prank(caller);
        realPolend.leveragedGenesis(VERSE_ID, 10 ether);
        assertEq(realPolend.getTotalLeveragedDebt(VERSE_ID), 100 ether, "leveraged debt");

        uint256 capacityAfter = launcher.previewPreorderCapacity(VERSE_ID);
        assertEq(capacityAfter, 35 ether, "capacity after");
        assertGt(capacityAfter, capacityBefore, "capacity increased");
    }

    // --- Pure Leveraged Genesis: totalNormalFunds == 0, totalLeveragedDebt > 0 ---

    function testPureLeveragedGenesis_EndToEndLifecycle() external {
        uint256 leveragedDebt = 1000 ether;
        uint256 leveragedInterest = 100 ether;

        // ── Phase 1: Setup pure leveraged verse ──
        _setGenesisVerse(uint128(block.timestamp + 1 days), false);
        polend.setTotalLeveragedInterest(VERSE_ID, leveragedInterest);
        polend.setTotalLeveragedDebt(VERSE_ID, leveragedDebt);
        _seedLauncherAndPolendFunding(0, leveragedDebt);

        // ── Phase 2: Genesis → Locked ──
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "stage locked");

        // 4 pools created, normal YT = 0, all YT to leveraged
        assertEq(router.createPoolAndAddLiquidityCallCount(), 4, "four pools");
        assertEq(MemeverseLauncherUpgradeable(launcherProxy).totalNormalClaimableYT(VERSE_ID), 0, "normal yt zero");
        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        assertGt(market.totalLeveragedYT, 0, "leveraged yt exists");
        assertEq(yt.balanceOf(address(polend)), market.totalLeveragedYT, "yt at polend");
        assertEq(splitter.initializeVerseCallCount(), 1, "splitter initialized");

        // ── Phase 3: Locked → Unlocked ──
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp);
        _writeVerseBack(verse);
        vm.warp(block.timestamp + 1);

        launcher.changeStage(VERSE_ID);

        assertEq(uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
        assertEq(splitter.lastCallIndex(), 1, "splitter settled");
        assertEq(polend.lastCallIndex(), 2, "polend settled");

        // ── Phase 4: Normal-side claims revert ──
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalYT(VERSE_ID);

        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalFees(VERSE_ID);

        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.redeemAuxiliaryLiquidity(VERSE_ID);

        // ── Phase 5: settleLeveragedAuxiliaryLiquidity → 100% to leveraged ──
        setAuxiliaryLiquiditiesForTest(launcherProxy, VERSE_ID, 100 ether, 50 ether, 80 ether);
        router.setRemoveLiquidityResult(address(pol), address(uAsset), 30 ether, 15 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 12 ether, 6 ether);
        router.setRemoveLiquidityResult(address(pt), address(pol), 20 ether, 10 ether);

        vm.prank(address(polend));
        (uint256 polAmt, uint256 ptAmt, uint256 uAssetAmt) = launcher.settleLeveragedAuxiliaryLiquidity(VERSE_ID);

        assertEq(polAmt, 40 ether, "pol 100pct");
        assertEq(ptAmt, 32 ether, "pt 100pct");
        assertEq(uAssetAmt, 21 ether, "uAsset 100pct");

        // Remaining auxiliary LP should be 0 after full leveraged settlement
        (uint256 remPolUAsset, uint256 remPtUAsset, uint256 remPtPol) =
            MemeverseLauncherUpgradeable(launcherProxy).auxiliaryLiquidities(VERSE_ID);
        assertEq(remPolUAsset, 0, "remaining pol/uAsset");
        assertEq(remPtUAsset, 0, "remaining pt/uAsset");
        assertEq(remPtPol, 0, "remaining pt/pol");
    }
}
