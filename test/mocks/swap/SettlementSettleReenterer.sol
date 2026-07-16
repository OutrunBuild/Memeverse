// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title SettlementSettleReenterer
/// @notice ERC-777/ERC-1363-style callback token that reenters `poolManager.swap` from two settlement windows.
/// @dev Models the SECR-001 adversarial windows. The settlement entry has two ERC20 call sites a callback
///      token can hijack:
///      - `transferFrom` (Phase 1/2, BEFORE `poolManager.unlock`): reenters via `poolManager.unlock` + swap.
///      - `transfer` (inside `CurrencySettler.settle`, DURING the unlock, v4 lock open): reenters via a
///        direct `poolManager.swap`. A token whose `transfer` fires a callback can reenter here.
///
///      Window taxonomy (accurate): the settlement entry makes two ERC20 call sites — `transferFrom`
///      (Phase 1/2, runs BEFORE `poolManager.unlock`) and `transfer` (inside `CurrencySettler.settle`,
///      runs DURING the unlock, with the v4 lock open). The v4 `onlyWhenUnlocked` modifier blocks a
///      direct `poolManager.swap` from a `transferFrom` callback (the lock is not yet open), but does
///      NOT block `poolManager.unlock(...)` from there — a callback token could open its own unlock and
///      swap inside it. In either window the reentrant swap caller is this token contract, not the hook,
///      so real v4 executes beforeSwap/afterSwap and the swap follows the public fee path. The Memeverse
///      protocol does not support callback tokens (ERC-777/1363); these cases are defense-in-depth.
///
///      The transfer-window arm fires ONLY when `to == address(poolManager)`, matching the exact
///      `CurrencySettler.settle` call site. The independent transferFrom-window arm fires once from the
///      settlement entry's first input pull.
///
///      The legitimate settlement swap is a hook self-call, so v4 skips its swap callbacks. This token's
///      reentrant swap is a non-hook call, so v4 executes the public callback path. A settle-transfer reentry
///      succeeds only after this token closes every caller delta returned by the real PoolManager. Tests observe:
///        - `reentryFired == true`        proves the `transfer(to == manager)` callback window was reached.
///        - `reentrySwapExecuted == true` proves the public-path swap ran and all caller deltas were closed.
///      The one-shot `armed` guard prevents recursion.
contract SettlementSettleReenterer is MockERC20 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error ReentrantTransferFailed();
    error UnauthorizedUnlockCallback();

    IPoolManager public poolManager;
    PoolKey public forgedKey;
    SwapParams public swapParams;
    /// @dev HookData forwarded to the reentrant swap's `beforeSwap`/`afterSwap`. Default empty; the rebate
    ///      PoC arms it with a 20-byte referrer so the reentrant public swap accrues referral rebate.
    bytes public forgedHookData;

    bool public armed;
    /// @dev Independent arm for the `transferFrom` window so the existing `transfer`-window scenarios are
    ///      not disturbed: `arm`/`armWithHookData` only set `armed` (transfer window); the transferFrom
    ///      PoC sets `armedTransferFrom`.
    bool public armedTransferFrom;
    bool public reentryFired;
    bool public reentrySwapExecuted;
    bytes4 public reentryRevertSelector;
    uint160 public reentryPreSqrtPriceX96;
    uint160 public reentryPostSqrtPriceX96;

    constructor() MockERC20("SettleReenterer", "SRE", 18) {}

    /// @notice Arms a single reentrant swap fired from the next `transfer(to == poolManager)`.
    /// @param manager_ PoolManager to reenter (the same manager the settlement unlocks).
    /// @param key_ Pool key the reentrant swap will target (the "forged" public-swap key).
    /// @param params_ Swap parameters for the reentrant swap (exact-input, negative amountSpecified).
    function arm(IPoolManager manager_, PoolKey memory key_, SwapParams memory params_) external {
        poolManager = manager_;
        forgedKey = key_;
        swapParams = params_;
        forgedHookData = bytes("");
        armed = true;
        _resetReentryOutcome();
    }

    /// @notice Arms a single reentrant swap with explicit hookData (e.g. a 20-byte referrer) for rebate PoCs.
    function armWithHookData(
        IPoolManager manager_,
        PoolKey memory key_,
        SwapParams memory params_,
        bytes memory hookData_
    ) external {
        poolManager = manager_;
        forgedKey = key_;
        swapParams = params_;
        forgedHookData = hookData_;
        armed = true;
        _resetReentryOutcome();
    }

    /// @notice Arms a single reentrant swap fired from the next `transferFrom` (the Phase 1/2 window that
    ///         runs BEFORE `poolManager.unlock`). The reentrant swap opens its own unlock and swaps inside
    ///         the callback, since a direct `poolManager.swap` would revert `ManagerLocked`.
    function armTransferFrom(IPoolManager manager_, PoolKey memory key_, SwapParams memory params_) external {
        poolManager = manager_;
        forgedKey = key_;
        swapParams = params_;
        forgedHookData = bytes("");
        armedTransferFrom = true;
        _resetReentryOutcome();
    }

    /// @notice Transfers tokens, then — when armed and the recipient is the PoolManager — fires one reentrant
    ///         `poolManager.swap` from inside the settlement's `CurrencySettler.settle` window.
    /// @dev The transfer completes first (ERC-777 `tokensReceived`-style post-transfer callback), then the
    ///      reentry runs synchronously. Any swap or delta-closure failure reverts the surrounding settlement;
    ///      `reentrySwapExecuted` becomes true only after every returned caller delta is closed. The one-shot
    ///      `armed` guard prevents recursion.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (armed && to == address(poolManager)) {
            armed = false;
            reentryFired = true;
            // v4 has one global sync snapshot. Credit the completed outer payment before the inner swap
            // replaces that snapshot while settling its own input currency.
            poolManager.settleFor(msg.sender);
            _swapAndCloseDeltas();
            reentrySwapExecuted = true;
        }
        return ok;
    }

    /// @notice transferFrom-callback arm: reenters via `poolManager.unlock` + swap (the transferFrom window
    ///         runs BEFORE `unlock`, so a direct `poolManager.swap` reverts `ManagerLocked`; opening a fresh
    ///         unlock and swapping inside its callback is the reachable path).
    /// @dev Fires from the first `transferFrom` the settlement entry makes. The reentrant swap targets the
    ///      forged public key and is called by this token contract, so v4 executes normal swap callbacks.
    ///      `reentrySwapExecuted` is set only if that swap completes; a public-block revert leaves it false and
    ///      records its selector so the negative-path test proves the intended guard caused the rejection.
    ///      The one-shot `armedTransferFrom` guard prevents recursion.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (armedTransferFrom) {
            armedTransferFrom = false;
            reentryFired = true;
            // Open a fresh unlock so the inner `poolManager.swap` passes `onlyWhenUnlocked`. Mark it complete
            // only after the manager accepts the callback with every delta settled.
            try poolManager.unlock("") returns (bytes memory result) {
                reentrySwapExecuted = abi.decode(result, (bool));
            } catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 selector;
                    assembly ("memory-safe") {
                        selector := mload(add(reason, 0x20))
                    }
                    reentryRevertSelector = selector;
                }
            }
        }
        return ok;
    }

    /// @notice PoolManager unlock callback for the transferFrom-window reentry: completes one public swap and
    ///         settles every resulting delta before returning.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlockCallback();
        _swapAndCloseDeltas();
        return abi.encode(true);
    }

    /// @dev A real v4 swap books its returned delta to this token because this token is `msg.sender`.
    ///      Closing both currency legs before returning is required for the surrounding unlock to finish.
    function _swapAndCloseDeltas() internal {
        (reentryPreSqrtPriceX96,,,) = poolManager.getSlot0(forgedKey.toId());
        BalanceDelta delta = poolManager.swap(forgedKey, swapParams, forgedHookData);
        (reentryPostSqrtPriceX96,,,) = poolManager.getSlot0(forgedKey.toId());

        if (delta.amount0() < 0) _settleNegativeDelta(forgedKey.currency0, uint256(int256(-delta.amount0())));
        if (delta.amount1() < 0) _settleNegativeDelta(forgedKey.currency1, uint256(int256(-delta.amount1())));
        if (delta.amount0() > 0) {
            poolManager.take(forgedKey.currency0, address(this), uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            poolManager.take(forgedKey.currency1, address(this), uint256(int256(delta.amount1())));
        }
    }

    function _resetReentryOutcome() internal {
        reentryFired = false;
        reentrySwapExecuted = false;
        reentryRevertSelector = bytes4(0);
        reentryPreSqrtPriceX96 = 0;
        reentryPostSqrtPriceX96 = 0;
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
