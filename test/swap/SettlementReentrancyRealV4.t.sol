// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {SettlementSettleReenterer} from "../mocks/swap/SettlementSettleReenterer.sol";

/// @title SettlementReentrancyRealV4Test
/// @notice Proves successful settlement reentry fund flows against the genuine v4 PoolManager delta ledger.
/// @dev Covers both windows: transfer-window same-lock reentry (during unlock) and transferFrom-window
///      nested-unlock reentry (before unlock).
contract SettlementReentrancyRealV4Test is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal manager;
    MemeverseUniswapHook internal hook;
    SettlementSettleReenterer internal callbackToken;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal publicPoolKey;
    PoolKey internal settlementPoolKey;
    bool internal settlementZeroForOne;
    address internal treasury = address(0xFEE);
    address internal referrer = address(0xBEEF);

    function setUp() public {
        manager = deployRealPoolManager();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        callbackToken = new SettlementSettleReenterer();

        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        callbackToken.mint(address(this), 1_000_000 ether);
        // The callback token is the caller of the inner swap and must be able to pay either main-pool input.
        token0.mint(address(callbackToken), 100 ether);
        token1.mint(address(callbackToken), 100 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHook(hookProxy);
        hook.setLauncher(address(this));
        hook.setPoolInitializer(address(this));

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        callbackToken.approve(address(hook), type(uint256).max);

        publicPoolKey = _dynamicPoolKey(address(token0), address(token1));
        settlementPoolKey = _dynamicPoolKey(address(callbackToken), address(token1));
        settlementZeroForOne = Currency.unwrap(settlementPoolKey.currency0) == address(callbackToken);

        _initializeAndFundPool(publicPoolKey);
        _initializeAndFundPool(settlementPoolKey);

        hook.setProtocolFeeCurrency(publicPoolKey.currency0, true);
        hook.setProtocolFeeCurrency(Currency.wrap(address(callbackToken)), true);
        vm.warp(block.timestamp + 900);
    }

    /// @notice A callback-token reentry follows the public fee path and closes its real-v4 caller deltas.
    function test_SettlementTransferReentryPaysPublicFeeOnRealV4() public {
        MockERC20 publicInputToken = MockERC20(Currency.unwrap(publicPoolKey.currency0));
        uint256 treasuryInputBefore = publicInputToken.balanceOf(treasury);
        (, uint256 inputFeePerShareBefore,) = hook.poolInfo(publicPoolKey.toId());

        _executeReentrantSettlement(bytes(""), true);

        assertTrue(callbackToken.reentryFired(), "settlement transfer callback fired");
        assertTrue(callbackToken.reentrySwapExecuted(), "reentrant swap closed its caller deltas");
        (, uint256 inputFeePerShareAfter,) = hook.poolInfo(publicPoolKey.toId());
        assertGt(inputFeePerShareAfter, inputFeePerShareBefore, "reentrant public swap accrued LP fees");
        assertGt(publicInputToken.balanceOf(treasury), treasuryInputBefore, "reentrant public swap paid treasury");
    }

    /// @notice Reverse-direction reentry closes the opposite real-v4 settle and take delta legs.
    function test_SettlementTransferReentryClosesReverseDirectionDeltasOnRealV4() public {
        MockERC20 reverseInputToken = MockERC20(Currency.unwrap(publicPoolKey.currency1));
        MockERC20 reverseOutputToken = MockERC20(Currency.unwrap(publicPoolKey.currency0));
        uint256 inputBalanceBefore = reverseInputToken.balanceOf(address(callbackToken));
        uint256 outputBalanceBefore = reverseOutputToken.balanceOf(address(callbackToken));

        _executeReentrantSettlement(bytes(""), false);

        assertTrue(callbackToken.reentryFired(), "settlement transfer callback fired");
        assertTrue(callbackToken.reentrySwapExecuted(), "reverse reentrant swap closed its caller deltas");
        assertLt(reverseInputToken.balanceOf(address(callbackToken)), inputBalanceBefore, "currency1 input settled");
        assertGt(reverseOutputToken.balanceOf(address(callbackToken)), outputBalanceBefore, "currency0 output taken");
        assertGt(
            callbackToken.reentryPostSqrtPriceX96(),
            callbackToken.reentryPreSqrtPriceX96(),
            "reverse swap increased price"
        );
    }

    /// @notice The outer settlement still completes its input fees, LP custody, and output delivery.
    function test_SettlementTransferReentryPreservesOuterSettlementOnRealV4() public {
        uint256 payerInputBefore = callbackToken.balanceOf(address(this));
        uint256 treasuryInputBefore = callbackToken.balanceOf(treasury);
        uint256 hookInputBefore = callbackToken.balanceOf(address(hook));
        uint256 recipientOutputBefore = token1.balanceOf(address(this));

        _executeReentrantSettlement(bytes(""), true);

        assertTrue(callbackToken.reentrySwapExecuted(), "reentrant swap completed");
        assertEq(payerInputBefore - callbackToken.balanceOf(address(this)), 10 ether, "payer funded settlement");
        assertEq(callbackToken.balanceOf(treasury) - treasuryInputBefore, 0.035 ether, "treasury received fee");
        assertEq(callbackToken.balanceOf(address(hook)) - hookInputBefore, 0.065 ether, "hook retained LP fee");
        assertGt(token1.balanceOf(address(this)) - recipientOutputBefore, 0, "recipient received settlement output");
    }

    /// @notice Reentrant public-swap rebates are backed by tokens held by the hook on real v4.
    function test_SettlementTransferReentryPreservesRebateCustodyOnRealV4() public {
        MockERC20 publicInputToken = MockERC20(Currency.unwrap(publicPoolKey.currency0));
        uint256 hookInputBefore = publicInputToken.balanceOf(address(hook));

        _executeReentrantSettlement(abi.encodePacked(referrer), true);

        uint256 pendingRebate = hook.pendingRebateOf(referrer, publicPoolKey.currency0);
        assertTrue(callbackToken.reentrySwapExecuted(), "reentrant swap completed");
        assertGt(pendingRebate, 0, "reentrant public swap accrued rebate");
        assertGe(
            publicInputToken.balanceOf(address(hook)) - hookInputBefore,
            pendingRebate,
            "hook custody covers pending rebate"
        );
    }

    /// @notice transferFrom-window reentry (before unlock) opens a nested unlock, closes its own deltas, and
    ///         leaves the outer settlement fund flow intact on real v4.
    /// @dev Unlike the transfer-window tests (same-lock direct swap inside settle), this path fires from the
    ///      Phase 1 protocol-fee `transferFrom` and must open a fresh unlock because the outer lock is not yet open.
    function test_SettlementTransferFromReentryClosesOwnUnlockAndPreservesOuterOnRealV4() public {
        MockERC20 publicInputToken = MockERC20(Currency.unwrap(publicPoolKey.currency0));
        uint256 treasuryPublicInputBefore = publicInputToken.balanceOf(treasury);
        (, uint256 inputFeePerShareBefore,) = hook.poolInfo(publicPoolKey.toId());

        uint256 payerInputBefore = callbackToken.balanceOf(address(this));
        uint256 treasuryInputBefore = callbackToken.balanceOf(treasury);
        uint256 hookInputBefore = callbackToken.balanceOf(address(hook));
        uint256 recipientOutputBefore = token1.balanceOf(address(this));

        _executeTransferFromReentrantSettlement(true);

        assertTrue(callbackToken.reentryFired(), "transferFrom reentry fired");
        assertTrue(callbackToken.reentrySwapExecuted(), "nested unlock closed its caller deltas");

        // Outer settlement fund flow (same shape as transfer-window outer preservation).
        assertEq(payerInputBefore - callbackToken.balanceOf(address(this)), 10 ether, "payer funded settlement");
        assertEq(callbackToken.balanceOf(treasury) - treasuryInputBefore, 0.035 ether, "treasury received fee");
        assertEq(callbackToken.balanceOf(address(hook)) - hookInputBefore, 0.065 ether, "hook retained LP fee");
        assertGt(token1.balanceOf(address(this)) - recipientOutputBefore, 0, "recipient received settlement output");

        // Inner nested unlock took the public fee path on publicPoolKey.
        (, uint256 inputFeePerShareAfter,) = hook.poolInfo(publicPoolKey.toId());
        assertGt(inputFeePerShareAfter, inputFeePerShareBefore, "reentrant public swap accrued LP fees");
        assertGt(publicInputToken.balanceOf(treasury), treasuryPublicInputBefore, "reentrant public swap paid treasury");
    }

    function _executeReentrantSettlement(bytes memory hookData, bool reentryZeroForOne) internal {
        callbackToken.armWithHookData(manager, publicPoolKey, _reentrySwapParams(reentryZeroForOne), hookData);
        _runSettlement();
    }

    /// @dev transferFrom-window arm: reentry opens its own unlock before the outer settlement unlock starts.
    function _executeTransferFromReentrantSettlement(bool reentryZeroForOne) internal {
        callbackToken.armTransferFrom(manager, publicPoolKey, _reentrySwapParams(reentryZeroForOne));
        _runSettlement();
    }

    function _runSettlement() internal {
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: settlementPoolKey, params: _settlementSwapParams(), recipient: address(this)
            })
        );
    }

    function _reentrySwapParams(bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(0.01 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _settlementSwapParams() internal view returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: settlementZeroForOne,
            amountSpecified: -int256(10 ether),
            sqrtPriceLimitX96: settlementZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _dynamicPoolKey(address currencyA, address currencyB) internal view returns (PoolKey memory key) {
        (address currency0, address currency1) = currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _initializeAndFundPool(PoolKey memory key) internal {
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }
}
