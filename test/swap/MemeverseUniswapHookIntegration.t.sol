// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseDynamicFeeEngine} from "../../src/swap/interfaces/IMemeverseDynamicFeeEngine.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";
import {RealisticSwapManagerHarness} from "../mocks/swap/RealisticSwapMocks.sol";

contract MemeverseUniswapHookIntegrationTest is RealisticSwapIntegrationBase {
    using BalanceDeltaLibrary for BalanceDelta;

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));
    }

    function testDirectManager_ExactInput_InputFee_PartialFill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 98 ether);

        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );

        _assertRollback(address(this), before_);
    }

    function testDirectManager_ExactInput_OutputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        uint256 payer0Before = token0.balanceOf(address(this));
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        (, uint256 fee0PerShareBefore,) = hook.poolInfo(poolId);

        BalanceDelta delta = integrator.swap(key, params, address(this), bytes(""));

        (, uint256 fee0PerShareAfter,) = hook.poolInfo(poolId);
        assertEq(payer0Before - token0.balanceOf(address(this)), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(
            token1.balanceOf(address(this)) - payer1Before, quote.estimatedUserOutputAmount, "exact recipient output"
        );
        assertEq(token1.balanceOf(treasury) - treasury1Before, quote.estimatedProtocolFeeAmount, "exact treasury fee");
        assertEq(
            fee0PerShareAfter - fee0PerShareBefore,
            _expectedLpFeeGrowth(quote.estimatedLpFeeAmount),
            "exact lp fee growth"
        );
        assertEq(delta.amount0(), -int128(int256(quote.estimatedUserInputAmount)), "delta0 exact");
        assertEq(delta.amount1(), int128(int256(quote.estimatedUserOutputAmount)), "delta1 exact");
    }

    function testDirectManager_ExactOutput_InputFee_Underfill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        manager.setNextExactOutputAmount(poolId, 9 ether);
        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );

        _assertRollback(address(this), before_);
    }

    function testDirectManager_ExactOutput_OutputFee_GrossUnderfill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        manager.setNextExactOutputAmount(poolId, quote.estimatedUserOutputAmount + quote.estimatedProtocolFeeAmount - 1);
        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(key, params, address(this), bytes(""));

        _assertRollback(address(this), before_);
    }

    function testDirectManager_ExactOutput_OutputFee_OverfillKeepsSurplusWithRecipient() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        uint256 surplus = 1 ether;
        manager.setNextExactOutputAmount(
            poolId, quote.estimatedUserOutputAmount + quote.estimatedProtocolFeeAmount + surplus
        );
        uint256 payer1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);

        integrator.swap(key, params, address(this), bytes(""));

        assertEq(
            token1.balanceOf(address(this)) - payer1Before,
            quote.estimatedUserOutputAmount + surplus,
            "recipient keeps surplus"
        );
        assertEq(
            token1.balanceOf(treasury) - treasury1Before,
            quote.estimatedProtocolFeeAmount,
            "treasury gets reserved fee only"
        );
    }

    function testDirectManager_ExactOutput_ZeroFill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        manager.setNextExactOutputAmount(poolId, 0);
        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );

        _assertRollback(address(this), before_);
    }

    function testDirectManager_RawTransferBypass_RevertsAtUnlock() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        vm.expectRevert(RealisticSwapManagerHarness.CurrencyNotSettled.selector);
        rawTransferIntegrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
    }

    // ---------------------------------------------------------------------------
    // Context wiring: verify hook correctly assembles QuoteSwapContext from
    // PoolManager state and hook storage before passing it to the engine.
    // These tests catch wiring bugs that engine-only unit tests cannot detect:
    // wrong poolId, stale liquidity, launch config, fee side, and price context.
    // ---------------------------------------------------------------------------

    /// @notice Verifies the hook reads `launchTimestamp` from `$.poolLaunchTimestamp[poolId]`
    ///         and passes it to the engine. A just-initialized pool has a recent launch
    ///         timestamp, so the launch fee should be higher than the base fee.
    function testQuoteSwapContext_LaunchTimestampWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        // Do NOT mature the launch window — pool was just initialized, so launch fee is active.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: 0});

        IMemeverseUniswapHook.SwapQuote memory launchQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Launch fee should be above the minimum (100 bps) because we're within the decay window.
        assertGt(launchQuote.feeBps, 100, "launch fee above base during decay window");
    }

    /// @notice Verifies the hook reads `defaultLaunchFeeConfig` from its storage and
    ///         passes it to the engine. Changing the config should change the quoted fee.
    function testQuoteSwapContext_LaunchFeeConfigWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: 0});

        IMemeverseUniswapHook.SwapQuote memory defaultQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Set a config with a much higher start fee.
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 9000, minFeeBps: 100, decayDurationSeconds: 900})
        );
        IMemeverseUniswapHook.SwapQuote memory highStartQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertGt(highStartQuote.feeBps, defaultQuote.feeBps, "higher start fee config increases quote");
    }

    /// @notice Verifies the hook reads `liquidity` from `poolManager.getLiquidity(poolId)`
    ///         and passes it to the engine. Adding more liquidity should reduce the dynamic
    ///         fee because the same trade size causes less price impact.
    function testQuoteSwapContext_LiquidityWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        // First swap to build up volatility state so the dynamic fee is sensitive to liquidity.
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: 0});
        IMemeverseUniswapHook.SwapQuote memory lowLiqQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Add more liquidity — this increases poolManager.getLiquidity(poolId).
        _addLiquidity(address(this));
        IMemeverseUniswapHook.SwapQuote memory highLiqQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertLe(highLiqQuote.feeBps, lowLiqQuote.feeBps, "more liquidity reduces dynamic fee");
    }

    /// @notice Verifies the hook reads `protocolFeeOnInput` via `_resolveSwapFeeContext`
    ///         and passes it to the engine. Setting the fee currency to the input side
    ///         should yield `protocolFeeOnInput = true`; setting it to the output side
    ///         should yield `protocolFeeOnInput = false`.
    function testQuoteSwapContext_ProtocolFeeOnInputWiring() external {
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: 0});

        // Input side: currency0 is the input for zeroForOne.
        hook.setProtocolFeeCurrency(key.currency0, true);
        IMemeverseUniswapHook.SwapQuote memory inputSideQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        assertTrue(inputSideQuote.protocolFeeOnInput, "fee on input when input currency supported");

        // Output side: disable input currency, enable output currency only.
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);
        IMemeverseUniswapHook.SwapQuote memory outputSideQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        assertFalse(outputSideQuote.protocolFeeOnInput, "fee on output when only output currency supported");
    }

    /// @notice Verifies the hook reads `preSqrtPriceX96` from `poolManager.getSlot0(poolId)`
    ///         and passes it to the engine. After a swap moves the price, a subsequent quote
    ///         should reflect the new price, not the original.
    function testQuoteSwapContext_SqrtPriceWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: 0});

        IMemeverseUniswapHook.SwapQuote memory beforeQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Execute a swap to move the price.
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );

        IMemeverseUniswapHook.SwapQuote memory afterQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // After a zeroForOne swap the price moves down. The dynamic fee should differ
        // because the engine now sees a different preSqrtPriceX96.
        // We can't assert exact values, but the spot price before should differ.
        assertNotEq(afterQuote.feeBps, beforeQuote.feeBps, "price move changes fee quote");
    }
}
