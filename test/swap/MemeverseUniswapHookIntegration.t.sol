// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {FeeMath} from "../../src/swap/libraries/FeeMath.sol";
import {MemeversePoolKeyLib} from "../../src/swap/libraries/MemeversePoolKeyLib.sol";
import {OrdinarySwapMath} from "../../src/swap/libraries/OrdinarySwapMath.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";
import {RealisticSwapManagerHarness} from "../mocks/swap/RealisticSwapMocks.sol";

contract MemeverseUniswapHookIntegrationTest is RealisticSwapIntegrationBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    struct QuoteReadOnlySnapshot {
        IDynamicFeeFacet.DynamicFeeState dynamicFeeState;
        IDynamicFeeFacet.AddressBatchState addressBatchState;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
        address liquidityToken;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
        uint256 cachedLpTotalSupply;
        uint256 holderFee0Offset;
        uint256 holderFee1Offset;
        uint256 holderPendingFee0;
        uint256 holderPendingFee1;
        uint256 traderFee0Offset;
        uint256 traderFee1Offset;
        uint256 traderPendingFee0;
        uint256 traderPendingFee1;
        uint256 payerToken0;
        uint256 payerToken1;
        uint256 traderToken0;
        uint256 traderToken1;
        uint256 treasuryToken0;
        uint256 treasuryToken1;
        uint256 hookToken0;
        uint256 hookToken1;
        uint256 managerToken0;
        uint256 managerToken1;
        uint256 lensToken0;
        uint256 lensToken1;
    }

    struct ExpectedOrdinarySwap {
        OrdinarySwapMath.CurveResult finalCurve;
        OrdinarySwapMath.FinalSettlement finalSettlement;
        uint256 inputHookDelta;
        uint256 outputHookDelta;
    }

    struct ReferralAccountingSnapshot {
        uint256 pendingCurrency0;
        uint256 pendingCurrency1;
        uint256 treasuryCurrency0;
        uint256 treasuryCurrency1;
    }

    struct ExecutionAccountingSnapshot {
        uint256 payerCurrency0;
        uint256 payerCurrency1;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
        ReferralAccountingSnapshot referral;
    }

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));
    }

    function testDirectManager_ExactInput_InputFee_PartialFill_RevertsAndRollsBack() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        // One session covers the seed swap and the rollback swap; the revert rolls back its own context.
        hook.beginAccountSession();
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();
        _matureLaunchWindow();
        manager.setNextExactInputPoolInputAmount(poolId, 98 ether);

        RollbackSnapshot memory before_ = _rollbackSnapshot(address(this));

        hook.beginAccountSession();
        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();

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

        hook.beginAccountSession();
        BalanceDelta delta = integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();

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

        hook.beginAccountSession();
        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();

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

        hook.beginAccountSession();
        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();

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

        hook.beginAccountSession();
        integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();

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

        hook.beginAccountSession();
        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();

        _assertRollback(address(this), before_);
    }

    function testDirectManager_RawTransferBypass_RevertsAtUnlock() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();

        // Open a session so the swap passes the session gate and reaches the integrator's settle guard.
        hook.beginAccountSession();
        vm.expectRevert(RealisticSwapManagerHarness.CurrencyNotSettled.selector);
        rawTransferIntegrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();
    }

    /// @notice Lens STATICCALL and direct ordinary CALL agree without mutating the first-anchor state.
    function testLensAndBridgeQuotesAreReadOnlyAtFirstAnchor() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        IDynamicFeeFacet.DynamicFeeState memory firstAnchor = hook.dynamicFeeStateOf(poolId);
        assertEq(firstAnchor.volAnchorSqrtPriceX96, 0, "first anchor starts empty");

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        _assertLensAndBridgeQuotesAreReadOnly(params, tx.origin, true);
    }

    /// @notice Lens STATICCALL and direct ordinary CALL stay equivalent on the volatility refresh boundary.
    function testLensAndBridgeQuotesAreReadOnlyAtVolatilityRefreshBoundary() external {
        _matureLaunchWindow();
        hook.setProtocolFeeCurrency(key.currency0, true);

        SwapParams memory seedParams = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        manager.setNextSwapSqrtPriceX96(poolId, SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 100);
        hook.beginAccountSession();
        integrator.swap(key, seedParams, address(this), bytes(""));
        hook.endAccountSession();

        IDynamicFeeFacet.DynamicFeeState memory seeded = hook.dynamicFeeStateOf(poolId);
        assertGt(seeded.volLastMoveTs, 0, "price move starts refresh clock");
        assertGt(seeded.volDeviationAccumulator, 0, "price move seeds deviation");
        vm.warp(uint256(seeded.volLastMoveTs) + 10);
        assertEq(block.timestamp - seeded.volLastMoveTs, 10, "exact volatility refresh boundary");

        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);
        _assertLensAndBridgeQuotesAreReadOnly(seedParams, tx.origin, false);
    }

    /// @notice Lens, direct bridge quote, and execution agree across all eight ordinary-swap paths.
    function testLensBridgeAndExecutionAgreeAcrossAllDirectionsRequestKindsAndFeeLegs() external {
        _matureLaunchWindow();

        _assertLensBridgeAndExecutionAgree(true, -int256(1 ether), true);
        _assertLensBridgeAndExecutionAgree(true, -int256(1 ether), false);
        _assertLensBridgeAndExecutionAgree(true, int256(1 ether), true);
        _assertLensBridgeAndExecutionAgree(true, int256(1 ether), false);
        _assertLensBridgeAndExecutionAgree(false, -int256(1 ether), true);
        _assertLensBridgeAndExecutionAgree(false, -int256(1 ether), false);
        _assertLensBridgeAndExecutionAgree(false, int256(1 ether), true);
        _assertLensBridgeAndExecutionAgree(false, int256(1 ether), false);
    }

    /// @notice An intermediary keeps recipient and callback-caller roles separate from the dynamic-fee principal.
    /// @dev Task 2 replaced the tx.origin identity root with the hook-captured session principal. The dynamic-fee
    ///      trader is now `address(this)` (the session principal set by `beginAccountSession`), so this test
    ///      proves the principal owns the batch while the recipient, the integrator (callback sender), and the
    ///      manager (callback caller) do not. The payer here coincides with the principal (this contract calls
    ///      `beginAccountSession` and is also the integrator's `msg.sender`), so payer/principal separation is no
    ///      longer a distinct axis.
    function testIntermediarySeparatesTraderPayerRecipientAndCallbackCallerRoles() external {
        _matureLaunchWindow();
        hook.setProtocolFeeCurrency(key.currency0, true);

        address principal = address(this);
        address recipient = makeAddr("recipient");
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, principal);

        uint256 payerInputBefore = token0.balanceOf(address(this));
        uint256 payerOutputBefore = token1.balanceOf(address(this));
        uint256 recipientOutputBefore = token1.balanceOf(recipient);

        // The integrator records msg.sender as payer, PoolManager sees the integrator as swap/callback sender,
        // and SwapFacet keys dynamic history by the session principal (this contract).
        hook.beginAccountSession();
        BalanceDelta delta = integrator.swap(key, params, recipient, bytes(""));
        hook.endAccountSession();

        assertEq(payerInputBefore - token0.balanceOf(address(this)), quote.estimatedUserInputAmount, "payer input");
        assertEq(token1.balanceOf(address(this)), payerOutputBefore, "payer is not recipient");
        assertEq(
            token1.balanceOf(recipient) - recipientOutputBefore, quote.estimatedUserOutputAmount, "recipient output"
        );
        assertEq(delta.amount0(), -int128(int256(quote.estimatedUserInputAmount)), "final input delta");
        assertEq(delta.amount1(), int128(int256(quote.estimatedUserOutputAmount)), "final output delta");

        IDynamicFeeFacet.AddressBatchState memory traderBatch = hook.addressBatchStateOf(principal, poolId);
        assertGt(traderBatch.batchStartTs, 0, "session principal owns dynamic batch");
        assertEq(hook.addressBatchStateOf(recipient, poolId).batchStartTs, 0, "recipient has no trader batch");
        assertEq(
            hook.addressBatchStateOf(address(integrator), poolId).batchStartTs, 0, "callback sender has no trader batch"
        );
        assertEq(hook.addressBatchStateOf(address(manager), poolId).batchStartTs, 0, "callback caller has no batch");
    }

    /// @notice A capacity-limited request fails identically in Lens, bridge, and execution.
    function testLensBridgeAndExecutionRejectTheSameInsufficientPriceLimit() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1});
        (uint160 preSqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(poolId);

        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, tx.origin, preSqrtPriceX96, liquidity, true);

        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, tx.origin);

        // Execution path: open a session so the swap reaches the capacity guard, not the session gate.
        hook.beginAccountSession();
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();
    }

    /// @notice Execution normalizes a full-range exact-output rounding endpoint to the shared capacity error.
    function testExecutionRejectsExactOutputThatRoundsToFullRangeEndpoint() external {
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(MemeversePoolKeyLib.DEFAULT_TICK_SPACING);
        uint160 lowerEndpoint = TickMath.getSqrtPriceAtTick(MemeversePoolKeyLib.FULL_RANGE_LOWER_TICK);
        OrdinarySwapMath.CapacityResult memory capacity =
            OrdinarySwapMath.calculateCapacity(maxLiquidity, SQRT_PRICE_1_1, true, lowerEndpoint);

        // The mock has no liquidity setter; seed the StateLibrary-visible pool liquidity before `beforeSwap`.
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        bytes32 liquidityStorageSlot = keccak256(abi.encode(bytes32(uint256(poolStateSlot) + 3), uint256(1)));
        vm.store(address(manager), liquidityStorageSlot, bytes32(uint256(maxLiquidity)));
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), maxLiquidity, "full-range liquidity");

        _matureLaunchWindow();
        hook.setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(capacity.outputCapacity - 1), sqrtPriceLimitX96: lowerEndpoint
        });

        hook.beginAccountSession();
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();
    }

    /// @notice The full negative int256 exact-input boundary reaches the shared capacity error without panic.
    function testLensBridgeAndExecutionHandleInt256MinimumWithoutArithmeticPanic() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        (uint160 preSqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(poolId);

        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, tx.origin, preSqrtPriceX96, liquidity, true);

        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, tx.origin);

        // Execution path: open a session so the swap reaches the capacity guard, not the session gate.
        hook.beginAccountSession();
        vm.expectRevert(OrdinarySwapMath.FinalTargetNotExecutable.selector);
        integrator.swap(key, params, address(this), bytes(""));
        hook.endAccountSession();
    }

    function _assertLensAndBridgeQuotesAreReadOnly(SwapParams memory params, address trader, bool protocolFeeOnInput)
        internal
    {
        QuoteReadOnlySnapshot memory beforeQuote = _quoteReadOnlySnapshot(trader);

        IMemeverseUniswapHook.SwapQuote memory lensQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, trader);
        _assertQuoteReadOnlySnapshotUnchanged(beforeQuote, _quoteReadOnlySnapshot(trader), "lens");

        IDynamicFeeFacet.PreparedSwapFee memory bridgeQuote = IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(
                poolId, params, trader, beforeQuote.sqrtPriceX96, beforeQuote.liquidity, protocolFeeOnInput
            );
        _assertQuoteReadOnlySnapshotUnchanged(beforeQuote, _quoteReadOnlySnapshot(trader), "bridge");

        assertEq(lensQuote.feeBps, bridgeQuote.feeBps, "lens/bridge fee bps");
        assertEq(lensQuote.protocolFeeOnInput, protocolFeeOnInput, "lens/bridge fee leg");
        assertEq(lensQuote.estimatedUserInputAmount, bridgeQuote.estimatedInputAmount, "lens/bridge user input");
        assertEq(lensQuote.estimatedUserOutputAmount, bridgeQuote.estimatedOutputAmount, "lens/bridge user output");
        _assertLensFeeBreakdownMatchesBridge(params, protocolFeeOnInput, lensQuote, bridgeQuote);
    }

    /// @dev Uses only the shared ordinary-swap settlement library; this test does not duplicate fee algebra.
    function _assertLensFeeBreakdownMatchesBridge(
        SwapParams memory params,
        bool protocolFeeOnInput,
        IMemeverseUniswapHook.SwapQuote memory lensQuote,
        IDynamicFeeFacet.PreparedSwapFee memory bridgeQuote
    ) internal pure {
        assertLt(params.amountSpecified, 0, "read-only differential uses exact input");

        OrdinarySwapMath.FeeSplit memory feeSplit = OrdinarySwapMath.deriveFeeSplit(bridgeQuote.feeBps);
        OrdinarySwapMath.SettlementPlan memory settlementPlan =
            OrdinarySwapMath.deriveSettlementPlan(params.amountSpecified, protocolFeeOnInput, feeSplit);
        OrdinarySwapMath.CurveResult memory bridgeCurve = OrdinarySwapMath.CurveResult({
            coreInput: settlementPlan.coreInputTarget,
            coreGrossOutput: bridgeQuote.estimatedGrossOutputAmount,
            postSqrtPriceX96: 0
        });
        OrdinarySwapMath.FinalSettlement memory expected = OrdinarySwapMath.deriveFinalSettlement(
            params.amountSpecified, protocolFeeOnInput, feeSplit, settlementPlan, bridgeCurve
        );

        assertEq(expected.userInput, bridgeQuote.estimatedInputAmount, "shared settlement bridge input");
        assertEq(expected.userNetOutput, bridgeQuote.estimatedOutputAmount, "shared settlement bridge output");
        assertEq(lensQuote.estimatedLpFeeAmount, expected.lpFee, "lens/bridge lp fee");
        assertEq(lensQuote.estimatedProtocolFeeAmount, expected.protocolFee, "lens/bridge protocol fee");
    }

    function _quoteReadOnlySnapshot(address trader) internal view returns (QuoteReadOnlySnapshot memory snapshot) {
        snapshot.dynamicFeeState = hook.dynamicFeeStateOf(poolId);
        snapshot.addressBatchState = hook.addressBatchStateOf(trader, poolId);
        (snapshot.sqrtPriceX96, snapshot.tick, snapshot.protocolFee, snapshot.lpFee) = manager.getSlot0(poolId);
        snapshot.liquidity = IPoolManager(address(manager)).getLiquidity(poolId);
        (snapshot.liquidityToken, snapshot.fee0PerShare, snapshot.fee1PerShare) = hook.poolInfo(poolId);
        snapshot.cachedLpTotalSupply = hook.cachedLpTotalSupply(poolId);
        (snapshot.holderFee0Offset, snapshot.holderFee1Offset, snapshot.holderPendingFee0, snapshot.holderPendingFee1) =
            hook.userFeeState(poolId, address(this));
        (snapshot.traderFee0Offset, snapshot.traderFee1Offset, snapshot.traderPendingFee0, snapshot.traderPendingFee1) =
            hook.userFeeState(poolId, trader);
        snapshot.payerToken0 = token0.balanceOf(address(this));
        snapshot.payerToken1 = token1.balanceOf(address(this));
        snapshot.traderToken0 = token0.balanceOf(trader);
        snapshot.traderToken1 = token1.balanceOf(trader);
        snapshot.treasuryToken0 = token0.balanceOf(treasury);
        snapshot.treasuryToken1 = token1.balanceOf(treasury);
        snapshot.hookToken0 = token0.balanceOf(address(hook));
        snapshot.hookToken1 = token1.balanceOf(address(hook));
        snapshot.managerToken0 = token0.balanceOf(address(manager));
        snapshot.managerToken1 = token1.balanceOf(address(manager));
        snapshot.lensToken0 = token0.balanceOf(address(lens));
        snapshot.lensToken1 = token1.balanceOf(address(lens));
    }

    function _assertQuoteReadOnlySnapshotUnchanged(
        QuoteReadOnlySnapshot memory beforeQuote,
        QuoteReadOnlySnapshot memory afterQuote,
        string memory caller
    ) internal pure {
        _assertDynamicFeeStateUnchanged(beforeQuote.dynamicFeeState, afterQuote.dynamicFeeState, caller);
        assertEq(
            afterQuote.addressBatchState.batchAccumPpm,
            beforeQuote.addressBatchState.batchAccumPpm,
            string.concat(caller, " batch accum")
        );
        assertEq(
            afterQuote.addressBatchState.batchStartTs,
            beforeQuote.addressBatchState.batchStartTs,
            string.concat(caller, " batch start")
        );
        assertEq(afterQuote.sqrtPriceX96, beforeQuote.sqrtPriceX96, string.concat(caller, " sqrt price"));
        assertEq(afterQuote.tick, beforeQuote.tick, string.concat(caller, " tick"));
        assertEq(afterQuote.protocolFee, beforeQuote.protocolFee, string.concat(caller, " manager protocol fee"));
        assertEq(afterQuote.lpFee, beforeQuote.lpFee, string.concat(caller, " manager lp fee"));
        assertEq(afterQuote.liquidity, beforeQuote.liquidity, string.concat(caller, " liquidity"));
        assertEq(afterQuote.liquidityToken, beforeQuote.liquidityToken, string.concat(caller, " lp token"));
        assertEq(afterQuote.fee0PerShare, beforeQuote.fee0PerShare, string.concat(caller, " fee0 growth"));
        assertEq(afterQuote.fee1PerShare, beforeQuote.fee1PerShare, string.concat(caller, " fee1 growth"));
        assertEq(
            afterQuote.cachedLpTotalSupply, beforeQuote.cachedLpTotalSupply, string.concat(caller, " cached lp supply")
        );
        assertEq(
            afterQuote.holderFee0Offset, beforeQuote.holderFee0Offset, string.concat(caller, " holder fee0 offset")
        );
        assertEq(
            afterQuote.holderFee1Offset, beforeQuote.holderFee1Offset, string.concat(caller, " holder fee1 offset")
        );
        assertEq(afterQuote.holderPendingFee0, beforeQuote.holderPendingFee0, string.concat(caller, " holder pending0"));
        assertEq(afterQuote.holderPendingFee1, beforeQuote.holderPendingFee1, string.concat(caller, " holder pending1"));
        assertEq(
            afterQuote.traderFee0Offset, beforeQuote.traderFee0Offset, string.concat(caller, " trader fee0 offset")
        );
        assertEq(
            afterQuote.traderFee1Offset, beforeQuote.traderFee1Offset, string.concat(caller, " trader fee1 offset")
        );
        assertEq(afterQuote.traderPendingFee0, beforeQuote.traderPendingFee0, string.concat(caller, " trader pending0"));
        assertEq(afterQuote.traderPendingFee1, beforeQuote.traderPendingFee1, string.concat(caller, " trader pending1"));
        assertEq(afterQuote.payerToken0, beforeQuote.payerToken0, string.concat(caller, " payer token0"));
        assertEq(afterQuote.payerToken1, beforeQuote.payerToken1, string.concat(caller, " payer token1"));
        assertEq(afterQuote.traderToken0, beforeQuote.traderToken0, string.concat(caller, " trader token0"));
        assertEq(afterQuote.traderToken1, beforeQuote.traderToken1, string.concat(caller, " trader token1"));
        assertEq(afterQuote.treasuryToken0, beforeQuote.treasuryToken0, string.concat(caller, " treasury token0"));
        assertEq(afterQuote.treasuryToken1, beforeQuote.treasuryToken1, string.concat(caller, " treasury token1"));
        assertEq(afterQuote.hookToken0, beforeQuote.hookToken0, string.concat(caller, " hook token0"));
        assertEq(afterQuote.hookToken1, beforeQuote.hookToken1, string.concat(caller, " hook token1"));
        assertEq(afterQuote.managerToken0, beforeQuote.managerToken0, string.concat(caller, " manager token0"));
        assertEq(afterQuote.managerToken1, beforeQuote.managerToken1, string.concat(caller, " manager token1"));
        assertEq(afterQuote.lensToken0, beforeQuote.lensToken0, string.concat(caller, " lens token0"));
        assertEq(afterQuote.lensToken1, beforeQuote.lensToken1, string.concat(caller, " lens token1"));
    }

    function _assertDynamicFeeStateUnchanged(
        IDynamicFeeFacet.DynamicFeeState memory beforeQuote,
        IDynamicFeeFacet.DynamicFeeState memory afterQuote,
        string memory caller
    ) internal pure {
        assertEq(afterQuote.weightedVolume0, beforeQuote.weightedVolume0, string.concat(caller, " weighted volume"));
        assertEq(
            afterQuote.weightedPriceVolume0,
            beforeQuote.weightedPriceVolume0,
            string.concat(caller, " weighted price volume")
        );
        assertEq(afterQuote.ewVWAPX18, beforeQuote.ewVWAPX18, string.concat(caller, " ewvwap"));
        assertEq(
            afterQuote.volAnchorSqrtPriceX96,
            beforeQuote.volAnchorSqrtPriceX96,
            string.concat(caller, " volatility anchor")
        );
        assertEq(afterQuote.volLastMoveTs, beforeQuote.volLastMoveTs, string.concat(caller, " volatility timestamp"));
        assertEq(
            afterQuote.volDeviationAccumulator,
            beforeQuote.volDeviationAccumulator,
            string.concat(caller, " volatility deviation")
        );
        assertEq(
            afterQuote.volCarryAccumulator, beforeQuote.volCarryAccumulator, string.concat(caller, " volatility carry")
        );
        assertEq(afterQuote.shortImpactPpm, beforeQuote.shortImpactPpm, string.concat(caller, " short impact"));
        assertEq(afterQuote.shortLastTs, beforeQuote.shortLastTs, string.concat(caller, " short timestamp"));
    }

    function _assertLensBridgeAndExecutionAgree(bool zeroForOne, int256 amountSpecified, bool protocolFeeOnInput)
        internal
    {
        address referrer = makeAddr("matrixReferrer");
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, false);
        if (zeroForOne) {
            hook.setProtocolFeeCurrency(protocolFeeOnInput ? key.currency0 : key.currency1, true);
        } else {
            hook.setProtocolFeeCurrency(protocolFeeOnInput ? key.currency1 : key.currency0, true);
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
        });
        (uint160 preSqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(poolId);
        // Task 2 made the hook-captured session principal (this contract) the dynamic-fee trader, with no
        // tx.origin fallback. The quote must therefore use the same principal so lens/bridge/execution agree.
        address trader = address(this);
        IDynamicFeeFacet.PreparedSwapFee memory bridgeQuote = IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, trader, preSqrtPriceX96, liquidity, protocolFeeOnInput);
        IMemeverseUniswapHook.SwapQuote memory lensQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, trader);

        assertEq(lensQuote.feeBps, bridgeQuote.feeBps, "fee bps");
        assertEq(lensQuote.protocolFeeOnInput, protocolFeeOnInput, "fee leg");
        assertEq(lensQuote.estimatedUserInputAmount, bridgeQuote.estimatedInputAmount, "bridge user input");
        assertEq(lensQuote.estimatedUserOutputAmount, bridgeQuote.estimatedOutputAmount, "bridge user output");

        ExpectedOrdinarySwap memory expected =
            _calculateExpectedOrdinarySwap(params, preSqrtPriceX96, liquidity, bridgeQuote.feeBps, protocolFeeOnInput);
        _assertQuotesMatchExpectedSettlement(bridgeQuote, lensQuote, expected);
        _executeAndAssertExpectedSettlement(params, referrer, lensQuote, expected);
    }

    function _executeAndAssertExpectedSettlement(
        SwapParams memory params,
        address referrer,
        IMemeverseUniswapHook.SwapQuote memory lensQuote,
        ExpectedOrdinarySwap memory expected
    ) internal {
        ExecutionAccountingSnapshot memory beforeSwap = _executionAccountingSnapshot(referrer);
        // The execution swap enters beforeSwapLogic, which requires an active session. Open one so the eight
        // direction/request/fee-leg cases all reach execution.
        hook.beginAccountSession();
        BalanceDelta delta = integrator.swap(key, params, address(this), abi.encodePacked(referrer));
        hook.endAccountSession();
        ExecutionAccountingSnapshot memory afterSwap = _executionAccountingSnapshot(referrer);

        _assertCallerDeltaAndLpFee(params.zeroForOne, delta, lensQuote, expected, beforeSwap, afterSwap);

        bool protocolFeeCurrencyIsCurrency0 =
            params.zeroForOne ? lensQuote.protocolFeeOnInput : !lensQuote.protocolFeeOnInput;
        _assertReferralAccounting(
            protocolFeeCurrencyIsCurrency0,
            expected.finalSettlement.protocolFee,
            beforeSwap.referral,
            afterSwap.referral
        );
    }

    function _assertCallerDeltaAndLpFee(
        bool zeroForOne,
        BalanceDelta delta,
        IMemeverseUniswapHook.SwapQuote memory lensQuote,
        ExpectedOrdinarySwap memory expected,
        ExecutionAccountingSnapshot memory beforeSwap,
        ExecutionAccountingSnapshot memory afterSwap
    ) internal view {
        uint256 expectedLpFeeGrowth = _expectedLpFeeGrowth(lensQuote.estimatedLpFeeAmount);
        int256 expectedCallerInputDelta = -int256(expected.finalCurve.coreInput) - int256(expected.inputHookDelta);
        int256 expectedCallerOutputDelta =
            int256(expected.finalCurve.coreGrossOutput) - int256(expected.outputHookDelta);

        assertEq(expectedCallerInputDelta, -int256(expected.finalSettlement.userInput), "core minus input hook delta");
        assertEq(
            expectedCallerOutputDelta, int256(expected.finalSettlement.userNetOutput), "core minus output hook delta"
        );

        // Exact-input uses input as the specified hook delta and output as unspecified; exact-output reverses
        // those callback roles. Currency mapping is direction-only, so the caller-delta equation is shared.
        if (zeroForOne) {
            assertEq(
                beforeSwap.payerCurrency0 - afterSwap.payerCurrency0, lensQuote.estimatedUserInputAmount, "user input"
            );
            assertEq(
                afterSwap.payerCurrency1 - beforeSwap.payerCurrency1, lensQuote.estimatedUserOutputAmount, "user output"
            );
            assertEq(delta.amount0(), int128(expectedCallerInputDelta), "caller currency0 delta");
            assertEq(delta.amount1(), int128(expectedCallerOutputDelta), "caller currency1 delta");
            assertEq(afterSwap.fee0PerShare - beforeSwap.fee0PerShare, expectedLpFeeGrowth, "lp input fee");
            assertEq(afterSwap.fee1PerShare, beforeSwap.fee1PerShare, "other lp fee unchanged");
            return;
        }

        assertEq(beforeSwap.payerCurrency1 - afterSwap.payerCurrency1, lensQuote.estimatedUserInputAmount, "user input");
        assertEq(
            afterSwap.payerCurrency0 - beforeSwap.payerCurrency0, lensQuote.estimatedUserOutputAmount, "user output"
        );
        assertEq(delta.amount1(), int128(expectedCallerInputDelta), "caller currency1 delta");
        assertEq(delta.amount0(), int128(expectedCallerOutputDelta), "caller currency0 delta");
        assertEq(afterSwap.fee1PerShare - beforeSwap.fee1PerShare, expectedLpFeeGrowth, "lp input fee");
        assertEq(afterSwap.fee0PerShare, beforeSwap.fee0PerShare, "other lp fee unchanged");
    }

    function _calculateExpectedOrdinarySwap(
        SwapParams memory params,
        uint160 preSqrtPriceX96,
        uint128 liquidity,
        uint256 feeBps,
        bool protocolFeeOnInput
    ) internal pure returns (ExpectedOrdinarySwap memory expected) {
        OrdinarySwapMath.CapacityResult memory capacity = OrdinarySwapMath.calculateCapacity(
            liquidity, preSqrtPriceX96, params.zeroForOne, params.sqrtPriceLimitX96
        );
        OrdinarySwapMath.CurveResult memory originalCurve = OrdinarySwapMath.calculateOriginalRequestCurve(
            liquidity, preSqrtPriceX96, params.zeroForOne, params.amountSpecified
        );
        OrdinarySwapMath.FeeSplit memory feeSplit = OrdinarySwapMath.deriveFeeSplit(feeBps);
        OrdinarySwapMath.SettlementPlan memory settlementPlan =
            OrdinarySwapMath.deriveSettlementPlan(params.amountSpecified, protocolFeeOnInput, feeSplit);
        expected.finalCurve = OrdinarySwapMath.calculateFinalQuoteCurve(
            liquidity,
            preSqrtPriceX96,
            params.zeroForOne,
            params.amountSpecified,
            settlementPlan,
            originalCurve,
            capacity
        );
        expected.finalSettlement = OrdinarySwapMath.deriveFinalSettlement(
            params.amountSpecified, protocolFeeOnInput, feeSplit, settlementPlan, expected.finalCurve
        );
        expected.inputHookDelta = expected.finalSettlement.userInput - expected.finalCurve.coreInput;
        expected.outputHookDelta = expected.finalCurve.coreGrossOutput - expected.finalSettlement.userNetOutput;
    }

    function _assertQuotesMatchExpectedSettlement(
        IDynamicFeeFacet.PreparedSwapFee memory bridgeQuote,
        IMemeverseUniswapHook.SwapQuote memory lensQuote,
        ExpectedOrdinarySwap memory expected
    ) internal pure {
        assertEq(bridgeQuote.estimatedInputAmount, expected.finalSettlement.userInput, "bridge final input");
        assertEq(bridgeQuote.estimatedOutputAmount, expected.finalSettlement.userNetOutput, "bridge final net output");
        assertEq(
            bridgeQuote.estimatedGrossOutputAmount, expected.finalCurve.coreGrossOutput, "bridge core gross output"
        );
        assertEq(lensQuote.estimatedUserInputAmount, expected.finalSettlement.userInput, "lens final input");
        assertEq(lensQuote.estimatedUserOutputAmount, expected.finalSettlement.userNetOutput, "lens final net output");
        assertEq(lensQuote.estimatedLpFeeAmount, expected.finalSettlement.lpFee, "lens lp fee");
        assertEq(lensQuote.estimatedProtocolFeeAmount, expected.finalSettlement.protocolFee, "lens protocol fee");
        assertEq(
            expected.inputHookDelta,
            expected.finalSettlement.lpFee + (lensQuote.protocolFeeOnInput ? expected.finalSettlement.protocolFee : 0),
            "input hook delta"
        );
        assertEq(
            expected.outputHookDelta,
            lensQuote.protocolFeeOnInput ? 0 : expected.finalSettlement.protocolFee,
            "output hook delta"
        );
    }

    function _referralAccountingSnapshot(address referrer)
        internal
        view
        returns (ReferralAccountingSnapshot memory snapshot)
    {
        snapshot.pendingCurrency0 = hook.pendingRebateOf(referrer, key.currency0);
        snapshot.pendingCurrency1 = hook.pendingRebateOf(referrer, key.currency1);
        snapshot.treasuryCurrency0 = token0.balanceOf(treasury);
        snapshot.treasuryCurrency1 = token1.balanceOf(treasury);
    }

    function _executionAccountingSnapshot(address referrer)
        internal
        view
        returns (ExecutionAccountingSnapshot memory snapshot)
    {
        snapshot.payerCurrency0 = token0.balanceOf(address(this));
        snapshot.payerCurrency1 = token1.balanceOf(address(this));
        (, snapshot.fee0PerShare, snapshot.fee1PerShare) = hook.poolInfo(poolId);
        snapshot.referral = _referralAccountingSnapshot(referrer);
    }

    function _assertReferralAccounting(
        bool protocolFeeCurrencyIsCurrency0,
        uint256 protocolFee,
        ReferralAccountingSnapshot memory beforeSwap,
        ReferralAccountingSnapshot memory afterSwap
    ) internal view {
        uint256 expectedRebate = FullMath.mulDiv(protocolFee, hook.referrerRebateBps(), FeeMath.PROTOCOL_FEE_SHARE_BPS);
        assertLe(expectedRebate, protocolFee, "rebate cannot exceed protocol fee");

        if (protocolFeeCurrencyIsCurrency0) {
            assertEq(afterSwap.pendingCurrency0 - beforeSwap.pendingCurrency0, expectedRebate, "currency0 rebate");
            assertEq(afterSwap.pendingCurrency1, beforeSwap.pendingCurrency1, "currency1 pending unchanged");
            assertEq(
                afterSwap.treasuryCurrency0 - beforeSwap.treasuryCurrency0,
                protocolFee - expectedRebate,
                "currency0 treasury net fee"
            );
            assertEq(afterSwap.treasuryCurrency1, beforeSwap.treasuryCurrency1, "currency1 treasury unchanged");
            return;
        }

        assertEq(afterSwap.pendingCurrency1 - beforeSwap.pendingCurrency1, expectedRebate, "currency1 rebate");
        assertEq(afterSwap.pendingCurrency0, beforeSwap.pendingCurrency0, "currency0 pending unchanged");
        assertEq(
            afterSwap.treasuryCurrency1 - beforeSwap.treasuryCurrency1,
            protocolFee - expectedRebate,
            "currency1 treasury net fee"
        );
        assertEq(afterSwap.treasuryCurrency0, beforeSwap.treasuryCurrency0, "currency0 treasury unchanged");
    }

    // ---------------------------------------------------------------------------
    // Context wiring: verify storage-backed fee quoting uses PoolManager state and
    // shared hook storage (launch config/timestamp self-read by DynamicFeeFacet).
    // These tests catch wiring bugs that math-only unit tests cannot detect:
    // wrong poolId, stale liquidity, launch config, fee side, and price context.
    // ---------------------------------------------------------------------------

    /// @notice Verifies the facet self-reads `poolLaunchTimestamp[poolId]` from shared storage.
    ///         A just-initialized pool has a recent launch timestamp, so the launch fee should be
    ///         higher than the base fee.
    function testLensQuote_LaunchTimestampStorageWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        // Do NOT mature the launch window — pool was just initialized, so launch fee is active.
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        IMemeverseUniswapHook.SwapQuote memory launchQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Launch fee should be above the minimum (100 bps) because we're within the decay window.
        assertGt(launchQuote.feeBps, 100, "launch fee above base during decay window");
    }

    /// @notice Verifies the facet self-reads `defaultLaunchFeeConfig` from shared storage.
    ///         Changing the config should change the quoted fee.
    function testLensQuote_LaunchFeeConfigStorageWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        IMemeverseUniswapHook.SwapQuote memory defaultQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Set a config with a much higher start fee.
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 9000, minFeeBps: 100, decayDurationSeconds: 900})
        );
        IMemeverseUniswapHook.SwapQuote memory highStartQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertGt(highStartQuote.feeBps, defaultQuote.feeBps, "higher start fee config increases quote");
    }

    /// @notice Verifies the quote path reads `liquidity` from `poolManager.getLiquidity(poolId)`.
    ///         Adding more liquidity should reduce the dynamic fee because the same trade size
    ///         causes less price impact.
    function testLensQuote_LiquidityWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        // First swap to build up volatility state so the dynamic fee is sensitive to liquidity.
        hook.beginAccountSession();
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory lowLiqQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Add more liquidity — this increases poolManager.getLiquidity(poolId).
        _addLiquidity(address(this));
        IMemeverseUniswapHook.SwapQuote memory highLiqQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertLe(highLiqQuote.feeBps, lowLiqQuote.feeBps, "more liquidity reduces dynamic fee");
    }

    /// @notice Verifies the quote path resolves `protocolFeeOnInput` via `_resolveSwapFeeContext`.
    ///         Setting the fee currency to the input side should yield `protocolFeeOnInput = true`;
    ///         setting it to the output side should yield `protocolFeeOnInput = false`.
    function testLensQuote_ProtocolFeeLegWiring() external {
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

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

    /// @notice Verifies the quote path reads `preSqrtPriceX96` from `poolManager.getSlot0(poolId)`.
    ///         After a swap moves the price, a subsequent quote should reflect the new price,
    ///         not the original.
    function testLensQuote_PreSqrtPriceWiring() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10_000 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        IMemeverseUniswapHook.SwapQuote memory beforeQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // Execute a swap to move the price.
        hook.beginAccountSession();
        integrator.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            bytes("")
        );
        hook.endAccountSession();

        IMemeverseUniswapHook.SwapQuote memory afterQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        // After a zeroForOne swap the price moves down. The dynamic fee should differ
        // because the engine now sees a different preSqrtPriceX96.
        // We can't assert exact values, but the spot price before should differ.
        assertNotEq(afterQuote.feeBps, beforeQuote.feeBps, "price move changes fee quote");
    }
}
