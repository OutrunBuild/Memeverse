// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {FeeMath} from "../../../src/swap/libraries/FeeMath.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

/// @title MemeverseSwapForkRebateTest
/// @notice Fork tests for the on-chain referral rebate path on real Ethereum mainnet V4.
/// @dev These tests prove rebate custody closes the hook's real-v4 delta within the unlock session and that
///      claimable accounting remains solvent. Any non-zero residual delta reverts with CurrencyNotSettled.
contract MemeverseSwapForkRebateTest is MemeverseSwapForkBase {
    address internal referrer = makeAddr("referrer");

    function setUp() public {
        _setUpBase(IPermit2(address(0)));
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
    }

    function _packReferrer(address r) internal pure returns (bytes memory) {
        return abi.encodePacked(r);
    }

    // Rebate custody and `pendingRebate` live on the hook proxy. Tests use the inherited `_hook()` getter.

    function testSwap_WithReferrer_SucceedsAndAccruesRebate() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 treasuryBefore = token0.balanceOf(treasury);
        uint256 hookBefore = token0.balanceOf(address(_hook()));

        // A successful real-v4 unlock proves no CurrencyNotSettled residual delta remains.
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));

        // Rebate = protocolFee * referrerRebateBps / PROTOCOL_FEE_SHARE_BPS.
        uint256 expectedRebate =
            (quote.estimatedProtocolFeeAmount * _hook().referrerRebateBps()) / FeeMath.PROTOCOL_FEE_SHARE_BPS;
        assertEq(_hook().pendingRebateOf(referrer, key.currency0), expectedRebate, "rebate accrued to referrer");

        uint256 toTreasury = quote.estimatedProtocolFeeAmount - expectedRebate;
        assertEq(token0.balanceOf(treasury) - treasuryBefore, toTreasury, "treasury gets reduced protocol fee");

        // Solvency: hook custody >= all pending rebates (ledger-only: the hook took custody on its
        // own delta; it just ledgers the claimable balance, no separate PoolManager delta).
        assertGe(token0.balanceOf(address(_hook())) - hookBefore, expectedRebate, "hook custody >= pending rebate");
    }

    function testSwap_NoReferrer_FullProtocolFeeToTreasury() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");
        assertEq(
            token0.balanceOf(treasury) - treasuryBefore,
            quote.estimatedProtocolFeeAmount,
            "full protocol fee to treasury"
        );
        assertEq(_hook().pendingRebateOf(referrer, key.currency0), 0, "no rebate accrued");
    }

    function testSwap_SelfReferral_SucceedsAndAccruesToSwapper() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(address(this)));
        uint256 expectedRebate =
            (quote.estimatedProtocolFeeAmount * _hook().referrerRebateBps()) / FeeMath.PROTOCOL_FEE_SHARE_BPS;
        assertEq(
            _hook().pendingRebateOf(address(this), key.currency0), expectedRebate, "self-referral accrued to swapper"
        );
    }

    /// @dev Regression guard for the claim path: the referrer must be able to pull their accrued
    ///      ledger balance, receive the exact token amount, and have pending zeroed. claimRebate
    ///      debits `pendingRebate[msg.sender]`, so the referrer must be the caller; `recipient` is
    ///      only the payout destination (here the referrer pays to themselves).
    function testClaimRebate_TransfersToReferrerAndResets() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        uint256 pending = _hook().pendingRebateOf(referrer, key.currency0);
        assertGt(pending, 0, "rebate accrued");

        uint256 referrerBefore = token0.balanceOf(referrer);
        // vm.prank applies to the next external call only; claimRebate keys pending off msg.sender,
        // so the referrer must be the caller.
        vm.prank(referrer);
        uint256 claimed = _hook().claimRebate(key.currency0, referrer);
        assertEq(claimed, pending, "claimed == pending");
        assertEq(token0.balanceOf(referrer) - referrerBefore, pending, "referrer received rebate");
        assertEq(_hook().pendingRebateOf(referrer, key.currency0), 0, "pending reset after claim");
    }

    /// @dev Adversarial: paying a standard ERC20 rebate to PoolManager must not create or leave a V4
    ///      currency delta, because claimRebate only calls ERC20.transfer and PoolManager accounting is
    ///      touched only inside an unlock callback. MockERC20 has no recipient hook, so recipient-side
    ///      reentrancy is not reachable in this fork setup.
    function testClaimRebate_ToPoolManager_DoesNotBreakFutureSwap() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        uint256 pending = _hook().pendingRebateOf(referrer, key.currency0);
        assertGt(pending, 0, "rebate accrued");

        uint256 managerBefore = token0.balanceOf(address(manager));
        vm.prank(referrer);
        uint256 claimed = _hook().claimRebate(key.currency0, address(manager));

        assertEq(claimed, pending, "claimed == pending");
        assertEq(_hook().pendingRebateOf(referrer, key.currency0), 0, "pending reset");
        assertEq(token0.balanceOf(address(manager)) - managerBefore, pending, "manager received ERC20 transfer");

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, "");
    }

    // ── Adversarial rebate delta-closure matrix ───────────────────────────────────────────────
    //
    // This matrix covers every swap direction and fee side. The output-side fee path is the highest-risk:
    // the hook takes rebate custody on the OUTPUT currency in `_collectProtocolFee`
    // (called from `_afterSwap`'s exact-input branch when `!ctx.protocolFeeOnInput`), and the
    // `afterSwapReturnDelta` value must exactly offset what the hook withheld. If the unspecified delta
    // the hook returns does not match its take on the output currency, real V4 reverts the unlock with
    // `CurrencyNotSettled`. Mock settle paths would mask that, so this matrix MUST run on the real
    // mainnet V4 singleton.

    /// @dev Adversarial: asserts a referrer swap succeeds on real V4 (no CurrencyNotSettled) across
    ///      every direction × fee-side combo, and that hook solvency + treasury precision hold.
    ///      The output-side combos (A1, A3) exercise the hook's output-currency take; if `afterSwap`
    ///      returns a mismatched unspecified delta, the real V4 unlock reverts here.
    ///
    ///      `_resolveSwapFeeContext` prefers the input side when both pool sides are supported.
    ///      The rebate.t.sol setUp already registered currency0, so to force a specific fee side we
    ///      must explicitly disable the other currency first — otherwise zeroForOne always resolves
    ///      to input-side (currency0) regardless of the requested feeCurrency.
    function _assertRebateSucceeds(bool zeroForOne, Currency feeCurrency, int256 amountSpecified) internal {
        Currency otherCurrency = Currency.unwrap(feeCurrency) == address(token0) ? key.currency1 : key.currency0;
        _hook().setProtocolFeeCurrency(otherCurrency, false);
        _hook().setProtocolFeeCurrency(feeCurrency, true);
        MockERC20 feeToken = Currency.unwrap(feeCurrency) == address(token0) ? token0 : token1;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        // exact-output must supply amountInMaximum (router pulls the quoted input budget up front);
        // exact-input uses the specified magnitude as the zero-slippage maximum.
        uint256 amountInMaximum = amountSpecified > 0 ? quote.estimatedUserInputAmount : uint256(-amountSpecified);

        uint256 treasuryBefore = feeToken.balanceOf(treasury);
        uint256 hookBefore = feeToken.balanceOf(address(_hook()));

        // MUST succeed on real V4 — no CurrencyNotSettled. This is the delta-closure check.
        router.swap(key, params, address(this), block.timestamp, 0, amountInMaximum, _packReferrer(referrer));

        uint256 expectedRebate =
            (quote.estimatedProtocolFeeAmount * _hook().referrerRebateBps()) / FeeMath.PROTOCOL_FEE_SHARE_BPS;
        assertEq(_hook().pendingRebateOf(referrer, feeCurrency), expectedRebate, "rebate accrued");
        assertEq(
            feeToken.balanceOf(treasury) - treasuryBefore,
            quote.estimatedProtocolFeeAmount - expectedRebate,
            "treasury reduced"
        );
        assertGe(feeToken.balanceOf(address(_hook())) - hookBefore, expectedRebate, "hook solvency");
    }

    /// @dev A1: output-side fee + zeroForOne. Hook takes rebate on currency1 in `_afterSwap`.
    function testRebate_ZeroForOne_OutputFee() external {
        _assertRebateSucceeds(true, key.currency1, -int256(100 ether));
    }

    /// @dev A2: input-side fee + oneForZero. Hook takes rebate on currency1 in `_beforeSwap`.
    function testRebate_OneForZero_InputFee() external {
        _assertRebateSucceeds(false, key.currency1, -int256(100 ether));
    }

    /// @dev A3: output-side fee + oneForZero. Hook takes rebate on currency0 in `_afterSwap`.
    function testRebate_OneForZero_OutputFee() external {
        _assertRebateSucceeds(false, key.currency0, -int256(100 ether));
    }

    /// @dev Adversarial: exact-output + referrer + output-side fee - the exact-output twin of A1.
    ///      Unlike A1 (exact-input, afterSwap returns `unspecifiedDelta = protocolFee`), exact-output
    ///      grosses up the output delta in beforeSwap (`toBeforeSwapDelta(reservedFee, 0)`) and withholds
    ///      it via `_collectProtocolFee` on the OUTPUT currency, returning `unspecifiedDelta = lpFee only`.
    ///      The beforeSwap gross-up credit must exactly offset the afterSwap take or the real V4 unlock
    ///      reverts CurrencyNotSettled. Mock settle masks this; only the mainnet V4 singleton validates it.
    ///      This case covers exact-output with a referrer.
    function testRebate_ExactOutput_OutputFee() external {
        _assertRebateSucceeds(true, key.currency1, int256(10 ether));
    }

    /// @dev Adversarial: multiple referrer swaps accumulate, hook custody stays >= pending across
    ///      accumulations. Guards against a per-swap custody shortfall that only surfaces after N swaps.
    ///      Does NOT assume per-swap rebate is constant: each swap mutates the pool price and dynamic
    ///      fee state (ewvwap, adverse flag), so the second swap's fee can exceed the first. We read
    ///      the actual accrued balance after each swap and assert monotonic growth + solvency.
    function testRebate_MultipleSwaps_AccumulateSolvency() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        uint256 hookBefore = token0.balanceOf(address(_hook()));

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        uint256 pendingAfterOne = _hook().pendingRebateOf(referrer, key.currency0);
        assertGt(pendingAfterOne, 0, "first swap accrued");

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        uint256 pendingAfterTwo = _hook().pendingRebateOf(referrer, key.currency0);
        assertGt(pendingAfterTwo, pendingAfterOne, "second swap grew the balance");

        // Solvency invariant: hook token custody >= sum of all pending rebates in that currency.
        assertGe(token0.balanceOf(address(_hook())) - hookBefore, pendingAfterTwo, "hook solvent for accumulated");
    }

    /// @dev Adversarial: claim zeroes pending; a subsequent swap re-accrues from zero with no leftover
    ///      interference. Guards against a stale-balance carry-over bug in the accrue/claim cycle.
    ///      Does NOT assume the re-accrued amount equals the pre-claim amount (fee state drifts), only
    ///      that the claim fully zeroed pending and the next swap accrues a fresh positive balance.
    function testRebate_ClaimThenReaccrue_NoInterference() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        assertGt(_hook().pendingRebateOf(referrer, key.currency0), 0, "accrued before claim");

        vm.prank(referrer);
        _hook().claimRebate(key.currency0, referrer);
        assertEq(_hook().pendingRebateOf(referrer, key.currency0), 0, "zeroed after claim");

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));
        assertGt(_hook().pendingRebateOf(referrer, key.currency0), 0, "re-accrued after claim");
    }

    // ── B4: full-rebate boundary (rebateBps == PROTOCOL_FEE_SHARE_BPS) ─────────────────────────
    //
    // At the max rebate rate, `rebate == protocolFeeAmount` so `toTreasury == 0`. `_takeToTreasury`
    // skips the zero-amount `poolManager.take` (hook:1168). This test verifies the hook's delta still
    // closes (no CurrencyNotSettled from skipping the treasury take) and the hook receives the full
    // protocol fee. setReferrerRebateBps is `onlyOwner` on the hook; in the fork
    // base the hook owner is `address(this)`, so no prank is needed.

    /// @dev Adversarial: rebateBps = PROTOCOL_FEE_SHARE_BPS → rebate = full protocolFee, toTreasury=0.
    ///      `_takeToTreasury` skips the zero-amount take; verify delta still closes (no
    ///      CurrencyNotSettled), treasury unchanged, hook receives the full protocol fee.
    function testAdversarial_FullRebateBps_TreasurySkipsTake() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _hook().setReferrerRebateBps(FeeMath.PROTOCOL_FEE_SHARE_BPS);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));

        uint256 treasuryBefore = token0.balanceOf(treasury);
        uint256 hookBefore = token0.balanceOf(address(_hook()));

        router.swap(key, params, address(this), block.timestamp, 0, 100 ether, _packReferrer(referrer));

        assertEq(token0.balanceOf(treasury) - treasuryBefore, 0, "treasury zero (full rebate, skip take)");
        assertEq(
            _hook().pendingRebateOf(referrer, key.currency0), quote.estimatedProtocolFeeAmount, "full rebate accrued"
        );
        assertGe(
            token0.balanceOf(address(_hook())) - hookBefore, quote.estimatedProtocolFeeAmount, "hook receives full"
        );
    }
}
