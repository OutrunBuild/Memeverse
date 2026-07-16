// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";

/// @notice Regression coverage for the two zero-liquidity arithmetic-underflow bugs (CI-012 and CI-016).
///         A drained pool (`liquidity == 0` and `cachedLpTotalSupply == 0`) makes
///         `DynamicFeeMath.estimateDynamicFeeQuote` early-return with `estimatedGrossOutputAmount == 0`.
///         Two call sites previously did an unguarded subtraction against that zero, triggering Panic 0x11.
///         This suite exercises the quote path (CI-016) end-to-end on the mock V4 manager, since the quote
///         never reaches SqrtPriceMath and so reproduces the underflow regardless of whether the pool
///         math path is mocked or real. The exact-output control groups confirm the fix does not alter the
///         documented "drained pool quote returns zero, never reverts" semantics for either fee leg.
contract MemeverseUniswapHookDrainedPoolTest is RealisticSwapIntegrationBase {
    /// @dev The mock manager mirrors real PoolManager storage via extsload (see RealisticSwapMocks
    ///      `_syncPoolStorage`), so StateLibrary reads the same liquidity slot the production code does.
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));
    }

    /// @dev Removes all LP liquidity so the pool reaches the drained state the bugs require:
    ///      `poolManager.getLiquidity(poolId) == 0` and `cachedLpTotalSupply == 0`. Asserts both are zero
    ///      so a future setup change cannot silently leave residual liquidity and mask the regression.
    function _drainPool() internal {
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 lpBalance = IERC20(liquidityToken).balanceOf(address(this));
        assertGt(lpBalance, 0, "setup: LP balance present before drain");

        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                liquidity: uint128(lpBalance),
                recipient: address(this)
            })
        );

        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0, "drained: pool liquidity is zero");
        assertEq(hook.cachedLpTotalSupply(poolId), 0, "drained: cached LP supply is zero");
    }

    // ------------------------------------------------------------------
    // CI-016 regression: quote path, exact-output + !protocolFeeOnInput
    // ------------------------------------------------------------------

    /// @notice Drained-pool exact-output quote with the protocol fee on the output leg must NOT panic
    ///         (the pre-fix `estimatedGrossOutputAmount(0) - requestedOutputAmount` underflow). It returns
    ///         a zero-valued quote: the net output clamps to zero (LR-001: a drained pool delivers nothing,
    ///         so the requested amount is not advertised as the user's net take), the grossed-up protocol
    ///         fee clamps to zero, and no revert bubbles up.
    function testQuoteSwap_DrainedPool_ExactOutput_OutputFee_ReturnsZeroNotRevert() external {
        // Output leg carries the protocol fee (input unsupported, output supported) -> protocolFeeOnInput == false.
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        // Must not revert (pre-fix this panicked with Panic 0x11).
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertEq(quote.estimatedUserOutputAmount, 0, "drained pool delivers no net output (LR-001)");
        assertEq(quote.estimatedProtocolFeeAmount, 0, "grossed-up protocol fee clamped to 0");
        assertEq(quote.estimatedLpFeeAmount, 0, "no LP fee on drained pool");
    }

    // ------------------------------------------------------------------
    // Negative controls: the fix must not change drained-pool behavior for other legs / directions
    // ------------------------------------------------------------------

    /// @dev Control for CI-016: exact-output with the protocol fee on the INPUT leg
    ///      (`protocolFeeOnInput == true`) never touched the buggy line; it must keep returning a zero
    ///      quote on a drained pool. Guards against the fix over-clamping the input-leg path. LR-001 also
    ///      makes net output clamp to zero here since the drained pool still delivers nothing.
    function testQuoteSwap_DrainedPool_ExactOutput_InputFee_ReturnsZeroNotRevert() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertEq(quote.estimatedUserOutputAmount, 0, "drained pool delivers no net output (LR-001)");
        assertEq(quote.estimatedProtocolFeeAmount, 0, "no protocol fee on drained pool");
        assertEq(quote.estimatedLpFeeAmount, 0, "no LP fee on drained pool");
    }

    /// @dev Control for CI-016: exact-INPUT on a drained pool never reaches the buggy exact-output line;
    ///      it must keep returning a preview that does not revert. For exact-input + output-fee-leg the LP
    ///      fee is input-derived (non-zero), while the protocol fee is derived from the gross output
    ///      estimate (zero on a drained pool) and the deliverable output estimate is zero. This pins that
    ///      the fix left the input-side path untouched while still returning a usable, non-reverting quote.
    function testQuoteSwap_DrainedPool_ExactInput_OutputFee_ReturnsZeroOutputNotRevert() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertEq(quote.estimatedUserInputAmount, 1 ether, "user input preserved");
        assertEq(quote.estimatedUserOutputAmount, 0, "no deliverable output on drained pool");
        assertGt(quote.estimatedLpFeeAmount, 0, "input-derived LP fee preview present");
        assertEq(quote.estimatedProtocolFeeAmount, 0, "gross-output-derived protocol fee is 0 on drained pool");
    }
}
