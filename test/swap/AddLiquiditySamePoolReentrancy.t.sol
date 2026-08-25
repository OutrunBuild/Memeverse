// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {AddLiquiditySettleReenterer} from "../mocks/swap/AddLiquiditySettleReenterer.sol";

/// @title AddLiquiditySamePoolReentrancyTest
/// @notice A callback-token same-pool reentry during the add-liquidity settle transferFrom window is blocked
///         by the per-pool swap-lifecycle lock now held by `_addLiquidityCore`.
/// @dev The lock is acquired before the recipient fee snapshot and released after the LP mint and
///      `cachedLpTotalSupply` update, so it spans snapshot → settle transferFrom → mint. The reenterer wraps
///      its nested `poolManager.swap` in a try/catch, so the inner `SwapLifecycleReentrant` revert is swallowed
///      by the reenterer rather than bubbling into the outer add. This test expects the inner reentry to be
///      blocked while the outer add completes.
///
///      Assertions (same-pool):
///        - `reentryFired == true`                       the transferFrom callback fired.
///        - `reentrySwapExecuted == false`               the inner same-pool swap was blocked by the lock.
///        - `reentryRevertSelector == 0x90bfb865`        v4 wraps the inner beforeSwap `SwapLifecycleReentrant`
///          as `CustomRevert.WrappedError` (selector 0x90bfb865).
///        - Fee growth unchanged, claim zero             the blocked swap could not advance feePerShare between
///          the snapshot and the mint, so no per-share fees leak to the freshly minted shares.
///        - Outer add completes                          LP shares minted and `cachedLpTotalSupply` updated.
///
///      Assertions (cross-pool):
///        - `reentrySwapExecuted == true`                the lock is per-poolId: a swap on a DIFFERENT pool is
///          not blocked and runs the normal public fee path.
///        - Add pool fee growth unchanged                the cross-pool swap accrues fees on the other pool only.
///
///      The inner swap is a public-path call (called by the token, not the hook), so v4 runs beforeSwap and
///      the lock trip surfaces as a v4 `WrappedError` rather than the raw selector. A session is opened so the
///      inner swap reaches the lifecycle lock rather than aborting on the earlier `AccountSessionNotActive`
///      gate.
///
///      Does NOT inherit any upgradeable production contract — `HookStorageHelper` is a standalone Test helper
///      and all hook interaction is via the external `MemeverseUniswapHookUpgradeable` interface.
contract AddLiquiditySamePoolReentrancyTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Selector of v4's `CustomRevert.WrappedError(address,bytes4,bytes,bytes)` — the ERC-7751 wrapper v4 emits
    // when a hook's beforeSwap/afterSwap revert bubbles back through PoolManager.swap.
    bytes4 internal constant _WRAPPED_ERROR_SELECTOR = bytes4(0x90bfb865);

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    AddLiquiditySettleReenterer internal callbackToken;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal addPoolKey;
    PoolKey internal otherPoolKey;
    address internal treasury = address(0xFEE);

    function setUp() public {
        manager = deployRealPoolManager();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        callbackToken = new AddLiquiditySettleReenterer();

        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        callbackToken.mint(address(this), 1_000_000 ether);
        // The callback token is the caller of the inner swap and must pay its own reentrant input leg: the
        // cross-pool test forges token0/token1, and the same-pool test forges the callback token itself. Without
        // this self-funding an unfixed same-pool reentry would fail on the mock's underfunded input transfer
        // instead of exercising the fee-leak chain.
        token0.mint(address(callbackToken), 100 ether);
        token1.mint(address(callbackToken), 100 ether);
        callbackToken.mint(address(callbackToken), 100 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        hook.setPoolInitializer(address(this));

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        callbackToken.approve(address(hook), type(uint256).max);

        // The pool under attack pairs the callback token with a normal token; the independent pool is for the
        // cross-pool negative test.
        addPoolKey = _dynamicPoolKey(address(callbackToken), address(token1));
        otherPoolKey = _dynamicPoolKey(address(token0), address(token1));

        _initializeAndFundPool(addPoolKey);
        _initializeAndFundPool(otherPoolKey);

        // The cross-pool swap's LP/protocol fee takes draw the input currency from the PoolManager's own
        // balance; pre-fund it so those takes succeed inside the reentrant window.
        token0.transfer(address(manager), 100 ether);
        token1.transfer(address(manager), 100 ether);

        // Warp past the launch-fee decay window (DEFAULT_LAUNCH_DECAY_SECONDS = 900) so the cross-pool
        // reentrant swap runs at the deterministic minimum fee. publicSwapResumeTime is never written, so
        // public swaps are enabled from pool creation (0 means never paused).
        vm.warp(block.timestamp + 900);
    }

    /// @notice A callback token reentering the SAME poolId from the add-liquidity settle window trips the
    ///         per-pool lock now held by `_addLiquidityCore`, and the outer add completes normally because the
    ///         reenterer swallows the inner revert in its own try/catch.
    function test_AddLiquiditySettleSamePoolReentryBlocked() public {
        callbackToken.arm(manager, addPoolKey, _reentrySwapParams(addPoolKey), address(hook));

        (, uint256 fee0Before, uint256 fee1Before) = hook.poolInfo(addPoolKey.toId());
        uint256 cachedSupplyBefore = hook.cachedLpTotalSupply(addPoolKey.toId());

        // Open a session so the reentrant transferFrom-fired public swap reaches the per-pool lifecycle lock
        // (surfaced as the v4 WrappedError asserted below), not the session gate.
        hook.beginAccountSession();
        (uint128 liquidity,) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: addPoolKey.currency0,
                currency1: addPoolKey.currency1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                to: address(this)
            })
        );
        hook.endAccountSession();

        // Inner reentrant swap was blocked.
        assertTrue(callbackToken.reentryFired(), "transferFrom callback fired");
        assertFalse(callbackToken.reentrySwapExecuted(), "inner same-pool swap blocked");
        assertEq(callbackToken.reentryRevertSelector(), _WRAPPED_ERROR_SELECTOR, "inner revert is v4 WrappedError");
        assertTrue(
            _containsSelector(
                callbackToken.reentryRevertReason(), IMemeverseUniswapHook.SwapLifecycleReentrant.selector
            ),
            "wrapped revert carries SwapLifecycleReentrant"
        );

        // The blocked swap could not advance fee growth between the snapshot and the mint: no per-share fees
        // leaked to the freshly minted shares, and the recipient claims nothing.
        (, uint256 fee0After, uint256 fee1After) = hook.poolInfo(addPoolKey.toId());
        assertEq(fee0After, fee0Before, "fee0PerShare unchanged");
        assertEq(fee1After, fee1Before, "fee1PerShare unchanged");
        (uint256 claimed0, uint256 claimed1) =
            hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: addPoolKey, recipient: address(this)}));
        assertEq(claimed0, 0, "no fee0 claim after blocked reentry");
        assertEq(claimed1, 0, "no fee1 claim after blocked reentry");

        // Outer add completed normally.
        assertGt(liquidity, 0, "liquidity minted");
        assertEq(hook.cachedLpTotalSupply(addPoolKey.toId()), cachedSupplyBefore + liquidity, "cached supply updated");
    }

    /// @notice A callback token reentering a DIFFERENT poolId does NOT trip the lock, proving the lock is
    ///         per-pool and the outer add still completes.
    /// @dev Cross-pool nested swaps address an independent per-poolId slot, so they do not collide with the
    ///      add window's lock. The cross-pool swap runs the normal public fee path on the other pool; its fee
    ///      growth lands on the other pool only, leaving the added pool's per-share accounting untouched.
    function test_AddLiquiditySettleCrossPoolReentryAllowed() public {
        callbackToken.arm(manager, otherPoolKey, _reentrySwapParams(otherPoolKey), address(hook));

        (, uint256 addFee0Before, uint256 addFee1Before) = hook.poolInfo(addPoolKey.toId());
        (, uint256 otherFee0Before, uint256 otherFee1Before) = hook.poolInfo(otherPoolKey.toId());

        hook.beginAccountSession();
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: addPoolKey.currency0,
                currency1: addPoolKey.currency1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                to: address(this)
            })
        );
        hook.endAccountSession();

        // Inner cross-pool swap executed on the public fee path.
        assertTrue(callbackToken.reentryFired(), "transferFrom callback fired");
        assertTrue(callbackToken.reentrySwapExecuted(), "cross-pool swap executed");

        // Fee growth advanced on the other pool only; the added pool's accounting is untouched.
        (, uint256 addFee0After, uint256 addFee1After) = hook.poolInfo(addPoolKey.toId());
        (, uint256 otherFee0After, uint256 otherFee1After) = hook.poolInfo(otherPoolKey.toId());
        assertEq(addFee0After, addFee0Before, "add pool fee0 unchanged");
        assertEq(addFee1After, addFee1Before, "add pool fee1 unchanged");
        assertTrue(
            otherFee0After > otherFee0Before || otherFee1After > otherFee1Before,
            "other pool accrued the cross-pool swap fee"
        );

        // The added pool's recipient claims nothing: no fee accrued between its snapshot and mint.
        (uint256 claimed0, uint256 claimed1) =
            hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: addPoolKey, recipient: address(this)}));
        assertEq(claimed0, 0, "no fee0 claim");
        assertEq(claimed1, 0, "no fee1 claim");
    }

    /// @notice Without an active account session the same-pool reentry is blocked by the earlier session gate,
    ///         pinning the gate order contract: session gate runs BEFORE the lifecycle lock.
    /// @dev The add-liquidity path itself opens no session, so on the production no-session path this is the
    ///      selector a reentrant swap hits (still blocked, just earlier). The outer add completes regardless.
    function test_AddLiquiditySettleReentryWithoutSessionBlockedBySessionGate() public {
        callbackToken.arm(manager, addPoolKey, _reentrySwapParams(addPoolKey), address(hook));

        (uint128 liquidity,) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: addPoolKey.currency0,
                currency1: addPoolKey.currency1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                to: address(this)
            })
        );

        assertTrue(callbackToken.reentryFired(), "transferFrom callback fired");
        assertFalse(callbackToken.reentrySwapExecuted(), "inner same-pool swap blocked");
        assertTrue(
            _containsSelector(
                callbackToken.reentryRevertReason(), IMemeverseUniswapHook.AccountSessionNotActive.selector
            ),
            "wrapped revert carries AccountSessionNotActive"
        );
        assertGt(liquidity, 0, "outer add completed");
    }

    /// @notice Inside the post-unlock protection window the same-pool reentry is blocked by the earlier
    ///         public-swap gate, pinning the gate order contract: public-swap gate runs BEFORE the lifecycle lock.
    /// @dev The launcher (this test contract) sets a future resume time; with an active session the reentrant
    ///      swap then hits `PublicSwapDisabled` before reaching the lock. The outer add completes regardless.
    function test_AddLiquiditySettleReentryDuringProtectionWindowBlockedByPublicSwapGate() public {
        hook.setPublicSwapResumeTime(address(callbackToken), address(token1), uint40(block.timestamp + 60));
        callbackToken.arm(manager, addPoolKey, _reentrySwapParams(addPoolKey), address(hook));

        hook.beginAccountSession();
        (uint128 liquidity,) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: addPoolKey.currency0,
                currency1: addPoolKey.currency1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                to: address(this)
            })
        );
        hook.endAccountSession();

        assertTrue(callbackToken.reentryFired(), "transferFrom callback fired");
        assertFalse(callbackToken.reentrySwapExecuted(), "inner same-pool swap blocked");
        assertTrue(
            _containsSelector(callbackToken.reentryRevertReason(), IMemeverseUniswapHook.PublicSwapDisabled.selector),
            "wrapped revert carries PublicSwapDisabled"
        );
        assertGt(liquidity, 0, "outer add completed");
    }

    function _reentrySwapParams(PoolKey memory key) internal pure returns (SwapParams memory) {
        bool zeroForOne = Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1);
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(0.01 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
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

    /// @dev Scans raw revert bytes for a selector anywhere in the payload (v4 nests the hook revert inside
    ///      `CustomRevert.WrappedError`, so the target selector is not the outermost word). Byte-wise sliding
    ///      window — same implementation as `BeforeSwapReentrancyGuard.t.sol::_containsSelector`.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            bytes4 word;
            assembly ("memory-safe") {
                // Read 4 bytes starting at data[i]; offset mload pointer so the 4 target bytes sit in the low
                // half-word (a bytes4 is right-aligned), then mask.
                word := and(
                    mload(add(add(data, 0x20), i)),
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            }
            if (word == selector) return true;
        }
        return false;
    }
}
