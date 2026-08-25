// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {ISwapFacet} from "./interfaces/ISwapFacet.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {MemeversePoolKeyLib} from "./libraries/MemeversePoolKeyLib.sol";
import {MemeverseTransientState} from "./libraries/MemeverseTransientState.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {OrdinarySwapMath} from "./libraries/OrdinarySwapMath.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {SwapFeeMath} from "./libraries/SwapFeeMath.sol";
import {SwapGuardMath} from "./libraries/SwapGuardMath.sol";
import {UniswapLP} from "./tokens/UniswapLP.sol";
import {MemeverseSwapFeeBase} from "./MemeverseSwapFeeBase.sol";

/// @title SwapFacet
/// @notice Diamond facet holding the Memeverse v4 hook callback logic, swap-fee split glue, and
///         LP per-share fee accounting.
/// @dev This facet is the delegatecall target for the v4 hook callbacks (`beforeSwap` / `afterSwap` /
///      `beforeInitialize` / `beforeAddLiquidity`) plus the swap-side fee helpers. The Router
///      (`MemeverseUniswapHookUpgradeable`) dispatches each callback by `_forwardCalldata`-ing into the matching
///      `*Logic` function; the facet then executes in the Router's (hook proxy) storage context, so
///      `address(this) == hook` and all storage reads/writes land in the shared hook namespace.
///      `onlyViaRouter` reverts on a direct CALL: under a direct CALL `address(this)` is the facet's own
///      address, which equals the facet's immutable `__self`, so the guard trips (under delegatecall
///      `address(this)` is the hook proxy, ≠ `__self`).
///
///      Storage layout frozen — see `IMemeverseHookStorage` (authoritative source).
///
///      Settlement swaps are initiated by the hook itself, so Uniswap v4 skips their beforeSwap and afterSwap
///      callbacks. Public swaps and callback-token reentrant swaps have non-hook callers and run this facet's
///      normal fee path. Referral rebate tokens remain in hook custody, with `pendingRebate` recorded in shared
///      hook storage.
///      Dynamic-fee quotes and realized-state updates delegate to `DynamicFeeFacet`; `address(this)` remains
///      the hook proxy and all state stays keyed by `PoolId` in the shared namespace.
// solhint-disable-next-line gas-small-strings
contract SwapFacet layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    MemeverseSwapFeeBase,
    ISwapFacet,
    ImmutableState
{
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    // Reuse the existing transient fee word so afterSwap can recover the fee side without another storage lookup.
    uint256 internal constant SWAP_CONTEXT_PROTOCOL_FEE_ON_INPUT_FLAG = 1 << 255;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param poolManager_ PoolManager shared with the hook (bound as immutable implementation bytecode state).
    ///      Trailing underscore resolves the clash with the inherited `ImmutableState.poolManager` immutable.
    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    /// @notice Reverts when a currency pair includes native (zero-address) currency.
    modifier erc20Pair(Currency currency0, Currency currency1) {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(currency0, currency1);
        _;
    }

    // -----------------------------------------------------------------
    // v4 hook callback logic entries
    // -----------------------------------------------------------------

    /// @inheritdoc ISwapFacet
    /// @dev Only swaps whose caller differs from the hook reach this callback (see the contract-level dev note
    ///      on v4 skipping hook self-call swap callbacks).
    function beforeSwapLogic(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyViaRouter
        erc20Pair(key.currency0, key.currency1)
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeBps)
    {
        PoolId poolId = key.toId();
        address referrer = _decodeReferrer(hookData);
        // Execution identity comes ONLY from the hook-captured active session principal; there is no
        // transaction-origin, Router, or hookData fallback. A swap reaching this callback without an active session
        // is rejected before any fee work runs. `principal` is the dynamic-fee address-batch key for this
        // swap and is pushed into the matching swap context for the afterSwap principal check.
        address principal = MemeverseTransientState.activePrincipal();
        if (principal == address(0)) revert IMemeverseUniswapHook.AccountSessionNotActive();
        _revertIfPublicSwapBlocked(poolId);
        // Run the public-swap business gate before acquiring the per-pool lifecycle lock. The lock then
        // covers the complete beforeSwap → pool swap → afterSwap window, preventing callback tokens from
        // reentering this pool and advancing dynamicFeeState against the outer swap's fee snapshot.
        if (MemeverseTransientState.acquireSwapLifecycleLock(poolId)) {
            revert IMemeverseUniswapHook.SwapLifecycleReentrant();
        }
        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 effectiveSupply = _activeLpSupplyForSwap(poolId, liquidity);
        SwapFeeMath.SwapFeeContext memory ctx = _resolveSwapFeeContext(key, params.zeroForOne);
        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(liquidity, preSqrtPriceX96, params.zeroForOne, params.sqrtPriceLimitX96);

        // Fee selection uses the original request curve exactly once. The fee leg and price limit are
        // carried for settlement/quote geometry but are not inputs to DynamicFeeMath.selectDynamicFee.
        uint256 dynamicFeeBps = _prepareSwapFee(
            IDynamicFeeFacet.PrepareSwapFeeParams({
                poolId: poolId,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                trader: principal,
                preSqrtPriceX96: preSqrtPriceX96,
                liquidity: liquidity,
                protocolFeeOnInput: ctx.protocolFeeOnInput,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );
        OrdinarySwapMath.FeeSplit memory feeSplit = OrdinarySwapMath.deriveFeeSplit(dynamicFeeBps);
        OrdinarySwapMath.SettlementPlan memory settlementPlan =
            OrdinarySwapMath.deriveSettlementPlan(params.amountSpecified, ctx.protocolFeeOnInput, feeSplit);
        OrdinarySwapMath.revertIfFinalTargetIsNotExecutable(
            liquidity, preSqrtPriceX96, params.amountSpecified, settlementPlan, capacity
        );

        uint256 coreTarget =
            params.amountSpecified < 0 ? settlementPlan.coreInputTarget : settlementPlan.coreOutputTarget;
        _revertIfBeforeSwapAmountsAreNotRepresentable(params.amountSpecified, coreTarget);
        MemeverseTransientState.pushSwapContext(
            poolId, principal, _encodeSwapContextFee(dynamicFeeBps, ctx.protocolFeeOnInput), preSqrtPriceX96, coreTarget
        );

        uint256 specifiedDeltaAmount;
        if (params.amountSpecified < 0) {
            _collectKnownInputFees(poolId, ctx, settlementPlan, effectiveSupply, referrer);
            specifiedDeltaAmount =
                OrdinarySwapMath._absoluteExactInput(params.amountSpecified) - settlementPlan.coreInputTarget;
        } else {
            specifiedDeltaAmount = settlementPlan.coreOutputTarget - uint256(params.amountSpecified);
        }
        if (specifiedDeltaAmount == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDeltaAmount.toInt128(), int128(0)), 0);
    }

    /// @inheritdoc ISwapFacet
    /// @dev Every invocation consumes a context created by the matching `beforeSwapLogic` call; settlement
    ///      self-calls never reach this callback (see the contract-level dev note).
    function afterSwapLogic(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyViaRouter returns (bytes4 selector, int128 unspecifiedDelta) {
        // Compute the poolId once here and reuse it inside `_afterSwapLifecycleLogic` to avoid the
        // duplicate `key.toId()` keccak that occurred when a `releaseSwapLifecycleLock` modifier and
        // the body each derived it independently (viaIR does not CSE across that boundary).
        PoolId poolId = key.toId();
        (selector, unspecifiedDelta) = _afterSwapLifecycleLogic(poolId, key, params, delta, hookData);
        // Single release point: reached on every normal return from the helper. If the helper reverts,
        // execution unwinds before this line, so the lock is not released here; transient storage auto-clears
        // at tx end so no stale lock persists (same semantics as the former modifier, which also released
        // only after a normal `_;` return).
        MemeverseTransientState.releaseSwapLifecycleLock(poolId);
    }

    /// @dev Body helper for the external `afterSwapLogic`. Accepts the already-derived `poolId` as the first
    ///      argument so the poolId keccak is computed exactly once per swap (by the external wrapper) rather
    ///      than once by a release modifier and again in the body. The lifecycle-lock release is intentionally
    ///      NOT performed here: it lives in the external wrapper so a single release covers all return paths.
    function _afterSwapLifecycleLogic(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4 selector, int128 unspecifiedDelta) {
        address referrer = _decodeReferrer(hookData);

        // Execution identity is validated by `_loadAndValidateSwapContext`, which also consumes the matching
        // beforeSwap context and returns it for the fee/settlement math below.
        MemeverseTransientState.SwapContext memory context = _loadAndValidateSwapContext(poolId);

        (Currency currencyIn, Currency currencyOut) = SwapFeeMath.swapCurrencies(key, params.zeroForOne);
        uint256 encodedFeeBps = context.encodedFeeBps;
        uint160 preSqrtPriceX96 = context.preSqrtPriceX96;
        uint256 storedCoreTarget = context.coreTarget;
        uint256 feeBps = _decodeSwapContextFee(encodedFeeBps);
        bool protocolFeeOnInput = _swapContextProtocolFeeOnInput(encodedFeeBps);
        (uint160 postSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        OrdinarySwapMath.FeeSplit memory feeSplit = OrdinarySwapMath.deriveFeeSplit(feeBps);
        OrdinarySwapMath.SettlementPlan memory settlementPlan =
            OrdinarySwapMath.deriveSettlementPlan(params.amountSpecified, protocolFeeOnInput, feeSplit);
        uint256 derivedCoreTarget =
            params.amountSpecified < 0 ? settlementPlan.coreInputTarget : settlementPlan.coreOutputTarget;
        if (storedCoreTarget != derivedCoreTarget) revert OrdinarySwapMath.FinalTargetNotMet();

        OrdinarySwapMath.CurveResult memory actualCurve = OrdinarySwapMath.CurveResult({
            coreInput: SwapFeeMath.actualInputAmount(delta, params.zeroForOne),
            coreGrossOutput: SwapFeeMath.actualOutputAmount(delta, params.zeroForOne),
            postSqrtPriceX96: postSqrtPriceX96
        });
        if (params.amountSpecified < 0 && actualCurve.coreInput != settlementPlan.coreInputTarget) {
            revert IMemeverseUniswapHook.ExactInputPartialFill();
        }
        if (params.amountSpecified > 0 && actualCurve.coreGrossOutput < settlementPlan.coreOutputTarget) {
            revert IMemeverseUniswapHook.ExactOutputPartialFill();
        }
        OrdinarySwapMath.FinalSettlement memory finalSettlement = OrdinarySwapMath.deriveFinalSettlement(
            params.amountSpecified, protocolFeeOnInput, feeSplit, settlementPlan, actualCurve
        );
        uint256 unspecifiedDeltaAmount = params.amountSpecified < 0
            ? actualCurve.coreGrossOutput - finalSettlement.userNetOutput
            : finalSettlement.userInput - actualCurve.coreInput;
        // Check before the cast: an out-of-range amount must revert with `AmountNotRepresentable`,
        // not a generic `SafeCastOverflow` (mirrors the check-then-cast order in `beforeSwapLogic`).
        _revertIfFinalUserAmountsAreNotRepresentable(finalSettlement);
        int128 callbackDelta = unspecifiedDeltaAmount.toInt128();

        // History advances only after actual core deltas pass the complete-fill and callback-bound checks.
        _updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
                poolId: poolId,
                delta: delta,
                trader: context.principal,
                preSqrtPriceX96: preSqrtPriceX96,
                postSqrtPriceX96: postSqrtPriceX96
            })
        );

        if (params.amountSpecified < 0) {
            if (!protocolFeeOnInput && finalSettlement.protocolFee > 0) {
                _collectProtocolFee(poolId, currencyOut, finalSettlement.protocolFee, referrer);
            }
            return (IHooks.afterSwap.selector, callbackDelta);
        }

        uint256 effectiveSupply = _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
        if (finalSettlement.lpFee > 0) {
            _collectLpFee(poolId, currencyIn, params.zeroForOne, finalSettlement.lpFee, effectiveSupply);
        }
        if (finalSettlement.protocolFee > 0) {
            Currency protocolFeeCurrency = protocolFeeOnInput ? currencyIn : currencyOut;
            _collectProtocolFee(poolId, protocolFeeCurrency, finalSettlement.protocolFee, referrer);
        }
        return (IHooks.afterSwap.selector, callbackDelta);
    }

    /// @dev Loads and validates the beforeSwap context for this afterSwap. Requires an active session whose
    ///      principal matches the consumed context's principal. A missing context (no matching beforeSwap,
    ///      wrong pool, or a zero-principal push) reverts ContextMissing; a principal mismatch (session
    ///      changed between beforeSwap and afterSwap — impossible inside one atomic account frame) reverts
    ///      PrincipalMismatch. Returns the validated context for the caller's fee/settlement math.
    function _loadAndValidateSwapContext(PoolId poolId)
        internal
        returns (MemeverseTransientState.SwapContext memory context)
    {
        address activePrincipal = MemeverseTransientState.activePrincipal();
        if (activePrincipal == address(0)) revert IMemeverseUniswapHook.AccountSessionNotActive();

        context = MemeverseTransientState.consumeCurrentSwapContext(poolId);
        if (context.principal == address(0)) revert IMemeverseUniswapHook.AccountSessionContextMissing();
        if (context.principal != activePrincipal) {
            revert IMemeverseUniswapHook.AccountSessionPrincipalMismatch(context.principal, activePrincipal);
        }
    }

    /// @inheritdoc ISwapFacet
    /// @dev Validates tick spacing, the dynamic-fee flag, the configured pool initializer as `sender`,
    ///      and the one-time price authorization; then clones the LP token implementation and records the
    ///      pool launch timestamp. Reads/writes the
    ///      shared hook storage (`poolInfo`, `poolLaunchTimestamp`, `poolInitializationAuth`,
    ///      `lpTokenImplementation`) via delegatecall.
    function beforeInitializeLogic(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyViaRouter
        erc20Pair(key.currency0, key.currency1)
        returns (bytes4 selector)
    {
        if (key.tickSpacing != MemeversePoolKeyLib.DEFAULT_TICK_SPACING) {
            revert IMemeverseUniswapHook.TickSpacingNotDefault();
        }
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert IMemeverseUniswapHook.FeeMustBeDynamic();

        PoolId poolId = key.toId();

        if (sender != _memeverseUniswapHookStorage.poolInitializer) {
            revert IMemeverseUniswapHook.UnauthorizedPoolInitializer();
        }

        PoolInitializationAuth memory auth = _memeverseUniswapHookStorage.poolInitializationAuth[poolId];
        if (!auth.active) revert IMemeverseUniswapHook.UnauthorizedPoolInitialization();
        if (auth.startPriceX96 != sqrtPriceX96) revert IMemeverseUniswapHook.InvalidInitialPrice();
        delete _memeverseUniswapHookStorage.poolInitializationAuth[poolId];

        address liquidityToken = Clones.clone(_memeverseUniswapHookStorage.lpTokenImplementation);
        // Initialize immediately so the clone cannot be claimed and LP mint/burn authority stays with this hook.
        UniswapLP(liquidityToken).initialize("Memeverse LP", "MLP", 18, poolId, address(this));

        _memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken = liquidityToken;
        _memeverseUniswapHookStorage.poolLaunchTimestamp[poolId] = uint40(block.timestamp);

        emit IMemeverseUniswapHook.PoolInitialized(poolId, liquidityToken, key.currency0, key.currency1);

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc ISwapFacet
    /// @dev Restricts add-liquidity modifications to calls originating from the hook itself. The Router's
    ///      liquidity entries `unlock` into PoolManager, which calls the hook with `sender == address(this)`.
    function beforeAddLiquidityLogic(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyViaRouter
        returns (bytes4 selector)
    {
        if (sender != address(this)) revert IMemeverseUniswapHook.SenderMustBeHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice External wrapper exposing the per-share snapshot logic to the Router.
    /// @dev Reached by two Router paths: the external `updateUserSnapshot` entry (LP-token transfer hook)
    ///      via `_forwardCalldata` (selector swap), and the liquidity entries via `_facetDelegatecall`
    ///      (`_updateUserSnapshotViaFacet`). The body delegates to the `internal` helper below so the
    ///      accounting stays in one place; a direct CALL still trips `onlyViaRouter`.
    function updateUserSnapshotLogic(PoolId id, address user) external override onlyViaRouter {
        _updateUserSnapshot(id, user);
    }

    // -----------------------------------------------------------------
    // Internal state-changing helpers
    // -----------------------------------------------------------------

    /// @dev Exact-input fees known before the core swap keep the existing LP/rebate merged-take optimization.
    // reentrancy-no-eth: poolManager.take (L368) does not invoke a v4 hook callback (see _settleProtocolFee @dev); reachable only inside the per-pool acquireSwapLifecycleLock window (acquired at beforeSwapLogic L108), so a reentrant same-pool swap reverts SwapLifecycleReentrant. Effects (_accrueLpFee/_settleProtocolFee) precede the take (strict CEI).
    // reentrancy-events: same window — within _settleProtocolFee, ReferralRebateAccrued is emitted before the _takeToTreasury take, while ProtocolFeeCollected is emitted after it (it needs the treasury_ return value). The take runs inside the per-pool acquireSwapLifecycleLock window, so the event-after-external-call ordering poses no reentrancy risk.
    // Two stacked next-line directives are NOT honored by slither (only the last one before the line
    // applies), so both detectors are suppressed in a single comma-separated directive below.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function _collectKnownInputFees(
        PoolId poolId,
        SwapFeeMath.SwapFeeContext memory ctx,
        OrdinarySwapMath.SettlementPlan memory settlementPlan,
        uint256 effectiveSupply,
        address referrer
    ) internal {
        uint256 lpFee = settlementPlan.knownLpInputFee;
        uint256 protocolFee = settlementPlan.knownProtocolInputFee;
        if (lpFee > 0 && protocolFee > 0 && effectiveSupply != 0) {
            uint256 rebate = _computeRebate(protocolFee, referrer);
            _accrueLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFee, effectiveSupply);
            _settleProtocolFee(poolId, ctx.currencyIn, protocolFee, referrer, rebate);
            poolManager.take(ctx.currencyIn, address(this), lpFee + rebate);
            return;
        }

        if (lpFee > 0) _collectLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFee, effectiveSupply);
        if (protocolFee > 0) _collectProtocolFee(poolId, ctx.currencyIn, protocolFee, referrer);
    }

    /// @dev Treasury take + rebate ledger/emit, WITHOUT the rebate take. The rebate take is the caller's
    ///      responsibility: `_collectProtocolFee` takes rebate inline (afterSwap / beforeSwap edge), while
    ///      the beforeSwap merge path folds the rebate take into the LP-fee take. Splitting here lets both
    ///      paths share the ledger/emit/treasury logic so the rebate formula and event ordering stay
    ///      identical. This helper is strict CEI: the rebate ledger effect (`pendingRebate += rebate`) and
    ///      `ReferralRebateAccrued` emit precede the treasury take (`_takeToTreasury` → `PoolManager.take`),
    ///      which precedes the `ProtocolFeeCollected` emit (it needs the `treasury_` return value). The
    ///      ledger effect also precedes the caller-side rebate take. `PoolManager.take` does not invoke a v4
    ///      hook callback, but it does execute the ERC20 currency's `transfer` code. Safety still relies on
    ///      standard ERC20 fee currencies, a passive treasury, and atomic rollback if any interaction reverts.
    function _settleProtocolFee(
        PoolId poolId,
        Currency feeCurrency,
        uint256 protocolFeeAmount,
        address referrer,
        uint256 rebate
    ) internal {
        uint256 toTreasury = protocolFeeAmount - rebate;
        // Effect: record the rebate ledger before any external interaction (strict CEI) so a reentrant call
        // during the treasury take cannot observe a stale rebate balance for this swap's referrer.
        if (rebate > 0) {
            _memeverseUniswapHookStorage.pendingRebate[referrer][feeCurrency] += rebate;
            emit IMemeverseUniswapHook.ReferralRebateAccrued(referrer, feeCurrency, rebate);
        }
        // Interaction: treasury take (reentrancy bounds: see the @dev above). Always emit ProtocolFeeCollected
        // for indexer continuity (toTreasury may be 0 when rebateBps == PROTOCOL_FEE_SHARE_BPS).
        // _takeToTreasury with amount 0 is a no-op take.
        address treasury_ = _takeToTreasury(feeCurrency, toTreasury);
        emit IMemeverseUniswapHook.ProtocolFeeCollected(poolId, feeCurrency, treasury_, toTreasury, block.number);
    }

    /// @dev Rebate custody remains on the hook proxy: `poolManager.take(feeCurrency, address(this), rebate)`.
    ///      Under delegatecall `address(this)` is the hook proxy, so the token
    ///      lands in hook custody and the v4 `take` delta is recorded on the hook (offset by its
    ///      `beforeSwap` specifiedDelta credit, which already reserves the full protocol fee). The rebate
    ///      ledger increment is handled by `_settleProtocolFee` (`pendingRebate[...] += rebate` + emit),
    ///      and the ledger step itself creates no unsettled hook delta. Rebate rate reads the hook-owned
    ///      `referrerRebateBps` storage value.
    ///      `_computeRebate` and `_settleProtocolFee` give the beforeSwap merge path the same rebate formula
    ///      and ledger/emit ordering without a separate rebate take.
    function _collectProtocolFee(PoolId poolId, Currency feeCurrency, uint256 protocolFeeAmount, address referrer)
        internal
    {
        if (protocolFeeAmount == 0) return;
        uint256 rebate = _computeRebate(protocolFeeAmount, referrer);
        _settleProtocolFee(poolId, feeCurrency, protocolFeeAmount, referrer, rebate);
        if (rebate > 0) {
            // Separate rebate take (afterSwap path + beforeSwap edge); the beforeSwap main path merges this
            // take with the LP-fee take instead (same currency, same recipient address(this)) — see the @dev
            // above for the hook-custody settlement rationale.
            poolManager.take(feeCurrency, address(this), rebate);
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

        // CEI: credit the per-share accumulator (effect + emit LPFeeCollected) before the token pull
        // (interaction). Matches the beforeSwap merge path above and SettlementFacet's settlement path.
        // Atomic rollback still bounds the take: if take reverts, the accrual storage write reverts with it.
        _accrueLpFee(poolId, feeCurrency, feeCurrencyIsCurrency0, lpFeeAmount, effectiveSupply);
        poolManager.take(feeCurrency, address(this), lpFeeAmount);
    }

    function _takeToTreasury(Currency feeCurrency, uint256 amount) internal returns (address treasury_) {
        treasury_ = _memeverseUniswapHookStorage.treasury;
        if (treasury_ == address(0)) revert IMemeverseUniswapHook.Unauthorized();
        // Skip the take for a zero amount: when rebateBps == PROTOCOL_FEE_SHARE_BPS the entire protocol
        // fee goes to the referrer (toTreasury == 0). A zero-amount take would still call transfer(to, 0),
        // which reverts for non-compliant ERC20s that return false on zero-value transfers.
        if (amount > 0) {
            poolManager.take(feeCurrency, treasury_, amount);
        }
    }

    /// @notice Updates the user fee accounting snapshot for a pool.
    /// @dev Kept `internal` and wrapped by
    ///      `updateUserSnapshotLogic` so the Router can reach it across the contract boundary via
    ///      delegatecall. Reads/writes the shared hook storage `poolInfo` and `userFeeState`.
    /// @param id The hook-managed pool id.
    /// @param user The user whose fee snapshot is synchronized.
    function _updateUserSnapshot(PoolId id, address user) internal {
        PoolInfo storage pool = _memeverseUniswapHookStorage.poolInfo[id];
        UserFeeState storage state = _memeverseUniswapHookStorage.userFeeState[id][user];

        // Snapshot pool fee growth and the user's current offsets once into locals.
        // This function never writes pool.fee*PerShare, so all later uses share the
        // same local values (solc via_ir does not reliably CSE storage here). Caching
        // the offsets before the external balanceOf also enables a zero-growth
        // early-return: when fee growth has not advanced past the offset, mulDiv is 0,
        // the if(>0) guards skip, and the offset SSTOREs would be no-ops, so we skip
        // balanceOf + mulDiv + noop writes entirely (the common case on the Router
        // remove path, where the LP token's _update override already synced the offset).
        uint256 fee0PerShare = pool.fee0PerShare;
        uint256 fee1PerShare = pool.fee1PerShare;
        uint256 fee0Offset = state.fee0Offset;
        uint256 fee1Offset = state.fee1Offset;

        if (user == address(0)) {
            state.fee0Offset = fee0PerShare;
            state.fee1Offset = fee1PerShare;
            return;
        }

        // Zero-growth fast path: offsets already match current growth, so there is
        // nothing to crystallize and nothing to write. Returning here also skips the
        // external balanceOf call below.
        if (fee0PerShare == fee0Offset && fee1PerShare == fee1Offset) {
            return;
        }

        uint256 balance = UniswapLP(pool.liquidityToken).balanceOf(user);
        if (balance == 0) {
            // A zero-balance account should not retain stale offsets; advancing them prevents future mint recipients from inheriting old fees.
            state.fee0Offset = fee0PerShare;
            state.fee1Offset = fee1PerShare;
            return;
        }

        unchecked {
            // Crystallize accrued fees before any mint/burn changes the user's LP balance baseline.
            // Subtraction is safe: fee growth is monotonically non-decreasing, so fee*PerShare >= fee*Offset.
            uint256 fee0Claimable = FeeMath.claimableFee(balance, fee0PerShare, fee0Offset);
            uint256 fee1Claimable = FeeMath.claimableFee(balance, fee1PerShare, fee1Offset);

            if (fee0Claimable > 0) state.pendingFee0 += fee0Claimable;
            if (fee1Claimable > 0) state.pendingFee1 += fee1Claimable;
        }

        state.fee0Offset = fee0PerShare;
        state.fee1Offset = fee1PerShare;
    }

    // -----------------------------------------------------------------
    // Facet-to-facet internal delegatecall to DynamicFeeFacet
    // -----------------------------------------------------------------

    /// @dev `beforeSwapLogic` uses this wrapper to delegate through
    ///      `MemeverseSwapFeeBase._delegatecallDynamicFeeFacet`. The settlement path uses its fixed fee and
    ///      does not call this quote wrapper. The hot path decodes one `feeBps` word.
    function _prepareSwapFee(IDynamicFeeFacet.PrepareSwapFeeParams memory params) internal returns (uint256 feeBps) {
        bytes memory ret = _delegatecallDynamicFeeFacet(abi.encodeCall(IDynamicFeeFacet.prepareSwapFee, (params)));
        return abi.decode(ret, (uint256));
    }

    // -----------------------------------------------------------------
    // Internal view helpers
    // -----------------------------------------------------------------

    /// @dev Rebate share of the protocol fee: protocolFee * rebateBps / PROTOCOL_FEE_SHARE_BPS.
    ///      Returns 0 when there is no referrer or rebate is disabled (rebateBps == 0). Both the beforeSwap
    ///      merged take and `_collectProtocolFee` use this formula.
    function _computeRebate(uint256 protocolFeeAmount, address referrer) internal view returns (uint256 rebate) {
        if (referrer == address(0)) return 0;
        uint256 rebateBps = _memeverseUniswapHookStorage.referrerRebateBps;
        if (rebateBps == 0) return 0;
        return FullMath.mulDiv(protocolFeeAmount, rebateBps, FeeMath.PROTOCOL_FEE_SHARE_BPS);
    }

    /// @dev Gate logic lives in SwapGuardMath so the execution path cannot drift from the quote path.
    function _revertIfPublicSwapBlocked(PoolId poolId) internal view {
        SwapGuardMath.revertIfPublicSwapBlocked(_memeverseUniswapHookStorage.publicSwapResumeTime[poolId]);
    }

    /// @dev Returns the cached LP total supply for per-share fee accounting. `beforeSwapLogic` reads
    ///      liquidity once for both this gate and the dynamic-fee quote. When the cache is zero:
    ///      - if the pool has liquidity → reverts NoActiveLiquidityShares (pool is active, cache is stale)
    ///      - if the pool is drained (liquidity == 0) → returns 0, preserving zero-liquidity quote semantics
    ///      Mirrors `SettlementFacet._activeLpSupplyForSettlement(PoolId)` shape; no `amountSpecified`
    ///      parameter because this runs only inside the v4 beforeSwap callback, which v4 guarantees is
    ///      non-zero (PoolManager.swap reverts SwapAmountCannotBeZero before dispatching beforeSwap).
    function _activeLpSupplyForSwap(PoolId poolId, uint128 liquidity) internal view returns (uint256 effectiveSupply) {
        effectiveSupply = _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
        if (effectiveSupply != 0) return effectiveSupply;
        // Gate delegated to SwapGuardMath (single source of truth). Reuse the same liquidity snapshot passed
        // to the quote; liquidity==0 means a drained pool, otherwise the stale cache is rejected.
        SwapGuardMath.revertIfOrphanedLiquidity(liquidity);
        return 0;
    }

    // -----------------------------------------------------------------
    // Internal pure helpers
    // -----------------------------------------------------------------

    function _revertIfBeforeSwapAmountsAreNotRepresentable(int256 amountSpecified, uint256 coreTarget) internal pure {
        uint256 largestDelta = uint256(uint128(type(int128).max));
        if (coreTarget > largestDelta) revert OrdinarySwapMath.AmountNotRepresentable();
        if (amountSpecified < 0 && OrdinarySwapMath._absoluteExactInput(amountSpecified) > largestDelta) {
            revert OrdinarySwapMath.AmountNotRepresentable();
        }
    }

    function _revertIfFinalUserAmountsAreNotRepresentable(OrdinarySwapMath.FinalSettlement memory finalSettlement)
        internal
        pure
    {
        uint256 largestDelta = uint256(uint128(type(int128).max));
        if (finalSettlement.userInput > largestDelta || finalSettlement.userNetOutput > largestDelta) {
            revert OrdinarySwapMath.AmountNotRepresentable();
        }
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
}
