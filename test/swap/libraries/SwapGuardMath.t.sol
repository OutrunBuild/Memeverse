// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SwapGuardMath} from "../../../src/swap/libraries/SwapGuardMath.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

/// @notice Harness exposing the library's internal helpers so a Solidity test can call them.
contract SwapGuardMathHarness {
    function exposed_revertIfPublicSwapBlocked(uint40 resumeTime) external view {
        SwapGuardMath.revertIfPublicSwapBlocked(resumeTime);
    }

    function exposed_revertIfNoActiveLiquidityShares(uint128 liquidity) external pure {
        SwapGuardMath.revertIfNoActiveLiquidityShares(liquidity);
    }

    function exposed_revertIfNativeCurrencyUnsupported(Currency currency0, Currency currency1) external pure {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(currency0, currency1);
    }
}

/// @notice Focused tests for the shared public-swap revert gates.
contract SwapGuardMathTest is Test {
    SwapGuardMathHarness internal harness = new SwapGuardMathHarness();

    // -----------------------------------------------------------------
    // revertIfPublicSwapBlocked
    // -----------------------------------------------------------------

    /// @notice resumeTime==0 means "never paused" — must not revert.
    function testPublicSwapBlock_NeverPaused_DoesNotRevert() external {
        harness.exposed_revertIfPublicSwapBlocked(0);
    }

    /// @notice resumeTime in the future is "still paused" — must revert.
    function testPublicSwapBlock_ResumeTimeInFuture_Reverts() external {
        uint40 future = uint40(block.timestamp) + 600;
        vm.expectRevert(SwapGuardMath.PublicSwapDisabled.selector);
        harness.exposed_revertIfPublicSwapBlocked(future);
    }

    /// @notice resumeTime in the past is "already resumed" — must not revert.
    function testPublicSwapBlock_ResumeTimeInPast_DoesNotRevert() external {
        // Foundry's default block.timestamp is 0, so warp forward before computing a past resume time.
        vm.warp(1_700_000_000);
        uint40 past = uint40(block.timestamp) - 600;
        harness.exposed_revertIfPublicSwapBlocked(past);
    }

    /// @notice At exactly resumeTime the gate is open (block.timestamp < resumeTime is false).
    function testPublicSwapBlock_AtResumeTime_DoesNotRevert() external {
        // Foundry's default block.timestamp is 0; warp forward first so nowTs != 0 and the gate's
        // `resumeTime != 0` early-return cannot hide the block.timestamp == resumeTime boundary.
        vm.warp(1_700_000_000);
        uint40 nowTs = uint40(block.timestamp);
        harness.exposed_revertIfPublicSwapBlocked(nowTs);
    }

    // -----------------------------------------------------------------
    // revertIfNoActiveLiquidityShares
    // -----------------------------------------------------------------
    // Every call site checks `cachedLpTotalSupply` and returns early when `cached != 0` before calling this
    // helper. Integration tests cover that caller precheck; these unit tests cover the helper's two branches:
    // liquidity==0 (drained pool, do not revert) and liquidity>0 (orphaned pool, revert).

    /// @notice No v4 liquidity — fully drained pool — must not revert (quote path returns 0).
    function testNoActiveShares_NoLiquidity_DoesNotRevert() external {
        harness.exposed_revertIfNoActiveLiquidityShares(0);
    }

    /// @notice Live v4 liquidity but the caller already passed the cached-supply precheck — orphaned pool, must revert.
    function testNoActiveShares_OnlyV4Liquidity_Reverts() external {
        vm.expectRevert(SwapGuardMath.NoActiveLiquidityShares.selector);
        harness.exposed_revertIfNoActiveLiquidityShares(5_000 ether);
    }

    // -----------------------------------------------------------------
    // revertIfNativeCurrencyUnsupported
    // -----------------------------------------------------------------

    /// @notice Both pool sides are ERC20 (non-zero) — gate passes, no revert.
    function testNativeCurrency_BothErc20_DoesNotRevert() external {
        harness.exposed_revertIfNativeCurrencyUnsupported(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)));
    }

    /// @notice currency0 being native (zero-address) must trip the gate.
    function testNativeCurrency_Currency0Native_Reverts() external {
        vm.expectRevert(SwapGuardMath.NativeCurrencyUnsupported.selector);
        harness.exposed_revertIfNativeCurrencyUnsupported(Currency.wrap(address(0)), Currency.wrap(address(0x2)));
    }

    /// @notice currency1 being native (zero-address) must trip the gate.
    function testNativeCurrency_Currency1Native_Reverts() external {
        vm.expectRevert(SwapGuardMath.NativeCurrencyUnsupported.selector);
        harness.exposed_revertIfNativeCurrencyUnsupported(Currency.wrap(address(0x1)), Currency.wrap(address(0)));
    }

    // -----------------------------------------------------------------
    // Selector consistency — library and interface definitions MUST have identical 4-byte selectors so
    // callers, tests, and indexers observe the same revert identifiers.
    // -----------------------------------------------------------------

    /// @notice PublicSwapDisabled has the same stable 4-byte selector in the library and interface.
    function testSelector_PublicSwapDisabled_UnchangedAcrossDefinitions() external pure {
        bytes4 libSelector = SwapGuardMath.PublicSwapDisabled.selector;
        bytes4 ifaceSelector = IMemeverseUniswapHook.PublicSwapDisabled.selector;
        assertEq(libSelector, ifaceSelector, "PublicSwapDisabled selector must match interface definition");
        // Literal pin guards against symmetric drift: if both definitions gain the same parameter,
        // lib==iface still holds while off-chain consumers decoding the selector would break.
        assertEq(libSelector, bytes4(0xa6700c86), "PublicSwapDisabled selector must stay 0xa6700c86");
    }

    /// @notice NoActiveLiquidityShares has the same stable 4-byte selector in the library and interface.
    function testSelector_NoActiveLiquidityShares_UnchangedAcrossDefinitions() external pure {
        bytes4 libSelector = SwapGuardMath.NoActiveLiquidityShares.selector;
        bytes4 ifaceSelector = IMemeverseUniswapHook.NoActiveLiquidityShares.selector;
        assertEq(libSelector, ifaceSelector, "NoActiveLiquidityShares selector must match interface definition");
        // Literal pin against symmetric drift (see testSelector_PublicSwapDisabled_* for rationale).
        assertEq(libSelector, bytes4(0xc0eac340), "NoActiveLiquidityShares selector must stay 0xc0eac340");
    }

    /// @notice NativeCurrencyUnsupported has the same stable 4-byte selector in the library and interface.
    function testSelector_NativeCurrencyUnsupported_UnchangedAcrossDefinitions() external pure {
        bytes4 libSelector = SwapGuardMath.NativeCurrencyUnsupported.selector;
        bytes4 ifaceSelector = IMemeverseUniswapHook.NativeCurrencyUnsupported.selector;
        assertEq(libSelector, ifaceSelector, "NativeCurrencyUnsupported selector must match interface definition");
        // Literal pin against symmetric drift (see testSelector_PublicSwapDisabled_* for rationale).
        assertEq(libSelector, bytes4(0x708b8d6a), "NativeCurrencyUnsupported selector must stay 0x708b8d6a");
    }
}
