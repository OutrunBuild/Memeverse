// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {OrdinarySwapMath} from "../../../src/swap/libraries/OrdinarySwapMath.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

/// @notice Fork tests covering the hook's pre-swap executability guard against the deployed
///         mainnet V4 singleton: over-trading the pool's 100 token0 / 100 token1 liquidity within
///         a tight price limit reverts FinalTargetNotExecutable (wrapped by V4). The
///         ExactInput/OutputPartialFill rollback guards are covered by the mock-injected underfill
///         tests in test/swap/MemeverseSwapRouter.t.sol — on the deployed V4 the hook's planner
///         always rejects an unachievable target first.
contract MemeverseSwapForkPartialFillTest is MemeverseSwapForkBase {
    function setUp() public {
        // No Permit2 needed: tests do not sign any EIP-3009 / Permit2 flow.
        _setUpBase(IPermit2(address(0)));
    }

    /// @dev Tighten sqrtPriceLimitX96 to just below 1.0 so a -100 ether input cannot fully fill:
    ///      the hook's pre-swap executability check rejects the
    ///      unachievable target and reverts FinalTargetNotExecutable, which the deployed mainnet V4
    ///      wraps as WrappedError(hook, beforeSwap, FinalTargetNotExecutable) — assert the exact
    ///      nested selector instead of accepting any revert. (The ExactInputPartialFill rollback
    ///      guard itself is covered by the mock-injected underfill tests in MemeverseSwapRouter.t.sol;
    ///      on the deployed V4 the hook's planner always rejects first.) State must roll back fully.
    function testExactInput_TargetNotExecutable_RevertsAndRollsBack() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint160 roomyLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: roomyLimit});

        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));
        bytes memory revertData = _swapCapturingRevert(key, params, address(this), 100 ether);
        assertEq(bytes4(revertData), CustomRevert.WrappedError.selector, "outer selector");
        (address target, bytes4 callbackSelector, uint256 reasonLength, bytes4 reasonSelector) =
            _wrappedReason(revertData);
        assertEq(target, address(key.hooks), "wrapped target");
        assertEq(callbackSelector, IHooks.beforeSwap.selector, "wrapped callback");
        assertEq(reasonLength, 4, "nested reason length");
        assertEq(reasonSelector, OrdinarySwapMath.FinalTargetNotExecutable.selector, "nested reason selector");
        _assertRollback(address(this), before_);
    }

    /// @dev Boundary-near success case: the 1% sqrt-price cushion is close enough to exercise the
    ///      partial-fill guard but still leaves enough room for a full 1-token exact-input swap.
    function testExactInput_NearLimitButFillable_SucceedsAndMutatesState() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint160 nearLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: nearLimit});
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 outputBefore = token1.balanceOf(address(this));
        (, uint256 fee0Before,) = _hook().poolInfo(poolId);

        _swapInSession(key, params, 0, 1 ether, "");

        (, uint256 fee0After,) = _hook().poolInfo(poolId);
        assertEq(token1.balanceOf(address(this)) - outputBefore, quote.estimatedUserOutputAmount, "output received");
        assertGt(fee0After, fee0Before, "input-side LP fee grew");
    }

    /// @dev Boundary-near exact-output success case: request well below the pool's deliverable output.
    ///      Use the quote as max input because the router pulls the full exact-output budget up front.
    function testExactOutput_NearAvailableLiquidity_Succeeds() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 outputBefore = token1.balanceOf(address(this));

        _swapInSession(key, params, 0, quote.estimatedUserInputAmount, "");

        assertEq(quote.estimatedUserOutputAmount, 1 ether, "quoted requested output");
        assertEq(token1.balanceOf(address(this)) - outputBefore, quote.estimatedUserOutputAmount, "output received");
    }

    /// @dev Tight price limit blocks a 10 ether exact-output request before the pool can deliver the
    ///      requested output. The router pulls a finite budget the test account owns, so the swap reaches
    ///      V4/hook, whose pre-swap executability check rejects the undeliverable output with
    ///      FinalTargetNotExecutable, wrapped by the deployed mainnet V4 as
    ///      WrappedError(hook, beforeSwap, FinalTargetNotExecutable) — assert the exact nested
    ///      selector instead of accepting any revert. (The ExactOutputPartialFill rollback guard
    ///      itself is covered by the mock-injected underfill tests in MemeverseSwapRouter.t.sol.)
    function testExactOutput_TargetNotExecutable_RevertsAndRollsBack() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint160 roomyLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: roomyLimit});

        uint256 inputBudget = token0.balanceOf(address(this));
        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));
        bytes memory revertData = _swapCapturingRevert(key, params, address(this), inputBudget);
        assertEq(bytes4(revertData), CustomRevert.WrappedError.selector, "outer selector");
        (address target, bytes4 callbackSelector, uint256 reasonLength, bytes4 reasonSelector) =
            _wrappedReason(revertData);
        assertEq(target, address(key.hooks), "wrapped target");
        assertEq(callbackSelector, IHooks.beforeSwap.selector, "wrapped callback");
        assertEq(reasonLength, 4, "nested reason length");
        assertEq(reasonSelector, OrdinarySwapMath.FinalTargetNotExecutable.selector, "nested reason selector");
        _assertRollback(address(this), before_);
    }
}
