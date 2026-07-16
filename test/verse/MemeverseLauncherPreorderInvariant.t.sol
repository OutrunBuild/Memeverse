// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {POLendInvariantStub, POLSplitterInvariantStub} from "../mocks/verse/LauncherInvariantStubs.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {
    MockIntegrationMemecoin,
    MockLauncherIntegrationLzEndpointRegistry,
    MockLauncherIntegrationProxyDeployer
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";

contract MockPOLendForPreorderInvariant is POLendInvariantStub {}

contract MockPOLSplitterForPreorderInvariant is POLSplitterInvariantStub {
    constructor(address pt_, address yt_) POLSplitterInvariantStub(pt_, yt_) {}
}

abstract contract MemeverseLauncherPreorderInvariantBase is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    address internal constant REGISTRAR = address(0xBEEF);
    uint32 internal constant REMOTE_GOV_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;
    uint256 internal constant VERSE_ID = 1;

    address[] internal actors;

    function _setActors(address alice, address bob, address charlie) internal {
        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);
    }

    function _registerVerse(IMemeverseLauncher launcher, address uAsset) internal {
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = REMOTE_GOV_CHAIN_ID;

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            VERSE_ID,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 30 days),
            omnichainIds,
            uAsset,
            false
        );
    }
}

contract PreorderSuccessHandler is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal immutable launcher;
    address internal immutable launcherProxy;
    MockERC20 internal immutable uAsset;
    address[] internal actors;
    uint256 public recordedMemecoinDust;
    bool public memecoinDustRecorded;

    constructor(IMemeverseLauncher _launcher, address _launcherProxy, MockERC20 _uAsset, address[] memory _actors) {
        launcher = _launcher;
        launcherProxy = _launcherProxy;
        uAsset = _uAsset;
        actors = _actors;
    }

    /// @notice Test helper for genesis.
    /// @param actorSeed See implementation.
    /// @param amountSeed See implementation.
    function genesis(uint256 actorSeed, uint256 amountSeed) external {
        if (launcher.getStageByVerseId(VERSE_ID) != IMemeverseLauncher.Stage.Genesis) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = uAsset.balanceOf(actor);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, _min(balance, type(uint128).max));
        vm.prank(actor);
        try launcher.genesis(VERSE_ID, amount, actor) {} catch {}
    }

    /// @notice Test helper for preorder.
    /// @param actorSeed See implementation.
    /// @param amountSeed See implementation.
    function preorder(uint256 actorSeed, uint256 amountSeed) external {
        if (launcher.getStageByVerseId(VERSE_ID) != IMemeverseLauncher.Stage.Genesis) return;

        uint256 capacity = launcher.previewPreorderCapacity(VERSE_ID);
        if (capacity == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = uAsset.balanceOf(actor);
        uint256 maxAmount = _min(capacity, _min(balance, type(uint128).max));
        if (maxAmount == 0) return;

        uint256 amount = bound(amountSeed, 1, maxAmount);
        vm.prank(actor);
        try launcher.preorder(VERSE_ID, amount, actor) {} catch {}
    }

    /// @notice Test helper for warp.
    /// @param deltaSeed See implementation.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 5 days));
    }

    /// @notice Test helper for changeStage.
    function changeStage() external {
        try launcher.changeStage(VERSE_ID) {
            if (!memecoinDustRecorded) {
                (uint256 totalFunds, uint256 settledMemecoin, uint40 settlementTimestamp) =
                    getPreorderStateForTest(launcherProxy, VERSE_ID);
                if (settlementTimestamp != 0 && totalFunds != 0) {
                    IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
                    uint256 launcherMemecoinBalance =
                        MockIntegrationMemecoin(verse.memecoin).balanceOf(address(launcher));
                    recordedMemecoinDust = launcherMemecoinBalance - settledMemecoin;
                    memecoinDustRecorded = true;
                }
            }
        } catch {}
    }

    /// @notice Test helper for claim.
    /// @param actorSeed See implementation.
    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try launcher.claimUnlockedPreorderMemecoin(VERSE_ID) {} catch {}
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract PreorderRefundHandler is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal immutable launcher;
    address internal immutable launcherProxy;
    MockERC20 internal immutable uAsset;
    address[] internal actors;

    constructor(IMemeverseLauncher _launcher, address _launcherProxy, MockERC20 _uAsset, address[] memory _actors) {
        launcher = _launcher;
        launcherProxy = _launcherProxy;
        uAsset = _uAsset;
        actors = _actors;
    }

    /// @notice Test helper for genesis.
    /// @param actorSeed See implementation.
    /// @param amountSeed See implementation.
    function genesis(uint256 actorSeed, uint256 amountSeed) external {
        if (launcher.getStageByVerseId(VERSE_ID) != IMemeverseLauncher.Stage.Genesis) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = uAsset.balanceOf(actor);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, _min(balance, type(uint128).max));
        vm.prank(actor);
        try launcher.genesis(VERSE_ID, amount, actor) {} catch {}
    }

    /// @notice Test helper for preorder.
    /// @param actorSeed See implementation.
    /// @param amountSeed See implementation.
    function preorder(uint256 actorSeed, uint256 amountSeed) external {
        if (launcher.getStageByVerseId(VERSE_ID) != IMemeverseLauncher.Stage.Genesis) return;

        uint256 capacity = launcher.previewPreorderCapacity(VERSE_ID);
        if (capacity == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 balance = uAsset.balanceOf(actor);
        uint256 maxAmount = _min(capacity, _min(balance, type(uint128).max));
        if (maxAmount == 0) return;

        uint256 amount = bound(amountSeed, 1, maxAmount);
        vm.prank(actor);
        try launcher.preorder(VERSE_ID, amount, actor) {} catch {}
    }

    /// @notice Test helper for warp.
    /// @param deltaSeed See implementation.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 3 days));
    }

    /// @notice Test helper for changeStage.
    function changeStage() external {
        try launcher.changeStage(VERSE_ID) {} catch {}
    }

    /// @notice Test helper for refundGenesis.
    /// @param actorSeed See implementation.
    function refundGenesis(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try launcher.refund(VERSE_ID) {} catch {}
    }

    /// @notice Test helper for refundPreorder.
    /// @param actorSeed See implementation.
    function refundPreorder(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try launcher.refundPreorder(VERSE_ID) {} catch {}
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract MemeverseLauncherPreorderSuccessInvariantTest is StdInvariant, MemeverseLauncherPreorderInvariantBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11E);

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseSwapRouter internal router;
    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockLauncherIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    MockPOLendForPreorderInvariant internal polend;
    MockPOLSplitterForPreorderInvariant internal splitter;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;
    PreorderSuccessHandler internal handler;

    /// @notice Test helper for setUp.
    function setUp() external {
        _setActors(ALICE, BOB, CHARLIE);

        manager = new MockPoolManagerForRouterTest();
        proxyDeployer = new MockLauncherIntegrationProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForPreorderInvariant();
        splitter = new MockPOLSplitterForPreorderInvariant(address(pt), address(yt));
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
        // helper (replaces the former Testable subclass + hand-rolled engine deployment).
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), address(this));
        hook = MemeverseUniswapHook(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0xBEEF))
        );
        hook.setLauncher(address(launcher));
        hook.setPoolInitializer(address(router));

        launcher.setMemeverseUniswapHook(address(router.hook()));
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
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setLendMarket(address(pt), address(yt));

        registry.setEndpoint(REMOTE_GOV_CHAIN_ID, REMOTE_EID);
        _registerVerse(launcher, address(uAsset));

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);

        uAsset.mint(ALICE, 1_000 ether);
        uAsset.mint(BOB, 1_000 ether);
        uAsset.mint(CHARLIE, 1_000 ether);

        vm.prank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(BOB);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(CHARLIE);
        uAsset.approve(address(launcher), type(uint256).max);

        vm.prank(ALICE);
        launcher.genesis(VERSE_ID, 10 ether, ALICE);

        handler = new PreorderSuccessHandler(launcher, launcherProxy, uAsset, actors);
        targetContract(address(handler));
    }

    /// @notice Test helper for invariant_genesisAccountingMatchesUserBalances.
    function invariant_genesisAccountingMatchesUserBalances() external view {
        uint256 totalNormalFunds = launcher.totalNormalFunds(VERSE_ID);
        MemeverseLauncher launcherImpl = MemeverseLauncher(launcherProxy);
        uint256 totalUserGenesisFunds;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 genesisFund,,) = launcherImpl.userGenesisData(VERSE_ID, actors[i]);
            totalUserGenesisFunds += genesisFund;
        }
        assertEq(totalUserGenesisFunds, uint256(totalNormalFunds), "genesis sum");
    }

    /// @notice Test helper for invariant_preorderCapacityNeverExceeded.
    function invariant_preorderCapacityNeverExceeded() external view {
        MemeverseLauncher launcherImpl = MemeverseLauncher(launcherProxy);
        uint256 totalNormalFunds_ = launcher.totalNormalFunds(VERSE_ID);
        uint256 leveragedDebt = polend.getTotalLeveragedDebt(VERSE_ID);
        (uint256 totalFunds,,) = getPreorderStateForTest(launcherProxy, VERSE_ID);
        uint256 preorderBase = (totalNormalFunds_ + leveragedDebt) * 7 / 10;
        uint256 maxCapacity =
            preorderBase * launcherImpl.getLauncherParameters().preorderCapRatio / launcherImpl.RATIO();

        assertLe(totalFunds, maxCapacity, "preorder cap");
        assertEq(totalFunds + launcher.previewPreorderCapacity(VERSE_ID), maxCapacity, "preorder capacity accounting");
    }

    /// @notice Test helper for invariant_claimsNeverExceedEntitlement.
    function invariant_claimsNeverExceedEntitlement() external view {
        MemeverseLauncher launcherImpl = MemeverseLauncher(launcherProxy);
        (uint256 totalFunds, uint256 settledMemecoin, uint40 settlementTimestamp) =
            getPreorderStateForTest(launcherProxy, VERSE_ID);
        IMemeverseLauncher.Stage stage = launcher.getStageByVerseId(VERSE_ID);
        bool preorderClaimPreviewAvailable = stage >= IMemeverseLauncher.Stage.Locked;
        uint256 totalClaimed;

        for (uint256 i; i < actors.length; ++i) {
            (uint256 funds, uint256 claimedMemecoin,) = launcherImpl.userPreorderData(VERSE_ID, actors[i]);
            uint256 purchasedMemecoin = totalFunds == 0 ? 0 : FullMath.mulDiv(settledMemecoin, funds, totalFunds);
            assertLe(claimedMemecoin, purchasedMemecoin, "claimed exceeds entitlement");

            uint256 claimable = preorderClaimPreviewAvailable
                ? claimablePreorderMemecoinForTest(launcherProxy, VERSE_ID, actors[i])
                : 0;
            assertLe(claimable + claimedMemecoin, purchasedMemecoin, "unlocked exceeds entitlement");

            totalClaimed += claimedMemecoin;
        }

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        if (settlementTimestamp != 0 && preorderClaimPreviewAvailable) {
            uint256 launcherMemecoinBalance = MockIntegrationMemecoin(verse.memecoin).balanceOf(address(launcher));
            assertGe(launcherMemecoinBalance + totalClaimed, settledMemecoin, "settled memecoin undercollateralized");
            if (handler.memecoinDustRecorded()) {
                assertEq(
                    launcherMemecoinBalance + totalClaimed,
                    settledMemecoin + handler.recordedMemecoinDust(),
                    "settled memecoin conservation"
                );
            }
        }
    }
}

contract MemeverseLauncherPreorderRefundInvariantTest is StdInvariant, MemeverseLauncherPreorderInvariantBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11E);

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockLauncherIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    MockPOLendForPreorderInvariant internal polend;
    MockPOLSplitterForPreorderInvariant internal splitter;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;
    PreorderRefundHandler internal handler;

    /// @notice Test helper for setUp.
    function setUp() external {
        _setActors(ALICE, BOB, CHARLIE);

        proxyDeployer = new MockLauncherIntegrationProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForPreorderInvariant();
        splitter = new MockPOLSplitterForPreorderInvariant(address(pt), address(yt));
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

        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        // Phase 3B: registerMemeverse/genesis/preorder delegatecall the launch sibling; bind it
        // before _registerVerse (which exercises registerMemeverse) or setUp reverts LaunchImplNotSet.
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        polend.setLendMarket(address(pt), address(yt));

        registry.setEndpoint(REMOTE_GOV_CHAIN_ID, REMOTE_EID);
        _registerVerse(launcher, address(uAsset));

        uAsset.mint(ALICE, 1_000 ether);
        uAsset.mint(BOB, 1_000 ether);
        uAsset.mint(CHARLIE, 1_000 ether);

        vm.prank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(BOB);
        uAsset.approve(address(launcher), type(uint256).max);
        vm.prank(CHARLIE);
        uAsset.approve(address(launcher), type(uint256).max);

        handler = new PreorderRefundHandler(launcher, launcherProxy, uAsset, actors);
        targetContract(address(handler));
    }

    /// @notice Test helper for invariant_refundPathKeepsGenesisAccountingExact.
    function invariant_refundPathKeepsGenesisAccountingExact() external view {
        MemeverseLauncher launcherImpl = MemeverseLauncher(launcherProxy);
        uint256 totalNormalFunds = launcher.totalNormalFunds(VERSE_ID);
        uint256 outstandingGenesis;
        uint256 outstandingPreorder;
        uint256 historicalGenesis;
        uint256 historicalPreorder;

        for (uint256 i; i < actors.length; ++i) {
            (uint256 genesisFund, bool isGenesisRefunded,) = launcherImpl.userGenesisData(VERSE_ID, actors[i]);
            (uint256 preorderFund,, bool isPreorderRefunded) = launcherImpl.userPreorderData(VERSE_ID, actors[i]);

            historicalGenesis += genesisFund;
            historicalPreorder += preorderFund;
            if (!isGenesisRefunded) outstandingGenesis += genesisFund;
            if (!isPreorderRefunded) outstandingPreorder += preorderFund;
        }

        assertEq(historicalGenesis, uint256(totalNormalFunds), "genesis history");
        (uint256 totalFunds,,) = getPreorderStateForTest(launcherProxy, VERSE_ID);
        assertEq(historicalPreorder, totalFunds, "preorder history");
        assertEq(uAsset.balanceOf(address(launcher)), outstandingGenesis + outstandingPreorder, "refund conservation");
    }

    /// @notice Test helper for invariant_refundPathNeverSettlesPreorder.
    function invariant_refundPathNeverSettlesPreorder() external view {
        IMemeverseLauncher.Stage stage = launcher.getStageByVerseId(VERSE_ID);
        assertTrue(
            stage == IMemeverseLauncher.Stage.Genesis || stage == IMemeverseLauncher.Stage.Refund, "unexpected stage"
        );

        (, uint256 settledMemecoin, uint40 settlementTimestamp) = getPreorderStateForTest(launcherProxy, VERSE_ID);
        assertEq(settledMemecoin, 0, "refund path settled memecoin");
        assertEq(settlementTimestamp, 0, "refund path settlement timestamp");
    }

    /// @notice Test helper for invariant_refundPathStillRespectsPreorderCap.
    function invariant_refundPathStillRespectsPreorderCap() external view {
        MemeverseLauncher launcherImpl = MemeverseLauncher(launcherProxy);
        uint256 totalNormalFunds_ = launcher.totalNormalFunds(VERSE_ID);
        uint256 leveragedDebt = polend.getTotalLeveragedDebt(VERSE_ID);
        (uint256 totalFunds,,) = getPreorderStateForTest(launcherProxy, VERSE_ID);
        uint256 preorderBase = (totalNormalFunds_ + leveragedDebt) * 7 / 10;
        uint256 maxCapacity =
            preorderBase * launcherImpl.getLauncherParameters().preorderCapRatio / launcherImpl.RATIO();

        assertLe(totalFunds, maxCapacity, "refund preorder cap");
        assertEq(totalFunds + launcher.previewPreorderCapacity(VERSE_ID), maxCapacity, "refund preorder capacity");
    }
}
