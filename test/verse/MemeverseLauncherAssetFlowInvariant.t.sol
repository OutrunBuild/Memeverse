// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    MockLiquidProof,
    MockLzEndpointRegistry,
    MockOFTDispatcher,
    MockPredictOnlyProxyDeployer,
    MockSwapRouter
} from "../mocks/verse/LauncherLifecycleMocks.sol";

contract AssetFlowHandler is Test {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal immutable launcher;
    MockLiquidProof internal immutable liquidProof;
    MockERC20 internal immutable memecoinLp;
    MockERC20 internal immutable polLp;
    address[] internal actors;

    constructor(
        IMemeverseLauncher _launcher,
        MockLiquidProof _liquidProof,
        MockERC20 _memecoinLp,
        MockERC20 _polLp,
        address[] memory _actors
    ) {
        launcher = _launcher;
        liquidProof = _liquidProof;
        memecoinLp = _memecoinLp;
        polLp = _polLp;
        actors = _actors;
    }

    /// @notice Test helper for claimNormalYT.
    /// @param actorSeed See implementation.
    function claimNormalYT(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try launcher.claimNormalYT(VERSE_ID) {} catch {}
    }

    /// @notice Test helper for redeemMemecoinLiquidity.
    /// @param actorSeed See implementation.
    /// @param amountSeed See implementation.
    function redeemMemecoinLiquidity(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 polBalance = liquidProof.balanceOf(actor);
        if (polBalance == 0) return;

        uint256 amount = bound(amountSeed, 1, polBalance);
        vm.prank(actor);
        try launcher.redeemMemecoinLiquidity(VERSE_ID, amount, false) {} catch {}
    }

    /// @notice Test helper for touchBalances.
    function touchBalances() external view {
        for (uint256 i; i < actors.length; ++i) {
            liquidProof.balanceOf(actors[i]);
            memecoinLp.balanceOf(actors[i]);
            polLp.balanceOf(actors[i]);
        }
    }
}

// Invariant fuzzing here still uses the lifecycle mock router for broad state exploration.
// `MemeverseLauncherSwapIntegration.t.sol` currently adds only the real launch-settlement path plus the
// current real-stack `mintPOLToken` / fee-claim blockers; broader asset-flow semantics are still mock-backed here.
contract MintPOLHandler is Test {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal immutable launcher;
    MockSwapRouter internal immutable router;
    MockERC20 internal immutable uAsset;
    MockERC20 internal immutable memecoin;
    address[] internal actors;

    constructor(
        IMemeverseLauncher _launcher,
        MockSwapRouter _router,
        MockERC20 _uAsset,
        MockERC20 _memecoin,
        address[] memory _actors
    ) {
        launcher = _launcher;
        router = _router;
        uAsset = _uAsset;
        memecoin = _memecoin;
        actors = _actors;
    }

    /// @notice Test helper for mintAuto.
    /// @param actorSeed See implementation.
    /// @param uAssetDesiredSeed See implementation.
    /// @param memecoinDesiredSeed See implementation.
    /// @param liquiditySeed See implementation.
    function mintAuto(uint256 actorSeed, uint256 uAssetDesiredSeed, uint256 memecoinDesiredSeed, uint256 liquiditySeed)
        external
    {
        address actor = actors[actorSeed % actors.length];
        uint256 uAssetBalance = uAsset.balanceOf(actor);
        uint256 memecoinBalance = memecoin.balanceOf(actor);
        if (uAssetBalance == 0 || memecoinBalance == 0) return;

        uint256 uAssetDesired = bound(uAssetDesiredSeed, 1, uAssetBalance);
        uint256 memecoinDesired = bound(memecoinDesiredSeed, 1, memecoinBalance);
        uint128 liquidity = uint128(bound(liquiditySeed, 1, _min(uAssetDesired, memecoinDesired)));
        uint256 uAssetUsed = bound(uint256(liquiditySeed >> 16), 1, uAssetDesired);
        uint256 memecoinUsed = bound(uint256(liquiditySeed >> 48), 1, memecoinDesired);

        router.setAddLiquidityResult(address(uAsset), address(memecoin), liquidity, uAssetUsed, memecoinUsed);

        vm.prank(actor);
        try launcher.mintPOLToken(VERSE_ID, uAssetDesired, memecoinDesired, 0, 0, 0, block.timestamp) returns (
            uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut
        ) {
            assertEq(amountInUAsset, uAssetUsed, "auto uAsset used");
            assertEq(amountInMemecoin, memecoinUsed, "auto memecoin used");
            assertEq(amountOut, liquidity, "auto pol out");
        } catch {}
    }

    /// @notice Test helper for mintExact.
    /// @param actorSeed See implementation.
    /// @param uAssetDesiredSeed See implementation.
    /// @param memecoinDesiredSeed See implementation.
    /// @param amountOutSeed See implementation.
    /// @param uAssetRequiredSeed See implementation.
    /// @param memecoinRequiredSeed See implementation.
    function mintExact(
        uint256 actorSeed,
        uint256 uAssetDesiredSeed,
        uint256 memecoinDesiredSeed,
        uint256 amountOutSeed,
        uint256 uAssetRequiredSeed,
        uint256 memecoinRequiredSeed
    ) external {
        address actor = actors[actorSeed % actors.length];
        uint256 uAssetBalance = uAsset.balanceOf(actor);
        uint256 memecoinBalance = memecoin.balanceOf(actor);
        if (uAssetBalance == 0 || memecoinBalance == 0) return;

        uint256 uAssetDesired = bound(uAssetDesiredSeed, 1, uAssetBalance);
        uint256 memecoinDesired = bound(memecoinDesiredSeed, 1, memecoinBalance);
        uint128 amountOut = uint128(bound(amountOutSeed, 1, _min(uAssetDesired, memecoinDesired)));
        uint256 uAssetRequired = bound(uAssetRequiredSeed, 1, uAssetDesired);
        uint256 memecoinRequired = bound(memecoinRequiredSeed, 1, memecoinDesired);

        router.setQuoteAmountsForLiquidity(
            address(uAsset), address(memecoin), amountOut, uAssetRequired, memecoinRequired
        );
        router.setAddLiquidityResult(address(uAsset), address(memecoin), amountOut, uAssetRequired, memecoinRequired);

        vm.prank(actor);
        try launcher.mintPOLToken(VERSE_ID, uAssetDesired, memecoinDesired, 0, 0, amountOut, block.timestamp) returns (
            uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOutReceived
        ) {
            assertEq(amountInUAsset, uAssetRequired, "exact uAsset used");
            assertEq(amountInMemecoin, memecoinRequired, "exact memecoin used");
            assertEq(amountOutReceived, amountOut, "exact pol out");
        } catch {}
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract MemeverseLauncherClaimRedeemInvariantTest is StdInvariant, Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;
    uint256 internal constant TOTAL_GENESIS = 120 ether;
    uint256 internal constant INITIAL_CLAIMABLE_POL = 60 ether;
    uint256 internal constant INITIAL_POL_LP = 90 ether;
    uint256 internal constant INITIAL_MEMECOIN_LP = 60 ether;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11E);

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockSwapRouter internal router;
    MockOFTDispatcher internal dispatcher;
    MockPredictOnlyProxyDeployer internal proxyDeployer;
    MockLzEndpointRegistry internal registry;
    MockERC20 internal uAsset;
    MockERC20 internal memecoin;
    MockLiquidProof internal liquidProof;
    MockERC20 internal memecoinLp;
    MockERC20 internal polLp;

    address[] internal actors;
    AssetFlowHandler internal handler;

    function _deployLauncher(
        address polendAddr,
        address splitterAddr,
        uint256 executorRewardRate,
        uint128 oftReceiveGasLimit,
        uint128 yieldDispatcherGasLimit,
        uint256 preorderCapRatio,
        uint256 preorderVestingDuration
    ) internal returns (IMemeverseLauncher) {
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
                        polendAddr,
                        splitterAddr,
                        executorRewardRate,
                        oftReceiveGasLimit,
                        yieldDispatcherGasLimit,
                        preorderCapRatio,
                        preorderVestingDuration
                    )
                )
            )
        );
        return IMemeverseLauncher(launcherProxy);
    }

    /// @notice Test helper for setUp.
    function setUp() external {
        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CHARLIE);

        launcher = _deployLauncher(address(0x10), address(0x11), 25, 115_000, 135_000, 2_500, 7 days);
        router = new MockSwapRouter(address(launcher));
        dispatcher = new MockOFTDispatcher();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        liquidProof = new MockLiquidProof();
        memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        polLp = new MockERC20("POL-LP", "POL-LP", 18);
        proxyDeployer = new MockPredictOnlyProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLzEndpointRegistry();

        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));

        IMemeverseLauncher.Memeverse memory verse;
        verse.uAsset = address(uAsset);
        verse.memecoin = address(memecoin);
        verse.pol = address(liquidProof);
        verse.governor = address(0xCAFE);
        verse.yieldVault = address(0xD00D);
        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            address(uAsset),
            address(memecoin),
            address(liquidProof),
            address(0xD00D),
            address(0xCAFE),
            address(0),
            0,
            0,
            IMemeverseLauncher.Stage.Unlocked,
            false
        );

        setGenesisFundForTest(launcherProxy, VERSE_ID, 120 ether);
        setUserGenesisDataForTest(launcherProxy, VERSE_ID, ALICE, 24 ether, false, false);
        setUserGenesisDataForTest(launcherProxy, VERSE_ID, BOB, 36 ether, false, false);
        setUserGenesisDataForTest(launcherProxy, VERSE_ID, CHARLIE, 60 ether, false, false);

        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));
        router.setLpToken(address(liquidProof), address(uAsset), address(polLp));

        liquidProof.mint(ALICE, INITIAL_CLAIMABLE_POL * 24 ether / TOTAL_GENESIS);
        liquidProof.mint(BOB, INITIAL_CLAIMABLE_POL * 36 ether / TOTAL_GENESIS);
        liquidProof.mint(CHARLIE, INITIAL_CLAIMABLE_POL * 60 ether / TOTAL_GENESIS);
        memecoinLp.mint(address(launcher), INITIAL_MEMECOIN_LP);
        polLp.mint(address(launcher), INITIAL_POL_LP);

        handler = new AssetFlowHandler(launcher, liquidProof, memecoinLp, polLp, actors);
        targetContract(address(handler));
    }

    /// @notice Test helper for invariant_polTokenClaimAndBurnConserveSupply.
    function invariant_polTokenClaimAndBurnConserveSupply() external view {
        uint256 userPolBalance;
        for (uint256 i; i < actors.length; ++i) {
            userPolBalance += liquidProof.balanceOf(actors[i]);
        }

        assertEq(
            liquidProof.balanceOf(address(launcher)) + userPolBalance + liquidProof.burnedAmount(),
            INITIAL_CLAIMABLE_POL,
            "pol conservation"
        );
    }

    /// @notice Test helper for invariant_memecoinLpAndPolLpConserved.
    function invariant_memecoinLpAndPolLpConserved() external view {
        uint256 userMemecoinLp;
        uint256 userPolLp;
        for (uint256 i; i < actors.length; ++i) {
            userMemecoinLp += memecoinLp.balanceOf(actors[i]);
            userPolLp += polLp.balanceOf(actors[i]);
        }

        assertEq(memecoinLp.balanceOf(address(launcher)) + userMemecoinLp, INITIAL_MEMECOIN_LP, "memecoin lp");
        assertEq(polLp.balanceOf(address(launcher)) + userPolLp, INITIAL_POL_LP, "pol lp");
    }

    /// @notice Test helper for invariant_usersNeverExceedGenesisEntitlements.
    function invariant_usersNeverExceedGenesisEntitlements() external view {
        for (uint256 i; i < actors.length; ++i) {
            (uint256 genesisFund,, bool isRedeemed) =
                MemeverseLauncher(launcherProxy).userGenesisData(VERSE_ID, actors[i]);
            uint256 polShare = INITIAL_CLAIMABLE_POL * genesisFund / TOTAL_GENESIS;
            uint256 polLpShare = INITIAL_POL_LP * genesisFund / TOTAL_GENESIS;
            uint256 userPolBalance = liquidProof.balanceOf(actors[i]);
            uint256 userMemecoinLpBalance = memecoinLp.balanceOf(actors[i]);
            uint256 userPolLpBalance = polLp.balanceOf(actors[i]);

            assertLe(userPolBalance + userMemecoinLpBalance, polShare, "user combined pol claim");
            assertLe(userPolLpBalance, polLpShare, "user pol lp");

            if (isRedeemed) assertEq(userPolLpBalance, polLpShare, "redeemed user pol lp");
        }
    }
}

contract MemeverseLauncherMintPOLInvariantTest is StdInvariant, Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11E);
    uint256 internal constant INITIAL_USER_BALANCE = 1_000 ether;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockSwapRouter internal router;
    MockOFTDispatcher internal dispatcher;
    MockPredictOnlyProxyDeployer internal proxyDeployer;
    MockLzEndpointRegistry internal registry;
    MockERC20 internal uAsset;
    MockERC20 internal memecoin;
    MockLiquidProof internal liquidProof;
    MockERC20 internal memecoinLp;

    address[] internal actors;
    MintPOLHandler internal handler;

    /// @notice Test helper for setUp.
    function setUp() external {
        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CHARLIE);

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
                        address(0x10),
                        address(0x11),
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
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        router = new MockSwapRouter(address(launcher));
        dispatcher = new MockOFTDispatcher();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        liquidProof = new MockLiquidProof();
        memecoinLp = new MockERC20("MEME-LP", "MEME-LP", 18);
        proxyDeployer = new MockPredictOnlyProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLzEndpointRegistry();

        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));

        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            address(uAsset),
            address(memecoin),
            address(liquidProof),
            address(0),
            address(0),
            address(0),
            0,
            0,
            IMemeverseLauncher.Stage.Locked,
            false
        );

        router.setLpToken(address(memecoin), address(uAsset), address(memecoinLp));

        uAsset.mint(ALICE, INITIAL_USER_BALANCE);
        uAsset.mint(BOB, INITIAL_USER_BALANCE);
        uAsset.mint(CHARLIE, INITIAL_USER_BALANCE);
        memecoin.mint(ALICE, INITIAL_USER_BALANCE);
        memecoin.mint(BOB, INITIAL_USER_BALANCE);
        memecoin.mint(CHARLIE, INITIAL_USER_BALANCE);

        vm.startPrank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
        memecoin.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(BOB);
        uAsset.approve(address(launcher), type(uint256).max);
        memecoin.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(CHARLIE);
        uAsset.approve(address(launcher), type(uint256).max);
        memecoin.approve(address(launcher), type(uint256).max);
        vm.stopPrank();

        handler = new MintPOLHandler(launcher, router, uAsset, memecoin, actors);
        targetContract(address(handler));
    }

    /// @notice Test helper for invariant_mintPOL_ConservesUAssetAndMemecoinAcrossUsersLauncherAndRouter.
    function invariant_mintPOL_ConservesUAssetAndMemecoinAcrossUsersLauncherAndRouter() external view {
        uint256 totalUAsset = uAsset.balanceOf(address(launcher)) + uAsset.balanceOf(address(router));
        uint256 totalMemecoin = memecoin.balanceOf(address(launcher)) + memecoin.balanceOf(address(router));

        for (uint256 i; i < actors.length; ++i) {
            totalUAsset += uAsset.balanceOf(actors[i]);
            totalMemecoin += memecoin.balanceOf(actors[i]);
        }

        assertEq(totalUAsset, INITIAL_USER_BALANCE * actors.length, "uAsset conservation");
        assertEq(totalMemecoin, INITIAL_USER_BALANCE * actors.length, "memecoin conservation");
    }

    /// @notice Test helper for invariant_mintPOL_LeavesNoResidualLauncherInputBalances.
    function invariant_mintPOL_LeavesNoResidualLauncherInputBalances() external view {
        assertEq(uAsset.balanceOf(address(launcher)), 0, "launcher uAsset");
        assertEq(memecoin.balanceOf(address(launcher)), 0, "launcher memecoin");
    }

    /// @notice Test helper for invariant_mintPOL_POLSupplyMatchesLauncherBackingLP.
    function invariant_mintPOL_POLSupplyMatchesLauncherBackingLP() external view {
        uint256 userPolSupply;
        for (uint256 i; i < actors.length; ++i) {
            userPolSupply += liquidProof.balanceOf(actors[i]);
        }

        assertEq(userPolSupply, memecoinLp.balanceOf(address(launcher)), "pol backing lp");
    }
}
