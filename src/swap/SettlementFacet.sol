// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {ISettlementFacet} from "./interfaces/ISettlementFacet.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {MemeverseTransientState} from "./libraries/MemeverseTransientState.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {SwapFeeMath} from "./libraries/SwapFeeMath.sol";
import {SwapGuardMath} from "./libraries/SwapGuardMath.sol";
import {DynamicFeeMath} from "./libraries/DynamicFeeMath.sol";
import {MemeverseSwapFeeBase} from "./MemeverseSwapFeeBase.sol";

/// @title SettlementFacet
/// @notice Diamond facet holding the preorder settlement swap entry plus the settlement-branch
///         PoolManager unlock callback logic.
/// @dev This facet is the delegatecall target for two settlement surfaces:
///      1. `executeSettlementLogic` — the entry the Router (`MemeverseUniswapHookUpgradeable`) dispatches in response
///         to a launcher preorder-settlement call. It charges input-side fees, funds the net swap input,
///         opens a PoolManager `unlock`, and reconciles the callback-reported fee against the hook's own rate.
///      2. `settlementUnlockCallback` — the internal swap/settle/take body that the Router's `unlockCallback`
///         dispatches into after decoding the explicit settlement payload kind.
///
///      Both functions execute in the Router's (hook proxy) storage context via delegatecall, so
///      `address(this) == hook` and all reads/writes land in the shared hook namespace. `onlyViaRouter`
///      reverts on a direct CALL: under a direct CALL `address(this)` is the facet's own address, which
///      equals the facet's immutable `__self`, so the guard trips (under delegatecall `address(this)` is
///      the hook proxy, ≠ `__self`).
///
///      Storage layout FROZEN — shared ERC-7201 namespace; field order fixed, append-only.
///      See `IMemeverseHookStorage.MemeverseUniswapHookStorage` for the slot-derivation rationale.
///
///      The settlement swap is a hook self-call into PoolManager, so Uniswap v4 skips its beforeSwap and
///      afterSwap callbacks. Callback-token reentrant swaps originate from the token contract, so they retain
///      the normal public callback and fee path.
///      Net swap input is held by the hook proxy and settled from `address(this)` during the Router's unlock
///      callback. Realized dynamic-fee state updates delegate to `DynamicFeeFacet`, while
///      `DynamicFeeMath.refreshVolatilityAnchorAndCarry` refreshes the pre-swap anchor directly so the
///      post-swap update measures price impact against the correct anchor.
// solhint-disable-next-line gas-small-strings
contract SettlementFacet layout at erc7201("outrun.storage.MemeverseUniswapHook")
    is
    MemeverseSwapFeeBase,
    ISettlementFacet,
    ImmutableState
{
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for int128;

    // Fixed preorder settlement fee. LP and protocol shares are derived via `FeeMath.splitFeeBps`.
    uint24 internal constant PREORDER_SETTLEMENT_FEE_BPS = 100;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param poolManager_ PoolManager shared with the hook (bound as immutable implementation bytecode state).
    ///      Trailing underscore resolves the clash with the inherited `ImmutableState.poolManager` immutable.
    constructor(IPoolManager poolManager_) ImmutableState(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
    }

    // -----------------------------------------------------------------
    // Settlement entry
    // -----------------------------------------------------------------

    /// @inheritdoc ISettlementFacet
    /// @dev - Net swap input is pulled to the hook proxy (`transferFrom(msg.sender, address(this))`). The
    ///        Router-owned `unlockCallback` then settles the input delta from the hook's own balance.
    ///      - The settlement swap runs inside `poolManager.unlock` dispatched by the Router's
    ///        `unlockCallback`, which calls `settlementUnlockCallback` (this facet) on the
    ///        settlement branch of the callback payload.
    ///      `nonReentrant` and the launcher-only caller gate live on the Router entry that wraps this
    ///      delegatecall; this facet body intentionally carries neither.
    function executeSettlementLogic(IMemeverseUniswapHook.PreorderSettlementParams calldata params)
        external
        override
        onlyViaRouter
        returns (BalanceDelta delta)
    {
        // The PoolKey must point at this hook so the PoolManager recognizes the swap as a hook self-call and
        // skips public swap callbacks. The launcher already constructs this key; this is a fail-fast backstop.
        if (address(params.key.hooks) != address(this)) revert IMemeverseUniswapHook.HookAddressMismatch();

        PoolId poolId = params.key.toId();
        (uint160 entrySqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (_memeverseUniswapHookStorage.poolInfo[poolId].liquidityToken == address(0) || entrySqrtPriceX96 == 0) {
            revert IMemeverseUniswapHook.PoolNotInitialized();
        }
        // amountSpecified >= 0: reject non-negative (zero or exact-output) settlement requests.
        if (params.params.amountSpecified >= 0) revert IMemeverseUniswapHook.ZeroValue();
        uint256 effectiveSupply = _activeLpSupplyForSettlement(poolId);

        // Cache treasury once at the entry (cold) and reuse it for the input-side fee charge, the
        // settlement callback data, and the output-side emit. Safe to cache: `setTreasury` is
        // onlyOwner and this entry is launcher-initiated (msg.sender == launcher, not owner), so no
        // path in a settlement tx can re-point treasury mid-flight.
        address treasury_ = _memeverseUniswapHookStorage.treasury;

        // Phase 1 — charge input-side fees up front. LP fee is pulled from the launcher and credited to LPs;
        // the input-side protocol fee (when `protocolFeeOnInput` — input registered, or neither leg
        // registered / ordinary pool) is pulled straight to treasury. The remainder (netInputAmount) is
        // what actually enters the pool.
        uint256 grossInputAmount = uint256(-int256(params.params.amountSpecified));
        SwapFeeMath.SwapFeeContext memory ctx = _resolveSwapFeeContext(params.key, params.params.zeroForOne);

        // The entry price seeds the pre-swap volatility anchor. PIF (price move) uses the callback's swap-adjacent price below.
        DynamicFeeMath.refreshVolatilityAnchorAndCarry(
            _memeverseUniswapHookStorage.dynamicFeeState[poolId], entrySqrtPriceX96
        );

        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(PREORDER_SETTLEMENT_FEE_BPS);
        (uint256 lpFeeInputAmount, uint256 protocolFeeInputAmount) =
            _exactInputFeeAmounts(grossInputAmount, lpFeeBps, protocolFeeBps, ctx.protocolFeeOnInput);
        uint256 netInputAmount = grossInputAmount - lpFeeInputAmount - protocolFeeInputAmount;
        // Defense-in-depth backstop: under the fixed 100 bps settlement fee, the 65/35 split and the
        // exact-input guarantee (grossInputAmount >= 1) make netInputAmount mathematically >= 1, so this
        // revert is currently unreachable. Retained to fail-fast if a future fee-constant change could
        // consume the entire gross input. Mirrors `_accrueLpFee`'s unreachable-but-kept backstop pattern.
        if (netInputAmount == 0) revert IMemeverseUniswapHook.ZeroValue();

        // Hold the per-pool swap-lifecycle lock across both transferFrom calls, the PoolManager unlock,
        // and `_updateAfterSwap`. This prevents callback tokens from reentering the same pool during any
        // settlement phase. The settlement swap is a hook self-call, so v4 skips beforeSwap/afterSwap and
        // this entry owns the complete acquire/release lifecycle without self-deadlocking.
        if (MemeverseTransientState.acquireSwapLifecycleLock(poolId)) {
            revert IMemeverseUniswapHook.SwapLifecycleReentrant();
        }

        // Pull the input-side fees from the launcher (payer == msg.sender == launcher at the Router entry).
        _collectPreorderSettlementInputFees(
            poolId, ctx, lpFeeInputAmount, protocolFeeInputAmount, effectiveSupply, treasury_
        );

        // Phase 2 — fund the net swap input AND pull the LP fee to the hook proxy in a single transferFrom
        // (same payer msg.sender, same input currency, same destination hook proxy as the LP fee accrued in
        // Phase 1), saving one ERC20 transferFrom per settlement because both amounts share the payer,
        // currency, and hook-proxy destination. The Router owns `unlockCallback` and routes the settlement
        // payload back into `settlementUnlockCallback` below; net input remains on the hook proxy until then.
        SwapParams memory settlementParams = params.params;
        settlementParams.amountSpecified = -int256(netInputAmount);
        if (!IERC20Minimal(Currency.unwrap(ctx.currencyIn))
                .transferFrom(msg.sender, address(this), netInputAmount + lpFeeInputAmount)) {
            revert IMemeverseUniswapHook.ERC20TransferFailed();
        }

        bytes memory resultBytes = poolManager.unlock(
            abi.encode(
                IMemeverseUniswapHook.UnlockCallbackKind.Settlement,
                ISettlementFacet.SettlementCallbackData({
                    recipient: params.recipient,
                    treasury: treasury_,
                    key: params.key,
                    swapParams: settlementParams,
                    protocolFeeOnInput: ctx.protocolFeeOnInput
                })
            )
        );

        ISettlementFacet.SettlementResult memory result = abi.decode(resultBytes, (ISettlementFacet.SettlementResult));

        // Phase 3 — refresh realized dynamic fee state with the swap delta, then reconcile the
        // output-side protocol fee against the hook's own rate. The output fee is derived here from
        // `result.swapDelta` (which mirrors the PoolManager swap return), not trusted from a separate
        // fee report. The owner-selected facet remains within the Router trust domain. Input-side charging
        // resolves to 0 here.
        _updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
                poolId: poolId,
                delta: result.swapDelta,
                // `trader: msg.sender` (== launcher via onlyLauncher) intentionally differs from SwapFacet's Hook-captured session principal:
                // in SwapFacet `msg.sender` is the PoolManager (onlyPoolManager, preserved under delegatecall), not the trader.
                // Do NOT "unify" — `addressBatchState` would silently re-key. The two contexts have different `msg.sender` values by design.
                trader: msg.sender,
                preSqrtPriceX96: result.preSwapSqrtPriceX96,
                postSqrtPriceX96: result.postSwapSqrtPriceX96
            })
        );

        uint256 expectedProtocolFeeOutputAmount = ctx.protocolFeeOnInput
            ? 0
            : FeeMath.feeOnAmount(
                SwapFeeMath.actualOutputAmount(result.swapDelta, params.params.zeroForOne), protocolFeeBps
            );
        if (result.protocolFeeOutputAmount != expectedProtocolFeeOutputAmount) {
            revert IMemeverseUniswapHook.PreorderSettlementFeeMismatch();
        }
        if (expectedProtocolFeeOutputAmount > 0) {
            Currency outputCurrency = params.params.zeroForOne ? params.key.currency1 : params.key.currency0;
            emit IMemeverseUniswapHook.ProtocolFeeCollected(
                poolId, outputCurrency, treasury_, expectedProtocolFeeOutputAmount, block.number
            );
        }

        delta = result.adjustedDelta;
        if (SwapFeeMath.actualInputAmount(delta, params.params.zeroForOne) != netInputAmount) {
            revert IMemeverseUniswapHook.ExactInputPartialFill();
        }

        // Release the lock acquired before the Phase 1 transferFrom; the full settlement window
        // (transferFrom + unlock swap/settle/take + Phase 3 _updateAfterSwap) is now closed. Transient storage
        // auto-clears on revert, so any revert path leaves no stale lock.
        MemeverseTransientState.releaseSwapLifecycleLock(poolId);
    }

    // -----------------------------------------------------------------
    // Settlement unlock callback body
    // -----------------------------------------------------------------

    /// @inheritdoc ISettlementFacet
    /// @dev This is the delegatecall target the Router's `IUnlockCallback.unlockCallback` dispatches into
    ///      after validating the explicit callback kind and decoding the typed settlement payload. This facet
    ///      deliberately does NOT implement `IUnlockCallback` itself — only the Router can be the
    ///      PoolManager unlock callback target, since `unlock` reenters the original caller.
    ///      The settle source is the hook proxy (`address(this)`), which holds the net input pulled in
    ///      `executeSettlementLogic`; `CurrencySettler.settle` therefore transfers from the hook's balance.
    ///      The protocol output fee is `take`n to treasury and the net output is `take`n to the recipient.
    function settlementUnlockCallback(ISettlementFacet.SettlementCallbackData calldata data)
        external
        override
        onlyViaRouter
        returns (ISettlementFacet.SettlementResult memory result)
    {
        // The Router reaches this facet from `unlockCallback` with PoolManager as `msg.sender`; enforce
        // that call boundary again inside the facet.
        if (msg.sender != address(poolManager)) revert IMemeverseUniswapHook.Unauthorized();

        // Read the pre-swap price right before the settlement swap so PIF measures this swap's price movement
        // from a swap-adjacent anchor (the entry price seeds the volatility anchor; this read seeds realized PIF).
        // Invariant: the lifecycle lock has been held since before the input transfers, so no path between the
        // entry read (`executeSettlementLogic`) and this swap can move the pool price — this read returns the
        // same value as the entry read. The re-read is a forward-compatible guard: if a future change inserts a
        // price-moving step before the swap, this still captures the correct PIF anchor instead of reusing a stale
        // entry price. Do NOT collapse the two reads into one passed across the unlock boundary — that couples the
        // callback ABI to an unenforced invariant and silently breaks PIF if it ever slips.
        // Cache `toId()` once: `PoolKey.toId()` is pure (keccak256 over the in-memory struct), so the two reads
        // share one hash; `poolManager.swap` recomputes it internally (unavoidable). Mirrors `executeSettlementLogic`.
        PoolId poolId = data.key.toId();
        (uint160 preSwapSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        BalanceDelta swapDelta = poolManager.swap(data.key, data.swapParams, bytes(""));
        (uint160 postSwapSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        int128 amount0 = swapDelta.amount0();
        int128 amount1 = swapDelta.amount1();

        // Settle the input leg (negative delta) from the hook proxy's own balance. Under delegatecall
        // `address(this)` is the hook, which holds the net input pulled in executeSettlementLogic, so
        // `CurrencySettler.settle` transfers from the hook's own ERC20 balance into the PoolManager.
        if (amount0 < 0) {
            data.key.currency0.settle(poolManager, address(this), uint256((-amount0).toUint128()), false);
        }
        if (amount1 < 0) {
            data.key.currency1.settle(poolManager, address(this), uint256((-amount1).toUint128()), false);
        }

        // Output-side protocol fee: when the protocol fee is on the output currency, deduct it from the
        // gross output and `take` it straight to treasury. The remainder is paid to the recipient below.
        uint256 protocolFeeOutputAmount;
        if (!data.protocolFeeOnInput) {
            uint256 grossOutputAmount = SwapFeeMath.actualOutputAmount(swapDelta, data.swapParams.zeroForOne);
            // PREORDER settlement fee is fixed; protocol half is constant — recompute instead of unlocking it.
            uint256 protocolFeeBps = FeeMath.protocolFeeBps(PREORDER_SETTLEMENT_FEE_BPS);
            protocolFeeOutputAmount = FeeMath.feeOnAmount(grossOutputAmount, protocolFeeBps);
            // Skip the zero-amount take: feeOnAmount rounds down, so a small gross output can yield
            // protocolFeeOutputAmount == 0. A zero take still calls transfer(to, 0) inside PoolManager.take,
            // which reverts for non-compliant ERC20s returning false on zero-value transfers — same guard
            // as SwapFacet._takeToTreasury. The subtraction block below already checks > 0.
            if (protocolFeeOutputAmount > 0) {
                Currency outputCurrency = data.swapParams.zeroForOne ? data.key.currency1 : data.key.currency0;
                poolManager.take(outputCurrency, data.treasury, protocolFeeOutputAmount);
            }
        }

        uint256 takeAmount0 = amount0 > 0 ? uint256(amount0.toUint128()) : 0;
        uint256 takeAmount1 = amount1 > 0 ? uint256(amount1.toUint128()) : 0;
        // No underflow: `protocolFeeOutputAmount = grossOutputAmount * bps / 10_000` where
        // `bps = FeeMath.protocolFeeBps(PREORDER_SETTLEMENT_FEE_BPS)` is a fixed const <= 10_000, and the
        // output-leg `takeAmount` below equals `grossOutputAmount` (same swapDelta leg). So fee <= gross =
        // takeAmount; the input leg is never subtracted here.
        if (protocolFeeOutputAmount > 0) {
            if (data.swapParams.zeroForOne) {
                takeAmount1 -= protocolFeeOutputAmount;
            } else {
                takeAmount0 -= protocolFeeOutputAmount;
            }
        }

        if (takeAmount0 > 0) poolManager.take(data.key.currency0, data.recipient, takeAmount0);
        if (takeAmount1 > 0) poolManager.take(data.key.currency1, data.recipient, takeAmount1);

        int128 adjustedAmount0 = amount0 > 0 ? int128(int256(takeAmount0)) : amount0;
        int128 adjustedAmount1 = amount1 > 0 ? int128(int256(takeAmount1)) : amount1;
        result = ISettlementFacet.SettlementResult({
            adjustedDelta: toBalanceDelta(adjustedAmount0, adjustedAmount1),
            swapDelta: swapDelta,
            preSwapSqrtPriceX96: preSwapSqrtPriceX96,
            postSwapSqrtPriceX96: postSwapSqrtPriceX96,
            protocolFeeOutputAmount: protocolFeeOutputAmount
        });
    }

    // -----------------------------------------------------------------
    // Settlement fee context + input-side fee charge
    // -----------------------------------------------------------------

    /// @dev Under delegatecall the payer is `msg.sender` at the Router entry (the launcher), so input-side
    ///      fees are pulled from `msg.sender` directly. LP fee is
    ///      credited per-share via `_accrueLpFee` (bookkeeping only — its token pull is coalesced with the
    ///      net swap input in `executeSettlementLogic`); protocol fee is pulled straight to treasury.
    ///      No PoolManager `take` is used here (unlike the public-swap path), because settlement charges
    ///      fees up front via direct ERC20 transfer rather than via v4 deltas.
    function _collectPreorderSettlementInputFees(
        PoolId poolId,
        SwapFeeMath.SwapFeeContext memory ctx,
        uint256 lpFeeInputAmount,
        uint256 protocolFeeInputAmount,
        uint256 effectiveSupply,
        address treasury_
    ) internal {
        // CEI: all effects (LP fee credit + protocol fee emit) before any external transfer, so no
        // transferFrom (interaction) precedes an emit (effect) — closes the cross-block reentrancy-events
        // window. transferFrom failure reverts the whole tx, rolling back effects; nonReentrant on the
        // Router entry is belt-and-braces.
        if (lpFeeInputAmount > 0) {
            if (effectiveSupply == 0) revert IMemeverseUniswapHook.NoActiveLiquidityShares();
            _accrueLpFee(poolId, ctx.currencyIn, ctx.inputIsCurrency0, lpFeeInputAmount, effectiveSupply);
        }
        if (protocolFeeInputAmount > 0) {
            emit IMemeverseUniswapHook.ProtocolFeeCollected(
                poolId, ctx.currencyIn, treasury_, protocolFeeInputAmount, block.number
            );
        }
        // Interactions last: pull the protocol fee straight to treasury. The LP fee token pull is
        // deliberately NOT done here — it is coalesced with the net swap input pull in
        // `executeSettlementLogic` (same payer msg.sender, same input currency, same destination hook
        // proxy), so one transferFrom handles both amounts. See executeSettlementLogic Phase 2.
        if (protocolFeeInputAmount > 0) {
            if (!IERC20Minimal(Currency.unwrap(ctx.currencyIn))
                    .transferFrom(msg.sender, treasury_, protocolFeeInputAmount)) {
                revert IMemeverseUniswapHook.ERC20TransferFailed();
            }
        }
    }

    /// @dev Resolves the effective LP supply for the settlement path and gates orphaned liquidity. A cached
    ///      supply is returned directly; otherwise PoolManager liquidity determines whether the cache is
    ///      stale or the pool is drained. `executeSettlementLogic` rejects non-negative input before this call.
    function _activeLpSupplyForSettlement(PoolId poolId) internal view returns (uint256 effectiveSupply) {
        effectiveSupply = _memeverseUniswapHookStorage.cachedLpTotalSupply[poolId];
        if (effectiveSupply != 0) return effectiveSupply;
        // cached == 0: orphaned-liquidity gate (liquidity > 0 reverts; drained pool liquidity == 0 falls
        // through to return 0 — the caller's per-share divide guard catches the empty-pool case).
        SwapGuardMath.revertIfOrphanedLiquidity(poolManager.getLiquidity(poolId));
        return 0;
    }
}
