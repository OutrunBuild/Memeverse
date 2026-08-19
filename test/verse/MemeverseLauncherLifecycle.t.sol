// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

using OptionsBuilder for bytes;
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseFeePreviewReader} from "../../src/verse/interfaces/IMemeverseFeePreviewReader.sol";
import {IMemeverseOFTEnum} from "../../src/common/types/IMemeverseOFTEnum.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {
    MockPreorderSettlementHookForLauncherTest,
    MockSwapRouter,
    MockSwapRouterWithBrokenPoolKey,
    MockLiquidProof,
    RefundCallbackToken,
    MintPolRefundObserver,
    MockPredictOnlyProxyDeployer,
    MockPOLendForLifecycle,
    RedeemMemecoinLiquidityReenterer,
    ClaimNormalFeesReenterer,
    MockPOLSplitterForLifecycle,
    MockOFTDispatcher,
    MockLzEndpointRegistry,
    MockOFTToken
} from "../mocks/verse/LauncherLifecycleMocks.sol";

contract MemeverseLauncherLifecycleTest is Test, MemeverseLauncherTestHelper {
    using PoolIdLibrary for PoolKey;

    event RefundPreorder(uint256 indexed verseId, address indexed receiver, uint256 refundAmount);
    event ClaimNormalFees(uint256 indexed verseId, address indexed receiver, uint256 uAssetAmount, uint256 ptAmount);

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    IMemeverseFeePreviewReader internal feePreviewReader;
    MockSwapRouter internal router;
    MockOFTDispatcher internal dispatcher;
    MockPredictOnlyProxyDeployer internal proxyDeployer;
    MockPOLendForLifecycle internal polend;
    MockPOLSplitterForLifecycle internal splitter;
    MockLzEndpointRegistry internal registry;
    MockERC20 internal uAsset;
    MockERC20 internal memecoin;
    MockLiquidProof internal liquidProof;
    MockERC20 internal pt;
    MockERC20 internal yt;
    MockERC20 internal polUAssetLp;
    MockERC20 internal ptUAssetLp;
    MockERC20 internal ptPolLp;

    address internal constant REWARD_RECEIVER = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);

    function _readPublicSwapResumeTime(PoolKey memory key) internal view returns (bool ok, uint40 resumeTime) {
        address hookAddress = address(IMemeverseSwapRouter(address(router)).hook());
        (bool success, bytes memory data) =
            hookAddress.staticcall(abi.encodeWithSignature("publicSwapResumeTime(bytes32)", key.toId()));
        if (!success || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint40)));
    }

    function _assertProtectionWindow(PoolKey memory key, uint40 resumeTime, string memory label) internal view {
        (bool resumeOk, uint40 storedResumeTime) = _readPublicSwapResumeTime(key);
        assertTrue(resumeOk, string.concat(label, " resume getter missing"));
        assertEq(storedResumeTime, resumeTime, string.concat(label, " resumeTime"));
    }

    /// @notice Deploys the launcher test harness and supporting mocks.
    /// @dev Wires the launcher to the mock router and mock dispatcher.
    function setUp() external {
        dispatcher = new MockOFTDispatcher();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        liquidProof = new MockLiquidProof();
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polUAssetLp = new MockERC20("POL-UASSET-LP", "POL-UASSET-LP", 18);
        ptUAssetLp = new MockERC20("PT-UASSET-LP", "PT-UASSET-LP", 18);
        ptPolLp = new MockERC20("PT-POL-LP", "PT-POL-LP", 18);
        proxyDeployer = new MockPredictOnlyProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        polend = new MockPOLendForLifecycle();
        splitter = new MockPOLSplitterForLifecycle(address(pt), address(yt));
        registry = new MockLzEndpointRegistry();
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
                        address(registry),
                        address(polend),
                        address(splitter),
                        25,
                        115_000,
                        135_000,
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = IMemeverseLauncher(launcherProxy);
        router = new MockSwapRouter(address(launcher));

        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        feePreviewReader = new MemeverseFeePreviewReader(address(launcher));
        launcher.setFeePreviewReader(address(feePreviewReader));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        polend.setLendMarket(address(pt), address(yt));
        router.setLpToken(address(liquidProof), address(uAsset), address(polUAssetLp));
        router.setLpToken(address(pt), address(uAsset), address(ptUAssetLp));
        router.setLpToken(address(pt), address(liquidProof), address(ptPolLp));
    }

    /// @notice Seeds the launcher state with a verse locked for staking.
    /// @dev Populates the necessary uAsset/memecoin/liquid-proof pointers for locking tests.
    function _setLockedVerse(uint256 verseId) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
            address(uAsset),
            address(memecoin),
            address(liquidProof),
            address(0xD00D),
            address(0xCAFE),
            address(0),
            0,
            0,
            IMemeverseLauncher.Stage.Locked,
            false
        );
        setOmnichainIdsForTest(launcherProxy, verseId, _array(uint32(block.chainid)));
    }

    /// @notice Transitions a seeded verse from Locked to Unlocked.
    /// @dev Reuses the locked verse fixture and flips the stage flag.
    function _setUnlockedVerse(uint256 verseId) internal {
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        setMemeverseForTest(
            launcherProxy,
            verseId,
            verse.uAsset,
            verse.memecoin,
            verse.pol,
            verse.yieldVault,
            verse.governor,
            verse.incentivizer,
            verse.endTime,
            verse.unlockTime,
            IMemeverseLauncher.Stage.Unlocked,
            verse.flashGenesis
        );
    }

    /// @notice Seeds a verse that is currently in the Genesis stage.
    /// @dev Controls flashGenesis, endTime, and omnichain ids for change-stage tests.
    function _setGenesisVerse(uint256 verseId, bool flashGenesis, uint128 endTime) internal {
        _setGenesisVerseWithAssets(
            verseId, address(uAsset), address(memecoin), address(liquidProof), flashGenesis, endTime
        );
    }

    function _setGenesisVerseWithAssets(
        uint256 verseId,
        address uAssetAddress,
        address memecoinAddress,
        address polAddress,
        bool flashGenesis,
        uint128 endTime
    ) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
            uAssetAddress,
            memecoinAddress,
            polAddress,
            address(0),
            address(0),
            address(0),
            endTime,
            0,
            IMemeverseLauncher.Stage.Genesis,
            flashGenesis
        );
        setOmnichainIdsForTest(launcherProxy, verseId, _array(uint32(block.chainid + 1)));
    }

    /// @notice Approves the launcher to pull mint inputs for a user.
    /// @dev Centralizes the approval pattern used by mintPOLToken scenarios.
    function _approveMintInputs(address user) internal {
        vm.startPrank(user);
        uAsset.approve(address(launcher), type(uint256).max);
        memecoin.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Writes a full Memeverse struct into proxy storage via the helper.
    /// @dev Bridges the struct-based test pattern to the individual-field helper.
    /// @notice Returns the launcher cast to the concrete MemeverseLauncherUpgradeable type.
    /// @dev Used for view functions not on IMemeverseLauncher (e.g. auxiliaryLiquidities, BPS_BASE).
    function _concrete() internal view returns (MemeverseLauncherUpgradeable) {
        return MemeverseLauncherUpgradeable(launcherProxy);
    }

    function _writeMemeverse(uint256 verseId, IMemeverseLauncher.Memeverse memory verse) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
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
        if (verse.omnichainIds.length > 0) {
            setOmnichainIdsForTest(launcherProxy, verseId, verse.omnichainIds);
        }
    }

    function _array(uint32 value) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = value;
    }

    function _setSemanticPreviewQuote(address tokenA, address tokenB, uint256 tokenAFee, uint256 tokenBFee) internal {
        (uint256 fee0, uint256 fee1) = tokenA < tokenB ? (tokenAFee, tokenBFee) : (tokenBFee, tokenAFee);
        router.setPreviewQuote(tokenA, tokenB, address(launcher), fee0, fee1);
    }

    /// @notice Verifies preview fee mapping preserves token ordering for both pools.
    /// @dev Ensures the fee preview rearranges router outputs into semantic memecoin/uAsset names.
    /// @dev Ensures the launcher maps router fee0/fee1 outputs back to semantic token names.
    function testPreviewGenesisMakerFees_MapsFeesCorrectly() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setQuote(address(memecoin), address(uAsset), address(launcher), 11 ether, 22 ether);
        router.setQuote(address(liquidProof), address(uAsset), address(launcher), 33 ether, 44 ether);

        (uint256 uAssetFee, uint256 memecoinFee) = feePreviewReader.previewGenesisMakerFees(verseId);

        assertEq(memecoinFee, 22 ether, "memecoin fee");
        assertEq(uAssetFee, 44 ether, "uAsset fee");
    }

    function testPreviewGenesisMakerFees_IncludesAuxiliaryGovFeesFromPTPools() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);

        _setSemanticPreviewQuote(address(memecoin), address(uAsset), 3 ether, 7 ether);
        _setSemanticPreviewQuote(address(liquidProof), address(uAsset), 5 ether, 14 ether);
        _setSemanticPreviewQuote(address(pt), address(uAsset), 28 ether, 21 ether);
        _setSemanticPreviewQuote(address(pt), address(liquidProof), 14 ether, 35 ether);

        (uint256 uAssetFee, uint256 memecoinFee) = feePreviewReader.previewGenesisMakerFees(verseId);

        assertEq(memecoinFee, 3 ether, "memecoin fee");
        assertEq(uAssetFee, 29 ether, "uAsset fee includes auxiliary gov share");
    }

    function testPreviewGenesisMakerFees_PostUnlockConvertsAuxiliaryGovPTFee() external {
        uint256 verseId = 32;
        _setUnlockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        splitter.setPreviewPTToUAssetResult(2 ether);

        _setSemanticPreviewQuote(address(memecoin), address(uAsset), 3 ether, 7 ether);
        _setSemanticPreviewQuote(address(liquidProof), address(uAsset), 0, 0);
        _setSemanticPreviewQuote(address(pt), address(uAsset), 14 ether, 0);
        _setSemanticPreviewQuote(address(pt), address(liquidProof), 0, 0);

        (uint256 uAssetFee, uint256 memecoinFee) = feePreviewReader.previewGenesisMakerFees(verseId);

        assertEq(memecoinFee, 3 ether, "memecoin fee");
        assertEq(uAssetFee, 9 ether, "uAsset fee includes converted PT backing");
    }

    function testPreviewGenesisMakerFees_PostUnlockIncludesPendingAuxiliaryGovFees() external {
        uint256 verseId = 35;
        _setUnlockedVerse(verseId);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 3 ether, 14 ether);
        splitter.setPreviewPTToUAssetResult(2 ether);

        _setSemanticPreviewQuote(address(memecoin), address(uAsset), 0, 0);
        _setSemanticPreviewQuote(address(liquidProof), address(uAsset), 0, 0);
        _setSemanticPreviewQuote(address(pt), address(uAsset), 0, 0);
        _setSemanticPreviewQuote(address(pt), address(liquidProof), 0, 0);

        (uint256 uAssetFee, uint256 memecoinFee) = feePreviewReader.previewGenesisMakerFees(verseId);

        assertEq(memecoinFee, 0, "memecoin fee");
        assertEq(uAssetFee, 5 ether, "uAsset fee includes pending auxiliary gov fees");
    }

    /// @notice Verifies previewing fees reverts before the locked stage.
    /// @dev Guards the launcher from previewing fees until after the locked-stage entry.
    /// @dev The launcher must not preview LP fees during genesis.
    function testPreviewGenesisMakerFees_RevertsWhenNotLocked() external {
        uint256 verseId = 1;
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(uAsset);
        verse.memecoin = address(memecoin);
        verse.pol = address(liquidProof);
        verse.currentStage = IMemeverseLauncher.Stage.Genesis;
        _writeMemeverse(verseId, verse);

        vm.expectRevert(IMemeverseLauncher.NotReachedLockedStage.selector);
        feePreviewReader.previewGenesisMakerFees(verseId);
    }

    /// @notice Verifies normal YT can be claimed exactly once after the verse is locked.
    /// @dev Covers proportional YT distribution for normal genesis contributors.
    function testClaimNormalYT_SucceedsOnceAtLocked() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setTotalNormalClaimableYTForTest(launcherProxy, verseId, 60 ether);
        yt.mint(address(launcher), 60 ether);

        vm.prank(ALICE);
        uint256 amount = launcher.claimNormalYT(verseId);

        assertEq(amount, 12 ether, "claimed amount");
        assertEq(yt.balanceOf(ALICE), 12 ether, "alice yt");

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalYT(verseId);
    }

    function testClaimNormalYT_AllowsZeroFloorDustClaimOnce() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 1, false, false);
        setTotalNormalClaimableYTForTest(launcherProxy, verseId, 1);
        yt.mint(address(launcher), 1);

        vm.prank(ALICE);
        uint256 amount = launcher.claimNormalYT(verseId);

        assertEq(amount, 0, "claimed amount");
        assertEq(yt.balanceOf(ALICE), 0, "alice yt");

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalYT(verseId);
    }

    /// @notice Test quote distribution lz fee returns zero for local governance chain.
    /// @dev Verifies same-chain verses do not quote any LayerZero fee.
    function testQuoteDistributionLzFee_ReturnsZeroForLocalGovernanceChain() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 0);
    }

    /// @notice Test quote distribution lz fee quotes remote gov and memecoin fees.
    /// @dev Ensures remote verses aggregate the quote fees plus LayerZero bridging costs.
    function testQuoteDistributionLzFee_QuotesRemoteGovAndMemecoinFees() external {
        uint256 verseId = 1;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 9 ether, 4 ether);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 6 ether);
        remoteUAsset.setQuoteFee(0.15 ether);
        remoteMemecoin.setQuoteFee(0.25 ether);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 0.4 ether);
    }

    /// @notice Test quote distribution lz fee quotes only gov fee when memecoin fee is zero.
    /// @dev Confirms remote LZ quoting still works when the memecoin fee is zero.
    function testQuoteDistributionLzFee_QuotesOnlyGovFeeWhenMemecoinFeeIsZero() external {
        uint256 verseId = 18;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        if (address(remoteMemecoin) < address(remoteUAsset)) {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 9 ether);
        } else {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 9 ether, 0);
        }
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        remoteUAsset.setQuoteFee(0.15 ether);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 0.15 ether);
    }

    /// @notice Test quote distribution lz fee quotes only memecoin fee when gov fee is zero.
    /// @dev Covers the remote path where the governance fee is absent but the memecoin fee remains.
    function testQuoteDistributionLzFee_QuotesOnlyMemecoinFeeWhenGovFeeIsZero() external {
        uint256 verseId = 19;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        if (address(remoteMemecoin) < address(remoteUAsset)) {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 5 ether, 0);
        } else {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 5 ether);
        }
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        remoteMemecoin.setQuoteFee(0.25 ether);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 0.25 ether);
    }

    /// @notice Verifies remote gov-fee quoting stays overflow-safe for large claimable uAsset fees.
    /// @dev Guards against intermediate multiplication overflow when splitting executor reward from the main uAsset fee.
    function testQuoteDistributionLzFee_UsesFullPrecisionForLargeUAssetFee() external {
        uint256 verseId = 25;
        uint256 rewardRate = 9999;
        uint256 largeFee = type(uint256).max / rewardRate + 1;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);
        launcher.setExecutorRewardRate(rewardRate);

        if (address(remoteMemecoin) < address(remoteUAsset)) {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, largeFee);
        } else {
            router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), largeFee, 0);
        }
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        remoteUAsset.setQuoteAmountAsFee(true);

        uint256 expectedExecutorReward = FullMath.mulDiv(largeFee, rewardRate, 10_000);
        uint256 expectedGovFee = largeFee - expectedExecutorReward;

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, expectedGovFee);
    }

    /// @notice Test quote distribution lz fee quotes remote gov fee when only PT fee is bridged as uAsset.
    /// @dev Ensures remote PT fees still reserve a uAsset OFT send quote after the bridge-redemption rewrite.
    function testQuoteDistributionLzFee_QuotesRemoteGovFeeWhenOnlyPTFeeExists() external {
        uint256 verseId = 20;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        polend.setPreRedeemPTFeeBacking(2 ether);
        registry.setEndpoint(202, 302);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        if (address(pt) < address(remoteUAsset)) {
            router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 14 ether, 0);
        } else {
            router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 0, 14 ether);
        }
        router.setPreviewQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteFee(0.15 ether);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 0.15 ether);
    }

    /// @notice Verifies remote quote still charges for pending gov fees captured at unlock.
    /// @dev Historical auxiliary fees claimed during `Locked -> Unlocked` must still reserve a uAsset send.
    function testQuoteDistributionLzFee_QuotesPendingAuxiliaryGovFeesAfterUnlock() external {
        uint256 verseId = 29;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.unlockTime = uint128(block.timestamp - 1);
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        polend.setPreRedeemPTFeeBacking(2 ether);
        registry.setEndpoint(202, 302);

        router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        if (address(liquidProof) < address(remoteUAsset)) {
            router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 6 ether);
        } else {
            router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 6 ether, 0);
        }
        router.setClaimQuote(address(pt), address(remoteUAsset), address(launcher), 0, 0);
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteFee(0.15 ether);

        launcher.changeStage(verseId);
        (uint256 pendingUAssetFee, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertGt(pendingUAssetFee + pendingPTFee, 0, "pending auxiliary gov fee captured");

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);
        assertEq(fee, 0.15 ether, "pending auxiliary fee still quoted");
    }

    function testQuoteDistributionLzFee_PostUnlockUsesConvertedPendingPTFee() external {
        uint256 verseId = 33;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 0, 14 ether);
        splitter.setPreviewPTToUAssetResult(2 ether);
        registry.setEndpoint(202, 302);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteAmountAsFee(true);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 2 ether, "quoted converted pending backing");
    }

    function testQuoteDistributionLzFee_PostUnlockUsesConvertedCurrentPTFee() external {
        uint256 verseId = 34;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        splitter.setPreviewPTToUAssetResult(2 ether);
        registry.setEndpoint(202, 302);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        if (address(pt) < address(remoteUAsset)) {
            router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 14 ether, 0);
        } else {
            router.setPreviewQuote(address(pt), address(remoteUAsset), address(launcher), 0, 14 ether);
        }
        router.setPreviewQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteAmountAsFee(true);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 2 ether, "quoted converted current backing");
    }

    function testQuoteDistributionLzFee_MergesPendingAndCurrentPTBeforeConversion() external {
        uint256 verseId = 36;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Unlocked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 0, 1);
        splitter.setPreviewPTToUAssetRatio(1, 2);
        registry.setEndpoint(202, 302);

        router.setPreviewQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setPreviewQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        _setSemanticPreviewQuote(address(pt), address(remoteUAsset), 1, 0);
        router.setPreviewQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteAmountAsFee(true);

        uint256 fee = feePreviewReader.quoteDistributionLzFee(verseId);

        assertEq(fee, 1, "quoted merged converted backing");
    }

    /// @notice Verifies fee redemption reverts before the locked stage.
    /// @dev Guarantees redeemAndDistributeFees cannot run until the locked stage is reached.
    /// @dev The launcher must not claim or distribute fees during genesis.
    function testRedeemAndDistributeFees_RevertsWhenNotLocked() external {
        uint256 verseId = 1;
        _setGenesisVerse(verseId, false, uint128(block.timestamp + 1 days));

        vm.expectRevert(IMemeverseLauncher.NotReachedLockedStage.selector);
        launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);
    }

    /// @notice Verifies expired Genesis moves to Refund when minimum funding was never met.
    /// @dev Captures the stage-transition behavior that reroutes undersubscribed Genesis to Refund.
    function testChangeStage_WhenGenesisEndedWithoutMinimumFund_MovesToRefund() external {
        uint256 verseId = 7;
        uint128 endTime = uint128(block.timestamp + 1);
        _setGenesisVerse(verseId, false, endTime);
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 4 ether);
        vm.warp(endTime + 1);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Refund), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Refund), "stored stage");
    }

    function testChangeStage_WhenPausedGenesisEndedWithoutMinimumFund_MovesToRefund() external {
        uint256 verseId = 31;
        uint128 endTime = uint128(block.timestamp + 1);
        _setGenesisVerse(verseId, false, endTime);
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 4 ether);
        vm.warp(endTime + 1);
        _concrete().pause();

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Refund), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Refund), "stored stage");
    }

    /// @notice Verifies flashGenesis can lock early once the minimum funding target is met.
    /// @dev Confirms the flash Genesis branch bypasses endTime when the funding target is satisfied.
    function testChangeStage_WhenFlashGenesisAndMinimumFundMet_MovesToLocked() external {
        uint256 verseId = 8;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Locked), "stored stage");
    }

    function testChangeStage_WhenGenesisDeploymentReentersGenesisOrPreorder_SeesLockedStage() external {
        uint256 verseId = 30;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);
        splitter.setInitializeVerseReentry(address(launcher), verseId);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        assertTrue(splitter.initializeReentryAttempted(), "reentry attempted");
        assertEq(uint256(splitter.initializeObservedStage()), uint256(IMemeverseLauncher.Stage.Locked), "reentry stage");
        assertFalse(splitter.initializeGenesisSucceeded(), "genesis reentry");
        assertFalse(splitter.initializePreorderSucceeded(), "preorder reentry");
    }

    function testExecutePreorderSettlement_SplitsBootstrapResidualPOLAndPTByFundingShare() external {
        uint256 verseId = 33;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedInterest(verseId, 10 ether);
        polend.setTotalLeveragedDebt(verseId, 100 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 140 ether, 560 ether, 140 ether);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 40 ether, 35 ether, 35 ether);
        router.setAddLiquidityResult(address(pt), address(uAsset), 20 ether, 10 ether, 10 ether);
        router.setAddLiquidityResult(address(pt), address(liquidProof), 40 ether, 35 ether, 35 ether);

        launcher.changeStage(verseId);

        (
            uint256 normalResidualPOL,
            uint256 normalResidualPT,
            uint256 leveragedResidualPOL,
            uint256 leveragedResidualPT
        ) = _concrete().bootstrapResidualClaims(verseId);
        assertEq(normalResidualPOL, 5 ether, "normal pol residual");
        assertEq(leveragedResidualPOL, 5 ether, "leveraged pol residual");
        assertEq(normalResidualPT, 15 ether / 2, "normal pt residual");
        assertEq(leveragedResidualPT, 15 ether / 2, "leveraged pt residual");

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp);
        _writeMemeverse(verseId, verse);
        router.setRemoveLiquidityResult(address(liquidProof), address(uAsset), 1 ether, 2 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 3 ether, 4 ether);
        router.setRemoveLiquidityResult(address(pt), address(liquidProof), 5 ether, 6 ether);
        polend.setSettleAuxiliaryOnGlobalSettlement(address(launcher), true);
        uint256 polendPOLBefore = liquidProof.balanceOf(address(polend));
        uint256 polendPTBefore = pt.balanceOf(address(polend));

        vm.warp(block.timestamp + 1);
        assertEq(uint256(launcher.changeStage(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        assertEq(liquidProof.balanceOf(address(polend)) - polendPOLBefore, 12 ether, "settled pol plus residual");
        assertEq(
            pt.balanceOf(address(polend)) - polendPTBefore, 4 ether + 6 ether + 15 ether / 2, "settled pt plus residual"
        );
        (,, leveragedResidualPOL, leveragedResidualPT) = _concrete().bootstrapResidualClaims(verseId);
        assertEq(leveragedResidualPOL, 0, "leveraged pol cleared");
        assertEq(leveragedResidualPT, 0, "leveraged pt cleared");
    }

    function testExecutePreorderSettlement_FundsUnusedBootstrapUAssetAfterAcceptedBootstrapDust() external {
        uint256 verseId = 34;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 140 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 40 ether, 20 ether, 10 ether);
        router.setAddLiquidityResult(address(pt), address(uAsset), 20 ether, 10 ether, 5 ether);
        router.setAddLiquidityResult(address(pt), address(liquidProof), 40 ether, 40 ether, 40 ether);

        // Lock the BootstrapUnusedAssetsHandled emit on the real sibling delegatecall path — until now this
        // emit was only asserted via the forceDeployLiquidity replica (a manual copy), so a param-order bug in
        // the sibling would have gone undetected. Mock polend settlementDustStates==(0,0) => capacity 0 =>
        // credited 0, treasuryExcess = full 21 ether unused; main-pool mock consumes the entire memecoin
        // budget (both amounts 0 => fallback to desired) => burnedMemecoin 0.
        vm.expectEmit(true, true, true, true, address(launcher));
        emit IMemeverseLauncher.BootstrapUnusedAssetsHandled(
            verseId, address(uAsset), address(memecoin), 21 ether, 0, 21 ether, 0
        );
        launcher.changeStage(verseId);

        assertEq(polend.lastFundSettlementDustReserveUAsset(), address(uAsset), "reserve uAsset");
        assertEq(polend.lastFundSettlementDustReserveAmount(), 21 ether, "unused uAsset");
    }

    function testPureLeveragedGenesis_LaunchesAndAllocatesAuxiliaryLiquidityToLeveragedSide() external {
        uint256 verseId = 32;
        uint128 endTime = uint128(block.timestamp + 1 days);
        _setGenesisVerse(verseId, false, endTime);
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setTotalLeveragedInterest(verseId, 10 ether);
        polend.setTotalLeveragedDebt(verseId, 100 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 140 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 60 ether, 0, 0);
        router.setAddLiquidityResult(address(pt), address(uAsset), 30 ether, 0, 0);
        router.setAddLiquidityResult(address(pt), address(liquidProof), 90 ether, 0, 0);

        vm.warp(endTime + 1);
        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Locked), "stored stage");
        assertEq(launcher.totalNormalFunds(verseId), 0, "normal funds");
        assertEq(_concrete().totalNormalClaimableYT(verseId), 0, "normal yt");
        IPOLend.LendMarket memory market = polend.getLendMarket(verseId);
        assertGt(market.totalLeveragedYT, 0, "leveraged yt");

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp);
        _writeMemeverse(verseId, verse);
        router.setRemoveLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 15 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 12 ether, 6 ether);
        router.setRemoveLiquidityResult(address(pt), address(liquidProof), 20 ether, 10 ether);
        polend.setSettleAuxiliaryOnGlobalSettlement(address(launcher), true);
        uint256 polendPolBefore = liquidProof.balanceOf(address(polend));
        uint256 polendPtBefore = pt.balanceOf(address(polend));
        uint256 polendUAssetBefore = uAsset.balanceOf(address(polend));

        vm.warp(block.timestamp + 1);
        assertEq(uint256(launcher.changeStage(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        (uint256 remainingPolUAssetLp, uint256 remainingPtUAssetLp, uint256 remainingPtPolLp) =
            _concrete().auxiliaryLiquidities(verseId);
        assertEq(remainingPolUAssetLp, 0, "remaining pol/uAsset");
        assertEq(remainingPtUAssetLp, 0, "remaining pt/uAsset");
        assertEq(remainingPtPolLp, 0, "remaining pt/pol");
        assertEq(
            uint256(router.lastRemoveLiquidityAmount(address(liquidProof), address(uAsset))),
            60 ether,
            "removed pol/uAsset"
        );
        assertEq(uint256(router.lastRemoveLiquidityAmount(address(pt), address(uAsset))), 30 ether, "removed pt/uAsset");
        assertEq(
            uint256(router.lastRemoveLiquidityAmount(address(pt), address(liquidProof))), 90 ether, "removed pt/pol"
        );
        assertEq(liquidProof.balanceOf(address(polend)) - polendPolBefore, 35 ether, "polend pol");
        assertEq(pt.balanceOf(address(polend)) - polendPtBefore, 16 ether, "polend pt");
        assertEq(uAsset.balanceOf(address(polend)) - polendUAssetBefore, 42 ether, "polend uAsset");

        assertEq(launcher.totalNormalFunds(verseId), 0, "normal funds before redeem");
        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.redeemAuxiliaryLiquidity(verseId);
    }

    function testPureLeveragedGenesis_WhenOnlyDebtMeetsMinimum_MovesToRefund() external {
        uint256 verseId = 33;
        uint128 endTime = uint128(block.timestamp + 1 days);
        _setGenesisVerse(verseId, false, endTime);
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setTotalLeveragedInterest(verseId, 9 ether);
        polend.setTotalLeveragedDebt(verseId, 100 ether);

        vm.warp(endTime + 1);
        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Refund), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Refund), "stored stage");
        assertEq(launcher.totalNormalFunds(verseId), 0, "normal funds");
        assertEq(_concrete().totalNormalClaimableYT(verseId), 0, "normal yt");
        IPOLend.LendMarket memory market = polend.getLendMarket(verseId);
        assertEq(market.totalLeveragedYT, 0, "leveraged yt");
    }

    /// @notice Verifies Locked entry protects the four launcher-managed pools until actual unlock.
    function testChangeStage_WhenGenesisMovesToLocked_DoesNotSetProtectionWindow() external {
        uint256 verseId = 28;
        uint40 unlockTime = uint40(block.timestamp + 3 days);
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = unlockTime;
        _writeMemeverse(verseId, verse);

        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);

        PoolKey memory memecoinKey = router.getHookPoolKey(address(memecoin), address(uAsset));
        PoolKey memory polKey = router.getHookPoolKey(address(liquidProof), address(uAsset));

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        _assertProtectionWindow(memecoinKey, 0, "memecoin/uAsset");
        _assertProtectionWindow(polKey, 0, "POL/uAsset");
    }

    function testChangeStage_WhenPreorderSettlementConfigDrifts_RevertsBeforeCreatingPool() external {
        uint256 verseId = 34;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);

        MockPreorderSettlementHookForLauncherTest settlementHook =
            MockPreorderSettlementHookForLauncherTest(address(router.hook()));
        settlementHook.setPoolInitializer(address(0xBAD));

        vm.expectRevert(IMemeverseLauncher.InvalidPreorderSettlementConfig.selector);
        launcher.changeStage(verseId);

        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Genesis), "stage");
        assertEq(router.createPoolAndAddLiquidityCallCount(), 0, "pool create calls");
    }

    /// @notice Verifies successful Genesis settlement executes the launch preorder swap and unlocks preorder memecoin linearly.
    /// @dev Covers the new launcher-managed preorder settlement path and linear unlock math.
    function testChangeStage_WhenGenesisSucceedsWithPreorder_SettlesAndUnlocksLinearly() external {
        uint256 verseId = 22;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);
        router.setLaunchSwapResult(address(uAsset), address(memecoin), 10 ether, 60 ether);

        uAsset.mint(address(this), 10 ether);
        uAsset.approve(address(launcher), type(uint256).max);
        launcher.preorder(verseId, 10 ether, ALICE);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");

        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(verseId), 0, "initial claimable");

        vm.warp(block.timestamp + 3 days + 12 hours);
        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(verseId), 30 ether, "half unlocked");

        vm.warp(block.timestamp + 3 days + 12 hours + 1);
        vm.prank(ALICE);
        uint256 claimedAmount = launcher.claimUnlockedPreorderMemecoin(verseId);
        assertEq(claimedAmount, 60 ether, "claimed amount");
        assertEq(memecoin.balanceOf(ALICE), 60 ether, "alice memecoin");
    }

    function testChangeStage_PreorderSettlement_UsesCorrectSqrtPriceBoundary() external {
        uint256 verseId = 23;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);
        router.setLaunchSwapResult(address(uAsset), address(memecoin), 10 ether, 60 ether);

        bool zeroForOne = address(uAsset) < address(memecoin);
        uint160 expectedLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        MockPreorderSettlementHookForLauncherTest settlementHook =
            MockPreorderSettlementHookForLauncherTest(address(router.hook()));
        settlementHook.setExpectedLaunchSqrtPriceLimit(zeroForOne, expectedLimit);

        uAsset.mint(address(this), 10 ether);
        uAsset.approve(address(launcher), type(uint256).max);
        launcher.preorder(verseId, 10 ether, ALICE);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        assertEq(settlementHook.lastSettlementZeroForOne(), zeroForOne, "zeroForOne");
        assertEq(settlementHook.lastSettlementSqrtPriceLimitX96(), expectedLimit, "sqrt price limit");
        assertEq(settlementHook.settlementCallCount(), 1, "settlement calls");
    }

    function testChangeStage_WhenPreorderSettlementReverts_RevertsAtomically() external {
        uint256 verseId = 25;
        _setGenesisVerse(verseId, true, uint128(block.timestamp + 1 days));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);

        MockPreorderSettlementHookForLauncherTest settlementHook =
            MockPreorderSettlementHookForLauncherTest(address(router.hook()));
        settlementHook.setPreorderSettlementRevert("mock preorder settlement revert");

        uAsset.mint(address(this), 10 ether);
        uAsset.approve(address(launcher), type(uint256).max);
        launcher.preorder(verseId, 10 ether, ALICE);

        (uint256 totalFundsBefore, uint256 settledMemecoinBefore, uint40 settlementTimestampBefore) =
            getPreorderStateForTest(launcherProxy, verseId);
        assertEq(totalFundsBefore, 10 ether, "preorder total funds before");
        assertEq(settledMemecoinBefore, 0, "settled memecoin before");
        assertEq(settlementTimestampBefore, 0, "settlement timestamp before");

        vm.expectRevert(bytes("mock preorder settlement revert"));
        launcher.changeStage(verseId);

        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Genesis), "stage");

        (uint256 totalFundsAfter, uint256 settledMemecoinAfter, uint40 settlementTimestampAfter) =
            getPreorderStateForTest(launcherProxy, verseId);
        assertEq(totalFundsAfter, 10 ether, "preorder total funds after");
        assertEq(settledMemecoinAfter, 0, "settled memecoin after");
        assertEq(settlementTimestampAfter, 0, "settlement timestamp after");
    }

    /// @notice Verifies non-flash Genesis cannot lock early even if the minimum funding target is met.
    /// @dev Preserves the requirement that non-flash launches wait for endTime expiry before locking.
    function testChangeStage_WhenNotFlashGenesisBeforeEnd_Reverts() external {
        uint256 verseId = 9;
        uint128 endTime = uint128(block.timestamp + 1 days);
        _setGenesisVerse(verseId, false, endTime);
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.StillInGenesisStage.selector, uint256(endTime)));
        launcher.changeStage(verseId);
    }

    /// @notice Test change stage reverts at final stages.
    /// @dev Ensures the launcher rejects stage transitions once a verse reaches a final stage.
    function testChangeStage_RevertsAtFinalStages() external {
        uint256 verseId = 10;
        IMemeverseLauncher.Memeverse memory verse;
        verse.memecoin = address(memecoin);
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _writeMemeverse(verseId, verse);

        vm.expectRevert(IMemeverseLauncher.ReachedFinalStage.selector);
        launcher.changeStage(verseId);
    }

    /// @notice Test change stage locked before unlock time keeps stage locked.
    /// @dev Keeps the locked state until the unlockTime timestamp elapses.
    function testChangeStage_LockedBeforeUnlockTimeKeepsStageLocked() external {
        uint256 verseId = 14;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp + 1 days);
        _writeMemeverse(verseId, verse);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked));
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Locked));
    }

    /// @notice Test change stage locked after unlock time moves to unlocked.
    /// @dev Releases the lock once unlockTime has passed.
    function testChangeStage_LockedAfterUnlockTimeMovesToUnlocked() external {
        uint256 verseId = 20;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Unlocked));
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked));
    }

    function testChangeStage_AllowsAuxiliaryRedeemDuringUnlockSettlement() external {
        uint256 verseId = 29;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, address(splitter), 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);
        splitter.setSettleReentry(address(launcher), verseId);

        launcher.changeStage(verseId);

        assertTrue(splitter.reentryAttempted(), "settlement reentry attempted");
        assertTrue(splitter.reentrySucceeded(), "settlement reentry allowed");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
        assertEq(polUAssetLp.balanceOf(address(splitter)), 12 ether, "settlement redeem succeeds");
    }

    function testChangeStage_AllowsPublicRedeemMemecoinLiquidityDuringUnlockSettlement() external {
        uint256 verseId = 31;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        RedeemMemecoinLiquidityReenterer reenterer = new RedeemMemecoinLiquidityReenterer();
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(address(reenterer), 10 ether);
        splitter.setSettleMemecoinLiquidityReentry(address(reenterer), address(launcher), verseId, 4 ether);

        launcher.changeStage(verseId);

        assertTrue(splitter.reentryAttempted(), "settlement reentry attempted");
        assertTrue(reenterer.reentryAttempted(), "public reentry attempted");
        assertTrue(reenterer.reentrySucceeded(), "public reentry allowed");
        assertEq(liquidProof.balanceOf(address(reenterer)), 6 ether, "reenterer pol burned");
        assertEq(memecoinLp.balanceOf(address(reenterer)), 4 ether, "reenterer lp");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");
    }

    function testPreviewPreorderCapacityAndClaimNormalYT_SingleFieldAboveOldSplitMax() external {
        uint256 verseId = 30;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, type(uint128).max);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, type(uint128).max, false, false);
        setTotalNormalClaimableYTForTest(launcherProxy, verseId, 2 ether);
        yt.mint(address(launcher), 2 ether);

        uint256 expectedCapacity = uint256(type(uint128).max) * 7 * 2_500 / (10 * _concrete().BPS_BASE());

        assertEq(launcher.previewPreorderCapacity(verseId), expectedCapacity, "preview capacity");

        vm.prank(ALICE);
        uint256 amount = launcher.claimNormalYT(verseId);

        assertEq(amount, 2 ether, "claim share");
    }

    /// @notice Verifies entering `Unlocked` snapshots pool resume times onto the hook with the fixed 24 hour window.
    /// @dev The protection window is now a constant product rule rather than a mutable config surface.
    function testChangeStage_LockedAfterUnlockSnapshotsHookResumeTimes() external {
        uint256 verseId = 24;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        PoolKey memory memecoinKey = router.getHookPoolKey(address(memecoin), address(uAsset));
        PoolKey memory polKey = router.getHookPoolKey(address(liquidProof), address(uAsset));
        PoolKey memory ptUAssetKey = router.getHookPoolKey(address(pt), address(uAsset));
        PoolKey memory ptPolKey = router.getHookPoolKey(address(pt), address(liquidProof));

        launcher.changeStage(verseId);

        uint40 resumeTime = uint40(block.timestamp + 24 hours);
        _assertProtectionWindow(memecoinKey, resumeTime, "memecoin/uAsset");
        _assertProtectionWindow(polKey, resumeTime, "POL/uAsset");
        _assertProtectionWindow(ptUAssetKey, resumeTime, "PT/uAsset");
        _assertProtectionWindow(ptPolKey, resumeTime, "PT/POL");
    }

    /// @notice Verifies unlock protection no longer depends on the router's pool-key helper after router rebinding.
    /// @dev Rebinding to a router that shares the same hook but has a broken helper must still protect the live pool.
    function testChangeStage_LockedAfterUnlockDoesNotDependOnRouterPoolKeyHelper() external {
        uint256 verseId = 27;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        PoolKey memory memecoinKey = router.getHookPoolKey(address(memecoin), address(uAsset));
        address sharedHook = address(router.hook());
        MockSwapRouterWithBrokenPoolKey brokenRouter = new MockSwapRouterWithBrokenPoolKey(sharedHook);
        MockPreorderSettlementHookForLauncherTest(sharedHook).setPoolInitializer(address(brokenRouter));
        launcher.setMemeverseSwapRouter(address(brokenRouter));

        launcher.changeStage(verseId);

        (bool memecoinResumeOk, uint40 memecoinResumeTime) = _readPublicSwapResumeTime(memecoinKey);
        assertTrue(memecoinResumeOk, "memecoin resume getter missing");
        assertEq(memecoinResumeTime, uint40(block.timestamp + 24 hours), "memecoin resume time");
    }

    /// @notice Test refund reverts when stage or user state invalid.
    /// @dev Guards refund access when the verse stage or user flags forbid it.
    function testRefund_RevertsWhenStageOrUserStateInvalid() external {
        uint256 verseId = 11;
        _setLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.NotRefundStage.selector);
        launcher.refund(verseId);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _writeMemeverse(verseId, verse);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.refund(verseId);
    }

    function testRefund_WhenPausedTransfersFundsAndMarksRefunded() external {
        uint256 verseId = 32;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _writeMemeverse(verseId, verse);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 5 ether, false, false);
        uAsset.mint(address(launcher), 5 ether);
        _concrete().pause();

        vm.prank(ALICE);
        uint256 refunded = launcher.refund(verseId);

        (, bool isRefunded,) = _concrete().userGenesisData(verseId, ALICE);
        assertEq(refunded, 5 ether, "refunded");
        assertTrue(isRefunded, "isRefunded");
        assertEq(uAsset.balanceOf(ALICE), 5 ether, "alice uAsset");
    }

    /// @notice Test refund preorder reverts when stage or user state invalid.
    /// @dev Ensures preorder refunds only run during the refund stage with valid user state.
    function testRefundPreorder_RevertsWhenStageOrUserStateInvalid() external {
        uint256 verseId = 21;
        _setLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.NotRefundStage.selector);
        launcher.refundPreorder(verseId);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _writeMemeverse(verseId, verse);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.refundPreorder(verseId);
    }

    /// @notice Verifies refund preorder returns funds and marks the user as refunded.
    /// @dev Covers the successful preorder refund path, asserting balances and flags.
    function testRefundPreorder_WhenPausedTransfersFundsAndMarksRefunded() external {
        uint256 verseId = 23;
        _setLockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _writeMemeverse(verseId, verse);
        setUserPreorderDataForTest(launcherProxy, verseId, ALICE, 5 ether, 0, false);
        uAsset.mint(address(launcher), 5 ether);
        _concrete().pause();

        vm.expectEmit(true, true, false, true, address(launcher));
        emit RefundPreorder(verseId, ALICE, 5 ether);

        vm.prank(ALICE);
        uint256 refunded = launcher.refundPreorder(verseId);

        (uint256 funds, uint256 claimedMemecoin, bool isRefunded) = _concrete().userPreorderData(verseId, ALICE);
        assertEq(refunded, 5 ether, "refunded");
        assertEq(funds, 5 ether, "funds");
        assertEq(claimedMemecoin, 0, "claimed");
        assertTrue(isRefunded, "isRefunded");
        assertEq(uAsset.balanceOf(ALICE), 5 ether, "alice uAsset");
    }

    /// @notice Verifies normal YT claims revert when the caller has no genesis share.
    /// @dev Guards the new claim path from minting YT to unrelated accounts.
    function testClaimNormalYT_RevertsWhenUserHasNoShare() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalYT(verseId);
    }

    /// @notice Verifies Locked-stage auxiliary fees remain claimable by normal users after unlock.
    /// @dev `changeStage` must flush historical auxiliary fees into `normalFeeStates` before switching to `Unlocked`.
    function testChangeStage_PreservesLockedAuxiliaryFeesForNormalClaimsAfterUnlock() external {
        uint256 verseId = 28;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        polend.setTotalLeveragedDebt(verseId, 40 ether);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, 0);
        if (address(liquidProof) < address(uAsset)) {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 8 ether);
        } else {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 8 ether, 0);
        }
        if (address(pt) < address(uAsset)) {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 12 ether, 0);
        } else {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 0, 12 ether);
        }
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);

        assertEq(uint256(launcher.changeStage(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        (uint256 accUAssetFee, uint256 accPTFee) = _concrete().normalFeeStates(verseId);
        assertEq(accUAssetFee, 6 ether, "locked normal uAsset fee kept");
        assertEq(accPTFee, 9 ether, "locked normal pt fee kept");

        vm.prank(ALICE);
        (uint256 claimedUAssetFee, uint256 claimedPTFee) = launcher.claimNormalFees(verseId);
        assertEq(claimedUAssetFee, 1.2 ether, "normal user gets unlock-delayed uAsset fee");
        assertEq(claimedPTFee, 1.8 ether, "normal user gets unlock-delayed pt fee");
    }

    /// @notice Verifies that, post-unlock, freshly claimed auxiliary fees do not accrue to `normalFeeStates`.
    /// @dev GR-001 short-circuits `_splitAuxiliaryGovFees`/`_accrueAuxiliaryFeeShares` on `!preserveNormalShare`,
    ///      so the entire auxiliary uAsset fee flows to governance while `accUAssetFee` stays frozen.
    function testRedeemAndDistributeFees_UnlockedStageFreezesNormalAuxiliaryFeeShare() external {
        uint256 verseId = 51;
        _setUnlockedVerse(verseId);
        // normalFunds + leveragedDebt make the normal share non-zero in the Locked branch, so a GR-001 regression
        // (accUAssetFee += totalUAssetFee - govUAssetFee) would otherwise inflate the normal accrual here.
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        // Baseline normal fee accrual so a freeze assertion distinguishes "unchanged" from "zero default".
        setNormalFeeStateForTest(launcherProxy, verseId, 5 ether, 0);

        // Inject only the pol/uAsset auxiliary fee; leave main pool and pt pairs at zero to isolate the
        // auxiliary-only path that exercises GR-001.
        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, 0);
        if (address(liquidProof) < address(uAsset)) {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 8 ether);
        } else {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 8 ether, 0);
        }
        if (address(pt) < address(uAsset)) {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 0, 0);
        } else {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 0, 0);
        }
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);

        (uint256 accUAssetFeeBefore, uint256 accPTFeeBefore) = _concrete().normalFeeStates(verseId);
        assertEq(accUAssetFeeBefore, 5 ether, "baseline normal uAsset fee");

        (uint256 govFee,,,) = launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        // GR-001: auxiliary uAsset fee never accrues to normal-side during Unlocked.
        (uint256 accUAssetFeeAfter, uint256 accPTFeeAfter) = _concrete().normalFeeStates(verseId);
        assertEq(accUAssetFeeAfter, accUAssetFeeBefore, "normal uAsset fee frozen after unlock");
        assertEq(accPTFeeAfter, accPTFeeBefore, "normal pt fee frozen after unlock");

        // GR-001: the entire auxiliary uAsset fee routes to governance via the dispatcher.
        assertEq(govFee, 8 ether, "auxiliary uAsset fee all to gov");
        assertEq(uAsset.balanceOf(address(dispatcher)), 8 ether, "dispatcher uAsset");
        assertEq(dispatcher.composeCallCount(), 1, "compose called");
        assertEq(dispatcher.lastToken(), address(uAsset), "compose token");
    }

    /// @notice Verifies unlock fee capture uses full-precision division rather than overflowing intermediate multiplication.
    function testChangeStage_CapturesLargeAuxiliaryFeesWithoutOverflow() external {
        uint256 verseId = 41;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 1);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 1, false, false);

        uint256 leveragedDebt = uint256(1) << 120;
        uint256 feeAmount = uint256(1) << 70;
        polend.setTotalLeveragedDebt(verseId, leveragedDebt);

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp - 1);
        _writeMemeverse(verseId, verse);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, 0);
        if (address(liquidProof) < address(uAsset)) {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, feeAmount);
        } else {
            router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), feeAmount, 0);
        }
        if (address(pt) < address(uAsset)) {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), feeAmount, 0);
        } else {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 0, feeAmount);
        }
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);

        assertEq(uint256(launcher.changeStage(verseId)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked");

        uint256 totalFunds = leveragedDebt + 1;
        uint256 expectedGovUAssetFee = FullMath.mulDiv(feeAmount, leveragedDebt, totalFunds);
        uint256 expectedGovPTFee = FullMath.mulDiv(feeAmount, leveragedDebt, totalFunds);
        uint256 expectedNormalUAssetFee = feeAmount - expectedGovUAssetFee;
        uint256 expectedNormalPTFee = feeAmount - expectedGovPTFee;

        (uint256 accUAssetFee, uint256 accPTFee) = _concrete().normalFeeStates(verseId);
        assertEq(accUAssetFee, expectedNormalUAssetFee, "normal uAsset fee");
        assertEq(accPTFee, expectedNormalPTFee, "normal pt fee");

        (uint256 pendingUAssetFee, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertEq(pendingUAssetFee, expectedGovUAssetFee, "pending gov uAsset fee");
        assertEq(pendingPTFee, expectedGovPTFee, "pending gov pt fee");
    }

    function testClaimNormalFees_SettledSplitterRedeemsClaimablePTToUAsset() external {
        uint256 verseId = 32;
        _setUnlockedVerse(verseId);
        splitter.setSettled(true);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 20 ether);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 20 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 ptAmount) = launcher.claimNormalFees(verseId);

        assertEq(splitter.redeemPTCallCount(), 1, "redeemPT called");
        assertEq(splitter.lastRedeemPTVerseId(), verseId, "verse id");
        assertEq(splitter.lastRedeemPTAmount(), 4 ether, "pt redeemed");
        assertEq(splitter.lastRedeemPTTo(), ALICE, "redeem receiver");
        assertEq(uAssetAmount, 6 ether, "uAsset includes redeemed PT");
        assertEq(ptAmount, 0, "no PT returned");
        assertEq(uAsset.balanceOf(ALICE), 6 ether, "alice uAsset");
        assertEq(pt.balanceOf(ALICE), 0, "alice pt");
    }

    function testClaimNormalFees_UnsettledSplitterReportsTransferredPT() external {
        uint256 verseId = 46;
        _setUnlockedVerse(verseId);
        splitter.setSettled(false);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 20 ether);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 20 ether);

        vm.expectEmit(true, true, false, true, address(launcher));
        emit ClaimNormalFees(verseId, ALICE, 2 ether, 4 ether);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 ptAmount) = launcher.claimNormalFees(verseId);

        assertEq(uAssetAmount, 2 ether, "uAsset claim");
        assertEq(ptAmount, 4 ether, "returned claimed pt amount");
        assertEq(uAsset.balanceOf(ALICE), 2 ether, "alice uAsset");
        assertEq(pt.balanceOf(ALICE), 4 ether, "alice pt");
    }

    function testClaimNormalFees_ReentrantRedeemPTCannotDoubleClaimUAssetFee() external {
        uint256 verseId = 43;
        _setUnlockedVerse(verseId);
        splitter.setSettled(true);
        splitter.setPreviewPTToUAssetResult(4 ether);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 20 ether);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 20 ether);

        ClaimNormalFeesReenterer reenterer =
            new ClaimNormalFeesReenterer(launcher, IERC20(address(uAsset)), IERC20(address(pt)), verseId);
        splitter.setClaimNormalFeesReentry(address(reenterer));
        setUserGenesisDataForTest(launcherProxy, verseId, address(reenterer), 24 ether, false, false);

        (uint256 claimedUAssetFee, uint256 claimedPTFee) = reenterer.claimNormalFees();

        assertTrue(reenterer.reentryAttempted(), "reentry attempted");
        assertEq(claimedUAssetFee, 6 ether, "single claim total");
        assertEq(claimedPTFee, 0, "pt redeemed");
        assertEq(uAsset.balanceOf(address(reenterer)), 6 ether, "no double uAsset fee");
    }

    function testClaimNormalFees_RedeemPTCallbackCanClaimNormalYTOnce() external {
        uint256 verseId = 44;
        _setUnlockedVerse(verseId);
        splitter.setSettled(true);
        splitter.setPreviewPTToUAssetResult(4 ether);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 20 ether);
        setTotalNormalClaimableYTForTest(launcherProxy, verseId, 60 ether);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 20 ether);
        yt.mint(address(launcher), 60 ether);

        ClaimNormalFeesReenterer reenterer =
            new ClaimNormalFeesReenterer(launcher, IERC20(address(uAsset)), IERC20(address(pt)), verseId);
        splitter.setClaimNormalFeesReentryMode(address(reenterer), 2);
        setUserGenesisDataForTest(launcherProxy, verseId, address(reenterer), 24 ether, false, false);

        (uint256 claimedUAssetFee, uint256 claimedPTFee) = reenterer.claimNormalFees();

        assertTrue(reenterer.reentryAttempted(), "reentry attempted");
        assertTrue(reenterer.reentrySucceeded(), "claimNormalYT reentry succeeded");
        assertEq(claimedUAssetFee, 6 ether, "single claim total");
        assertEq(claimedPTFee, 0, "pt redeemed");
        assertEq(uAsset.balanceOf(address(reenterer)), 6 ether, "uAsset claimed");
        assertEq(yt.balanceOf(address(reenterer)), 12 ether, "yt claimed");
        assertTrue(_concrete().normalYTClaimed(verseId, address(reenterer)), "yt marked claimed");
    }

    function testClaimNormalFees_RedeemPTCallbackCanRedeemAuxiliaryLiquidityOnce() external {
        uint256 verseId = 45;
        _setUnlockedVerse(verseId);
        splitter.setSettled(true);
        splitter.setPreviewPTToUAssetResult(4 ether);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 20 ether);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        setBootstrapResidualClaimsForTest(launcherProxy, verseId, 25 ether, 10 ether, 0, 0);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 30 ether);
        liquidProof.mint(address(launcher), 25 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);

        ClaimNormalFeesReenterer reenterer =
            new ClaimNormalFeesReenterer(launcher, IERC20(address(uAsset)), IERC20(address(pt)), verseId);
        splitter.setClaimNormalFeesReentryMode(address(reenterer), 3);
        setUserGenesisDataForTest(launcherProxy, verseId, address(reenterer), 24 ether, false, false);

        (uint256 claimedUAssetFee, uint256 claimedPTFee) = reenterer.claimNormalFees();

        assertTrue(reenterer.reentryAttempted(), "reentry attempted");
        assertTrue(reenterer.reentrySucceeded(), "redeemAuxiliaryLiquidity reentry succeeded");
        assertEq(claimedUAssetFee, 6 ether, "single claim total");
        assertEq(claimedPTFee, 0, "pt redeemed");
        assertEq(uAsset.balanceOf(address(reenterer)), 6 ether, "uAsset claimed");
        assertEq(polUAssetLp.balanceOf(address(reenterer)), 12 ether, "pol/uAsset lp claimed");
        assertEq(ptUAssetLp.balanceOf(address(reenterer)), 6 ether, "pt/uAsset lp claimed");
        assertEq(ptPolLp.balanceOf(address(reenterer)), 18 ether, "pt/pol lp claimed");
        assertEq(liquidProof.balanceOf(address(reenterer)), 5 ether, "pol residual claimed");
        assertEq(pt.balanceOf(address(reenterer)), 2 ether, "pt residual claimed");
        (,, bool isRedeemed) = _concrete().userGenesisData(verseId, address(reenterer));
        assertTrue(isRedeemed, "user marked redeemed");
    }

    function testClaimNormalFees_SettledSplitterLeavesZeroBackingPTDustUnclaimed() external {
        uint256 verseId = 35;
        _setUnlockedVerse(verseId);
        splitter.setSettled(true);
        splitter.setPreviewPTToUAssetResult(0);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 5);
        uAsset.mint(address(launcher), 10 ether);
        pt.mint(address(launcher), 5);

        vm.expectEmit(true, true, false, true, address(launcher));
        emit ClaimNormalFees(verseId, ALICE, 2 ether, 1);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 ptAmount) = launcher.claimNormalFees(verseId);

        assertEq(splitter.redeemPTCallCount(), 0, "zero backing pt not redeemed");
        assertEq(uAssetAmount, 2 ether, "uAsset still claimable");
        assertEq(ptAmount, 1, "pt dust reported as still-pending entitlement");
        assertEq(uAsset.balanceOf(ALICE), 2 ether, "alice uAsset");
        (, uint256 claimedPTFee) = _concrete().userNormalFeeClaims(verseId, ALICE);
        assertEq(claimedPTFee, 0, "pt entitlement stays pending for self-heal");

        // Self-heal retry: grow accPTFee so the still-pending entitlement becomes redeemable, and
        // restore 1:1 PT backing so the preview is non-zero. entitledPT = mulDiv(505, 24e18, 120e18) = 101.
        setNormalFeeStateForTest(launcherProxy, verseId, 10 ether, 505);
        splitter.setPreviewPTToUAssetRatio(1, 1);
        pt.mint(address(launcher), 101);
        uint256 expectedRedeemedPT = FullMath.mulDiv(505, 24 ether, 120 ether);

        vm.expectEmit(true, true, false, true, address(launcher));
        emit ClaimNormalFees(verseId, ALICE, expectedRedeemedPT, 0);

        vm.prank(ALICE);
        (uAssetAmount, ptAmount) = launcher.claimNormalFees(verseId);

        assertEq(splitter.redeemPTCallCount(), 1, "single redeemPT across both claims");
        assertEq(splitter.lastRedeemPTAmount(), expectedRedeemedPT, "redeemed the pending pt");
        assertEq(uAssetAmount, expectedRedeemedPT, "uAsset from in-place redeem");
        assertEq(ptAmount, 0, "pt redeemed in place");
        assertEq(uAsset.balanceOf(ALICE), 2 ether + expectedRedeemedPT, "alice uAsset after retry");
        (, uint256 claimedPTFeeAfter) = _concrete().userNormalFeeClaims(verseId, ALICE);
        assertEq(claimedPTFeeAfter, expectedRedeemedPT, "claimed pt fee advanced to new entitlement");
    }

    function testClaimNormalFees_HandlesMaxUint128FeeShareWithoutOverflow() external {
        uint256 verseId = 36;
        uint256 largeFee = uint256(type(uint128).max) + 3;
        _setUnlockedVerse(verseId);
        splitter.setSettled(false);
        setGenesisFundForTest(launcherProxy, verseId, type(uint128).max);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, type(uint128).max, false, false);
        setNormalFeeStateForTest(launcherProxy, verseId, largeFee, largeFee);
        uAsset.mint(address(launcher), largeFee);
        pt.mint(address(launcher), largeFee);

        vm.prank(ALICE);
        (uint256 uAssetAmount, uint256 ptAmount) = launcher.claimNormalFees(verseId);

        assertEq(uAssetAmount, largeFee, "uAsset amount");
        assertEq(ptAmount, largeFee, "pt amount");
        assertEq(uAsset.balanceOf(ALICE), largeFee, "alice uAsset");
        assertEq(pt.balanceOf(ALICE), largeFee, "alice pt");
    }

    /// @notice Verifies fee redemption returns zero values when no fees are claimable.
    /// @dev Confirms the early-return path short-circuits without dispatching or mutating balances.
    function testRedeemAndDistributeFees_ReturnsZeroWhenNoFees() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(govFee, 0, "govFee");
        assertEq(memecoinFee, 0, "memecoinFee");
        assertEq(liquidProofFee, 0, "liquidProofFee");
        assertEq(executorReward, 0, "executorReward");
    }

    /// @notice Verifies no-fee redemption rejects accidental native value.
    /// @dev Prevents stray ETH from being trapped by the no-fee early return.
    function testRedeemAndDistributeFees_NoFeesRevertsWhenMsgValueProvided() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.InvalidLzFee.selector, 0, 1));
        launcher.redeemAndDistributeFees{value: 1}(verseId, REWARD_RECEIVER);
    }

    /// @notice Test redeem and distribute fees remote path checks lz fee and sends oft.
    /// @dev Validates the remote dispatch branch requires the exact LayerZero fee and calls `send`.
    function testRedeemAndDistributeFees_RemotePathChecksLzFeeAndSendsOFT() external {
        uint256 verseId = 2;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 9 ether, 4 ether);
        router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 6 ether);
        remoteUAsset.setQuoteFee(0.15 ether);
        remoteMemecoin.setQuoteFee(0.25 ether);

        remoteUAsset.mint(address(launcher), 100 ether);
        remoteMemecoin.mint(address(launcher), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.InvalidLzFee.selector, 0.4 ether, 0));
        launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        launcher.redeemAndDistributeFees{value: 0.4 ether}(verseId, REWARD_RECEIVER);

        assertEq(remoteUAsset.sendCallCount(), 1);
        assertEq(remoteMemecoin.sendCallCount(), 1);
        assertEq(remoteUAsset.lastSendDstEid(), 302);
        assertEq(remoteMemecoin.lastSendDstEid(), 302);
        assertEq(remoteUAsset.lastNativeFeePaid(), 0.15 ether);
        assertEq(remoteMemecoin.lastNativeFeePaid(), 0.25 ether);
        // The remote lzCompose execution gas is allocated solely by the encoded executor options, so the OFT sends
        // must carry them verbatim. Literal gas limits (matching the setUp `initialize` args 10/11) are asserted
        // instead of storage getters: reading the getters would silently follow a re-wiring to the wrong storage
        // slot, defeating the anchor (F-100).
        bytes memory expectedOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(115_000, 0)
            .addExecutorLzComposeOption(0, 135_000, 0);
        assertEq(remoteUAsset.lastSendOptions(), expectedOptions, "uAsset send must carry executor options");
        assertEq(remoteMemecoin.lastSendOptions(), expectedOptions, "memecoin send must carry executor options");
        // Cross-chain fee distribution must route through OFT sends, never the local dispatcher
        // (remoteFeePathNeverUsesLocalDispatcher). A regression here would silently misroute fees.
        assertEq(dispatcher.composeCallCount(), 0, "remote path must not invoke local dispatcher");
    }

    /// @notice Verifies remote fee redemption rejects overpayment instead of trapping extra ETH in the launcher.
    /// @dev Requires the caller to provide the exact quoted LayerZero fee and reject overpayments.
    function testRedeemAndDistributeFees_RemotePathRevertsWhenLzFeeIsNotExact() external {
        uint256 verseId = 24;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 9 ether, 4 ether);
        router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 6 ether);
        remoteUAsset.setQuoteFee(0.15 ether);
        remoteMemecoin.setQuoteFee(0.25 ether);
        remoteUAsset.mint(address(launcher), 100 ether);
        remoteMemecoin.mint(address(launcher), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.InvalidLzFee.selector, 0.4 ether, 0.41 ether));
        launcher.redeemAndDistributeFees{value: 0.41 ether}(verseId, REWARD_RECEIVER);
    }

    /// @notice Test redeem and distribute fees remote path only gov fee skips memecoin send.
    /// @dev Ensures memecoin dispatch is skipped when its quote is zero in the remote path.
    function testRedeemAndDistributeFees_RemotePathOnlyGovFeeSkipsMemecoinSend() external {
        uint256 verseId = 21;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        if (address(remoteMemecoin) < address(remoteUAsset)) {
            router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 9 ether);
        } else {
            router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 9 ether, 0);
        }
        router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        remoteUAsset.setQuoteFee(0.15 ether);
        remoteUAsset.mint(address(launcher), 100 ether);

        launcher.redeemAndDistributeFees{value: 0.15 ether}(verseId, REWARD_RECEIVER);

        assertEq(remoteUAsset.sendCallCount(), 1);
        assertEq(remoteMemecoin.sendCallCount(), 0);
    }

    /// @notice Test redeem and distribute fees remote path only memecoin fee skips gov send.
    /// @dev Ensures governance dispatch is skipped when its quote is zero in the remote path.
    function testRedeemAndDistributeFees_RemotePathOnlyMemecoinFeeSkipsGovSend() external {
        uint256 verseId = 22;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        registry.setEndpoint(202, 302);

        if (address(remoteMemecoin) < address(remoteUAsset)) {
            router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 5 ether, 0);
        } else {
            router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 5 ether);
        }
        router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        remoteMemecoin.setQuoteFee(0.25 ether);
        remoteMemecoin.mint(address(launcher), 100 ether);

        launcher.redeemAndDistributeFees{value: 0.25 ether}(verseId, REWARD_RECEIVER);

        assertEq(remoteUAsset.sendCallCount(), 0);
        assertEq(remoteMemecoin.sendCallCount(), 1);
    }

    /// @notice Verifies fee redemption uses the same overflow-safe reward split as fee quoting.
    /// @dev Prevents unchecked reward multiplication from wrapping and misallocating value between executor and governor.
    function testRedeemAndDistributeFees_UsesFullPrecisionForLargeUAssetFee() external {
        uint256 verseId = 26;
        uint256 rewardRate = 9999;
        uint256 largeFee = type(uint256).max / rewardRate + 1;
        _setLockedVerse(verseId);
        launcher.setExecutorRewardRate(rewardRate);

        if (address(memecoin) < address(uAsset)) {
            router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, largeFee);
        } else {
            router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), largeFee, 0);
        }
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 0);

        uint256 expectedExecutorReward = FullMath.mulDiv(largeFee, rewardRate, 10_000);
        uint256 expectedGovFee = largeFee - expectedExecutorReward;

        (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(govFee, expectedGovFee, "gov fee");
        assertEq(memecoinFee, 0, "memecoin fee");
        assertEq(polFee, 0, "pol fee");
        assertEq(executorReward, expectedExecutorReward, "executor reward");
        assertEq(uAsset.balanceOf(REWARD_RECEIVER), expectedExecutorReward, "reward receiver uAsset");
        assertEq(uAsset.balanceOf(address(dispatcher)), expectedGovFee, "dispatcher uAsset");
    }

    /// @notice Test redeem and distribute fees remote path pre-redeems locked PT fee into the remote uAsset send.
    /// @dev Ensures remote governance never receives raw PT and the pre-redeemed amount is folded into the single uAsset OFT send.
    function testRedeemAndDistributeFees_RemotePathPreRedeemsLockedPTFeeAsUAsset() external {
        uint256 verseId = 23;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        polend.setPreRedeemPTFeeBacking(2 ether);
        registry.setEndpoint(202, 302);

        router.setClaimQuote(address(remoteMemecoin), address(remoteUAsset), address(launcher), 0, 0);
        router.setClaimQuote(address(liquidProof), address(remoteUAsset), address(launcher), 0, 0);
        if (address(pt) < address(remoteUAsset)) {
            router.setClaimQuote(address(pt), address(remoteUAsset), address(launcher), 14 ether, 0);
        } else {
            router.setClaimQuote(address(pt), address(remoteUAsset), address(launcher), 0, 14 ether);
        }
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);
        remoteUAsset.setQuoteFee(0.15 ether);

        launcher.redeemAndDistributeFees{value: 0.15 ether}(verseId, REWARD_RECEIVER);

        assertEq(polend.preRedeemPTFeeCallCount(), 1);
        assertEq(polend.lastPreRedeemPTFeeVerseId(), verseId);
        assertEq(polend.lastPreRedeemPTFeeAmount(), 4 ether);
        assertEq(polend.lastPreRedeemPTFeeMintTo(), address(launcher));
        assertEq(splitter.bridgeRedeemCallCount(), 0);
        assertEq(remoteUAsset.sendCallCount(), 1);
        assertEq(remoteUAsset.lastSendAmountLD(), 2 ether);
        assertEq(remoteMemecoin.sendCallCount(), 0);
    }

    function testRedeemAndDistributeFees_RemotePathKeepsPendingZeroBackingAuxiliaryGovPTFee() external {
        uint256 verseId = 37;
        MockOFTToken remoteUAsset = new MockOFTToken("UASSET", "UASSET");
        MockOFTToken remoteMemecoin = new MockOFTToken("MEME", "MEME");
        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(remoteUAsset);
        verse.memecoin = address(remoteMemecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        verse.currentStage = IMemeverseLauncher.Stage.Locked;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = 202;
        _writeMemeverse(verseId, verse);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 3 ether, 1);
        registry.setEndpoint(202, 302);
        remoteUAsset.setQuoteFee(0.15 ether);

        launcher.redeemAndDistributeFees{value: 0.15 ether}(verseId, REWARD_RECEIVER);

        (uint256 pendingUAssetFee, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertEq(pendingUAssetFee, 0, "uAsset pending cleared");
        assertEq(pendingPTFee, 0, "pt pending consumed from current redemption path");
        assertEq(remoteUAsset.sendCallCount(), 1, "uAsset sent");
        assertEq(remoteMemecoin.sendCallCount(), 0, "memecoin not sent");
    }

    function testRedeemAndDistributeFees_LocalPathPreRedeemsLockedPTFeeAsUAsset() external {
        uint256 verseId = 31;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        polend.setTotalLeveragedDebt(verseId, 40 ether);
        polend.setPreRedeemPTFeeBacking(2 ether);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, 0);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 0);
        if (address(pt) < address(uAsset)) {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 14 ether, 0);
        } else {
            router.setClaimQuote(address(pt), address(uAsset), address(launcher), 0, 14 ether);
        }
        router.setClaimQuote(address(pt), address(liquidProof), address(launcher), 0, 0);

        launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(polend.preRedeemPTFeeCallCount(), 1, "preRedeem called");
        assertEq(polend.lastPreRedeemPTFeeVerseId(), verseId, "verse id");
        assertEq(polend.lastPreRedeemPTFeeAmount(), 4 ether, "pt amount");
        assertEq(polend.lastPreRedeemPTFeeMintTo(), address(dispatcher), "mint target");
        assertEq(splitter.bridgeRedeemCallCount(), 0, "bridgeRedeem not used");
        assertEq(pt.balanceOf(address(0xCAFE)), 0, "no raw pt to governor");
        assertEq(uAsset.balanceOf(address(0xCAFE)), 0, "no direct uAsset to governor");
        assertEq(uAsset.balanceOf(address(dispatcher)), 2 ether, "uAsset to dispatcher");
        assertEq(dispatcher.composeCallCount(), 1, "compose called");
        (, uint8 tokenType, uint256 composedAmount) = abi.decode(dispatcher.lastMessage(), (address, uint8, uint256));
        assertEq(tokenType, uint8(IMemeverseOFTEnum.TokenType.UASSET), "compose token type");
        assertEq(composedAmount, 2 ether, "composed uAsset backing");
        (, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertEq(pendingPTFee, 0, "pending pt cleared after preRedeem");
    }

    function testRedeemAndDistributeFees_LocalPathLeavesZeroBackingPTDustPending() external {
        uint256 verseId = 36;
        _setLockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 100 ether);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 3 ether, 1);
        splitter.setPreviewPTToUAssetResult(0);
        uAsset.mint(address(launcher), 3 ether);

        (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(polend.preRedeemPTFeeCallCount(), 0, "zero backing pt not pre-redeemed");
        assertEq(govFee, 3 ether, "uAsset fee still distributed");
        assertEq(memecoinFee, 0, "memecoinFee");
        assertEq(liquidProofFee, 0, "liquidProofFee");
        assertEq(executorReward, 0, "executorReward");
        assertEq(uAsset.balanceOf(address(dispatcher)), 3 ether, "uAsset to dispatcher");
        assertEq(dispatcher.composeCallCount(), 1, "compose called");
        (uint256 pendingUAssetFee, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertEq(pendingUAssetFee, 0, "uAsset pending cleared");
        assertEq(pendingPTFee, 1, "pt pending unchanged");
    }

    function testRedeemAndDistributeFees_AfterUnlockRedeemsPendingPTFeeThroughSplitter() external {
        uint256 verseId = 30;
        _setUnlockedVerse(verseId);
        setPendingAuxiliaryGovFeeForTest(launcherProxy, verseId, 0, 7 ether);
        pt.mint(address(launcher), 7 ether);

        launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(splitter.redeemPTCallCount(), 1, "redeemPT called");
        assertEq(splitter.lastRedeemPTVerseId(), verseId, "verse id");
        assertEq(splitter.lastRedeemPTAmount(), 7 ether, "pt amount");
        assertEq(splitter.lastRedeemPTTo(), address(dispatcher), "redeem receiver");
        assertEq(polend.preRedeemPTFeeCallCount(), 0, "no preRedeem after unlock");
        assertEq(pt.balanceOf(address(0xCAFE)), 0, "no raw pt to governor");
        assertEq(uAsset.balanceOf(address(0xCAFE)), 0, "no direct uAsset to governor");
        assertEq(uAsset.balanceOf(address(dispatcher)), 7 ether, "uAsset to dispatcher");
        assertEq(dispatcher.composeCallCount(), 1, "compose called");
        (, uint256 pendingPTFee) = _concrete().pendingAuxiliaryGovFeeStates(verseId);
        assertEq(pendingPTFee, 0, "pending pt cleared after redeem");
    }

    /// @notice Test redeem and distribute fees local path with only gov fee skips memecoin dispatch.
    /// @dev Confirms the local path keeps dispatcher fees aligned with the available memecoin/governance splits.
    function testRedeemAndDistributeFees_LocalPathWithOnlyGovFeeSkipsMemecoinDispatch() external {
        uint256 verseId = 15;
        _setLockedVerse(verseId);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 9 ether, 0);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 0);

        (uint256 govFee, uint256 memecoinFee,, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertGt(govFee, 0);
        assertEq(memecoinFee, 0);
        assertGt(executorReward, 0);
        assertEq(dispatcher.composeCallCount(), 1);
        assertEq(dispatcher.lastToken(), address(uAsset));
    }

    /// @notice Verifies local fee redemption rejects accidental native value.
    /// @dev Prevents stray ETH from being trapped in the launcher on same-chain paths.
    function testRedeemAndDistributeFees_LocalPathRevertsWhenMsgValueProvided() external {
        uint256 verseId = 25;
        _setLockedVerse(verseId);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 9 ether, 0);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.InvalidLzFee.selector, 0, 1));
        launcher.redeemAndDistributeFees{value: 1}(verseId, REWARD_RECEIVER);
    }

    /// @notice Test redeem and distribute fees local path with only memecoin fee skips gov dispatch.
    /// @dev Verifies executor rewards and gov dispatch are zero when only memecoin fees exist locally.
    function testRedeemAndDistributeFees_LocalPathWithOnlyMemecoinFeeSkipsGovDispatch() external {
        uint256 verseId = 16;
        _setLockedVerse(verseId);
        launcher.setExecutorRewardRate(0);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 0, 5 ether);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 0, 0);

        (uint256 govFee, uint256 memecoinFee,, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(govFee, 0);
        assertEq(memecoinFee, 5 ether);
        assertEq(executorReward, 0);
        assertEq(dispatcher.composeCallCount(), 1);
        assertEq(dispatcher.lastToken(), address(memecoin));
    }

    /// @notice Verifies same-chain fee redemption claims, burns, and dispatches the expected assets.
    /// @dev Covers the restored fee distribution flow through the mock dispatcher and validates all transfers.
    function testRedeemAndDistributeFees_SameChainClaimsAndDistributesFees() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 20 ether, 7 ether);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 12 ether, 5 ether);

        (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(memecoinFee, 7 ether, "memecoin fee");
        assertEq(liquidProofFee, 5 ether, "liquid proof fee");
        assertEq(executorReward, 0.05 ether, "executor reward");
        assertEq(govFee, 31.95 ether, "gov fee");

        assertEq(uAsset.balanceOf(REWARD_RECEIVER), executorReward, "reward receiver uAsset");
        assertEq(uAsset.balanceOf(address(dispatcher)), govFee, "dispatcher uAsset");
        assertEq(uAsset.balanceOf(address(0xCAFE)), 0, "no direct governor uAsset");
        assertEq(pt.balanceOf(address(0xCAFE)), 0, "no raw pt to governor");
        assertEq(memecoin.balanceOf(address(dispatcher)), memecoinFee, "dispatcher memecoin");
        assertEq(liquidProof.burnedAmount(), liquidProofFee, "burned liquid proof");
        assertEq(dispatcher.composeCallCount(), 2, "compose call count");
        assertEq(uAsset.balanceOf(address(launcher)), 0, "launcher uAsset");
        assertEq(memecoin.balanceOf(address(launcher)), 0, "launcher memecoin");
        assertEq(liquidProof.balanceOf(address(launcher)), 0, "launcher liquid proof");
    }

    /// @notice Fuzzes same-chain fee redemption across main and auxiliary pool fee amounts.
    /// @dev Leaves normal funding and leverage unset so every auxiliary fee is governance-side value.
    function testFuzz_RedeemAndDistributeFees_SameChainClaimsAndDistributesAllFees(
        uint128 mainMemecoinFee,
        uint128 mainUAssetFee,
        uint128 auxiliaryPolFee,
        uint128 auxiliaryUAssetFee
    ) external {
        uint256 verseId = 40;
        _setLockedVerse(verseId);

        if (address(memecoin) < address(uAsset)) {
            router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), mainMemecoinFee, mainUAssetFee);
        } else {
            router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), mainUAssetFee, mainMemecoinFee);
        }
        if (address(liquidProof) < address(uAsset)) {
            router.setClaimQuote(
                address(liquidProof), address(uAsset), address(launcher), auxiliaryPolFee, auxiliaryUAssetFee
            );
        } else {
            router.setClaimQuote(
                address(liquidProof), address(uAsset), address(launcher), auxiliaryUAssetFee, auxiliaryPolFee
            );
        }

        (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(memecoinFee, uint256(mainMemecoinFee), "memecoin fee");
        assertEq(liquidProofFee, uint256(auxiliaryPolFee), "liquid proof fee");
        // With no normal-side liability, all claimed uAsset leaves through governance or executor reward paths.
        assertEq(govFee + executorReward, uint256(mainUAssetFee) + uint256(auxiliaryUAssetFee), "uAsset fee");
        assertEq(liquidProof.burnedAmount(), liquidProofFee, "burned liquid proof");
        assertEq(uAsset.balanceOf(address(launcher)), 0, "launcher uAsset");
        assertEq(memecoin.balanceOf(address(launcher)), 0, "launcher memecoin");
        assertEq(liquidProof.balanceOf(address(launcher)), 0, "launcher liquid proof");
        assertEq(uAsset.balanceOf(REWARD_RECEIVER), executorReward, "reward receiver uAsset");
        assertEq(uAsset.balanceOf(address(dispatcher)), govFee, "dispatcher uAsset");
        assertEq(memecoin.balanceOf(address(dispatcher)), memecoinFee, "dispatcher memecoin");

        uint256 expectedComposeCallCount;
        if (govFee != 0) expectedComposeCallCount++;
        if (memecoinFee != 0) expectedComposeCallCount++;
        assertEq(dispatcher.composeCallCount(), expectedComposeCallCount, "compose call count");
    }

    /// @notice Verifies preview fee mapping matches actual redemption fee mapping.
    /// @dev Prevents preview and claim flows from drifting on token ordering.
    function testPreviewAndRedeemShareTheSameFeeMapping() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setPreviewQuote(address(memecoin), address(uAsset), address(launcher), 9 ether, 4 ether);
        router.setPreviewQuote(address(liquidProof), address(uAsset), address(launcher), 13 ether, 6 ether);
        router.setClaimQuote(address(memecoin), address(uAsset), address(launcher), 9 ether, 4 ether);
        router.setClaimQuote(address(liquidProof), address(uAsset), address(launcher), 13 ether, 6 ether);

        (uint256 previewUAssetFee, uint256 previewMemecoinFee) = feePreviewReader.previewGenesisMakerFees(verseId);
        (uint256 govFee, uint256 memecoinFee,, uint256 executorReward) =
            launcher.redeemAndDistributeFees(verseId, REWARD_RECEIVER);

        assertEq(previewMemecoinFee, memecoinFee, "memecoin mapping");
        assertEq(previewUAssetFee, govFee + executorReward + uAsset.balanceOf(address(0xCAFE)), "uAsset mapping");
    }

    /// @notice Verifies memecoin LP redemption rejects zero POL input.
    /// @dev Confirms the restored zero-input guard is active.
    function testRedeemMemecoinLiquidity_RevertsOnZeroInput() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.redeemMemecoinLiquidity(verseId, 0, false);
    }

    /// @notice Verifies memecoin LP redemption rejects non-unlocked verses.
    /// @dev Confirms the restored stage guard is active for memecoin LP claims.
    function testRedeemMemecoinLiquidity_RevertsWhenNotUnlocked() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.NotUnlockedStage.selector);
        launcher.redeemMemecoinLiquidity(verseId, 1 ether, false);
    }

    /// @notice Verifies memecoin LP redemption burns POL and transfers pair LP shares.
    /// @dev Covers the restored router-based pair LP lookup in the happy path.
    function testRedeemMemecoinLiquidity_BurnsPOLAndTransfersMemecoinLp() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        address verseMemecoin = verse.memecoin;
        address verseUAsset = verse.uAsset;
        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(verseMemecoin), address(verseUAsset), address(memecoinLp));
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(ALICE, 10 ether);

        vm.prank(ALICE);
        uint256 amountInLP = launcher.redeemMemecoinLiquidity(verseId, 4 ether, false);

        assertEq(amountInLP, 4 ether, "lp amount");
        assertEq(liquidProof.burnedAmount(), 4 ether, "burned pol");
        assertEq(liquidProof.balanceOf(ALICE), 6 ether, "alice pol balance");
        assertEq(memecoinLp.balanceOf(ALICE), 4 ether, "alice memecoin lp");
        assertEq(memecoinLp.balanceOf(address(launcher)), 6 ether, "launcher memecoin lp");
    }

    /// @notice Verifies memecoin LP redemption can unwrap into underlying assets.
    /// @dev Covers the new launcher overload wired for splitter settlement.
    function testRedeemMemecoinLiquidity_UnwrapsUnderlyingWhenRequested() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setRemoveLiquidityResult(address(memecoin), address(uAsset), 3 ether, 5 ether);
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(ALICE, 10 ether);

        vm.prank(ALICE);
        uint256 amountInLP = launcher.redeemMemecoinLiquidity(verseId, 4 ether, true);

        uint256 expectedMemecoinAmount = address(memecoin) < address(uAsset) ? 3 ether : 5 ether;
        uint256 expectedUAssetAmount = address(memecoin) < address(uAsset) ? 5 ether : 3 ether;

        assertEq(amountInLP, 4 ether, "lp amount");
        assertEq(liquidProof.burnedAmount(), 4 ether, "burned pol");
        assertEq(memecoin.balanceOf(ALICE), expectedMemecoinAmount, "alice memecoin");
        assertEq(uAsset.balanceOf(ALICE), expectedUAssetAmount, "alice uAsset");
        assertEq(memecoinLp.balanceOf(address(launcher)), 6 ether, "launcher memecoin lp");
    }

    function testRedeemMemecoinLiquidity_UnwrapKeepsInfiniteLpAllowanceForRouter() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setRemoveLiquidityResult(address(memecoin), address(uAsset), 3 ether, 5 ether);
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(ALICE, 10 ether);

        vm.startPrank(ALICE);
        launcher.redeemMemecoinLiquidity(verseId, 4 ether, true);
        launcher.redeemMemecoinLiquidity(verseId, 2 ether, true);
        vm.stopPrank();

        assertEq(
            memecoinLp.allowance(address(launcher), address(router)),
            0,
            "launcher LP allowance consumed after exact approval"
        );
        assertEq(memecoinLp.balanceOf(address(launcher)), 4 ether, "launcher memecoin lp");
    }

    function testRedeemMemecoinLiquidity_AllowsSplitterSettlementWhilePaused() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setRemoveLiquidityResult(address(memecoin), address(uAsset), 3 ether, 5 ether);
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(address(splitter), 10 ether);
        _concrete().pause();

        vm.prank(address(splitter));
        uint256 amountInLP = launcher.redeemMemecoinLiquidity(verseId, 4 ether, true);

        assertEq(amountInLP, 4 ether, "lp amount");
        assertEq(liquidProof.burnedAmount(), 4 ether, "burned pol");
    }

    function testRedeemMemecoinLiquidity_AllowsUserPathWhilePaused() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);
        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(ALICE, 10 ether);
        _concrete().pause();

        vm.prank(ALICE);
        uint256 amountInLP = launcher.redeemMemecoinLiquidity(verseId, 4 ether, false);

        assertEq(amountInLP, 4 ether, "lp amount");
        assertEq(liquidProof.burnedAmount(), 4 ether, "burned pol");
        assertEq(memecoinLp.balanceOf(ALICE), 4 ether, "alice memecoin lp");
    }

    /// @notice Verifies memecoin LP redemption stays available during the post-unlock protection window.
    /// @dev Protection-window config should only gate public swaps, not unlocked liquidity redemption.
    function testRedeemMemecoinLiquidity_AllowsDuringPostUnlockProtectionWindow() external {
        uint256 verseId = 21;
        _setUnlockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp);
        _writeMemeverse(verseId, verse);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(ALICE, 10 ether);

        vm.prank(ALICE);
        uint256 amountInLP = launcher.redeemMemecoinLiquidity(verseId, 4 ether, false);

        assertEq(amountInLP, 4 ether, "lp amount");
        assertEq(memecoinLp.balanceOf(ALICE), 4 ether, "alice memecoin lp");
    }

    /// @notice Test redeem memecoin liquidity reverts when launcher lp balance insufficient.
    /// @dev Ensures the contract only transfers LP when it holds enough balance.
    function testRedeemMemecoinLiquidity_RevertsWhenLauncherLpBalanceInsufficient() external {
        uint256 verseId = 12;
        _setUnlockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        liquidProof.mint(ALICE, 10 ether);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InsufficientLPBalance.selector);
        launcher.redeemMemecoinLiquidity(verseId, 4 ether, false);
    }

    /// @notice Verifies auxiliary liquidity redemption rejects non-unlocked verses.
    /// @dev Confirms the new auxiliary exit only opens after unlock.
    function testRedeemAuxiliaryLiquidity_RevertsWhenNotUnlocked() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 1 ether, false, false);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.NotUnlockedStage.selector);
        launcher.redeemAuxiliaryLiquidity(verseId);
    }

    /// @notice Verifies auxiliary liquidity redemption rejects accounts that already redeemed.
    /// @dev Confirms the shared redeemed flag still gates the new exit path.
    function testRedeemAuxiliaryLiquidity_RevertsWhenAlreadyRedeemed() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 1 ether, false, true);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.redeemAuxiliaryLiquidity(verseId);
    }

    /// @notice Verifies auxiliary liquidity redemption transfers all three auxiliary LP tokens pro rata.
    /// @dev Asserts the launcher sends LP shares directly without unwrapping or reducing recorded liquidity.
    function testRedeemAuxiliaryLiquidity_TransfersShareAcrossAuxiliaryPools() external {
        uint256 verseId = 1;
        _setUnlockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);

        vm.prank(ALICE);
        (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) =
            launcher.redeemAuxiliaryLiquidity(verseId);

        (, bool isRefunded, bool isRedeemed) = _concrete().userGenesisData(verseId, ALICE);
        assertEq(polUAssetLpAmount, 12 ether, "pol/uAsset lp amount");
        assertEq(ptUAssetLpAmount, 6 ether, "pt/uAsset lp amount");
        assertEq(ptPolLpAmount, 18 ether, "pt/pol lp amount");
        assertEq(polUAssetLp.balanceOf(ALICE), 12 ether, "alice pol/uAsset lp");
        assertEq(ptUAssetLp.balanceOf(ALICE), 6 ether, "alice pt/uAsset lp");
        assertEq(ptPolLp.balanceOf(ALICE), 18 ether, "alice pt/pol lp");
        assertEq(
            uint256(router.lastRemoveLiquidityAmount(address(liquidProof), address(uAsset))), 0, "no pol/uAsset unwrap"
        );
        assertEq(uint256(router.lastRemoveLiquidityAmount(address(pt), address(uAsset))), 0, "no pt/uAsset unwrap");
        assertEq(uint256(router.lastRemoveLiquidityAmount(address(pt), address(liquidProof))), 0, "no pt/pol unwrap");
        (uint256 remainingPolUAssetLp, uint256 remainingPtUAssetLp, uint256 remainingPtPolLp) =
            _concrete().auxiliaryLiquidities(verseId);
        assertEq(remainingPolUAssetLp, 60 ether, "recorded pol/uAsset lp unchanged");
        assertEq(remainingPtUAssetLp, 30 ether, "recorded pt/uAsset lp unchanged");
        assertEq(remainingPtPolLp, 90 ether, "recorded pt/pol lp unchanged");
        assertFalse(isRefunded, "is refunded");
        assertTrue(isRedeemed, "is redeemed");
    }

    function testRedeemAuxiliaryLiquidity_UserCanRedeemLpWhenCalledThroughRouterAddress() external {
        uint256 verseId = 23;
        _setUnlockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, address(router), 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);

        (uint256 polUAssetLpAmount,,) = router.redeemAuxiliary(address(launcher), verseId);

        (,, bool isRedeemed) = _concrete().userGenesisData(verseId, address(router));
        assertEq(polUAssetLpAmount, 12 ether, "lp amount");
        assertEq(polUAssetLp.balanceOf(address(router)), 12 ether, "router lp");
        assertTrue(isRedeemed, "redeemed");
    }

    function testRedeemAuxiliaryLiquidity_DoesNotCallRouterRemoveLiquidity() external {
        uint256 verseId = 24;
        _setUnlockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);

        vm.prank(ALICE);
        (uint256 polUAssetLpAmount,,) = launcher.redeemAuxiliaryLiquidity(verseId);

        assertEq(polUAssetLpAmount, 12 ether, "lp amount");
        assertEq(
            uint256(router.lastRemoveLiquidityAmount(address(liquidProof), address(uAsset))), 0, "remove not called"
        );
    }

    /// @notice Verifies auxiliary liquidity remains redeemable during the post-unlock protection window.
    /// @dev The public-swap cooldown must not block auxiliary exits once the stage is unlocked.
    function testRedeemAuxiliaryLiquidity_AllowsDuringPostUnlockProtectionWindow() external {
        uint256 verseId = 22;
        _setUnlockedVerse(verseId);
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(verseId);
        verse.unlockTime = uint128(block.timestamp);
        _writeMemeverse(verseId, verse);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);

        vm.prank(ALICE);
        (uint256 polAmount,,) = launcher.redeemAuxiliaryLiquidity(verseId);

        assertEq(polAmount, 12 ether, "pol/uAsset lp amount");
    }

    function testRedeemAuxiliaryLiquidity_DistributesNormalBootstrapResiduals() external {
        uint256 verseId = 23;
        _setUnlockedVerse(verseId);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, ALICE, 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        setBootstrapResidualClaimsForTest(launcherProxy, verseId, 25 ether, 10 ether, 0, 0);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);
        liquidProof.mint(address(launcher), 25 ether);
        pt.mint(address(launcher), 10 ether);

        uint256 alicePolBefore = liquidProof.balanceOf(ALICE);
        uint256 alicePtBefore = pt.balanceOf(ALICE);

        vm.prank(ALICE);
        launcher.redeemAuxiliaryLiquidity(verseId);

        assertEq(liquidProof.balanceOf(ALICE) - alicePolBefore, 5 ether, "normal residual pol");
        assertEq(pt.balanceOf(ALICE) - alicePtBefore, 2 ether, "normal residual pt");
    }

    /// @notice Verifies auxiliary liquidity redemption rejects users without a genesis share.
    /// @dev Keeps the new exit path aligned with the old invalid-redeem guard.
    function testRedeemAuxiliaryLiquidity_RevertsWhenUserHasNoShare() external {
        uint256 verseId = 13;
        _setUnlockedVerse(verseId);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.redeemAuxiliaryLiquidity(verseId);
    }

    /// @notice Verifies mintPOLToken rejects zero input budgets.
    /// @dev Confirms zero-input guard prevents meaningless mint transactions.
    /// @dev Confirms the restored zero-input guard is active.
    function testMintPOLToken_RevertsOnZeroInput() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.mintPOLToken(verseId, 0, 1 ether, 0, 0, 0, block.timestamp);
    }

    /// @notice Verifies mintPOLToken rejects verses before the locked stage.
    /// @dev Confirms the stage guard blocks minting during Genesis or Refund.
    /// @dev Confirms the restored stage guard is active.
    function testMintPOLToken_RevertsWhenBeforeLocked() external {
        uint256 verseId = 1;
        IMemeverseLauncher.Memeverse memory verse;
        verse.currentStage = IMemeverseLauncher.Stage.Genesis;
        verse.uAsset = address(uAsset);
        verse.memecoin = address(memecoin);
        _writeMemeverse(verseId, verse);

        vm.expectRevert(IMemeverseLauncher.NotReachedLockedStage.selector);
        launcher.mintPOLToken(verseId, 1 ether, 1 ether, 0, 0, 0, block.timestamp);
    }

    /// @notice Verifies lifecycle entrypoints reject non-existent non-zero verse ids.
    /// @dev Prevents default-slot stage errors from leaking through state-changing APIs.
    function testLifecycleEntryPoints_RevertWhenVerseIdNotRegistered() external {
        uint256 invalidVerseId = 999;

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.refund(invalidVerseId);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.refundPreorder(invalidVerseId);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.claimNormalYT(invalidVerseId);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.claimUnlockedPreorderMemecoin(invalidVerseId);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.redeemAndDistributeFees(invalidVerseId, REWARD_RECEIVER);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.redeemMemecoinLiquidity(invalidVerseId, 1 ether, false);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.redeemAuxiliaryLiquidity(invalidVerseId);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.mintPOLToken(invalidVerseId, 1 ether, 1 ether, 0, 0, 0, block.timestamp);
    }

    /// @notice Verifies automatic liquidity minting refunds unused inputs and mints matching POL.
    /// @dev Covers the `amountOutDesired == 0` router path to ensure refunds happen before LP minting.
    function testMintPOLToken_WithAutoLiquidity_RefundsUnusedInputsAndMintsPol() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 8 ether, 6 ether, 10 ether);
        splitter.setPreviewPTToUAssetResult(6 ether);

        uAsset.mint(ALICE, 9 ether);
        memecoin.mint(ALICE, 13 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 9 ether, 13 ether, 5 ether, 8 ether, 0, block.timestamp);

        assertEq(amountInUAsset, 6 ether, "uAsset used");
        assertEq(amountInMemecoin, 10 ether, "memecoin used");
        assertEq(amountOut, 8 ether, "pol out");
        assertEq(uAsset.balanceOf(ALICE), 3 ether, "uAsset refund");
        assertEq(memecoin.balanceOf(ALICE), 3 ether, "memecoin refund");
        assertEq(liquidProof.balanceOf(ALICE), 8 ether, "alice pol");
        assertEq(memecoinLp.balanceOf(address(launcher)), 8 ether, "launcher lp");
    }

    /// @notice Verifies POL is minted before refund callbacks during auto-liquidity minting.
    /// @dev Uses a callback token to assert CEI ordering at refund time.
    function testMintPOLToken_WithAutoLiquidity_MintsPolBeforeRefundCallback() external {
        uint256 verseId = 1;
        RefundCallbackToken callbackMemecoin = new RefundCallbackToken("MEME", "MEME");
        memecoin = callbackMemecoin;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 8 ether, 6 ether, 10 ether);
        splitter.setPreviewPTToUAssetResult(6 ether);

        MintPolRefundObserver observer = new MintPolRefundObserver(
            launcher, IERC20(address(uAsset)), IERC20(address(memecoin)), IERC20(address(liquidProof)), verseId
        );
        callbackMemecoin.setCallbackTarget(address(observer));

        uAsset.mint(address(observer), 9 ether);
        memecoin.mint(address(observer), 13 ether);
        observer.approveLauncher();

        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            observer.executeMintPOLToken(9 ether, 13 ether, 5 ether, 8 ether, 0, block.timestamp);

        assertEq(amountInUAsset, 6 ether, "uAsset used");
        assertEq(amountInMemecoin, 10 ether, "memecoin used");
        assertEq(amountOut, 8 ether, "pol out");
        assertTrue(observer.sawPolDuringRefund(), "refund callback should observe minted POL");
        assertEq(liquidProof.balanceOf(address(observer)), 8 ether, "observer pol");
    }

    /// @notice Verifies exact-liquidity minting uses the detailed add-liquidity path and mints the requested POL.
    /// @dev Covers the `amountOutDesired != 0` launcher path without relying on padded quote amounts as a hard gate.
    function testMintPOLToken_WithExactLiquidity_UsesDetailedAddLiquidityAndMintsRequestedPol() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 7 ether, 9 ether);
        splitter.setPreviewPTToUAssetResult(7 ether);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 7 ether, "uAsset used");
        assertEq(amountInMemecoin, 9 ether, "memecoin used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(uAsset.balanceOf(ALICE), 3 ether, "uAsset refund");
        assertEq(memecoin.balanceOf(ALICE), 3 ether, "memecoin refund");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
        assertEq(memecoinLp.balanceOf(address(launcher)), 5 ether, "launcher lp");
        assertEq(router.addLiquidityDetailedCallCount(), 1, "detailed addLiquidity used");
    }

    function testMintPOLToken_MintsWhenPTBackingPreviewExceedsActualUAssetSpend() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether + 2);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset,, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "uAsset used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
    }

    function testMintPOLToken_MintsWhenPTBackingPreviewExceedsActualUAssetSpendByOneWei() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether + 1);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset,, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "uAsset used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
    }

    function testMintPOLToken_MintsWhenPTBackingPreviewIsBelowActualUAssetSpend() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(8 ether);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset,, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "uAsset used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
    }

    function testMintPOLToken_MintsWhenPTBackingPreviewMatchesActualUAssetSpend() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset,, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "uAsset used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
    }

    function testMintPOLToken_MintsWhenPTBackingPreviewIsOneWeiBelowActualUAssetSpend() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether - 1);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset,, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "uAsset used");
        assertEq(amountOut, 5 ether, "pol out");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
    }

    /// @notice Verifies exact-liquidity minting fails closed when budgets cannot mint the requested POL amount.
    /// @dev Confirms the launcher no longer treats a padded quote as a hard budget gate and instead checks actual output.
    function testMintPOLToken_WithExactLiquidity_RevertsWhenDetailedLiquidityUnderMints() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 4 ether, 7 ether, 9 ether);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseUniswapHook.TooMuchSlippage.selector);
        launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);
    }

    /// @notice Verifies auto-mode liquidity minting reverts TooMuchSlippage when the router settles zero LP.
    /// @dev Auto mode (amountOutDesired = 0) forwards caller mins; with min = 0 the mock router returns the
    /// stored (0, 0, 0) result as-is, so zero LP must surface the slippage error instead of reaching IPol.mint(0).
    /// Also proves the failed mint rolls the whole tx back: ALICE keeps both input tokens.
    function testMintPOLToken_AutoLiquidity_RevertsWhenZeroLiquidity() external {
        uint256 verseId = 1;
        _setLockedVerse(verseId);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 0, 0, 0);

        uint256 uAssetBefore = uAsset.balanceOf(ALICE);
        uint256 memecoinBefore = memecoin.balanceOf(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseUniswapHook.TooMuchSlippage.selector);
        launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 0, block.timestamp);

        assertEq(uAsset.balanceOf(ALICE), uAssetBefore, "uAsset rolled back");
        assertEq(memecoin.balanceOf(ALICE), memecoinBefore, "memecoin rolled back");
    }

    /// @notice Test mint poltoken with exact liquidity no refund path.
    /// @dev Ensures no refund is issued when exact liquidity formulas match the requested output.
    function testMintPOLToken_WithExactLiquidity_NoRefundPath() external {
        uint256 verseId = 17;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether);
        assertEq(amountInMemecoin, 12 ether);
        assertEq(amountOut, 5 ether);
        assertEq(uAsset.balanceOf(ALICE), 0);
        assertEq(memecoin.balanceOf(ALICE), 0);
    }

    /// @notice Verifies exact-liquidity minting uses the exact quote path even when the padded quote exceeds budget.
    /// @dev Proves `quoteAmountsForLiquidity(...)` no longer blocks exact-liquidity mints when `quoteExact...` fits.
    function testMintPOLToken_WithExactLiquidity_IgnoresPaddedQuoteBudgetOverrun() external {
        uint256 verseId = 19;
        _setLockedVerse(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 11 ether, 13 ether);
        router.setExactQuoteAmountsForLiquidity(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        router.setAddLiquidityResult(address(uAsset), address(memecoin), 5 ether, 10 ether, 12 ether);
        splitter.setPreviewPTToUAssetResult(10 ether);

        uAsset.mint(ALICE, 10 ether);
        memecoin.mint(ALICE, 12 ether);
        _approveMintInputs(ALICE);

        vm.prank(ALICE);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(verseId, 10 ether, 12 ether, 0, 0, 5 ether, block.timestamp);

        assertEq(amountInUAsset, 10 ether, "exact uAsset used");
        assertEq(amountInMemecoin, 12 ether, "exact memecoin used");
        assertEq(amountOut, 5 ether, "requested liquidity minted");
        assertEq(liquidProof.balanceOf(ALICE), 5 ether, "alice pol");
        assertEq(memecoinLp.balanceOf(address(launcher)), 5 ether, "launcher lp");
        assertEq(router.addLiquidityDetailedCallCount(), 1, "detailed addLiquidity used");
    }

    /// @notice Verifies only the owner can sweep native dust from the launcher.
    /// @dev Exposes the regression where any caller could drain the contract's native balance.
    function testRemoveGasDust_RevertsWhenCallerIsNotOwner() external {
        vm.deal(address(launcher), 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        launcher.removeGasDust(ALICE);
    }
}
