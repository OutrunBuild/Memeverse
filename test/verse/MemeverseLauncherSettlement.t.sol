// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {OutrunOwnable} from "../../src/common/access/OutrunOwnable.sol";

import {MockPOLendForLifecycle, MockPOLSplitterForLifecycle} from "../mocks/verse/LauncherLifecycleMocks.sol";

/// @notice Targeted guard tests for the `settlementImpl` zero-address check covering refund/YT/fee entries and the
///         Locked->Unlocked `changeStage` branch.
/// @dev The launcher facade delegatecalls the `MemeverseSettlementImpl` sibling for refund / YT / fee claim
///      entries (`refund`, `refundPreorder`, `claimNormalYT`, `claimNormalFees`, `claimUnlockedPreorderMemecoin`),
///      fee collection/distribution (`redeemAndDistributeFees`), and the Locked->Unlocked `changeStage` branch
///      (`unlockFromLocked`); if the sibling is unset the facade reverts with `SettlementImplNotSet` before the
///      delegatecall. Mirrors the `MemeverseLauncherBootstrapLiquidity` guard-test structure. The guard fires
///      before any external call, so the fixture seeds a Locked verse directly via storage (no bootstrap liquidity
///      deployment required).
contract MemeverseLauncherSettlementTest is Test, MemeverseLauncherTestHelper {
    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockERC20 internal uAsset;
    MockERC20 internal memecoin;
    MockERC20 internal pol;
    MockPOLendForLifecycle internal polend;
    MockPOLSplitterForLifecycle internal splitter;

    /// @notice Deploys the launcher proxy and supporting mocks, but intentionally leaves `settlementImpl` unset.
    function setUp() external {
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        pol = new MockERC20("POL", "POL", 18);
        polend = new MockPOLendForLifecycle();
        splitter = new MockPOLSplitterForLifecycle(address(pol), address(uAsset));
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
        // Bind the launch sibling so `changeStage` delegatecalls into `LaunchImpl.changeStage`, whose
        // Locked branch performs the nested `settlementImpl.unlockFromLocked` delegatecall and reaches
        // the SettlementImplNotSet guard below. settlementImpl stays unset (the point of these tests).
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        // Deliberately omitted: launcher.setSettlementImpl(...). Each test asserts the guard explicitly.
    }

    /// @notice Seeds a verse directly to `Locked` so fee-distribution entries pass their stage precheck and
    ///         reach the `settlementImpl` zero-address guard. `unlockTime = 0` makes `block.timestamp > unlockTime`
    ///         true so `changeStage` routes into the Locked->Unlocked branch.
    function _seedLockedVerse(uint256 verseId) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
            address(uAsset),
            address(memecoin),
            address(pol),
            address(0),
            address(0),
            address(0),
            0,
            0,
            IMemeverseLauncher.Stage.Locked,
            false
        );
    }

    /// @notice Verifies `redeemAndDistributeFees` reverts when `settlementImpl` is unset.
    /// @dev The facade validates rewardReceiver/stage, then hits the guard before the delegatecall.
    function test_revertsWhenSettlementImplNotSet_redeem() external {
        uint256 verseId = 1;
        _seedLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.SettlementImplNotSet.selector);
        launcher.redeemAndDistributeFees(verseId, makeAddr("reward"));
    }

    /// @notice Verifies `changeStage` (Locked->Unlocked) reverts when `settlementImpl` is unset.
    /// @dev The Locked->Unlocked branch delegatecalls the sibling's `unlockFromLocked` (which captures auxiliary
    ///      fees, advances the stage, settles POLSplitter/POLend, and arms public-swap protection); the guard
    ///      surfaces as `SettlementImplNotSet` before the delegatecall, leaving the stage untouched.
    function test_revertsWhenSettlementImplNotSet_changeStageUnlock() external {
        uint256 verseId = 1;
        _seedLockedVerse(verseId);

        vm.expectRevert(IMemeverseLauncher.SettlementImplNotSet.selector);
        launcher.changeStage(verseId);

        assertEq(
            uint256(launcher.getStageByVerseId(verseId)),
            uint256(IMemeverseLauncher.Stage.Locked),
            "stage unchanged after guard revert"
        );
    }

    /// @notice A direct (non-delegatecall) invocation of the settlement sibling must revert.
    /// @dev The sibling shares no storage with the proxy; its own `memeverseLauncherStorage` is permanently
    ///      uninitialized, so `collectAndDistributeFees` reads an empty verse/hook and reverts on the resulting
    ///      call to address(0). Locks the "collectAndDistributeFees is facade-delegatecall-only" invariant.
    function test_directCallToDistributorReverts() external {
        MemeverseSettlementImpl sibling = new MemeverseSettlementImpl();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        sibling.collectAndDistributeFees(1, makeAddr("reward"), address(splitter));
    }

    /// @notice `setSettlementImpl` rejects a zero address and unauthorized callers.
    function test_setSettlementImplGuards() external {
        // Zero address rejected (owner caller).
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setSettlementImpl(address(0));

        // Non-owner rejected.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, attacker));
        launcher.setSettlementImpl(address(1));
    }

    /// @notice `setFeePreviewReader` rejects a zero address and unauthorized callers.
    function test_setFeePreviewReaderGuards() external {
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setFeePreviewReader(address(0));

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, attacker));
        launcher.setFeePreviewReader(address(1));
    }
}
