// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLendUpgradeable} from "../../src/polend/POLendUpgradeable.sol";
import {POLSplitterUpgradeable} from "../../src/polend/POLSplitterUpgradeable.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {
    MockMemecoinForPOLendIntegration,
    MockPolForPOLendIntegration,
    MockProxyDeployerForPOLendIntegration,
    MockYieldDispatcherForPOLendIntegration
} from "../mocks/verse/LauncherPOLendIntegrationMocks.sol";
import {
    HookForPOLendSettlementInvariant,
    LPTokenForPOLendSettlementInvariant,
    RouterForPOLendSettlementInvariant,
    UniversalAssetForPOLendSettlementInvariant
} from "../mocks/verse/LauncherSettlementMocks.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";

contract MemeverseLauncherPOLendSettlementInvariantTest is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;
    uint256 internal constant NORMAL_FUNDS = 10 ether;
    uint256 internal constant LEVERAGED_INTEREST = 1 ether;
    uint256 internal constant LEVERAGED_DEBT = 10 ether;
    uint256 internal constant MAIN_LIQUIDITY = 70 ether;
    uint256 internal constant AUXILIARY_LIQUIDITY = 100 ether;
    uint256 internal constant MAX_SETTLEMENT_DUST = 100;

    address internal constant ALICE = address(0xA11CE);
    address internal constant LEVERAGED_USER = address(0x1E4);
    address internal constant TREASURY = address(0x7E45);

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    UniversalAssetForPOLendSettlementInvariant internal uAsset;
    MockMemecoinForPOLendIntegration internal memecoin;
    MockPolForPOLendIntegration internal pol;
    POLendUpgradeable internal polend;
    POLSplitterUpgradeable internal splitter;
    RouterForPOLendSettlementInvariant internal router;
    HookForPOLendSettlementInvariant internal hook;
    MockYieldDispatcherForPOLendIntegration internal dispatcher;
    LPTokenForPOLendSettlementInvariant internal mainLp;
    LPTokenForPOLendSettlementInvariant internal polUAssetLp;

    function setUp() external {
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
                        address(0x10),
                        address(0x11),
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

        uAsset = new UniversalAssetForPOLendSettlementInvariant();
        memecoin = new MockMemecoinForPOLendIntegration(launcherProxy);
        pol = new MockPolForPOLendIntegration(launcherProxy, address(memecoin));
        hook = new HookForPOLendSettlementInvariant(launcherProxy);
        router = new RouterForPOLendSettlementInvariant(address(hook));
        dispatcher = new MockYieldDispatcherForPOLendIntegration();

        address predictedSplitter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        polend = _deployPOLend(predictedSplitter);
        setPolendForTest(launcherProxy, address(polend));
        splitter = _deploySplitter();

        launcher.setMemeverseUniswapHook(address(hook));
        hook.setPoolInitializer(address(router));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(new MockProxyDeployerForPOLendIntegration()));
        setPolSplitterForTest(launcherProxy, address(splitter));
        launcher.setFundMetaData(address(uAsset), LEVERAGED_INTEREST, 1);

        polend.setMaxSettlementDustReserve(address(uAsset), uint128(MAX_SETTLEMENT_DUST));

        mainLp = new LPTokenForPOLendSettlementInvariant("MEME-UASSET-LP", "MEME-UASSET-LP");
        polUAssetLp = new LPTokenForPOLendSettlementInvariant("POL-UASSET-LP", "POL-UASSET-LP");
        router.setLpToken(address(memecoin), address(uAsset), address(mainLp));
        router.setLpToken(address(pol), address(uAsset), address(polUAssetLp));
        router.setCreateLiquidityResult(uint128(MAIN_LIQUIDITY));
        router.setDefaultAddLiquidityResult(uint128(AUXILIARY_LIQUIDITY));
        router.setPairCreateLiquidityResult(address(memecoin), address(uAsset), uint128(MAIN_LIQUIDITY));
        router.setPairOutputPerLp(address(memecoin), address(uAsset), 0, 1 ether);
    }

    function testRealPathMixedFundsCoversSettlementDustAndLeavesNormalAuxiliaryRemainder() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days));
        _registerLendMarket();
        _normalGenesis(NORMAL_FUNDS);
        _leveragedGenesis(LEVERAGED_INTEREST);
        _allowLauncherToSplitPOL();

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "genesis locked");
        assertEq(pol.allowance(address(launcher), address(splitter)), type(uint256).max, "splitter allowance inf");
        (uint256 ptBackingNumerator, uint256 ptBackingDenominator) = splitter.ptBackingRatios(VERSE_ID);
        assertEq(ptBackingNumerator, (NORMAL_FUNDS + LEVERAGED_DEBT) * 7 / 10, "pt backing numerator");
        assertEq(ptBackingDenominator, MAIN_LIQUIDITY, "pt backing denominator");

        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        router.setPairOutputPerLp(address(pol), address(uAsset), 0.04 ether, 0.08 ether);
        router.setPairOutputPerLp(pt, address(uAsset), 0.1 ether - 5, 0.06 ether);
        router.setPairOutputPerLp(pt, address(pol), 0, 0);
        hook.setClaimQuote(address(pol), address(uAsset), 0, 10 ether);

        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "still locked");

        // Auto-refill from interest was removed; manually fund the reserve so the settlement
        // dust deficit (50) is covered. This mirrors the new operational model.
        // MAX_SETTLEMENT_DUST is 100 wei in this test; fund up to the cap (covers the 50 deficit).
        uAsset.mint(address(this), MAX_SETTLEMENT_DUST);
        uAsset.approve(address(polend), MAX_SETTLEMENT_DUST);
        polend.fundSettlementDustReserve(address(uAsset), MAX_SETTLEMENT_DUST);

        (uint128 reserveBeforeSettlement,) = polend.settlementDustStates(address(uAsset));
        uint256 treasuryBeforeSettlement = uAsset.balanceOf(TREASURY);
        uint256 globalDebtBeforeSettlement = polend.getTotalDebtByUAsset(address(uAsset));
        uint256 expectedRecoveredUAsset = LEVERAGED_DEBT - 50;
        uint256 consumedSettlementDust = LEVERAGED_DEBT - expectedRecoveredUAsset;
        assertLe(consumedSettlementDust, reserveBeforeSettlement, "reserve cap");

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(verse.unlockTime + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        {
            (address settlementPt,,,,,, uint256 splitterSettlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
            uint256 settlementPTBacking = splitter.previewPTToUAsset(VERSE_ID, MockERC20(settlementPt).totalSupply());
            assertGe(splitterSettlementUAsset, settlementPTBacking, "settlementUAsset >= PT backing");
        }

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        (uint256 residualUAsset,) = polend.residualStates(VERSE_ID);
        (uint256 accUAssetFee, uint256 accPTFee) = MemeverseLauncherUpgradeable(launcherProxy).normalFeeStates(VERSE_ID);
        (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) = _auxiliaryLiquidities();

        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Settled), "market settled");
        assertEq(globalDebtBeforeSettlement, LEVERAGED_DEBT, "pre settlement global debt");
        assertEq(
            globalDebtBeforeSettlement - LEVERAGED_DEBT,
            polend.getTotalDebtByUAsset(address(uAsset)),
            "global debt conserved"
        );
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
        (uint128 reserveAfterSettlement,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserveAfterSettlement, reserveBeforeSettlement - consumedSettlementDust, "reserve after");
        assertEq(residualUAsset, 0, "dust covered deficit");
        assertEq(uAsset.balanceOf(TREASURY), treasuryBeforeSettlement, "unused reserve not swept");
        assertEq(polUAssetLpAmount, 50 ether, "normal pol/uAsset lp");
        assertEq(ptUAssetLpAmount, 50 ether, "normal pt/uAsset lp");
        assertEq(ptPolLpAmount, 50 ether, "normal pt/pol lp");
        assertEq(accUAssetFee, 5 ether, "locked normal uAsset fees");
        assertEq(accPTFee, 0, "no pt fees captured");
        assertEq(uAsset.repaidAmount(), LEVERAGED_DEBT, "debt repaid");
    }

    function testRealPathPureLeveragedBoundaryConsumesAllAuxiliaryLiquidity() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days));
        _registerLendMarket();
        _leveragedGenesis(LEVERAGED_INTEREST);
        _allowLauncherToSplitPOL();

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "genesis locked");
        assertEq(pol.allowance(address(launcher), address(splitter)), type(uint256).max, "splitter allowance inf");

        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        router.setPairOutputPerLp(address(pol), address(uAsset), 0.02 ether, 0.04 ether);
        router.setPairOutputPerLp(pt, address(uAsset), 0.1 ether, 0.03 ether);
        router.setPairOutputPerLp(pt, address(pol), 0, 0);

        uint256 globalDebtBeforeSettlement = polend.getTotalDebtByUAsset(address(uAsset));
        (uint128 reserveBeforeSettlement,) = polend.settlementDustStates(address(uAsset));
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(verse.unlockTime + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        {
            (address settlementPt,,,,,, uint256 splitterSettlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
            uint256 settlementPTBacking = splitter.previewPTToUAsset(VERSE_ID, MockERC20(settlementPt).totalSupply());
            assertGe(splitterSettlementUAsset, settlementPTBacking, "settlementUAsset >= PT backing");
        }

        IPOLend.LendMarket memory market = polend.getLendMarket(VERSE_ID);
        (uint256 residualUAsset,) = polend.residualStates(VERSE_ID);
        (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) = _auxiliaryLiquidities();

        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Settled), "market settled");
        assertEq(globalDebtBeforeSettlement, LEVERAGED_DEBT, "pre settlement global debt");
        assertEq(
            globalDebtBeforeSettlement - LEVERAGED_DEBT,
            polend.getTotalDebtByUAsset(address(uAsset)),
            "global debt conserved"
        );
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
        (uint128 reserveAfterSettlement,) = polend.settlementDustStates(address(uAsset));
        assertEq(reserveAfterSettlement, reserveBeforeSettlement, "reserve unchanged (no deficit)");
        assertEq(residualUAsset, 0, "exact recovery");
        assertEq(polUAssetLpAmount, 0, "pol/uAsset lp consumed");
        assertEq(ptUAssetLpAmount, 0, "pt/uAsset lp consumed");
        assertEq(ptPolLpAmount, 0, "pt/pol lp consumed");
        assertEq(MemeverseLauncherUpgradeable(launcherProxy).totalNormalClaimableYT(VERSE_ID), 0, "no normal yt");
        assertEq(uAsset.repaidAmount(), LEVERAGED_DEBT, "debt repaid");
    }

    function testLockDerivesAuxiliaryUAssetFromActualMainBackingAndRoutesUnusedBudget() external {
        uint256 totalGenesisFunds = NORMAL_FUNDS + LEVERAGED_DEBT;
        uint256 mainPoolUAssetUsed = 10 ether;
        uint256 mainUAssetFunds = totalGenesisFunds * 7 / 10;
        uint256 memecoinAmount = mainUAssetFunds;
        uint256 polForPolUAsset = MAIN_LIQUIDITY * 2 / 7;
        uint256 polToSplit = MAIN_LIQUIDITY * 3 / 7;
        uint256 ptForPtUAsset = polToSplit / 3;
        uint256 expectedPolUAsset = polForPolUAsset * mainPoolUAssetUsed / MAIN_LIQUIDITY;

        polend.setMaxSettlementDustReserve(address(uAsset), uint128(20 ether));
        router.setPairCreateSpend(address(memecoin), address(uAsset), memecoinAmount, mainPoolUAssetUsed);

        _setGenesisVerse(uint128(block.timestamp + 1 days));
        _registerLendMarket();
        _normalGenesis(NORMAL_FUNDS);
        _leveragedGenesis(LEVERAGED_INTEREST);
        _allowLauncherToSplitPOL();

        uint256 treasuryBefore = uAsset.balanceOf(TREASURY);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "genesis locked");

        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        uint256 expectedPtUAsset = splitter.previewPTToUAsset(VERSE_ID, ptForPtUAsset);
        uint256 expectedUnusedUAsset = totalGenesisFunds - mainPoolUAssetUsed - expectedPolUAsset - expectedPtUAsset;

        (uint256 backingNumerator, uint256 backingDenominator) = splitter.ptBackingRatios(VERSE_ID);
        assertEq(backingNumerator, mainPoolUAssetUsed, "backing numerator");
        assertEq(backingDenominator, MAIN_LIQUIDITY, "backing denominator");
        assertEq(
            router.pulledForPair(address(pol), address(uAsset), address(uAsset)),
            expectedPolUAsset,
            "pol/uAsset backing spend"
        );
        assertEq(
            router.pulledForPair(pt, address(uAsset), address(uAsset)), expectedPtUAsset, "pt/uAsset backing spend"
        );
        (uint128 reserveAfterLock,) = polend.settlementDustStates(address(uAsset));
        // New model: reserve holds bootstrap residual only (auto-refill from interest removed);
        // full LEVERAGED_INTEREST now sweeps to treasury.
        assertEq(reserveAfterLock, expectedUnusedUAsset, "unused bootstrap reserve");
        assertEq(uAsset.balanceOf(TREASURY) - treasuryBefore, LEVERAGED_INTEREST, "interest swept to treasury");
    }

    function testRealPathFundBasedAmountAboveOneCoversSettlementPTBacking() external {
        uint256 fundBasedAmount = 4;
        uint256 mainUAssetFunds = LEVERAGED_DEBT * 7 / 10;
        uint128 mainLiquidity = uint128(mainUAssetFunds * 2);
        uint256 memecoinPerMainLp = mainUAssetFunds * fundBasedAmount * 1 ether / mainLiquidity;
        uint256 uAssetPerMainLp = mainUAssetFunds * 1 ether / mainLiquidity;

        launcher.setFundMetaData(address(uAsset), LEVERAGED_INTEREST, fundBasedAmount);
        router.setPairCreateLiquidityResult(address(memecoin), address(uAsset), mainLiquidity);
        router.setPairOutputPerLp(address(memecoin), address(uAsset), memecoinPerMainLp, uAssetPerMainLp);

        _setGenesisVerse(uint128(block.timestamp + 1 days));
        _registerLendMarket();
        _leveragedGenesis(LEVERAGED_INTEREST);
        _allowLauncherToSplitPOL();

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "genesis locked");
        (uint256 ptBackingNumerator, uint256 ptBackingDenominator) = splitter.ptBackingRatios(VERSE_ID);
        assertEq(ptBackingNumerator, mainUAssetFunds, "pt backing numerator");
        assertEq(ptBackingDenominator, mainLiquidity, "pt backing denominator");

        uint256 polForPolUAsset = uint256(mainLiquidity) * 2 / 7;
        uint256 polToSplit = uint256(mainLiquidity) * 3 / 7;
        uint256 ptForPtUAsset = polToSplit / 3;
        uint256 ptForPtPol = polToSplit - ptForPtUAsset;
        uint256 polForPtPol = uint256(mainLiquidity) - polForPolUAsset - polToSplit;
        uint256 auxiliaryFunds = LEVERAGED_DEBT - mainUAssetFunds;
        uint256 polUAssetFunds = auxiliaryFunds * 2 / 3;
        uint256 ptUAssetFunds = auxiliaryFunds - polUAssetFunds;

        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        router.setPairOutputPerLp(
            address(pol),
            address(uAsset),
            polForPolUAsset * 1 ether / AUXILIARY_LIQUIDITY,
            polUAssetFunds * 1 ether / AUXILIARY_LIQUIDITY
        );
        router.setPairOutputPerLp(
            pt,
            address(uAsset),
            ptForPtUAsset * 1 ether / AUXILIARY_LIQUIDITY,
            ptUAssetFunds * 1 ether / AUXILIARY_LIQUIDITY
        );
        router.setPairOutputPerLp(
            pt, address(pol), ptForPtPol * 1 ether / AUXILIARY_LIQUIDITY, polForPtPol * 1 ether / AUXILIARY_LIQUIDITY
        );

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(verse.unlockTime + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        (address settlementPt,,,,,, uint256 splitterSettlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        uint256 settlementPTBacking = splitter.previewPTToUAsset(VERSE_ID, MockERC20(settlementPt).totalSupply());
        assertGe(splitterSettlementUAsset, settlementPTBacking, "settlementUAsset >= PT backing");
    }

    function testRealPathLockedPreRedeemPTFeeSettlementBacking() external {
        _setGenesisVerse(uint128(block.timestamp + 1 days));
        _registerLendMarket();
        _normalGenesis(NORMAL_FUNDS);
        _leveragedGenesis(LEVERAGED_INTEREST);
        _allowLauncherToSplitPOL();

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "genesis locked");
        IMemeverseLauncher.Memeverse memory sameChainVerse = launcher.getMemeverseByVerseId(VERSE_ID);
        sameChainVerse.omnichainIds[0] = uint32(block.chainid);
        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            sameChainVerse.uAsset,
            sameChainVerse.memecoin,
            sameChainVerse.pol,
            sameChainVerse.yieldVault,
            sameChainVerse.governor,
            sameChainVerse.incentivizer,
            sameChainVerse.endTime,
            sameChainVerse.unlockTime,
            sameChainVerse.currentStage,
            sameChainVerse.flashGenesis
        );
        setOmnichainIdsForTest(launcherProxy, VERSE_ID, sameChainVerse.omnichainIds);

        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        uint256 polAmount = 10 ether;
        uint256 ptFee = 2 ether;
        uint256 requiredUAsset = splitter.previewPTToUAsset(VERSE_ID, polAmount);
        uint256 requiredMemecoin = 10 ether;

        uAsset.mint(ALICE, requiredUAsset);
        memecoin.mint(ALICE, requiredMemecoin);
        router.setExactLiquidityQuote(address(uAsset), address(memecoin), requiredUAsset, requiredMemecoin);
        router.setPairAddLiquidityResult(address(uAsset), address(memecoin), uint128(polAmount));

        vm.startPrank(ALICE);
        uAsset.approve(address(launcher), requiredUAsset);
        memecoin.approve(address(launcher), requiredMemecoin);
        launcher.mintPOLToken(VERSE_ID, requiredUAsset, requiredMemecoin, 0, 0, polAmount, block.timestamp);
        pol.approve(address(splitter), polAmount);
        splitter.split(VERSE_ID, polAmount);
        // solhint-disable-next-line erc20-unchecked-transfer
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        MockERC20(pt).transfer(address(hook), ptFee);
        vm.stopPrank();

        hook.setClaimQuote(pt, address(uAsset), ptFee, 0);
        launcher.redeemAndDistributeFees(VERSE_ID, address(0xE));
        (uint256 preRedeemedPTAmount, uint256 preRedeemedUAssetBacking) = splitter.preRedeemedStates(VERSE_ID);
        uint256 expectedPreRedeemedPTAmount = ptFee * LEVERAGED_DEBT / (NORMAL_FUNDS + LEVERAGED_DEBT);
        uint256 expectedPreRedeemedUAssetBacking = splitter.previewPTToUAsset(VERSE_ID, expectedPreRedeemedPTAmount);
        assertEq(preRedeemedPTAmount, expectedPreRedeemedPTAmount, "preRedeemed pt");
        assertEq(preRedeemedUAssetBacking, expectedPreRedeemedUAssetBacking, "preRedeemed backing");
        assertEq(MockERC20(pt).balanceOf(address(hook)), 0, "hook pt fee consumed");

        router.setPairOutputPerLp(address(pol), address(uAsset), 0.04 ether, 0.08 ether);
        router.setPairOutputPerLp(pt, address(uAsset), 0.2 ether, 0.06 ether);
        router.setPairOutputPerLp(pt, address(pol), 0, 0);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(verse.unlockTime + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        (address settlementPt,,,,,, uint256 splitterSettlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        uint256 settlementPTBacking = splitter.previewPTToUAsset(VERSE_ID, MockERC20(settlementPt).totalSupply());
        assertGe(splitterSettlementUAsset, settlementPTBacking, "settlementUAsset >= PT backing");
    }

    function _deploySplitter() internal returns (POLSplitterUpgradeable deployedSplitter) {
        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();
        bytes memory data = abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), launcherProxy));
        return POLSplitterUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _deployPOLend(address splitter_) internal returns (POLendUpgradeable deployedPOLend) {
        POLendUpgradeable implementation = new POLendUpgradeable();
        bytes memory data = abi.encodeCall(
            POLendUpgradeable.initialize,
            (address(this), 0.1 ether, 10 ether, TREASURY, launcherProxy, splitter_, address(this))
        );
        return POLendUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _setGenesisVerse(uint128 endTime) internal {
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
            false
        );
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = uint32(block.chainid + 1);
        setOmnichainIdsForTest(launcherProxy, VERSE_ID, chainIds);
    }

    function _registerLendMarket() internal {
        vm.prank(launcherProxy);
        polend.registerLendMarket(VERSE_ID);
    }

    function _normalGenesis(uint256 amount) internal {
        uAsset.mint(ALICE, amount);
        vm.startPrank(ALICE);
        uAsset.approve(launcherProxy, amount);
        launcher.genesis(VERSE_ID, amount, ALICE);
        vm.stopPrank();
    }

    function _leveragedGenesis(uint256 interestAmount) internal {
        uAsset.mint(LEVERAGED_USER, interestAmount);
        vm.startPrank(LEVERAGED_USER);
        uAsset.approve(address(polend), interestAmount);
        polend.leveragedGenesis(VERSE_ID, interestAmount);
        vm.stopPrank();
    }

    function _allowLauncherToSplitPOL() internal {
        vm.prank(launcherProxy);
        pol.approve(address(splitter), type(uint256).max);
    }

    function _auxiliaryLiquidities()
        internal
        view
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        return MemeverseLauncherUpgradeable(launcherProxy).auxiliaryLiquidities(VERSE_ID);
    }
}

contract SettlementDustInvariantHandler is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;
    uint256 internal constant OTHER_VERSE_ID = 2;
    uint256 internal constant MAIN_LIQUIDITY = 70 ether;
    uint256 internal constant AUXILIARY_LIQUIDITY = 100 ether;
    uint256 internal constant MAIN_UASSET_RATE = 1 ether;

    address internal constant ALICE = address(0xA11CE);
    address internal constant LEVERAGED_USER = address(0x1E4);
    address internal constant OTHER_LEVERAGED_USER = address(0x2E4);
    address internal constant TREASURY = address(0x7E45);

    bytes32 internal constant GLOBAL_SETTLEMENT_EXECUTED =
        keccak256("GlobalSettlementExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");

    bool public attempted;
    bool public succeeded;
    uint256 public debt;
    uint256 public expectedRecoveredUAsset;
    uint256 public recoveredUAsset;
    uint256 public consumedSettlementDust;
    uint256 public settlementDustReserveAfter;
    uint256 public residualUAsset;
    uint256 public totalLeveragedInterest;
    /// @dev Reserve snapshot taken right after the Genesis->Locked transition. Under the post-auto-refill
    ///      model this is only the bootstrap residual (finalize no longer credits interest to the reserve),
    ///      so the name reflects the snapshot timing, not an interest-funded "auto" credit.
    uint256 public reserveAfterLock;
    uint256 public treasuryInterest;
    uint256 public bootstrapUnusedUAsset;
    uint256 public extraReserve;
    uint256 public reserveBeforeSettlement;
    uint256 public reserveAfterSettlement;
    uint256 public maxReserve;
    uint256 public treasuryDelta;
    uint256 public repaidAmount;
    uint256 public otherMarketDebt;
    uint256 public expectedGlobalDebtAfterSettlement;
    uint256 public globalDebtBeforeSettlement;
    uint256 public globalDebtAfter;
    uint256 public marketStateAfter;
    uint256 public stageAfter;
    uint256 public otherMarketStateAfter;
    uint256 public settlementUAssetAfter;
    uint256 public ptTotalSupplyAfter;
    uint256 public ptBackingAfter;
    uint256 public expectedSettlementUAssetBeforePTRedeem;
    uint256 public expectedRedeemedPTAmount;
    uint256 public expectedRedeemedPTBacking;
    uint256 public expectedOutstandingPTBackingBeforeSettlement;
    uint256 public initialPolUAssetLp;
    uint256 public initialPtUAssetLp;
    uint256 public initialPtPolLp;
    uint256 public remainingPolUAssetLp;
    uint256 public remainingPtUAssetLp;
    uint256 public remainingPtPolLp;
    uint256 public expectedRemainingPolUAssetLp;
    uint256 public expectedRemainingPtUAssetLp;
    uint256 public expectedRemainingPtPolLp;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    UniversalAssetForPOLendSettlementInvariant internal uAsset;
    MockMemecoinForPOLendIntegration internal memecoin;
    MockPolForPOLendIntegration internal pol;
    HookForPOLendSettlementInvariant internal hook;
    RouterForPOLendSettlementInvariant internal router;
    MockYieldDispatcherForPOLendIntegration internal dispatcher;
    POLSplitterUpgradeable internal splitter;
    POLendUpgradeable internal polend;

    constructor() {
        _deployLauncher();
        uAsset = new UniversalAssetForPOLendSettlementInvariant();
        memecoin = new MockMemecoinForPOLendIntegration(launcherProxy);
        pol = new MockPolForPOLendIntegration(launcherProxy, address(memecoin));
        hook = new HookForPOLendSettlementInvariant(launcherProxy);
        router = new RouterForPOLendSettlementInvariant(address(hook));
        dispatcher = new MockYieldDispatcherForPOLendIntegration();
        splitter = _deploySplitter(launcherProxy);
        polend = _deployPOLend(launcherProxy, splitter);

        _wireLauncher(launcherProxy, router, hook, dispatcher, splitter, polend);

        LPTokenForPOLendSettlementInvariant mainLp =
            new LPTokenForPOLendSettlementInvariant("MEME-UASSET-LP", "MEME-UASSET-LP");
        LPTokenForPOLendSettlementInvariant polUAssetLp =
            new LPTokenForPOLendSettlementInvariant("POL-UASSET-LP", "POL-UASSET-LP");
        router.setLpToken(address(memecoin), address(uAsset), address(mainLp));
        router.setLpToken(address(pol), address(uAsset), address(polUAssetLp));
        router.setCreateLiquidityResult(uint128(MAIN_LIQUIDITY));
        router.setDefaultAddLiquidityResult(uint128(AUXILIARY_LIQUIDITY));
        router.setPairCreateLiquidityResult(address(memecoin), address(uAsset), uint128(MAIN_LIQUIDITY));
    }

    function settle(
        uint256 normalFundsSeed,
        uint256 interestSeed,
        uint256 maxDustSeed,
        uint256 extraReserveSeed,
        uint256 polUAssetPolRateSeed,
        uint256 polUAssetUAssetRateSeed,
        uint256 ptUAssetPtRateSeed,
        uint256 ptUAssetUAssetRateSeed,
        uint256 ptPolPtRateSeed,
        uint256 ptPolPolRateSeed,
        uint256 mainMemecoinRateSeed,
        uint256 auxiliaryFeeSeed
    ) external {
        if (attempted) return;
        attempted = true;

        uint256 normalFunds = bound(normalFundsSeed, 0, 50 ether);
        uint256 leveragedInterest = bound(interestSeed, 1, 5 ether);
        maxReserve = bound(maxDustSeed, 1, 2 ether);
        extraReserve = bound(extraReserveSeed, 0, 2 ether);
        uint256 polUAssetPolRate = bound(polUAssetPolRateSeed, 0, 0.2 ether);
        uint256 polUAssetUAssetRate = bound(polUAssetUAssetRateSeed, 0, 0.5 ether);
        uint256 ptUAssetPtRate = bound(ptUAssetPtRateSeed, 0, 0.1 ether);
        uint256 ptUAssetUAssetRate = bound(ptUAssetUAssetRateSeed, 0, 0.5 ether);
        uint256 ptPolPtRate = bound(ptPolPtRateSeed, 0, 0.1 ether);
        uint256 ptPolPolRate = bound(ptPolPolRateSeed, 0, 0.2 ether);
        uint256 mainMemecoinRate = bound(mainMemecoinRateSeed, 0, 2 ether);
        uint256 auxiliaryUAssetFee = bound(auxiliaryFeeSeed, 0, 1 ether);

        launcher.setFundMetaData(address(uAsset), leveragedInterest, 1);
        polend.setMaxSettlementDustReserve(address(uAsset), uint128(maxReserve));

        router.setPairOutputPerLp(address(memecoin), address(uAsset), mainMemecoinRate, MAIN_UASSET_RATE);

        _setGenesisVerse(launcherProxy, uAsset, memecoin, pol, uint128(block.timestamp + 1 days));
        vm.prank(launcherProxy);
        polend.registerLendMarket(VERSE_ID);
        if (normalFunds != 0) _normalGenesis(launcherProxy, uAsset, normalFunds);
        _leveragedGenesis(polend, uAsset, leveragedInterest);
        uint256 otherLeveragedInterest = leveragedInterest + 1;
        _createOtherOutstandingMarket(otherLeveragedInterest);

        vm.prank(address(launcher));
        pol.approve(address(splitter), type(uint256).max);

        uint256 treasuryBeforeLock = uAsset.balanceOf(TREASURY);
        vm.warp(block.timestamp + 1 days + 1);
        launcher.changeStage(VERSE_ID);
        totalLeveragedInterest = polend.getTotalLeveragedInterest(VERSE_ID);
        (uint128 reserveAfterLockSnap,) = polend.settlementDustStates(address(uAsset));
        reserveAfterLock = reserveAfterLockSnap;
        treasuryInterest = uAsset.balanceOf(TREASURY) - treasuryBeforeLock;
        debt = polend.getTotalLeveragedDebt(VERSE_ID);
        (address pt,,,,,,,,,,) = splitter.splitInfos(VERSE_ID);
        uint256 launchUAssetSpend = router.pulledForPair(address(memecoin), address(uAsset), address(uAsset))
            + router.pulledForPair(address(pol), address(uAsset), address(uAsset))
            + router.pulledForPair(pt, address(uAsset), address(uAsset));
        uint256 launchFunds = normalFunds + debt;
        bootstrapUnusedUAsset = launchFunds > launchUAssetSpend ? launchFunds - launchUAssetSpend : 0;

        if (extraReserve != 0) {
            uAsset.mint(address(this), extraReserve);
            uAsset.approve(address(polend), extraReserve);
            polend.fundSettlementDustReserve(address(uAsset), extraReserve);
        }

        router.setPairOutputPerLp(address(pol), address(uAsset), polUAssetPolRate, polUAssetUAssetRate);
        router.setPairOutputPerLp(pt, address(uAsset), ptUAssetPtRate, ptUAssetUAssetRate);
        router.setPairOutputPerLp(pt, address(pol), ptPolPtRate, ptPolPolRate);
        hook.setClaimQuote(address(pol), address(uAsset), 0, auxiliaryUAssetFee);

        uint256 treasuryBefore = uAsset.balanceOf(TREASURY);
        (initialPolUAssetLp, initialPtUAssetLp, initialPtPolLp) = _auxiliaryLiquidities();

        uint256 totalFunds = normalFunds + debt;
        uint256 leveragedPolUAssetLp = initialPolUAssetLp * debt / totalFunds;
        uint256 leveragedPtUAssetLp = initialPtUAssetLp * debt / totalFunds;
        uint256 leveragedPtPolLp = initialPtPolLp * debt / totalFunds;
        expectedRemainingPolUAssetLp = initialPolUAssetLp - leveragedPolUAssetLp;
        expectedRemainingPtUAssetLp = initialPtUAssetLp - leveragedPtUAssetLp;
        expectedRemainingPtPolLp = initialPtPolLp - leveragedPtPolLp;

        uint256 polAmount =
            leveragedPolUAssetLp * polUAssetPolRate / 1 ether + leveragedPtPolLp * ptPolPolRate / 1 ether;
        uint256 ptAmount = leveragedPtUAssetLp * ptUAssetPtRate / 1 ether + leveragedPtPolLp * ptPolPtRate / 1 ether;
        uint256 ptBacking = splitter.previewPTToUAsset(VERSE_ID, ptAmount);
        expectedOutstandingPTBackingBeforeSettlement = splitter.previewPTToUAsset(VERSE_ID, MockERC20(pt).totalSupply());
        expectedSettlementUAssetBeforePTRedeem = expectedOutstandingPTBackingBeforeSettlement + polAmount
            * MAIN_UASSET_RATE / 1 ether + hookUAssetFee(address(pol), address(uAsset));
        expectedRedeemedPTAmount = ptAmount;
        expectedRedeemedPTBacking = ptBacking;
        expectedRecoveredUAsset = leveragedPolUAssetLp * polUAssetUAssetRate / 1 ether + leveragedPtUAssetLp
            * ptUAssetUAssetRate / 1 ether + polAmount * MAIN_UASSET_RATE / 1 ether + ptBacking;

        uint256 treasuryBeforeOtherLock = uAsset.balanceOf(TREASURY);
        vm.prank(address(launcher));
        polend.finalizeLeveragedGenesis(OTHER_VERSE_ID);
        otherMarketDebt = polend.getTotalLeveragedDebt(OTHER_VERSE_ID);
        assertNotEq(otherMarketDebt, debt, "other market debt differs");
        expectedGlobalDebtAfterSettlement = otherMarketDebt;
        globalDebtBeforeSettlement = polend.getTotalDebtByUAsset(address(uAsset));
        treasuryBefore += uAsset.balanceOf(TREASURY) - treasuryBeforeOtherLock;
        (uint128 reserveBefore,) = polend.settlementDustStates(address(uAsset));
        reserveBeforeSettlement = reserveBefore;

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(verse.unlockTime + 1);
        vm.recordLogs();
        try launcher.changeStage(VERSE_ID) returns (IMemeverseLauncher.Stage) {
            succeeded = true;
            _captureSettlementEvent();
        } catch {
            succeeded = false;
        }

        stageAfter = uint256(launcher.getStageByVerseId(VERSE_ID));
        marketStateAfter = uint256(polend.getLendMarket(VERSE_ID).state);
        otherMarketStateAfter = uint256(polend.getLendMarket(OTHER_VERSE_ID).state);
        globalDebtAfter = polend.getTotalDebtByUAsset(address(uAsset));
        (uint128 reserveAfter,) = polend.settlementDustStates(address(uAsset));
        reserveAfterSettlement = reserveAfter;
        treasuryDelta = uAsset.balanceOf(TREASURY) - treasuryBefore;
        repaidAmount = uAsset.repaidAmount();
        (residualUAsset,) = polend.residualStates(VERSE_ID);
        (address ptAfter,,,,,, uint256 splitterSettlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        settlementUAssetAfter = splitterSettlementUAsset;
        ptTotalSupplyAfter = MockERC20(ptAfter).totalSupply();
        ptBackingAfter = splitter.previewPTToUAsset(VERSE_ID, ptTotalSupplyAfter);
        (remainingPolUAssetLp, remainingPtUAssetLp, remainingPtPolLp) = _auxiliaryLiquidities();
    }

    function _auxiliaryLiquidities()
        internal
        view
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        return MemeverseLauncherUpgradeable(launcherProxy).auxiliaryLiquidities(VERSE_ID);
    }

    function expectedDeficit() external view returns (uint256) {
        return debt > expectedRecoveredUAsset ? debt - expectedRecoveredUAsset : 0;
    }

    function expectedRedeemPTExceedsSettlementBacking() external view returns (bool) {
        return expectedRedeemedPTBacking > expectedSettlementUAssetBeforePTRedeem;
    }

    function expectedRedeemPTConvertsToZero() external view returns (bool) {
        return expectedRedeemedPTAmount != 0 && expectedRedeemedPTBacking == 0;
    }

    function hookUAssetFee(address tokenA, address tokenB) internal view returns (uint256 fee) {
        (uint256 fee0, uint256 fee1) = router.previewClaimableFees(tokenA, tokenB, address(launcher));
        fee = tokenA < tokenB ? fee1 : fee0;
    }

    function _captureSettlementEvent() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != GLOBAL_SETTLEMENT_EXECUTED) continue;
            (
                uint256 eventDebt,
                uint256 eventRecovered,
                uint256 eventConsumed,
                uint256 reserveAfterFromEvent,
                uint256 eventResidualUAsset,
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            debt = eventDebt;
            recoveredUAsset = eventRecovered;
            consumedSettlementDust = eventConsumed;
            settlementDustReserveAfter = reserveAfterFromEvent;
            residualUAsset = eventResidualUAsset;
        }
    }

    function _deployLauncher() internal {
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
                        address(0x10),
                        address(0x11),
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
    }

    function _deploySplitter(address launcher_) internal returns (POLSplitterUpgradeable) {
        POLSplitterUpgradeable implementation = new POLSplitterUpgradeable();
        bytes memory data = abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), launcher_));
        return POLSplitterUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _deployPOLend(address launcher_, POLSplitterUpgradeable splitter_) internal returns (POLendUpgradeable) {
        POLendUpgradeable implementation = new POLendUpgradeable();
        bytes memory data = abi.encodeCall(
            POLendUpgradeable.initialize,
            (address(this), 0.1 ether, 10 ether, TREASURY, launcher_, address(splitter_), address(this))
        );
        return POLendUpgradeable(address(new ERC1967Proxy(address(implementation), data)));
    }

    function _createOtherOutstandingMarket(uint256 interestAmount) internal {
        _setOtherGenesisVerse(launcherProxy, uAsset, memecoin, pol, uint128(block.timestamp + 1 days));
        polend.setDefaultInterestRate(0.25 ether);
        vm.prank(address(launcher));
        polend.registerLendMarket(OTHER_VERSE_ID);
        polend.setDefaultInterestRate(0.1 ether);

        _leveragedGenesisFor(polend, uAsset, OTHER_VERSE_ID, OTHER_LEVERAGED_USER, interestAmount);
    }

    function _wireLauncher(
        address launcher_,
        RouterForPOLendSettlementInvariant router_,
        HookForPOLendSettlementInvariant hook_,
        MockYieldDispatcherForPOLendIntegration dispatcher_,
        POLSplitterUpgradeable splitter_,
        POLendUpgradeable polend_
    ) internal {
        IMemeverseLauncher(launcher_).setMemeverseUniswapHook(address(hook_));
        hook_.setPoolInitializer(address(router_));
        IMemeverseLauncher(launcher_).setMemeverseSwapRouter(address(router_));
        IMemeverseLauncher(launcher_).setLaunchImpl(address(new MemeverseLaunchImpl()));
        IMemeverseLauncher(launcher_).setSettlementImpl(address(new MemeverseSettlementImpl()));
        IMemeverseLauncher(launcher_).setFeePreviewReader(address(new MemeverseFeePreviewReader(launcher_)));
        IMemeverseLauncher(launcher_).setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        IMemeverseLauncher(launcher_).setYieldDispatcher(address(dispatcher_));
        IMemeverseLauncher(launcher_).setMemeverseProxyDeployer(address(new MockProxyDeployerForPOLendIntegration()));
        setPolSplitterForTest(launcher_, address(splitter_));
        setPolendForTest(launcher_, address(polend_));
    }

    function _setGenesisVerse(
        address launcher_,
        UniversalAssetForPOLendSettlementInvariant uAsset_,
        MockMemecoinForPOLendIntegration memecoin_,
        MockPolForPOLendIntegration pol_,
        uint128 endTime
    ) internal {
        setMemeverseForTest(
            launcher_,
            VERSE_ID,
            address(uAsset_),
            address(memecoin_),
            address(pol_),
            address(0xD00D), // yieldVault
            address(0xCAFE), // governor
            address(0), // incentivizer
            endTime,
            endTime + 7 days,
            IMemeverseLauncher.Stage.Genesis,
            false
        );
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = uint32(block.chainid + 1);
        setOmnichainIdsForTest(launcher_, VERSE_ID, chainIds);
    }

    function _setOtherGenesisVerse(
        address launcher_,
        UniversalAssetForPOLendSettlementInvariant uAsset_,
        MockMemecoinForPOLendIntegration memecoin_,
        MockPolForPOLendIntegration pol_,
        uint128 endTime
    ) internal {
        setMemeverseForTest(
            launcher_,
            OTHER_VERSE_ID,
            address(uAsset_),
            address(memecoin_),
            address(pol_),
            address(0xD0D0), // yieldVault
            address(0xBEEF), // governor
            address(0), // incentivizer
            endTime,
            endTime + 7 days,
            IMemeverseLauncher.Stage.Genesis,
            false
        );
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = uint32(block.chainid + 2);
        setOmnichainIdsForTest(launcher_, OTHER_VERSE_ID, chainIds);
    }

    function _normalGenesis(address launcher_, UniversalAssetForPOLendSettlementInvariant uAsset_, uint256 amount)
        internal
    {
        uAsset_.mint(ALICE, amount);
        vm.startPrank(ALICE);
        uAsset_.approve(launcher_, amount);
        IMemeverseLauncher(launcher_).genesis(VERSE_ID, amount, ALICE);
        vm.stopPrank();
    }

    function _leveragedGenesis(
        POLendUpgradeable polend_,
        UniversalAssetForPOLendSettlementInvariant uAsset_,
        uint256 interestAmount
    ) internal {
        _leveragedGenesisFor(polend_, uAsset_, VERSE_ID, LEVERAGED_USER, interestAmount);
    }

    function _leveragedGenesisFor(
        POLendUpgradeable polend_,
        UniversalAssetForPOLendSettlementInvariant uAsset_,
        uint256 verseId,
        address user,
        uint256 interestAmount
    ) internal {
        uAsset_.mint(user, interestAmount);
        vm.startPrank(user);
        uAsset_.approve(address(polend_), interestAmount);
        polend_.leveragedGenesis(verseId, interestAmount);
        vm.stopPrank();
    }
}

contract MemeverseLauncherPOLendSettlementStdInvariantTest is StdInvariant, Test {
    SettlementDustInvariantHandler internal handler;

    function setUp() external {
        handler = new SettlementDustInvariantHandler();
        targetContract(address(handler));
    }

    function invariant_settlementEitherRevertsOnlyWhenDustBoundsAreExceeded() external view {
        if (!handler.attempted()) return;

        uint256 deficit = handler.expectedDeficit();
        bool exceedsDustBounds = deficit > handler.maxReserve() || deficit > handler.reserveBeforeSettlement();
        bool invalidPTRedemption =
            handler.expectedRedeemPTConvertsToZero() || handler.expectedRedeemPTExceedsSettlementBacking();
        if (handler.succeeded()) {
            assertFalse(exceedsDustBounds || invalidPTRedemption, "successful settlement exceeded bounds");
        } else {
            assertTrue(exceedsDustBounds || invalidPTRedemption, "settlement reverted without exceeding bounds");
        }
    }

    function invariant_successfulSettlementRepaysDebtAndClearsGlobalAccounting() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        assertEq(handler.repaidAmount(), handler.debt(), "repaid debt");
        assertEq(
            handler.globalDebtBeforeSettlement(),
            handler.debt() + handler.otherMarketDebt(),
            "pre settlement global debt"
        );
        assertEq(
            handler.globalDebtBeforeSettlement() - handler.debt(), handler.globalDebtAfter(), "global debt conserved"
        );
        assertEq(handler.globalDebtAfter(), handler.expectedGlobalDebtAfterSettlement(), "other market debt remains");
        assertNotEq(handler.otherMarketDebt(), handler.debt(), "other market debt differs");
        assertEq(handler.marketStateAfter(), uint256(IPOLend.MarketState.Settled), "market settled");
        assertEq(handler.stageAfter(), uint256(IMemeverseLauncher.Stage.Unlocked), "stage unlocked");
        assertEq(handler.otherMarketStateAfter(), uint256(IPOLend.MarketState.Locked), "other market locked");
    }

    function invariant_successfulSettlementUsesOnlyBoundedReserveForDeficit() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        uint256 deficit = handler.expectedDeficit();
        assertEq(handler.recoveredUAsset(), handler.expectedRecoveredUAsset(), "recovered uasset");
        assertEq(handler.consumedSettlementDust(), deficit, "consumed dust");
        assertLe(handler.consumedSettlementDust(), handler.maxReserve(), "max dust cap");
        assertLe(handler.consumedSettlementDust(), handler.reserveBeforeSettlement(), "reserve cap");
    }

    function invariant_successfulSettlementRoutesReserveAndResiduals() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        uint256 expectedResidual =
            handler.expectedRecoveredUAsset() > handler.debt() ? handler.expectedRecoveredUAsset() - handler.debt() : 0;
        uint256 expectedReserveAfter = handler.reserveBeforeSettlement() - handler.consumedSettlementDust();

        assertEq(handler.residualUAsset(), expectedResidual, "residual uasset");
        assertEq(handler.settlementDustReserveAfter(), expectedReserveAfter, "reserve after event");
        assertEq(handler.treasuryDelta(), 0, "unused reserve not swept");
        assertEq(handler.reserveAfterSettlement(), expectedReserveAfter, "reserve after");
    }

    function invariant_successfulSettlementPreservesInterestReserveAccounting() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        uint256 expectedResidual =
            handler.recoveredUAsset() > handler.debt() ? handler.recoveredUAsset() - handler.debt() : 0;

        assertEq(
            handler.reserveAfterLock() + handler.treasuryInterest(),
            handler.totalLeveragedInterest() + handler.bootstrapUnusedUAsset(),
            "lock funding conserved (reserve snapshot + treasury == leveraged interest + bootstrap residual)"
        );
        assertEq(
            handler.consumedSettlementDust() + handler.reserveAfterSettlement(),
            handler.reserveBeforeSettlement(),
            "reserve split"
        );
        assertGe(
            handler.reserveBeforeSettlement(), handler.reserveAfterLock() + handler.extraReserve(), "reserve source"
        );
        assertEq(handler.residualUAsset(), expectedResidual, "residual from recovered");
    }

    function invariant_successfulSplitterSettlementBacksPTSupply() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        assertGe(handler.settlementUAssetAfter(), handler.ptBackingAfter(), "settlementUAsset >= PT backing");
    }

    function invariant_settlementConsumesOnlyLeveragedAuxiliaryShare() external view {
        if (!handler.attempted() || !handler.succeeded()) return;

        assertEq(handler.remainingPolUAssetLp(), handler.expectedRemainingPolUAssetLp(), "pol/uasset remainder");
        assertEq(handler.remainingPtUAssetLp(), handler.expectedRemainingPtUAssetLp(), "pt/uasset remainder");
        assertEq(handler.remainingPtPolLp(), handler.expectedRemainingPtPolLp(), "pt/pol remainder");
    }
}
