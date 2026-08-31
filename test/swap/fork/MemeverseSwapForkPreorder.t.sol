// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

contract MemeverseSwapForkPreorderTest is MemeverseSwapForkBase {
    using BalanceDeltaLibrary for BalanceDelta;

    function setUp() public {
        _setUpBase(IPermit2(address(0)));
        // executePreorderSettlement is launcher-only and pulls input via transferFrom(msg.sender);
        // the fork base deploys this contract as the launcher, so just approve the hook here.
        token0.approve(address(_hook()), type(uint256).max);
        token1.approve(address(_hook()), type(uint256).max);
    }

    /// @dev For each (direction, feeCurrency): assert delta direction, fee lands only on the fee
    ///      side, and token conservation across all holders (hook + treasury + manager + recipient).
    ///      10 ether stays well inside the 100-ether pool.
    function _assertPreorderConservation(bool zeroForOne, Currency feeCurrency) internal {
        _hook().setProtocolFeeCurrency(feeCurrency, true);

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        bool feeOnInput = Currency.unwrap(feeCurrency) == Currency.unwrap(inputCurrency);

        uint256 payerInBefore = _bal(inputCurrency, address(this));
        uint256 payerOutBefore = _bal(outputCurrency, address(this));
        uint256 treasuryInBefore = _bal(inputCurrency, treasury);
        uint256 treasuryOutBefore = _bal(outputCurrency, treasury);
        // Hook proxy custody of LP fees: input-side fee pulls lpFee via transferFrom into address(key.hooks).
        uint256 hookInBefore = _bal(inputCurrency, address(key.hooks));
        uint256 hookOutBefore = _bal(outputCurrency, address(key.hooks));
        uint256 mgrInBefore = _bal(inputCurrency, address(manager));
        uint256 mgrOutBefore = _bal(outputCurrency, address(manager));
        uint40 launchTsBefore = _hook().poolLaunchTimestamp(poolId);

        BalanceDelta delta = _hook()
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                    key: key,
                    params: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -10 ether,
                        sqrtPriceLimitX96: _validExecutionPriceLimit(zeroForOne)
                    }),
                    recipient: address(this)
                })
            );

        if (zeroForOne) {
            assertLt(delta.amount0(), 0, "delta0");
            assertGt(delta.amount1(), 0, "delta1");
        } else {
            assertLt(delta.amount1(), 0, "delta1");
            assertGt(delta.amount0(), 0, "delta0");
        }

        uint256 payerInDec = payerInBefore - _bal(inputCurrency, address(this));
        uint256 hookInInc = _bal(inputCurrency, address(key.hooks)) - hookInBefore;
        uint256 treasuryInInc = _bal(inputCurrency, treasury) - treasuryInBefore;
        uint256 mgrInInc = _bal(inputCurrency, address(manager)) - mgrInBefore;
        uint256 mgrOutDec = mgrOutBefore - _bal(outputCurrency, address(manager));
        uint256 recipientOutInc = _bal(outputCurrency, address(this)) - payerOutBefore;
        uint256 treasuryOutInc = _bal(outputCurrency, treasury) - treasuryOutBefore;
        uint256 hookOutInc = _bal(outputCurrency, address(key.hooks)) - hookOutBefore;

        // Fee lands only on the fee currency side.
        if (feeOnInput) {
            assertGt(treasuryInInc, 0, "treasury received input-side fee");
            assertEq(treasuryOutInc, 0, "no output-side treasury fee");
        } else {
            assertGt(treasuryOutInc, 0, "treasury received output-side fee");
            assertEq(treasuryInInc, 0, "no input-side treasury fee");
        }

        // Token conservation across every holder (settlement takes no persistent custody):
        //   input : payer decrease == hook + treasury + pool increase
        //   output: pool decrease   == recipient + treasury + hook increase
        assertEq(payerInDec, hookInInc + treasuryInInc + mgrInInc, "input conservation");
        assertEq(mgrOutDec, recipientOutInc + treasuryOutInc + hookOutInc, "output conservation");

        // Preorder must not rewrite the launch timestamp.
        assertEq(_hook().poolLaunchTimestamp(poolId), launchTsBefore, "launch timestamp unchanged");
    }

    function _bal(Currency currency, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    function testPreorder_ZeroForOne_InputFee() external {
        _assertPreorderConservation(true, key.currency0);
    }

    function testPreorder_ZeroForOne_OutputFee() external {
        _assertPreorderConservation(true, key.currency1);
    }

    function testPreorder_OneForZero_InputFee() external {
        _assertPreorderConservation(false, key.currency1);
    }

    function testPreorder_OneForZero_OutputFee() external {
        _assertPreorderConservation(false, key.currency0);
    }

    /// @dev Adversarial: a preorder settlement is a hook-initiated swap, so Uniswap v4 skips its
    ///      beforeSwap and afterSwap callbacks. The next public router swap must use the normal
    ///      callback fee path and pay treasury.
    function testPreorderThenPublicSwap_FeePathRestored() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);

        SwapParams memory preorderParams = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        _hook()
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                    key: key, params: preorderParams, recipient: address(this)
                })
            );

        SwapParams memory publicParams = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        uint256 treasuryBefore = token0.balanceOf(treasury);

        _swapInSession(key, publicParams, 0, 10 ether, "");

        assertGt(token0.balanceOf(treasury), treasuryBefore, "public swap charged treasury fee");
    }

    /// @dev Adversarial: public -> preorder -> public verifies path isolation: the settlement succeeds,
    ///      and both public swaps retain the normal treasury-fee behavior.
    function testPublicSwapThenPreorderThenPublicSwap_AllSucceed() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        SwapParams memory publicParams = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        SwapParams memory preorderParams = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        uint256 treasuryBeforeFirstPublic = token0.balanceOf(treasury);
        _swapInSession(key, publicParams, 0, 10 ether, "");
        uint256 treasuryAfterFirstPublic = token0.balanceOf(treasury);
        assertGt(treasuryAfterFirstPublic, treasuryBeforeFirstPublic, "first public swap charged fee");

        _hook()
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                    key: key, params: preorderParams, recipient: address(this)
                })
            );

        _swapInSession(key, publicParams, 0, 10 ether, "");
        assertGt(token0.balanceOf(treasury), treasuryAfterFirstPublic, "second public swap charged fee");
    }

    /// @dev Ordinary-pool preorder settlement: neither currency registered. Pins that the settlement
    ///      path resolves the fee to the input leg (currency0 for zeroForOne=true) instead of reverting,
    ///      and charges the input fee to the treasury. Mirrors the registered-currency preorder matrix
    ///      above with both protocol-fee flags cleared — the protocol-fee path no longer reverts, so an
    ///      ordinary-pool preorder must succeed and accrue a fee on the input side only.
    function testPreorder_OrdinaryPool_SucceedsAndChargesInputFee() external {
        // Explicit: neither side is a registered protocol-fee currency.
        _hook().setProtocolFeeCurrency(key.currency0, false);
        _hook().setProtocolFeeCurrency(key.currency1, false);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);

        BalanceDelta delta = _hook()
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({key: key, params: params, recipient: address(this)})
            );

        // zeroForOne=true: input (currency0) flows into the pool, output (currency1) to the recipient.
        assertLt(delta.amount0(), 0, "input flowed in");
        assertGt(delta.amount1(), 0, "output produced");

        // Ordinary-pool resolution: input leg carries the fee. Treasury0 increases by a non-zero amount;
        // treasury1 is unchanged so a stray output-side fee cannot masquerade as success.
        assertGt(token0.balanceOf(treasury) - treasury0Before, 0, "treasury charged input-side fee");
        assertEq(token1.balanceOf(treasury) - treasury1Before, 0, "no output-side fee on ordinary pool");
    }

    /// @dev executePreorderSettlement is launcher-only (hook onlyLauncher modifier -> Unauthorized).
    ///      A non-launcher caller is rejected at the hook entry. Hook-level error, exact selector.
    function test_RevertWhen_Preorder_NonLauncher() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        address attacker = makeAddr("attacker");
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        vm.prank(attacker); // attacker != launcher (this contract)
        vm.expectRevert(IMemeverseUniswapHook.Unauthorized.selector);
        _hook()
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({key: key, params: params, recipient: address(this)})
            );
    }
}
