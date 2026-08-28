// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {
    MockIntegrationLiquidProof,
    MockLauncherIntegrationProxyDeployer,
    MockPOLendForPreorderIntegration,
    MockPOLSplitterForPreorderIntegration
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";
import {LzEndpointRegistryMock} from "../mocks/common/LzEndpointRegistryMock.sol";

contract MemeverseLauncherPreorderIntegrationTest is Test, HookStorageHelper {
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint32 internal constant REMOTE_GOV_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseSwapRouter internal router;
    MemeverseLauncherUpgradeable internal launcher;
    MockLauncherIntegrationProxyDeployer internal proxyDeployer;
    LzEndpointRegistryMock internal registry;
    MockPOLendForPreorderIntegration internal polend;
    MockPOLSplitterForPreorderIntegration internal splitter;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;

    /// @notice Test helper for setUp.
    function setUp() external {
        manager = new MockPoolManagerForRouterTest();
        proxyDeployer = new MockLauncherIntegrationProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new LzEndpointRegistryMock();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForPreorderIntegration();
        splitter = new MockPOLSplitterForPreorderIntegration(address(pt), address(yt));
        MemeverseLauncherUpgradeable launcherImplementation = new MemeverseLauncherUpgradeable();
        bytes memory launcherInitData = abi.encodeCall(
            MemeverseLauncherUpgradeable.initialize,
            (
                address(this),
                address(0x1111),
                REGISTRAR,
                address(0x3333),
                address(0x4444),
                address(registry),
                address(polend),
                address(splitter),
                25,
                115_000,
                135_000,
                2_500,
                7 days
            )
        );
        launcher =
            MemeverseLauncherUpgradeable(address(new ERC1967Proxy(address(launcherImplementation), launcherInitData)));
        // Real MemeverseUniswapHookUpgradeable deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        // hookOwner = address(this), treasury = address(this).
        address hookProxy =
            deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), address(this), address(launcher));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0xBEEF))
        );
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
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);

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

        _provideLiquiditySettleAndAssert(1);
    }

    /// @notice The combined genesis+preorder entry reaches the same settled state as the two-call path.
    /// @dev Replaces the standalone `genesis` + `preorder` pair with a single `genesisAndPreorder`, then reuses
    ///      the real launcher-router-hook settlement path. Also asserts the combined entry applies both legs'
    ///      accounting and emits `Genesis` then `Preorder` exactly once.
    function testGenesisAndPreorder_SettlesThroughRealLauncherRouterHookPath() external {
        // Genesis then Preorder, emitted in order by the two helpers under the single call.
        vm.expectEmit(true, true, true, true);
        emit IMemeverseLauncher.Genesis(1, ALICE, ALICE, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit IMemeverseLauncher.Preorder(1, ALICE, ALICE, 1 ether);
        vm.prank(ALICE);
        launcher.genesisAndPreorder(1, 10 ether, 1 ether, ALICE);

        vm.prank(BOB);
        launcher.preorder(1, 0.5 ether, BOB);

        // The genesis leg enlarged the preorder base and both legs credited the shared `user`.
        assertEq(launcher.totalNormalFunds(1), 10 ether, "genesis enlarged normal funds");
        (uint256 aliceGenesisFund,,) = launcher.userGenesisData(1, ALICE);
        assertEq(aliceGenesisFund, 10 ether, "alice genesis fund");
        (uint256 alicePreorderFunds,,) = launcher.userPreorderData(1, ALICE);
        assertEq(alicePreorderFunds, 1 ether, "alice preorder funds");
        (uint256 bobPreorderFunds,,) = launcher.userPreorderData(1, BOB);
        assertEq(bobPreorderFunds, 0.5 ether, "bob preorder funds");

        // Both legs debited the shared payer atomically: genesisAmount + preorderAmount left ALICE's balance.
        assertEq(uAsset.balanceOf(ALICE), 199 ether, "alice paid 11e uAsset (10 genesis + 1 preorder)");

        _provideLiquiditySettleAndAssert(1);
    }

    /// @notice A preorder amount over the capacity the genesis leg just opened must revert, and the genesis
    ///         leg's transfer-in and accounting must roll back atomically.
    /// @dev After a 10 ether genesis (totalLeveragedDebt = 0 here), the preorder cap is
    ///      `10e18 * 7 * 2500 / (10 * 10000) = 1.75 ether`. A 2 ether preorder exceeds it, so `_preorder`
    ///      reverts `InvalidLength`; because `_genesis` ran first in the same call, its `totalNormalFunds`
    ///      write, user-genesis credit, and uAsset transfer-in are all undone.
    function testGenesisAndPreorder_RevertWhen_PreorderExceedsCap_RollsBackAtomically() external {
        assertEq(launcher.totalNormalFunds(1), 0, "clean slate");
        uint256 aliceBalanceBefore = uAsset.balanceOf(ALICE);

        vm.expectPartialRevert(IMemeverseLauncher.InvalidLength.selector);
        vm.prank(ALICE);
        launcher.genesisAndPreorder(1, 10 ether, 2 ether, ALICE);

        // Atomic rollback: the genesis leg's effects never partially apply.
        assertEq(launcher.totalNormalFunds(1), 0, "totalNormalFunds rolled back");
        (uint256 aliceGenesisFund,,) = launcher.userGenesisData(1, ALICE);
        assertEq(aliceGenesisFund, 0, "genesis fund rolled back");
        assertEq(uAsset.balanceOf(ALICE), aliceBalanceBefore, "alice uAsset rolled back");
    }

    /// @notice A zero genesis amount is rejected before either leg runs.
    function testGenesisAndPreorder_RevertWhen_GenesisAmountZero() external {
        vm.expectPartialRevert(IMemeverseLauncher.ZeroInput.selector);
        vm.prank(ALICE);
        launcher.genesisAndPreorder(1, 0, 1 ether, ALICE);
    }

    /// @notice A zero preorder amount is rejected before either leg runs.
    function testGenesisAndPreorder_RevertWhen_PreorderAmountZero() external {
        vm.expectPartialRevert(IMemeverseLauncher.ZeroInput.selector);
        vm.prank(ALICE);
        launcher.genesisAndPreorder(1, 10 ether, 0, ALICE);
    }

    /// @notice Shared settlement + linear-vesting claim assertions for the real launcher-router-hook preorder path.
    /// @dev Called by both preorder tests after their test-specific deposit setup. Seeds the three pools, advances
    ///      to Locked, and asserts the fixed 0.35% protocol fee plus the preorder memecoin vesting schedule.
    function _provideLiquiditySettleAndAssert(uint256 verseId) internal {
        IMemeverseLauncher.Memeverse memory verseBefore = launcher.getMemeverseByVerseId(verseId);
        // The launcher is bound to the hook at deploy (initialize), so the launcher proxy — not
        // this contract — must drive `createPoolAndAddLiquidity` (router onlyLauncher). Fund the launcher
        // with the three pool assets and act as it; LP tokens are still minted to this contract (recipient).
        vm.prank(address(launcher));
        MockIntegrationLiquidProof(verseBefore.pol).mint(address(launcher), 300 ether);
        pt.mint(address(launcher), 200 ether);
        uAsset.mint(address(launcher), 300 ether);
        vm.startPrank(address(launcher));
        MockERC20(verseBefore.pol).approve(address(router), type(uint256).max);
        pt.approve(address(router), type(uint256).max);
        uAsset.approve(address(router), type(uint256).max);
        router.createPoolAndAddLiquidity(
            verseBefore.pol, address(uAsset), 100 ether, 100 ether, uint160(1 << 96), address(this), block.timestamp
        );
        router.createPoolAndAddLiquidity(
            address(pt), address(uAsset), 50 ether, 50 ether, uint160(1 << 96), address(this), block.timestamp
        );
        router.createPoolAndAddLiquidity(
            address(pt), verseBefore.pol, 50 ether, 50 ether, uint160(1 << 96), address(this), block.timestamp
        );
        vm.stopPrank();
        uint256 treasuryUAssetBalanceBefore = uAsset.balanceOf(address(this));

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);
        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "locked");

        uint256 treasuryUAssetBalance = uAsset.balanceOf(address(this)) - treasuryUAssetBalanceBefore;
        assertEq(treasuryUAssetBalance, 0.00525 ether, "treasury received fixed 0.35% protocol fee");

        vm.warp(block.timestamp + 3 days + 12 hours);

        vm.prank(ALICE);
        uint256 aliceHalf = launcher.claimablePreorderMemecoin(verseId);
        vm.prank(BOB);
        uint256 bobHalf = launcher.claimablePreorderMemecoin(verseId);

        assertEq(aliceHalf, 0.2475 ether, "alice half claimable");
        assertEq(bobHalf, 0.12375 ether, "bob half claimable");

        vm.warp(block.timestamp + 3 days + 12 hours + 1);

        vm.prank(ALICE);
        uint256 aliceClaimed = launcher.claimUnlockedPreorderMemecoin(verseId);
        vm.prank(BOB);
        uint256 bobClaimed = launcher.claimUnlockedPreorderMemecoin(verseId);

        assertEq(aliceClaimed, 0.495 ether, "alice total");
        assertEq(bobClaimed, 0.2475 ether, "bob total");
        assertEq(MockERC20(verseBefore.memecoin).balanceOf(ALICE), 0.495 ether, "alice memecoin");
        assertEq(MockERC20(verseBefore.memecoin).balanceOf(BOB), 0.2475 ether, "bob memecoin");
    }
}
