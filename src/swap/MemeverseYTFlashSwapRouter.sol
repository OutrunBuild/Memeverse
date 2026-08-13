// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ReentrancyGuard} from "../common/access/ReentrancyGuard.sol";
import {IMemeverseLauncher} from "../verse/interfaces/IMemeverseLauncher.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseYTFlashSwapRouter} from "./interfaces/IMemeverseYTFlashSwapRouter.sol";
import {MemeversePoolKeyLib} from "./libraries/MemeversePoolKeyLib.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";

/// @title MemeverseYTFlashSwapRouter
/// @notice Reuses the canonical PT/POL Uniswap v4 pool to swap POL against exact YT amounts in a single
///         `PoolManager.unlock`, without creating a second AMM. Each entry validates user bounds, binds the payer to
///         the hook-captured active session principal, re-derives the canonical hook/splitter from the hook's current
///         launcher, snapshots a three-token baseline, then opens a one-shot flash context whose hash is committed to
///         transient storage before the callback runs.
/// @dev Identity root: `payer` is always `msg.sender`; there is no public or callback payer parameter. The one-shot
///      context hash is verified and cleared inside `_unlockCallback` before any decode or external call, which makes
///      replayed, tampered, or double callbacks revert before settlement. The buy settlement body executes the real
///      POL -> YT fund flow and the sell settlement body executes the real exact YT -> POL flash merge fund flow, each
///      in a single `PoolManager.unlock`.
contract MemeverseYTFlashSwapRouter is SafeCallback, ReentrancyGuard, IMemeverseYTFlashSwapRouter {
    using CurrencySettler for Currency;
    using OutrunSafeERC20 for IERC20;

    /// @notice Flash direction carried on the one-shot context.
    enum FlashAction {
        Buy,
        Sell
    }

    /// @notice Pre-entry snapshot of the router's own PT/YT/POL balances; never enters FlashContext or its hash.
    struct RouterBalances {
        uint256 pt;
        uint256 yt;
        uint256 pol;
    }

    /// @notice Execution-only payload committed by `_runFlashSwap` and verified inside `_unlockCallback`.
    /// @dev Excludes `RouterBalances` so the consumed hash is independent of router-held dust.
    struct FlashContext {
        FlashAction action;
        address payer;
        address recipient;
        address referrer;
        uint256 verseId;
        uint256 ytAmount;
        uint256 polLimit;
        uint160 priceLimit;
        address pt;
        address yt;
        address pol;
    }

    /// @dev Upper bound for the exact YT amount, matching the v4 signed-delta safe range. `maxPOLIn`/`minPOLOut`
    ///      intentionally keep full `uint256` semantics and are not bounded by this value.
    uint256 private constant INT128_MAX_VALUE = uint256(uint128(type(int128).max));

    IMemeverseUniswapHook public immutable hook;
    IPOLSplitter public immutable splitter;

    /// @dev Pending one-shot context hash. Written in `_runFlashSwap`, verified and cleared at the top of `_unlockCallback`
    ///      before decode/external calls. Transient so it never persists across transactions.
    bytes32 private transient _pendingContextHash;

    /// @param manager_ Uniswap v4 PoolManager, stored as immutable by `SafeCallback`/`ImmutableState`.
    /// @param hook_ Memeverse hook used to derive the canonical pool and read the active account-session principal.
    /// @param splitter_ Canonical POL splitter used to resolve verse assets and to split/merge.
    constructor(IPoolManager manager_, IMemeverseUniswapHook hook_, IPOLSplitter splitter_) SafeCallback(manager_) {
        // Fail closed at deployment: any zero-address immutable dependency would otherwise deploy silently and only
        // surface as a confusing no-code revert at the first runtime call. Mirrors MemeverseUniswapHookUpgradeable / FacetGuard.
        if (address(manager_) == address(0) || address(hook_) == address(0) || address(splitter_) == address(0)) {
            revert ZeroAddress();
        }
        // Code-readiness for all three immutable executable dependencies (checked after the zero-address guard, before
        // the diagonal `manager_ == hook_.poolManager()` compare). `manager_` is already bound as the
        // SafeCallback/ImmutableState immutable `poolManager` before this body runs; the checks cannot undo that binding,
        // but they make a misconfigured deployment revert with a named error instead of succeeding and only failing later
        // at runtime unlock / split calls. Mirrors the codebase's facet/upgrade/lens code-length-first ordering: a no-code
        // dependency fails here with a named error rather than as an opaque ABI-decode revert from the next STATICCALL
        // (e.g. `hook_.poolManager()` for `hook_`, or `getPTAndYTAndPOL` / `split` / `merge` for `splitter_` at runtime).
        if (address(manager_).code.length == 0) revert PoolManagerCodeNotReady(address(manager_));
        if (address(hook_).code.length == 0) revert HookCodeNotReady(address(hook_));
        if (address(splitter_).code.length == 0) revert SplitterCodeNotReady(address(splitter_));
        // Diagonal PoolManager invariant: the Router and Hook each bind an immutable PoolManager (via
        // SafeCallback/ImmutableState). The Router unlocks and swaps on its own PoolManager, which then calls back into
        // the Hook via `key.hooks`; the Hook's `onlyPoolManager` compares msg.sender against the Hook's PoolManager. If
        // the two differ, every swap and both YT Flash Swap entrypoints revert with NotPoolManager (or PoolNotInitialized
        // first) and, because the binding is immutable, the mistake is unrecoverable. Mirror the same fail-closed the
        // codebase already applies to facets/upgrade/lens for this exact invariant.
        // Cache the hook's immutable PoolManager once; reuses it for both the compare and the revert payload. `hook_`
        // is typed `IMemeverseUniswapHook`, which inherits `IImmutableState`, so `poolManager()` is callable directly
        // (unlike `_requireFacetPoolManager`, whose `facet` is a bare `address` and therefore requires the cast).
        address hookPoolManager = address(hook_.poolManager());
        if (address(manager_) != hookPoolManager) {
            revert RouterPoolManagerMismatch(address(manager_), hookPoolManager);
        }
        hook = hook_;
        splitter = splitter_;
    }

    /// @notice Buy an exact amount of YT with POL. See {IMemeverseYTFlashSwapRouter-swapPOLForExactYT}.
    function swapPOLForExactYT(
        uint256 verseId,
        uint256 exactYTOut,
        uint256 maxPOLIn,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 deadline,
        address referrer
    ) external override nonReentrant returns (uint256 polInUsed) {
        (address pt, address yt, address pol) = _validateAndResolve(deadline, recipient, exactYTOut, verseId);
        RouterBalances memory baseline = _snapshotBalances(pt, yt, pol);
        FlashContext memory c = FlashContext({
            action: FlashAction.Buy,
            payer: msg.sender,
            recipient: recipient,
            referrer: referrer,
            verseId: verseId,
            ytAmount: exactYTOut,
            polLimit: maxPOLIn,
            priceLimit: sqrtPriceLimitX96,
            pt: pt,
            yt: yt,
            pol: pol
        });
        polInUsed = _runFlashSwap(c);
        _assertBalancesRestored(baseline, pt, yt, pol);
        emit YTFlashSwapPOLForYT(verseId, msg.sender, recipient, exactYTOut, polInUsed, referrer);
    }

    /// @notice Sell an exact amount of YT for POL. See {IMemeverseYTFlashSwapRouter-swapExactYTForPOL}.
    function swapExactYTForPOL(
        uint256 verseId,
        uint256 exactYTIn,
        uint256 minPOLOut,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 deadline,
        address referrer
    ) external override nonReentrant returns (uint256 polOut) {
        (address pt, address yt, address pol) = _validateAndResolve(deadline, recipient, exactYTIn, verseId);
        RouterBalances memory baseline = _snapshotBalances(pt, yt, pol);
        FlashContext memory c = FlashContext({
            action: FlashAction.Sell,
            payer: msg.sender,
            recipient: recipient,
            referrer: referrer,
            verseId: verseId,
            ytAmount: exactYTIn,
            polLimit: minPOLOut,
            priceLimit: sqrtPriceLimitX96,
            pt: pt,
            yt: yt,
            pol: pol
        });
        polOut = _runFlashSwap(c);
        _assertBalancesRestored(baseline, pt, yt, pol);
        emit YTFlashSwapYTForPOL(verseId, msg.sender, recipient, exactYTIn, polOut, referrer);
    }

    /// @dev Commits the one-shot context hash to transient storage, opens the PoolManager unlock, then requires the
    ///      callback to have consumed (cleared) the hash and decodes its uint256 result.
    function _runFlashSwap(FlashContext memory c) internal returns (uint256 result) {
        bytes memory data = abi.encode(c);
        _pendingContextHash = keccak256(data);
        bytes memory callbackResult = poolManager.unlock(data);
        if (_pendingContextHash != bytes32(0)) revert CallbackNotConsumed(_pendingContextHash);
        result = abi.decode(callbackResult, (uint256));
    }

    /// @dev Verifies the raw callback payload matches the committed context, clears the hash, then dispatches to the
    ///      action-specific settlement. The hash is checked and cleared before any decode or external call, so a
    ///      replayed, tampered, or double callback cannot reach settlement.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        bytes32 expected = _pendingContextHash;
        bytes32 actual = keccak256(rawData);
        if (expected == bytes32(0) || actual != expected) revert UnexpectedOrTamperedCallback(expected, actual);
        _pendingContextHash = bytes32(0);
        FlashContext memory c = abi.decode(rawData, (FlashContext));
        return c.action == FlashAction.Buy ? _executeBuy(c) : _executeSell(c);
    }

    /// @dev POL -> exact YT settlement, run inside the PoolManager unlock callback. Executes one ordinary exact-input
    ///      PT->POL swap, then closes the deltas with a single POL take, a POL pull of the actual cost, an approval of
    ///      the splitter for exactly y, a split, a PT settle and a YT transfer. Fund flow (spec §8): swap y PT -> R POL; `take` R POL; pull `cost = y - R` POL
    ///      from the payer (only the actual cost, never `maxPOLIn`); approve the splitter for exactly y; split y into
    ///      y PT + y YT; settle the y PT against the -y PT delta; send the y YT to the recipient. The temporary POL
    ///      allowance must return to zero, and the router's PT/POL/YT balances must be exactly restored to their pre-call
    ///      baseline (pre-existing dust is preserved).
    function _executeBuy(FlashContext memory c) internal returns (bytes memory) {
        bool ptIsCurrency0 = c.pt < c.pol;
        BalanceDelta d = poolManager.swap(
            MemeversePoolKeyLib.hookPoolKey(c.pt, c.pol, address(hook)),
            SwapParams({
                // zeroForOne = ptIsCurrency0: a buy uses PT as the input leg, so when PT sorts first (currency0) the
                // swap direction is currency0 -> currency1.
                zeroForOne: ptIsCurrency0,
                amountSpecified: -int256(c.ytAmount),
                sqrtPriceLimitX96: c.priceLimit
            }),
            _hookData(c.referrer)
        );
        (int128 ptDelta, int128 polDelta) = _deltasForPTAndPOL(d, ptIsCurrency0);
        // Structural guard: the PT leg must be exactly filled (-y) and the POL delta must not be negative. POL == 0 is
        // intentionally allowed through here so it is reported as `InvalidBuyCost` below, matching spec §11
        // (`R_actual == 0` -> InvalidBuyCost), not as a structural mismatch.
        if (ptDelta != -int128(int256(c.ytAmount)) || polDelta < 0) revert FlashDeltaMismatch(ptDelta, polDelta);
        uint256 r = uint256(uint128(polDelta));
        // Cost validity per spec §8 item 2/§11: a valid buy requires `0 < R_actual < y`. `r == 0` (zero AMM-leg output) and
        // `r >= y` (zero/negative cost) both fail closed here, and this check also guarantees the unsigned `y - r`
        // subtraction below never underflows.
        if (r == 0 || r >= c.ytAmount) revert InvalidBuyCost(r, c.ytAmount);
        uint256 cost = c.ytAmount - r;
        if (cost > c.polLimit) revert MaxPOLInExceeded(cost, c.polLimit);
        Currency.wrap(c.pol).take(poolManager, address(this), r, false);
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(c.pol).safeTransferFrom(c.payer, address(this), cost);
        _approveExactly(IERC20(c.pol), address(splitter), c.ytAmount);
        (uint256 ptMinted, uint256 ytMinted) = splitter.split(c.verseId, c.ytAmount);
        uint256 remaining = IERC20(c.pol).allowance(address(this), address(splitter));
        if (remaining != 0) revert SplitterAllowanceResidual(remaining);
        if (ptMinted != c.ytAmount || ytMinted != c.ytAmount) {
            revert SplitResultMismatch(ptMinted, ytMinted, c.ytAmount);
        }
        Currency.wrap(c.pt).settle(poolManager, address(this), c.ytAmount, false);
        IERC20(c.yt).safeTransfer(c.recipient, c.ytAmount);
        return abi.encode(cost);
    }

    /// @dev Splits the raw currency0/currency1 swap delta into (PT delta, POL delta) based on which canonical address
    ///      sorts first. PT is currency0 exactly when `pt < pol`.
    function _deltasForPTAndPOL(BalanceDelta d, bool ptIsCurrency0)
        internal
        pure
        returns (int128 ptDelta, int128 polDelta)
    {
        if (ptIsCurrency0) {
            (ptDelta, polDelta) = (d.amount0(), d.amount1());
        } else {
            (ptDelta, polDelta) = (d.amount1(), d.amount0());
        }
    }

    /// @dev Encodes the referrer for the single underlying PT/POL swap. Zero referrer means empty hookData; a non-zero
    ///      referrer is packed (not abi-encoded), matching spec §10.
    function _hookData(address referrer) internal pure returns (bytes memory) {
        return referrer == address(0) ? bytes("") : abi.encodePacked(referrer);
    }

    /// @dev Approves `spender` for exactly `amount` in a single call. The buy uses one approve(y) before split; the
    ///      post-split allowance check then proves the splitter consumed it all.
    function _approveExactly(IERC20 token, address spender, uint256 amount) internal {
        if (!token.approve(spender, amount)) revert ApprovalFailed(address(token), spender, amount);
    }

    /// @dev Exact YT -> POL settlement, run inside the PoolManager unlock callback. Executes one ordinary exact-output
    ///      POL->PT swap for y PT, then closes the deltas with a single PT take, a YT pull of y, a 1:1 merge, a POL
    ///      settle of `Q_actual`, and a net POL transfer. Fund flow (spec §9): swap q POL -> y PT; `take` y PT; pull
    ///      y YT from the payer; `merge` burns y PT + y YT into y POL (no ERC20 approval, the Splitter is the minter);
    ///      settle q POL against the -q POL delta; send the remaining `polOut = y - q` POL to the recipient. The router's
    ///      PT/YT/POL balances must be exactly restored to their pre-call baseline (pre-existing dust is preserved).
    function _executeSell(FlashContext memory c) internal returns (bytes memory) {
        bool ptIsCurrency0 = c.pt < c.pol;
        BalanceDelta d = poolManager.swap(
            MemeversePoolKeyLib.hookPoolKey(c.pt, c.pol, address(hook)),
            SwapParams({
                // zeroForOne = !ptIsCurrency0: a sell uses PT as the output leg (POL is the input), so the swap
                // direction is the inverse of the PT ordering.
                zeroForOne: !ptIsCurrency0,
                amountSpecified: int256(c.ytAmount),
                sqrtPriceLimitX96: c.priceLimit
            }),
            _hookData(c.referrer)
        );
        (int128 ptDelta, int128 polDelta) = _deltasForPTAndPOL(d, ptIsCurrency0);
        // Structural guard: the PT leg must be exactly filled (+y) and the POL delta must not be positive. POL == 0 is
        // intentionally allowed through here so it is reported as `InvalidSellDebt` below, matching spec §11
        // (`Q_actual == 0` -> InvalidSellDebt), not as a structural mismatch.
        if (ptDelta != int128(int256(c.ytAmount)) || polDelta > 0) revert FlashDeltaMismatch(ptDelta, polDelta);
        // `polDelta` is confirmed <= 0 here, so the signed negation is safe and never underflows. `q = Q_actual`.
        uint256 q = uint256(-int256(polDelta));
        // Debt validity per spec §9 item 2/§11: a valid sell requires `0 < Q_actual < y`. `q == 0` (zero AMM-leg input) and
        // `q >= y` (zero/negative output) both fail closed here, and this check also guarantees the unsigned `y - q`
        // subtraction below never underflows.
        if (q == 0 || q >= c.ytAmount) revert InvalidSellDebt(q, c.ytAmount);
        uint256 out = c.ytAmount - q;
        // Spec §9 item 3: `polOut >= minPOLOut` must be enforced before any take, payer pull, or merge so a failing sell
        // never moves funds.
        if (out < c.polLimit) revert MinPOLOutNotMet(out, c.polLimit);
        Currency.wrap(c.pt).take(poolManager, address(this), c.ytAmount, false);
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(c.yt).safeTransferFrom(c.payer, address(this), c.ytAmount);
        uint256 merged = splitter.merge(c.verseId, c.ytAmount);
        if (merged != c.ytAmount) revert MergeResultMismatch(merged, c.ytAmount);
        Currency.wrap(c.pol).settle(poolManager, address(this), q, false);
        IERC20(c.pol).safeTransfer(c.recipient, out);
        return abi.encode(out);
    }

    /// @dev Shared precondition chain, run before any fund action: deadline, recipient, exact-y range, active
    ///      account-session principal, canonical dependency re-derived from the hook's current launcher (never cached),
    ///      and canonical verse-asset resolution. Returns the canonical PT/YT/POL addresses.
    function _validateAndResolve(uint256 deadline, address recipient, uint256 ytAmount, uint256 verseId)
        internal
        view
        returns (address pt, address yt, address pol)
    {
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert ExpiredPastDeadline();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        if (ytAmount == 0 || ytAmount > INT128_MAX_VALUE) revert AmountOutOfRange(ytAmount);
        // Bind the payer to the hook-captured active principal before any fund action. `active != msg.sender` captures
        // both the no-session case (`active == address(0)`) and the mismatched-principal case with a single error.
        address active = hook.activeAccountSessionPrincipal();
        if (active != msg.sender) revert AccountSessionPrincipalMismatch(active, msg.sender);
        // Re-derive canonical hook/splitter from the hook's current launcher every call; the router caches nothing.
        address launcherAddr = hook.launcher();
        // Fail closed with a named error before the external read: a zero-address or no-code launcher would otherwise make
        // the `getLauncherContracts()` call hit a non-contract (empty returndata) and revert opaquely with no selector.
        // Mirrors the constructor's `HookCodeNotReady` and the verse-asset `InvalidCanonicalVerseAssets`
        // code-length-first ordering.
        if (launcherAddr == address(0) || launcherAddr.code.length == 0) revert LauncherCodeNotReady(launcherAddr);
        IMemeverseLauncher.LauncherContracts memory canonical = IMemeverseLauncher(launcherAddr).getLauncherContracts();
        if (canonical.memeverseUniswapHook != address(hook) || canonical.polSplitter != address(splitter)) {
            revert CanonicalDependencyMismatch(
                address(hook), canonical.memeverseUniswapHook, address(splitter), canonical.polSplitter
            );
        }
        (pt, yt, pol) = splitter.getPTAndYTAndPOL(verseId);
        if (pt == address(0) || yt == address(0) || pol == address(0) || pt == yt || pt == pol || yt == pol) {
            revert InvalidCanonicalVerseAssets(verseId, pt, yt, pol);
        }
        // Canonical PT/YT/POL must be deployed contracts. A non-contract (e.g. an EOA stored as `pol` under launcher
        // misconfiguration) would pass the zero/duplicate check above, but the next `_snapshotBalances` does
        // `IERC20(...).balanceOf` STATICCALLs whose empty returndata would trigger an opaque ABI-decode revert with no
        // selector. Check code length first so the failure is a named error, mirroring the constructor's
        // `HookCodeNotReady` code-length-first pattern.
        if (pt.code.length == 0 || yt.code.length == 0 || pol.code.length == 0) {
            revert InvalidCanonicalVerseAssets(verseId, pt, yt, pol);
        }
    }

    /// @dev Snapshots the router's own PT/YT/POL balances. These never enter FlashContext or its hash so the one-shot
    ///      guard cannot be influenced by router-held dust.
    function _snapshotBalances(address pt, address yt, address pol)
        internal
        view
        returns (RouterBalances memory baseline)
    {
        baseline.pt = IERC20(pt).balanceOf(address(this));
        baseline.yt = IERC20(yt).balanceOf(address(this));
        baseline.pol = IERC20(pol).balanceOf(address(this));
    }

    /// @dev Requires the three router balances to be exactly restored after the callback returns. Enforces that no
    ///      flash consumed pre-existing dust or left a residual asset movement.
    function _assertBalancesRestored(RouterBalances memory baseline, address pt, address yt, address pol)
        internal
        view
    {
        uint256 current = IERC20(pt).balanceOf(address(this));
        if (current != baseline.pt) revert RouterBalanceMismatch(pt, baseline.pt, current);
        current = IERC20(yt).balanceOf(address(this));
        if (current != baseline.yt) revert RouterBalanceMismatch(yt, baseline.yt, current);
        current = IERC20(pol).balanceOf(address(this));
        if (current != baseline.pol) revert RouterBalanceMismatch(pol, baseline.pol, current);
    }
}
