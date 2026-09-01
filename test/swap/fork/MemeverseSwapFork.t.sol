// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {FeeMath} from "../../../src/swap/libraries/FeeMath.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

contract MemeverseSwapForkTest is MemeverseSwapForkBase {
    using BalanceDeltaLibrary for BalanceDelta;

    function setUp() public {
        _setUpBase(IPermit2(address(0)));
    }

    function testExactInput_ZeroForOne_InputFee_QuoteMatchesActual() external {
        _assertQuoteMatchesActual(true, false, key.currency0);
    }

    function testExactInput_ZeroForOne_OutputFee_QuoteMatchesActual() external {
        _assertQuoteMatchesActual(true, false, key.currency1);
    }

    function testExactInput_OneForZero_InputFee_QuoteMatchesActual() external {
        _assertQuoteMatchesActual(false, false, key.currency1);
    }

    function testExactInput_OneForZero_OutputFee_QuoteMatchesActual() external {
        _assertQuoteMatchesActual(false, false, key.currency0);
    }

    /// @dev Unified quote==actual assertion for the four exact-input combinations of
    ///      (zeroForOne × input-side/output-side fee). Validates the router's quote
    ///      formula against real V4 swap math on every token flow: user input
    ///      spend, user output, treasury protocol fee, LP fee-per-share growth, and BalanceDelta.
    ///      The exact-output half of the matrix is covered by MemeverseSwapForkFuzz.t.sol.
    function _assertQuoteMatchesActual(bool zeroForOne, bool exactOutput, Currency feeCurrency) internal {
        _hook().setProtocolFeeCurrency(feeCurrency, true);
        _matureLaunchWindow();

        // token0 == key.currency0 (base guarantee). Direction decides input vs output token.
        MockERC20 inputToken = zeroForOne ? token0 : token1;
        MockERC20 outputToken = zeroForOne ? token1 : token0;
        // Fee accrues on the fee-currency side; LP fee-per-share grows on that same side.
        bool feeOnInput = Currency.unwrap(feeCurrency) == Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        MockERC20 feeToken = feeOnInput ? inputToken : outputToken;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactOutput ? int256(10 ether) : -int256(100 ether),
            sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 inBefore = inputToken.balanceOf(address(this));
        uint256 outBefore = outputToken.balanceOf(address(this));
        uint256 treasuryFeeBefore = feeToken.balanceOf(treasury);
        (, uint256 fee0Before, uint256 fee1Before) = _hook().poolInfo(poolId);

        // exact-output requires amountInMaximum > 0 (router AmountInMaximumRequired); use quoted
        // input. exact-input sets amountInMaximum to the specified input magnitude.
        uint256 amountInMaximum = exactOutput ? quote.estimatedUserInputAmount : 100 ether;
        BalanceDelta delta = _swapInSession(key, params, 0, amountInMaximum, "");

        (, uint256 fee0After, uint256 fee1After) = _hook().poolInfo(poolId);
        // Hook credits LP fee-per-share on the INPUT currency side (it keys off ctx.currencyIn /
        // ctx.inputIsCurrency0 in _collectLpFee, NOT the configured protocol-fee currency). So
        // zeroForOne (input == currency0) grows fee0PerShare; oneForZero (input == currency1) grows
        // fee1PerShare — regardless of which side the protocol fee was configured on.
        bool feeOnCurrency0 = zeroForOne;
        uint256 lpFeeGrowthDelta = feeOnCurrency0 ? (fee0After - fee0Before) : (fee1After - fee1Before);

        assertEq(inBefore - inputToken.balanceOf(address(this)), quote.estimatedUserInputAmount, "user input spend");
        assertEq(outputToken.balanceOf(address(this)) - outBefore, quote.estimatedUserOutputAmount, "user output");
        assertEq(feeToken.balanceOf(treasury) - treasuryFeeBefore, quote.estimatedProtocolFeeAmount, "treasury fee");
        assertEq(lpFeeGrowthDelta, _expectedLpFeeGrowth(quote.estimatedLpFeeAmount), "lp fee growth");
        // delta: negative on input side, positive on output side.
        assertEq(
            delta.amount0(),
            zeroForOne
                ? -int128(int256(quote.estimatedUserInputAmount))
                : int128(int256(quote.estimatedUserOutputAmount)),
            "delta0"
        );
        assertEq(
            delta.amount1(),
            zeroForOne
                ? int128(int256(quote.estimatedUserOutputAmount))
                : -int128(int256(quote.estimatedUserInputAmount)),
            "delta1"
        );
    }

    function testLaunchFeeWindow_FeeAboveBase() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        // Do NOT mature the window — pool just initialized, elapsed=0, launch fee = startFeeBps.
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        // Pool just initialized (elapsed=0) -> launch fee equals startFeeBps (5000) exactly.
        assertEq(quote.feeBps, 5000, "launch fee = startFeeBps at elapsed=0");
    }

    /// @dev Asserts the launch-fee COMPONENT is monotonically non-increasing across warps.
    function testLaunchFeeWindow_ComponentMonotonicAcrossWarp() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        uint256 feeEarly = router.quoteSwap(key, params, address(this)).feeBps;
        vm.warp(block.timestamp + 300);
        uint256 feeMid = router.quoteSwap(key, params, address(this)).feeBps;
        vm.warp(block.timestamp + 600);
        uint256 feeLate = router.quoteSwap(key, params, address(this)).feeBps;
        assertGe(feeEarly, feeMid, "launch fee non-increasing (early->mid)");
        assertGe(feeMid, feeLate, "launch fee non-increasing (mid->late)");
    }

    function testPublicSwapBlocked_RevertsBeforeResumeTime() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        _blockPublicSwap(block.timestamp + 3600);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        // PublicSwapDisabled fires in hook beforeSwap; the deployed mainnet V4 wraps it with the same
        // CustomRevert.WrappedError selector as the lib build (verified live against the fork block),
        // so pin the exact nested reason instead of accepting any revert.
        bytes memory revertData = _swapCapturingRevert(key, params, address(this), 10 ether);
        assertEq(bytes4(revertData), CustomRevert.WrappedError.selector, "outer selector");
        (address target, bytes4 callbackSelector, uint256 reasonLength, bytes4 reasonSelector) =
            _wrappedReason(revertData);
        assertEq(target, address(key.hooks), "wrapped target");
        assertEq(callbackSelector, IHooks.beforeSwap.selector, "wrapped callback");
        assertEq(reasonLength, 4, "nested reason length");
        assertEq(reasonSelector, IMemeverseUniswapHook.PublicSwapDisabled.selector, "nested reason selector");
    }

    function testPublicSwapResumes_AfterResumeTime() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        _blockPublicSwap(block.timestamp + 3600);
        vm.warp(block.timestamp + 3601);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        _swapInSession(key, params, 0, 10 ether, "");
    }

    function test_RevertWhen_NativeCurrencyUnsupported() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: key.currency1,
            fee: 0x800000,
            tickSpacing: 200,
            hooks: key.hooks
        });
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.swap(badKey, params, address(this), block.timestamp, 0, 10 ether, "");
    }

    /// @dev Neither currency side registered -> the swap must succeed (not revert). `setUp` registers
    ///      no protocol-fee currency, so neither `currencyIn` nor `currencyOut` is supported; the fee
    ///      resolves to the input leg (currency0 for zeroForOne=true). We prove the ordinary-pool path
    ///      executes end-to-end AND charges the fee on the input currency by asserting (a) a positive
    ///      output, (b) a `ProtocolFeeCollected` event emitted with currency0 as the fee currency, and
    ///      (c) a non-zero treasury balance delta on currency0 — so a zero-amount emit or a spurious
    ///      second emit cannot satisfy the test.
    function testSwap_OrdinaryPoolWithoutProtocolFeeCurrencyRegistration_Succeeds() external {
        // Explicit: neither side is a registered protocol-fee currency.
        _hook().setProtocolFeeCurrency(key.currency0, false);
        _hook().setProtocolFeeCurrency(key.currency1, false);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        // Open the session BEFORE arming the emit expectation so beginAccountSession's hook call does not
        // interleave with the ProtocolFeeCollected match.
        _hook().beginAccountSession();
        // Expect the protocol fee to be collected on the input leg (currency0). Match indexed poolId
        // (topic1) and currency (topic2) only; amount is unchecked. The hook emits this
        // event directly (not V4-wrapped), so the selector is verbatim.
        vm.expectEmit(true, true, false, false, address(_hook()));
        emit IMemeverseUniswapHook.ProtocolFeeCollected(key.toId(), key.currency0, address(0), 0);

        // Snapshot treasury balances BEFORE the swap so the post-swap assertions tie the emitted fee to
        // a real ERC20 transfer (defeats a zero-amount emit or a duplicate event masking a missing fee)
        // and rule out an output-side charge.
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);

        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, 10 ether, "");
        _hook().endAccountSession();

        // Input leg is currency0 (zeroForOne=true); a successful swap moves it into the pool (delta0 < 0)
        // and pays out currency1 (delta1 > 0).
        assertLt(delta.amount0(), 0, "input flowed into the pool");
        assertGt(delta.amount1(), 0, "output produced for the swapper");
        // Real balance delta: treasury actually received a non-zero currency0 protocol fee, and nothing on
        // the output leg (rules out an afterSwap output-side charge if the !protocolFeeOnInput guard regresses).
        assertGt(token0.balanceOf(treasury) - treasury0Before, 0, "treasury received non-zero currency0 fee");
        assertEq(token1.balanceOf(treasury) - treasury1Before, 0, "no output-side fee on ordinary pool");
    }

    /// @dev Referrer-bearing twin of `testSwap_OrdinaryPoolWithoutProtocolFeeCurrencyRegistration_Succeeds`.
    ///      With neither currency registered, the ordinary-pool resolution still charges the input leg
    ///      (currency0 for zeroForOne=true) — and the rebate carved out of that fee must accrue to the
    ///      referrer while the remainder lands in the treasury. Pins: (a) the swap succeeds on real V4,
    ///      (b) treasury receives a non-zero currency0 amount (real balance delta, not just an emit), (c)
    ///      `pendingRebateOf(referrer, currency0)` rises by the expected rebate, and (d)
    ///      `rebate + toTreasury == protocolFee` (65/25/10 conservation at default rebateBps=1000).
    function testSwap_OrdinaryPoolWithReferrer_AccruesRebateAndFundsTreasury() external {
        // Explicit: neither side is a registered protocol-fee currency.
        _hook().setProtocolFeeCurrency(key.currency0, false);
        _hook().setProtocolFeeCurrency(key.currency1, false);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        // Quote so the expected rebate/treasury split is derived from the same fee state the swap sees.
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        address referrer = makeAddr("ordinaryPoolReferrer");
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 pendingBefore = _hook().pendingRebateOf(referrer, key.currency0);

        // Referrer is the first 20 bytes of hookData (`_decodeReferrer`). `abi.encodePacked` keeps the
        // address in the low 20 bytes; `abi.encode` would left-pad to address(0).
        _swapInSession(key, params, 0, 10 ether, abi.encodePacked(referrer));

        uint256 rebate = _hook().pendingRebateOf(referrer, key.currency0) - pendingBefore;
        uint256 toTreasury = token0.balanceOf(treasury) - treasury0Before;

        // Rebate accrues on the input currency (currency0 is the ordinary-pool fee leg).
        assertGt(rebate, 0, "referrer rebate accrued in currency0");
        // Real balance delta: treasury actually received a non-zero currency0 amount.
        assertGt(toTreasury, 0, "treasury received non-zero currency0 fee");
        // 65/25/10 conservation, exact by construction: rebate + toTreasury = protocolFeeInputAmount.
        // Quote and execution use the same ordinary settlement formula (no state mutates between quote and swap).
        assertEq(rebate + toTreasury, quote.estimatedProtocolFeeAmount, "rebate + treasury == protocol fee");
        // Cross-check the rebate amount against the on-chain formula
        // (protocolFee * referrerRebateBps / PROTOCOL_FEE_SHARE_BPS).
        uint256 expectedRebate =
            (quote.estimatedProtocolFeeAmount * _hook().referrerRebateBps()) / FeeMath.PROTOCOL_FEE_SHARE_BPS;
        assertEq(rebate, expectedRebate, "rebate matches bps formula");
    }

    // ── Router slippage check (post-swap, router-level — NOT V4-wrapped) ──

    /// @dev The core output clears the minimum, but the output-side protocol fee lowers the final user delta below it.
    function test_RevertWhen_FinalOutputAmountBelowMinimum() external {
        _hook().setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 amountOutMinimum = quote.estimatedUserOutputAmount + 1;
        uint256 coreGrossOutput = quote.estimatedUserOutputAmount + quote.estimatedProtocolFeeAmount;
        assertGt(coreGrossOutput, amountOutMinimum, "core output clears minimum before output fee");

        // Open a session so the swap reaches execution; the router's min-output check still reverts after.
        _hook().beginAccountSession();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseSwapRouter.OutputAmountBelowMinimum.selector,
                quote.estimatedUserOutputAmount,
                amountOutMinimum
            )
        );
        router.swap(key, params, address(this), block.timestamp, amountOutMinimum, 10 ether, "");
    }

    /// @dev One prefunded wei lets settlement finish so the router can compare the final user input delta to the cap.
    function test_RevertWhen_FinalInputAmountExceedsMaximum() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        assertGt(
            quote.estimatedLpFeeAmount + quote.estimatedProtocolFeeAmount,
            1,
            "input fees create a core-to-user input gap"
        );
        uint256 amountInMaximum = quote.estimatedUserInputAmount - 1;
        assertTrue(token0.transfer(address(router), 1), "router prefund");

        // Open a session so the swap reaches execution; the router's max-input check still reverts after.
        _hook().beginAccountSession();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseSwapRouter.InputAmountExceedsMaximum.selector, quote.estimatedUserInputAmount, amountInMaximum
            )
        );
        router.swap(key, params, address(this), block.timestamp, 0, amountInMaximum, "");
    }

    // ── Router entry validation (pre-swap, router-level — exact selector) ──

    /// @dev deadline < block.timestamp -> router ExpiredPastDeadline (pre-swap, router-level).
    function test_RevertWhen_ExpiredDeadline() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        vm.expectRevert(IMemeverseSwapRouter.ExpiredPastDeadline.selector);
        router.swap(key, params, address(this), block.timestamp - 1, 0, 10 ether, "");
    }

    /// @dev amountSpecified == 0 -> router SwapAmountCannotBeZero (pre-swap, router-level).
    function test_RevertWhen_ZeroAmount() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: _validExecutionPriceLimit(true)});
        vm.expectRevert(IMemeverseSwapRouter.SwapAmountCannotBeZero.selector);
        router.swap(key, params, address(this), block.timestamp, 0, 0, "");
    }
}
