// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {DeployMemeverseHookProxy} from "../../script/DeployMemeverseHookProxy.s.sol";
import {IOutrunDeployer} from "../../script/IOutrunDeployer.sol";
import {OutrunDeployer} from "../../script/deployment/OutrunDeployer.sol";
import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {FakeDeploymentHook} from "../mocks/swap/FakeDeploymentHook.sol";
import {MemeverseUniswapHookV2} from "../mocks/upgrade/MemeverseUniswapHookV2.sol";

contract DeployMemeverseHookProxyHarness is DeployMemeverseHookProxy {
    function exposedComputeSwapFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
        view
        returns (bytes32 salt, address facet)
    {
        return _computeSwapFacet(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedComputeDynamicFeeFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
        view
        returns (bytes32 salt, address facet)
    {
        return _computeDynamicFeeFacet(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedComputeSettlementFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
        view
        returns (bytes32 salt, address facet)
    {
        return _computeSettlementFacet(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedComputeHookImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
        view
        returns (bytes32 salt, address impl)
    {
        return _computeHookImpl(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedComputeLpTokenImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
        view
        returns (bytes32 salt, address impl)
    {
        return _computeLpTokenImpl(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedDeploySwapFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) external {
        _deploySwapFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
    }

    function exposedDeployDynamicFeeFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) external {
        _deployDynamicFeeFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
    }

    function exposedDeploySettlementFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) external {
        _deploySettlementFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
    }

    function exposedDeployHookImpl(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) external {
        _deployHookImpl(outrunDeployer, deployerNamespace, nonce, poolManager);
    }

    function exposedDeployLpTokenImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        external
    {
        _deployLpTokenImpl(outrunDeployer, deployerNamespace, nonce);
    }

    function exposedSelectProxySalt(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        address hookOwner,
        address hookTreasury,
        IPoolManager poolManager,
        address hookLauncher
    ) external view returns (bytes32 salt, address proxy, bool reuseExistingProxy) {
        return _selectProxySalt(
            outrunDeployer, deployerNamespace, nonce, hookOwner, hookTreasury, poolManager, hookLauncher
        );
    }
}

contract DeployMemeverseHookProxyTest is Test {
    using Bytes32AddressLib for bytes32;

    address internal constant POOL_MANAGER = address(0x1001);
    address internal constant HOOK_OWNER = address(0x1002);
    address internal constant HOOK_TREASURY = address(0x1003);
    address internal constant DEPLOYER_NAMESPACE = address(0x1004);
    address internal constant HOOK_LAUNCHER = address(0x1005);

    // Same constant as DeployMemeverseHookProxy — solmate CREATE3 minimal proxy bytecode hash.
    bytes32 internal constant CREATE3_PROXY_BYTECODE_HASH = keccak256(hex"67363d3d37363d34f03d5260086018f3");
    bytes4 internal constant UNUSABLE_HOOK_OWNER_SELECTOR = bytes4(keccak256("UnusableHookOwner(address)"));
    bytes4 internal constant OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    OutrunDeployer internal outrunDeployer;
    DeployMemeverseHookProxyHarness internal script;

    function setUp() external {
        outrunDeployer = new OutrunDeployer(address(this));
        script = new DeployMemeverseHookProxyHarness();
        vm.setEnv("EXPECTED_HOOK_PROXY_CODEHASH", vm.toString(bytes32(0)));
        vm.setEnv("EXPECTED_HOOK_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(0)));
        vm.setEnv("EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(0)));
        vm.setEnv("EXPECTED_SWAP_FACET_CODEHASH", vm.toString(bytes32(0)));
        vm.setEnv("EXPECTED_DYNAMIC_FEE_FACET_CODEHASH", vm.toString(bytes32(0)));
        vm.setEnv("EXPECTED_SETTLEMENT_FACET_CODEHASH", vm.toString(bytes32(0)));
    }

    function testMinesSaltForOutrunDeployerAddressWithExpectedHookFlags() external view {
        (bytes32 salt, address proxy) =
            script.mineProxySalt(IOutrunDeployer(address(outrunDeployer)), DEPLOYER_NAMESPACE);

        assertEq(uint160(proxy) & script.uniswapV4HookFlagMask(), script.memeverseHookFlags());
        assertEq(outrunDeployer.getDeployed(DEPLOYER_NAMESPACE, salt), proxy);
    }

    function testMineProxySaltSkipsOccupiedMatchingAddress() external {
        (bytes32 occupiedSalt, address occupiedProxy) =
            script.mineProxySalt(IOutrunDeployer(address(outrunDeployer)), DEPLOYER_NAMESPACE);
        vm.etch(occupiedProxy, hex"01");

        (bytes32 nextSalt, address nextProxy) =
            script.mineProxySalt(IOutrunDeployer(address(outrunDeployer)), DEPLOYER_NAMESPACE);

        assertTrue(nextSalt != occupiedSalt);
        assertTrue(nextProxy != occupiedProxy);
        assertEq(uint160(nextProxy) & script.uniswapV4HookFlagMask(), script.memeverseHookFlags());
    }

    function testSameSaltPredictsDeterministicAddress() external view {
        bytes32 salt = bytes32(uint256(123));
        address predicted = outrunDeployer.getDeployed(DEPLOYER_NAMESPACE, salt);

        assertEq(outrunDeployer.getDeployed(DEPLOYER_NAMESPACE, salt), predicted);
    }

    function testDifferentDeployerNamespacePredictsDifferentAddress() external view {
        bytes32 salt = bytes32(uint256(123));

        assertTrue(
            outrunDeployer.getDeployed(DEPLOYER_NAMESPACE, salt) != outrunDeployer.getDeployed(address(0x9999), salt)
        );
    }

    function testDeployProxyInitializesHookAtMinedAddress() external {
        (bytes32 salt, address predictedProxy,) = script.exposedSelectProxySalt(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            1,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        MemeverseUniswapHookUpgradeable hook = MemeverseUniswapHookUpgradeable(r.hookProxy);

        assertEq(outrunDeployer.getDeployed(address(script), salt), predictedProxy);
        assertEq(r.hookProxy, predictedProxy);
        assertGt(r.hookImplementation.code.length, 0);
        assertGt(r.hookProxy.code.length, 0);
        // UUPS carries no ProxyAdmin: only the implementation slot is checked (owner is verified via hook.owner()).
        assertGt(r.lpTokenImplementation.code.length, 0);
        assertGt(r.swapFacet.code.length, 0);
        assertGt(r.dynamicFeeFacet.code.length, 0);
        assertGt(r.settlementFacet.code.length, 0);
        assertEq(uint160(r.hookProxy) & script.uniswapV4HookFlagMask(), script.memeverseHookFlags());
        assertEq(hook.owner(), HOOK_OWNER);
        assertEq(hook.treasury(), HOOK_TREASURY);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.lpTokenImplementation(), r.lpTokenImplementation);
        assertEq(hook.swapFacet(), r.swapFacet);
        assertEq(hook.dynamicFeeFacet(), r.dynamicFeeFacet);
        assertEq(hook.settlementFacet(), r.settlementFacet);
        // Each facet binds the same PoolManager immutably; under delegatecall it settles/takes against it.
        assertEq(address(ImmutableState(r.swapFacet).poolManager()), POOL_MANAGER);
        assertEq(address(ImmutableState(r.dynamicFeeFacet).poolManager()), POOL_MANAGER);
        assertEq(address(ImmutableState(r.settlementFacet).poolManager()), POOL_MANAGER);
        assertEq(
            address(uint160(uint256(vm.load(r.hookProxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), r.hookImplementation
        );
    }

    function testRunReadsDeploymentNonceFromEnv() external {
        uint256 privateKey = 1;
        address deploymentSender = vm.addr(privateKey);
        uint256 deploymentNonce = 7;
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(deploymentSender);
        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("OUTRUN_DEPLOYER", vm.toString(address(outrunDeployer)));
        vm.setEnv("POOL_MANAGER", vm.toString(POOL_MANAGER));
        vm.setEnv("HOOK_OWNER", vm.toString(HOOK_OWNER));
        vm.setEnv("HOOK_TREASURY", vm.toString(HOOK_TREASURY));
        vm.setEnv("MEMEVERSE_LAUNCHER", vm.toString(HOOK_LAUNCHER));
        vm.setEnv("DEPLOYMENT_NONCE", vm.toString(deploymentNonce));
        script.setUp();

        (bytes32 expectedHookImplSalt, address expectedHookImpl) =
            script.exposedComputeHookImpl(IOutrunDeployer(address(outrunDeployer)), deploymentSender, deploymentNonce);
        (bytes32 expectedLpTokenImplSalt, address expectedLpTokenImpl) = script.exposedComputeLpTokenImpl(
            IOutrunDeployer(address(outrunDeployer)), deploymentSender, deploymentNonce
        );
        (bytes32 expectedSettlementFacetSalt, address expectedSettlementFacet) = script.exposedComputeSettlementFacet(
            IOutrunDeployer(address(outrunDeployer)), deploymentSender, deploymentNonce
        );
        (bytes32 expectedSwapFacetSalt, address expectedSwapFacet) =
            script.exposedComputeSwapFacet(IOutrunDeployer(address(outrunDeployer)), deploymentSender, deploymentNonce);
        (bytes32 expectedDynamicFeeFacetSalt, address expectedDynamicFeeFacet) = script.exposedComputeDynamicFeeFacet(
            IOutrunDeployer(address(outrunDeployer)), deploymentSender, deploymentNonce
        );

        DeployMemeverseHookProxy.DeploymentResult memory r = script.run();

        assertEq(r.hookImplementation, expectedHookImpl);
        assertEq(r.lpTokenImplementation, expectedLpTokenImpl);
        assertEq(r.swapFacet, expectedSwapFacet);
        assertEq(r.dynamicFeeFacet, expectedDynamicFeeFacet);
        assertEq(r.settlementFacet, expectedSettlementFacet);
        assertEq(
            MemeverseUniswapHookUpgradeable(r.hookProxy).launcher(), HOOK_LAUNCHER, "hook launcher bound at deploy"
        );
        assertGt(r.hookProxy.code.length, 0);
        assertEq(outrunDeployer.getDeployed(deploymentSender, expectedHookImplSalt), expectedHookImpl);
        assertEq(outrunDeployer.getDeployed(deploymentSender, expectedLpTokenImplSalt), expectedLpTokenImpl);
        assertEq(outrunDeployer.getDeployed(deploymentSender, expectedSwapFacetSalt), expectedSwapFacet);
        assertEq(outrunDeployer.getDeployed(deploymentSender, expectedDynamicFeeFacetSalt), expectedDynamicFeeFacet);
        assertEq(outrunDeployer.getDeployed(deploymentSender, expectedSettlementFacetSalt), expectedSettlementFacet);
    }

    function testDeployProxyRejectsPoolManagerWithoutCode() external {
        _deployExpectingRevert(
            abi.encodeWithSelector(DeployMemeverseHookProxy.PoolManagerCodeNotReady.selector, POOL_MANAGER)
        );
    }

    function testDeployProxyRejectsHookOwnerEqualToPredictedHookProxy() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        address selectedProxy = script.getPredictedProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            nonce,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );

        _deployExpectingRevert(abi.encodeWithSelector(UNUSABLE_HOOK_OWNER_SELECTOR, selectedProxy), selectedProxy);
    }

    function testReusesExistingDeployment() external {
        // First deploy: creates facets + hook proxy.
        DeployMemeverseHookProxy.DeploymentResult memory first = _deployHookProxyForTest();
        assertGt(first.lpTokenImplementation.code.length, 0);
        assertGt(first.swapFacet.code.length, 0);
        assertGt(first.dynamicFeeFacet.code.length, 0);
        assertGt(first.settlementFacet.code.length, 0);
        _setExpectedImplementationCodehashes(first.hookProxy);

        // Second deploy with same nonce: idempotent through the already validated hook proxy.
        vm.prank(address(script));
        DeployMemeverseHookProxy.DeploymentResult memory second = script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            IPoolManager(POOL_MANAGER),
            HOOK_OWNER,
            HOOK_TREASURY,
            HOOK_LAUNCHER,
            1
        );

        // All addresses must be identical — deterministic CREATE3 salts guarantee this.
        assertEq(second.hookImplementation, first.hookImplementation);
        assertEq(second.hookProxy, first.hookProxy);
        assertEq(second.lpTokenImplementation, first.lpTokenImplementation);
        assertEq(second.swapFacet, first.swapFacet);
        assertEq(second.dynamicFeeFacet, first.dynamicFeeFacet);
        assertEq(second.settlementFacet, first.settlementFacet);

        // State is intact: owner, poolManager, and facet bindings unchanged.
        assertEq(MemeverseUniswapHookUpgradeable(second.hookProxy).owner(), HOOK_OWNER);
        assertEq(address(MemeverseUniswapHookUpgradeable(second.hookProxy).poolManager()), POOL_MANAGER);
        assertEq(MemeverseUniswapHookUpgradeable(second.hookProxy).lpTokenImplementation(), first.lpTokenImplementation);
        assertEq(MemeverseUniswapHookUpgradeable(second.hookProxy).swapFacet(), first.swapFacet);
        assertEq(MemeverseUniswapHookUpgradeable(second.hookProxy).dynamicFeeFacet(), first.dynamicFeeFacet);
        assertEq(MemeverseUniswapHookUpgradeable(second.hookProxy).settlementFacet(), first.settlementFacet);
    }

    function testSameNonceReuseRejectsStaleHookImplementationBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        // The stale fake implementation has its own slot-0 owner getter. Seed slot-0 owner so owner-read in
        // _validateExistingDeployment does not short-circuit before reaching the implementation-codehash
        // check this test targets.
        _assertStaleBytecodeReverts(
            r,
            r.hookImplementation,
            DeployMemeverseHookProxy.CodehashMismatch.selector,
            bytes32(0),
            bytes32(uint256(uint160(HOOK_OWNER)))
        );
    }

    /// @dev Deploys a hook proxy with the standard test config; shared by the stale-bytecode codehash tests.
    function _deployHookProxyForTest() internal returns (DeployMemeverseHookProxy.DeploymentResult memory r) {
        return _deployHookProxyForTest(1);
    }

    /// @dev Variant for tests that need a non-default nonce (e.g. nonce-scoped prediction tests).
    function _deployHookProxyForTest(uint256 nonce)
        internal
        returns (DeployMemeverseHookProxy.DeploymentResult memory r)
    {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));
        vm.prank(address(script));
        r = script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            IPoolManager(POOL_MANAGER),
            HOOK_OWNER,
            HOOK_TREASURY,
            HOOK_LAUNCHER,
            nonce
        );
    }

    /// @dev Re-runs `deployHookProxy` (nonce=1) under the script prank, expecting `encodedError`.
    ///      Consolidates the prank + expectRevert + redeploy sequence shared by the stale-bytecode,
    ///      slot-spoof, and UnusableHookOwner tests.
    function _deployExpectingRevert(bytes memory encodedError) internal {
        _deployExpectingRevert(encodedError, HOOK_OWNER);
    }

    /// @dev Variant for tests that pass a non-default hookOwner (e.g. UnusableHookOwner cases where
    ///      hookOwner is the predicted proxy/admin address).
    function _deployExpectingRevert(bytes memory encodedError, address hookOwner) internal {
        vm.prank(address(script));
        vm.expectRevert(encodedError);
        script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            IPoolManager(POOL_MANAGER),
            hookOwner,
            HOOK_TREASURY,
            HOOK_LAUNCHER,
            1
        );
    }

    /// @dev Variant for tests that pass a non-default hookLauncher (e.g. launcher mismatch on reuse).
    function _deployExpectingRevert(bytes memory encodedError, address hookOwner, address hookLauncher) internal {
        vm.prank(address(script));
        vm.expectRevert(encodedError);
        script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            IPoolManager(POOL_MANAGER),
            hookOwner,
            HOOK_TREASURY,
            hookLauncher,
            1
        );
    }

    /// @dev Etches stale bytecode at `target`, then re-deploys expecting the codehash-mismatch revert.
    function _assertStaleBytecodeReverts(
        DeployMemeverseHookProxy.DeploymentResult memory r,
        address target,
        bytes4 mismatchSelector
    ) internal {
        bytes32 expectedCodehash = target.codehash;
        _setExpectedImplementationCodehashes(r.hookProxy);
        FakeDeploymentHook stale = new FakeDeploymentHook();
        vm.etch(target, address(stale).code);
        bytes32 currentCodehash = target.codehash;

        _deployExpectingRevert(abi.encodeWithSelector(mismatchSelector, target, expectedCodehash, currentCodehash));
    }

    /// @dev Variant that seeds a proxy storage slot before the stale-bytecode check — used by the
    ///      hook-implementation test where `FakeDeploymentHook.owner()` reads slot 0 under delegatecall.
    function _assertStaleBytecodeReverts(
        DeployMemeverseHookProxy.DeploymentResult memory r,
        address target,
        bytes4 mismatchSelector,
        bytes32 seedSlot,
        bytes32 seedValue
    ) internal {
        vm.store(r.hookProxy, seedSlot, seedValue);
        _assertStaleBytecodeReverts(r, target, mismatchSelector);
    }

    function testSameNonceReuseRejectsStaleSwapFacetBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _assertStaleBytecodeReverts(r, r.swapFacet, DeployMemeverseHookProxy.CodehashMismatch.selector);
    }

    function testSameNonceReuseRejectsStaleDynamicFeeFacetBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _assertStaleBytecodeReverts(r, r.dynamicFeeFacet, DeployMemeverseHookProxy.CodehashMismatch.selector);
    }

    function testSameNonceReuseRejectsStaleSettlementFacetBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _assertStaleBytecodeReverts(r, r.settlementFacet, DeployMemeverseHookProxy.CodehashMismatch.selector);
    }

    function testSameNonceReuseRejectsStaleLPTokenImplementationBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _assertStaleBytecodeReverts(r, r.lpTokenImplementation, DeployMemeverseHookProxy.CodehashMismatch.selector);
    }

    function testSameNonceReuseRejectsStaleHookProxyBytecode() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        // proxy.codehash is checked first in _validateExistingImplementationCodehashes, so etching stale
        // bytecode at the proxy trips CodehashMismatch before any slot is read.
        _assertStaleBytecodeReverts(r, r.hookProxy, DeployMemeverseHookProxy.CodehashMismatch.selector);
    }

    /// @notice A reused proxy whose owner slot was corrupted is rejected at the deeper
    ///         _validateExistingDeployment layer (owner mismatch); under UUPS there is no ProxyAdmin, so the
    ///         corrupted owner slot is the only signal needed.
    /// @dev Corrupts the ERC7201 `outrun.storage.Ownable` slot; codehash checks still pass (a storage write
    ///      doesn't change bytecode), and the script reaches `_validateExistingDeployment` which reverts with
    ///      `ExistingHookOwnerMismatch`. Other storage-backed fields (treasury) follow the same mechanism;
    ///      code-backed fields (impl/lpTokenImpl/facets/poolManager) are guarded earlier by the codehash checks.
    function testSameNonceReuseRejectsExistingHookOwnerMismatch() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _setExpectedImplementationCodehashes(r.hookProxy);
        // UUPS has no ProxyAdmin: corrupting only the proxy owner slot falls through to
        // `_validateExistingDeployment` which reverts `ExistingHookOwnerMismatch`.
        bytes32 OWNABLE_SLOT = 0x7f241041d6960443a72c6e46e3b41069d0f1a8933ddb434b1da86a3f3cba9f00;
        address stranger = address(0xB0B0);
        vm.store(r.hookProxy, OWNABLE_SLOT, bytes32(uint256(uint160(stranger))));
        _deployExpectingRevert(
            abi.encodeWithSelector(
                DeployMemeverseHookProxy.ExistingHookOwnerMismatch.selector, r.hookProxy, HOOK_OWNER, stranger
            )
        );
    }

    /// @notice A same-nonce reuse that supplies a different launcher is rejected.
    /// @dev The launcher is init-bound and write-once under C1, so `_validateExistingDeployment` reverts
    ///      `ExistingHookLauncherMismatch` when the caller-supplied launcher differs from the on-chain binding
    ///      (a stale/wrong MEMEVERSE_LAUNCHER env must not be silently accepted on reuse).
    function testSameNonceReuseRejectsExistingHookLauncherMismatch() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _setExpectedImplementationCodehashes(r.hookProxy);
        address stranger = address(0xB0B0);
        _deployExpectingRevert(
            abi.encodeWithSelector(
                DeployMemeverseHookProxy.ExistingHookLauncherMismatch.selector, r.hookProxy, stranger, HOOK_LAUNCHER
            ),
            HOOK_OWNER,
            stranger
        );
    }

    /// @notice A reused proxy whose on-chain owner slot was rewritten to the proxy's own address
    ///         (self-ownership) is rejected on the reuse path because it would brick UUPS upgrades.
    /// @dev `_validateExistingDeployment` checks `_requireUsableHookOwner(actual.hookOwner, proxy)` before
    ///      comparing the owner with caller-supplied `HOOK_OWNER`, so this case reverts `UnusableHookOwner`.
    function testSameNonceReuseRejectsSelfOwnedProxy() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();
        _setExpectedImplementationCodehashes(r.hookProxy);
        // Rewrite the on-chain owner slot to the proxy address, simulating a self-owned (bricked) proxy.
        bytes32 OWNABLE_SLOT = 0x7f241041d6960443a72c6e46e3b41069d0f1a8933ddb434b1da86a3f3cba9f00;
        vm.store(r.hookProxy, OWNABLE_SLOT, bytes32(uint256(uint160(r.hookProxy))));
        _deployExpectingRevert(abi.encodeWithSelector(UNUSABLE_HOOK_OWNER_SELECTOR, r.hookProxy));
    }

    /// @notice Under UUPS the hook owner drives upgrades directly through the proxy (no ProxyAdmin): a
    ///         non-owner is rejected by `_authorizeUpgrade`'s `onlyOwner` guard, and the owner can upgrade
    ///         to a fresh implementation that itself carries UUPS (so the proxy never locks).
    function testOwnerCanUpgradeViaUUPS() external {
        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();

        MemeverseUniswapHookUpgradeable hook = MemeverseUniswapHookUpgradeable(r.hookProxy);
        address newOwner = address(0xB0B0);

        assertEq(hook.owner(), HOOK_OWNER);

        MemeverseUniswapHookV2 newImpl = new MemeverseUniswapHookV2(IPoolManager(POOL_MANAGER));

        // Non-owner upgrade is rejected by UUPS `_authorizeUpgrade` (onlyOwner) in the proxy delegatecall context.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, newOwner));
        hook.upgradeToAndCall(address(newImpl), "");

        // Owner drives the upgrade directly via UUPS; the proxy address is preserved and V2's marker is live.
        vm.prank(HOOK_OWNER);
        hook.upgradeToAndCall(address(newImpl), "");
        assertEq(MemeverseUniswapHookV2(r.hookProxy).version(), 2);
    }

    function testNewNonceDeploysNewHookProxyInsteadOfReusingOlderProxy() external {
        DeployMemeverseHookProxy.DeploymentResult memory first = _deployHookProxyForTest();

        vm.prank(address(script));
        DeployMemeverseHookProxy.DeploymentResult memory second = script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            IPoolManager(POOL_MANAGER),
            HOOK_OWNER,
            HOOK_TREASURY,
            HOOK_LAUNCHER,
            2
        );

        assertTrue(second.hookProxy != first.hookProxy);
        assertGt(second.hookProxy.code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(second.hookProxy).swapFacet().code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(second.hookProxy).dynamicFeeFacet().code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(second.hookProxy).settlementFacet().code.length, 0);
        assertEq(
            address(ImmutableState(MemeverseUniswapHookUpgradeable(second.hookProxy).swapFacet()).poolManager()),
            POOL_MANAGER
        );
    }

    function testOccupiedGlobalFirstHookFlagAddressDoesNotBlockNonceProxyDeploy() external {
        address globalFirstProxy = script.getPredictedProxy(IOutrunDeployer(address(outrunDeployer)), address(script));
        vm.etch(globalFirstProxy, hex"01");

        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest();

        assertTrue(r.hookProxy != globalFirstProxy);
        assertGt(r.hookProxy.code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(r.hookProxy).swapFacet().code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(r.hookProxy).dynamicFeeFacet().code.length, 0);
        assertGt(MemeverseUniswapHookUpgradeable(r.hookProxy).settlementFacet().code.length, 0);
        assertEq(
            address(ImmutableState(MemeverseUniswapHookUpgradeable(r.hookProxy).swapFacet()).poolManager()),
            POOL_MANAGER
        );
    }

    function testNonceScopedPredictedProxyMatchesDeployedProxy() external {
        // Skipped under coverage: the nonce=11 salt-mining loop blows past the per-call gas cap when
        // instrumentation is injected.
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        uint256 nonce = 11;
        address predictedProxy = script.getPredictedProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            nonce,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );

        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest(nonce);

        assertEq(r.hookProxy, predictedProxy);
    }

    function testNonceScopedSelectedPredictionSkipsDirtyCandidate() external {
        uint256 nonce = 498;
        address firstCandidate =
            script.getPredictedProxy(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        vm.etch(firstCandidate, hex"01");

        address predictedProxy = script.getPredictedProxy(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            nonce,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );

        DeployMemeverseHookProxy.DeploymentResult memory r = _deployHookProxyForTest(nonce);

        assertTrue(predictedProxy != firstCandidate);
        assertEq(r.hookProxy, predictedProxy);
    }

    function testDeployProxyRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        // Simulate a previous failed deploy: the CREATE3 minimal proxy was deployed
        // (CREATE2 succeeded) but the inner CREATE failed (e.g. initialization reverted).
        // The final proxy address has no code, but the CREATE3 proxy is occupied.
        (bytes32 salt,,) = script.exposedSelectProxySalt(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            1,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );
        bytes32 hashedSalt = keccak256(abi.encodePacked(address(script), salt));
        address create3Proxy = keccak256(
                abi.encodePacked(bytes1(0xFF), address(outrunDeployer), hashedSalt, CREATE3_PROXY_BYTECODE_HASH)
            ).fromLast20Bytes();
        vm.etch(create3Proxy, hex"01");

        // Re-running with the same nonce should revert with a clear error indicating
        // the CREATE3 salt is consumed, not the opaque "DEPLOYMENT_FAILED" from solmate.
        _deployExpectingRevert(
            abi.encodeWithSelector(DeployMemeverseHookProxy.Create3SaltConsumed.selector, salt, create3Proxy)
        );
    }

    function testDeployProxyRejectsConsumedHookProxySaltBeforeIntermediateDeploys() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 hookProxySalt,,) = script.exposedSelectProxySalt(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            nonce,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );
        address hookCreate3Proxy = _create3ProxyAddress(address(script), hookProxySalt);
        vm.etch(hookCreate3Proxy, hex"01");

        (, address lpTokenImpl) =
            script.exposedComputeLpTokenImpl(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        (bytes32 swapFacetSalt, address swapFacet) =
            script.exposedComputeSwapFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        (, address dynamicFeeFacet) =
            script.exposedComputeDynamicFeeFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        (, address settlementFacet) =
            script.exposedComputeSettlementFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        (, address hookImpl) =
            script.exposedComputeHookImpl(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);

        // If hook proxy salt validation is late, this occupied swap-facet CREATE3 proxy is hit first.
        vm.etch(_create3ProxyAddress(address(script), swapFacetSalt), hex"01");

        _deployExpectingRevert(
            abi.encodeWithSelector(
                DeployMemeverseHookProxy.Create3SaltConsumed.selector, hookProxySalt, hookCreate3Proxy
            )
        );

        assertEq(lpTokenImpl.code.length, 0);
        assertEq(swapFacet.code.length, 0);
        assertEq(dynamicFeeFacet.code.length, 0);
        assertEq(settlementFacet.code.length, 0);
        assertEq(hookImpl.code.length, 0);
    }

    /// @dev Asserts an occupied intermediate-deployment address (stale bytecode) is rejected and the next
    ///      intermediate's CREATE3 salt is NOT consumed. Shared by the 5 occupation-guard tests.
    function _assertIntermediateDeploymentNotReusable(address occupied, address nextCreate3Proxy) internal {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));
        vm.etch(occupied, hex"01");

        _deployExpectingRevert(
            abi.encodeWithSelector(
                DeployMemeverseHookProxy.ExistingIntermediateDeploymentNotReusable.selector, occupied
            )
        );

        assertEq(nextCreate3Proxy.code.length, 0);
    }

    function testDeployProxyRejectsOccupiedLpTokenImplementationBeforeSwapFacetSaltUse() external {
        (, address lpTokenImpl) =
            script.exposedComputeLpTokenImpl(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        (bytes32 swapFacetSalt,) =
            script.exposedComputeSwapFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        _assertIntermediateDeploymentNotReusable(lpTokenImpl, _create3ProxyAddress(address(script), swapFacetSalt));
    }

    function testDeployProxyRejectsOccupiedSwapFacetBeforeDynamicFeeFacetSaltUse() external {
        (, address swapFacet) =
            script.exposedComputeSwapFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        (bytes32 dynamicFeeFacetSalt,) =
            script.exposedComputeDynamicFeeFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        _assertIntermediateDeploymentNotReusable(swapFacet, _create3ProxyAddress(address(script), dynamicFeeFacetSalt));
    }

    function testDeployProxyRejectsOccupiedDynamicFeeFacetBeforeSettlementFacetSaltUse() external {
        (, address dynamicFeeFacet) =
            script.exposedComputeDynamicFeeFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        (bytes32 settlementFacetSalt,) =
            script.exposedComputeSettlementFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        _assertIntermediateDeploymentNotReusable(
            dynamicFeeFacet, _create3ProxyAddress(address(script), settlementFacetSalt)
        );
    }

    function testDeployProxyRejectsOccupiedSettlementFacetBeforeHookImplementationSaltUse() external {
        (, address settlementFacet) =
            script.exposedComputeSettlementFacet(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        (bytes32 hookImplSalt,) =
            script.exposedComputeHookImpl(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        _assertIntermediateDeploymentNotReusable(settlementFacet, _create3ProxyAddress(address(script), hookImplSalt));
    }

    function testDeployProxyRejectsOccupiedHookImplementationBeforeHookProxySaltUse() external {
        (bytes32 hookProxySalt,,) = script.exposedSelectProxySalt(
            IOutrunDeployer(address(outrunDeployer)),
            address(script),
            1,
            HOOK_OWNER,
            HOOK_TREASURY,
            IPoolManager(POOL_MANAGER),
            HOOK_LAUNCHER
        );
        (, address hookImpl) =
            script.exposedComputeHookImpl(IOutrunDeployer(address(outrunDeployer)), address(script), 1);
        _assertIntermediateDeploymentNotReusable(hookImpl, _create3ProxyAddress(address(script), hookProxySalt));
    }

    function testDeploySwapFacetRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 salt,) =
            script.exposedComputeSwapFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        address create3Proxy = _create3ProxyAddress(address(script), salt);
        vm.etch(create3Proxy, hex"01");

        vm.expectPartialRevert(DeployMemeverseHookProxy.ArtifactCreate3SaltConsumed.selector);
        script.exposedDeploySwapFacet(
            IOutrunDeployer(address(outrunDeployer)), address(script), nonce, IPoolManager(POOL_MANAGER)
        );
    }

    function testDeployLPTokenImplRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 salt,) =
            script.exposedComputeLpTokenImpl(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        address create3Proxy = _create3ProxyAddress(address(script), salt);
        vm.etch(create3Proxy, hex"01");

        vm.expectPartialRevert(DeployMemeverseHookProxy.ArtifactCreate3SaltConsumed.selector);
        script.exposedDeployLpTokenImpl(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
    }

    function testDeploySettlementFacetRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 salt,) =
            script.exposedComputeSettlementFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        address create3Proxy = _create3ProxyAddress(address(script), salt);
        vm.etch(create3Proxy, hex"01");

        vm.expectPartialRevert(DeployMemeverseHookProxy.ArtifactCreate3SaltConsumed.selector);
        script.exposedDeploySettlementFacet(
            IOutrunDeployer(address(outrunDeployer)), address(script), nonce, IPoolManager(POOL_MANAGER)
        );
    }

    function testDeployDynamicFeeFacetRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 salt,) =
            script.exposedComputeDynamicFeeFacet(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        address create3Proxy = _create3ProxyAddress(address(script), salt);
        vm.etch(create3Proxy, hex"01");

        vm.expectPartialRevert(DeployMemeverseHookProxy.ArtifactCreate3SaltConsumed.selector);
        script.exposedDeployDynamicFeeFacet(
            IOutrunDeployer(address(outrunDeployer)), address(script), nonce, IPoolManager(POOL_MANAGER)
        );
    }

    function testDeployHookImplRejectsConsumedCreate3Salt() external {
        vm.etch(POOL_MANAGER, hex"01");
        outrunDeployer.transferOwnership(address(script));

        uint256 nonce = 1;
        (bytes32 salt,) =
            script.exposedComputeHookImpl(IOutrunDeployer(address(outrunDeployer)), address(script), nonce);
        address create3Proxy = _create3ProxyAddress(address(script), salt);
        vm.etch(create3Proxy, hex"01");

        vm.expectPartialRevert(DeployMemeverseHookProxy.ArtifactCreate3SaltConsumed.selector);
        script.exposedDeployHookImpl(
            IOutrunDeployer(address(outrunDeployer)), address(script), nonce, IPoolManager(POOL_MANAGER)
        );
    }

    function testDeployProxyRejectsMismatchedDeployerNamespace() external {
        vm.etch(POOL_MANAGER, hex"01");
        address wrongNamespace = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMemeverseHookProxy.DeployerNamespaceMismatch.selector, address(this), wrongNamespace
            )
        );
        script.deployHookProxy(
            IOutrunDeployer(address(outrunDeployer)),
            wrongNamespace,
            IPoolManager(POOL_MANAGER),
            HOOK_OWNER,
            HOOK_TREASURY,
            HOOK_LAUNCHER,
            1
        );
    }

    function _create3ProxyAddress(address deployerNamespace, bytes32 salt)
        internal
        view
        returns (address create3Proxy)
    {
        bytes32 hashedSalt = keccak256(abi.encodePacked(deployerNamespace, salt));
        create3Proxy = keccak256(
                abi.encodePacked(bytes1(0xFF), address(outrunDeployer), hashedSalt, CREATE3_PROXY_BYTECODE_HASH)
            ).fromLast20Bytes();
    }

    function _setExpectedImplementationCodehashes(address proxy) internal {
        address hookImplementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        vm.setEnv("EXPECTED_HOOK_PROXY_CODEHASH", vm.toString(proxy.codehash));
        vm.setEnv("EXPECTED_HOOK_IMPLEMENTATION_CODEHASH", vm.toString(hookImplementation.codehash));
        address lpTokenImplementation = MemeverseUniswapHookUpgradeable(proxy).lpTokenImplementation();
        vm.setEnv("EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH", vm.toString(lpTokenImplementation.codehash));
        address swapFacet = MemeverseUniswapHookUpgradeable(proxy).swapFacet();
        vm.setEnv("EXPECTED_SWAP_FACET_CODEHASH", vm.toString(swapFacet.codehash));
        address dynamicFeeFacet = MemeverseUniswapHookUpgradeable(proxy).dynamicFeeFacet();
        vm.setEnv("EXPECTED_DYNAMIC_FEE_FACET_CODEHASH", vm.toString(dynamicFeeFacet.codehash));
        address settlementFacet = MemeverseUniswapHookUpgradeable(proxy).settlementFacet();
        vm.setEnv("EXPECTED_SETTLEMENT_FACET_CODEHASH", vm.toString(settlementFacet.codehash));
    }
}
