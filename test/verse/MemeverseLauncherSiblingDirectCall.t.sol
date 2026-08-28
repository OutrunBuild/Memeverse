// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {DelegatecallOnly} from "../../src/common/access/DelegatecallOnly.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";

import {
    MockSwapRouter,
    MockPOLendForLifecycle,
    MockPOLSplitterForLifecycle,
    MockOFTDispatcher,
    MockLiquidProof,
    MockPredictOnlyProxyDeployer
} from "../mocks/verse/LauncherLifecycleMocks.sol";
import {LzEndpointRegistryMock} from "../mocks/common/LzEndpointRegistryMock.sol";

/// @title MemeverseLauncherSiblingDirectCall
/// @notice Verifies the `DelegatecallOnly` guard on the three launcher delegatecall siblings
///         (`MemeverseLaunchImpl`, `MemeverseSettlementImpl`, `MemeverseLiquidityImpl`): a direct
///         (non-delegatecall) entry must revert with `DelegatecallOnlyCall`, while the normal facade
///         delegatecall path (including the nested delegatecall into the liquidity sibling reached from
///         `changeStage`) must still pass.
contract MemeverseLauncherSiblingDirectCall is Test {
    // Facade delegatecall path (used by the smoke tests). Mirrors MemeverseLauncherLifecycleTest.setUp's
    // launcher wiring so the normal path runs against the same sibling instances the facade stores.
    IMemeverseLauncher internal launcher;
    MockSwapRouter internal router;
    MockERC20 internal uAsset;
    MockERC20 internal memecoin;
    MockLiquidProof internal liquidProof;
    MockERC20 internal pt;
    MockERC20 internal yt;
    MockPOLendForLifecycle internal polend;
    MockPOLSplitterForLifecycle internal splitter;
    MockPredictOnlyProxyDeployer internal proxyDeployer;

    address internal constant ALICE = address(0xA11CE);

    function setUp() external {
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        liquidProof = new MockLiquidProof();
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        proxyDeployer = new MockPredictOnlyProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        polend = new MockPOLendForLifecycle();
        splitter = new MockPOLSplitterForLifecycle(address(pt), address(yt));
        LzEndpointRegistryMock registry = new LzEndpointRegistryMock();
        MockOFTDispatcher dispatcher = new MockOFTDispatcher();

        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        address proxy = address(
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
        launcher = IMemeverseLauncher(proxy);
        router = new MockSwapRouter(address(launcher));

        // Wire the facade to delegatecall into fresh sibling instances — the same pattern the lifecycle
        // suite uses, so the delegatecall smoke test exercises the real guard on the real delegatecall path.
        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setYieldDispatcher(address(dispatcher));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        polend.setLendMarket(address(pt), address(yt));
    }

    // =============================================================================================================
    // Direct-call revert — the guard's core security property. Each sibling is instantiated standalone and
    // called directly (not via the facade), so `address(this) == _self` and the guard must revert before any
    // storage access. The fallback "empty storage -> external call to address(0)" path is now an explicit revert.
    // =============================================================================================================

    function test_DirectCall_LaunchImplGenesis_Reverts() external {
        MemeverseLaunchImpl sibling = new MemeverseLaunchImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.genesis(1, 1 ether, ALICE);
    }

    function test_DirectCall_LaunchImplGenesisAndPreorder_Reverts() external {
        MemeverseLaunchImpl sibling = new MemeverseLaunchImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.genesisAndPreorder(1, 1 ether, 1 ether, ALICE);
    }

    function test_DirectCall_LaunchImplChangeStage_Reverts() external {
        MemeverseLaunchImpl sibling = new MemeverseLaunchImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.changeStage(1);
    }

    function test_DirectCall_LaunchImplRegisterMemeverse_Reverts() external {
        MemeverseLaunchImpl sibling = new MemeverseLaunchImpl();
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = 1;
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.registerMemeverse("n", "s", 1, 0, 0, omnichainIds, address(uAsset), false);
    }

    function test_DirectCall_SettlementImplRefund_Reverts() external {
        MemeverseSettlementImpl sibling = new MemeverseSettlementImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.refund(1);
    }

    function test_DirectCall_SettlementImplCollectAndDistributeFees_Reverts() external {
        MemeverseSettlementImpl sibling = new MemeverseSettlementImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.collectAndDistributeFees{value: 0}(1, ALICE, address(splitter));
    }

    function test_DirectCall_LiquidityImplDeployBootstrapLiquidity_Reverts() external {
        MemeverseLiquidityImpl sibling = new MemeverseLiquidityImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.deployBootstrapLiquidity(
            1, address(uAsset), address(memecoin), address(liquidProof), 0, address(polend), address(splitter)
        );
    }

    function test_DirectCall_LiquidityImplMintPOLToken_Reverts() external {
        MemeverseLiquidityImpl sibling = new MemeverseLiquidityImpl();
        bytes4 selector = DelegatecallOnly.DelegatecallOnlyCall.selector;
        vm.expectRevert(abi.encodeWithSelector(selector));
        sibling.mintPOLToken(address(uAsset), address(memecoin), address(liquidProof), 0, 0, 0, 0, 0, block.timestamp);
    }

    // =============================================================================================================
    // Delegatecall smoke — the guard must NOT break the normal facade path. This changeStage run goes through
    // the facade's `functionDelegateCall` into LaunchImpl, which in the Genesis->Locked branch issues a NESTED
    // `functionDelegateCall` into LiquidityImpl.deployBootstrapLiquidity. Passing the guard at both levels
    // (facade->LaunchImpl and LaunchImpl->LiquidityImpl) proves `onlyDelegatecall` lets legitimate nested
    // delegatecall through while only direct calls revert.
    // =============================================================================================================

    function test_Delegatecall_FacadeChangeStageWithNestedLiquidityDelegatecall_Succeeds() external {
        uint256 verseId = 1;
        // flashGenesis verse that has already met the minimum fund; changeStage deploys bootstrap liquidity
        // via a nested delegatecall into the liquidity sibling.
        _seedFlashGenesisVerse(verseId, 120 ether);
        router.setAddLiquidityResult(address(memecoin), address(uAsset), 90 ether, 0, 0);
        router.setAddLiquidityResult(address(liquidProof), address(uAsset), 30 ether, 0, 0);

        IMemeverseLauncher.Stage stage = launcher.changeStage(verseId);

        assertEq(uint256(stage), uint256(IMemeverseLauncher.Stage.Locked), "locked");
        assertEq(uint256(launcher.getStageByVerseId(verseId)), uint256(IMemeverseLauncher.Stage.Locked), "stored stage");
    }

    /// @dev Seeds a flashGenesis verse and its fund metadata directly into proxy storage. Mirrors the
    ///      lifecycle suite's `_setGenesisVerse` + `setFundMetaData` + `setGenesisFundForTest` helper chain
    ///      without inheriting the white-box helper contract.
    function _seedFlashGenesisVerse(uint256 verseId, uint256 genesisFund) internal {
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        bytes32 launcherSlot = 0xe4d68b4f0bdabf27c869795dba7c9a87fd97b24006928b28f58769be5bd8f500;
        // memeverses[verseId] base slot = keccak256(verseId . slot+15)
        bytes32 verseBase = keccak256(abi.encode(verseId, bytes32(uint256(launcherSlot) + 15)));
        // Field layout (per IMemeverseLauncher.Memeverse): slot+4 uAsset|currentStage|flashGenesis (packed),
        // slot+5 memecoin, slot+6 pol, slot+10 endTime|unlockTime (packed uint128), slot+11 omnichainIds length.
        // slot+4 packs uAsset (bytes 0-19), currentStage (byte 20, Genesis=0), flashGenesis (byte 21).
        vm.store(
            address(launcher),
            bytes32(uint256(verseBase) + 4),
            bytes32(
                uint256(uint160(address(uAsset))) | (uint256(uint8(IMemeverseLauncher.Stage.Genesis)) << 160)
                    | (uint256(1) << 168)
            )
        );
        vm.store(address(launcher), bytes32(uint256(verseBase) + 5), bytes32(uint256(uint160(address(memecoin)))));
        vm.store(address(launcher), bytes32(uint256(verseBase) + 6), bytes32(uint256(uint160(address(liquidProof)))));
        // endTime far in the future so the flashGenesis branch (not the time-expired branch) drives the lock.
        uint256 packedEndUnlock = uint256(uint128(block.timestamp + 1 days));
        vm.store(address(launcher), bytes32(uint256(verseBase) + 10), bytes32(packedEndUnlock));
        // omnichainIds: length=1 at slot+11; element 0 at keccak256(slot+11) set to a remote chain id so the
        // remote-governance (predict-only) branch runs (no concrete governor deploy needed for the smoke test).
        bytes32 omnichainSlot = bytes32(uint256(verseBase) + 11);
        vm.store(address(launcher), omnichainSlot, bytes32(uint256(1)));
        vm.store(address(launcher), keccak256(abi.encode(omnichainSlot)), bytes32(uint256(uint32(block.chainid + 1))));
        // totalNormalFunds[verseId] = keccak256(verseId . slot+17)
        vm.store(
            address(launcher), keccak256(abi.encode(verseId, bytes32(uint256(launcherSlot) + 17))), bytes32(genesisFund)
        );
    }
}
