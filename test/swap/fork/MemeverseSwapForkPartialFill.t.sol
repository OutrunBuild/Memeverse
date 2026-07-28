// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

/// @notice Fork tests covering the hook's partial-fill guards (ExactInputPartialFill /
///         ExactOutputPartialFill) against the deployed mainnet V4 singleton. The pool holds
///         100 token0 / 100 token1 of liquidity, so both tests intentionally over-trade that budget.
contract MemeverseSwapForkPartialFillTest is MemeverseSwapForkBase {
    function setUp() public {
        // No Permit2 needed: tests do not sign any EIP-3009 / Permit2 flow.
        _setUpBase(IPermit2(address(0)));
    }

    /// @dev Tighten sqrtPriceLimitX96 to just below 1.0 so a -100 ether input cannot fully fill:
    ///      actual pool input < net input -> hook reverts ExactInputPartialFill (wrapped by mainnet
    ///      V4, hence expectRevert() with no selector). State must roll back fully.
    function testExactInput_PriceLimitExhaustion_RevertsAndRollsBack() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint160 tightLimit = SQRT_PRICE_1_1 - 1;
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: tightLimit});

        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));
        // Open a session so the swap reaches the partial-fill guard, not the session gate.
        _hook().beginAccountSession();
        vm.expectRevert();
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");
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
    ///      V4/hook and exercises ExactOutputPartialFill instead of failing during router pre-funding.
    function testExactOutput_InsufficientLiquidity_RevertsAndRollsBack() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        uint160 tightLimit = SQRT_PRICE_1_1 - 1;
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: tightLimit});

        uint256 inputBudget = token0.balanceOf(address(this));
        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));
        // Open a session so the swap reaches the partial-fill guard, not the session gate.
        _hook().beginAccountSession();
        vm.expectRevert();
        router.swap(key, params, address(this), block.timestamp, 0, inputBudget, "");
        _assertRollback(address(this), before_);
    }
}
