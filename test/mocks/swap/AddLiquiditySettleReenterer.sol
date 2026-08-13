// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title AddLiquiditySettleReenterer
/// @notice ERC-777/ERC-1363-style callback token that reenters `poolManager.swap` from the add-liquidity
///         settle window (`MemeverseUniswapHook._addLiquidityCore` → `_settleDeltas` → `CurrencySettler.settle`).
/// @dev Models the ALR-001 adversarial window. `CurrencySettler.settle` pulls the liquidity payment with
///      `transferFrom(payer, manager, amount)` while the PoolManager is unlocked (the add path runs inside
///      `poolManager.unlock`), so a direct `poolManager.swap` from this token's `transferFrom` passes
///      `onlyWhenUnlocked`. The reentrant swap caller is this token contract, not the hook, so real v4
///      executes beforeSwap/afterSwap and the swap follows the public fee path. The Memeverse protocol does
///      not support callback tokens (ERC-777/1363); these cases are defense-in-depth.
///
///      The trigger is gated on `msg.sender == triggerCaller` (the hook address, which is the only caller of
///      the settle `transferFrom`) so this token never fires from arbitrary transfers. The one-shot `armed`
///      guard prevents recursion.
///
///      Outer-settle compensation (same pattern as SettlementSettleReenterer's transfer window): v4 has one
///      global sync snapshot. This token credits the completed outer payment first via
///      `poolManager.settleFor(msg.sender)` — `msg.sender` is the hook, and the hook's own `sync` snapshot is
///      still live at that point — before the inner swap replaces that snapshot while settling its own input
///      currency. The outer `settle()` that follows then measures zero and is a no-op, so the outer
///      add-liquidity unlock closes with every delta settled. When the forged key is the SAME poolId, the
///      reentrant beforeSwap trips the per-pool swap-lifecycle lock now held by `_addLiquidityCore` and
///      reverts `SwapLifecycleReentrant`; this token's try/catch swallows the v4 WrappedError so the outer add
///      still completes, and the tests observe:
///        - `reentryFired == true`        proves the transferFrom callback window was reached.
///        - `reentrySwapExecuted == true` proves a cross-pool public-path swap ran and all its caller deltas
///          were closed (the lock is per-poolId, so a DIFFERENT pool is not blocked).
///        - `reentrySwapExecuted == false` + `reentryRevertSelector == 0x90bfb865` proves the same-pool swap
///          was blocked by the lock (v4 wraps the beforeSwap revert as `CustomRevert.WrappedError`).
contract AddLiquiditySettleReenterer is MockERC20 {
    using PoolIdLibrary for PoolKey;

    error ReentrantTransferFailed();

    IPoolManager public poolManager;
    PoolKey public forgedKey;
    SwapParams public swapParams;
    /// @dev The reentrant swap fires only when the settle `transferFrom` caller is this address (the hook).
    address public triggerCaller;

    bool public armed;
    bool public reentryFired;
    bool public reentrySwapExecuted;
    bytes4 public reentryRevertSelector;
    bytes public reentryRevertReason;

    constructor() MockERC20("AddLiquidityReenterer", "ALR", 18) {}

    /// @notice Arms a single reentrant swap fired from the next `transferFrom` whose caller is `triggerCaller_`.
    /// @param manager_ PoolManager to reenter (the same manager the add-liquidity unlock holds open).
    /// @param key_ Pool key the reentrant swap targets (same poolId for the blocked case, a different pool for
    ///             the cross-pool allowed case).
    /// @param params_ Swap parameters for the reentrant swap.
    /// @param triggerCaller_ Caller address that arms the trigger (the hook address for the settle pull).
    function arm(IPoolManager manager_, PoolKey memory key_, SwapParams memory params_, address triggerCaller_)
        external
    {
        poolManager = manager_;
        forgedKey = key_;
        swapParams = params_;
        triggerCaller = triggerCaller_;
        armed = true;
        reentryFired = false;
        reentrySwapExecuted = false;
        reentryRevertSelector = bytes4(0);
        reentryRevertReason = bytes("");
    }

    /// @notice Transfers tokens, then — when armed and called by the hook — fires one reentrant
    ///         `poolManager.swap` from inside the add-liquidity settle window.
    /// @dev The transfer completes first (post-transfer callback), so the outer payment lands in the manager
    ///      before the outer settle snapshot is consumed. `settleFor(msg.sender)` credits that payment to the
    ///      hook while the hook's own sync snapshot is still live; the inner swap (or its blocked revert) then
    ///      clears the single transient sync slot, making the outer `settle()` a no-op. Same-pool: the lock
    ///      held by `_addLiquidityCore` reverts the inner swap before any balance movement; cross-pool: the
    ///      swap runs and this token closes every returned caller delta before returning. The one-shot `armed`
    ///      guard prevents recursion.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (armed && msg.sender == triggerCaller) {
            armed = false;
            reentryFired = true;
            // v4 has one global sync snapshot. Credit the completed outer payment before the inner swap
            // replaces that snapshot while settling its own input currency.
            poolManager.settleFor(msg.sender);
            _swapAndCloseDeltas();
        }
        return ok;
    }

    /// @dev A real v4 swap books its returned delta to this token because this token is `msg.sender`. Closing
    ///      both currency legs before returning is required for the surrounding unlock to finish. For a
    ///      same-poolId forged key this never reaches delta closure (beforeSwap reverts first on the lifecycle
    ///      lock held by `_addLiquidityCore`); the try/catch records the v4 WrappedError so the outer add
    ///      still completes. hookData is always empty: this mock isolates lifecycle-lock behavior.
    function _swapAndCloseDeltas() internal {
        try poolManager.swap(forgedKey, swapParams, bytes("")) returns (BalanceDelta delta) {
            reentrySwapExecuted = true;
            if (delta.amount0() < 0) _settleNegativeDelta(forgedKey.currency0, uint256(int256(-delta.amount0())));
            if (delta.amount1() < 0) _settleNegativeDelta(forgedKey.currency1, uint256(int256(-delta.amount1())));
            if (delta.amount0() > 0) {
                poolManager.take(forgedKey.currency0, address(this), uint256(int256(delta.amount0())));
            }
            if (delta.amount1() > 0) {
                poolManager.take(forgedKey.currency1, address(this), uint256(int256(delta.amount1())));
            }
        } catch (bytes memory reason) {
            reentryRevertReason = reason;
            if (reason.length >= 4) {
                bytes4 selector;
                assembly ("memory-safe") {
                    selector := mload(add(reason, 0x20))
                }
                reentryRevertSelector = selector;
            }
        }
    }

    function _settleNegativeDelta(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        bool transferred = Currency.unwrap(currency) == address(this)
            ? this.transfer(address(poolManager), amount)
            : IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        if (!transferred) revert ReentrantTransferFailed();
        poolManager.settle();
    }
}
