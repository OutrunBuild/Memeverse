// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title IMemeverseYTFlashSwapRouter
/// @notice Public ABI for the YT Flash Swap Router, which reuses the canonical PT/POL Uniswap v4 pool to swap POL
///         against exact YT amounts without creating a second AMM. The router is a normal PoolManager swap caller;
///         `unlockCallback` is a PoolManager-only technical callback, not a user entrypoint.
/// @dev This interface deliberately does not inherit `IUnlockCallback`: the callback is exposed by the router
///      contract via `SafeCallback`, not part of the user-facing surface defined here.
interface IMemeverseYTFlashSwapRouter {
    // =====================================================================================
    // User-input validation
    // =====================================================================================

    /// @notice Reverts when `deadline` is in the past.
    error ExpiredPastDeadline();

    /// @notice Reverts when the constructor is deployed with a zero-address `manager_`, `hook_`, or `splitter_`.
    error ZeroAddress();

    /// @notice Reverts when the constructor is deployed with a `hook_` that has no deployed code.
    /// @dev Checked before reading `hook_.poolManager()` so a no-code hook fails with a named error instead of an
    ///      opaque ABI-decode revert from the immutable-getter STATICCALL.
    error HookCodeNotReady(address hook);

    /// @notice Reverts when the constructor is deployed with a `manager_` that has no deployed code.
    /// @dev Checked before the diagonal `manager_ == hook_.poolManager()` compare so a no-code manager fails with a named
    ///      error. `manager_` is already bound as the `SafeCallback`/`ImmutableState` immutable `poolManager` before the
    ///      constructor body runs; this check cannot prevent that binding, but it prevents the deployment from succeeding.
    error PoolManagerCodeNotReady(address poolManager);

    /// @notice Reverts when the constructor is deployed with a `splitter_` that has no deployed code.
    /// @dev Mirrors `HookCodeNotReady`: a no-code `splitter_` would otherwise first fail as an opaque ABI-decode revert
    ///      at the runtime `getPTAndYTAndPOL` / `split` / `merge` calls.
    error SplitterCodeNotReady(address splitter);

    /// @notice Reverts when the constructor `manager_` differs from the hook's immutable PoolManager.
    /// @dev Operational guardrail (not a security boundary): the Router and Hook each bind an immutable PoolManager;
    ///      a mismatch would make every swap revert at the Hook's `onlyPoolManager`. Mirrors the codebase's
    ///      `FacetPoolManagerMismatch`/`UpgradePoolManagerMismatch`/`HookLensPoolManagerMismatch`.
    error RouterPoolManagerMismatch(address routerPoolManager, address hookPoolManager);

    /// @notice Reverts when `recipient` is the zero address or the router itself.
    error InvalidRecipient(address recipient);

    /// @notice Reverts when the exact YT amount is zero or exceeds the v4 signed-delta safe range.
    /// @dev `maxPOLIn` and `minPOLOut` keep full `uint256` comparison semantics and are NOT capped by this guard.
    error AmountOutOfRange(uint256 amount);

    // =====================================================================================
    // Identity, canonical dependency and verse-asset resolution
    // =====================================================================================

    /// @notice Reverts when the hook-captured active account-session principal is not `msg.sender`.
    /// @dev Scoped to this router's entry validation. It is a distinct contract from the hook's afterSwap-only
    ///      `AccountSessionPrincipalMismatch`; both no-session (`active == address(0)`) and mismatched-principal
    ///      cases are captured by the same check `active != msg.sender`.
    /// @param active Active session principal returned by the hook (`address(0)` when no session is active).
    /// @param caller `msg.sender` of the user entry.
    error AccountSessionPrincipalMismatch(address active, address caller);

    /// @notice Reverts when the hook's current launcher does not bind this router's hook and splitter as canonical.
    /// @param expectedHook Router immutable hook address.
    /// @param canonicalHook Hook address advertised by the launcher.
    /// @param expectedSplitter Router immutable splitter address.
    /// @param canonicalSplitter Splitter address advertised by the launcher.
    error CanonicalDependencyMismatch(
        address expectedHook, address canonicalHook, address expectedSplitter, address canonicalSplitter
    );

    /// @notice Reverts when the hook's current launcher is the zero address or has no deployed code.
    /// @dev Checked before the `getLauncherContracts()` external read so a no-code launcher fails with a named error
    ///      instead of an opaque ABI-decode revert from the empty-return STATICCALL. Mirrors the constructor's
    ///      `HookCodeNotReady` code-length-first ordering.
    error LauncherCodeNotReady(address launcher);

    /// @notice Reverts when the canonical splitter returns a zero, repeated, or non-contract (no deployed code)
    ///         PT/YT/POL address for `verseId`.
    error InvalidCanonicalVerseAssets(uint256 verseId, address pt, address yt, address pol);

    // =====================================================================================
    // One-shot callback context guards
    // =====================================================================================

    /// @notice Reverts when a callback payload's hash does not match the context committed by `_runFlashSwap`, or when no
    ///         one-shot context is pending.
    error UnexpectedOrTamperedCallback(bytes32 expected, bytes32 actual);

    /// @notice Reverts when `PoolManager.unlock` returns without consuming (clearing) the pending context hash.
    error CallbackNotConsumed(bytes32 pending);

    // =====================================================================================
    // Postcondition guards
    // =====================================================================================

    /// @notice Reverts when a Router PT/YT/POL balance is not restored to its pre-entry baseline.
    error RouterBalanceMismatch(address token, uint256 expected, uint256 actual);

    /// @notice Reverts when the Splitter POL allowance is not fully consumed after a buy split.
    error SplitterAllowanceResidual(uint256 remaining);

    /// @notice Reverts when an ERC20 `approve` call returns false.
    error ApprovalFailed(address token, address spender, uint256 amount);

    /// @notice Reverts when a Splitter split does not mint exactly the requested PT and YT.
    error SplitResultMismatch(uint256 pt, uint256 yt, uint256 expected);

    /// @notice Reverts when a Splitter merge does not return exactly the requested POL.
    error MergeResultMismatch(uint256 merged, uint256 expected);

    // =====================================================================================
    // Settlement-structure guards
    // =====================================================================================

    /// @notice Reverts when the real swap delta does not match the fixed-y structure (signs, legs, full fill).
    /// @dev Never compares against a historical quote.
    error FlashDeltaMismatch(int128 ptDelta, int128 polDelta);

    /// @notice Reverts when the buy net POL output `R_actual` is zero or not strictly less than `y`.
    error InvalidBuyCost(uint256 r, uint256 y);

    /// @notice Reverts when the sell net POL input `Q_actual` is zero or not strictly less than `y`.
    error InvalidSellDebt(uint256 q, uint256 y);

    /// @notice Reverts when the buy actual POL cost exceeds the caller's `maxPOLIn` bound.
    error MaxPOLInExceeded(uint256 actual, uint256 maximum);

    /// @notice Reverts when the sell actual POL output is below the caller's `minPOLOut` bound.
    error MinPOLOutNotMet(uint256 actual, uint256 minimum);

    // =====================================================================================
    // Events
    // =====================================================================================

    /// @notice Emitted after a successful POL -> exact YT flash swap, once every delta, balance, and allowance
    ///         postcondition has cleared.
    /// @param verseId Canonical verse id of the PT/YT/POL triple.
    /// @param payer `msg.sender`, also the active account-session principal.
    /// @param recipient Recipient of the exact YT output (never the router).
    /// @param exactYTOut Exact YT amount received by `recipient`.
    /// @param polInUsed Actual POL pulled from `payer`.
    /// @param referrer Referrer address forwarded to the hook (`address(0)` if none).
    event YTFlashSwapPOLForYT(
        uint256 indexed verseId,
        address indexed payer,
        address indexed recipient,
        uint256 exactYTOut,
        uint256 polInUsed,
        address referrer
    );

    /// @notice Emitted after a successful exact YT -> POL flash swap, once every delta, balance, and allowance
    ///         postcondition has cleared.
    /// @param verseId Canonical verse id of the PT/YT/POL triple.
    /// @param payer `msg.sender`, also the active account-session principal.
    /// @param recipient Recipient of the net POL output (never the router).
    /// @param exactYTIn Exact YT amount sold by `payer`.
    /// @param polOut Net POL amount sent to `recipient`.
    /// @param referrer Referrer address forwarded to the hook (`address(0)` if none).
    event YTFlashSwapYTForPOL(
        uint256 indexed verseId,
        address indexed payer,
        address indexed recipient,
        uint256 exactYTIn,
        uint256 polOut,
        address referrer
    );

    // =====================================================================================
    // User entrypoints
    // =====================================================================================

    /// @notice Swap POL for an exact amount of YT, reusing the canonical PT/POL pool via a single flash swap.
    /// @param verseId Canonical verse id resolving PT/YT/POL via the canonical splitter.
    /// @param exactYTOut Exact YT amount to deliver to `recipient`.
    /// @param maxPOLIn Maximum POL to pull from `msg.sender` (full uint256 bound, no int128 cap).
    /// @param sqrtPriceLimitX96 Price limit applied to the underlying PT/POL swap.
    /// @param recipient Recipient of the YT output; must not be zero or the router.
    /// @param deadline Latest valid execution timestamp (inclusive).
    /// @param referrer Referrer forwarded to the hook as packed `hookData`, or `address(0)` for empty `hookData`.
    /// @return polInUsed Actual POL pulled from `msg.sender`.
    function swapPOLForExactYT(
        uint256 verseId,
        uint256 exactYTOut,
        uint256 maxPOLIn,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 deadline,
        address referrer
    ) external returns (uint256 polInUsed);

    /// @notice Swap an exact amount of YT for POL, reusing the canonical PT/POL pool via a single flash merge.
    /// @param verseId Canonical verse id resolving PT/YT/POL via the canonical splitter.
    /// @param exactYTIn Exact YT amount to sell from `msg.sender`.
    /// @param minPOLOut Minimum net POL to deliver to `recipient` (full uint256 bound, no int128 cap).
    /// @param sqrtPriceLimitX96 Price limit applied to the underlying PT/POL swap.
    /// @param recipient Recipient of the POL output; must not be zero or the router.
    /// @param deadline Latest valid execution timestamp (inclusive).
    /// @param referrer Referrer forwarded to the hook as packed `hookData`, or `address(0)` for empty `hookData`.
    /// @return polOut Net POL amount sent to `recipient`.
    function swapExactYTForPOL(
        uint256 verseId,
        uint256 exactYTIn,
        uint256 minPOLOut,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 deadline,
        address referrer
    ) external returns (uint256 polOut);
}
