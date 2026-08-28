// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";
import {MockPermit2ForRouterTest} from "../mocks/swap/Permit2Mocks.sol";

contract MemeverseSwapRouterPermit2IntegrationTest is RealisticSwapIntegrationBase {
    using BalanceDeltaLibrary for BalanceDelta;

    MockPermit2ForRouterTest internal permit2;

    function setUp() public {
        permit2 = new MockPermit2ForRouterTest();
        _setUpIntegration(IPermit2(address(permit2)));

        vm.prank(alice);
        token0.approve(address(permit2), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(permit2), type(uint256).max);
    }

    function testPermit2_ExactInput_OutputFee_FullFill_Succeeds() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 alice0Before = token0.balanceOf(alice);
        uint256 alice1Before = token1.balanceOf(alice);
        RollbackSnapshot memory dynamicBefore = _rollbackSnapshot(alice);
        // The session principal is the test contract, independent of the pranked swap caller.
        hook.beginAccountSession();
        vm.prank(alice);
        BalanceDelta delta = router.swapWithPermit2(
            _singlePermit(address(token0), 100 ether), key, params, alice, block.timestamp, 0, 100 ether, ""
        );
        hook.endAccountSession();
        RollbackSnapshot memory dynamicAfter = _rollbackSnapshot(alice);
        IMemeverseUniswapHook.SwapQuote memory followUpQuote = router.quoteSwap(key, params, address(this));

        assertEq(permit2.lastOwner(), alice, "permit2 owner");
        assertEq(permit2.lastRecipient(), address(router), "permit2 recipient");
        assertEq(permit2.lastToken(), address(token0), "permit2 token");
        assertEq(permit2.lastRequestedAmount(), 100 ether, "permit2 requested amount");
        assertEq(
            permit2.lastWitness(),
            _swapWitness(key, params, alice, block.timestamp, 0, 100 ether, bytes("")),
            "permit2 witness"
        );
        assertEq(permit2.lastWitnessTypeString(), SWAP_WITNESS_TYPE_STRING, "permit2 witness type");
        assertEq(alice0Before - token0.balanceOf(alice), quote.estimatedUserInputAmount, "exact user spend");
        assertEq(token1.balanceOf(alice) - alice1Before, quote.estimatedUserOutputAmount, "exact recipient output");
        assertEq(token1.balanceOf(treasury), quote.estimatedProtocolFeeAmount, "exact treasury fee");
        (, uint256 fee0PerShareAfter,) = hook.poolInfo(poolId);
        assertEq(fee0PerShareAfter, _expectedLpFeeGrowth(quote.estimatedLpFeeAmount), "exact lp fee growth");
        assertEq(delta.amount0(), -int128(int256(quote.estimatedUserInputAmount)), "delta0 exact");
        assertEq(delta.amount1(), int128(int256(quote.estimatedUserOutputAmount)), "delta1 exact");
        assertGt(dynamicAfter.weightedVolume0, dynamicBefore.weightedVolume0, "weightedVolume0 changed");
        assertGt(dynamicAfter.ewVWAPX18, dynamicBefore.ewVWAPX18, "ewvwap changed");
        assertGt(dynamicAfter.volDeviationAccumulator, dynamicBefore.volDeviationAccumulator, "vol deviation changed");
        assertGt(dynamicAfter.shortImpactPpm, dynamicBefore.shortImpactPpm, "short impact changed");
        assertGt(followUpQuote.feeBps, quote.feeBps, "state affects next quote fee");
    }

    function testPermit2_ExactOutput_PrepullsBudgetAndRefundsAboveFinalInput() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, alice);
        uint256 inputBudget = quote.estimatedUserInputAmount + 1 ether;
        uint256 alice0Before = token0.balanceOf(alice);

        hook.beginAccountSession();
        vm.prank(alice);
        BalanceDelta delta = router.swapWithPermit2(
            _singlePermit(address(token0), inputBudget), key, params, alice, block.timestamp, 0, inputBudget, ""
        );
        hook.endAccountSession();

        uint256 finalUserInput = uint256(uint128(-delta.amount0()));
        assertEq(permit2.lastRequestedAmount(), inputBudget, "permit2 prepulls the signed budget");
        assertEq(finalUserInput, quote.estimatedUserInputAmount, "delta reports final user input");
        assertEq(alice0Before - token0.balanceOf(alice), finalUserInput, "unused budget refunded to payer");
        assertEq(inputBudget - finalUserInput, 1 ether, "refund equals unused prefund");
        assertEq(token0.balanceOf(address(router)), 0, "router retains no input budget");
    }

    function testPermit2_ExactInput_OutputFee_PartialFill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency1, true);

        // One session covers the seed swap and the rollback swap; the revert rolls back its own context.
        hook.beginAccountSession();
        vm.prank(alice);
        router.swapWithPermit2(
            _singlePermit(address(token0), 10 ether),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        RollbackSnapshot memory before_ = _rollbackSnapshot(alice);

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        router.swapWithPermit2(
            _singlePermit(address(token0), 100 ether),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            alice,
            block.timestamp,
            0,
            100 ether,
            ""
        );

        _assertRollback(alice, before_);
        hook.endAccountSession();
    }
}
