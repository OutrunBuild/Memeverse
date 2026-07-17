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
///      (`MemeverseUniswapHook`) dispatches each callback by `_forwardCalldata`-ing into the matching
///      `*Logic` function; the facet then executes in the Router's (hook proxy) storage context, so
///      `address(this) == hook` and all storage reads/writes land in the shared hook namespace.
///      `onlyViaRouter` reverts on a direct CALL: under a direct CALL `address(this)` is the facet's own
///      address, which equals the facet's immutable `__self`, so the guard trips (under delegatecall
///      `address(this)` is the hook proxy, ≠ `__self`).
///
///      Storage layout FROZEN — shared ERC-7201 namespace; field order fixed, append-only.
///      See `IMemeverseHookStorage.MemeverseUniswapHookStorage` for the slot-derivation rationale.
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
    using SafeCast for int256;

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
    /// @dev Uniswap v4 invokes this callback only for swaps whose caller differs from the hook. Hook-initiated
    ///      settlement swaps skip both swap callbacks in PoolManager, while public and callback-token reentrant
    ///      swaps reach this function and use the normal public-fee path.
    function beforeSwapLogic(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyViaRouter
        erc20Pair(key.currency0, key.currency1)
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeBps)
    {
        PoolId poolId = key.toId();
        address referrer = _decodeReferrer(hookData);
        _revertIfPublicSwapBlocked(poolId);
        // Run the public-swap business gate before acquiring the per-pool lifecycle lock. The lock then
        // covers the complete beforeSwap → pool swap → afterSwap window, preventing callback tokens from
        // reentering this pool and advancing dynamicFeeState against the outer swap's fee snapshot.
        if (MemeverseTransientState.acquireSwapLifecycleLock(poolId)) {
            revert IMemeverseUniswapHook.SwapLifecycleReentrant();
        }
        uint128 liquidity = poolManager.getLiquidity(poolId);
        uint256 effectiveSupply = _activeLpSupplyForSwap(poolId, liquidity);

        uint256 absSpecified = params.amountSpecified.abs();
        SwapFeeMath.SwapFeeContext memory ctx = _resolveSwapFeeContext(key, params.zeroForOne);

        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Dynamic-fee quote via internal delegatecall to DynamicFeeFacet (facet-to-facet collaboration).
        // `address(this)` stays the hook proxy; the facet reads launch config/timestamp from shared
        // storage, so callers only pass pool/swap/trader context.
        (uint256 dynamicFeeBps, uint256 estimatedGrossOutputAmount) = _prepareSwapFee(
            IDynamicFeeFacet.PrepareSwapFeeParams({
                poolId: poolId,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                // solhint-disable-next-line avoid-tx-origin
                trader: tx.origin,
                preSqrtPriceX96: preSqrtPriceX96,
                liquidity: liquidity,
                protocolFeeOnInput: ctx.protocolFeeOnInput
            })
        );

        (uint256 lpFeeBpsSplit, uint256 protocolFeeBps) = FeeMath.splitFeeBps(dynamicFeeBps);

        uint256 lpFeeInputAmount = 0;
        uint256 protocolFeeInputAmount = 0;
        if (params.amountSpecified < 0) {
            // Exact-input swaps can charge input-side fees immediately because the user's budget is already known up front.
            // Shared with afterSwapLogic's partial-fill guard via _exactInputFeeAmounts so the two cannot drift.
            (lpFeeInputAmount, protocolFeeInputAmount) =
                _exactInputFeeAmounts(absSpecified, lpFeeBpsSplit, protocolFeeBps, ctx.protocolFeeOnInput);
        }

        bytes32 swapContextBase = MemeverseTransientState.pushSwapContext(
            poolId, _encodeSwapContextFee(dynamicFeeBps, ctx.protocolFeeOnInput), preSqrtPriceX96
        );
        uint256 exactOutputProtocolFeeOutputAmount = 0;
        if (params.amountSpecified > 0 && !ctx.protocolFeeOnInput) {
            // Bounded: drained pools (liquidity == 0) yield estimatedGrossOutputAmount == 0 from the
            // dynamic-fee early-return, so subtracting absSpecified would underflow. Clamp to 0 so the
            // swap proceeds to afterSwap's ExactOutputPartialFill guard instead of panicking here.
            exactOutputProtocolFeeOutputAmount =
                estimatedGrossOutputAmount > absSpecified ? estimatedGrossOutputAmount - absSpecified : 0;
            MemeverseTransientState.storeExactOutputProtocolFee(swapContextBase, exactOutputProtocolFeeOutputAmount);
        }

        if (lpFeeInputAmount > 0 && protocolFeeInputAmount > 0 && effectiveSupply != 0) {
            // LP fee and rebate both accrue to address(this) in currencyIn, so their takes collapse into one
            // poolManager.take (saves one PoolManager CALL + one ERC20 transfer per referrer-bearing input-side
            // swap). `_settleProtocolFee` records the rebate ledger (effect) before the treasury take
            // (interaction); the ledger also precedes this caller-side merged rebate take. `PoolManager.take`
            // does not invoke a v4 hook callback, but its ERC20 transfer still executes currency token code.
            // Safety relies on the fee currency being a standard ERC20, a passive treasury, and atomic
            // transaction rollback.
            // `effectiveSupply != 0` gates the merge path: drained pools (liquidity == 0) make
            // _activeLpSupplyForSwap return 0, and _accrueLpFee would divide-by-zero (Panic 0x12) inside
            // FullMath.mulDiv. Such pools must fall through to the else branch, where _collectLpFee
            // early-returns on its own effectiveSupply == 0 guard while protocol fee is still collected.
            uint256 rebate = _computeRebate(protocolFeeInputAmount, referrer);
            _accrueLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFeeInputAmount, effectiveSupply);
            _settleProtocolFee(poolId, ctx.currencyIn, protocolFeeInputAmount, referrer, rebate);
            poolManager.take(ctx.currencyIn, address(this), lpFeeInputAmount + rebate);
        } else {
            // Edge cases (lpFee == 0, protocol == 0, or drained pool with effectiveSupply == 0): keep the
            // two independent checks so a drained pool still skips LP fee (_collectLpFee
            // early-returns) while protocol fee is collected as usual.
            if (lpFeeInputAmount > 0) {
                _collectLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFeeInputAmount, effectiveSupply);
            }
            if (protocolFeeInputAmount > 0) {
                _collectProtocolFee(poolId, ctx.currencyIn, protocolFeeInputAmount, referrer);
            }
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

    /// @inheritdoc ISwapFacet
    /// @dev Settlement self-calls never reach this callback because Uniswap v4 skips both swap callbacks when
    ///      `msg.sender == address(key.hooks)`. Every invocation here therefore consumes a context created by
    ///      the matching `beforeSwapLogic` call.
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

        (Currency currencyIn, Currency currencyOut) = SwapFeeMath.swapCurrencies(key, params.zeroForOne);
        (uint256 encodedFeeBps, uint160 preSqrtPriceX96, bytes32 swapContextBase) =
            MemeverseTransientState.consumeCurrentSwapContext(poolId);
        uint256 feeBps = _decodeSwapContextFee(encodedFeeBps);
        bool protocolFeeOnInput = _swapContextProtocolFeeOnInput(encodedFeeBps);
        SwapFeeMath.SwapFeeContext memory ctx = SwapFeeMath.SwapFeeContext({
            currencyIn: currencyIn,
            currencyOut: currencyOut,
            inputIsCurrency0: params.zeroForOne,
            protocolFeeOnInput: protocolFeeOnInput
        });
        (uint160 postSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Realized-state update via internal delegatecall to DynamicFeeFacet.
        _updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
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
            // The input-fee charge and partial-fill guard both use `_exactInputFeeAmounts`, so they apply
            // the identical formula.
            (uint256 lpFeeInputAmount, uint256 protocolFeeInputAmount) =
                _exactInputFeeAmounts(absSpecified, lpFeeBps, protocolFeeBps, ctx.protocolFeeOnInput);
            uint256 expectedPoolInput = absSpecified - lpFeeInputAmount - protocolFeeInputAmount;
            uint256 actualPoolInput = SwapFeeMath.actualInputAmount(delta, params.zeroForOne);
            if (actualPoolInput != expectedPoolInput) revert IMemeverseUniswapHook.ExactInputPartialFill();

            if (!ctx.protocolFeeOnInput) {
                uint256 actualOutputAbs = SwapFeeMath.actualOutputAmount(delta, params.zeroForOne);
                uint256 exactInputProtocolFeeOutputAmount = FeeMath.feeOnAmount(actualOutputAbs, protocolFeeBps);
                if (exactInputProtocolFeeOutputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyOut, exactInputProtocolFeeOutputAmount, referrer);
                }
                // V4 afterSwap contract: a positive unspecifiedDelta means the hook takes that much of the
                // unspecified currency. For exact-input swaps unspecified=output, so returning the output-side
                // protocol fee as positive withholds it from the taker (user receives less output).
                return (IHooks.afterSwap.selector, int128(int256(exactInputProtocolFeeOutputAmount)));
            }

            return (IHooks.afterSwap.selector, 0);
        }

        if (params.amountSpecified > 0) {
            // Exact-output fees settle against the actual fill, so only afterSwap knows the final input amount to charge.
            uint256 requestedOutputAbs = uint256(params.amountSpecified);
            uint256 actualOutputAbs = SwapFeeMath.actualOutputAmount(delta, params.zeroForOne);
            uint256 minimumOutputAbs = requestedOutputAbs;
            uint256 reservedProtocolFeeOutputAmount = 0;
            if (!ctx.protocolFeeOnInput) {
                reservedProtocolFeeOutputAmount = MemeverseTransientState.consumeExactOutputProtocolFee(swapContextBase);
                // Match the exact beforeSwap reservation so overfills are delivered to the recipient instead of skimmed.
                minimumOutputAbs += reservedProtocolFeeOutputAmount;
            }
            if (actualOutputAbs < minimumOutputAbs) revert IMemeverseUniswapHook.ExactOutputPartialFill();

            uint256 actualInputAbs = SwapFeeMath.actualInputAmount(delta, params.zeroForOne);

            uint256 exactOutputLpFeeInputAmount = FeeMath.feeOnAmount(actualInputAbs, lpFeeBps);
            if (exactOutputLpFeeInputAmount > 0) {
                uint256 effectiveSupply = _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
                _collectLpFee(
                    poolId, ctx.currencyIn, ctx.inputIsCurrency0, exactOutputLpFeeInputAmount, effectiveSupply
                );
            }

            uint256 unspecifiedDeltaAmount;
            if (ctx.protocolFeeOnInput) {
                uint256 exactOutputProtocolFeeInputAmount = FeeMath.feeOnAmount(actualInputAbs, protocolFeeBps);
                if (exactOutputProtocolFeeInputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyIn, exactOutputProtocolFeeInputAmount, referrer);
                }
                unspecifiedDeltaAmount = exactOutputLpFeeInputAmount + exactOutputProtocolFeeInputAmount;
            } else {
                // Output-side protocol fee was grossed up in beforeSwapLogic; here the hook withholds the realized output fee from the taker.
                if (reservedProtocolFeeOutputAmount > 0) {
                    _collectProtocolFee(poolId, ctx.currencyOut, reservedProtocolFeeOutputAmount, referrer);
                }
                unspecifiedDeltaAmount = exactOutputLpFeeInputAmount;
            }

            // V4 afterSwap contract: a positive unspecifiedDelta means the hook takes that much of the
            // unspecified currency. For exact-output swaps unspecified=input, so returning the input-side
            // fee total (LP + protocol when protocolFeeOnInput) as positive charges it to the taker
            // (user pays more input); the output-side protocol fee was already grossed up in beforeSwap.
            return (IHooks.afterSwap.selector, int128(int256(unspecifiedDeltaAmount)));
        }
        return (IHooks.afterSwap.selector, 0);
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
        // Effect: record the rebate ledger before any external interaction (strict CEI). The treasury take
        // below calls `PoolManager.take`, which executes the fee currency's ERC20 `transfer` code; recording
        // the ledger first means a reentrant call during that transfer cannot observe a stale rebate balance
        // for this swap's referrer. The rebate take (interaction) is the caller's responsibility:
        // `_collectProtocolFee` takes it inline; the beforeSwap merge path folds it into the LP-fee take.
        if (rebate > 0) {
            _memeverseUniswapHookStorage.pendingRebate[referrer][feeCurrency] += rebate;
            emit IMemeverseUniswapHook.ReferralRebateAccrued(referrer, feeCurrency, rebate);
        }
        // Interaction: treasury take. `PoolManager.take` does not invoke a v4 hook callback, but its ERC20
        // transfer still executes currency token code; standard ERC20 fee currencies and atomic rollback bound
        // that interaction. Always emit ProtocolFeeCollected for indexer continuity (toTreasury may be 0 when
        // rebateBps == PROTOCOL_FEE_SHARE_BPS). _takeToTreasury with amount 0 is a no-op take.
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
            // Separate rebate take (afterSwap path + beforeSwap edge). The beforeSwap main path merges
            // this take with the LP-fee take instead (same currency, same recipient address(this)). Rebate
            // custody on the hook proxy: v4 records `take` deltas on msg.sender (the hook under
            // delegatecall), so the take is settled by the hook's beforeSwap specifiedDelta credit that
            // already reserved the full protocol fee. The ledger is written before this caller-side take.
            // `PoolManager.take` does not invoke a v4 hook callback, though its ERC20 transfer executes the
            // currency's token code; standard ERC20 fee currencies and atomic rollback bound that interaction.
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
        // remove path, where LP _beforeTokenTransfer already synced the offset).
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
            uint256 fee0Claimable = FullMath.mulDiv(balance, fee0PerShare - fee0Offset, FeeMath.FEE_GROWTH_Q128);
            uint256 fee1Claimable = FullMath.mulDiv(balance, fee1PerShare - fee1Offset, FeeMath.FEE_GROWTH_Q128);

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
    ///      does not call this quote wrapper. The hot path decodes only `feeBps` and
    ///      `estimatedGrossOutputAmount`.
    function _prepareSwapFee(IDynamicFeeFacet.PrepareSwapFeeParams memory params)
        internal
        returns (uint256 feeBps, uint256 estimatedGrossOutputAmount)
    {
        bytes memory ret = _delegatecallDynamicFeeFacet(abi.encodeCall(IDynamicFeeFacet.prepareSwapFee, (params)));
        return abi.decode(ret, (uint256, uint256));
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
        SwapGuardMath.revertIfNoActiveLiquidityShares(liquidity);
        return 0;
    }

    // -----------------------------------------------------------------
    // Internal pure helpers
    // -----------------------------------------------------------------

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
