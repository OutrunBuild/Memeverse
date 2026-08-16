// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {DelegatecallOnly} from "../../src/common/access/DelegatecallOnly.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";

import {
    MockSwapRouter,
    MockLiquidProof,
    MockPredictOnlyProxyDeployer,
    MockPOLendForLifecycle,
    MockPOLSplitterForLifecycle,
    MockOFTDispatcher,
    MockLzEndpointRegistry
} from "../mocks/verse/LauncherLifecycleMocks.sol";

/// @notice Targeted guard tests for the nested launch->liquidity delegatecall chain in `changeStage`.
/// @dev The facade's `changeStage` delegatecalls the launch sibling, which (in the Genesis->Locked branch)
///      delegatecalls the liquidity sibling to deploy bootstrap liquidity. The guard chain is:
///      facade.changeStage -> (LaunchImplNotSet guard on facade) -> launchImpl.changeStage ->
///      _deployLiquidity -> (LiquidityImplNotSet guard in launchImpl) -> liquidityImpl.deployBootstrapLiquidity.
contract MemeverseLauncherBootstrapLiquidityTest is Test, MemeverseLauncherTestHelper {
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

    /// @notice Deploys the launcher proxy and supporting mocks and binds the launch sibling, but intentionally
    ///         leaves `liquidityImpl` unset.
    /// @dev Mirrors `MemeverseLauncherLifecycleTest.setUp` minus the `setLiquidityImpl` call so each test can
    ///      control liquidity-sibling availability explicitly. The launch sibling is bound here so the
    ///      facade's `changeStage` clears its `LaunchImplNotSet` guard and reaches the liquidity guard inside
    ///      `MemeverseLaunchImpl._deployLiquidity`.
    function setUp() external {
        dispatcher = new MockOFTDispatcher();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        liquidProof = new MockLiquidProof();
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
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
        // Bind the launch sibling so the facade's LaunchImplNotSet guard does not fire and the call reaches
        // the liquidity guard inside MemeverseLaunchImpl._deployLiquidity.
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        // Deliberately omitted: launcher.setLiquidityImpl(...). Each test asserts the guard explicitly.
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        router.setLpToken(address(liquidProof), address(uAsset), address(new MockERC20("POL-U", "POL-U", 18)));
        router.setLpToken(address(pt), address(uAsset), address(new MockERC20("PT-U", "PT-U", 18)));
        router.setLpToken(address(pt), address(liquidProof), address(new MockERC20("PT-POL", "PT-POL", 18)));
    }

    /// @notice Seeds a flash-Genesis verse that satisfies the minimum funding target so `changeStage`
    ///         routes into `_deployAndSetupMemeverse` -> `_deployLiquidity`.
    /// @dev Reuses the lifecycle fixture proven to reach `Locked` when a bootstrap sibling is bound.
    ///      `omnichainIds[0] != block.chainid` forces the remote governance branch, which only predicts
    ///      addresses instead of deploying and initializing concrete vaults/governor contracts.
    function _seedFlashGenesisVerseReadyToLock(uint256 verseId) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
            address(uAsset),
            address(memecoin),
            address(liquidProof),
            address(0),
            address(0),
            address(0),
            0,
            0,
            IMemeverseLauncher.Stage.Genesis,
            true // flashGenesis allows locking before endTime once minTotalFund is met
        );
        setOmnichainIdsForTest(launcherProxy, verseId, _array(uint32(block.chainid + 1)));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        setGenesisFundForTest(launcherProxy, verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);
    }

    function _array(uint32 value) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = value;
    }

    /// @notice Verifies `changeStage` reverts when `liquidityImpl` is unset even though funding qualifies for launch.
    /// @dev The call traverses facade.changeStage -> launchImpl.changeStage -> launchImpl._deployLiquidity, where
    ///      the zero-address guard fires and surfaces as `LiquidityImplNotSet` (the launch sibling is already bound).
    function test_revertsWhenLiquidityImplNotSet() external {
        uint256 verseId = 1;
        _seedFlashGenesisVerseReadyToLock(verseId);

        vm.expectRevert(IMemeverseLauncher.LiquidityImplNotSet.selector);
        launcher.changeStage(verseId);

        // Reaching `_deployLiquidity` inside the launch sibling means Genesis pre-checks passed and the
        // verse was about to lock; the guard must leave the stage untouched so the call is safe to retry
        // after binding a sibling.
        assertEq(
            uint256(launcher.getStageByVerseId(verseId)),
            uint256(IMemeverseLauncher.Stage.Genesis),
            "stage unchanged after guard revert"
        );
    }

    /// @notice Verifies the bootstrap liquidity sibling runs via the nested delegatecall chain once bound,
    ///         advancing the verse to `Locked`.
    /// @dev Same fixture as the guard test, but `setLiquidityImpl` is invoked first; facade.changeStage
    ///      delegatecalls launchImpl.changeStage, which delegatecalls liquidityImpl.deployBootstrapLiquidity.
    ///      The liquidity sibling deploys the main and POL pools, mints POL, and records bootstrap residual
    ///      state in the facade's storage.
    function test_bootstrapRunsViaSiblingAfterSet() external {
        uint256 verseId = 1;
        _seedFlashGenesisVerseReadyToLock(verseId);

        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "returned stage");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Locked), "stored stage");
        // The liquidity sibling records the POL/uAsset LP amount in the facade's auxiliary-liquidity slot.
        (uint256 polUAssetLp,,) = MemeverseLauncherUpgradeable(launcherProxy).auxiliaryLiquidities(verseId);
        assertGt(polUAssetLp, 0, "bootstrap deployed POL/uAsset liquidity");
    }

    /// @notice A direct (non-delegatecall) invocation of sibling.deployBootstrapLiquidity must revert.
    /// @dev The sibling inherits `DelegatecallOnly`, so a direct call reverts with `DelegatecallOnlyCall`
    ///      at the `onlyDelegatecall` guard before any storage access. Locks the
    ///      "deployBootstrapLiquidity is facade-delegatecall-only" invariant so a future initializer/setter
    ///      added to the sibling cannot silently break it.
    function test_directCallToSiblingReverts() external {
        MemeverseLiquidityImpl sibling = new MemeverseLiquidityImpl();
        address attacker = makeAddr("attacker");

        // Direct call hits the inherited `onlyDelegatecall` guard and reverts before the body runs.
        vm.prank(attacker);
        vm.expectRevert(DelegatecallOnly.DelegatecallOnlyCall.selector);
        sibling.deployBootstrapLiquidity(
            1, address(uAsset), address(memecoin), address(liquidProof), 0, address(polend), address(splitter)
        );
    }
}
