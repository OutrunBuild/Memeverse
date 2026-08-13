// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title SwapGuardMath
/// @notice Shared revert gates for the public-swap path. The Lens reads hook getters and the facets read
///         shared storage, but both feed the resolved values into these helpers so the gate logic itself
///         has a single definition and cannot drift between the quote path and the execution path.
/// @dev Selector-equivalence rule: each error below is selector-identical to its counterpart declared on
///      `IMemeverseUniswapHook`. Solidity error selectors
///      depend only on `name(params)` — defining same-name no-arg errors in this library keeps the 4-byte
///      selector observed by callers, tests, and indexers unchanged. The equality holds only while both
///      definitions stay same-name no-arg; drift is anchored by
///      `SwapGuardMathTest.testSelector_*_UnchangedAcrossDefinitions`.
library SwapGuardMath {
    /// @notice Selector-identical to `IMemeverseUniswapHook.PublicSwapDisabled` (see file-level note).
    error PublicSwapDisabled();

    /// @notice Selector-identical to `IMemeverseUniswapHook.NoActiveLiquidityShares` (see file-level note).
    error NoActiveLiquidityShares();

    /// @notice Selector-identical to `IMemeverseUniswapHook.NativeCurrencyUnsupported` (see file-level note).
    error NativeCurrencyUnsupported();

    /// @notice Reverts while public swaps are still paused.
    /// @param resumeTime Per-pool `publicSwapResumeTime`; 0 means never paused.
    function revertIfPublicSwapBlocked(uint40 resumeTime) internal view {
        if (resumeTime != 0 && block.timestamp < resumeTime) revert PublicSwapDisabled();
    }

    /// @notice Reverts on orphaned liquidity: the pool has live v4 liquidity but zero claimable LP shares.
    /// @dev Amount-agnostic by design. The quote path (Lens) and the public-swap path (SwapFacet) perform
    ///      their own `amountSpecified == 0` early-exit before calling; the settlement path never sees
    ///      `amountSpecified == 0` because `executeSettlementLogic` pre-rejects it via `ZeroValue`. Keeping
    ///      the gate amount-agnostic is what lets all callers share one definition.
    ///      Callers MUST pre-check `cachedLpTotalSupply != 0` (and early-return on `!= 0`) before invoking;
    ///      this helper only encodes the orphaned-liquidity branch (cached == 0 + liquidity > 0 → revert).
    ///      The cached argument was removed because every call site already gates on it. This does NOT
    ///      cover the LP-fee divide-by-zero guard in
    ///      `SettlementFacet._collectPreorderSettlementInputFees` (that check guards on the
    ///      caller-supplied `effectiveSupply` to protect a per-share division — different semantics).
    /// @param liquidity Live v4 pool liquidity from `poolManager.getLiquidity(poolId)`.
    function revertIfOrphanedLiquidity(uint128 liquidity) internal pure {
        if (liquidity == 0) return;
        revert NoActiveLiquidityShares();
    }

    /// @notice Reverts when a pool pair includes native (zero-address) currency; Memeverse pools are ERC20-only.
    /// @dev Single source of the pool-pair native-currency gate (was 4 hand-synced copies across
    ///      Hook / SwapFacet / Router / Lens); do not re-inline. The per-currency native-currency rejection
    ///      in `MemeverseUniswapHookUpgradeable.setProtocolFeeCurrency` is a separate check and stays inline.
    /// @param currency0 One side of the pool pair.
    /// @param currency1 The other side of the pool pair.
    function revertIfNativeCurrencyUnsupported(Currency currency0, Currency currency1) internal pure {
        if (currency0.isAddressZero() || currency1.isAddressZero()) revert NativeCurrencyUnsupported();
    }
}
