// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {SwapGuardMath} from "./libraries/SwapGuardMath.sol";
import {LiquidityQuote} from "./libraries/LiquidityQuote.sol";
import {MemeversePoolKeyLib} from "./libraries/MemeversePoolKeyLib.sol";
import {MemeverseTransientState} from "./libraries/MemeverseTransientState.sol";
import {UniswapLP} from "./tokens/UniswapLP.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {ISwapFacet} from "./interfaces/ISwapFacet.sol";
import {ISettlementFacet} from "./interfaces/ISettlementFacet.sol";
import {IMemeverseHookStorage} from "./interfaces/IMemeverseHookStorage.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {OutrunOwnable} from "../common/access/OutrunOwnable.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";

/**
 * @title MemeverseUniswapHookUpgradeable
 * @notice Thin diamond Router for the Memeverse Uniswap v4 hook.
 * @dev High-level flow:
 * - This contract is the single Uniswap hook address and the only storage owner. It owns the ERC7201
 *   namespace `outrun.storage.MemeverseUniswapHook`, shared with the delegatecall facets
 *   (`SwapFacet`, `DynamicFeeFacet`, `SettlementFacet`) via `layout at`.
 * - v4 callbacks (`beforeSwap` / `afterSwap` / `beforeInitialize` / `beforeAddLiquidity`) are thin
 *   entries that `delegatecall` into `swapFacet`; the facet runs in the Router storage context so all
 *   reads/writes land in the shared namespace.
 * - `executePreorderSettlement` is a thin entry that `delegatecall`s into `settlementFacet`.
 * - `quoteSwapFeeWithContext` is a thin entry that `delegatecall`s into `dynamicFeeFacet`; the Lens reaches
 *   this bridge with `STATICCALL`, whose EIP-214 static context propagates into the delegated facet.
 * - Liquidity management (`addLiquidityCore` / `removeLiquidityCore` / `claimFeesCore`) and the LP
 *   per-share snapshot helper (`updateUserSnapshot`) are implemented directly on the Router; the
 *   snapshot body itself is delegated to `swapFacet.updateUserSnapshotLogic`.
 * - Rebate claim is implemented directly on the Router because the rebate token custody lives on the
 *   hook proxy (the facet `take`s into `address(this)` under delegatecall).
 * - Admin setters, view getters, and the `IUnlockCallback` entry (which routes explicit typed callback
 *   payloads to liquidity or settlement logic) live here.
 *
 * Upgrade invariant: the hook proxy address is the real Uniswap hook address, and the external ABI
 * (v4 callback selectors, admin/view/liquidity selectors, and `quoteSwapFeeWithContext`) is the
 * contract callers depend on. Facet addresses are owner-configurable via `setFacet`.
 */
// solhint-disable-next-line gas-small-strings
contract MemeverseUniswapHookUpgradeable layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    IMemeverseHookStorage,
    IMemeverseUniswapHook,
    IUnlockCallback,
    ImmutableState,
    ReentrancyGuardTransient,
    Initializable,
    OutrunOwnableUpgradeable,
    UUPSUpgradeable
{
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int128;

    /// @notice Role discriminator for the swap callback facet (`beforeSwap` / `afterSwap` /
    ///         `beforeInitialize` / `beforeAddLiquidity` + `updateUserSnapshotLogic`).
    bytes32 public constant SWAP_FACET_ROLE = keccak256("mv.hook.facet.swap");
    /// @notice Role discriminator for the dynamic fee facet (quote + realized-state writes).
    bytes32 public constant DYNAMIC_FEE_FACET_ROLE = keccak256("mv.hook.facet.dynamicFee");
    /// @notice Role discriminator for the preorder settlement facet (entry + settlement unlock callback).
    bytes32 public constant SETTLEMENT_FACET_ROLE = keccak256("mv.hook.facet.settlement");

    /// @dev Default referral rebate rate (10% of total fee), written by `initialize` and read by
    ///      `SwapFacet._collectProtocolFee`. Typed `uint24` to match the storage field and guarantee
    ///      the value fits without cast.
    uint24 internal constant DEFAULT_REFERRAL_REBATE_BPS = 1000;

    /// @dev Default launch-fee schedule written by `initialize`. Typed to match the storage fields in
    ///      `IDynamicFeeFacet.LaunchFeeConfig` so the literal casts are lossless and the same values are
    ///      reused by the matching `DefaultLaunchFeeConfigUpdated` emit without re-stating the literals.
    uint24 internal constant DEFAULT_LAUNCH_START_FEE_BPS = 5000;
    uint24 internal constant DEFAULT_LAUNCH_MIN_FEE_BPS = 100;
    uint32 internal constant DEFAULT_LAUNCH_DECAY_SECONDS = 900;

    /// @notice Typed payload for the liquidity branch of `PoolManager.unlock`.
    struct ModifyLiquidityCallbackData {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    MemeverseUniswapHookStorage private _memeverseUniswapHookStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param _manager Uniswap v4 pool manager stored by `ImmutableState` as immutable implementation bytecode state.
    constructor(IPoolManager _manager) ImmutableState(_manager) {
        if (address(_manager) == address(0)) revert ZeroAddress();
        _disableInitializers();
    }

    /// @notice Initializes owner-controlled Router state for an upgradeable proxy.
    /// @dev The proxy address is the real Uniswap hook address, so hook permission flags are validated
    ///      here. Facets reject direct CALLs via an immutable self-address guard (`__self`), independent of
    ///      Router storage; no hook self-address is stored for the facet guard.
    ///
    ///      The `launcher` is bound here exactly once and never retargeted (there is no `setLauncher`):
    ///      the OZ `initializer` modifier makes this write-once, mirroring the launcher-side write-once
    ///      hook binding (`setMemeverseUniswapHook` + back-pointer check). A retargetable launcher binding
    ///      would let an owner orphan the launcher and permanently lock every `onlyLauncher` verse flow.
    /// @param initialOwner Initial owner authorized to configure and upgrade the Router.
    /// @param treasury_ Treasury receiving protocol fees.
    /// @param lpTokenImplementation_ Clone implementation used for pool LP tokens.
    /// @param swapFacet_ Facet holding the v4 swap callback logic.
    /// @param dynamicFeeFacet_ Facet holding the dynamic fee quote and realized-state logic.
    /// @param settlementFacet_ Facet holding the preorder settlement entry and unlock callback.
    /// @param launcher_ Launcher consulted for post-unlock public-swap protection; write-once via this initializer.
    function initialize(
        address initialOwner,
        address treasury_,
        address lpTokenImplementation_,
        address swapFacet_,
        address dynamicFeeFacet_,
        address settlementFacet_,
        address launcher_
    ) external initializer {
        if (
            treasury_ == address(0) || lpTokenImplementation_ == address(0) || swapFacet_ == address(0)
                || dynamicFeeFacet_ == address(0) || settlementFacet_ == address(0) || launcher_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (lpTokenImplementation_.code.length == 0) revert LPTokenImplementationCodeNotReady(lpTokenImplementation_);
        // Each facet must share this hook's PoolManager: a facet bound to a different PoolManager would
        // settle/take against the wrong manager under delegatecall and break accounting silently.
        _requireFacetPoolManager(swapFacet_);
        _requireFacetPoolManager(dynamicFeeFacet_);
        _requireFacetPoolManager(settlementFacet_);
        _validateProxyHookAddress();
        __OutrunOwnable_init(initialOwner);

        _memeverseUniswapHookStorage.treasury = treasury_;
        _memeverseUniswapHookStorage.lpTokenImplementation = lpTokenImplementation_;
        _memeverseUniswapHookStorage.swapFacet = swapFacet_;
        _memeverseUniswapHookStorage.dynamicFeeFacet = dynamicFeeFacet_;
        _memeverseUniswapHookStorage.settlementFacet = settlementFacet_;
        // Launcher is write-once: bound here and never retargeted (no setLauncher), mirroring the
        // launcher-side write-once hook binding so onlyLauncher flows can never be orphaned.
        _memeverseUniswapHookStorage.launcher = launcher_;
        // Emit initial facet bindings so indexers/subgraphs tracking FacetUpdated observe
        // deployment-time bindings. address(0) denotes the initial oldFacet value.
        emit FacetUpdated(SWAP_FACET_ROLE, address(0), swapFacet_);
        emit FacetUpdated(DYNAMIC_FEE_FACET_ROLE, address(0), dynamicFeeFacet_);
        emit FacetUpdated(SETTLEMENT_FACET_ROLE, address(0), settlementFacet_);
        emit TreasuryUpdated(address(0), treasury_);
        emit LPTokenImplementationUpdated(address(0), lpTokenImplementation_);
        emit LauncherUpdated(address(0), launcher_);
        _memeverseUniswapHookStorage.defaultLaunchFeeConfig = IDynamicFeeFacet.LaunchFeeConfig({
            startFeeBps: DEFAULT_LAUNCH_START_FEE_BPS,
            minFeeBps: DEFAULT_LAUNCH_MIN_FEE_BPS,
            decayDurationSeconds: DEFAULT_LAUNCH_DECAY_SECONDS
        });
        emit DefaultLaunchFeeConfigUpdated(
            0, 0, 0, DEFAULT_LAUNCH_START_FEE_BPS, DEFAULT_LAUNCH_MIN_FEE_BPS, DEFAULT_LAUNCH_DECAY_SECONDS
        );
        // Initialize the current default referral rebate rate (10% of total fee).
        // Deployment-time guard: the compiled-in default must never exceed the protocol fee share cap,
        // otherwise `SwapFacet._collectProtocolFee` would compute `rebate > protocolFeeAmount` and the
        // `toTreasury = protocolFeeAmount - rebate` subtraction would underflow, reverting every referrer
        // swap. This branch is intentionally runtime-unreachable: it fail-fast at the only path that can
        // write an out-of-range default (this `initialize` write), complementing `setReferrerRebateBps`'s
        // runtime `<= PROTOCOL_FEE_SHARE_BPS` cap.
        if (DEFAULT_REFERRAL_REBATE_BPS > FeeMath.PROTOCOL_FEE_SHARE_BPS) revert RebateExceedsProtocolShare();
        _memeverseUniswapHookStorage.referrerRebateBps = DEFAULT_REFERRAL_REBATE_BPS;
        emit ReferrerRebateBpsUpdated(0, DEFAULT_REFERRAL_REBATE_BPS);
    }

    /// @dev Catch-all for selectors absent from this hook's ABI. Reverts with the offending selector and
    ///      does not route to facets; supported facet dispatch uses explicit thin-entry functions.
    fallback() external {
        revert UnsupportedSelector(msg.sig);
    }

    /// @inheritdoc IMemeverseUniswapHook
    function owner() public view override(OutrunOwnable, IMemeverseUniswapHook) returns (address) {
        return super.owner();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev UUPS upgrade gate. The hook proxy is upgradeable; authorization is restricted to the hook owner
    ///      so a stale caller or a compromised facet cannot swap the implementation. Mirrors the launcher
    ///      (MemeverseLauncherUpgradeable.sol) UUPS pattern. Also guards against poolManager drift: a new implementation
    ///      bound to a different PoolManager would silently break every swap and LP path, so we revert
    ///      `UpgradePoolManagerMismatch`. This is an operational guardrail, not a security boundary — a
    ///      malicious owner could ship a fake `poolManager()` getter, but it catches honest constructor
    ///      mistakes during upgrade.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // Named pre-check for a no-code target: without it the probe's STATICCALL to a codeless
        // address would SUCCEED with empty returndata, and that success-path decode failure is
        // outside Solidity try/catch — it bubbles as a raw decode revert (see the boundary note
        // below), losing the precise `UpgradeTargetCodeNotReady` label.
        if (newImplementation.code.length == 0) revert UpgradeTargetCodeNotReady(newImplementation);
        // Read the new implementation's immutable PoolManager via the same ImmutableState getter the
        // facets use, then reject drift. The try/catch folds the unreadable-target failures it can see
        // (getter missing, probe reverts) into the named `UpgradePoolManagerUnreadable` instead of a bare
        // revert. One class stays outside the catch: a successful call whose return data cannot be
        // ABI-decoded is NOT caught by Solidity try/catch semantics and bubbles up as the raw decode
        // revert — still fail-closed, the upgrade is rejected either way, only the error label differs.
        // `currentPoolManager` is the local immutable self-read (address(poolManager), not an external
        // call); caching the getter result in `newPoolManager` avoids re-issuing that STATICCALL when
        // assembling the revert payload.
        address currentPoolManager = address(poolManager);
        try ImmutableState(newImplementation).poolManager() returns (IPoolManager newPoolManager) {
            if (address(newPoolManager) != currentPoolManager) {
                revert UpgradePoolManagerMismatch(currentPoolManager, address(newPoolManager));
            }
        } catch {
            revert UpgradePoolManagerUnreadable(newImplementation);
        }
    }

    /// @dev Only test subclasses may override this to skip hook-address validation.
    /// Production deployments must not override — the proxy address must carry the correct flags.
    function _validateProxyHookAddress() internal view virtual {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // -----------------------------------------------------------------
    // Diamond dispatch helper
    // -----------------------------------------------------------------

    /// @dev Delegatecalls into `facet` with `data` and bubbles up any revert verbatim, via OZ
    ///      `Address.functionDelegateCall` (which also reverts with `AddressEmptyCode` when the target
    ///      has no code, hardening against misconfiguration). The facet runs in this contract's storage
    ///      context (one hook per proxy), so `address(this)` stays the hook and all state reads/writes
    ///      land in the shared ERC7201 namespace. Selector encoding on the caller side
    ///      (`abi.encodeCall(IFacet.<func>, (...))`) is load-bearing — a signature drift silently
    ///      disables the corresponding callback. Use this helper when the inner facet signature differs
    ///      from the outer entry, or when called from an internal context where `msg.data` is not the
    ///      mirroring entry; when the inner `*Logic` mirrors the outer entry 1:1, prefer `_forwardCalldata`
    ///      (selector swap only, no per-field re-encoding).
    ///      The delegatecall target is an owner-controlled facet, not an arbitrary address: `setFacet` is
    ///      guarded by `onlyOwner` and each candidate facet is verified by `_requireFacetPoolManager`
    ///      (code present + immutable `poolManager` matching this hook). This is the standard EIP-2535
    ///      diamond pattern, so the controlled-delegatecall detector is inherent rather than exploitable here.
    // NOTE: kept as the single low-level delegatecall implementation so the one
    // suppression below applies to both typed dispatches and calldata forwarders.
    // slither-disable-next-line controlled-delegatecall
    function _facetDelegatecall(address facet, bytes memory data) internal returns (bytes memory ret) {
        return Address.functionDelegateCall(facet, data);
    }

    /// @dev Forward the CURRENT calldata to `facet` with its 4-byte selector replaced by `innerSelector`,
    ///      then delegatecall. Valid ONLY when the inner `*Logic` signature mirrors the outer entry 1:1
    ///      (same param types/order), so outer calldata[4:] is byte-identical to the inner calldata args -
    ///      skipping `abi.encodeCall`'s per-field re-encoding. Pure Solidity: `bytes.concat(selector,
    ///      msg.data[4:])` compiles to a selector write + a single CALLDATACOPY (cheaper than an assembly
    ///      selector swap, which under `via_ir` mis-reads a `bytes4` arg as 0x00000000). `msg.data` still
    ///      reflects the outer entry's calldata because this is an internal call. The delegatecall target is
    ///      an owner-controlled facet guarded exactly like `_facetDelegatecall` above (same EIP-2535 diamond
    ///      pattern: `setFacet` is `onlyOwner` + `_requireFacetPoolManager`), so the controlled-delegatecall
    ///      detector is inherent, not exploitable.
    function _forwardCalldata(address facet, bytes4 innerSelector) internal returns (bytes memory) {
        return _facetDelegatecall(facet, bytes.concat(innerSelector, msg.data[4:]));
    }

    /// @dev Same forward as `_forwardCalldata`, then return the facet returndata verbatim to the
    ///      external caller (OZ Proxy-style). Valid ONLY for thin entries with no post-body modifier
    ///      cleanup (e.g. pure `onlyPoolManager`). MUST NOT be used under `nonReentrant` or any
    ///      modifier that runs code after `_`, because assembly `return` ends the whole external call.
    function _forwardCalldataAndReturn(address facet, bytes4 innerSelector) internal {
        bytes memory ret = _forwardCalldata(facet, innerSelector);
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
        }
    }

    function _requireFacetPoolManager(address facet) internal view {
        if (facet.code.length == 0) revert FacetCodeNotReady(facet);
        // ImmutableState exposes `poolManager` as a public immutable getter on each facet. The try/catch
        // folds the unreadable-facet failures it can see (getter missing, probe reverts) into the named
        // `FacetPoolManagerUnreadable` instead of a bare revert; a successful call whose return data cannot
        // be ABI-decoded is NOT caught by Solidity try/catch semantics and bubbles up as the raw decode
        // revert — the facet swap is rejected (fail-closed) either way. Caching the getter result in
        // `facetPoolManager` reuses the same value for the mismatch revert instead of re-issuing the
        // STATICCALL; mirrors `_authorizeUpgrade`.
        try ImmutableState(facet).poolManager() returns (IPoolManager facetPoolManager) {
            if (address(facetPoolManager) != address(poolManager)) {
                revert FacetPoolManagerMismatch(facet, address(poolManager), address(facetPoolManager));
            }
        } catch {
            revert FacetPoolManagerUnreadable(facet);
        }
    }

    // -----------------------------------------------------------------
    // View getters
    // -----------------------------------------------------------------

    /// @inheritdoc IMemeverseUniswapHook
    function lpTokenImplementation() external view override returns (address) {
        return _memeverseUniswapHookStorage.lpTokenImplementation;
    }

    /// @inheritdoc IMemeverseUniswapHook
    function treasury() external view override returns (address) {
        return _memeverseUniswapHookStorage.treasury;
    }

    /// @inheritdoc IMemeverseUniswapHook
    function launcher() external view override returns (address) {
        return _memeverseUniswapHookStorage.launcher;
    }

    function supportedProtocolFeeCurrencies(address currency) external view override returns (bool) {
        return _memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[currency];
    }

    function poolInfo(PoolId poolId)
        external
        view
        override
        returns (address liquidityToken, uint256 fee0PerShare, uint256 fee1PerShare)
    {
        PoolInfo storage info = _memeverseUniswapHookStorage.poolInfo[poolId];
        return (info.liquidityToken, info.fee0PerShare, info.fee1PerShare);
    }

    function liquidityTokenOf(PoolId poolId) external view override returns (address liquidityToken) {
        return _memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken;
    }

    function cachedLpTotalSupply(PoolId poolId) external view override returns (uint256 supply) {
        return _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
    }

    function poolLaunchTimestamp(PoolId poolId) external view override returns (uint40) {
        return _memeverseUniswapHookStorage.poolLaunchTimestamp[poolId];
    }

    function publicSwapResumeTime(PoolId poolId) external view override returns (uint40) {
        return _memeverseUniswapHookStorage.publicSwapResumeTime[poolId];
    }

    function userFeeState(PoolId poolId, address user)
        external
        view
        override
        returns (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1)
    {
        UserFeeState storage state = _memeverseUniswapHookStorage.userFeeState[poolId][user];
        return (state.fee0Offset, state.fee1Offset, state.pendingFee0, state.pendingFee1);
    }

    function defaultLaunchFeeConfig()
        external
        view
        override
        returns (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds)
    {
        IDynamicFeeFacet.LaunchFeeConfig storage config = _memeverseUniswapHookStorage.defaultLaunchFeeConfig;
        return (config.startFeeBps, config.minFeeBps, config.decayDurationSeconds);
    }

    function poolInitializer() external view override returns (address) {
        return _memeverseUniswapHookStorage.poolInitializer;
    }

    /// @inheritdoc IMemeverseUniswapHook
    function swapFacet() external view override returns (address) {
        return _memeverseUniswapHookStorage.swapFacet;
    }

    /// @inheritdoc IMemeverseUniswapHook
    function dynamicFeeFacet() external view override returns (address) {
        return _memeverseUniswapHookStorage.dynamicFeeFacet;
    }

    /// @inheritdoc IMemeverseUniswapHook
    function settlementFacet() external view override returns (address) {
        return _memeverseUniswapHookStorage.settlementFacet;
    }

    // -----------------------------------------------------------------
    // Unsupported selector handling
    // -----------------------------------------------------------------
    // Every supported facet route has an explicit external entry; all other selectors reach `fallback`.

    // -----------------------------------------------------------------
    // v4 hook callback thin entries → delegatecall SwapFacet
    // -----------------------------------------------------------------

    /// @notice PoolManager callback before a hook-managed pool is initialized.
    /// @dev Thin entry: forwards the outer calldata to `swapFacet.beforeInitializeLogic` via
    ///      `_forwardCalldataAndReturn` (selector swap + verbatim facet returndata). Valid because the
    ///      inner `beforeInitializeLogic` signature mirrors this entry 1:1 and `onlyPoolManager` has no
    ///      post-body cleanup.
    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        _forwardCalldataAndReturn(_memeverseUniswapHookStorage.swapFacet, ISwapFacet.beforeInitializeLogic.selector);
    }

    /// @notice PoolManager callback before a hook-managed swap.
    /// @dev Thin entry: forwards the outer calldata to `swapFacet.beforeSwapLogic` via
    ///      `_forwardCalldataAndReturn` (selector swap + verbatim facet returndata). Valid because the
    ///      inner `beforeSwapLogic` signature mirrors this entry 1:1 and `onlyPoolManager` has no
    ///      post-body cleanup.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _forwardCalldataAndReturn(_memeverseUniswapHookStorage.swapFacet, ISwapFacet.beforeSwapLogic.selector);
    }

    /// @notice PoolManager callback after a hook-managed swap.
    /// @dev Thin entry: forwards the outer calldata to `swapFacet.afterSwapLogic` via
    ///      `_forwardCalldataAndReturn` (selector swap + verbatim facet returndata). Valid because the
    ///      inner `afterSwapLogic` signature mirrors this entry 1:1 and `onlyPoolManager` has no
    ///      post-body cleanup.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _forwardCalldataAndReturn(_memeverseUniswapHookStorage.swapFacet, ISwapFacet.afterSwapLogic.selector);
    }

    /// @notice PoolManager callback before liquidity is added to a hook-managed pool.
    /// @dev Thin entry: forwards the outer calldata to `swapFacet.beforeAddLiquidityLogic` via
    ///      `_forwardCalldataAndReturn` (selector swap + verbatim facet returndata). Valid because the
    ///      inner `beforeAddLiquidityLogic` signature mirrors this entry 1:1 and `onlyPoolManager` has no
    ///      post-body cleanup.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _forwardCalldataAndReturn(_memeverseUniswapHookStorage.swapFacet, ISwapFacet.beforeAddLiquidityLogic.selector);
    }

    /// @notice Declares which hook callbacks are enabled for this hook.
    /// @dev Memeverse uses only `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, and `afterSwap`.
    /// @return permissions The callback permission bitmap consumed by the Uniswap v4 hook framework.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------------------------
    // Smart-EOA transient account session (Hook owns the transient store)
    // -----------------------------------------------------------------
    // Identity root for the dynamic-fee address-batch key. There is NO principal parameter anywhere: the
    // hook captures the direct caller of `beginAccountSession` as `activePrincipal`, and every swap callback
    // in this transaction reads that value. `activePrincipal != address(0)` is the sole session-active
    // marker; a non-zero `SwapContext.principal` is the sole swap-context presence marker. These entries run
    // directly against this contract's own transient store (not via the Router `onlyViaRouter` facet path).

    /// @inheritdoc IMemeverseUniswapHook
    function beginAccountSession() external override {
        address principal = msg.sender;
        // Presence gate, not auth/allowlist: a no-code EOA cannot atomically run begin → Router → end, so it
        // is rejected. This accepts EIP-7702-delegated EOAs (EXTCODESIZE == 23) and any deployed contract
        // account; it does NOT authenticate the account implementation behind the caller.
        if (principal.code.length == 0) revert AccountSessionCallerMustHaveCode(principal);
        address active = MemeverseTransientState.activePrincipal();
        if (active != address(0)) revert AccountSessionAlreadyActive(active);
        uint256 depth = MemeverseTransientState.swapContextDepth();
        if (depth != 0) revert AccountSessionHasPendingContext(depth);
        MemeverseTransientState.setActivePrincipal(principal);
    }

    /// @inheritdoc IMemeverseUniswapHook
    function endAccountSession() external override {
        address active = MemeverseTransientState.activePrincipal();
        if (active == address(0)) revert AccountSessionNotActive();
        if (msg.sender != active) revert AccountSessionUnauthorized(msg.sender, active);
        uint256 depth = MemeverseTransientState.swapContextDepth();
        if (depth != 0) revert AccountSessionHasPendingContext(depth);
        MemeverseTransientState.clearActivePrincipal();
    }

    /// @inheritdoc IMemeverseUniswapHook
    function activeAccountSessionPrincipal() external view override returns (address principal) {
        principal = MemeverseTransientState.activePrincipal();
    }

    modifier onlyLauncher() {
        _checkLauncher();
        _;
    }

    modifier erc20Pair(Currency currency0, Currency currency1) {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(currency0, currency1);
        _;
    }

    function _checkLauncher() private view {
        if (msg.sender != _memeverseUniswapHookStorage.launcher) revert Unauthorized();
    }

    // -----------------------------------------------------------------
    // Liquidity management (implemented directly on the Router)
    // -----------------------------------------------------------------

    /// @notice Add full-range liquidity while the caller funds the assets and receives LP shares at `params.to`.
    /// @dev This is the low-level liquidity-add entrypoint intended for routers and other on-chain integrators.
    /// It omits deadline and min-amount checks and returns the settled delta to the caller.
    /// @param params The core liquidity-add parameters.
    /// @return liquidity The LP liquidity minted by the operation.
    /// @return delta The balance delta settled against the caller.
    function addLiquidityCore(AddLiquidityCoreParams calldata params)
        external
        override
        nonReentrant
        returns (uint128 liquidity, BalanceDelta delta)
    {
        return _addLiquidityCore(params, msg.sender);
    }

    function _addLiquidityCore(AddLiquidityCoreParams memory params, address payer)
        internal
        returns (uint128 liquidity, BalanceDelta addedDelta)
    {
        if (params.to == address(0)) revert ZeroAddress();
        SwapGuardMath.revertIfNativeCurrencyUnsupported(params.currency0, params.currency1);
        // Out-of-order currencies must not be silently re-sorted into the canonical pool (this core API
        // trusts the caller's ordering): previously the unsorted key mapped to a nonexistent poolId that
        // reverted `PoolNotInitialized` below, so keep failing closed with the same error here.
        if (Currency.unwrap(params.currency0) > Currency.unwrap(params.currency1)) revert PoolNotInitialized();
        PoolKey memory key = MemeversePoolKeyLib.hookPoolKey(
            Currency.unwrap(params.currency0), Currency.unwrap(params.currency1), address(this)
        );
        PoolId poolId = key.toId();

        // Hold the per-pool swap-lifecycle lock across the snapshot -> settle -> mint window: a callback
        // token (ERC-777/1363) reentering poolManager.swap on this pool during the settle transferFrom would
        // advance feePerShare between the recipient's fee snapshot and the LP mint, letting the freshly minted
        // shares claim fees that accrued before they existed. The same lock already guards the swap and
        // settlement paths; holding it here makes beforeSwapLogic reject such a reentrant swap.
        if (MemeverseTransientState.acquireSwapLifecycleLock(poolId)) {
            revert SwapLifecycleReentrant();
        }

        PoolInfo storage pool = _memeverseUniswapHookStorage.poolInfo[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        // Read once: the delegatecall at _updateUserSnapshotViaFacet blocks the optimizer from
        // reusing this value at the mint site, so caching avoids a redundant warm SLOAD there.
        address liquidityToken = pool.liquidityToken;
        if (liquidityToken == address(0) || sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Crystallize the recipient's accrued fees before minting changes their LP balance baseline.
        _updateUserSnapshotViaFacet(poolId, params.to);

        (liquidity,,) = LiquidityQuote.quote(sqrtPriceX96, params.amount0Desired, params.amount1Desired);

        addedDelta = _modifyLiquidity(
            payer,
            key,
            ModifyLiquidityParams({
                tickLower: MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK,
                tickUpper: MemeversePoolKeyLib.FULL_RANGE_UPPER_TICK,
                liquidityDelta: uint256(liquidity).toInt256(),
                salt: 0
            })
        );

        UniswapLP(liquidityToken).mint(params.to, liquidity);
        _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId] += liquidity;

        // Window closed: the snapshot, the settle window, and the mint now agree on feePerShare. A revert
        // earlier in this function leaves the transient lock to auto-clear at tx end, mirroring the
        // settlement path's release-only-on-normal-return semantics.
        MemeverseTransientState.releaseSwapLifecycleLock(poolId);

        emit LiquidityAdded(
            poolId,
            payer,
            params.to,
            liquidity,
            uint256((-addedDelta.amount0()).toUint128()),
            uint256((-addedDelta.amount1()).toUint128())
        );
    }

    /// @notice Removes full-range liquidity owned by the caller and sends the underlying assets to `params.recipient`.
    /// @dev This is the low-level liquidity exit entrypoint intended for routers and other on-chain integrators.
    /// It omits deadline and min-amount checks.
    /// @param params The core liquidity-remove parameters.
    /// @return delta The balance delta returned by the liquidity removal.
    function removeLiquidityCore(RemoveLiquidityCoreParams calldata params)
        external
        override
        nonReentrant
        returns (BalanceDelta delta)
    {
        return _removeLiquidityCore(params);
    }

    function _removeLiquidityCore(RemoveLiquidityCoreParams memory params) internal returns (BalanceDelta delta) {
        if (params.recipient == address(0)) revert ZeroAddress();
        SwapGuardMath.revertIfNativeCurrencyUnsupported(params.currency0, params.currency1);
        // Out-of-order currencies must not be silently re-sorted into the canonical pool (this core API
        // trusts the caller's ordering): previously the unsorted key mapped to a nonexistent poolId that
        // reverted `PoolNotInitialized` on the getLiquidity check below, so keep failing closed here.
        if (Currency.unwrap(params.currency0) > Currency.unwrap(params.currency1)) revert PoolNotInitialized();
        PoolKey memory key = MemeversePoolKeyLib.hookPoolKey(
            Currency.unwrap(params.currency0), Currency.unwrap(params.currency1), address(this)
        );
        PoolId poolId = key.toId();
        if (poolManager.getLiquidity(poolId) == 0) revert PoolNotInitialized();

        // Crystallize the caller's accrued fees before burning changes their LP balance baseline.
        _updateUserSnapshotViaFacet(poolId, msg.sender);

        UniswapLP lp = UniswapLP(_memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken);
        lp.burn(msg.sender, params.liquidity);
        _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId] -= params.liquidity;

        delta = _modifyLiquidity(
            params.recipient,
            key,
            ModifyLiquidityParams({
                tickLower: MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK,
                tickUpper: MemeversePoolKeyLib.FULL_RANGE_UPPER_TICK,
                liquidityDelta: -(uint256(params.liquidity).toInt256()),
                salt: 0
            })
        );

        emit LiquidityRemoved(
            poolId,
            msg.sender,
            params.liquidity,
            uint256(delta.amount0().toUint128()),
            uint256(delta.amount1().toUint128())
        );
    }

    /// @notice Claims the caller's pending LP fees and sends them to the requested recipient.
    /// @dev Fee ownership is derived strictly from `msg.sender`; relayed or signature-based claims are unsupported.
    /// @param params The core fee-claim parameters.
    /// @return fee0Amount The claimed amount of currency0 fees.
    /// @return fee1Amount The claimed amount of currency1 fees.
    function claimFeesCore(ClaimFeesCoreParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        return _claimFees(params.key, msg.sender, params.recipient);
    }

    /// @notice Execute preorder settlement through a dedicated hook path.
    /// @dev Thin entry: forwards the outer calldata to `settlementFacet.executeSettlementLogic` via
    ///      `_forwardCalldata` (selector swap only, no abi re-encoding). Valid because the inner
    ///      `executeSettlementLogic` signature mirrors this entry 1:1. The launcher-only gate, reentrancy
    ///      guard, and ERC20-pair check live here (and consume `params`) so the facet body stays
    ///      single-purpose; they only inspect `params`/`msg.sender` and do not alter the forwarded calldata.
    /// @param params Preorder settlement request.
    /// @return delta Net settlement delta consumed by the launcher accounting path.
    function executePreorderSettlement(PreorderSettlementParams calldata params)
        external
        override
        nonReentrant
        onlyLauncher
        erc20Pair(params.key.currency0, params.key.currency1)
        returns (BalanceDelta delta)
    {
        return abi.decode(
            _forwardCalldata(
                _memeverseUniswapHookStorage.settlementFacet, ISettlementFacet.executeSettlementLogic.selector
            ),
            (BalanceDelta)
        );
    }

    function _modifyLiquidity(address sender, PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockCallbackKind.ModifyLiquidity,
                    ModifyLiquidityCallbackData({sender: sender, key: key, params: params})
                )
            ),
            (BalanceDelta)
        );
    }

    /// @notice Callback invoked by the PoolManager during `unlock` flow.
    /// @dev Only callable by the PoolManager. Reads the first ABI word as a raw discriminator via a
    ///      calldata slice (`rawData[:32]`); the slice carries an implicit `length >= 32` revert, and
    ///      `length >= 32` is structurally guaranteed because rawData is always this contract's own
    ///      `abi.encode(UnlockCallbackKind, ...)`. ModifyLiquidity still decodes its typed tuple; Settlement
    ///      slice-forwards the static payload (see branch comment). Unknown well-formed kinds revert with
    ///      `InvalidUnlockCallbackKind`; structurally corrupt payloads still hit a standard decode failure
    ///      in the ModifyLiquidity branch.
    /// @param rawData Encoded liquidity or settlement callback payload.
    /// @return result Encoded return value for the unlock caller.
    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        uint256 rawKind = uint256(bytes32(rawData[:32]));

        if (rawKind == uint256(UnlockCallbackKind.ModifyLiquidity)) {
            (, ModifyLiquidityCallbackData memory data) =
                abi.decode(rawData, (UnlockCallbackKind, ModifyLiquidityCallbackData));
            BalanceDelta delta;
            (delta,) = poolManager.modifyLiquidity(data.key, data.params, bytes(""));
            if (data.params.liquidityDelta < 0) {
                _takeDeltas(data.sender, data.key, delta);
            } else {
                _settleDeltas(data.sender, data.key, delta);
            }
            return abi.encode(delta);
        }

        if (rawKind == uint256(UnlockCallbackKind.Settlement)) {
            // SettlementCallbackData is fully static today: abi.encode(kind, data) lays
            // `data` contiguously at rawData[32:]. Prepend the facet selector and forward —
            // byte-identical to abi.encodeCall(settlementUnlockCallback, (data)), without
            // memory decode + re-encode. If SettlementCallbackData gains a dynamic field,
            // this must return to abi.encodeCall (or redesign the envelope).
            // Return the facet's typed returndata as the callback bytes payload. PoolManager forwards that
            // content verbatim, so the settlement entry decodes `SettlementResult` exactly once.
            return _facetDelegatecall(
                _memeverseUniswapHookStorage.settlementFacet,
                bytes.concat(ISettlementFacet.settlementUnlockCallback.selector, rawData[32:])
            );
        }

        revert InvalidUnlockCallbackKind(rawKind);
    }

    /// @dev Mirrors v4-periphery DeltaResolver: skip the sync+transfer+settle / take
    ///      round-trip when a leg delta is 0 (e.g. a liquidity quote resolved to 0,
    ///      making both legs zero). No-op on compliant ERC20s; this avoids the
    ///      wasted external calls and any 0-value-transfer revert on non-compliant tokens.
    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        uint128 amount0 = (-delta.amount0()).toUint128();
        uint128 amount1 = (-delta.amount1()).toUint128();
        if (amount0 > 0) key.currency0.settle(poolManager, sender, amount0);
        if (amount1 > 0) key.currency1.settle(poolManager, sender, amount1);
    }

    function _takeDeltas(address recipient, PoolKey memory key, BalanceDelta delta) internal {
        uint128 amount0 = delta.amount0().toUint128();
        uint128 amount1 = delta.amount1().toUint128();
        if (amount0 > 0) poolManager.take(key.currency0, recipient, amount0);
        if (amount1 > 0) poolManager.take(key.currency1, recipient, amount1);
    }

    function _claimFees(PoolKey memory key, address feeOwner, address recipient)
        internal
        erc20Pair(key.currency0, key.currency1)
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        PoolId poolId = key.toId();

        if (_memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken == address(0)) revert PoolNotInitialized();

        _updateUserSnapshotViaFacet(poolId, feeOwner);

        UserFeeState storage state = _memeverseUniswapHookStorage.userFeeState[poolId][feeOwner];
        fee0Amount = state.pendingFee0;
        fee1Amount = state.pendingFee1;

        // CEI: zero the pending balance before the external transfer.
        if (fee0Amount > 0) {
            state.pendingFee0 = 0;
            key.currency0.transferWithGuard(recipient, fee0Amount);
        }
        if (fee1Amount > 0) {
            state.pendingFee1 = 0;
            key.currency1.transferWithGuard(recipient, fee1Amount);
        }

        if (fee0Amount > 0 || fee1Amount > 0) {
            emit FeesClaimed(poolId, feeOwner, key.currency0, key.currency1, fee0Amount, fee1Amount);
        }
    }

    function _poolIdForTokens(address tokenA, address tokenB)
        internal
        view
        erc20Pair(Currency.wrap(tokenA), Currency.wrap(tokenB))
        returns (PoolId poolId)
    {
        poolId = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, address(this)).toId();
    }

    /// @dev Reaches the per-share accounting on `swapFacet` via delegatecall so the snapshot body
    ///      has a single source of truth shared with the v4 swap callbacks.
    function _updateUserSnapshotViaFacet(PoolId poolId, address user) internal {
        _facetDelegatecall(
            _memeverseUniswapHookStorage.swapFacet, abi.encodeCall(ISwapFacet.updateUserSnapshotLogic, (poolId, user))
        );
    }

    /// @notice Updates the user fee accounting snapshot for a pool.
    /// @dev LP token transfers call this selector to keep per-share offsets current. Forwards the outer
    ///      calldata to `swapFacet.updateUserSnapshotLogic` via `_forwardCalldata` (selector swap only, no
    ///      abi re-encoding) — valid because the inner signature mirrors this entry 1:1, so the accounting
    ///      runs in this Router's storage. This void entry uses `_forwardCalldata` (drops facet returndata)
    ///      rather than `_forwardCalldataAndReturn`: the facet is void so there is nothing to return, unlike
    ///      the 4 v4-callback thin entries which must pass non-empty tuples (`bytes4`/`BeforeSwapDelta`)
    ///      verbatim to the PoolManager. The choice is structural, not a gas optimization (pure Solidity also
    ///      avoids the assembly-return constraints of `_forwardCalldataAndReturn`).
    ///      Parameter docs live on `IMemeverseUniswapHook.updateUserSnapshot`; params are unnamed (raw calldata).
    function updateUserSnapshot(PoolId, address) external override {
        _forwardCalldata(_memeverseUniswapHookStorage.swapFacet, ISwapFacet.updateUserSnapshotLogic.selector);
    }

    // -----------------------------------------------------------------
    // Dynamic fee quote and fee-state reads
    // -----------------------------------------------------------------

    /// @notice Quotes only the dynamic-fee portion of a public swap.
    /// @dev UPGRADE INVARIANT: the Lens calls this selector with `STATICCALL`; hook proxy upgrades MUST
    ///      preserve the signature. The function remains non-view because solc 0.8.35 rejects `view` +
    ///      `delegatecall` (Error 8961). The Lens call is statically enforced because the EIP-214 context
    ///      propagates through `delegatecall`. A direct ordinary CALL is read-only only while
    ///      `IDynamicFeeFacet.quote` remains read-only; `eth_call` alone is not static-call enforcement.
    ///
    ///      Return path: `delegatecall` the facet and return its raw returndata verbatim (assembly `return`,
    ///      same EIP-2535 / OZ-Proxy forwarding pattern as `_forwardCalldataAndReturn`). This skips the
    ///      `abi.decode` → re-`encode` round-trip that a typed `return` would force. The round-trip is
    ///      redundant because `PreparedSwapFee` is fully static (11 words), so the facet's ABI encoding and
    ///      solc's re-encoding are byte-identical. Safe here because this is a bare `external override` with
    ///      no post-body modifier (unlike `nonReentrant`, assembly `return` would skip). The
    ///      `_facetDelegatecall` + `abi.encodeCall` dispatch is kept (not swapped for
    ///      `_forwardCalldataAndReturn`) so a future signature drift between the 6-arg outer entry and the
    ///      single-struct inner entry fails at compile time instead of relying on layout coincidence.
    /// @param poolId Pool being quoted.
    /// @param params Swap parameters used for the quote.
    /// @param trader Trader address used by the dynamic fee context.
    /// @param preSqrtPriceX96 Pool price before the quoted swap.
    /// @param liquidity Current pool liquidity.
    /// @param protocolFeeOnInput Whether the protocol fee is charged from the input currency.
    /// @return Prepared fee data returned by the dynamic fee facet.
    function quoteSwapFeeWithContext(
        PoolId poolId,
        SwapParams calldata params,
        address trader,
        uint160 preSqrtPriceX96,
        uint128 liquidity,
        bool protocolFeeOnInput
    ) external override returns (IDynamicFeeFacet.PreparedSwapFee memory) {
        if (params.amountSpecified != 0) {
            SwapGuardMath.revertIfPublicSwapBlocked(_memeverseUniswapHookStorage.publicSwapResumeTime[poolId]);
            // A live pool with no cached LP shares cannot distribute LP fees. Match Lens and execution
            // before delegating so every non-zero quote entry rejects the same orphaned-liquidity state.
            if (_memeverseUniswapHookStorage.cachedLpTotalSupply[poolId] == 0) {
                SwapGuardMath.revertIfOrphanedLiquidity(liquidity);
            }
        }
        bytes memory ret = _facetDelegatecall(
            _memeverseUniswapHookStorage.dynamicFeeFacet,
            abi.encodeCall(
                IDynamicFeeFacet.quote,
                (IDynamicFeeFacet.PrepareSwapFeeParams({
                        poolId: poolId,
                        zeroForOne: params.zeroForOne,
                        amountSpecified: params.amountSpecified,
                        trader: trader,
                        preSqrtPriceX96: preSqrtPriceX96,
                        liquidity: liquidity,
                        protocolFeeOnInput: protocolFeeOnInput,
                        sqrtPriceLimitX96: params.sqrtPriceLimitX96
                    }))
            )
        );
        // Forward the facet's returndata verbatim; see the @dev note on why the decode+re-encode is skipped.
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
        }
    }

    /// @notice Reads the per-pool dynamic fee state held in this hook's storage namespace.
    /// @dev UPGRADE INVARIANT: the Lens calls this selector; hook proxy implementation upgrades MUST preserve
    ///      this signature. Reads this hook's own ERC7201 storage (`dynamicFeeState[poolId]`) directly — no
    ///      facet `delegatecall` — matching `addressBatchStateOf` and `pendingRebateOf`.
    /// @param poolId Pool being queried.
    /// @return state Current dynamic fee state.
    function dynamicFeeStateOf(PoolId poolId)
        external
        view
        override
        returns (IDynamicFeeFacet.DynamicFeeState memory state)
    {
        return _memeverseUniswapHookStorage.dynamicFeeState[poolId];
    }

    /// @notice Reads the per-trader, per-pool address batch state held in this hook's storage namespace.
    /// @dev Reads shared hook storage directly without a facet delegatecall, matching `pendingRebateOf` and
    ///      `dynamicFeeStateOf`.
    /// @param trader Trader address whose batch state is read.
    /// @param poolId Pool being queried.
    /// @return state Current address batch state.
    function addressBatchStateOf(address trader, PoolId poolId)
        external
        view
        override
        returns (IDynamicFeeFacet.AddressBatchState memory state)
    {
        return _memeverseUniswapHookStorage.addressBatchState[trader][poolId];
    }

    // -----------------------------------------------------------------
    // Referral rebate claim (Router-direct; custody lives on the hook proxy)
    // -----------------------------------------------------------------

    /// @notice Claims the caller's accrued referral rebate in `currency` and sends it to `recipient`.
    /// @dev Rebate custody lives on this hook proxy: `SwapFacet._collectProtocolFee` `take`s the rebate
    ///      into `address(this)` under delegatecall, and `pendingRebate` is recorded in this storage.
    ///      CEI: zero the pending balance before the external transfer so a malicious ERC20 recipient
    ///      cannot re-enter and double-claim. `nonReentrant` is belt-and-braces.
    /// @param currency Rebate currency to claim.
    /// @param recipient Recipient of the claimed rebate.
    /// @return amount Claimed rebate amount sent to `recipient`.
    function claimRebate(Currency currency, address recipient) external override nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroAddress();
        amount = _memeverseUniswapHookStorage.pendingRebate[msg.sender][currency];
        if (amount == 0) return 0;
        // Effect: clear before interaction.
        _memeverseUniswapHookStorage.pendingRebate[msg.sender][currency] = 0;
        currency.transferWithGuard(recipient, amount);
        emit ReferralRebateClaimed(msg.sender, recipient, currency, amount);
    }

    /// @inheritdoc IMemeverseUniswapHook
    function pendingRebateOf(address referrer, Currency currency) external view override returns (uint256) {
        return _memeverseUniswapHookStorage.pendingRebate[referrer][currency];
    }

    /// @inheritdoc IMemeverseUniswapHook
    function referrerRebateBps() external view override returns (uint256) {
        return _memeverseUniswapHookStorage.referrerRebateBps;
    }

    // -----------------------------------------------------------------
    // Admin setters
    // -----------------------------------------------------------------

    /// @notice Updates the treasury address.
    /// @dev Only callable by the owner. Zero address is rejected because protocol fees require a concrete recipient.
    /// The configured treasury is expected to be a passive receiver and must not use fee receipts to trigger
    /// reentrant swap or liquidity actions.
    /// @param treasury_ The new treasury address.
    function setTreasury(address treasury_) external override onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();

        address old = _memeverseUniswapHookStorage.treasury;
        _memeverseUniswapHookStorage.treasury = treasury_;
        emit TreasuryUpdated(old, treasury_);
    }

    /// @notice Sets the referral rebate rate (share of the total swap fee, in bps) on referral swaps.
    /// @dev Writes the hook-owned `referrerRebateBps` storage field read by `SwapFacet._collectProtocolFee`.
    ///      `bps` is the referrer's share of the *total* swap fee in bps (`rebate = totalFee * bps / 10_000`,
    ///      equivalently `protocolFee * bps / FeeMath.PROTOCOL_FEE_SHARE_BPS` since the protocol share is 35%;
    ///      default DEFAULT_REFERRAL_REBATE_BPS = 1000 → 10% of the total fee). Capped at
    ///      `FeeMath.PROTOCOL_FEE_SHARE_BPS` so rebate ≤ protocol fee and the treasury subtraction
    ///      (`protocolFee - rebate`) never underflows. ABI keeps the argument as `uint256` for caller
    ///      compatibility; the storage field stays `uint24` so the cast is applied at the write boundary.
    ///      The `uint24(bps)` cast is lossless because `bps <= PROTOCOL_FEE_SHARE_BPS`,
    ///      far below `type(uint24).max`.
    /// @param bps New rebate rate in basis points.
    function setReferrerRebateBps(uint256 bps) external override onlyOwner {
        if (bps > FeeMath.PROTOCOL_FEE_SHARE_BPS) revert RebateExceedsProtocolShare();
        uint256 old = _memeverseUniswapHookStorage.referrerRebateBps;
        // Emit the cast (storage-typed) value so the event reflects the persisted state, not the raw uint256 arg.
        uint24 newBps = uint24(bps);
        _memeverseUniswapHookStorage.referrerRebateBps = newBps;
        emit ReferrerRebateBpsUpdated(old, newBps);
    }

    /// @notice Registers or removes a protocol-fee token, which controls HOW the protocol fee is collected — not whether.
    /// @dev A registered currency is collected in when it is a pool leg: if a pool contains a protocol-fee token the fee
    ///      is taken in that token (input side preferred when both legs are registered); otherwise the fee is taken from
    ///      the input leg. Registering or removing never disables the fee — it only changes which leg it is charged on
    ///      (`protocolFeeOnInput = inputSupported || !outputSupported`).
    /// @param currency The currency whose protocol-fee-token flag is being updated.
    /// @param supported Whether `currency` should be collected in as the protocol fee when present in a pool leg.
    function setProtocolFeeCurrency(Currency currency, bool supported) external override onlyOwner {
        // 1-arg per-currency protocol-fee-token flag; the 2-arg pool-pair native-currency check is `SwapGuardMath.revertIfNativeCurrencyUnsupported`.
        if (currency.isAddressZero()) revert NativeCurrencyUnsupported();
        _memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[Currency.unwrap(currency)] = supported;
        emit ProtocolFeeCurrencySupportUpdated(currency, supported);
    }

    /// @notice Sets the router authorized to initialize hook-managed pools.
    /// @dev Pool initialization remains blocked unless this router writes a matching one-time authorization.
    /// @param initializer The authorized pool-initializer router.
    function setPoolInitializer(address initializer) external override onlyOwner {
        if (initializer == address(0)) revert ZeroAddress();

        address oldInitializer = _memeverseUniswapHookStorage.poolInitializer;
        _memeverseUniswapHookStorage.poolInitializer = initializer;
        emit PoolInitializerUpdated(oldInitializer, initializer);
    }

    /// @inheritdoc IMemeverseUniswapHook
    /// @dev Only callable by the owner. Existing LP clones are unaffected — they are independent contracts.
    function setLpTokenImplementation(address implementation_) external override onlyOwner {
        if (implementation_ == address(0)) revert ZeroAddress();
        if (implementation_.code.length == 0) revert LPTokenImplementationCodeNotReady(implementation_);

        address old = _memeverseUniswapHookStorage.lpTokenImplementation;
        _memeverseUniswapHookStorage.lpTokenImplementation = implementation_;
        emit LPTokenImplementationUpdated(old, implementation_);
    }

    /// @notice Authorizes the configured pool initializer to initialize one pool at one exact start price.
    /// @dev The authorization is consumed in `beforeInitialize` (via `swapFacet.beforeInitializeLogic`).
    /// @param key Pool key being authorized.
    /// @param startPriceX96 Expected initial pool price.
    function authorizePoolInitialization(PoolKey calldata key, uint160 startPriceX96)
        external
        override
        erc20Pair(key.currency0, key.currency1)
    {
        if (msg.sender != _memeverseUniswapHookStorage.poolInitializer) revert UnauthorizedPoolInitializer();
        PoolId poolId = key.toId();
        if (_memeverseUniswapHookStorage.poolInitializationAuth[poolId].active) {
            revert PoolInitializationAlreadyAuthorized();
        }
        _memeverseUniswapHookStorage.poolInitializationAuth[poolId] =
            PoolInitializationAuth({startPriceX96: startPriceX96, active: true});
        emit PoolInitializationAuthorized(poolId, startPriceX96);
    }

    /// @notice Sets the pool-level public-swap resume time written by the launcher.
    /// @dev Only the configured launcher may snapshot post-unlock protection windows onto pools.
    /// The hook resolves the pool identity locally from the token pair so launcher-side protection writes do not
    /// depend on mutable router helpers.
    /// @param tokenA One token in the protected pool.
    /// @param tokenB The other token in the protected pool.
    /// @param resumeTime New public-swap resume timestamp for the pool.
    function setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime) external override onlyLauncher {
        PoolId poolId = _poolIdForTokens(tokenA, tokenB);
        uint40 oldResumeTime = _memeverseUniswapHookStorage.publicSwapResumeTime[poolId];
        _memeverseUniswapHookStorage.publicSwapResumeTime[poolId] = resumeTime;
        emit PublicSwapResumeTimeUpdated(poolId, oldResumeTime, resumeTime);
    }

    /// @notice Sets the default launch fee configuration.
    /// @dev Only callable by the owner. Zero values reject with `ZeroValue`; out-of-range schedules
    ///      (a field exceeds BPS_BASE, or minFee > startFee) reject with `InvalidLaunchFeeConfig`.
    /// @param config The new default launch fee configuration.
    function setDefaultLaunchFeeConfig(IDynamicFeeFacet.LaunchFeeConfig calldata config) external override onlyOwner {
        if (config.startFeeBps == 0 || config.minFeeBps == 0 || config.decayDurationSeconds == 0) revert ZeroValue();
        if (
            config.startFeeBps > FeeMath.BPS_BASE || config.minFeeBps > FeeMath.BPS_BASE
                || config.minFeeBps > config.startFeeBps
        ) {
            revert InvalidLaunchFeeConfig();
        }

        IDynamicFeeFacet.LaunchFeeConfig memory oldConfig = _memeverseUniswapHookStorage.defaultLaunchFeeConfig;
        _memeverseUniswapHookStorage.defaultLaunchFeeConfig = config;
        emit DefaultLaunchFeeConfigUpdated(
            oldConfig.startFeeBps,
            oldConfig.minFeeBps,
            oldConfig.decayDurationSeconds,
            config.startFeeBps,
            config.minFeeBps,
            config.decayDurationSeconds
        );
    }

    /// @notice Replaces a diamond facet pointer.
    /// @dev Only callable by the owner. The new facet must have deployed code and share this hook's
    ///      PoolManager (each facet binds it via `ImmutableState`). The facet's `onlyViaRouter` guard uses
    ///      an immutable self-address (`__self`) baked at construction, so it is unaffected by facet swaps.
    /// @param role One of `SWAP_FACET_ROLE` / `DYNAMIC_FEE_FACET_ROLE` / `SETTLEMENT_FACET_ROLE`.
    /// @param facet New facet address.
    function setFacet(bytes32 role, address facet) external override onlyOwner {
        if (facet == address(0)) revert ZeroAddress();
        _requireFacetPoolManager(facet);
        address old;
        if (role == SWAP_FACET_ROLE) {
            old = _memeverseUniswapHookStorage.swapFacet;
            _memeverseUniswapHookStorage.swapFacet = facet;
        } else if (role == DYNAMIC_FEE_FACET_ROLE) {
            old = _memeverseUniswapHookStorage.dynamicFeeFacet;
            _memeverseUniswapHookStorage.dynamicFeeFacet = facet;
        } else if (role == SETTLEMENT_FACET_ROLE) {
            old = _memeverseUniswapHookStorage.settlementFacet;
            _memeverseUniswapHookStorage.settlementFacet = facet;
        } else {
            revert UnknownFacetRole(role);
        }
        emit FacetUpdated(role, old, facet);
    }
}
