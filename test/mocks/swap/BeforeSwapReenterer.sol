// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title BeforeSwapReenterer
/// @notice ERC-777/ERC-1363-style callback token that reenters `poolManager.swap` from the `beforeSwap`
///         fee-take window.
/// @dev Models the per-pool lifecycle-reentrancy attack path: during a public swap whose input currency is
///      this token, `SwapFacet.beforeSwapLogic` calls `poolManager.take(currencyIn, address(hook), feeAmount)`;
///      PoolManager then executes `currencyIn.transfer(hook, feeAmount)`, and this token's `transfer` fires
///      one reentrant `poolManager.swap` against a configured (forged) key. When the forged key is the SAME
///      poolId as the outer swap, the reentrant beforeSwap trips the per-pool swap-lifecycle lock and reverts
///      `SwapLifecycleReentrant`; when it is a DIFFERENT pool, the lock must NOT trip (the lock is per-poolId).
///      The reentrant swap caller is this token contract (not the hook), so v4 runs the normal beforeSwap/
///      afterSwap public path.
///
///      The trigger is gated on `to == triggerRecipient` (the hook address) so this token only fires from the
///      beforeSwap take, not from arbitrary transfers. The one-shot `armed` guard prevents recursion.
///      Empty hookData is intentional: these tests isolate the lifecycle lock, not referral rebate accrual.
contract BeforeSwapReenterer is MockERC20 {
    error ReentrantTransferFailed();

    IPoolManager public poolManager;
    PoolKey public forgedKey;
    SwapParams public swapParams;
    /// @dev The reentrant swap fires only when `transfer.to == triggerRecipient` (the hook address, since the
    ///      beforeSwap take transfers currencyIn to address(hook)).
    address public triggerRecipient;

    bool public armed;

    constructor() MockERC20("BeforeSwapReenterer", "BSR", 18) {}

    /// @notice Arms a single reentrant swap fired from the next `transfer(to == triggerRecipient)`.
    /// @param manager_ PoolManager to reenter (the same manager the outer swap unlocks).
    /// @param key_ Pool key the reentrant swap targets (same poolId for the blocked case, different for cross-pool).
    /// @param params_ Exact-input swap params for the reentrant swap.
    /// @param triggerRecipient_ Recipient address that arms the trigger (the hook address for the beforeSwap take).
    function arm(IPoolManager manager_, PoolKey memory key_, SwapParams memory params_, address triggerRecipient_)
        external
    {
        poolManager = manager_;
        forgedKey = key_;
        swapParams = params_;
        triggerRecipient = triggerRecipient_;
        armed = true;
    }

    /// @notice Transfers tokens, then — when armed and `to == triggerRecipient` — fires one reentrant
    ///         `poolManager.swap` from inside the outer swap's beforeSwap fee-take window.
    /// @dev The transfer completes first (ERC-777 `tokensReceived`-style post-transfer callback), then the
    ///      reentrant swap runs synchronously. The reentrant swap's revert propagates out through the take and
    ///      reverts the whole outer swap atomically — matching the on-chain protection an attacker observes.
    ///      The same-poolId case reverts `SwapLifecycleReentrant`; the cross-pool case reaches beforeSwap (the
    ///      per-poolId lock does not trip) and reverts later only on unrelated v4 delta accounting. The one-shot
    ///      `armed` guard prevents recursion.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (armed && to == triggerRecipient) {
            armed = false;
            _swapAndCloseDeltas();
        }
        return ok;
    }

    /// @dev A real v4 swap books its returned delta to this token because this token is `msg.sender`. Closing
    ///      both currency legs before returning is required for the surrounding beforeSwap take to finish. For a
    ///      same-poolId forged key this never reaches delta closure (beforeSwap reverts first on the lifecycle lock).
    ///      hookData is always empty: this mock isolates lifecycle-lock behavior, not referral paths.
    function _swapAndCloseDeltas() internal {
        BalanceDelta delta = poolManager.swap(forgedKey, swapParams, bytes(""));

        if (delta.amount0() < 0) _settleNegativeDelta(forgedKey.currency0, uint256(int256(-delta.amount0())));
        if (delta.amount1() < 0) _settleNegativeDelta(forgedKey.currency1, uint256(int256(-delta.amount1())));
        if (delta.amount0() > 0) {
            poolManager.take(forgedKey.currency0, address(this), uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            poolManager.take(forgedKey.currency1, address(this), uint256(int256(delta.amount1())));
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
