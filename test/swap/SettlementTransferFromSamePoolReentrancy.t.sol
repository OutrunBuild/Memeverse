// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {SettlementSettleReenterer} from "../mocks/swap/SettlementSettleReenterer.sol";

/// @title SettlementTransferFromSamePoolReentrancyTest
/// @notice A callback-token same-pool reentry during the settlement transferFrom window
///         (Phase 1/2, BEFORE `poolManager.unlock`) is blocked by the per-pool swap-lifecycle lock.
/// @dev The lock is acquired at the top of `executeSettlementLogic`, so it spans Phase 1 transferFrom through
///      Phase 3 `_updateAfterSwap`.
///
///      Unlike `SettlementSamePoolReentrancyTest`, the
///      transferFrom-window reenterer wraps its nested `poolManager.unlock("")` + swap in a try/catch, so the
///      inner `SwapLifecycleReentrant` revert is swallowed by the reenterer rather than bubbling into the outer
///      settlement. This test expects the inner reentry to be blocked while the outer settlement completes.
///
///      Assertions:
///        - `reentryFired == true`                       the transferFrom callback fired.
///        - `reentrySwapExecuted == false`               the inner same-pool swap was blocked by the lock.
///        - `reentryRevertSelector == 0x90bfb865`        v4 wraps the inner beforeSwap `SwapLifecycleReentrant`
///          as `CustomRevert.WrappedError` (selector 0x90bfb865); the reenterer's try/catch on
///          `poolManager.unlock("")` captures that wrapped revert on the unlock-return path.
///        - Outer settlement completes: payer debited, treasury fee paid, recipient receives output.
///
///      The inner swap is a public-path call (called by the token, not the hook), so v4 runs beforeSwap and
///      the lock trip surfaces as a v4 `WrappedError` rather than the raw selector. The cross-pool
///      transferFrom-window case (inner completes) is covered by `SettlementReentrancyRealV4Test`.
///
///      Does NOT inherit any upgradeable production contract — `HookStorageHelper` is a standalone Test helper
///      and all hook interaction is via the external `MemeverseUniswapHook` interface.
contract SettlementTransferFromSamePoolReentrancyTest is Test, HookStorageHelper {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Selector of v4's `CustomRevert.WrappedError(address,bytes4,bytes,bytes)` — the ERC-7751 wrapper v4 emits
    // when a hook's beforeSwap/afterSwap revert bubbles back through PoolManager.swap. The transferFrom-window
    // reenterer's try/catch on `poolManager.unlock("")` captures this selector on the unlock-return path.
    bytes4 internal constant _WRAPPED_ERROR_SELECTOR = bytes4(0x90bfb865);

    IPoolManager internal manager;
    MemeverseUniswapHook internal hook;
    SettlementSettleReenterer internal callbackToken;
    MockERC20 internal token1;
    PoolKey internal settlementPoolKey;
    bool internal settlementZeroForOne;
    address internal treasury = address(0xFEE);

    function setUp() public {
        manager = deployRealPoolManager();
        token1 = new MockERC20("Token1", "TK1", 18);
        // The callback token is BOTH the settlement pool's input currency AND the reentry caller. Its
        // transferFrom callback fires inside the Phase 1/2 pull window (before `poolManager.unlock`).
        callbackToken = new SettlementSettleReenterer();

        token1.mint(address(this), 1_000_000 ether);
        callbackToken.mint(address(this), 1_000_000 ether);
        // The callback token is the caller of the inner swap and must pay its own reentrant input leg.
        callbackToken.mint(address(callbackToken), 100 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHook(hookProxy);
        hook.setPoolInitializer(address(this));

        token1.approve(address(hook), type(uint256).max);
        callbackToken.approve(address(hook), type(uint256).max);

        settlementPoolKey = _dynamicPoolKey(address(callbackToken), address(token1));
        settlementZeroForOne = Currency.unwrap(settlementPoolKey.currency0) == address(callbackToken);

        _initializeAndFundPool(settlementPoolKey);

        // Register callbackToken as a protocol-fee token so the input leg deterministically carries the
        // fee (registration selects the leg; the input-side fee would also fire for an ordinary pool).
        hook.setProtocolFeeCurrency(Currency.wrap(address(callbackToken)), true);
        vm.warp(block.timestamp + 900);
    }

    /// @notice A transferFrom-window same-pool reentry is blocked by the per-pool lock, and the outer settlement
    ///         completes normally because the reenterer swallows the inner revert in its own try/catch.
    /// @dev `armTransferFrom` sets the forged key to the SAME settlement pool, so the reenterer opens a nested
    ///      `poolManager.unlock("")` from inside the Phase 1 transferFrom and swaps on THIS poolId. The outer
    ///      settlement already holds the lock acquired at the top of `executeSettlementLogic`, so the
    ///      inner public-path swap trips `SwapLifecycleReentrant` in `beforeSwapLogic`; v4 wraps that as
    ///      `WrappedError` (0x90bfb865) and the reenterer's try/catch records it. The swallow means the outer
    ///      transferFrom returns true and the settlement continues to completion.
    function test_TransferFromSamePoolReentryBlockedOuterSettlementCompletes() public {
        callbackToken.armTransferFrom(manager, settlementPoolKey, _reentrySwapParams());

        // Snapshot the outer settlement fund flow (proves the outer settlement completes).
        uint256 payerInputBefore = callbackToken.balanceOf(address(this));
        uint256 treasuryInputBefore = callbackToken.balanceOf(treasury);
        uint256 recipientOutputBefore = token1.balanceOf(address(this));

        // The outer call succeeds because the reenterer's try/catch swallows the inner swap revert. Open a session
        // so the reentrant transferFrom-fired public swap reaches the per-pool lifecycle lock (surfaced as the v4
        // WrappedError asserted below), not the session gate. The settlement self-call skips v4 callbacks.
        hook.beginAccountSession();
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: settlementPoolKey, params: _settlementSwapParams(), recipient: address(this)
            })
        );
        hook.endAccountSession();

        // Inner reentrant swap was blocked.
        assertTrue(callbackToken.reentryFired(), "transferFrom callback fired");
        assertFalse(callbackToken.reentrySwapExecuted(), "inner same-pool swap blocked");
        // Inner revert selector: v4 wraps the beforeSwap SwapLifecycleReentrant into WrappedError on the swap
        // return path; the reenterer's try/catch on `poolManager.unlock("")` captures that wrapped selector.
        assertEq(callbackToken.reentryRevertSelector(), _WRAPPED_ERROR_SELECTOR, "inner revert is v4 WrappedError");

        // Outer settlement completed normally.
        assertEq(payerInputBefore - callbackToken.balanceOf(address(this)), 10 ether, "payer funded settlement");
        assertGt(callbackToken.balanceOf(treasury) - treasuryInputBefore, 0, "treasury received fee");
        assertGt(token1.balanceOf(address(this)) - recipientOutputBefore, 0, "recipient received output");
    }

    function _reentrySwapParams() internal pure returns (SwapParams memory) {
        // Direction follows the settlement pool so the callback token pays its own input leg.
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _settlementSwapParams() internal view returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: settlementZeroForOne,
            amountSpecified: -int256(10 ether),
            sqrtPriceLimitX96: settlementZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _dynamicPoolKey(address currencyA, address currencyB) internal view returns (PoolKey memory key) {
        (address currency0, address currency1) = currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _initializeAndFundPool(PoolKey memory key) internal {
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }
}
