// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "./SafeCast.sol";

/// @title SwapFeeMath
/// @notice Pure swap amount helpers and the fee context shared by SwapFacet, SettlementFacet, and
///         MemeverseSwapRouter. Contains no storage or events.
/// @dev Selector-equivalence rule: `CurrencyNotSupported` is selector-identical to its counterpart
///      declared on `IMemeverseUniswapHook`. Solidity error selectors depend only on `name(params)`,
///      so the same-name no-arg definitions stay byte-equal; drift is anchored by
///      `testQuoteSwapReverts_WhenProtocolFeeCurrencyUnsupported`.
library SwapFeeMath {
    using SafeCast for int128;

    /// @dev Canonical input/output and protocol-fee leg context shared by swap and settlement accounting.
    struct SwapFeeContext {
        Currency currencyIn;
        Currency currencyOut;
        bool protocolFeeOnInput;
        bool inputIsCurrency0;
    }

    /// @notice Selector-identical to `IMemeverseUniswapHook.CurrencyNotSupported` (see file-level note).
    error CurrencyNotSupported();

    /// @notice Returns the protocol-fee leg when the input currency is NOT supported.
    /// @dev Shared by `MemeverseSwapFeeBase._resolveSwapFeeContext` and
    ///      `MemeverseUniswapHookLens._protocolFeeOnInput`. Callers short-circuit the input-supported
    ///      case via `||` (returns true) before calling, so this helper only handles the output leg
    ///      (output supported → false) and reverts `CurrencyNotSupported` when neither leg is
    ///      registered.
    /// @param outputSupported Whether the output currency is registered for protocol fees.
    /// @return protocolFeeOnInput Always false (output leg); reverts if neither leg is supported.
    function protocolFeeOnInputOrRevert(bool outputSupported) internal pure returns (bool protocolFeeOnInput) {
        // Reaching here means the input leg is NOT the fee leg (caller's `||` short-circuited it).
        // Output supported → fee falls on the output leg → protocolFeeOnInput is false.
        if (outputSupported) return false;
        revert CurrencyNotSupported();
    }

    /// @notice Resolves input and output currencies for a swap direction.
    /// @dev Single source of truth for the zeroForOne → (currencyIn, currencyOut) mapping.
    ///      Shared by SwapFacet, SettlementFacet, MemeverseSwapFeeBase, MemeverseUniswapHookLens,
    ///      and MemeverseSwapRouter so the two currency legs cannot drift apart. Call sites that
    ///      need only one leg keep the inline ternary for readability.
    /// @param key The pool key defining currency0 and currency1.
    /// @param zeroForOne True when swapping currency0 for currency1.
    /// @return currencyIn The currency the swapper sells (flowing into the pool).
    /// @return currencyOut The currency the swapper buys (flowing out of the pool).
    function swapCurrencies(PoolKey calldata key, bool zeroForOne)
        internal
        pure
        returns (Currency currencyIn, Currency currencyOut)
    {
        if (zeroForOne) return (key.currency0, key.currency1);
        return (key.currency1, key.currency0);
    }

    /// @dev BalanceDelta uses the pool's perspective: a negative amount means tokens flowed INTO the pool
    ///      (the user paid them), so the absolute value is the input amount the user provided.
    function actualInputAmount(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne ? uint256((-delta.amount0()).toUint128()) : uint256((-delta.amount1()).toUint128());
    }

    /// @dev BalanceDelta uses the pool's perspective: a positive amount means tokens flowed OUT of the pool
    ///      (the user received them), so the raw value is the output amount the user got.
    function actualOutputAmount(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne ? uint256(delta.amount1().toUint128()) : uint256(delta.amount0().toUint128());
    }
}
