// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {MemeverseUniswapHookV2} from "../mocks/upgrade/MemeverseUniswapHookV2.sol";

/// @notice Upgrade/facet shell that deploys with code but exposes no `poolManager()` getter.
/// @dev The hook's `_authorizeUpgrade` and `_requireFacetPoolManager` probes read through the
///      `ImmutableState.poolManager()` getter; with no matching selector and no fallback the probe call
///      reverts into the probe's catch branch.
contract PoolManagerGetterMissingShell {
    /// @notice Unrelated placeholder whose only job is to give the shell deployed code.
    /// @return Fixed marker value.
    function marker() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Upgrade/facet shell whose `poolManager()` getter exists but always reverts.
contract PoolManagerGetterRevertingShell {
    error GetterReverted();

    /// @notice Getter-shaped probe target that fails on demand.
    function poolManager() external view {
        revert GetterReverted();
    }
}

/// @notice Upgrade/facet shell whose `poolManager()` getter succeeds but returns empty returndata.
contract PoolManagerGetterEmptyReturnShell {
    /// @notice Getter-shaped probe target returning zero bytes of returndata.
    /// @dev A plain view function must return a declared value, so `return(0, 0)` in assembly is the only
    ///      way to make the STATICCALL succeed while returning nothing decodable into an address.
    function poolManager() external view {
        assembly {
            return(0, 0)
        }
    }
}

/// @notice UUPS upgrade and facet-binding guards for the hook proxy.
/// @dev Every test deploys the real MemeverseUniswapHookUpgradeable behind a CREATE2-mined flag-address
///      UUPS proxy (or uses the shared setUp hook) and drives `upgradeToAndCall`/`setFacet` probes,
///      including implementation shells with deliberately broken `poolManager()` getters.
contract MemeverseUniswapHookUpgradeTest is Test, HookStorageHelper {
    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHookUpgradeable internal hook;

    function _deployHookProxy(address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHookUpgradeable deployed)
    {
        // Deploy the real MemeverseUniswapHookUpgradeable, its three facets, and the LP token implementation behind a
        // CREATE2-mined flag-address UUPS proxy so production address validation is exercised.
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), owner_, treasury_);
        deployed = MemeverseUniswapHookUpgradeable(hookProxy);
    }

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        hook = _deployHookProxy(address(this), address(this));
    }

    function testNonOwnerCannotUpgrade() external {
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));

        // UUPS `_authorizeUpgrade` runs under onlyOwner inside the proxy delegatecall context, so a non-owner
        // caller is rejected with OwnableUnauthorizedAccount before the implementation slot is touched.
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(address(newImplementation), "");
    }

    /// @notice Verifies an owner-driven UUPS upgrade to the V2 shell preserves V1 hook storage (owner, treasury,
    ///         launcher, poolInitializer).
    /// @dev The V2 shell cannot inherit V1 (Solidity Error 8894 blocks inheriting a `layout at` contract), so it
    ///      exposes no V1 getters and post-upgrade storage is read via `vm.load` against the V1 storage slots
    ///      (OutrunOwnableUpgradeable owner slot + the hook ERC7201 namespace struct field offsets). UUPS upgrade
    ///      authorization lives on the implementation (`_authorizeUpgrade`, onlyOwner), so the owner can drive the
    ///      upgrade directly through the proxy without a ProxyAdmin.
    function testOwnerCanUpgradeAndPreserveStorage() external {
        MemeverseUniswapHookUpgradeable initialized = MemeverseUniswapHookUpgradeable(
            deployHookAtFlagAddress(IPoolManager(address(mockManager)), address(this), address(0xFEE), address(0xD00D))
        );
        initialized.setPoolInitializer(address(0xBEEF));

        // Snapshot the V1-set storage through the V1 getters while V1 is still live.
        bytes32 ownableSlot = 0x7f241041d6960443a72c6e46e3b41069d0f1a8933ddb434b1da86a3f3cba9f00;
        bytes32 snapshotOwner = vm.load(address(initialized), ownableSlot);
        bytes32 snapshotTreasury = vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_TREASURY));
        bytes32 snapshotLauncher = vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_LAUNCHER));
        bytes32 snapshotPoolInitializer =
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_POOL_INITIALIZER));

        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));

        // Owner drives the upgrade directly through the proxy via UUPS upgradeToAndCall (no ProxyAdmin).
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(address(newImplementation), "");

        assertEq(MemeverseUniswapHookV2(address(initialized)).version(), 2, "version");
        assertEq(vm.load(address(initialized), ownableSlot), snapshotOwner, "owner survived");
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_TREASURY)),
            snapshotTreasury,
            "treasury survived"
        );
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_LAUNCHER)),
            snapshotLauncher,
            "launcher survived"
        );
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_POOL_INITIALIZER)),
            snapshotPoolInitializer,
            "poolInitializer survived"
        );
    }

    function testOwnerCannotUpgradeToImplementationWithDifferentPoolManager() external {
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));
        MockPoolManagerForHookLiquidity differentManager = new MockPoolManagerForHookLiquidity();
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(differentManager)));

        // The hook enforces poolManager drift checks on-chain; a mismatched implementation must revert.
        // Encode the full error (selector + args) because this Foundry version matches `bytes4` exactly,
        // not as a prefix — see the `abi.encodeWithSelector` pattern used elsewhere in this file.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.UpgradePoolManagerMismatch.selector,
                address(mockManager),
                address(differentManager)
            )
        );
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(address(newImplementation), "");
    }

    function testOwnerCannotUpgradeToCodelessImplementation() external {
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));

        // An EOA upgrade target has no code, so the drift-check pre-check must reject it with a
        // named error before the ImmutableState external call would produce an opaque decode revert.
        address eoaTarget = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.UpgradeTargetCodeNotReady.selector, eoaTarget));
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(eoaTarget, "");
    }

    /// @notice Test upgradeToAndCall reverts with the named guard error when the target has code but no
    ///         `poolManager()` getter at all.
    /// @dev Coverage: the `_authorizeUpgrade` probe's catch branch must fold this honest-failure class
    ///      into `UpgradePoolManagerUnreadable` so the upgrade still fails closed with a greppable label
    ///      instead of a bare revert.
    function testUpgradeRevertsWhenPoolManagerGetterMissing() external {
        PoolManagerGetterMissingShell shell = new PoolManagerGetterMissingShell();
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.UpgradePoolManagerUnreadable.selector, address(shell))
        );
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(address(shell), "");
    }

    /// @notice Test upgradeToAndCall reverts with the named guard error when the target's `poolManager()`
    ///         getter exists but reverts.
    /// @dev Coverage: second catch-branch input — a reverting getter must fail closed through the same
    ///      `UpgradePoolManagerUnreadable` label, not surface the getter's own error.
    function testUpgradeRevertsWhenPoolManagerGetterReverts() external {
        PoolManagerGetterRevertingShell shell = new PoolManagerGetterRevertingShell();
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.UpgradePoolManagerUnreadable.selector, address(shell))
        );
        MemeverseUniswapHookUpgradeable(address(initialized)).upgradeToAndCall(address(shell), "");
    }

    /// @notice Test upgradeToAndCall still fails closed when the target's `poolManager()` getter succeeds
    ///         but returns undecodable (empty) data.
    /// @dev Semantic boundary of the catch branch, pinned as an executable negative-space assertion: the
    ///      raw low-level call must revert while its revert selector should NOT equal
    ///      `UpgradePoolManagerUnreadable` — Solidity try/catch does not catch "call succeeded but return
    ///      data cannot be ABI-decoded", so that class bubbles up as the raw decode revert instead of the
    ///      named error; the upgrade is still rejected (fail-closed holds, only the label differs; see
    ///      `_authorizeUpgrade`'s comment and the `UpgradePoolManagerUnreadable` doc comment on the
    ///      interface). A bare `vm.expectRevert()` matches any revert, so it cannot distinguish the two
    ///      labels. `bytes4(ret)` zero-pads returndata shorter than 4 bytes, keeping the selector
    ///      comparison safe for any revert payload shape.
    function testUpgradeRevertsWhenPoolManagerGetterReturnsUndecodableData() external {
        PoolManagerGetterEmptyReturnShell shell = new PoolManagerGetterEmptyReturnShell();
        MemeverseUniswapHookUpgradeable initialized = _deployHookProxy(address(this), address(this));

        // The test contract is the proxy owner (no prank needed): without owner rights the call would die
        // at `onlyOwner` before the probe and the negative-space assertion below would pass vacuously.
        (bool ok, bytes memory ret) =
            address(initialized).call(abi.encodeCall(initialized.upgradeToAndCall, (address(shell), "")));

        assertFalse(ok, "undecodable getter returndata must still reject the upgrade (fail-closed)");
        assertFalse(
            bytes4(ret) == IMemeverseUniswapHook.UpgradePoolManagerUnreadable.selector,
            "decode failure must bubble up as the raw decode revert, not fold into the named error"
        );
    }

    /// @notice Test setFacet reverts with the named guard error when the facet has code but no
    ///         `poolManager()` getter at all.
    /// @dev Coverage: `_requireFacetPoolManager`'s catch branch must fold this honest-failure class into
    ///      `FacetPoolManagerUnreadable` instead of a bare revert, mirroring the upgrade probe. The
    ///      `hook` from setUp is used directly because its owner is this test contract.
    function testSetFacetRevertsWhenPoolManagerGetterMissing() external {
        PoolManagerGetterMissingShell shell = new PoolManagerGetterMissingShell();
        // Read the role constant BEFORE arming expectRevert: the constant-getter call is itself an
        // external call and would otherwise consume the cheatcode instead of the setFacet call.
        bytes32 swapFacetRole = hook.SWAP_FACET_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.FacetPoolManagerUnreadable.selector, address(shell))
        );
        hook.setFacet(swapFacetRole, address(shell));
    }
}
