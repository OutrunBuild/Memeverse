// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {LiquidityQuote} from "./libraries/LiquidityQuote.sol";
import {MemeverseTransientState} from "./libraries/MemeverseTransientState.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {UniswapLP} from "./tokens/UniswapLP.sol";
import {ReentrancyGuard} from "../common/access/ReentrancyGuard.sol";
import {IMemeverseDynamicFeeEngine} from "./interfaces/IMemeverseDynamicFeeEngine.sol";
import {IMemeversePreorderSettlementExecutor} from "./interfaces/IMemeversePreorderSettlementExecutor.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";

/// @notice Minimal admin surface required for hook-owned dynamic fee engine proxies.
/// @dev Kept local so the fee engine business interface does not expose upgrade ownership controls.
interface IMemeverseDynamicFeeEngineAdmin {
    /// @notice Returns the current engine proxy owner.
    /// @return The address authorized by the engine proxy to upgrade its implementation.
    function owner() external view returns (address);

    /// @notice Upgrades the current engine proxy implementation and optionally calls migration data.
    /// @param newImplementation New engine implementation address.
    /// @param data Optional initialization or migration calldata forwarded to the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/**
 * @title MemeverseUniswapHook
 * @notice A Uniswap v4 hook implementing:
 * - Full-range liquidity management (single position from MIN_TICK to MAX_TICK)
 * - A custom ERC20 LP token per pool
 * - Dynamic fees for adverse swaps (based on projected price impact, an EWMA volatility signal,
 *   and a linearly decayed short-term cumulative impact signal)
 * - Launch-time fee scheduling during the initial trading window after pool initialization
 *
 * @dev High-level flow:
 * - This contract is the Core engine for the Memeverse v4 integration.
 * - End-user and SDK-facing flows are expected to enter via `MemeverseSwapRouter`.
 * - The external Core APIs on this contract remain intentionally open for custom routers and advanced integrators.
 * - The configured `treasury` is expected to be a passive fee receiver.
 * - `beforeInitialize`: validates pool settings and deploys the pool-specific LP token.
 * - `beforeSwap`: computes public-swap fees and accrues fee accounting.
 * - `afterSwap`: updates ewVWAP, reference-price volatility state, and short-term impact state, and optionally takes protocol fees.
 * - `addLiquidityCore` / `removeLiquidityCore`: mint/burn LP tokens while adding/removing full-range liquidity.
 * - `claimFeesCore`: lets the calling LP claim its own accrued fees to a chosen recipient
 *   (tracked via per-share accounting).
 */
// solhint-disable-next-line gas-small-strings
contract MemeverseUniswapHook layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    IMemeverseUniswapHook,
    IUnlockCallback,
    ImmutableState,
    ReentrancyGuard,
    Initializable,
    OutrunOwnableUpgradeable
{
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;
    using SafeCast for int128;
    bytes internal constant ZERO_BYTES = bytes("");

    int24 internal constant MIN_TICK = -887200;
    int24 internal constant MAX_TICK = 887200;
    int24 internal constant TICK_SPACING = 200;
    uint256 internal constant FEE_GROWTH_Q128 = uint256(1) << 128;

    uint24 internal constant FEE_BASE_BPS = 100; // Minimum fee in bps.
    uint24 internal constant PREORDER_SETTLEMENT_FEE_BPS = 100; // Fixed fee for preorder settlement swaps.
    // Reuse the existing transient fee word so afterSwap can recover the fee side without another storage lookup.
    uint256 internal constant SWAP_CONTEXT_PROTOCOL_FEE_ON_INPUT_FLAG = 1 << 255;

    struct ModifyLiquidityCallbackData {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    struct PoolInitializationAuth {
        uint160 startPriceX96;
        bool active;
    }

    struct SwapFeeContext {
        Currency currencyIn;
        Currency currencyOut;
        bool protocolFeeOnInput;
        bool inputIsCurrency0;
    }

    /// @notice Storage layout for the MemeverseUniswapHook ERC7201 namespace.
    /// @custom:storage-location erc7201:outrun.storage.MemeverseUniswapHook
    struct MemeverseUniswapHookStorage {
        address treasury;
        address launcher;
        mapping(address => bool) supportedProtocolFeeCurrencies;
        mapping(PoolId => PoolInfo) poolInfo;
        mapping(PoolId => uint256) cachedLpTotalSupply;
        mapping(PoolId => uint40) poolLaunchTimestamp;
        mapping(PoolId => uint40) publicSwapResumeTime;
        mapping(PoolId => mapping(address => UserFeeState)) userFeeState;
        IMemeverseDynamicFeeEngine.LaunchFeeConfig defaultLaunchFeeConfig;
        address poolInitializer;
        mapping(PoolId => PoolInitializationAuth) poolInitializationAuth;
        IMemeverseDynamicFeeEngine dynamicFeeEngine;
        address lpTokenImplementation;
        IMemeversePreorderSettlementExecutor preorderSettlementExecutor;
    }

    MemeverseUniswapHookStorage private memeverseUniswapHookStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param _manager Uniswap v4 pool manager stored by `ImmutableState` as immutable implementation bytecode state.
    constructor(IPoolManager _manager) ImmutableState(_manager) {
        if (address(_manager) == address(0)) revert ZeroAddress();
        _disableInitializers();
    }

    /// @notice Initializes owner-controlled hook state for an upgradeable proxy.
    /// @dev The proxy address is the real Uniswap hook address, so hook permission flags are validated here.
    /// @param initialOwner Initial owner authorized to configure and upgrade the hook.
    /// @param treasury_ Treasury receiving protocol fees.
    /// @param dynamicFeeEngine_ Engine proxy address for dynamic fee state.
    /// @param lpTokenImplementation_ Clone implementation used for pool LP tokens.
    /// @param preorderSettlementExecutor_ Stateless helper for preorder settlement calculations.
    function initialize(
        address initialOwner,
        address treasury_,
        IMemeverseDynamicFeeEngine dynamicFeeEngine_,
        address lpTokenImplementation_,
        IMemeversePreorderSettlementExecutor preorderSettlementExecutor_
    ) external initializer {
        if (
            treasury_ == address(0) || address(dynamicFeeEngine_) == address(0) || lpTokenImplementation_ == address(0)
                || address(preorderSettlementExecutor_) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (lpTokenImplementation_.code.length == 0) revert LPTokenImplementationCodeNotReady(lpTokenImplementation_);
        _validatePreorderSettlementExecutor(preorderSettlementExecutor_);
        address enginePoolManager = address(dynamicFeeEngine_.poolManager());
        if (enginePoolManager != address(poolManager)) {
            revert DynamicFeeEnginePoolManagerMismatch(address(poolManager), enginePoolManager);
        }
        if (dynamicFeeEngine_.authorizedHook() != address(this)) {
            revert EngineNotAuthorizedCaller(address(dynamicFeeEngine_));
        }
        _requireEngineOwnedByHook(dynamicFeeEngine_);
        _validateProxyHookAddress();
        __OutrunOwnable_init(initialOwner);

        memeverseUniswapHookStorage.treasury = treasury_;
        memeverseUniswapHookStorage.dynamicFeeEngine = dynamicFeeEngine_;
        memeverseUniswapHookStorage.lpTokenImplementation = lpTokenImplementation_;
        memeverseUniswapHookStorage.preorderSettlementExecutor = preorderSettlementExecutor_;
        emit TreasuryUpdated(address(0), treasury_);
        emit LPTokenImplementationUpdated(address(0), lpTokenImplementation_);
        emit PreorderSettlementExecutorUpdated(address(0), address(preorderSettlementExecutor_));
        memeverseUniswapHookStorage.defaultLaunchFeeConfig = IMemeverseDynamicFeeEngine.LaunchFeeConfig({
            startFeeBps: 5000, minFeeBps: FEE_BASE_BPS, decayDurationSeconds: 900
        });
        emit DefaultLaunchFeeConfigUpdated(0, 0, 0, 5000, FEE_BASE_BPS, 900);
    }

    /// @inheritdoc IMemeverseUniswapHook
    function owner() public view override(OutrunOwnableUpgradeable, IMemeverseUniswapHook) returns (address) {
        return super.owner();
    }

    /// @dev Only test subclasses may override this to skip hook-address validation.
    /// Production deployments must not override — the proxy address must carry the correct flags.
    function _validateProxyHookAddress() internal view virtual {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Returns the dynamic fee engine bound to this hook.
    /// @return The engine contract used for dynamic fee quotes and realized swap state.
    function dynamicFeeEngine() external view override returns (IMemeverseDynamicFeeEngine) {
        return memeverseUniswapHookStorage.dynamicFeeEngine;
    }

    /// @notice Returns the LP token implementation cloned for each initialized pool.
    /// @return Implementation contract used by `Clones.clone` during pool initialization.
    function lpTokenImplementation() external view override returns (address) {
        return memeverseUniswapHookStorage.lpTokenImplementation;
    }

    /// @notice Returns the preorder settlement executor bound to this hook.
    /// @return The stateless helper contract used to assemble preorder settlement swap parameters.
    function preorderSettlementExecutor() external view override returns (IMemeversePreorderSettlementExecutor) {
        return memeverseUniswapHookStorage.preorderSettlementExecutor;
    }

    function _dynamicFeeEngine() internal view returns (IMemeverseDynamicFeeEngine) {
        return memeverseUniswapHookStorage.dynamicFeeEngine;
    }

    function _preorderSettlementExecutor() internal view returns (IMemeversePreorderSettlementExecutor) {
        return memeverseUniswapHookStorage.preorderSettlementExecutor;
    }

    function _boundDynamicFeeEngine() internal view returns (IMemeverseDynamicFeeEngine engine) {
        engine = memeverseUniswapHookStorage.dynamicFeeEngine;
        _requireEngineBoundToHook(engine);
    }

    /// @notice Replaces the hook's dynamic fee engine pointer.
    /// @dev The new engine must be an initialized engine proxy owned by this hook proxy, authorized for this hook,
    ///      and using the same PoolManager. Do not pass an implementation address here; use
    ///      `upgradeDynamicFeeEngineImplementation` to upgrade the currently bound engine proxy implementation.
    ///      WARNING: DynamicFeeState lives in the engine's own storage, keyed by this hook's address.
    ///      After replacement the new engine starts from zero state — EWVWAP, volatility accumulators,
    ///      short-impact, and address-batch state all reset. The first swap(s) will quote fees without
    ///      historical smoothing, effectively falling back to FEE_BASE_BPS + pifPpm until enough swaps
    ///      rebuild the state. No funds are at risk, but operators should expect a brief fee-model cold start.
    /// @param newEngine Initialized engine proxy owned by this hook proxy and authorized for this hook.
    function upgradeDynamicFeeEngine(IMemeverseDynamicFeeEngine newEngine) external onlyOwner {
        if (address(newEngine) == address(0)) revert ZeroAddress();
        address enginePoolManager = address(newEngine.poolManager());
        if (enginePoolManager != address(poolManager)) {
            revert DynamicFeeEnginePoolManagerMismatch(address(poolManager), enginePoolManager);
        }
        // Reject engines whose authorized hook is not this contract — all subsequent swap and settlement
        // calls would revert with UnauthorizedCaller inside the engine.
        if (newEngine.authorizedHook() != address(this)) revert EngineNotAuthorizedCaller(address(newEngine));
        _requireEngineOwnedByHook(newEngine);

        address oldEngine = address(memeverseUniswapHookStorage.dynamicFeeEngine);
        memeverseUniswapHookStorage.dynamicFeeEngine = newEngine;
        emit DynamicFeeEngineUpdated(oldEngine, address(newEngine));
    }

    /// @notice Upgrades the implementation behind the currently bound dynamic fee engine proxy.
    /// @dev Engine ownership must stay on this hook so governance has one control path: hook owner -> hook -> engine.
    ///      The engine's own UUPS authorization validates the new implementation and preserves its storage.
    ///      When upgrading a deployed engine to an implementation that introduces the referral rebate,
    ///      `referrerRebateBps` keeps its prior value (0 on an engine initialized under an older
    ///      implementation), so rebates stay disabled until the owner sets the rate. Pass
    ///      `abi.encodeCall(IMemeverseDynamicFeeEngine.setReferrerRebateBps, (1000))` as `data` (or call
    ///      `hook.setReferrerRebateBps(1000)` after the upgrade) to activate the default 10% rate.
    /// @param newImplementation New engine implementation address.
    /// @param data Optional migration calldata forwarded to the engine proxy.
    function upgradeDynamicFeeEngineImplementation(address newImplementation, bytes calldata data) external onlyOwner {
        IMemeverseDynamicFeeEngine currentEngine = _boundDynamicFeeEngine();
        IMemeverseDynamicFeeEngineAdmin(address(currentEngine)).upgradeToAndCall(newImplementation, data);
        _requireEngineBoundToHook(currentEngine);
    }

    function _requireEngineOwnedByHook(IMemeverseDynamicFeeEngine engine) internal view {
        address actualOwner = IMemeverseDynamicFeeEngineAdmin(address(engine)).owner();
        // The hook must own the engine proxy, otherwise engine upgrades can bypass hook ownership transfer.
        if (actualOwner != address(this)) {
            revert DynamicFeeEngineOwnerMismatch(address(engine), address(this), actualOwner);
        }
    }

    function _requireEngineBoundToHook(IMemeverseDynamicFeeEngine engine) internal view {
        _requireEngineOwnedByHook(engine);
        if (engine.authorizedHook() != address(this)) revert EngineNotAuthorizedCaller(address(engine));
        address enginePoolManager = address(engine.poolManager());
        if (enginePoolManager != address(poolManager)) {
            revert DynamicFeeEnginePoolManagerMismatch(address(poolManager), enginePoolManager);
        }
    }

    function _validatePreorderSettlementExecutor(IMemeversePreorderSettlementExecutor executor) internal view {
        address executorAddress = address(executor);
        if (executorAddress.code.length == 0) revert PreorderSettlementExecutorCodeNotReady(executorAddress);
        // The executor is immutable-bound to a single hook; reject a misconfigured executor bound to
        // a different hook before the owner can wire it in (it would reject every settlement swap).
        address hookAddr = executor.HOOK();
        if (hookAddr != address(this)) {
            revert PreorderSettlementExecutorHookMismatch(executorAddress, address(this), hookAddr);
        }
    }

    function treasury() external view returns (address) {
        return memeverseUniswapHookStorage.treasury;
    }

    function launcher() external view override returns (address) {
        return memeverseUniswapHookStorage.launcher;
    }

    function supportedProtocolFeeCurrencies(address currency) external view returns (bool) {
        return memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[currency];
    }

    function poolInfo(PoolId poolId)
        external
        view
        override
        returns (address liquidityToken, uint256 fee0PerShare, uint256 fee1PerShare)
    {
        PoolInfo storage info = memeverseUniswapHookStorage.poolInfo[poolId];
        return (info.liquidityToken, info.fee0PerShare, info.fee1PerShare);
    }

    function cachedLpTotalSupply(PoolId poolId) external view override returns (uint256 supply) {
        return memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
    }

    function poolLaunchTimestamp(PoolId poolId) external view override returns (uint40) {
        return memeverseUniswapHookStorage.poolLaunchTimestamp[poolId];
    }

    function publicSwapResumeTime(PoolId poolId) external view override returns (uint40) {
        return memeverseUniswapHookStorage.publicSwapResumeTime[poolId];
    }

    function userFeeState(PoolId poolId, address user)
        external
        view
        returns (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1)
    {
        UserFeeState storage state = memeverseUniswapHookStorage.userFeeState[poolId][user];
        return (state.fee0Offset, state.fee1Offset, state.pendingFee0, state.pendingFee1);
    }

    function defaultLaunchFeeConfig()
        external
        view
        override
        returns (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds)
    {
        IMemeverseDynamicFeeEngine.LaunchFeeConfig storage config = memeverseUniswapHookStorage.defaultLaunchFeeConfig;
        return (config.startFeeBps, config.minFeeBps, config.decayDurationSeconds);
    }

    /// @notice Quotes only the dynamic-fee engine portion of a public swap.
    /// @dev Keeps lens quotes authorized without giving the lens direct engine authorization.
    /// @param poolId Pool being quoted.
    /// @param params Swap parameters used for the quote.
    /// @param trader Trader address used by the fee engine context.
    /// @param preSqrtPriceX96 Pool price before the quoted swap.
    /// @param liquidity Current pool liquidity.
    /// @param protocolFeeOnInput Whether the protocol fee is charged from the input currency.
    /// @return quote Prepared fee data returned by the dynamic fee engine.
    function quoteSwapFeeWithContext(
        PoolId poolId,
        SwapParams calldata params,
        address trader,
        uint160 preSqrtPriceX96,
        uint128 liquidity,
        bool protocolFeeOnInput
    ) external view override returns (IMemeverseDynamicFeeEngine.PreparedSwapFee memory quote) {
        IMemeverseDynamicFeeEngine.LaunchFeeConfig memory launchConfig =
        memeverseUniswapHookStorage.defaultLaunchFeeConfig;

        // The hook is the engine-authorized caller; the lens supplies PoolManager-derived read-only context.
        return _dynamicFeeEngine()
            .quoteSwapWithContext(
                address(this),
                IMemeverseDynamicFeeEngine.QuoteSwapContext({
                poolId: poolId,
                swapParams: params,
                trader: trader,
                preSqrtPriceX96: preSqrtPriceX96,
                liquidity: liquidity,
                protocolFeeOnInput: protocolFeeOnInput,
                launchFeeConfig: launchConfig,
                launchTimestamp: memeverseUniswapHookStorage.poolLaunchTimestamp[poolId]
            })
            );
    }

    function poolInitializer() external view override returns (address) {
        return memeverseUniswapHookStorage.poolInitializer;
    }

    modifier onlyLauncher() {
        _checkLauncher();
        _;
    }

    modifier erc20Pair(Currency currency0, Currency currency1) {
        _revertIfNativeCurrencyUnsupported(currency0, currency1);
        _;
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

    /// @notice PoolManager callback before a hook-managed pool is initialized.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key being initialized.
    /// @param sqrtPriceX96 Initial pool price.
    /// @return The `beforeInitialize` selector expected by PoolManager.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        erc20Pair(key.currency0, key.currency1)
        returns (bytes4)
    {
        if (key.tickSpacing != TICK_SPACING) revert TickSpacingNotDefault();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert FeeMustBeDynamic();

        PoolId poolId = key.toId();

        if (sender != memeverseUniswapHookStorage.poolInitializer) revert UnauthorizedPoolInitializer();

        PoolInitializationAuth memory auth = memeverseUniswapHookStorage.poolInitializationAuth[poolId];
        if (!auth.active) revert UnauthorizedPoolInitialization();
        if (auth.startPriceX96 != sqrtPriceX96) revert InvalidInitialPrice();
        delete memeverseUniswapHookStorage.poolInitializationAuth[poolId];

        address liquidityToken = Clones.clone(memeverseUniswapHookStorage.lpTokenImplementation);
        // Initialize immediately so the clone cannot be claimed and LP mint/burn authority stays with this hook.
        UniswapLP(liquidityToken).initialize("Memeverse LP", "MLP", 18, poolId, address(this));

        memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken = liquidityToken;
        memeverseUniswapHookStorage.poolLaunchTimestamp[poolId] = uint40(block.timestamp);

        emit PoolInitialized(poolId, liquidityToken, key.currency0, key.currency1);

        return IHooks.beforeInitialize.selector;
    }

    /// @notice PoolManager callback before a hook-managed swap.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key being swapped.
    /// @param params Swap parameters.
    /// @param hookData Extra hook data forwarded by PoolManager.
    /// @return The `beforeSwap` selector expected by PoolManager.
    /// @return delta Hook delta used to charge swap-side fees.
    /// @return lpFeeOverride Dynamic LP fee override; zero keeps PoolManager default behavior.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    /// @dev Computes the dynamic fee, collects any exact-input input-side fees, and stores swap context for `afterSwap`.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        erc20Pair(key.currency0, key.currency1)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Preorder settlement delegates the pool swap to the dedicated executor contract, so the swap callback
        // `sender` is the executor address — detected via the transient marker set in `executePreorderSettlement`.
        // Skip the public-swap fee path (including referrer decode) for those self-initiated swaps; mirror the
        // _afterSwap ordering where the preorder early return precedes `_decodeReferrer`.
        if (MemeverseTransientState.isExpectedPreorderSettlementExecutor(sender)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        PoolId poolId = key.toId();
        address referrer = _decodeReferrer(hookData);
        _revertIfPublicSwapBlocked(poolId);
        uint256 effectiveSupply = _activeLpSupplyForSwap(poolId, params.amountSpecified);

        uint256 absSpecified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        SwapFeeContext memory ctx = _resolveSwapFeeContext(key, params.zeroForOne);

        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        IMemeverseDynamicFeeEngine.LaunchFeeConfig memory launchConfig =
        memeverseUniswapHookStorage.defaultLaunchFeeConfig;
        IMemeverseDynamicFeeEngine.PreparedSwapFee memory quote = _dynamicFeeEngine()
            .prepareSwapFee(
                IMemeverseDynamicFeeEngine.PrepareSwapFeeParams({
                poolId: poolId,
                swapParams: params,
                // solhint-disable-next-line avoid-tx-origin
                trader: tx.origin,
                preSqrtPriceX96: preSqrtPriceX96,
                liquidity: liquidity,
                protocolFeeOnInput: ctx.protocolFeeOnInput,
                launchFeeConfig: launchConfig,
                launchTimestamp: memeverseUniswapHookStorage.poolLaunchTimestamp[poolId]
            })
            );
        uint256 dynamicFeeBps = quote.feeBps;
        uint256 estimatedGrossOutputAmount = quote.estimatedGrossOutputAmount;

        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(dynamicFeeBps);

        uint256 lpFeeInputAmount = 0;
        uint256 protocolFeeInputAmount = 0;
        if (params.amountSpecified < 0) {
            // Exact-input swaps can charge input-side fees immediately because the user's budget is already known up front.
            // Fee amounts below are mirrored in _afterSwap exact-input branch — keep in sync.
            lpFeeInputAmount = FeeMath.feeOnAmount(absSpecified, lpFeeBps);
            if (ctx.protocolFeeOnInput) {
                protocolFeeInputAmount = FeeMath.feeOnAmount(absSpecified, protocolFeeBps);
            }
        }

        uint256 swapContextDepth = MemeverseTransientState.pushSwapContext(
            poolId, _encodeSwapContextFee(dynamicFeeBps, ctx.protocolFeeOnInput), preSqrtPriceX96
        );
        uint256 exactOutputProtocolFeeOutputAmount = 0;
        if (params.amountSpecified > 0 && !ctx.protocolFeeOnInput) {
            // This exact rounded amount was reserved in beforeSwap, so afterSwap must not skim any overfill surplus.
            exactOutputProtocolFeeOutputAmount = estimatedGrossOutputAmount - absSpecified;
            MemeverseTransientState.storeExactOutputProtocolFee(
                poolId, swapContextDepth, exactOutputProtocolFeeOutputAmount
            );
        }

        if (lpFeeInputAmount > 0) {
            _collectLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFeeInputAmount, effectiveSupply);
        }
        if (protocolFeeInputAmount > 0) {
            _collectProtocolFee(poolId, ctx.currencyIn, protocolFeeInputAmount, referrer);
        }

        if (params.amountSpecified > 0 && !ctx.protocolFeeOnInput) {
            // Exact-output with output-side protocol fees asks the pool for the gross output now; the hook keeps the fee delta later.
            return (
                IHooks.beforeSwap.selector,
                toBeforeSwapDelta(exactOutputProtocolFeeOutputAmount.toInt128(), int128(0)),
                0
            );
        }

        if (params.amountSpecified > 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 specifiedDeltaInput = (lpFeeInputAmount + protocolFeeInputAmount).toInt128();
        if (specifiedDeltaInput == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDeltaInput, int128(0)), 0);
    }

    function _checkLauncher() private view {
        if (msg.sender != memeverseUniswapHookStorage.launcher) revert Unauthorized();
    }

    function _revertIfPublicSwapBlocked(PoolId poolId) internal view {
        uint40 resumeTime = memeverseUniswapHookStorage.publicSwapResumeTime[poolId];
        if (resumeTime != 0 && block.timestamp < resumeTime) revert PublicSwapDisabled();
    }

    /// @notice PoolManager callback after a hook-managed swap.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key being swapped.
    /// @param params Swap parameters.
    /// @param delta Pool balance delta from the swap.
    /// @param hookData Extra hook data forwarded by PoolManager.
    /// @return The `afterSwap` selector expected by PoolManager.
    /// @return unspecifiedDelta Hook delta used to settle output-side or exact-output fees.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4, int128) {
        if (MemeverseTransientState.isExpectedPreorderSettlementExecutor(sender)) {
            return (IHooks.afterSwap.selector, 0);
        }
        address referrer = _decodeReferrer(hookData);

        PoolId poolId = key.toId();
        SwapFeeContext memory ctx = SwapFeeContext({
            currencyIn: params.zeroForOne ? key.currency0 : key.currency1,
            currencyOut: params.zeroForOne ? key.currency1 : key.currency0,
            protocolFeeOnInput: false,
            inputIsCurrency0: params.zeroForOne
        });
        (uint256 encodedFeeBps, uint160 preSqrtPriceX96, uint256 swapContextDepth) =
            MemeverseTransientState.consumeCurrentSwapContext(poolId);
        uint256 feeBps = _decodeSwapContextFee(encodedFeeBps);
        ctx.protocolFeeOnInput = _swapContextProtocolFeeOnInput(encodedFeeBps);
        (uint160 postSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        _dynamicFeeEngine()
            .updateAfterSwap(
                IMemeverseDynamicFeeEngine.UpdateAfterSwapParams({
                poolId: poolId,
                delta: delta,
                // solhint-disable-next-line avoid-tx-origin
                trader: tx.origin,
                preSqrtPriceX96: preSqrtPriceX96,
                postSqrtPriceX96: postSqrtPriceX96
            })
            );

        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(feeBps);

        if (params.amountSpecified < 0) {
            uint256 absSpecified = uint256(-params.amountSpecified);
            // These must match the _beforeSwap computation for the partial-fill guard to work.
            uint256 lpFeeInputAmount = FeeMath.feeOnAmount(absSpecified, lpFeeBps);
            uint256 protocolFeeInputAmount =
                ctx.protocolFeeOnInput ? FeeMath.feeOnAmount(absSpecified, protocolFeeBps) : 0;
            uint256 expectedPoolInput = absSpecified - lpFeeInputAmount - protocolFeeInputAmount;
            uint256 actualPoolInput = _actualInputAmount(delta, params.zeroForOne);
            if (actualPoolInput != expectedPoolInput) revert ExactInputPartialFill();

            if (!ctx.protocolFeeOnInput) {
                uint256 actualOutputAbs = _actualOutputAmount(delta, params.zeroForOne);
                uint256 exactInputProtocolFeeOutputAmount = FeeMath.feeOnAmount(actualOutputAbs, protocolFeeBps);
                if (exactInputProtocolFeeOutputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyOut, exactInputProtocolFeeOutputAmount, referrer);
                }
                return (IHooks.afterSwap.selector, int128(int256(exactInputProtocolFeeOutputAmount)));
            }

            return (IHooks.afterSwap.selector, 0);
        }

        if (params.amountSpecified > 0) {
            // Exact-output fees settle against the actual fill, so only `afterSwap` knows the final input amount to charge.
            uint256 requestedOutputAbs = uint256(params.amountSpecified);
            uint256 actualOutputAbs = _actualOutputAmount(delta, params.zeroForOne);
            uint256 minimumOutputAbs = requestedOutputAbs;
            uint256 reservedProtocolFeeOutputAmount = 0;
            if (!ctx.protocolFeeOnInput) {
                reservedProtocolFeeOutputAmount =
                    MemeverseTransientState.consumeExactOutputProtocolFee(poolId, swapContextDepth);
                // Match the exact beforeSwap reservation so overfills are delivered to the recipient instead of skimmed.
                minimumOutputAbs += reservedProtocolFeeOutputAmount;
            }
            if (actualOutputAbs < minimumOutputAbs) revert ExactOutputPartialFill();

            uint256 actualInputAbs = _actualInputAmount(delta, params.zeroForOne);

            uint256 exactOutputLpFeeInputAmount = FeeMath.feeOnAmount(actualInputAbs, lpFeeBps);
            if (exactOutputLpFeeInputAmount > 0) {
                uint256 effectiveSupply = memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
                _collectLpFee(
                    poolId, ctx.currencyIn, ctx.inputIsCurrency0, exactOutputLpFeeInputAmount, effectiveSupply
                );
            }

            uint256 unspecifiedDelta;
            if (ctx.protocolFeeOnInput) {
                uint256 exactOutputProtocolFeeInputAmount = FeeMath.feeOnAmount(actualInputAbs, protocolFeeBps);
                if (exactOutputProtocolFeeInputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyIn, exactOutputProtocolFeeInputAmount, referrer);
                }
                unspecifiedDelta = exactOutputLpFeeInputAmount + exactOutputProtocolFeeInputAmount;
            } else {
                // Output-side protocol fee was grossed up in `beforeSwap`; here the hook withholds the realized output fee from the taker.
                if (reservedProtocolFeeOutputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyOut, reservedProtocolFeeOutputAmount, referrer);
                }
                unspecifiedDelta = exactOutputLpFeeInputAmount;
            }

            return (IHooks.afterSwap.selector, int128(int256(unspecifiedDelta)));
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice PoolManager callback before liquidity is added to a hook-managed pool.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key receiving liquidity.
    /// @param params Liquidity modification parameters.
    /// @param hookData Extra hook data forwarded by PoolManager.
    /// @return The `beforeAddLiquidity` selector expected by PoolManager.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view onlyPoolManager returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    /// @dev Restricts add-liquidity modifications to calls coming from this hook itself.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        returns (bytes4)
    {
        if (sender != address(this)) revert SenderMustBeHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Add full-range liquidity while the caller funds the assets and receives LP shares at `params.to`.
    /// @dev This is the low-level liquidity entrypoint intended for routers and other on-chain integrators.
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
        PoolKey memory key = _poolKey(params.currency0, params.currency1);
        PoolId poolId = key.toId();

        PoolInfo storage pool = memeverseUniswapHookStorage.poolInfo[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (pool.liquidityToken == address(0) || sqrtPriceX96 == 0) revert PoolNotInitialized();

        updateUserSnapshot(poolId, params.to);

        (liquidity,,) = LiquidityQuote.quote(sqrtPriceX96, params.amount0Desired, params.amount1Desired);

        addedDelta = _modifyLiquidity(
            payer,
            key,
            ModifyLiquidityParams({
                tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: liquidity.toInt256(), salt: 0
            })
        );

        UniswapLP(pool.liquidityToken).mint(params.to, liquidity);
        memeverseUniswapHookStorage.cachedLpTotalSupply[poolId] += liquidity;

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
        PoolKey memory key = _poolKey(params.currency0, params.currency1);
        PoolId poolId = key.toId();
        if (poolManager.getLiquidity(poolId) == 0) revert PoolNotInitialized();

        updateUserSnapshot(poolId, msg.sender);

        UniswapLP lp = UniswapLP(memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken);
        lp.burn(msg.sender, params.liquidity);
        memeverseUniswapHookStorage.cachedLpTotalSupply[poolId] -= params.liquidity;

        delta = _modifyLiquidity(
            params.recipient,
            key,
            ModifyLiquidityParams({
                tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: -(params.liquidity.toInt256()), salt: 0
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
    /// @dev Callable only by the configured launcher. Uses fixed 1% settlement economics and does not rely on
    /// `beforeSwap/afterSwap` marker branches.
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
        PoolId poolId = params.key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken == address(0) || sqrtPriceX96 == 0) {
            revert PoolNotInitialized();
        }
        if (params.params.amountSpecified >= 0) revert ZeroValue();

        _revertIfNoActiveLiquidityShares(poolId, params.params.amountSpecified);

        // Settlement executes in three phases:
        // 1) Charge fees up front — LP fee pulled from the launcher and credited to LPs, plus the
        //    input-side protocol fee to the treasury when applicable. The remainder (netInputAmount)
        //    is what actually enters the pool.
        // 2) Fund and delegate the swap — move netInput to the executor, set the transient marker so
        //    the executor's own swap skips the public-swap fee path in _beforeSwap/_afterSwap, call
        //    executor.execute() to swap inside a PoolManager unlock, then clear the marker.
        // 3) Reconcile — refresh the fee engine with the realized delta and re-derive the output-side
        //    protocol fee from the hook's own fee rate; revert if it differs from the executor's report.

        uint256 grossInputAmount = uint256(-params.params.amountSpecified);
        if (grossInputAmount == 0) revert ZeroValue();
        SwapFeeContext memory feeContext = _resolveSwapFeeContext(params.key, params.params.zeroForOne);
        _dynamicFeeEngine()
            .refreshBeforeSwap(
                IMemeverseDynamicFeeEngine.RefreshBeforeSwapParams({poolId: poolId, preSqrtPriceX96: sqrtPriceX96})
            );

        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(PREORDER_SETTLEMENT_FEE_BPS);
        uint256 lpFeeInputAmount = FeeMath.feeOnAmount(grossInputAmount, lpFeeBps);
        uint256 protocolFeeInputAmount =
            feeContext.protocolFeeOnInput ? FeeMath.feeOnAmount(grossInputAmount, protocolFeeBps) : 0;
        uint256 netInputAmount = grossInputAmount - lpFeeInputAmount - protocolFeeInputAmount;
        if (netInputAmount == 0) revert ZeroValue();

        _collectPreorderSettlementInputFees(msg.sender, poolId, feeContext, lpFeeInputAmount, protocolFeeInputAmount);

        SwapParams memory settlementParams = params.params;
        settlementParams.amountSpecified = -int256(netInputAmount);
        IMemeversePreorderSettlementExecutor executor = _preorderSettlementExecutor();
        if (!IERC20Minimal(Currency.unwrap(feeContext.currencyIn))
                .transferFrom(msg.sender, address(executor), netInputAmount)) {
            revert ERC20TransferFailed();
        }
        // Bypass intentionally stays set for the whole executor.execute() window, including any nested pool
        // callbacks (e.g. a malicious ERC20 transfer reentering during the executor's settle/take). The fee-neutral
        // branch in _beforeSwap/_afterSwap only fires when `sender == executor`, and the executor issues exactly one
        // swap with hook-supplied params — a reentrant swap from a token callback has `sender == attacker`, so it
        // misses the branch and pays normal fees. Do not loosen that sender check.
        MemeverseTransientState.setPreorderSettlementExecutor(address(executor));
        IMemeversePreorderSettlementExecutor.ExecuteResult memory result = executor.execute(
            IMemeversePreorderSettlementExecutor.ExecuteParams({
                poolManager: poolManager,
                recipient: params.recipient,
                treasury: memeverseUniswapHookStorage.treasury,
                key: params.key,
                swapParams: settlementParams,
                protocolFeeOnInput: feeContext.protocolFeeOnInput,
                protocolFeeOutputBps: feeContext.protocolFeeOnInput ? 0 : protocolFeeBps
            })
        );
        MemeverseTransientState.setPreorderSettlementExecutor(address(0));

        _dynamicFeeEngine()
            .updateAfterSwap(
                IMemeverseDynamicFeeEngine.UpdateAfterSwapParams({
                poolId: poolId,
                delta: result.swapDelta,
                trader: msg.sender,
                preSqrtPriceX96: result.preSwapSqrtPriceX96,
                postSqrtPriceX96: result.postSwapSqrtPriceX96
            })
            );
        // Output-side protocol fee is derived by the hook from its own fee rate and the realized swap output,
        // not trusted from the executor's self-reported amount. `swapDelta` mirrors the executor's
        // poolManager.swap() return, so this is a self-consistency check on the self-report — it catches an
        // inconsistent report, not a forged struct (a forged return struct is bounded by the onlyOwner
        // executor-replacement trust model). Input-side charging resolves to 0 here.
        uint256 expectedProtocolFeeOutputAmount = feeContext.protocolFeeOnInput
            ? 0
            : FeeMath.feeOnAmount(_actualOutputAmount(result.swapDelta, params.params.zeroForOne), protocolFeeBps);
        if (result.protocolFeeOutputAmount != expectedProtocolFeeOutputAmount) {
            revert PreorderSettlementFeeMismatch();
        }
        if (expectedProtocolFeeOutputAmount > 0) {
            Currency outputCurrency = params.params.zeroForOne ? params.key.currency1 : params.key.currency0;
            emit ProtocolFeeCollected(
                poolId,
                outputCurrency,
                memeverseUniswapHookStorage.treasury,
                expectedProtocolFeeOutputAmount,
                block.number
            );
        }

        delta = result.adjustedDelta;
        if (_actualInputAmount(delta, params.params.zeroForOne) != netInputAmount) revert ExactInputPartialFill();
    }

    function _modifyLiquidity(address sender, PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.unlock(abi.encode(ModifyLiquidityCallbackData({sender: sender, key: key, params: params}))),
            (BalanceDelta)
        );
    }

    /// @notice Callback invoked by the PoolManager during `unlock` flow.
    /// @dev Only callable by the PoolManager.
    /// @param rawData Encoded liquidity callback payload produced by `_modifyLiquidity`.
    /// @return result Encoded `BalanceDelta` returned back to the pool manager.
    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        ModifyLiquidityCallbackData memory data = abi.decode(rawData, (ModifyLiquidityCallbackData));
        BalanceDelta delta;
        (delta,) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
        if (data.params.liquidityDelta < 0) {
            _takeDeltas(data.sender, data.key, delta);
        } else {
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    /// @dev Transfers `amount` of `currency` to `to`.
    function _transferCurrency(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20Minimal(Currency.unwrap(currency)).transfer(to, amount)) revert ERC20TransferFailed();
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        key.currency0.settle(poolManager, sender, uint256((-delta.amount0()).toUint128()), false);
        key.currency1.settle(poolManager, sender, uint256((-delta.amount1()).toUint128()), false);
    }

    function _takeDeltas(address recipient, PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, recipient, uint256(delta.amount0().toUint128()));
        poolManager.take(key.currency1, recipient, uint256(delta.amount1().toUint128()));
    }

    function _claimFees(PoolKey memory key, address feeOwner, address recipient)
        internal
        erc20Pair(key.currency0, key.currency1)
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        PoolId poolId = key.toId();

        if (memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken == address(0)) revert PoolNotInitialized();

        updateUserSnapshot(poolId, feeOwner);

        UserFeeState storage state = memeverseUniswapHookStorage.userFeeState[poolId][feeOwner];
        fee0Amount = state.pendingFee0;
        fee1Amount = state.pendingFee1;

        if (fee0Amount > 0) {
            state.pendingFee0 = 0;
            _transferCurrency(key.currency0, recipient, fee0Amount);
        }
        if (fee1Amount > 0) {
            state.pendingFee1 = 0;
            _transferCurrency(key.currency1, recipient, fee1Amount);
        }

        if (fee0Amount > 0 || fee1Amount > 0) {
            emit FeesClaimed(poolId, feeOwner, key.currency0, key.currency1, fee0Amount, fee1Amount);
        }
    }

    function _poolKey(Currency currency0, Currency currency1)
        internal
        view
        erc20Pair(currency0, currency1)
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function _poolIdForTokens(address tokenA, address tokenB) internal view returns (PoolId poolId) {
        (Currency currency0, Currency currency1) = tokenA < tokenB
            ? (Currency.wrap(tokenA), Currency.wrap(tokenB))
            : (Currency.wrap(tokenB), Currency.wrap(tokenA));
        poolId = _poolKey(currency0, currency1).toId();
    }

    function _resolveSwapFeeContext(PoolKey memory key, bool zeroForOne)
        internal
        view
        returns (SwapFeeContext memory ctx)
    {
        ctx.currencyIn = zeroForOne ? key.currency0 : key.currency1;
        ctx.currencyOut = zeroForOne ? key.currency1 : key.currency0;
        if (_isProtocolFeeCurrencySupported(ctx.currencyIn)) {
            ctx.protocolFeeOnInput = true;
        } else if (_isProtocolFeeCurrencySupported(ctx.currencyOut)) {
            ctx.protocolFeeOnInput = false;
        } else {
            revert CurrencyNotSupported();
        }
        ctx.inputIsCurrency0 = zeroForOne;
    }

    function _encodeSwapContextFee(uint256 feeBps, bool protocolFeeOnInput) internal pure returns (uint256 encodedFee) {
        encodedFee = feeBps;
        if (protocolFeeOnInput) encodedFee |= SWAP_CONTEXT_PROTOCOL_FEE_ON_INPUT_FLAG;
    }

    function _decodeSwapContextFee(uint256 encodedFeeBps) internal pure returns (uint256 feeBps) {
        return encodedFeeBps & ~SWAP_CONTEXT_PROTOCOL_FEE_ON_INPUT_FLAG;
    }

    function _swapContextProtocolFeeOnInput(uint256 encodedFeeBps) internal pure returns (bool) {
        return encodedFeeBps & SWAP_CONTEXT_PROTOCOL_FEE_ON_INPUT_FLAG != 0;
    }

    /// @dev Referrer is the first 20 bytes of `hookData`. Empty or short payload means no referrer.
    function _decodeReferrer(bytes calldata hookData) internal pure returns (address referrer) {
        if (hookData.length < 20) return address(0);
        return address(bytes20(hookData[:20]));
    }

    function _collectProtocolFee(PoolId poolId, Currency feeCurrency, uint256 protocolFeeAmount, address referrer)
        internal
    {
        if (protocolFeeAmount == 0) return;
        // rebate = protocolFee × rebateBps / PROTOCOL_FEE_SHARE_BPS
        //   = (totalFee × 35%) × rebateBps / 35% = totalFee × rebateBps / BPS_BASE
        // rebateBps is the rebate share of the *total fee* in bps (default 1000 = 10%, max 3500).
        uint256 rebate = 0;
        if (referrer != address(0)) {
            uint256 rebateBps = _dynamicFeeEngine().referrerRebateBps();
            if (rebateBps != 0) {
                rebate = FullMath.mulDiv(protocolFeeAmount, rebateBps, FeeMath.PROTOCOL_FEE_SHARE_BPS);
            }
        }
        uint256 toTreasury = protocolFeeAmount - rebate;

        // Always emit ProtocolFeeCollected for indexer continuity (toTreasury may be 0
        // when rebateBps == PROTOCOL_FEE_SHARE_BPS). _takeToTreasury with amount 0 is a no-op take.
        address treasury_ = _takeToTreasury(feeCurrency, toTreasury);
        emit ProtocolFeeCollected(poolId, feeCurrency, treasury_, toTreasury, block.number);
        if (rebate > 0) {
            // Hook takes the rebate to the engine's address (delta recorded on the hook, offset by its
            // `beforeSwap` specifiedDelta credit, which already reserves the full protocol fee). v4 records
            // `take` deltas on msg.sender, so an engine-internal take would leave an unsettled -rebate on the
            // engine and revert the unlock with CurrencyNotSettled. The engine then ledgers the rebate purely
            // and holds the token as claim custody, preserving engine-balance >= sum(pending) solvency.
            IMemeverseDynamicFeeEngine engine = _dynamicFeeEngine();
            poolManager.take(feeCurrency, address(engine), rebate);
            engine.accrueRebate(referrer, feeCurrency, rebate);
        }
    }

    function _collectLpFee(
        PoolId poolId,
        Currency feeCurrency,
        bool feeCurrencyIsCurrency0,
        uint256 lpFeeAmount,
        uint256 effectiveSupply
    ) internal {
        if (lpFeeAmount == 0) return;
        if (effectiveSupply == 0) return;

        poolManager.take(feeCurrency, address(this), lpFeeAmount);
        _creditLpFee(poolId, feeCurrency, feeCurrencyIsCurrency0, lpFeeAmount, effectiveSupply);
    }

    function _collectPreorderSettlementInputFees(
        address payer,
        PoolId poolId,
        SwapFeeContext memory ctx,
        uint256 lpFeeInputAmount,
        uint256 protocolFeeInputAmount
    ) internal {
        if (lpFeeInputAmount > 0) {
            uint256 effectiveSupply = memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
            if (effectiveSupply == 0) revert NoActiveLiquidityShares();
            // Preorder settlement pulls ERC20 fees directly from the payer because there is no public-swap callback collection step.
            if (!IERC20Minimal(Currency.unwrap(ctx.currencyIn)).transferFrom(payer, address(this), lpFeeInputAmount)) {
                revert ERC20TransferFailed();
            }
            _creditLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFeeInputAmount, effectiveSupply);
        }

        if (protocolFeeInputAmount > 0) {
            address treasury_ = memeverseUniswapHookStorage.treasury;
            if (!IERC20Minimal(Currency.unwrap(ctx.currencyIn)).transferFrom(payer, treasury_, protocolFeeInputAmount))
            {
                revert ERC20TransferFailed();
            }
            emit ProtocolFeeCollected(poolId, ctx.currencyIn, treasury_, protocolFeeInputAmount, block.number);
        }
    }

    function _takeToTreasury(Currency feeCurrency, uint256 amount) internal returns (address treasury_) {
        treasury_ = memeverseUniswapHookStorage.treasury;
        if (treasury_ == address(0)) revert Unauthorized();
        // Skip the take for a zero amount: when rebateBps == PROTOCOL_FEE_SHARE_BPS the entire protocol
        // fee goes to the referrer (toTreasury == 0). A zero-amount take would still call transfer(to, 0),
        // which reverts for non-compliant ERC20s that return false on zero-value transfers.
        if (amount > 0) {
            poolManager.take(feeCurrency, treasury_, amount);
        }
    }

    function _setProtocolFeeCurrencySupport(Currency currency, bool supported) internal {
        if (currency.isAddressZero()) revert NativeCurrencyUnsupported();
        memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[Currency.unwrap(currency)] = supported;
        emit ProtocolFeeCurrencySupportUpdated(currency, supported);
    }

    function _isProtocolFeeCurrencySupported(Currency currency) internal view returns (bool) {
        return memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[Currency.unwrap(currency)];
    }

    function _creditLpFee(
        PoolId poolId,
        Currency feeCurrency,
        bool feeCurrencyIsCurrency0,
        uint256 lpFeeAmount,
        uint256 effectiveSupply
    ) internal {
        PoolInfo storage pool = memeverseUniswapHookStorage.poolInfo[poolId];
        uint256 feePerShare = FullMath.mulDiv(lpFeeAmount, FEE_GROWTH_Q128, effectiveSupply);
        if (feeCurrencyIsCurrency0) {
            uint256 newFee0PerShare = pool.fee0PerShare + feePerShare;
            pool.fee0PerShare = newFee0PerShare;
            emit LPFeeCollected(poolId, feeCurrency, lpFeeAmount, newFee0PerShare, block.number);
        } else {
            uint256 newFee1PerShare = pool.fee1PerShare + feePerShare;
            pool.fee1PerShare = newFee1PerShare;
            emit LPFeeCollected(poolId, feeCurrency, lpFeeAmount, newFee1PerShare, block.number);
        }
    }

    function _actualInputAmount(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne ? uint256((-delta.amount0()).toUint128()) : uint256((-delta.amount1()).toUint128());
    }

    function _actualOutputAmount(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne ? uint256(delta.amount1().toUint128()) : uint256(delta.amount0().toUint128());
    }

    /// @notice Updates the user fee accounting snapshot for a pool.
    /// @dev Requires the pool LP token to exist. Accrues newly earned fees into `pendingFee0/1`
    /// and updates per-share offsets for `user`.
    /// @param id The hook-managed pool id.
    /// @param user The user whose fee snapshot is synchronized.
    function updateUserSnapshot(PoolId id, address user) public override {
        PoolInfo storage pool = memeverseUniswapHookStorage.poolInfo[id];
        UserFeeState storage state = memeverseUniswapHookStorage.userFeeState[id][user];

        if (user == address(0)) {
            state.fee0Offset = pool.fee0PerShare;
            state.fee1Offset = pool.fee1PerShare;
            return;
        }

        uint256 balance = UniswapLP(pool.liquidityToken).balanceOf(user);
        if (balance == 0) {
            // A zero-balance account should not retain stale offsets; advancing them prevents future mint recipients from inheriting old fees.
            state.fee0Offset = pool.fee0PerShare;
            state.fee1Offset = pool.fee1PerShare;
            return;
        }

        unchecked {
            // Crystallize accrued fees before any mint/burn changes the user's LP balance baseline.
            uint256 fee0Claimable = FullMath.mulDiv(balance, pool.fee0PerShare - state.fee0Offset, FEE_GROWTH_Q128);
            uint256 fee1Claimable = FullMath.mulDiv(balance, pool.fee1PerShare - state.fee1Offset, FEE_GROWTH_Q128);

            if (fee0Claimable > 0) state.pendingFee0 += fee0Claimable;
            if (fee1Claimable > 0) state.pendingFee1 += fee1Claimable;
        }

        state.fee0Offset = pool.fee0PerShare;
        state.fee1Offset = pool.fee1PerShare;
    }

    function _activeLpSupplyForSwap(PoolId poolId, int256 amountSpecified)
        internal
        view
        returns (uint256 effectiveSupply)
    {
        if (amountSpecified == 0) return 0;

        effectiveSupply = memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
        if (effectiveSupply != 0) return effectiveSupply;
        // A fully drained pool returns 0 to preserve zero-liquidity quote semantics.
        if (poolManager.getLiquidity(poolId) == 0) return 0;
        revert NoActiveLiquidityShares();
    }

    function _revertIfNoActiveLiquidityShares(PoolId poolId, int256 amountSpecified) internal view {
        _activeLpSupplyForSwap(poolId, amountSpecified);
    }

    /// @notice Updates the treasury address.
    /// @dev Only callable by the owner. Zero address is rejected because protocol fees require a concrete recipient.
    /// The configured treasury is expected to be a passive receiver and must not use fee receipts to trigger
    /// reentrant swap or liquidity actions.
    /// @param _treasury The new treasury address.
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();

        address old = memeverseUniswapHookStorage.treasury;
        memeverseUniswapHookStorage.treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    /// @notice Sets the referral rebate rate on the bound dynamic fee engine.
    /// @dev The engine's `onlyOwner` sees this hook as its owner; the human governance owner
    ///      calls this wrapper to adjust the rate post-deployment.
    /// @param bps New rebate rate in basis points (must not exceed `FeeMath.PROTOCOL_FEE_SHARE_BPS`).
    function setReferrerRebateBps(uint256 bps) external onlyOwner {
        _dynamicFeeEngine().setReferrerRebateBps(bps);
    }

    /// @notice Enables a currency as a supported protocol-fee settlement currency.
    /// @dev This is a convenience wrapper for `setProtocolFeeCurrencySupport(currency, true)`.
    /// @param currency The currency to enable for protocol-fee settlement.
    function setProtocolFeeCurrency(Currency currency) external onlyOwner {
        _setProtocolFeeCurrencySupport(currency, true);
    }

    /// @notice Updates whether a currency is eligible to receive protocol fees.
    /// @dev If both pool sides are supported, the swap path will prefer charging protocol fees on the input side.
    /// @param currency The currency whose support flag is being updated.
    /// @param supported Whether protocol fees may settle in `currency`.
    function setProtocolFeeCurrencySupport(Currency currency, bool supported) external onlyOwner {
        _setProtocolFeeCurrencySupport(currency, supported);
    }

    /// @notice Sets the launcher consulted for post-unlock public-swap protection.
    /// @dev Only callable by the owner. Zero address is rejected to avoid accidental fail-open reconfiguration.
    /// @param launcher_ The launcher binding used for `isPublicSwapAllowed` checks.
    function setLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();

        address oldLauncher = memeverseUniswapHookStorage.launcher;
        memeverseUniswapHookStorage.launcher = launcher_;
        emit LauncherUpdated(oldLauncher, launcher_);
    }

    /// @notice Sets the router authorized to initialize hook-managed pools.
    /// @dev Pool initialization remains blocked unless this router writes a matching one-time authorization.
    /// @param initializer The authorized pool-initializer router.
    function setPoolInitializer(address initializer) external onlyOwner {
        if (initializer == address(0)) revert ZeroAddress();

        address oldInitializer = memeverseUniswapHookStorage.poolInitializer;
        memeverseUniswapHookStorage.poolInitializer = initializer;
        emit PoolInitializerUpdated(oldInitializer, initializer);
    }

    /// @notice Sets the stateless helper used to assemble preorder settlement parameters.
    /// @dev Only callable by the owner. The helper is replaced atomically and must have deployed code.
    /// @param executor The new preorder settlement executor.
    function setPreorderSettlementExecutor(IMemeversePreorderSettlementExecutor executor) external onlyOwner {
        address executorAddress = address(executor);
        if (executorAddress == address(0)) revert ZeroAddress();
        _validatePreorderSettlementExecutor(executor);

        IMemeversePreorderSettlementExecutor oldExecutor = memeverseUniswapHookStorage.preorderSettlementExecutor;
        memeverseUniswapHookStorage.preorderSettlementExecutor = executor;
        emit PreorderSettlementExecutorUpdated(address(oldExecutor), executorAddress);
    }

    /// @notice Updates the clone template used to deploy LP tokens for new pools.
    /// @dev Only callable by the owner. Existing LP clones are unaffected — they are independent contracts.
    /// @param implementation_ The new LP token clone implementation.
    function setLpTokenImplementation(address implementation_) external onlyOwner {
        if (implementation_ == address(0)) revert ZeroAddress();
        if (implementation_.code.length == 0) revert LPTokenImplementationCodeNotReady(implementation_);

        address old = memeverseUniswapHookStorage.lpTokenImplementation;
        memeverseUniswapHookStorage.lpTokenImplementation = implementation_;
        emit LPTokenImplementationUpdated(old, implementation_);
    }

    /// @notice Authorizes the configured pool initializer to initialize one pool at one exact start price.
    /// @dev The authorization is consumed in `beforeInitialize`.
    /// @param key Pool key being authorized.
    /// @param startPriceX96 Expected initial pool price.
    function authorizePoolInitialization(PoolKey calldata key, uint160 startPriceX96)
        external
        erc20Pair(key.currency0, key.currency1)
    {
        if (msg.sender != memeverseUniswapHookStorage.poolInitializer) revert UnauthorizedPoolInitializer();
        PoolId poolId = key.toId();
        if (memeverseUniswapHookStorage.poolInitializationAuth[poolId].active) {
            revert PoolInitializationAlreadyAuthorized();
        }
        memeverseUniswapHookStorage.poolInitializationAuth[poolId] =
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
    function setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime) external onlyLauncher {
        PoolId poolId = _poolIdForTokens(tokenA, tokenB);
        uint40 oldResumeTime = memeverseUniswapHookStorage.publicSwapResumeTime[poolId];
        memeverseUniswapHookStorage.publicSwapResumeTime[poolId] = resumeTime;
        emit PublicSwapResumeTimeUpdated(poolId, oldResumeTime, resumeTime);
    }

    /// @notice Sets the default launch fee configuration.
    /// @dev Only callable by the owner. Zero values and out-of-range schedules are rejected.
    /// @param config The new default launch fee configuration.
    function setDefaultLaunchFeeConfig(IMemeverseDynamicFeeEngine.LaunchFeeConfig calldata config) external onlyOwner {
        if (config.startFeeBps == 0 || config.minFeeBps == 0 || config.decayDurationSeconds == 0) revert ZeroValue();
        if (
            config.startFeeBps > FeeMath.BPS_BASE || config.minFeeBps > FeeMath.BPS_BASE
                || config.minFeeBps > config.startFeeBps
        ) {
            revert ZeroValue();
        }

        IMemeverseDynamicFeeEngine.LaunchFeeConfig memory oldConfig = memeverseUniswapHookStorage.defaultLaunchFeeConfig;
        memeverseUniswapHookStorage.defaultLaunchFeeConfig = config;
        emit DefaultLaunchFeeConfigUpdated(
            oldConfig.startFeeBps,
            oldConfig.minFeeBps,
            oldConfig.decayDurationSeconds,
            config.startFeeBps,
            config.minFeeBps,
            config.decayDurationSeconds
        );
    }

    function _revertIfNativeCurrencyUnsupported(Currency currency0, Currency currency1) internal pure {
        if (currency0.isAddressZero() || currency1.isAddressZero()) revert NativeCurrencyUnsupported();
    }
}
