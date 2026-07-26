// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {SettlementSettleReenterer} from "../mocks/swap/SettlementSettleReenterer.sol";

/// @title SettlementReentrancyTest
/// @notice Regression suite for v4 hook self-call routing and callback-token settlement reentry.
/// @dev Settlement has two ERC20 callback windows: `transferFrom` (Phase 1/2, BEFORE unlock; nested unlock +
///      swap is reachable) and `transfer` inside `CurrencySettler.settle` (DURING unlock; same-lock direct swap).
///      The legitimate settlement swap is a hook self-call, so v4 skips both swap callbacks. A callback token
///      reenters as the token contract, so v4 executes the normal public callback and fee path. Same-pool
///      reentry in either window is blocked by the per-pool swap-lifecycle lock acquired in
///      `executeSettlementLogic`; cross-pool reentry is permitted.
///      Suite layering:
///      - mock: routing / output-fee / transferFrom guard rejection / PoolKey validation
///      - real-v4: transfer-window same-lock reentry fund flows; transferFrom-window nested-unlock e2e fund flow
contract SettlementReentrancyTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q128 = uint256(1) << 128;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    /// @dev Main pool (token0/token1). Used as the reentrant swap target (forgedKey) and as the public-swap
    ///      pool. It is distinct from the evil settlement pool, so any fee collected on it is attributable
    ///      solely to the reentrant public swap — a clean signal that the reentry took the public fee path.
    PoolKey internal key;
    PoolId internal poolId;

    address internal treasury = address(0xFEE);

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), address(this), treasury);
        hook = MemeverseUniswapHook(hookProxy);
        // Settlement entry is launcher-gated; the test contract acts as the launcher.
        hook.setLauncher(address(this));

        key = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        poolId = key.toId();

        // Initialize the main pool so it is swappable as the reentrant/public target.
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        mockManager.initialize(key, SQRT_PRICE_1_1);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // v4 dynamic-fee flag
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Deploys the callback-token, builds the evil settlement pool (evil/token1) with evil on the input
    ///      leg, initializes it, seeds LP shares, registers evil as the supported protocol-fee currency, and
    ///      funds the mock manager with the output currency so the settlement's `take` can pay out.
    function _setupEvilPool()
        internal
        returns (SettlementSettleReenterer evil, PoolKey memory evilKey, bool zeroForOne)
    {
        evil = new SettlementSettleReenterer();
        evil.mint(address(this), 1_000_000 ether);
        // Respect V4 pair ordering; keep evil on the input leg either way so settle's transfer(manager) fires.
        bool evilIsCurrency0 = address(evil) < address(token1);
        evilKey = evilIsCurrency0
            ? _dynamicPoolKey(Currency.wrap(address(evil)), Currency.wrap(address(token1)))
            : _dynamicPoolKey(Currency.wrap(address(token1)), Currency.wrap(address(evil)));
        zeroForOne = evilIsCurrency0;

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(evilKey, SQRT_PRICE_1_1);
        mockManager.initialize(evilKey, SQRT_PRICE_1_1);
        seedActiveLiquiditySharesForTest(address(hook), evilKey.toId(), address(this), 100 ether);
        hook.setProtocolFeeCurrency(Currency.wrap(address(evil)), true);
        evil.approve(address(hook), type(uint256).max);
        // Fund the output payout: the settlement callback `take`s token1 to the recipient.
        token1.mint(address(mockManager), 1_000_000 ether);
    }

    /// @dev Seeds the main pool as the reentrant/public swap target with real manager liquidity and matching
    ///      cached LP supply, then enables input-side protocol fees and funds the manager's fee payout.
    function _seedMainPoolForReentry() internal {
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
        hook.setProtocolFeeCurrency(Currency.wrap(address(token0)), true);
        token0.mint(address(mockManager), 1_000_000 ether);
    }

    /// @dev Reentrant swap parameters fired from inside settle: a small exact-input swap on the main pool
    ///      (token0 input, zeroForOne). Negative amountSpecified = exact-input.
    function _reentrySwapParams() internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
    }

    function _validExecutionPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime) internal {
        (bool ok,) = address(hook)
            .call(
                abi.encodeWithSignature("setPublicSwapResumeTime(address,address,uint40)", tokenA, tokenB, resumeTime)
            );
        require(ok, "setPublicSwapResumeTime failed");
    }

    // -----------------------------------------------------------------
    // Hook-initiated settlement swaps skip public callbacks
    // -----------------------------------------------------------------

    /// @notice The hook-initiated settlement swap skips public swap callbacks.
    /// @dev A public-swap block is set on the evil pool. The public path's first check
    ///      (`_revertIfPublicSwapBlocked`) reverts a public swap, while v4 does not invoke that callback for
    ///      the hook self-call. A direct public swap confirms the block is active.
    function test_SettlementReentrancy_SettlementSelfCallSkipsPublicCallbacks() public {
        (SettlementSettleReenterer evil, PoolKey memory evilKey, bool zeroForOne) = _setupEvilPool();
        _setPublicSwapResumeTime(address(evil), address(token1), uint40(block.timestamp + 1 hours));

        // Settlement succeeds because its PoolManager.swap caller is the hook itself.
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(10 ether),
                    sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
                }),
                recipient: address(this)
            })
        );

        // A non-hook swap on the same pool executes callbacks and observes the active block.
        vm.expectRevert(IMemeverseUniswapHook.PublicSwapDisabled.selector);
        mockManager.swapAsUnlocked(evilKey, _reentrySwapParams(), bytes(""));
    }

    // -----------------------------------------------------------------
    // Settlement self-call skips public afterSwap accounting
    // -----------------------------------------------------------------

    /// @notice The settlement self-call does not execute public beforeSwap or afterSwap accounting.
    /// @dev Here the evil pool charges an OUTPUT-side protocol
    ///      fee (token1 supported, evil input), so the settlement callback's `take` charges the output fee
    ///      exactly once. fee0PerShare on the evil pool reflects ONLY the entry's input-side LP fee (no public
    ///      callback fee), and treasury token1 equals the settlement's output fee.
    function test_SettlementReentrancy_SettlementSelfCallSkipsPublicFeeCallbacks() public {
        (SettlementSettleReenterer evil, PoolKey memory evilKey, bool zeroForOne) = _setupEvilPool();
        // Switch the supported fee currency to token1 (the output leg) so the settlement charges an output-side
        // protocol fee via the settlement callback take.
        hook.setProtocolFeeCurrency(Currency.wrap(address(evil)), false);
        hook.setProtocolFeeCurrency(Currency.wrap(address(token1)), true);

        PoolId evilPoolId = evilKey.toId();
        (, uint256 fee0Before, uint256 fee1Before) = hook.poolInfo(evilPoolId);
        uint256 treasuryToken1Before = token1.balanceOf(treasury);

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(10 ether),
                    sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
                }),
                recipient: address(this)
            })
        );

        (, uint256 fee0After, uint256 fee1After) = hook.poolInfo(evilPoolId);
        // Entry input-side LP fee on evil (input): feeOnAmount(10 ether, 65) = 0.065 ether; supply = 100 ether.
        // The input-side protocol fee is NOT charged here because the supported fee currency is token1
        // (output leg), so protocolFeeOnInput=false and only the LP fee reduces the net input.
        uint256 expectedFeePerShare = FullMath.mulDiv(0.065 ether, Q128, 100 ether);
        uint256 evilFeeDelta = zeroForOne ? (fee0After - fee0Before) : (fee1After - fee1Before);
        assertEq(evilFeeDelta, expectedFeePerShare, "self-call added no public LP fee on input leg");
        // Output protocol fee charged exactly once by the settlement callback:
        // netInput = 10 ether - lpFee(0.065 ether) = 9.935 ether (no input protocol fee, output-side mode);
        // grossOutput = netInput/2 = 4.9675 ether; feeOnAmount(4.9675 ether, 35) = 0.01738625 ether.
        assertEq(
            token1.balanceOf(treasury) - treasuryToken1Before,
            0.01738625 ether,
            "output protocol fee charged once by settlement callback"
        );
    }

    // -----------------------------------------------------------------
    // A non-hook caller always uses public callbacks
    // -----------------------------------------------------------------

    /// @notice A standalone non-hook swap executes the public fee callbacks.
    function test_SettlementReentrancy_PublicSwapCallerPaysPublicFee() public {
        _seedMainPoolForReentry();
        (, uint256 fee0PerShareBefore,) = hook.poolInfo(poolId);

        // The manager harness calls swap with a non-hook caller, so callbacks collect public fees.
        mockManager.swapAsUnlocked(key, _reentrySwapParams(), bytes(""));

        (, uint256 fee0PerShareAfter,) = hook.poolInfo(poolId);
        assertGt(fee0PerShareAfter, fee0PerShareBefore, "public swap paid public LP fee");
    }

    // -----------------------------------------------------------------
    // TransferFrom-window token reentry uses public callbacks
    // -----------------------------------------------------------------

    /// @notice A callback token reentering from a `transferFrom` callback (Phase 1/2, BEFORE `unlock`) via
    ///         `poolManager.unlock` + `swap` uses public callbacks because the swap caller is the token.
    /// @dev The main pool has public swaps blocked. The reentrant token's swap is rejected by that callback,
    ///      while the hook-initiated settlement self-call skips callbacks and completes.
    function test_SettlementReentrancy_TransferFromReentryUsesPublicCallerPath() public {
        (SettlementSettleReenterer evil, PoolKey memory evilKey, bool zeroForOne) = _setupEvilPool();
        _seedMainPoolForReentry();
        // Block public swaps on the main pool; the token-initiated reentry must observe this callback gate.
        _setPublicSwapResumeTime(address(token0), address(token1), uint40(block.timestamp + 1 hours));

        // Arm the transferFrom window: the reentrant swap fires from inside the settlement entry's first
        // `transferFrom` (the protocol-fee pull, or the Phase 2 combined net-input+LP-fee pull when there
        // is no input-side protocol fee), before `poolManager.unlock` opens.
        evil.armTransferFrom(IPoolManager(address(mockManager)), key, _reentrySwapParams());

        // Settlement completes while the token-initiated swap is rejected on the public callback path.
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(10 ether),
                    sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
                }),
                recipient: address(this)
            })
        );

        assertTrue(evil.reentryFired(), "transferFrom reentry fired");
        assertFalse(evil.reentrySwapExecuted(), "token-initiated reentry was blocked on the public callback path");
        assertEq(
            evil.reentryRevertSelector(),
            IMemeverseUniswapHook.PublicSwapDisabled.selector,
            "public swap guard caused the rejection"
        );
    }

    // -----------------------------------------------------------------
    // Mismatched key.hooks reverts at entry
    // -----------------------------------------------------------------

    /// @notice `executeSettlementLogic` reverts with `HookAddressMismatch` when the supplied `key.hooks` does
    ///         not point at this hook, mirroring the `quoteSwap` guard.
    /// @dev The check fires at the very top of the function body — before any pool state reads — so a
    ///      mismatched key is rejected fail-fast. The launcher constructs poolKey with hooks = address(hook);
    ///      this is a backstop against future caller-supplied keys.
    function test_SettlementReentrancy_RevertsWhenKeyHooksMismatch() public {
        // Same currencies/fee/tickSpacing as the initialized `key`, but hooks points elsewhere.
        PoolKey memory mismatchedKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(address(0xBEEF))
        });

        // The test contract is the launcher (see setUp), so `onlyLauncher` passes; the currencies are ERC20,
        // so `erc20Pair` passes. The facet's entry-level HookAddressMismatch check then fails fast.
        vm.expectRevert(IMemeverseUniswapHook.HookAddressMismatch.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: mismatchedKey,
                params: SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(10 ether),
                    sqrtPriceLimitX96: _validExecutionPriceLimit(true)
                }),
                recipient: address(this)
            })
        );
    }
}
