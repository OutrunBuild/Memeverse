// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {BaseScript} from "./BaseScript.s.sol";
import {IOutrunDeployer} from "./deployment/interfaces/IOutrunDeployer.sol";
import {MemeverseUniswapHookUpgradeable} from "../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {SwapFacet} from "../src/swap/SwapFacet.sol";
import {DynamicFeeFacet} from "../src/swap/DynamicFeeFacet.sol";
import {SettlementFacet} from "../src/swap/SettlementFacet.sol";
import {UniswapLP} from "../src/swap/tokens/UniswapLP.sol";

/// @title DeployMemeverseHookProxy
/// @notice Deploys the production Memeverse Uniswap v4 hook diamond Router (implementation + UUPS
///         proxy) together with its three delegatecall facets.
contract DeployMemeverseHookProxy is BaseScript {
    using Bytes32AddressLib for bytes32;

    uint160 internal constant MEMEVERSE_HOOK_FLAGS = 0x28cc;
    uint160 internal constant UNISWAP_V4_HOOK_FLAG_MASK = 0x3fff;
    uint256 internal constant MAX_SALT_SEARCH = 1_000_000;
    bytes32 internal constant CREATE3_PROXY_BYTECODE_HASH = keccak256(hex"67363d3d37363d34f03d5260086018f3");
    bytes internal constant HOOK_IMPL_SALT_SEED =
        hex"4d656d657665727365556e6973776170486f6f6b496d706c656d656e746174696f6e";
    bytes internal constant LP_TOKEN_IMPL_SALT_SEED =
        hex"4d656d657665727365556e69737761704c50546f6b656e496d706c656d656e746174696f6e";
    bytes internal constant SWAP_FACET_SALT_SEED = hex"4d656d657665727365537761704661636574";
    bytes internal constant DYNAMIC_FEE_FACET_SALT_SEED = hex"4d656d65766572736544796e616d69634665654661636574";
    bytes internal constant SETTLEMENT_FACET_SALT_SEED = hex"4d656d657665727365536574746c656d656e744661636574";

    error PoolManagerCodeNotReady(address poolManager);
    error ProxySaltNotFound(uint256 checkedSalts);
    error ProxyDeploymentMismatch(address expected, address actual);
    error HookFlagMismatch(address hook);
    error DeployerNamespaceMismatch(address expected, address provided);
    error Create3SaltConsumed(bytes32 salt, address create3Proxy);
    /// @dev Generic CREATE3-salt-consumed error for LP-token / facet / hook-implementation
    ///      deploys; `saltSeed` identifies which artifact collided (its hex literal is readable).
    error ArtifactCreate3SaltConsumed(bytes saltSeed, bytes32 salt, address create3Proxy);
    error ExistingIntermediateDeploymentNotReusable(address deployed);
    error ExistingHookOwnerMismatch(address hook, address expectedOwner, address actualOwner);
    error ExistingHookTreasuryMismatch(address hook, address expectedTreasury, address actualTreasury);
    error ExistingHookPoolManagerMismatch(address hook, address expectedPoolManager, address actualPoolManager);
    error ExistingHookLauncherMismatch(address hook, address expectedLauncher, address actualLauncher);
    error ExistingHookImplementationMismatch(
        address hook, address expectedImplementation, address actualImplementation
    );
    error ExistingHookLPTokenImplementationMismatch(
        address hook, address expectedImplementation, address actualImplementation
    );
    error ExistingHookLPTokenImplementationCodeMissing(address implementation);
    error ExistingHookSwapFacetMismatch(address hook, address expectedFacet, address actualFacet);
    error ExistingHookDynamicFeeFacetMismatch(address hook, address expectedFacet, address actualFacet);
    error ExistingHookSettlementFacetMismatch(address hook, address expectedFacet, address actualFacet);
    error ExistingHookFacetCodeMissing(address facet);
    error ExistingHookFacetPoolManagerMismatch(address facet, address expectedPoolManager, address actualPoolManager);
    /// @dev Unified codehash-check errors. `CodehashMismatch` carries the artifact address so ops can
    ///      map it back to the named deployment artifact; `ExpectedCodehashNotSet` carries the missing
    ///      env var name directly, avoiding a separate address->name lookup.
    error CodehashMismatch(address artifact, bytes32 expectedCodehash, bytes32 currentCodehash);
    error ExpectedCodehashNotSet(string envVar);
    error UnusableHookOwner(address hookOwner);
    error ZeroAddressNotAllowed();

    /// @notice Complete deployment artifacts for the Memeverse diamond hook (Router proxy + 3 facets).
    struct DeploymentResult {
        address hookImplementation;
        address hookProxy;
        address lpTokenImplementation;
        address swapFacet;
        address dynamicFeeFacet;
        address settlementFacet;
    }

    /// @notice Snapshot of all addresses resolved from an existing hook proxy.
    /// @dev Used to resolve each address exactly once on the reuse/deploy validation paths,
    ///      then pass to the match/validate functions which become pure comparisons.
    struct ResolvedDeployment {
        address implementation;
        address hookOwner;
        address hookTreasury;
        IPoolManager poolManager;
        address hookLauncher;
        address lpTokenImplementation;
        address swapFacet;
        address dynamicFeeFacet;
        address settlementFacet;
    }

    /// @notice Predicted artifact addresses for the same-nonce reuse check.
    /// @dev Packs the five expected artifact addresses into one `memory` slot so the salt-search
    ///      loop stays under the EVM 16-slot stack limit (a `memory` struct is a single pointer).
    ///      `hookImplementation` doubles as the readiness flag: `address(0)` means not yet computed
    ///      (lazily resolved only when an occupied proxy candidate needs the reuse check).
    struct ExpectedArtifacts {
        address hookImplementation;
        address lpTokenImplementation;
        address swapFacet;
        address dynamicFeeFacet;
        address settlementFacet;
    }

    /// @notice Executes the deployment using environment-provided production addresses.
    /// @dev All six contracts (LP token impl, 3 facets, hook impl, hook proxy) are deployed via OutrunDeployer
    ///      (CREATE3) with named, nonce-scoped salts. Addresses are deterministic per (deployer, nonce) pair.
    ///      A complete same-nonce hook proxy deployment is reusable only after validating the proxy and its
    ///      facet bindings. Intermediate CREATE3 addresses are not reusable without that final hook proxy proof.
    ///      If a CREATE3 minimal proxy was deployed but the inner contract creation failed (salt consumed,
    ///      final address empty), re-running reverts with a path-specific consumed-salt error.
    ///
    ///      ATOMICITY: run() forwards to run(uint256), which carries the broadcaster modifier
    ///      (BaseScript.s.sol vm.startBroadcast). Under startBroadcast the six outrunDeployer.deploy
    ///      calls become six independent on-chain transactions — NOT a single atomic transaction.
    ///      Simulation (forge script without --broadcast) is a full dry-run: any failure reverts the
    ///      whole script with zero on-chain state and no CREATE3 salt consumed. After --broadcast,
    ///      a partial on-chain failure does NOT roll back earlier deploys — it consumes CREATE3 salts
    ///      and DEPLOYMENT_NONCE must be incremented to recover. deployHookProxy(...) is a programmatic/test
    ///      entrypoint (no broadcaster): its six deploys run inside one call and revert atomically, but it is
    ///      not a production EOA atomic path — production deploys use run() (non-atomic, 6-broadcast).
    ///
    ///      Deployment order (must not be reordered):
    ///        1. LP token implementation (stateless bytecode, no dependencies)
    ///        2. Swap facet (stateless bytecode, binds PoolManager immutably)
    ///        3. Dynamic fee facet (stateless bytecode, binds PoolManager immutably)
    ///        4. Settlement facet (stateless bytecode, binds PoolManager immutably)
    ///        5. Hook implementation (stateless bytecode, binds PoolManager immutably)
    ///        6. Hook proxy — initialized with (hookOwner, hookTreasury, lpTokenImplementation, swapFacet,
    ///           dynamicFeeFacet, settlementFacet, hookLauncher). The hook proxy address is the real Uniswap
    ///           hook address; `hookLauncher` is bound write-once via `initialize` (no retarget path).
    ///
    ///      The facets are plain contracts (not proxies) and carry no hook-binding state. Each facet's
    ///      `onlyViaRouter` guard uses an immutable self-address (`__self`) baked at construction, so
    ///      facet deployment and Router initialization require no storage seeding for delegatecalls.
    ///
    ///      WARNING: do NOT extract individual deployment steps into separate transactions. A partial
    ///      deployment leaves CREATE3 salts consumed and requires incrementing the nonce to recover.
    /// @return result All deployed addresses: hook impl/proxy, LP token impl, and the 3 facets.
    function run() public returns (DeploymentResult memory result) {
        return run(vm.envUint("DEPLOYMENT_NONCE"));
    }

    /// @notice Executes the deployment using environment-provided production addresses and deployment nonce.
    /// @dev The nonce is part of the CREATE3 salts and must be incremented for each new deploy.
    /// @param nonce Deployment version nonce.
    /// @return result All deployed addresses: hook impl/proxy, LP token impl, and the 3 facets.
    function run(uint256 nonce) public broadcaster returns (DeploymentResult memory result) {
        IOutrunDeployer outrunDeployer = IOutrunDeployer(vm.envAddress("OUTRUN_DEPLOYER"));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address hookOwner = vm.envAddress("HOOK_OWNER");
        address hookTreasury = vm.envAddress("HOOK_TREASURY");
        address hookLauncher = vm.envAddress("MEMEVERSE_LAUNCHER");
        _requireNoZeroAddress(hookOwner);
        _requireNoZeroAddress(hookTreasury);
        _requireNoZeroAddress(hookLauncher);
        _requireNoZeroAddress(address(outrunDeployer));
        _requirePoolManagerCode(poolManager);

        return _executeDeployment(outrunDeployer, deployer, poolManager, hookOwner, hookTreasury, hookLauncher, nonce);
    }

    /// @notice Deploys the implementation and a mined UUPS proxy through OutrunDeployer.
    /// @dev ATOMICITY: all six CREATE3 deployments execute in a single call. If any step fails, the entire
    ///      call reverts — no intermediate salts are consumed.
    ///      This is a programmatic/test entrypoint, not a production EOA atomic path (production uses run());
    ///      see run() NatSpec.
    ///      WARNING: do NOT extract individual steps into separate transactions.
    /// @param outrunDeployer CREATE3 deployer used for the proxy address.
    /// @param deployerNamespace Address that will be the effective msg.sender when
    ///   OutrunDeployer.deploy() is called. Must match msg.sender unless called inside
    ///   a Foundry broadcast that sets msg.sender to this address.
    /// @param poolManager Uniswap v4 pool manager stored as immutable in the hook implementation and each facet.
    /// @param hookOwner Owner used for proxy initialization.
    /// @param hookTreasury Treasury used for proxy initialization.
    /// @param hookLauncher Launcher bound at proxy initialization (write-once via initialize).
    /// @param nonce Deployment version nonce, incremented for each new deploy.
    /// @return result All deployed addresses: hook impl/proxy, LP token impl, and the 3 facets.
    function deployHookProxy(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        IPoolManager poolManager,
        address hookOwner,
        address hookTreasury,
        address hookLauncher,
        uint256 nonce
    ) public returns (DeploymentResult memory result) {
        if (msg.sender != deployerNamespace) {
            revert DeployerNamespaceMismatch(msg.sender, deployerNamespace);
        }
        _requireNoZeroAddress(hookOwner);
        _requireNoZeroAddress(hookTreasury);
        _requireNoZeroAddress(hookLauncher);
        _requirePoolManagerCode(poolManager);

        return _executeDeployment(
            outrunDeployer, deployerNamespace, poolManager, hookOwner, hookTreasury, hookLauncher, nonce
        );
    }

    /// @notice Shared deployment body invoked by both `run(uint256)` and `deployHookProxy(...)`.
    /// @dev Entry-specific validation (env reads, zero-address checks, the deployerNamespace
    ///      msg.sender guard) stays in each entrypoint; this function trusts pre-validated args
    ///      and only executes the CREATE3 deployment + reuse/validation + result-fill sequence.
    function _executeDeployment(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        IPoolManager poolManager,
        address hookOwner,
        address hookTreasury,
        address hookLauncher,
        uint256 nonce
    ) internal returns (DeploymentResult memory result) {
        (bytes32 proxySalt, address selectedProxy, bool reuseExistingProxy) = _selectProxySalt(
            outrunDeployer, deployerNamespace, nonce, hookOwner, hookTreasury, poolManager, hookLauncher
        );
        _requireUsableHookOwner(hookOwner, selectedProxy);
        if (reuseExistingProxy) {
            result.hookProxy = selectedProxy;
            result.hookImplementation = _getExistingImplementation(result.hookProxy);
            result.lpTokenImplementation = MemeverseUniswapHookUpgradeable(result.hookProxy).lpTokenImplementation();
            result.swapFacet = MemeverseUniswapHookUpgradeable(result.hookProxy).swapFacet();
            result.dynamicFeeFacet = MemeverseUniswapHookUpgradeable(result.hookProxy).dynamicFeeFacet();
            result.settlementFacet = MemeverseUniswapHookUpgradeable(result.hookProxy).settlementFacet();
            return result;
        }

        // Each _deploy* predicts its CREATE3 address once, refuses occupied targets, deploys, and
        // returns the landed address — no second prediction in this orchestrator.
        address lpTokenImpl = _deployLpTokenImpl(outrunDeployer, deployerNamespace, nonce);
        address swapFacet = _deploySwapFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
        address dynamicFeeFacet = _deployDynamicFeeFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
        address settlementFacet = _deploySettlementFacet(outrunDeployer, deployerNamespace, nonce, poolManager);
        address hookImpl = _deployHookImpl(outrunDeployer, deployerNamespace, nonce, poolManager);
        address proxy = _deployProxy(
            outrunDeployer,
            deployerNamespace,
            proxySalt,
            selectedProxy,
            hookImpl,
            hookOwner,
            hookTreasury,
            lpTokenImpl,
            swapFacet,
            dynamicFeeFacet,
            settlementFacet,
            hookLauncher
        );
        // Resolve owner/treasury/poolManager/launcher from the just-deployed proxy; reuse the 5 addresses
        // returned by the deploy helpers above.
        // The deploy path does NOT run `_validateExistingImplementationCodehashes` (no same-nonce reuse), so
        // code existence + poolManager immutables are checked separately via `_validateDeployedArtifactCode`.
        ResolvedDeployment memory actual =
            _resolveDeployment(proxy, hookImpl, lpTokenImpl, swapFacet, dynamicFeeFacet, settlementFacet);
        // The deploy path knows all five artifact addresses from the _deploy* calls above; pack them
        // into the same expected-artifacts struct the reuse path uses for validation.
        ExpectedArtifacts memory expectedDeployed = ExpectedArtifacts({
            hookImplementation: hookImpl,
            lpTokenImplementation: lpTokenImpl,
            swapFacet: swapFacet,
            dynamicFeeFacet: dynamicFeeFacet,
            settlementFacet: settlementFacet
        });
        _validateExistingDeployment(proxy, actual, expectedDeployed, hookOwner, hookTreasury, poolManager, hookLauncher);
        _validateDeployedArtifactCode(actual, poolManager);

        result.hookImplementation = hookImpl;
        result.hookProxy = proxy;
        result.lpTokenImplementation = lpTokenImpl;
        result.swapFacet = swapFacet;
        result.dynamicFeeFacet = dynamicFeeFacet;
        result.settlementFacet = settlementFacet;
    }

    /// @notice Returns the expected Memeverse hook permission flags.
    /// @return flags The low-bit Uniswap v4 hook flag value required on the proxy address.
    function memeverseHookFlags() public pure returns (uint160 flags) {
        return MEMEVERSE_HOOK_FLAGS;
    }

    /// @notice Returns the Uniswap v4 hook flag mask.
    /// @return mask The low-bit mask applied to hook addresses.
    function uniswapV4HookFlagMask() public pure returns (uint160 mask) {
        return UNISWAP_V4_HOOK_FLAG_MASK;
    }

    /// @notice Builds ERC1967Proxy (UUPS) creation code for CREATE3 deployment.
    /// @dev UUPS proxies carry no ProxyAdmin; upgrade authorization lives on the implementation via
    ///      `_authorizeUpgrade`. The hook owner is encoded inside `initializeData` (the first arg of
    ///      `MemeverseUniswapHookUpgradeable.initialize`), so only the implementation and initializer data are appended.
    /// @param implementation Hook implementation address passed to the proxy constructor.
    /// @param initializeData Initializer calldata (encodes hook owner + treasury + facet pointers) passed to
    ///        the proxy constructor.
    /// @return creationCode Complete proxy creation code including constructor args.
    function proxyCreationCode(address implementation, bytes memory initializeData)
        public
        pure
        returns (bytes memory creationCode)
    {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializeData));
    }

    /// @notice Mines an OutrunDeployer salt whose proxy address has the required Uniswap v4 hook flags.
    /// @dev The proxy address, not the implementation address, is what Uniswap v4 checks for hook permissions.
    ///      Searches global `bytes32(i)` candidates from zero and skips candidates that already have code.
    /// @param outrunDeployer CREATE3 deployer used for address prediction.
    /// @param deployerNamespace Address that will call `OutrunDeployer.deploy`.
    /// @return salt First salt found in the bounded deterministic search.
    /// @return proxy Predicted proxy address carrying the required hook flags.
    function mineProxySalt(IOutrunDeployer outrunDeployer, address deployerNamespace)
        public
        view
        returns (bytes32 salt, address proxy)
    {
        for (uint256 i; i < MAX_SALT_SEARCH; ++i) {
            salt = bytes32(i);
            proxy = outrunDeployer.getDeployed(deployerNamespace, salt);
            if ((uint160(proxy) & UNISWAP_V4_HOOK_FLAG_MASK) == MEMEVERSE_HOOK_FLAGS && proxy.code.length == 0) {
                return (salt, proxy);
            }
        }

        revert ProxySaltNotFound(MAX_SALT_SEARCH);
    }

    /// @notice Returns the first global hook-flag-matching proxy address, regardless of deployment status.
    /// @dev Searches global `bytes32(i)` candidates from zero without checking whether the candidate has code.
    /// @param outrunDeployer CREATE3 deployer used for address prediction.
    /// @param deployerNamespace Address that will call `OutrunDeployer.deploy`.
    /// @return proxy First predicted proxy address carrying the required hook flags.
    function getPredictedProxy(IOutrunDeployer outrunDeployer, address deployerNamespace)
        public
        view
        returns (address proxy)
    {
        for (uint256 i; i < MAX_SALT_SEARCH; ++i) {
            proxy = outrunDeployer.getDeployed(deployerNamespace, bytes32(i));
            if ((uint160(proxy) & UNISWAP_V4_HOOK_FLAG_MASK) == MEMEVERSE_HOOK_FLAGS) {
                return proxy;
            }
        }

        revert ProxySaltNotFound(MAX_SALT_SEARCH);
    }

    /// @notice Returns the first nonce-scoped hook-flag candidate, regardless of deployment status.
    /// @dev This does not skip dirty occupied candidates. Use the overload with owner,
    ///      treasury, and poolManager to predict deployHookProxy/run selection.
    /// @param outrunDeployer CREATE3 deployer used for address prediction.
    /// @param deployerNamespace Address that will call `OutrunDeployer.deploy`.
    /// @param nonce Deployment version nonce.
    /// @return proxy First nonce-scoped proxy address carrying the required hook flags.
    function getPredictedProxy(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        public
        view
        returns (address proxy)
    {
        for (uint256 i; i < MAX_SALT_SEARCH; ++i) {
            bytes32 salt = keccak256(abi.encodePacked("MemeverseUniswapHookProxy", nonce, i));
            proxy = outrunDeployer.getDeployed(deployerNamespace, salt);
            if ((uint160(proxy) & UNISWAP_V4_HOOK_FLAG_MASK) == MEMEVERSE_HOOK_FLAGS) return proxy;
        }

        revert ProxySaltNotFound(MAX_SALT_SEARCH);
    }

    /// @notice Returns the nonce-scoped hook proxy selected by the deployment flow.
    /// @dev Uses the same validation inputs as deployHookProxy/run, so dirty non-hook
    ///      candidates are skipped and valid same-nonce deployments are reused.
    /// @param outrunDeployer CREATE3 deployer used for address prediction.
    /// @param deployerNamespace Address that will call `OutrunDeployer.deploy`.
    /// @param nonce Deployment version nonce.
    /// @param hookOwner Owner expected on a reusable hook proxy.
    /// @param hookTreasury Treasury expected on a reusable hook proxy.
    /// @param poolManager PoolManager expected on a reusable hook and its facets.
    /// @param hookLauncher Launcher expected on a reusable hook proxy (write-once, init-bound).
    /// @return proxy Selected proxy address used by deployHookProxy/run.
    function getPredictedProxy(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        address hookOwner,
        address hookTreasury,
        IPoolManager poolManager,
        address hookLauncher
    ) public view returns (address proxy) {
        (, proxy,) = _selectProxySalt(
            outrunDeployer, deployerNamespace, nonce, hookOwner, hookTreasury, poolManager, hookLauncher
        );
    }

    /// @notice Mines the nonce-scoped hook proxy salt used by deployHookProxy/run.
    /// @dev Existing code is reusable only when it is the expected same-nonce deployment.
    function _selectProxySalt(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        address hookOwner,
        address hookTreasury,
        IPoolManager poolManager,
        address expectedHookLauncher
    ) internal view returns (bytes32 salt, address proxy, bool reuseExistingProxy) {
        // Expected artifact addresses are only needed when an occupied proxy candidate must be checked
        // for same-nonce reuse. Pure-fresh success never loads them here. They are packed into a single
        // `memory` struct pointer to keep the loop under the EVM 16-slot stack limit; `hookImplementation`
        // stays address(0) until lazily resolved on the first occupied candidate.
        ExpectedArtifacts memory expected;
        for (uint256 i; i < MAX_SALT_SEARCH; ++i) {
            salt = keccak256(abi.encodePacked("MemeverseUniswapHookProxy", nonce, i));
            proxy = outrunDeployer.getDeployed(deployerNamespace, salt);
            if ((uint160(proxy) & UNISWAP_V4_HOOK_FLAG_MASK) != MEMEVERSE_HOOK_FLAGS) continue;
            if (proxy.code.length == 0) {
                address create3Proxy = _create3ProxyAddress(outrunDeployer, deployerNamespace, salt);
                if (create3Proxy.code.length != 0) revert Create3SaltConsumed(salt, create3Proxy);
                return (salt, proxy, false);
            }
            if (expected.hookImplementation == address(0)) {
                (, expected.hookImplementation) = _computeHookImpl(outrunDeployer, deployerNamespace, nonce);
                (, expected.lpTokenImplementation) = _computeLpTokenImpl(outrunDeployer, deployerNamespace, nonce);
                (, expected.swapFacet) = _computeSwapFacet(outrunDeployer, deployerNamespace, nonce);
                (, expected.dynamicFeeFacet) = _computeDynamicFeeFacet(outrunDeployer, deployerNamespace, nonce);
                (, expected.settlementFacet) = _computeSettlementFacet(outrunDeployer, deployerNamespace, nonce);
            }
            address actualImplementation = _getExistingImplementation(proxy);
            if (actualImplementation != expected.hookImplementation) continue;
            (
                address actualLpTokenImpl,
                address actualSwapFacet,
                address actualDynamicFeeFacet,
                address actualSettlementFacet
            ) = _validateExistingImplementationCodehashes(proxy, actualImplementation);

            // Resolve remaining addresses (owner/treasury/poolManager) once. Safe to call getters without
            // try/catch: `_validateExistingImplementationCodehashes` validated the proxy codehash above,
            // guaranteeing the proxy is valid MemeverseUniswapHookUpgradeable bytecode whose getters cannot revert.
            ResolvedDeployment memory actual = _resolveDeployment(
                proxy,
                actualImplementation,
                actualLpTokenImpl,
                actualSwapFacet,
                actualDynamicFeeFacet,
                actualSettlementFacet
            );
            // Single reuse gate: only when every field matches `_validateExistingDeployment` do we reuse.
            // Any field that disagrees reverts with that field's dedicated error selector rather than
            // silently skipping the candidate — a candidate that already passed implementation + codehash
            // checks yet mismatches on owner/treasury/poolManager/facet binding is a tampered deployment
            // and must stop here, not continue searching. Not reverting == all fields match == reusable.
            _validateExistingDeployment(
                proxy, actual, expected, hookOwner, hookTreasury, poolManager, expectedHookLauncher
            );
            return (salt, proxy, true);
        }

        revert ProxySaltNotFound(MAX_SALT_SEARCH);
    }

    // ──────────────────────── Generic Artifact Compute/Deploy ───────────────────
    //
    // Every deployment artifact (LP-token impl, the 3 facets, hook impl) follows one recipe:
    // salt = keccak(saltSeed ++ nonce); predicted = getDeployed(namespace, salt); refuse if the
    // CREATE3 proxy slot is occupied; deploy; assert the landed address matches the prediction.
    // The wrappers below are thin facades that supply each artifact's saltSeed and creationCode.

    /// @notice Computes the deterministic address for any single-salt CREATE3 artifact.
    /// @param outrunDeployer CREATE3 deployer used for address prediction.
    /// @param deployerNamespace Address that will call `OutrunDeployer.deploy`.
    /// @param nonce Deployment version nonce, mixed into every artifact's salt.
    /// @param saltSeed Per-artifact seed distinguishing salts (e.g. `SWAP_FACET_SALT_SEED`).
    /// @return salt The computed salt.
    /// @return artifact The predicted artifact address.
    function _computeArtifact(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        bytes memory saltSeed
    ) internal view returns (bytes32 salt, address artifact) {
        salt = keccak256(abi.encodePacked(saltSeed, nonce));
        artifact = outrunDeployer.getDeployed(deployerNamespace, salt);
    }

    /// @notice Predicts, guards, and deploys any single-salt CREATE3 artifact in one pass.
    /// @dev Computes the address once. If that address already has code, reverts
    ///      `ExistingIntermediateDeploymentNotReusable` (partial same-nonce leftovers are not reused).
    ///      If the CREATE3 proxy slot is occupied, reverts `ArtifactCreate3SaltConsumed` (saltSeed
    ///      echoes which artifact collided). A landed address that defies prediction reverts
    ///      `ProxyDeploymentMismatch`.
    /// @param outrunDeployer CREATE3 deployer used for deployment.
    /// @param deployerNamespace Address that will be the effective msg.sender.
    /// @param nonce Deployment version nonce.
    /// @param saltSeed Per-artifact seed, echoed in the revert for diagnosis.
    /// @param creationCode Fully assembled creation code (constructor args already appended).
    /// @return deployed The predicted and landed artifact address.
    function _deployArtifact(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        bytes memory saltSeed,
        bytes memory creationCode
    ) internal returns (address deployed) {
        (bytes32 salt, address expected) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, saltSeed);
        if (expected.code.length != 0) revert ExistingIntermediateDeploymentNotReusable(expected);
        address create3Proxy = _create3ProxyAddress(outrunDeployer, deployerNamespace, salt);
        if (create3Proxy.code.length != 0) revert ArtifactCreate3SaltConsumed(saltSeed, salt, create3Proxy);
        deployed = outrunDeployer.deploy(salt, creationCode);
        if (deployed != expected) revert ProxyDeploymentMismatch(expected, deployed);
    }

    // ─────────────────────────── LP Token Implementation ───────────────────────────

    /// @notice Computes the deterministic LP token implementation address.
    function _computeLpTokenImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        view
        returns (bytes32 salt, address impl)
    {
        (salt, impl) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, LP_TOKEN_IMPL_SALT_SEED);
    }

    /// @notice Deploys the LP token implementation via OutrunDeployer if not already deployed.
    /// @dev The implementation has initializers disabled; hook-managed clones initialize their own storage.
    /// @return impl Predicted and landed LP token implementation address.
    function _deployLpTokenImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        returns (address impl)
    {
        // UniswapLP has no constructor args, so its creation code is passed verbatim.
        impl = _deployArtifact(
            outrunDeployer, deployerNamespace, nonce, LP_TOKEN_IMPL_SALT_SEED, type(UniswapLP).creationCode
        );
    }

    // ─────────────────────────────── Swap Facet ───────────────────────────────────

    /// @notice Computes the deterministic swap facet address.
    function _computeSwapFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        view
        returns (bytes32 salt, address facet)
    {
        (salt, facet) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, SWAP_FACET_SALT_SEED);
    }

    /// @notice Deploys the swap facet via OutrunDeployer if not already deployed.
    /// @dev The facet is a plain contract (not a proxy) and binds the PoolManager immutably at construction.
    /// @return facet Predicted and landed swap facet address.
    function _deploySwapFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) internal returns (address facet) {
        facet = _deployArtifact(
            outrunDeployer,
            deployerNamespace,
            nonce,
            SWAP_FACET_SALT_SEED,
            abi.encodePacked(type(SwapFacet).creationCode, abi.encode(poolManager))
        );
    }

    // ─────────────────────────── Dynamic Fee Facet ────────────────────────────────

    /// @notice Computes the deterministic dynamic fee facet address.
    function _computeDynamicFeeFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        view
        returns (bytes32 salt, address facet)
    {
        (salt, facet) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, DYNAMIC_FEE_FACET_SALT_SEED);
    }

    /// @notice Deploys the dynamic fee facet via OutrunDeployer if not already deployed.
    /// @dev The facet is a plain contract (not a proxy) and binds the PoolManager immutably at construction.
    /// @return facet Predicted and landed dynamic fee facet address.
    function _deployDynamicFeeFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) internal returns (address facet) {
        facet = _deployArtifact(
            outrunDeployer,
            deployerNamespace,
            nonce,
            DYNAMIC_FEE_FACET_SALT_SEED,
            abi.encodePacked(type(DynamicFeeFacet).creationCode, abi.encode(poolManager))
        );
    }

    // ─────────────────────────── Settlement Facet ─────────────────────────────────

    /// @notice Computes the deterministic settlement facet address.
    function _computeSettlementFacet(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        view
        returns (bytes32 salt, address facet)
    {
        (salt, facet) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, SETTLEMENT_FACET_SALT_SEED);
    }

    /// @notice Deploys the settlement facet via OutrunDeployer if not already deployed.
    /// @dev The facet is a plain contract (not a proxy) and binds the PoolManager immutably at construction.
    /// @return facet Predicted and landed settlement facet address.
    function _deploySettlementFacet(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) internal returns (address facet) {
        facet = _deployArtifact(
            outrunDeployer,
            deployerNamespace,
            nonce,
            SETTLEMENT_FACET_SALT_SEED,
            abi.encodePacked(type(SettlementFacet).creationCode, abi.encode(poolManager))
        );
    }

    // ─────────────────────────── Hook Implementation ─────────────────────────────

    /// @notice Computes the deterministic hook implementation address.
    function _computeHookImpl(IOutrunDeployer outrunDeployer, address deployerNamespace, uint256 nonce)
        internal
        view
        returns (bytes32 salt, address impl)
    {
        (salt, impl) = _computeArtifact(outrunDeployer, deployerNamespace, nonce, HOOK_IMPL_SALT_SEED);
    }

    /// @notice Deploys the hook implementation via OutrunDeployer if not already deployed.
    /// @dev The hook implementation binds the PoolManager immutably at construction.
    /// @return impl Predicted and landed hook implementation address.
    function _deployHookImpl(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        uint256 nonce,
        IPoolManager poolManager
    ) internal returns (address impl) {
        impl = _deployArtifact(
            outrunDeployer,
            deployerNamespace,
            nonce,
            HOOK_IMPL_SALT_SEED,
            abi.encodePacked(type(MemeverseUniswapHookUpgradeable).creationCode, abi.encode(poolManager))
        );
    }

    // ───────────────────────────── Hook Proxy ────────────────────────────────────

    function _deployProxy(
        IOutrunDeployer outrunDeployer,
        address deployerNamespace,
        bytes32 salt,
        address expectedProxy,
        address implementation,
        address hookOwner,
        address hookTreasury,
        address lpTokenImplementation,
        address swapFacet,
        address dynamicFeeFacet,
        address settlementFacet,
        address launcher_
    ) internal returns (address proxy) {
        // Detect if the CREATE3 minimal proxy was already deployed for this salt
        // (e.g. a previous run's inner CREATE failed). The salt is permanently consumed
        // and cannot be retried — revert with actionable context instead of the opaque
        // "DEPLOYMENT_FAILED" error from solmate CREATE3.
        address create3Proxy = _create3ProxyAddress(outrunDeployer, deployerNamespace, salt);
        if (create3Proxy.code.length != 0) revert Create3SaltConsumed(salt, create3Proxy);

        bytes memory initializeData = abi.encodeCall(
            MemeverseUniswapHookUpgradeable.initialize,
            (hookOwner, hookTreasury, lpTokenImplementation, swapFacet, dynamicFeeFacet, settlementFacet, launcher_)
        );
        bytes memory creationCode = proxyCreationCode(implementation, initializeData);

        proxy = outrunDeployer.deploy(salt, creationCode);
        if (proxy != expectedProxy) revert ProxyDeploymentMismatch(expectedProxy, proxy);
        if ((uint160(proxy) & UNISWAP_V4_HOOK_FLAG_MASK) != MEMEVERSE_HOOK_FLAGS) revert HookFlagMismatch(proxy);
    }

    // ─────────────────────────────── Utils ───────────────────────────────────────

    function _requirePoolManagerCode(IPoolManager poolManager) internal view {
        address poolManagerAddress = address(poolManager);
        if (poolManagerAddress.code.length == 0) revert PoolManagerCodeNotReady(poolManagerAddress);
    }

    function _requireNoZeroAddress(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddressNotAllowed();
    }

    function _requireUsableHookOwner(address hookOwner, address proxy) internal pure {
        // UUPS carries no ProxyAdmin. Self-ownership would brick the proxy: the owner could not call any
        // onlyOwner entrypoint (including UUPS upgrades), so recovery would be impossible.
        if (hookOwner == proxy) revert UnusableHookOwner(hookOwner);
    }

    function _getExistingImplementation(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _create3ProxyAddress(IOutrunDeployer outrunDeployer, address deployerNamespace, bytes32 salt)
        internal
        pure
        returns (address create3Proxy)
    {
        bytes32 hashedSalt = keccak256(abi.encodePacked(deployerNamespace, salt));
        create3Proxy = keccak256(
                abi.encodePacked(bytes1(0xFF), address(outrunDeployer), hashedSalt, CREATE3_PROXY_BYTECODE_HASH)
            )
            .fromLast20Bytes();
    }

    /// @dev Each facet binds the PoolManager immutably via `ImmutableState`; under delegatecall the facet
    ///      settles/takes against this manager, so a mismatch would silently break accounting. The hook
    ///      `initialize` re-checks the same invariant; this mirrors it for the deploy-time/reuse validation.
    function _requireFacetPoolManager(address facet, IPoolManager expectedPoolManager) internal view {
        if (facet.code.length == 0) revert ExistingHookFacetCodeMissing(facet);
        address actualPoolManager = address(ImmutableState(facet).poolManager());
        if (actualPoolManager != address(expectedPoolManager)) {
            revert ExistingHookFacetPoolManagerMismatch(facet, address(expectedPoolManager), actualPoolManager);
        }
    }

    /// @notice Resolves every hook-proxy address into a single snapshot for the validate functions.
    /// @dev Both call sites pre-resolve `implementation` + `lpTokenImplementation` + the 3 facets before
    ///      calling here (the deploy path from CREATE3 computes, the reuse path from codehash-validated
    ///      getters), so they are taken as-is. Only `owner`/`treasury`/`poolManager` are read from the
    ///      proxy. If a future caller cannot pre-resolve an artifact, surface it explicitly instead of
    ///      silently falling back to a zero-derived proxy read — that would mask a caller bug.
    ///      Safe to call getters without try/catch: on the reuse path `_validateExistingImplementationCodehashes`
    ///      has already validated the proxy codehash, guaranteeing valid MemeverseUniswapHookUpgradeable bytecode; on the
    ///      deploy path the proxy was just deployed by this script.
    function _resolveDeployment(
        address proxy,
        address implementation,
        address lpTokenImplementation,
        address swapFacet,
        address dynamicFeeFacet,
        address settlementFacet
    ) internal view returns (ResolvedDeployment memory actual) {
        actual.implementation = implementation;

        MemeverseUniswapHookUpgradeable hook = MemeverseUniswapHookUpgradeable(proxy);
        actual.hookOwner = hook.owner();
        actual.hookTreasury = hook.treasury();
        actual.poolManager = hook.poolManager();
        actual.hookLauncher = hook.launcher();

        actual.lpTokenImplementation = lpTokenImplementation;
        actual.swapFacet = swapFacet;
        actual.dynamicFeeFacet = dynamicFeeFacet;
        actual.settlementFacet = settlementFacet;
    }

    /// @notice Validates a resolved deployment against expected values, reverting with a detailed error on
    ///         any mismatch.
    /// @dev All addresses come from the `actual` snapshot (resolved once by `_resolveDeployment`). Pure
    ///      address comparisons only — code existence and poolManager immutable checks live in
    ///      `_validateDeployedArtifactCode` (deploy path only), since the reuse path covers them via codehash.
    function _validateExistingDeployment(
        address proxy,
        ResolvedDeployment memory actual,
        ExpectedArtifacts memory expected,
        address expectedHookOwner,
        address expectedHookTreasury,
        IPoolManager expectedPoolManager,
        address expectedHookLauncher
    ) internal pure {
        if (actual.implementation != expected.hookImplementation) {
            revert ExistingHookImplementationMismatch(proxy, expected.hookImplementation, actual.implementation);
        }

        _requireUsableHookOwner(actual.hookOwner, proxy);
        if (actual.hookOwner != expectedHookOwner) {
            revert ExistingHookOwnerMismatch(proxy, expectedHookOwner, actual.hookOwner);
        }

        if (actual.hookTreasury != expectedHookTreasury) {
            revert ExistingHookTreasuryMismatch(proxy, expectedHookTreasury, actual.hookTreasury);
        }

        if (address(actual.poolManager) != address(expectedPoolManager)) {
            revert ExistingHookPoolManagerMismatch(proxy, address(expectedPoolManager), address(actual.poolManager));
        }

        // Launcher is init-bound and write-once (structurally like poolManager), so a same-nonce
        // reuse must match it too — otherwise a stale/wrong MEMEVERSE_LAUNCHER env is silently accepted.
        if (actual.hookLauncher != expectedHookLauncher) {
            revert ExistingHookLauncherMismatch(proxy, expectedHookLauncher, actual.hookLauncher);
        }

        if (actual.lpTokenImplementation != expected.lpTokenImplementation) {
            revert ExistingHookLPTokenImplementationMismatch(
                proxy, expected.lpTokenImplementation, actual.lpTokenImplementation
            );
        }

        if (actual.swapFacet != expected.swapFacet) {
            revert ExistingHookSwapFacetMismatch(proxy, expected.swapFacet, actual.swapFacet);
        }

        if (actual.dynamicFeeFacet != expected.dynamicFeeFacet) {
            revert ExistingHookDynamicFeeFacetMismatch(proxy, expected.dynamicFeeFacet, actual.dynamicFeeFacet);
        }

        if (actual.settlementFacet != expected.settlementFacet) {
            revert ExistingHookSettlementFacetMismatch(proxy, expected.settlementFacet, actual.settlementFacet);
        }
    }

    /// @notice Validates that deployed artifacts have code and correct poolManager immutables.
    /// @dev Called only on the deploy path, where `_validateExistingImplementationCodehashes` does not run
    ///      (no same-nonce reuse to validate against). On the reuse path, the codehash check covers both
    ///      code existence and the poolManager immutable (baked into facet bytecode at construction), so
    ///      this function is skipped there.
    function _validateDeployedArtifactCode(ResolvedDeployment memory actual, IPoolManager expectedPoolManager)
        internal
        view
    {
        if (actual.lpTokenImplementation.code.length == 0) {
            revert ExistingHookLPTokenImplementationCodeMissing(actual.lpTokenImplementation);
        }
        _requireFacetPoolManager(actual.swapFacet, expectedPoolManager);
        _requireFacetPoolManager(actual.dynamicFeeFacet, expectedPoolManager);
        _requireFacetPoolManager(actual.settlementFacet, expectedPoolManager);
    }

    /// @notice Validates the runtime codehashes of the proxy and all 5 deployment artifacts (implementation,
    ///         LP token, 3 facets) against ops-pinned env vars.
    /// @dev Uses the passed `implementation` (already resolved by the caller for the `continue` filter) to
    ///      avoid a second storage read. Returns the 4 artifact addresses so downstream functions don't
    ///      re-resolve them from the proxy.
    function _validateExistingImplementationCodehashes(address proxy, address implementation)
        internal
        view
        returns (address lpTokenImplementation, address swapFacet, address dynamicFeeFacet, address settlementFacet)
    {
        _requireCodehashMatch(proxy, "EXPECTED_HOOK_PROXY_CODEHASH");

        // UUPS proxies carry no ProxyAdmin (upgrade authorization lives on the implementation via
        // `_authorizeUpgrade`), so there is no admin slot or admin-owner relationship to validate here.
        // The proxy owner is still validated downstream by `_validateExistingDeployment` against the
        // deploy-arg `expectedHookOwner`.

        _requireCodehashMatch(implementation, "EXPECTED_HOOK_IMPLEMENTATION_CODEHASH");

        lpTokenImplementation = MemeverseUniswapHookUpgradeable(proxy).lpTokenImplementation();
        _requireCodehashMatch(lpTokenImplementation, "EXPECTED_LP_TOKEN_IMPLEMENTATION_CODEHASH");

        swapFacet = MemeverseUniswapHookUpgradeable(proxy).swapFacet();
        _requireCodehashMatch(swapFacet, "EXPECTED_SWAP_FACET_CODEHASH");

        dynamicFeeFacet = MemeverseUniswapHookUpgradeable(proxy).dynamicFeeFacet();
        _requireCodehashMatch(dynamicFeeFacet, "EXPECTED_DYNAMIC_FEE_FACET_CODEHASH");

        settlementFacet = MemeverseUniswapHookUpgradeable(proxy).settlementFacet();
        _requireCodehashMatch(settlementFacet, "EXPECTED_SETTLEMENT_FACET_CODEHASH");
    }

    /// @dev Shared recipe for every artifact codehash check: read the ops-pinned expected codehash from
    ///      `envVar`, reject a missing pin (carrying the variable name), then compare the on-chain
    ///      runtime codehash. The expected hash is an independent ops anchor for a known-good deploy,
    ///      so it is read from env rather than recomputed from local bytecode (which would make a stale
    ///      or tampered on-chain contract indistinguishable from a fresh one).
    function _requireCodehashMatch(address artifact, string memory envVar) internal view {
        bytes32 expectedCodehash = vm.envOr(envVar, bytes32(0));
        if (expectedCodehash == bytes32(0)) revert ExpectedCodehashNotSet(envVar);
        bytes32 currentCodehash = artifact.codehash;
        if (currentCodehash != expectedCodehash) revert CodehashMismatch(artifact, expectedCodehash, currentCodehash);
    }
}
