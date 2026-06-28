// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {
    MockIntegrationLiquidProof,
    MockLauncherIntegrationLzEndpointRegistry,
    MockLauncherIntegrationProxyDeployer,
    MockPOLendForPreorderIntegration,
    MockPOLSplitterForPreorderIntegration
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";

contract MemeverseLauncherPreorderIntegrationTest is Test, HookStorageHelper {
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint32 internal constant REMOTE_GOV_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseSwapRouter internal router;
    MemeverseLauncher internal launcher;
    MockLauncherIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    MockPOLendForPreorderIntegration internal polend;
    MockPOLSplitterForPreorderIntegration internal splitter;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;

    /// @notice Test helper for setUp.
    function setUp() external {
        manager = new MockPoolManagerForRouterTest();
        proxyDeployer = new MockLauncherIntegrationProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForPreorderIntegration();
        splitter = new MockPOLSplitterForPreorderIntegration(address(pt), address(yt));
        MemeverseLauncher launcherImplementation = new MemeverseLauncher();
        bytes memory launcherInitData = abi.encodeCall(
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
        );
        launcher = MemeverseLauncher(address(new ERC1967Proxy(address(launcherImplementation), launcherInitData)));
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        // hookOwner = address(this), treasury = address(this), engine bound to the hook proxy.
        (address hookProxy,) = deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), address(this));
        hook = MemeverseUniswapHook(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0xBEEF))
        );
        hook.setLauncher(address(launcher));
        hook.setPoolInitializer(address(router));

        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        assertEq(address(router.hook()), address(hook), "router hook");
        assertEq(hook.launcher(), address(launcher), "hook launcher");
        assertEq(hook.poolInitializer(), address(router), "hook initializer");
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setLendMarket(address(pt), address(yt));

        registry.setEndpoint(REMOTE_GOV_CHAIN_ID, REMOTE_EID);

        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = REMOTE_GOV_CHAIN_ID;
        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            1,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 30 days),
            omnichainIds,
            address(uAsset),
            true
        );

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(1);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)));
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin));

        uAsset.mint(ALICE, 210 ether);
        uAsset.mint(BOB, 20 ether);

        vm.prank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(BOB);
        uAsset.approve(address(launcher), type(uint256).max);
    }

    /// @notice Verifies the real launcher-router-hook path settles preorder through the launch marker and distributes linearly.
    /// @dev Uses the real router and hook with the mock pool manager instead of the lifecycle swap mock.
    function testPreorderSettlement_RealLauncherRouterHookPath() external {
        vm.prank(ALICE);
        launcher.genesis(1, 10 ether, ALICE);

        vm.prank(ALICE);
        launcher.preorder(1, 1 ether, ALICE);
        vm.prank(BOB);
        launcher.preorder(1, 0.5 ether, BOB);

        IMemeverseLauncher.Memeverse memory verseBefore = launcher.getMemeverseByVerseId(1);
        vm.prank(address(launcher));
        MockIntegrationLiquidProof(verseBefore.pol).mint(address(this), 300 ether);
        pt.mint(address(this), 200 ether);
        uAsset.mint(address(this), 300 ether);
        MockERC20(verseBefore.pol).approve(address(router), type(uint256).max);
        pt.approve(address(router), type(uint256).max);
        uAsset.approve(address(router), type(uint256).max);
        hook.setLauncher(address(this));
        router.createPoolAndAddLiquidity(
            verseBefore.pol, address(uAsset), 100 ether, 100 ether, uint160(1 << 96), address(this), block.timestamp
        );
        router.createPoolAndAddLiquidity(
            address(pt), address(uAsset), 50 ether, 50 ether, uint160(1 << 96), address(this), block.timestamp
        );
        router.createPoolAndAddLiquidity(
            address(pt), verseBefore.pol, 50 ether, 50 ether, uint160(1 << 96), address(this), block.timestamp
        );
        hook.setLauncher(address(launcher));
        uint256 treasuryUAssetBalanceBefore = uAsset.balanceOf(address(this));

        IMemeverseLauncher.Stage stage = launcher.changeStage(1);
        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "locked");

        uint256 treasuryUAssetBalance = uAsset.balanceOf(address(this)) - treasuryUAssetBalanceBefore;
        assertEq(treasuryUAssetBalance, 0.00525 ether, "treasury received fixed 0.35% protocol fee");

        vm.warp(block.timestamp + 3 days + 12 hours);

        vm.prank(ALICE);
        uint256 aliceHalf = launcher.claimablePreorderMemecoin(1);
        vm.prank(BOB);
        uint256 bobHalf = launcher.claimablePreorderMemecoin(1);

        assertEq(aliceHalf, 0.2475 ether, "alice half claimable");
        assertEq(bobHalf, 0.12375 ether, "bob half claimable");

        vm.warp(block.timestamp + 3 days + 12 hours + 1);

        vm.prank(ALICE);
        uint256 aliceClaimed = launcher.claimUnlockedPreorderMemecoin(1);
        vm.prank(BOB);
        uint256 bobClaimed = launcher.claimUnlockedPreorderMemecoin(1);

        assertEq(aliceClaimed, 0.495 ether, "alice total");
        assertEq(bobClaimed, 0.2475 ether, "bob total");
        assertEq(MockERC20(verseBefore.memecoin).balanceOf(ALICE), 0.495 ether, "alice memecoin");
        assertEq(MockERC20(verseBefore.memecoin).balanceOf(BOB), 0.2475 ether, "bob memecoin");
    }
}
