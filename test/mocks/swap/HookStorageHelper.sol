// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StorageSlotPrimitives} from "../StorageSlotPrimitives.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MemeverseUniswapHook} from "../../../src/swap/MemeverseUniswapHook.sol";
import {SwapFacet} from "../../../src/swap/SwapFacet.sol";
import {DynamicFeeFacet} from "../../../src/swap/DynamicFeeFacet.sol";
import {SettlementFacet} from "../../../src/swap/SettlementFacet.sol";
import {UniswapLP} from "../../../src/swap/tokens/UniswapLP.sol";

import {RealV4PoolManagerBytecode} from "../../swap/helpers/RealV4PoolManagerBytecode.sol";

/// @notice Standalone white-box helper for MemeverseUniswapHook proxy storage and flag-address deployment.
/// @dev Does NOT inherit MemeverseUniswapHook; only inherits Test. Three responsibilities:
///      1. `deployRealPoolManager`: deploys the REAL v4-core PoolManager from its pinned creation bytecode
///         (v4-core's fixed `pragma 0.8.26` blocks importing the contract under this repo's 0.8.35 toolchain).
///      2. `deployHookAtFlagAddress`: deploys a REAL diamond Router (MemeverseUniswapHook) behind a CREATE2-mined
///         UUPS proxy whose address carries the v4 hook permission flags (low 14 bits == 0x28CC), together
///         with its three delegatecall facets (SwapFacet/DynamicFeeFacet/SettlementFacet) and the LP token impl.
///         Tests therefore exercise the production address validation and facet bindings.
///         Returns the deployed hook proxy address only (diamond facets are bound on the Router at initialize).
///      3. `seedActiveLiquiditySharesForTest`: seeds `cachedLpTotalSupply[poolId]` and mints the matching LP
///         tokens via vm.store + vm.prank. LP.mint is `onlyOwner` (the hook), so the mint must be pranked as
///         the proxy while the cached-supply write is done directly via vm.store.
///      Inherit with `is Test, HookStorageHelper`.
abstract contract HookStorageHelper is StorageSlotPrimitives {
    using PoolIdLibrary for PoolId;

    // ── Hook permission flags (must mirror MemeverseUniswapHook.getHookPermissions) ──
    // Bits set: beforeInitialize(13) | beforeAddLiquidity(11) | beforeSwap(7) | afterSwap(6)
    //         | beforeSwapReturnDelta(3) | afterSwapReturnDelta(2) == 0x28CC.
    uint160 internal constant HOOK_REQUIRED_FLAGS =
        uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);

    // erc7201:outrun.storage.MemeverseUniswapHook namespace location
    // (src/swap/MemeverseUniswapHook.sol:147).
    bytes32 internal constant HOOK_SLOT = 0x9f27a56b97c42ac08d93ff5a852851d11eb052b06dc4c041fc6bfa4414f7e000;

    // Struct field offsets in MemeverseUniswapHookStorage
    // (src/swap/MemeverseUniswapHook.sol:131-144).
    uint256 internal constant OFF_TREASURY = 0;
    uint256 internal constant OFF_LAUNCHER = 1;
    uint256 internal constant OFF_SUPPORTED_FEE_CURRENCIES = 2; // mapping(address => bool)
    uint256 internal constant OFF_POOL_INFO = 3; // mapping(PoolId => PoolInfo)
    uint256 internal constant OFF_CACHED_LP_TOTAL_SUPPLY = 4; // mapping(PoolId => uint256)
    uint256 internal constant OFF_POOL_INITIALIZER = 9;

    // ── Slot computation helpers ──

    /// @dev Slot for mapping(PoolId => T) at struct field offset `fieldOffset` keyed by poolId.
    ///      PoolId is a bytes32 user-type; abi.encode on it encodes the raw bytes32 value.
    function _poolIdMappingSlot(uint256 fieldOffset, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), bytes32(uint256(HOOK_SLOT) + fieldOffset)));
    }

    /// @notice Reads the production hook's `cachedLpTotalSupply[poolId]` directly from storage.
    /// @dev Fee-accounting tests use this to assert the cached LP supply stays in sync with the LP token contract.
    function getCachedLpTotalSupplyForTest(address proxy, PoolId poolId) internal view returns (uint256) {
        return uint256(_loadSlot(proxy, _poolIdMappingSlot(OFF_CACHED_LP_TOTAL_SUPPLY, poolId)));
    }

    // ── Real v4 PoolManager deployment ──

    /// @notice Deploys the real v4-core PoolManager from creation bytecode, owner = caller.
    /// @dev The 17KB PoolManager creation code lives in RealV4PoolManagerBytecode (a library) so test contracts
    ///      stay under the 24KB deploy limit. v4-core pins `pragma 0.8.26` while this repo uses 0.8.35, so the
    ///      contract cannot be imported and `new PoolManager(...)` is unavailable — the creation-code constant is
    ///      the only viable deploy path. The `create` runs in the test contract's context, so the nonce sequence
    ///      (which deployHookAtFlagAddress relies on for address prediction) is unchanged versus inlining.
    function deployRealPoolManager() internal returns (IPoolManager) {
        bytes memory deployData =
            abi.encodePacked(RealV4PoolManagerBytecode.getCreationCode(), abi.encode(address(this)));
        address deployed;
        assembly {
            deployed := create(0, add(deployData, 0x20), mload(deployData))
        }
        require(deployed != address(0), "PoolManager deploy failed");
        return IPoolManager(deployed);
    }

    // ── Flag-address deployment ──

    /// @notice Deploys a REAL diamond Router (MemeverseUniswapHook) plus its three facets behind a CREATE2-mined
    ///         UUPS proxy whose low 14 bits equal 0x28CC, so production `_validateProxyHookAddress()` passes
    ///         at `initialize`.
    /// @dev Deployment sequence. CREATE order (nonce increments from `nonceBefore`):
    ///        N:   LP token impl
    ///        N+1: SwapFacet(manager)
    ///        N+2: DynamicFeeFacet(manager)
    ///        N+3: SettlementFacet(manager)
    ///        N+4: MemeverseUniswapHook impl (manager)
    ///      then CREATE2-mined UUPS hook proxy initialized with the Router signature
    ///      `(owner, treasury, lpTokenImpl, swapFacet, dynamicFeeFacet, settlementFacet)`. The proxy initCode
    ///      embeds the hook impl address plus all four pointer addresses (LP impl + 3 facets), every one of which
    ///      is a CREATE address precomputed up front, so the CREATE2 salt can be mined before any facet deploys.
    ///      `initialize` re-validates each facet shares this hook's PoolManager via `_requireFacetPoolManager`.
    ///      The hook owner is encoded inside `initializeData`; no ProxyAdmin is involved (UUPS authorization
    ///      lives on the implementation via `_authorizeUpgrade`).
    /// @param manager Uniswap v4 pool manager shared by the hook and every facet (immutable-bound).
    /// @param hookOwner Initial hook owner (typically the test contract).
    /// @param treasury Treasury set at initialize.
    /// @return hookProxy Address of the deployed hook proxy (carries flag bits).
    function deployHookAtFlagAddress(IPoolManager manager, address hookOwner, address treasury)
        internal
        returns (address hookProxy)
    {
        // (a) Predict every CREATE address up front so the CREATE2 proxy initCode can be assembled before deploy.
        uint256 nonceBefore = vm.getNonce(address(this));
        UniswapLP lpTokenImplementation = new UniswapLP();
        address predictedSwapFacet = vm.computeCreateAddress(address(this), nonceBefore + 1);
        address predictedDynamicFeeFacet = vm.computeCreateAddress(address(this), nonceBefore + 2);
        address predictedSettlementFacet = vm.computeCreateAddress(address(this), nonceBefore + 3);
        address predictedHookImpl = vm.computeCreateAddress(address(this), nonceBefore + 4);

        // (b) Assemble hook proxy initCode with the Router initialize signature.
        bytes memory hookInitData = abi.encodeCall(
            MemeverseUniswapHook.initialize,
            (
                hookOwner,
                treasury,
                address(lpTokenImplementation),
                predictedSwapFacet,
                predictedDynamicFeeFacet,
                predictedSettlementFacet
            )
        );
        bytes memory proxyInitCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(predictedHookImpl, hookInitData));

        // (c) Mine CREATE2 salt so the hook proxy lands at an address whose low 14 bits == 0x28CC.
        bytes32 salt;
        address predictedProxy;
        bytes32 initCodeHash = keccak256(proxyInitCode);
        for (uint256 i = 0; i < type(uint256).max; i++) {
            salt = bytes32(i);
            bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));
            predictedProxy = address(uint160(uint256(digest)));
            if (uint160(predictedProxy) & HOOK_FLAG_MASK == HOOK_REQUIRED_FLAGS) {
                break;
            }
        }
        require(uint160(predictedProxy) & HOOK_FLAG_MASK == HOOK_REQUIRED_FLAGS, "no mined salt");

        // (d) Deploy the three facets. Each is constructed with the shared PoolManager so the hook's
        //     `_requireFacetPoolManager` check passes at initialize.
        SwapFacet swapFacet = new SwapFacet(manager);
        require(address(swapFacet) == predictedSwapFacet, "swap facet drifted");
        DynamicFeeFacet dynamicFeeFacet = new DynamicFeeFacet(manager);
        require(address(dynamicFeeFacet) == predictedDynamicFeeFacet, "dynamic fee facet drifted");
        SettlementFacet settlementFacet = new SettlementFacet(manager);
        require(address(settlementFacet) == predictedSettlementFacet, "settlement facet drifted");

        // (e) Deploy the hook implementation (the REAL production Router contract).
        MemeverseUniswapHook hookImpl = new MemeverseUniswapHook(manager);
        require(address(hookImpl) == predictedHookImpl, "hook impl drifted");

        // (f) CREATE2-deploy the hook proxy at the mined predictedProxy address; initialize runs here.
        //     ERC1967Proxy (UUPS) takes only (impl, initData); the hook owner is encoded inside initData.
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(hookImpl), hookInitData);

        require(address(proxy) == predictedProxy, "CREATE2 proxy drifted");

        return address(proxy);
    }

    // ── Seed methods ──

    /// @notice Seeds active LP shares for a pool without going through the liquidity callback.
    /// @dev Updates `cachedLpTotalSupply[poolId]` and calls `UniswapLP.mint(owner, activeShares)`.
    ///      LP.mint is restricted to the hook (`onlyOwner`), so the mint is performed via `vm.prank(proxy)`.
    ///      The cached supply write is performed directly via vm.store on the cachedLpTotalSupply slot.
    ///      Requires the pool to already be initialized (liquidityToken != address(0)).
    function seedActiveLiquiditySharesForTest(address proxy, PoolId poolId, address owner, uint256 activeShares)
        internal
    {
        (address liquidityToken,,) = MemeverseUniswapHook(proxy).poolInfo(poolId);
        require(liquidityToken != address(0), "pool not initialized");

        // cachedLpTotalSupply[poolId] += activeShares
        bytes32 slot = _poolIdMappingSlot(OFF_CACHED_LP_TOTAL_SUPPLY, poolId);
        uint256 current = uint256(_loadSlot(proxy, slot));
        _writeSlot(proxy, slot, bytes32(current + activeShares));

        // LP.mint is onlyOwner == hook proxy; prank as the proxy to satisfy the access check.
        vm.prank(proxy);
        UniswapLP(liquidityToken).mint(owner, activeShares);
    }
}
