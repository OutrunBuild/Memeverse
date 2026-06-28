// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {
    MockSwapRouter,
    MockOFTDispatcher,
    MockPredictOnlyProxyDeployer,
    MockPOLendForLifecycle,
    MockPOLSplitterForLifecycle,
    MockLzEndpointRegistry,
    MockLiquidProof,
    MockPreorderSettlementHookForLauncherTest,
    RedeemMemecoinLiquidityReenterer
} from "../mocks/verse/LauncherLifecycleMocks.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract MemeverseLauncherUnlockProtectionTest is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    bytes4 internal constant PUBLIC_SWAP_DISABLED_SELECTOR = bytes4(keccak256("PublicSwapDisabled()"));

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
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

    function _deployHookProxy(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        (address hookProxy,) = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHook(hookProxy);
    }

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
        MemeverseLauncher impl = new MemeverseLauncher();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncher.initialize,
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
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));
        polend.setLendMarket(address(pt), address(yt));
        router.setLpToken(address(liquidProof), address(uAsset), address(polUAssetLp));
        router.setLpToken(address(pt), address(uAsset), address(ptUAssetLp));
        router.setLpToken(address(pt), address(liquidProof), address(ptPolLp));
    }

    function testLockedToUnlockedWritesDedicatedProtectionWindowForAllProtectedPairs() external {
        uint256 verseId = 1;
        _setLockedVerseReadyToUnlock(verseId);

        PoolKey memory memecoinKey = router.getHookPoolKey(address(memecoin), address(uAsset));
        PoolKey memory polKey = router.getHookPoolKey(address(liquidProof), address(uAsset));
        PoolKey memory ptUAssetKey = router.getHookPoolKey(address(pt), address(uAsset));
        PoolKey memory ptPolKey = router.getHookPoolKey(address(pt), address(liquidProof));

        launcher.changeStage(verseId);

        uint40 resumeTime = uint40(block.timestamp + 24 hours);
        _assertResumeTime(memecoinKey, resumeTime, "memecoin/uAsset");
        _assertResumeTime(polKey, resumeTime, "POL/uAsset");
        _assertResumeTime(ptUAssetKey, resumeTime, "PT/uAsset");
        _assertResumeTime(ptPolKey, resumeTime, "PT/POL");
    }

    function testPublicAndEquivalentPublicSwapPathsAreBlockedUntilProtectionWindowEnds() external {
        uint256 verseId = 2;
        MockPOLendForLifecycle localPolend = new MockPOLendForLifecycle();
        MockPOLSplitterForLifecycle localSplitter = new MockPOLSplitterForLifecycle(address(pt), address(yt));
        address localProxy = _deployLauncherProxy(address(localPolend), address(localSplitter));
        IMemeverseLauncher localLauncher = IMemeverseLauncher(localProxy);
        _setLockedVerseReadyToUnlock(localLauncher, verseId);
        MockPoolManagerForRouterTest guardedManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHook guardedHook =
            _deployHookProxy(IPoolManager(address(guardedManager)), address(this), address(1));
        MemeverseSwapRouter guardedRouter = new MemeverseSwapRouter(
            IPoolManager(address(guardedManager)),
            IMemeverseUniswapHook(address(guardedHook)),
            new MemeverseUniswapHookLens(IPoolManager(address(guardedManager))),
            IPermit2(address(0xBEEF))
        );
        PoolKey memory key = _hookPoolKey(address(guardedHook));
        guardedHook.setLauncher(address(localLauncher));
        guardedHook.setPoolInitializer(address(this));
        guardedHook.authorizePoolInitialization(key, 79_228_162_514_264_337_593_543_950_336);
        guardedManager.initialize(key, 79_228_162_514_264_337_593_543_950_336);
        _initializeHookPool(guardedHook, guardedManager, address(liquidProof), address(uAsset));
        _initializeHookPool(guardedHook, guardedManager, address(pt), address(uAsset));
        _initializeHookPool(guardedHook, guardedManager, address(pt), address(liquidProof));
        guardedHook.setPoolInitializer(address(guardedRouter));
        seedActiveLiquiditySharesForTest(address(guardedHook), key.toId(), address(this), 1e18);
        guardedHook.setProtocolFeeCurrency(key.currency0, true);
        memecoin.mint(address(this), 1_000_000 ether);
        uAsset.mint(address(this), 1_000_000 ether);
        memecoin.mint(address(guardedManager), 1_000_000 ether);
        uAsset.mint(address(guardedManager), 1_000_000 ether);
        memecoin.approve(address(guardedRouter), type(uint256).max);
        uAsset.approve(address(guardedRouter), type(uint256).max);
        localLauncher.setMemeverseUniswapHook(address(guardedHook));
        localLauncher.setMemeverseSwapRouter(address(guardedRouter));
        localLauncher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        localLauncher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        localLauncher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(localLauncher))));
        localLauncher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));

        localLauncher.changeStage(verseId);

        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        guardedRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        // Equivalent public routes that bypass the router still hit the production hook gate.
        vm.prank(address(guardedManager));
        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        guardedHook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        vm.warp(block.timestamp + 24 hours);
        BalanceDelta routerDelta = guardedRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        vm.prank(address(guardedManager));
        guardedHook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );
        assertLt(routerDelta.amount0(), 0, "router input");
    }

    function testUnlockSettlementAllowsPublicLiquidityRedemptionsDuringSettlement() external {
        uint256 verseId = 3;
        _setLockedVerseReadyToUnlock(verseId);
        _seedAuxiliaryLiquidity(verseId);

        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        RedeemMemecoinLiquidityReenterer reenterer = new RedeemMemecoinLiquidityReenterer();
        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        memecoinLp.mint(address(launcher), 10 ether);
        liquidProof.mint(address(reenterer), 10 ether);
        splitter.setSettleMemecoinLiquidityReentry(address(reenterer), address(launcher), verseId, 4 ether);
        polend.setTotalLeveragedDebt(verseId, 1 ether);
        polend.setSettleAuxiliaryOnGlobalSettlement(address(launcher), true);
        uint256 polendPolBefore = liquidProof.balanceOf(address(polend));
        uint256 polendPtBefore = pt.balanceOf(address(polend));
        uint256 polendUAssetBefore = uAsset.balanceOf(address(polend));

        launcher.changeStage(verseId);

        assertTrue(reenterer.reentryAttempted(), "public memecoin redeem tried during settlement");
        assertTrue(reenterer.reentrySucceeded(), "public memecoin redeem allowed during settlement");
        assertEq(memecoinLp.balanceOf(address(reenterer)), 4 ether, "public caller received LP");
        assertEq(liquidProof.balanceOf(address(reenterer)), 6 ether, "public caller POL burned");
        assertGt(liquidProof.balanceOf(address(polend)), polendPolBefore, "polend POL settlement allowed");
        assertGt(pt.balanceOf(address(polend)), polendPtBefore, "polend PT settlement allowed");
        assertGt(uAsset.balanceOf(address(polend)), polendUAssetBefore, "polend uAsset settlement allowed");
    }

    function testUnlockSettlementAllowsPublicAuxiliaryRedeemDuringSplitterSettlement() external {
        uint256 verseId = 4;
        _setLockedVerseReadyToUnlock(verseId);
        _seedAuxiliaryLiquidity(verseId);
        splitter.setSettleReentry(address(launcher), verseId);

        launcher.changeStage(verseId);

        assertTrue(splitter.reentryAttempted(), "public auxiliary redeem tried during settlement");
        assertTrue(splitter.reentrySucceeded(), "public auxiliary redeem allowed during settlement");
        assertEq(polUAssetLp.balanceOf(address(splitter)), 12 ether, "public auxiliary LP redeemed");
    }

    function testPolSplitterCanRedeemMemecoinLiquidityDuringUnlockSettlement() external {
        uint256 verseId = 5;
        SplitterMemecoinRedeemDuringSettle localSplitter =
            new SplitterMemecoinRedeemDuringSettle(address(pt), address(yt), 2 ether);
        MockPOLendForLifecycle localPolend = new MockPOLendForLifecycle();
        IMemeverseLauncher localLauncher = _newLauncher(localPolend, localSplitter);
        MockSwapRouter localRouter = _wireLauncher(localLauncher, localPolend);
        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        localRouter.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        _setLockedVerseReadyToUnlock(localLauncher, verseId);
        memecoinLp.mint(address(localLauncher), 10 ether);
        liquidProof.mint(address(localSplitter), 2 ether);

        localLauncher.changeStage(verseId);

        assertTrue(localSplitter.redeemAttempted(), "splitter redeem tried during settlement");
        assertTrue(localSplitter.redeemSucceeded(), "splitter redeem allowed during settlement");
        assertEq(localSplitter.redeemedLpAmount(), 2 ether, "splitter redeemed lp amount");
        assertEq(memecoinLp.balanceOf(address(localSplitter)), 2 ether, "splitter received lp");
    }

    function testPOLendCanRedeemMemecoinLiquidityDuringUnlockSettlement() external {
        uint256 verseId = 6;
        MockPOLSplitterForLifecycle localSplitter = new MockPOLSplitterForLifecycle(address(pt), address(yt));
        POLendMemecoinRedeemDuringSettlement localPolend = new POLendMemecoinRedeemDuringSettlement(2 ether);
        address localProxy = _deployLauncherProxy(address(localPolend), address(localSplitter));
        IMemeverseLauncher localLauncher = IMemeverseLauncher(localProxy);
        MockSwapRouter localRouter = _wireLauncher(localLauncher, localPolend);
        MockERC20 memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        localRouter.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        _setLockedVerseReadyToUnlock(localLauncher, verseId);
        memecoinLp.mint(address(localLauncher), 10 ether);
        liquidProof.mint(address(localPolend), 2 ether);

        localLauncher.changeStage(verseId);

        assertTrue(localPolend.redeemAttempted(), "polend redeem tried during settlement");
        assertTrue(localPolend.redeemSucceeded(), "polend redeem allowed during settlement");
        assertEq(localPolend.redeemedLpAmount(), 2 ether, "polend redeemed lp amount");
        assertEq(memecoinLp.balanceOf(address(localPolend)), 2 ether, "polend received lp");
    }

    function _setLockedVerseReadyToUnlock(uint256 verseId) internal {
        _setLockedVerseReadyToUnlock(launcher, verseId);
    }

    function _setLockedVerseReadyToUnlock(IMemeverseLauncher targetLauncher, uint256 verseId) internal {
        address proxy = address(targetLauncher);
        setMemeverseForTest(
            proxy,
            verseId,
            address(uAsset),
            address(memecoin),
            address(liquidProof),
            address(0xD00D),
            address(0xCAFE),
            address(0),
            0,
            uint128(block.timestamp - 1),
            IMemeverseLauncher.Stage.Locked,
            false
        );
        setOmnichainIdsForTest(proxy, verseId, _array(uint32(block.chainid)));
    }

    function _seedAuxiliaryLiquidity(uint256 verseId) internal {
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        setUserGenesisDataForTest(launcherProxy, verseId, address(splitter), 24 ether, false, false);
        setAuxiliaryLiquiditiesForTest(launcherProxy, verseId, 60 ether, 30 ether, 90 ether);
        polUAssetLp.mint(address(launcher), 60 ether);
        ptUAssetLp.mint(address(launcher), 30 ether);
        ptPolLp.mint(address(launcher), 90 ether);
        router.setRemoveLiquidityResult(address(liquidProof), address(uAsset), 12 ether, 24 ether);
        router.setRemoveLiquidityResult(address(pt), address(uAsset), 30 ether, 60 ether);
        router.setRemoveLiquidityResult(address(pt), address(liquidProof), 90 ether, 0);
    }

    function _assertResumeTime(PoolKey memory key, uint40 expectedResumeTime, string memory label) internal view {
        MockPreorderSettlementHookForLauncherTest hook =
            MockPreorderSettlementHookForLauncherTest(address(IMemeverseSwapRouter(address(router)).hook()));
        assertEq(hook.publicSwapResumeTime(PoolId.unwrap(key.toId())), expectedResumeTime, label);
    }

    function _hookPoolKey(address hook) internal view returns (PoolKey memory key) {
        return _hookPoolKey(hook, address(memecoin), address(uAsset));
    }

    function _hookPoolKey(address hook, address tokenA, address tokenB) internal pure returns (PoolKey memory key) {
        address token0 = tokenA < tokenB ? tokenA : tokenB;
        address token1 = tokenA < tokenB ? tokenB : tokenA;
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
    }

    function _initializeHookPool(
        MemeverseUniswapHook targetHook,
        MockPoolManagerForRouterTest targetManager,
        address tokenA,
        address tokenB
    ) internal {
        PoolKey memory targetKey = _hookPoolKey(address(targetHook), tokenA, tokenB);
        targetHook.authorizePoolInitialization(targetKey, 79_228_162_514_264_337_593_543_950_336);
        targetManager.initialize(targetKey, 79_228_162_514_264_337_593_543_950_336);
    }

    function _array(uint32 value) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = value;
    }

    function _deployLauncherProxy(address polendAddr, address splitterAddr) internal returns (address proxy) {
        MemeverseLauncher impl = new MemeverseLauncher();
        proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncher.initialize,
                    (
                        address(this),
                        address(0x1),
                        address(0x2),
                        address(0x3),
                        address(0x4),
                        address(0x5),
                        polendAddr,
                        splitterAddr,
                        25,
                        115_000,
                        135_000,
                        2_500,
                        7 days
                    )
                )
            )
        );
    }

    function _newLauncher(MockPOLendForLifecycle targetPolend, SplitterMemecoinRedeemDuringSettle targetSplitter)
        internal
        returns (IMemeverseLauncher targetLauncher)
    {
        address proxy = _deployLauncherProxy(address(targetPolend), address(targetSplitter));
        targetLauncher = IMemeverseLauncher(proxy);
    }

    function _wireLauncher(IMemeverseLauncher targetLauncher, MockPOLendForLifecycle targetPolend)
        internal
        returns (MockSwapRouter targetRouter)
    {
        targetRouter = new MockSwapRouter(address(targetLauncher));
        targetLauncher.setMemeverseUniswapHook(address(targetRouter.hook()));
        targetLauncher.setMemeverseSwapRouter(address(targetRouter));
        targetLauncher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        targetLauncher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        targetLauncher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(targetLauncher))));
        targetLauncher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        targetLauncher.setYieldDispatcher(address(dispatcher));
        targetLauncher.setMemeverseProxyDeployer(address(proxyDeployer));
        targetLauncher.setLzEndpointRegistry(address(registry));
        targetPolend.setLendMarket(address(pt), address(yt));
    }

    function _wireLauncher(IMemeverseLauncher targetLauncher, POLendMemecoinRedeemDuringSettlement targetPolend)
        internal
        returns (MockSwapRouter targetRouter)
    {
        targetRouter = new MockSwapRouter(address(targetLauncher));
        targetLauncher.setMemeverseUniswapHook(address(targetRouter.hook()));
        targetLauncher.setMemeverseSwapRouter(address(targetRouter));
        targetLauncher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        targetLauncher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        targetLauncher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(targetLauncher))));
        targetLauncher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        targetLauncher.setYieldDispatcher(address(dispatcher));
        targetLauncher.setMemeverseProxyDeployer(address(proxyDeployer));
        targetLauncher.setLzEndpointRegistry(address(registry));
        targetPolend.setLendMarket(address(pt), address(yt));
    }
}

contract SplitterMemecoinRedeemDuringSettle {
    address internal immutable pt;
    address internal immutable yt;
    uint256 internal immutable amountInPOL;
    bool public redeemAttempted;
    bool public redeemSucceeded;
    uint256 public redeemedLpAmount;
    bytes public redeemRevertData;

    constructor(address pt_, address yt_, uint256 amountInPOL_) {
        pt = pt_;
        yt = yt_;
        amountInPOL = amountInPOL_;
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, address(0), address(0), address(0), 0, 0, 0, 0, 0, false);
    }

    function getPT(uint256) external view returns (address) {
        return pt;
    }

    function getYT(uint256) external view returns (address) {
        return yt;
    }

    function getMemecoin(uint256) external pure returns (address) {
        return address(0);
    }

    function getPTAndYT(uint256) external view returns (address, address) {
        return (pt, yt);
    }

    function getPTSettlementState(uint256) external view returns (address, bool) {
        return (pt, false);
    }

    function settle(uint256 verseId) external returns (uint256 settlementUAsset, uint256 settlementMemecoin) {
        redeemAttempted = true;
        try IMemeverseLauncher(msg.sender).redeemMemecoinLiquidity(verseId, amountInPOL, false) returns (
            uint256 amountInLP
        ) {
            redeemSucceeded = true;
            redeemedLpAmount = amountInLP;
        } catch (bytes memory reason) {
            redeemRevertData = reason;
        }
        return (0, 0);
    }
}

contract POLendMemecoinRedeemDuringSettlement {
    uint256 internal immutable amountInPOL;
    bool public redeemAttempted;
    bool public redeemSucceeded;
    uint256 public redeemedLpAmount;
    bytes public redeemRevertData;

    constructor(uint256 amountInPOL_) {
        amountInPOL = amountInPOL_;
    }

    function setLendMarket(address, address) external {}

    function executeGlobalSettlement(uint256 verseId) external {
        redeemAttempted = true;
        try IMemeverseLauncher(msg.sender).redeemMemecoinLiquidity(verseId, amountInPOL, false) returns (
            uint256 amountInLP
        ) {
            redeemSucceeded = true;
            redeemedLpAmount = amountInLP;
        } catch (bytes memory reason) {
            redeemRevertData = reason;
        }
    }

    function getTotalLeveragedDebt(uint256) external pure returns (uint256) {
        return 1 ether;
    }
}
