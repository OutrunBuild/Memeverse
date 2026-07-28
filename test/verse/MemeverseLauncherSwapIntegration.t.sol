// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {RealisticSwapManagerHarness} from "../swap/helpers/RealisticSwapManagerHarness.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MockOFTDispatcher} from "../mocks/verse/LauncherLifecycleMocks.sol";
import {
    MockIntegrationLiquidProof,
    MockIntegrationMemecoin,
    MockLauncherIntegrationLzEndpointRegistry,
    MockPOLendForPreorderIntegration,
    MockPOLSplitterForPreorderIntegration
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";
import {
    MockLauncherSwapIntegrationProxyDeployer,
    MockPOLendForSwapIntegration
} from "../mocks/verse/LauncherSwapIntegrationMocks.sol";

contract DirectPoolManagerSwapHelper is IUnlockCallback {
    RealisticSwapManagerHarness internal immutable manager;

    constructor(RealisticSwapManagerHarness manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");

        (PoolKey memory key, SwapParams memory params) = abi.decode(rawData, (PoolKey, SwapParams));
        return abi.encode(manager.swap(key, params, ""));
    }
}

contract MemeverseLauncherSwapIntegrationTest is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant VERSE_ID = 1;
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant TREASURY = address(0x7EA5);

    RealisticSwapManagerHarness internal manager;
    DirectPoolManagerSwapHelper internal directSwapHelper;
    MemeverseUniswapHook internal hook;
    MemeverseSwapRouter internal router;
    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockLauncherSwapIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    MockOFTDispatcher internal dispatcher;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;
    MockPOLendForPreorderIntegration internal polend;
    MockPOLSplitterForPreorderIntegration internal splitter;

    function setUp() external {
        manager = new RealisticSwapManagerHarness();
        proxyDeployer = new MockLauncherSwapIntegrationProxyDeployer(address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        dispatcher = new MockOFTDispatcher();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForSwapIntegration();
        splitter = new MockPOLSplitterForPreorderIntegration(address(pt), address(yt));
        MemeverseLauncher impl = new MemeverseLauncher();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncher.initialize,
                    (
                        address(this),
                        address(0x1111),
                        REGISTRAR,
                        address(0x3333),
                        address(0x4444),
                        address(0x5555),
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
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        // hookOwner = address(this), treasury = TREASURY.
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), TREASURY);
        hook = MemeverseUniswapHook(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0))
        );

        hook.setLauncher(address(launcher));
        hook.setPoolInitializer(address(router));

        launcher.setMemeverseUniswapHook(address(hook));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        assertEq(address(router.hook()), address(hook), "router hook");
        assertEq(hook.launcher(), address(launcher), "hook launcher");
        assertEq(hook.poolInitializer(), address(router), "hook initializer");
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setLendMarket(address(pt), address(yt));

        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = uint32(block.chainid);
        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            VERSE_ID,
            uint128(block.timestamp + 30 days),
            uint128(block.timestamp + 60 days),
            omnichainIds,
            address(uAsset),
            true
        );

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.pol), true);

        uAsset.mint(ALICE, 250 ether);
        uAsset.mint(BOB, 100 ether);

        vm.prank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(BOB);
        uAsset.approve(address(launcher), type(uint256).max);

        directSwapHelper = new DirectPoolManagerSwapHelper(manager);
    }

    function testExecutePreorderSettlement_RealRouterHookManagerPath_AllowsBootstrapDust() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();

        (uint256 totalFunds, uint256 settledMemecoin, uint40 settlementTimestamp) =
            getPreorderStateForTest(launcherProxy, VERSE_ID);

        assertEq(uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "stage");
        assertEq(totalFunds, 30 ether, "preorder total funds");
        assertEq(settlementTimestamp, block.timestamp, "settlement timestamp");
        assertGt(settledMemecoin, 0, "settled memecoin");
        uint256 launcherMemecoinBalance = MockIntegrationMemecoin(verse.memecoin).balanceOf(address(launcher));
        assertGe(launcherMemecoinBalance, settledMemecoin, "launcher received settlement output");
        assertLe(launcherMemecoinBalance - settledMemecoin, 1, "launcher memecoin dust bounded");
        assertGt(uAsset.balanceOf(TREASURY), 0, "treasury received launch protocol fee");

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(ALICE);
        uint256 aliceClaimed = launcher.claimUnlockedPreorderMemecoin(VERSE_ID);
        vm.prank(BOB);
        uint256 bobClaimed = launcher.claimUnlockedPreorderMemecoin(VERSE_ID);

        uint256 launcherMemecoinAfterClaims = MockIntegrationMemecoin(verse.memecoin).balanceOf(address(launcher));
        assertEq(
            aliceClaimed + bobClaimed + launcherMemecoinAfterClaims,
            launcherMemecoinBalance,
            "settlement assets conserved through claims"
        );
        assertEq(
            launcherMemecoinAfterClaims,
            launcherMemecoinBalance - aliceClaimed - bobClaimed,
            "launcher retained only preexisting dust"
        );
    }

    function testMintPOLToken_RealRouterPath_MintsPOLWithExactLiquidity() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(BOB);
        address memecoinLp = router.lpToken(verse.memecoin, verse.uAsset);
        uint128 desiredLiquidity = 0.1 ether;
        (uint256 uAssetBudget, uint256 memecoinBudget) =
            router.quoteExactAmountsForLiquidity(verse.uAsset, verse.memecoin, desiredLiquidity);

        vm.prank(BOB);
        MockIntegrationMemecoin(verse.memecoin).approve(address(launcher), type(uint256).max);

        uint256 bobUAssetBefore = uAsset.balanceOf(BOB);
        uint256 bobMemecoinBefore = MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB);
        uint256 bobPolBefore = MockIntegrationLiquidProof(verse.pol).balanceOf(BOB);
        uint256 launcherLpBefore = MockERC20(memecoinLp).balanceOf(address(launcher));

        vm.prank(BOB);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(VERSE_ID, uAssetBudget, memecoinBudget, 0, 0, desiredLiquidity, block.timestamp);

        assertLe(amountInUAsset, uAssetBudget, "uAsset spend bounded by budget");
        assertLe(amountInMemecoin, memecoinBudget, "memecoin spend bounded by budget");
        assertEq(amountOut, desiredLiquidity, "desired POL minted");
        assertEq(uAsset.balanceOf(BOB), bobUAssetBefore - amountInUAsset, "payer uAsset debited");
        assertEq(
            MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB),
            bobMemecoinBefore - amountInMemecoin,
            "payer memecoin debited"
        );
        assertEq(
            MockIntegrationLiquidProof(verse.pol).balanceOf(BOB),
            bobPolBefore + desiredLiquidity,
            "recipient POL minted"
        );
        assertEq(
            MockERC20(memecoinLp).balanceOf(address(launcher)),
            launcherLpBefore + desiredLiquidity,
            "launcher LP increased"
        );
    }

    function testMintPOLToken_RealRouterPath_MintsSmallExactLiquidity() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(BOB);

        uint128 desiredLiquidity = 1;
        (uint256 quotedUAsset, uint256 quotedMemecoin) =
            router.quoteAmountsForLiquidity(verse.uAsset, verse.memecoin, desiredLiquidity);

        uint256 uAssetBudget = quotedUAsset + 1;
        uint256 memecoinBudget = quotedMemecoin + 1;

        vm.prank(BOB);
        MockIntegrationMemecoin(verse.memecoin).approve(address(launcher), type(uint256).max);

        uint256 bobUAssetBefore = uAsset.balanceOf(BOB);
        uint256 bobMemecoinBefore = MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB);

        vm.prank(BOB);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(VERSE_ID, uAssetBudget, memecoinBudget, 0, 0, desiredLiquidity, block.timestamp);

        assertEq(amountOut, desiredLiquidity, "small exact POL minted");
        assertLe(amountInUAsset, uAssetBudget, "small uAsset spend bounded by budget");
        assertLe(amountInMemecoin, memecoinBudget, "small memecoin spend bounded by budget");
        assertEq(uAsset.balanceOf(BOB), bobUAssetBefore - amountInUAsset, "small uAsset debited");
        assertEq(
            MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB),
            bobMemecoinBefore - amountInMemecoin,
            "small memecoin debited"
        );
    }

    function testMintPOLToken_RealRouterPath_RevertsWhenPriceMovesAfterExactLiquidityQuote() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(BOB);

        uint128 desiredLiquidity = 0.1 ether;
        (uint256 quotedUAsset, uint256 quotedMemecoin) =
            router.quoteExactAmountsForLiquidity(verse.uAsset, verse.memecoin, desiredLiquidity);
        PoolKey memory key = router.getHookPoolKey(verse.uAsset, verse.memecoin);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        manager.setCallerSlot0OverrideX96(key.toId(), address(hook), uint160((uint256(sqrtPriceX96) * 120) / 100));

        vm.prank(BOB);
        MockIntegrationMemecoin(verse.memecoin).approve(address(launcher), type(uint256).max);

        vm.expectRevert(IMemeverseUniswapHook.TooMuchSlippage.selector);
        vm.prank(BOB);
        launcher.mintPOLToken(VERSE_ID, quotedUAsset, quotedMemecoin, 0, 0, desiredLiquidity, block.timestamp);
    }

    function testMintPOLToken_RealRouterPath_AutoLiquiditySucceedsWhenUAssetSortsAfterMemecoin() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(BOB);

        address memecoinLp = router.lpToken(verse.memecoin, verse.uAsset);
        uint128 quotedLiquidity = 0.1 ether;
        (uint256 quotedUAsset, uint256 quotedMemecoin) =
            router.quoteAmountsForLiquidity(verse.uAsset, verse.memecoin, quotedLiquidity);
        uint256 uAssetBudget = quotedUAsset;
        uint256 memecoinBudget = quotedMemecoin + 0.01 ether;

        vm.prank(BOB);
        MockIntegrationMemecoin(verse.memecoin).approve(address(launcher), type(uint256).max);

        uint256 bobUAssetBefore = uAsset.balanceOf(BOB);
        uint256 bobMemecoinBefore = MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB);
        uint256 bobPolBefore = MockIntegrationLiquidProof(verse.pol).balanceOf(BOB);
        uint256 launcherLpBefore = MockERC20(memecoinLp).balanceOf(address(launcher));

        vm.prank(BOB);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(VERSE_ID, uAssetBudget, memecoinBudget, 0, 0, 0, block.timestamp);

        assertLe(amountInUAsset, uAssetBudget, "uAsset spend bounded by budget");
        assertLt(amountInMemecoin, memecoinBudget, "memecoin excess refunded");
        assertGt(amountOut, 0, "auto-liquidity minted POL");
        assertEq(uAsset.balanceOf(BOB), bobUAssetBefore - amountInUAsset, "auto path uAsset debited");
        assertEq(
            MockIntegrationMemecoin(verse.memecoin).balanceOf(BOB),
            bobMemecoinBefore - amountInMemecoin,
            "auto path memecoin debited"
        );
        assertEq(
            MockIntegrationLiquidProof(verse.pol).balanceOf(BOB),
            bobPolBefore + amountOut,
            "auto path recipient POL minted"
        );
        assertEq(
            MockERC20(memecoinLp).balanceOf(address(launcher)),
            launcherLpBefore + amountOut,
            "auto path launcher LP increased"
        );
    }

    function testLockedPublicSwaps_RealRouterPath_AllowedDuringLockedStage() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(ALICE);
        _claimUnlockedPreorderMemecoin(BOB);

        vm.prank(address(launcher));
        MockIntegrationLiquidProof(verse.pol).mint(ALICE, 1 ether);

        _approveRouter(ALICE, verse.memecoin);
        _approveRouter(ALICE, verse.pol);
        _approveRouter(ALICE, verse.uAsset);
        _approveRouter(BOB, verse.memecoin);
        _approveRouter(BOB, verse.uAsset);

        // Open one smart-EOA session as the test contract (has code) to span all swaps below: the hook's
        // beforeSwap session gate precedes the public-swap gate, so without a session every swap reverts
        // AccountSessionNotActive. The pranked trader stays the router's msg.sender; only the session principal
        // (address(this)) is read by the hook. Transient session state auto-clears at the test call's end.
        hook.beginAccountSession();
        // Locked stage allows swaps — no protection window is set.
        _swapExactInput(BOB, verse.memecoin, verse.uAsset, 1 ether);
        _swapExactInput(ALICE, verse.pol, verse.uAsset, 1 ether);
    }

    function testUnlockedPublicSwaps_RealRouterPath_BlockedDuringProtectionAndAllowedAfterResume() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();
        _claimUnlockedPreorderMemecoin(ALICE);
        _claimUnlockedPreorderMemecoin(BOB);

        vm.prank(address(launcher));
        MockIntegrationLiquidProof(verse.pol).mint(ALICE, 4 ether);
        pt.mint(ALICE, 4 ether);

        _approveRouter(ALICE, address(pt));
        _approveRouter(ALICE, verse.pol);
        _approveRouter(ALICE, verse.uAsset);
        _approveRouter(BOB, verse.memecoin);
        _approveRouter(BOB, verse.uAsset);

        vm.warp(uint256(verse.unlockTime) + 1);
        launcher.changeStage(VERSE_ID);

        uint40 resumeTime = uint40(block.timestamp + 24 hours);
        _assertPublicSwapResumeTime(verse.memecoin, verse.uAsset, resumeTime, "memecoin/uAsset resume time");
        _assertPublicSwapResumeTime(verse.pol, verse.uAsset, resumeTime, "POL/uAsset resume time");
        _assertPublicSwapResumeTime(address(pt), verse.uAsset, resumeTime, "PT/uAsset resume time");
        _assertPublicSwapResumeTime(address(pt), verse.pol, resumeTime, "PT/POL resume time");

        // Open one smart-EOA session as the test contract to span both the blocked-swap reverts and the
        // post-resume successes below. Each `vm.expectRevert` only unwinds its own `router.swap` call frame
        // (rolling back that swap's transient SwapContext), NOT the session principal written here; so one
        // begin covers all four reverts and the four later successes. Without it, the session gate reverts
        // AccountSessionNotActive before the asserted PublicSwapDisabled gate is reached.
        hook.beginAccountSession();
        bytes4 selector = IMemeverseUniswapHook.PublicSwapDisabled.selector;
        _expectSwapExactInputRevert(BOB, verse.memecoin, verse.uAsset, 0.1 ether, selector);
        _expectSwapExactInputRevert(ALICE, verse.pol, verse.uAsset, 0.1 ether, selector);
        _expectSwapExactInputRevert(ALICE, address(pt), verse.uAsset, 0.1 ether, selector);
        _expectSwapExactInputRevert(ALICE, address(pt), verse.pol, 0.1 ether, selector);

        vm.warp(resumeTime);
        _swapExactInput(BOB, verse.memecoin, verse.uAsset, 0.1 ether);
        _swapExactInput(ALICE, verse.pol, verse.uAsset, 0.1 ether);
        _swapExactInput(ALICE, address(pt), verse.uAsset, 0.1 ether);
        _swapExactInput(ALICE, address(pt), verse.pol, 0.1 ether);
    }

    function testUnlockedPublicSwaps_RealRouterPath_DirectPoolManagerBypassBlockedDuringProtection() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();

        vm.warp(uint256(verse.unlockTime) + 1);
        launcher.changeStage(VERSE_ID);

        uint40 resumeTime = uint40(block.timestamp + 24 hours);
        _assertPublicSwapResumeTime(verse.memecoin, verse.uAsset, resumeTime, "memecoin/uAsset resume time");
        _assertPublicSwapResumeTime(verse.pol, verse.uAsset, resumeTime, "POL/uAsset resume time");
        _assertPublicSwapResumeTime(address(pt), verse.uAsset, resumeTime, "PT/uAsset resume time");
        _assertPublicSwapResumeTime(address(pt), verse.pol, resumeTime, "PT/POL resume time");

        // Open one smart-EOA session as the test contract to span all four direct-swap reverts. The direct
        // manager.swap path bypasses the router but still reaches the hook's beforeSwap, where the session
        // gate precedes the public-swap gate. Each `vm.expectRevert` unwinds only its own swap frame's
        // transient SwapContext, not this session principal, so one begin covers all four reverts.
        hook.beginAccountSession();
        bytes4 selector = IMemeverseUniswapHook.PublicSwapDisabled.selector;
        _expectDirectSwapExactInputRevert(verse.memecoin, verse.uAsset, 0.1 ether, selector);
        _expectDirectSwapExactInputRevert(verse.pol, verse.uAsset, 0.1 ether, selector);
        _expectDirectSwapExactInputRevert(address(pt), verse.uAsset, 0.1 ether, selector);
        _expectDirectSwapExactInputRevert(address(pt), verse.pol, 0.1 ether, selector);
    }

    function testUnlockedPublicSwaps_RealRouterPath_ExecutePreorderSettlementSpoofBlockedDuringProtection() external {
        IMemeverseLauncher.Memeverse memory verse = _lockVerseWithLiquidity();

        vm.warp(uint256(verse.unlockTime) + 1);
        launcher.changeStage(VERSE_ID);

        PoolKey memory key = router.getHookPoolKey(verse.memecoin, verse.uAsset);
        bool zeroForOne = Currency.unwrap(key.currency0) == verse.uAsset;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseUniswapHook.Unauthorized.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                recipient: ALICE
            })
        );
    }

    function _lockVerseWithLiquidity() internal returns (IMemeverseLauncher.Memeverse memory verse) {
        vm.prank(ALICE);
        launcher.genesis(VERSE_ID, 200 ether, ALICE);

        vm.prank(ALICE);
        launcher.preorder(VERSE_ID, 10 ether, ALICE);
        vm.prank(BOB);
        launcher.preorder(VERSE_ID, 20 ether, BOB);

        launcher.changeStage(VERSE_ID);
        verse = launcher.getMemeverseByVerseId(VERSE_ID);
    }

    function _claimUnlockedPreorderMemecoin(address account) internal {
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(account);
        launcher.claimUnlockedPreorderMemecoin(VERSE_ID);
    }

    function _approveRouter(address owner, address token) internal {
        vm.prank(owner);
        MockERC20(token).approve(address(router), type(uint256).max);
    }

    function _assertPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime, string memory label)
        internal
        view
    {
        PoolKey memory key = router.getHookPoolKey(tokenA, tokenB);
        assertEq(hook.publicSwapResumeTime(key.toId()), resumeTime, label);
    }

    function _swapExactInput(address trader, address tokenIn, address tokenOut, uint256 amountIn) internal {
        PoolKey memory key = router.getHookPoolKey(tokenIn, tokenOut);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            trader,
            block.timestamp,
            0,
            amountIn,
            ""
        );
    }

    function _expectSwapExactInputRevert(
        address trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes4 selector
    ) internal {
        PoolKey memory key = router.getHookPoolKey(tokenIn, tokenOut);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(trader);
        vm.expectRevert(selector);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            trader,
            block.timestamp,
            0,
            amountIn,
            ""
        );
    }

    function _expectDirectSwapExactInputRevert(address tokenIn, address tokenOut, uint256 amountIn, bytes4 selector)
        internal
    {
        PoolKey memory key = router.getHookPoolKey(tokenIn, tokenOut);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.expectRevert(selector);
        directSwapHelper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
    }
}
