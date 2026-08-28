// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {BeforeSwapReenterer} from "../mocks/swap/BeforeSwapReenterer.sol";

/// @title BeforeSwapReentrancyGuardTest
/// @notice Proves the per-poolId transient swap-lifecycle lock blocks same-pool callback-token reentry from
///         the `beforeSwap` fee-take window, while leaving cross-pool nested swaps and settlement self-calls
///         untouched. Uses the real v4 PoolManager so the full beforeSwap → _swap → afterSwap lifecycle runs.
contract BeforeSwapReentrancyGuardTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    BeforeSwapReenterer internal callbackToken;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal callbackPoolKey;
    PoolKey internal otherPoolKey;
    address internal treasury = address(0xFEE);

    function setUp() public {
        manager = deployRealPoolManager();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        callbackToken = new BeforeSwapReenterer();

        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        callbackToken.mint(address(this), 1_000_000 ether);
        // The callback token reenters as the swap caller and must fund its own reentrant input leg.
        token0.mint(address(callbackToken), 100 ether);
        token1.mint(address(callbackToken), 100 ether);
        callbackToken.mint(address(callbackToken), 100 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        hook.setPoolInitializer(address(this));

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        callbackToken.approve(address(hook), type(uint256).max);

        // The callback-token pool pairs the callback token with a normal token so its input-side fee take
        // (currencyIn == callbackToken when callbackToken sorts as currency0 and zeroForOne is true) reenters.
        callbackPoolKey = _dynamicPoolKey(address(callbackToken), address(token1));
        // An independent pool for the cross-pool negative test.
        otherPoolKey = _dynamicPoolKey(address(token0), address(token1));

        _initializeAndFundPool(callbackPoolKey);
        _initializeAndFundPool(otherPoolKey);

        // Both pool input currencies are approved fee currencies so a non-zero input-side take occurs in beforeSwap
        // (the take to address(hook) is what arms the callback token's transfer trigger).
        hook.setProtocolFeeCurrency(callbackPoolKey.currency0, true);
        hook.setProtocolFeeCurrency(otherPoolKey.currency0, true);

        // Move past the post-unlock public-swap protection window so public swaps are allowed.
        vm.warp(block.timestamp + 900);
    }

    /// @notice A callback token reentering the SAME poolId from the beforeSwap take window trips the per-pool
    ///         swap-lifecycle lock, reverting `SwapLifecycleReentrant` and rolling back the whole outer swap.
    function test_RevertIf_SamePoolBeforeSwapCallbackTokenReentry() public {
        // Arm a reentrant swap against the SAME poolId (callbackPoolKey). The reentrant caller is the token
        // contract, so v4 runs the public beforeSwap path and trips the lock acquired by the outer swap.
        callbackToken.arm(
            manager,
            callbackPoolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(hook)
        );

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Open a session so the reentrant inner swap passes the session gate and reaches the per-pool lifecycle
        // lock (the asserted reentry revert), rather than aborting on `AccountSessionNotActive`.
        hook.beginAccountSession();
        // The lock aborts the reentrant beforeSwap with `SwapLifecycleReentrant`, which propagates out through
        // the take and reverts the whole outer swap. v4 wraps the hook revert in its own WrappedError at the swap
        // boundary, so the selector is scanned anywhere in the captured revert bytes (not just the outermost word).
        bytes memory revertData = _swapViaUnlockCapturingRevert(callbackPoolKey, params, "");
        hook.endAccountSession();
        assertGt(revertData.length, 0, "same-pool reentry must revert");
        assertTrue(
            _containsSelector(revertData, IMemeverseUniswapHook.SwapLifecycleReentrant.selector),
            "reentry reverted with SwapLifecycleReentrant"
        );
    }

    /// @notice A callback token reentering a DIFFERENT poolId does NOT trip the lock, proving the lock is per-pool.
    /// @dev Cross-pool nested swaps address an independent per-poolId slot, so they do not collide with the
    ///      outer swap's lock. This is the documented design: the lock only prevents dynamic-fee distortion on
    ///      the SAME pool, not legitimate cross-pool composition. The reentrant beforeSwap reaches the hook and
    ///      passes the lock acquire; the outer swap may still revert later on unrelated v4 delta accounting, so
    ///      the assertion scans the captured revert bytes for the lifecycle selector (must be absent).
    function test_CrossPoolBeforeSwapCallbackTokenReentryDoesNotTripLock() public {
        // Arm a reentrant swap against `otherPoolKey` (different poolId from the outer callbackPoolKey swap).
        callbackToken.arm(
            manager,
            otherPoolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(hook)
        );

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Open a session so the reentrant inner swap reaches the lifecycle guard under the same conditions as
        // the same-pool case; the assertion here is that a different poolId does NOT trip the lock.
        hook.beginAccountSession();
        // Capture the outer swap's revert bytes; whether it succeeds or fails, the lifecycle selector must be
        // absent (the per-pool lock did not trip for a different poolId).
        bytes memory revertData = _swapViaUnlockCapturingRevert(callbackPoolKey, params, "");
        hook.endAccountSession();
        assertFalse(
            _containsSelector(revertData, IMemeverseUniswapHook.SwapLifecycleReentrant.selector),
            "lock must not trip for a different poolId"
        );
    }

    /// @dev Drives a public swap through `poolManager.unlock` so real v4 runs the full beforeSwap → _swap →
    ///      afterSwap lifecycle, capturing revert bytes (empty when the swap succeeds). The test contract acts as
    ///      the unlock-callback caller and closes its own negative deltas. Reverts are captured rather than
    ///      re-raised because v4 wraps hook reverts in its own WrappedError at the swap boundary; the tests scan
    ///      the captured bytes for the lifecycle selector instead of relying on the outermost revert word.
    function _swapViaUnlockCapturingRevert(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        internal
        returns (bytes memory revertData)
    {
        try manager.unlock(abi.encode(key, params, hookData)) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            _settleDeltasIfAny(key, delta);
        } catch (bytes memory reason) {
            return reason;
        }
    }

    /// @dev Scans raw revert bytes (incl. v4 WrappedError payloads) for a 4-byte selector. Returns true if found.
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

    /// @notice PoolManager unlock callback: runs one public swap and returns its delta for the caller to settle.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(rawData, (PoolKey, SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        return abi.encode(delta);
    }

    function _settleDeltasIfAny(PoolKey memory key, BalanceDelta delta) internal {
        if (delta.amount0() < 0) {
            manager.sync(key.currency0);
            _pushToManager(key.currency0, uint256(int256(-delta.amount0())));
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(key.currency1);
            _pushToManager(key.currency1, uint256(int256(-delta.amount1())));
            manager.settle();
        }
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(int256(delta.amount1())));
        }
    }

    /// @dev All test currencies are MockERC20 (token0/token1/callbackToken). The test contract is never a
    ///      currency, so no self-transfer branch is needed here.
    function _pushToManager(Currency currency, uint256 amount) internal {
        bool ok = MockERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
        require(ok, "transfer to manager failed");
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
