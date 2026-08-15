// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IPOLSplitter} from "../../../src/polend/interfaces/IPOLSplitter.sol";
import {MemeverseYTFlashSwapRouter} from "../../../src/swap/MemeverseYTFlashSwapRouter.sol";

/// @title YTFlashSwapMocks
/// @notice Independent mock harness scoped to the YT Flash Swap test suite. Supplies only the minimal manager/hook/
///         launcher/splitter/token plumbing needed to exercise the router's entry guards, one-shot callback context,
///         and (in Task 4/5) scripted raw deltas with exact take/settle closure.
/// @dev These mocks DO NOT prove real fee economics, real v4 swap math, or real split/merge accounting. They only
///      provide deterministic branches for unit-level guard and structure coverage. They must not be reused from
///      `SwapRouterMocks.sol` and must not be modified outside this suite's tasks.
contract MockYTManager {
    /// @notice Unlock behavior the manager exercises on the router callback.
    enum Mode {
        Normal, // re-enter with the exact payload
        Tamper, // re-enter with a one-byte-flipped payload
        NoCallback, // return without invoking the callback
        Double // invoke the callback twice (Task 4 replay coverage)
    }

    /// @dev Differential-revert ordering pin selector for `take`. Surfaced only when `armTakeRanBeforeGuard()` armed a
    ///      flag that survives the reverting frame (set outside it); an inverted guard-after-`take` reorder then makes
    ///      `take` run first and revert with `TakeRanBeforeGuard()` instead of the production guard's error, so
    ///      `expectRevert(<prod error>)` fails and catches the reorder. Vacuous unless armed.
    error TakeRanBeforeGuard();

    Mode public mode;
    bool internal _inUnlock;

    /// @notice Number of `swap` calls observed inside unlock windows.
    uint256 public swapCount;
    /// @notice Last `hookData` forwarded to `swap`.
    bytes public lastHookData;
    /// @notice Last `SwapParams.zeroForOne` forwarded to `swap` (Task 4 mapping coverage).
    bool public lastZeroForOne;
    /// @notice Last `SwapParams.amountSpecified` forwarded to `swap` (Task 4 mapping coverage).
    int256 public lastAmountSpecified;
    /// @notice Last raw `SwapParams.sqrtPriceLimitX96` forwarded to `swap`; this mock records the parameter but does not
    ///         model v4 price-limit economics.
    uint160 public lastSqrtPriceLimitX96;

    int128 internal _scriptedDelta0;
    int128 internal _scriptedDelta1;
    bool internal _scriptedDeltaSet;

    /// @notice Per-currency net router delta vs this manager (positive = manager owes router, negative = router owes
    ///         manager). Task 4/5 take/settle close it to zero; Task 7 invariant reads it.
    mapping(address => int256) public routerDeltaOf;

    /// @dev Currency synced by the router immediately before `settle`; mirrors real PoolManager.sync semantics so the
    ///      mock can attribute an inbound ERC20 transfer to the right currency.
    Currency internal _syncedCurrency;
    uint256 internal _syncedReserves;
    bool internal _syncedSet;

    /// @dev Enumerable set of currencies ever touched via swap/take/sync. Lets `openDeltaCount` count non-zero router
    ///      deltas without enumerating an unbounded mapping (Task 7 baseline invariant). Rolled back with the tx on
    ///      revert, so it only contains currencies from committed (successful) flashes.
    address[] internal _seenCurrencies;
    mapping(address => bool) internal _seen;

    /// @notice Number of unlock windows that performed at least one successful `swap`. Task 7 invariant asserts this
    ///         equals the handler's successful-flash count (one swap per successful flash). Incremented at the end of a
    ///         non-reverting unlock window, so a reverting flash rolls it back together with the window.
    uint256 public successfulUnlockSwapCount;
    uint256 internal _swapsInWindow;

    /// @dev Extra tokens minted to the take recipient on top of the credited amount. Used by
    ///      `test_RevertWhen_BaselineMismatch` to leave a router balance residual that the postcondition guard catches.
    ///      Zero by default; does not affect delta accounting, so the per-currency delta still closes.
    uint256 public takeBonus;

    /// @dev Differential-revert ordering pin. When armed, `take` reverts with `TakeRanBeforeGuard()` instead of
    ///      performing the payout. Used by check-before-take tests: if the router's guard is correct, `take` never runs
    ///      and the expected guard revert surfaces; if a reorder moved `take` before the guard, this mock reverts first
    ///      and the expected guard selector stops matching. The flag is set outside the reverting frame (test body), so it
    ///      persists across reverts; disarm before any happy-path block in the same test.
    bool public takeRanBeforeGuardArmed;

    function setMode(Mode m) external {
        mode = m;
    }

    /// @notice Sets the extra mint applied on top of each `take` payout (Task 7 baseline-mismatch coverage).
    function setTakeBonus(uint256 bonus) external {
        takeBonus = bonus;
    }

    /// @notice Arms the take ordering pin: every subsequent `take` reverts with `TakeRanBeforeGuard()`. Persists
    ///         across reverted calls (the flag is set outside the reverting frame); call `disarmTakeRanBeforeGuard()`
    ///         before any happy-path `take` in the same test.
    function armTakeRanBeforeGuard() external {
        takeRanBeforeGuardArmed = true;
    }

    /// @notice Disarms the take ordering pin so `take` resumes its normal behavior.
    function disarmTakeRanBeforeGuard() external {
        takeRanBeforeGuardArmed = false;
    }

    /// @notice Scripts the raw currency0/currency1 deltas returned by the next `swap` call(s).
    function scriptSwapDelta(int128 delta0, int128 delta1) external {
        _scriptedDelta0 = delta0;
        _scriptedDelta1 = delta1;
        _scriptedDeltaSet = true;
    }

    /// @notice Open the unlock window and forward to the caller's `unlockCallback` per the current mode.
    function unlock(bytes calldata data) external returns (bytes memory) {
        require(!_inUnlock, "YT mock: nested unlock");
        _inUnlock = true;
        // Reset per-window swap counter so `successfulUnlockSwapCount` can attribute exactly one increment to a window
        // that contains at least one successful swap. A reverting callback propagates and rolls this back.
        _swapsInWindow = 0;
        bytes memory result;
        if (mode == Mode.NoCallback) {
            // Intentionally do not invoke the callback; the router's `_runFlashSwap` detects the unconsumed pending hash.
            result = "";
        } else {
            bytes memory payload;
            if (mode == Mode.Tamper) {
                payload = _tamper(data);
            } else {
                payload = data;
            }
            result = IUnlockCallback(msg.sender).unlockCallback(payload);
            if (mode == Mode.Double) {
                // Second invocation: the pending hash is already cleared, so the router rejects a replay.
                result = IUnlockCallback(msg.sender).unlockCallback(payload);
            }
        }
        _inUnlock = false;
        // Only count windows that actually performed a swap. The router does exactly one swap per flash, so this equals
        // the handler's successful-flash count under the Task 7 invariant.
        if (_swapsInWindow > 0) {
            successfulUnlockSwapCount += 1;
        }
        return result;
    }

    /// @notice Scripted swap entry; only allowed inside an unlock window. Credits the router's per-currency delta so
    ///         `take`/`settle` can close it to zero, and records the forwarded `SwapParams` for mapping coverage.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        require(_inUnlock, "YT mock: swap outside unlock");
        require(_scriptedDeltaSet, "YT mock: swap delta not scripted");
        swapCount += 1;
        _swapsInWindow += 1;
        lastHookData = hookData;
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        lastSqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        routerDeltaOf[c0] += int256(_scriptedDelta0);
        routerDeltaOf[c1] += int256(_scriptedDelta1);
        _register(c0);
        _register(c1);
        return toBalanceDelta(_scriptedDelta0, _scriptedDelta1);
    }

    /// @notice Records a router take: reduces what the manager owes the router and pays out the currency. The mock does
    ///         not model reserves, so it mints the payout to the recipient (test scope only) rather than transferring
    ///         from a pre-funded balance; this is what lets downstream `split`/`settle` transfers succeed. A non-zero
    ///         `takeBonus` mints extra without adjusting the delta, so the per-currency delta still closes while the
    ///         router balance postcondition fails (Task 7 baseline-mismatch coverage).
    function take(Currency currency, address to, uint256 amount) external {
        require(_inUnlock, "YT mock: take outside unlock");
        // Ordering pin: if armed, `take` was reached at all, which only happens when a router guard that should fire
        // before take was reordered after it. Revert with a distinct selector so the test's `expectRevert(guardSelector)`
        // fails and catches the reorder. Placed first (after the unlock-window guard) so it fires before any payout. The
        // flag persists across this revert (it is set in the test body); disarm before any happy-path take in the same test.
        if (takeRanBeforeGuardArmed) revert TakeRanBeforeGuard();
        address token = Currency.unwrap(currency);
        routerDeltaOf[token] -= int256(amount);
        YTMockERC20(token).mint(to, amount + takeBonus);
        _register(token);
    }

    /// @notice Records the synced currency and the manager's current reserves of it, like the real PoolManager before a
    ///         settle.
    function sync(Currency currency) external {
        require(_inUnlock, "YT mock: sync outside unlock");
        _syncedCurrency = currency;
        address token = Currency.unwrap(currency);
        _syncedReserves = YTMockERC20(token).balanceOf(address(this));
        _syncedSet = true;
        _register(token);
    }

    /// @notice Measures the inbound ERC20 transfer since `sync` and credits it to the router's delta for the synced
    ///         currency, mirroring real PoolManager.settle accounting.
    function settle() external payable returns (uint256) {
        require(_inUnlock, "YT mock: settle outside unlock");
        uint256 amount;
        if (_syncedSet) {
            address token = Currency.unwrap(_syncedCurrency);
            amount = YTMockERC20(token).balanceOf(address(this)) - _syncedReserves;
            routerDeltaOf[token] += int256(amount);
            _syncedSet = false;
        }
        return amount;
    }

    /// @notice Task 7 invariant helper: number of seen currencies with a non-zero router delta. The `router` argument
    ///         is kept for signature compatibility; this mock models a single router so deltas are tracked per currency
    ///         globally. After a successful flash every touched currency closes to zero, so this returns 0.
    function openDeltaCount(address router) external view returns (uint256 count) {
        router; // silence unused-parameter; the mock attributes all deltas to the single caller.
        for (uint256 i = 0; i < _seenCurrencies.length; i++) {
            if (routerDeltaOf[_seenCurrencies[i]] != 0) {
                count += 1;
            }
        }
    }

    /// @dev Adds a currency to the seen set on first touch so `openDeltaCount` can iterate it later.
    function _register(address token) internal {
        if (!_seen[token]) {
            _seen[token] = true;
            _seenCurrencies.push(token);
        }
    }

    function _tamper(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length);
        for (uint256 i = 0; i < data.length; i++) {
            out[i] = data[i];
        }
        if (out.length > 0) {
            out[out.length - 1] = bytes1(uint8(out[out.length - 1]) ^ 0x01);
        }
    }
}

/// @notice Minimal `IMemeverseUniswapHook` subset for the YT Flash Swap suite: launcher binding and the read-only
///         active account-session principal getter.
contract MockYTHook {
    /// @dev Public auto-getter `launcher()` matches the `IMemeverseUniswapHook.launcher()` selector.
    address public launcher;
    /// @dev Public auto-getter `activeAccountSessionPrincipal()` matches the hook interface selector.
    address public activeAccountSessionPrincipal;
    /// @dev Public auto-getter `poolManager()` matches the `IImmutableState.poolManager()` selector (now inherited by
    ///      `IMemeverseUniswapHook`), so the router's constructor diagonal guard can read the hook's bound PoolManager
    ///      without inheriting ImmutableState.
    IPoolManager public poolManager;

    function setLauncher(address launcher_) external {
        launcher = launcher_;
    }

    function setActivePrincipal(address principal) external {
        activeAccountSessionPrincipal = principal;
    }

    function setPoolManager(IPoolManager poolManager_) external {
        poolManager = poolManager_;
    }
}

/// @notice Test-only hook that exposes `launcher()` and `activeAccountSessionPrincipal()` but omits the `poolManager()`
///         selector, and has no `fallback`/`receive`.
/// @dev Used to prove the router constructor is fail-closed when `hook_` has deployed code but lacks the
///      `poolManager()` selector. The address passes the zero-address guard and the `code.length == 0` ->
///      `HookCodeNotReady` guard (it has code), then the runtime-cast STATICCALL
///      `IImmutableState(address(hook_)).poolManager()` hits an unknown selector with no fallback -> the EVM dispatcher
///      reverts with empty returndata -> Solidity's high-level ABI-decode of the return value reverts, aborting
///      deployment. This residual path is unguarded-by-named-error but still fail-closed. This mock
///      deliberately diverges from `MockYTHook` by omitting the `poolManager` public state var so its auto-getter
///      selector is absent. Setters mirror `MockYTHook` for symmetry even though the failing path reverts before any
///      runtime call uses them.
contract MockYTHookMissingPoolManager {
    /// @dev Public auto-getter `launcher()` matches the `IMemeverseUniswapHook.launcher()` selector.
    address public launcher;
    /// @dev Public auto-getter `activeAccountSessionPrincipal()` matches the hook interface selector.
    address public activeAccountSessionPrincipal;

    function setLauncher(address launcher_) external {
        launcher = launcher_;
    }

    function setActivePrincipal(address principal) external {
        activeAccountSessionPrincipal = principal;
    }
}

/// @notice Minimal `IMemeverseLauncher` subset returning a mutable `LauncherContracts` bundle for canonical-dependency
///         and launcher-config-change coverage.
contract MockLauncher {
    IMemeverseLauncher.LauncherContracts internal _contracts;

    function setCanonicalHook(address hook) external {
        _contracts.memeverseUniswapHook = hook;
    }

    function setCanonicalSplitter(address splitter) external {
        _contracts.polSplitter = splitter;
    }

    function setLauncherContracts(IMemeverseLauncher.LauncherContracts calldata contracts) external {
        _contracts = contracts;
    }

    function getLauncherContracts() external view returns (IMemeverseLauncher.LauncherContracts memory) {
        return _contracts;
    }
}

/// @notice Test-only launcher that has deployed code but deliberately omits the `getLauncherContracts()` selector and
///         has no `fallback`/`receive`.
/// @dev Used to prove the router's runtime `_validateAndResolve` path is fail-closed when `launcherAddr` has deployed
///      code but lacks the `getLauncherContracts()` selector. The address passes the zero-address guard and the
///      `code.length == 0` -> `LauncherCodeNotReady` guard (it has code), then the runtime-cast STATICCALL
///      `IMemeverseLauncher(address(launcherAddr)).getLauncherContracts()` hits an unknown selector with no fallback ->
///      the EVM dispatcher reverts with empty returndata -> Solidity's high-level ABI-decode reverts. This is the
///      unguarded-by-named-error residual sub-path of the launcher resolution; it is still fail-closed (it fires before
///      any fund action). This is the runtime analog of the constructor-side `MockYTHookMissingPoolManager`. The mock
///      deliberately has no members: the failing path reverts before any are read, so a plain contract body is
///      sufficient (it has deployed code, exposes no `getLauncherContracts()` selector, and has no fallback).
contract MockLauncherMissingSelector {}

/// @notice Minimal `IPOLSplitter` subset for the YT Flash Swap suite: canonical verse-asset resolution plus
///         stubbed split/merge used by Task 4/5.
contract MockYTSplitter {
    /// @dev Differential-revert ordering pin selector for `split`. Surfaced only when `armSplitRanBeforeGuard()` armed
    ///      the mock and the router reached `split`, proving a guard that should precede `split` was reordered after it.
    error SplitRanBeforeGuard();
    /// @dev Differential-revert ordering pin selector for `merge`. Same role as `SplitRanBeforeGuard` on the sell path.
    error MergeRanBeforeGuard();

    struct VerseAssets {
        address pt;
        address yt;
        address pol;
    }

    /// @dev Optional scripted override for the next `split` on a verse. `allowanceResidual > 0` simulates a
    ///      non-standard splitter that does not fully consume its POL approval, exercising the router's residual guard.
    ///      `ytMintBonus > 0` makes the malformed splitter mint `ytReturn + ytMintBonus` YT while still *returning*
    ///      `ytReturn`, so the surplus YT lands on the router and only the baseline guard catches it (mirroring how
    ///      `MockYTManager.takeBonus` produces a take-token residual). Used by the YT baseline-mismatch coverage.
    struct SplitScript {
        uint256 ptReturn;
        uint256 ytReturn;
        uint256 allowanceResidual;
        uint256 ytMintBonus;
        bool active;
    }

    /// @dev Optional scripted override for the next `merge` on a verse. A `polReturn != amount` exercises the router's
    ///      `MergeResultMismatch` guard. `ytShortBurn > 0` makes the malformed splitter burn only `amount - ytShortBurn`
    ///      YT (while still minting `polAmount` POL and returning it), leaving `ytShortBurn` YT on the router that only
    ///      the baseline guard catches. Used by the YT baseline-mismatch coverage.
    struct MergeScript {
        uint256 polReturn;
        uint256 ytShortBurn;
        bool active;
    }

    mapping(uint256 => VerseAssets) internal _assets;
    mapping(uint256 => SplitScript) internal _splitScripts;
    mapping(uint256 => MergeScript) internal _mergeScripts;
    uint256 public splitCount;
    uint256 public mergeCount;

    /// @dev Differential-revert ordering pin. When armed, `split` reverts with `SplitRanBeforeGuard()` instead of
    ///      performing the split. Used by check-before-split tests: if the router's cost guard is correct, `split`
    ///      never runs and the expected guard revert surfaces; if a reorder moved `split` before the guard, this mock
    ///      reverts first and the expected guard selector stops matching. Unlike a post-call storage-counter assertion
    ///      (which the reverting frame rolls back to its pre-call value and thus proves nothing), this changes the
    ///      revert reason itself, so the discrimination survives the rollback. The flag is set outside the reverting
    ///      frame (test body), so it persists across reverts; disarm before any happy-path block in the same test.
    bool public splitRanBeforeGuardArmed;
    /// @dev Same differential-revert pin for `merge` on the sell path (min-output check before merge).
    bool public mergeRanBeforeGuardArmed;

    /// @dev Reentrancy hook mirroring `YTMockERC20`: when armed, the next `split`/`merge` re-enters `reenterTarget`
    ///      with `reenterData` and bubbles any revert. Proves the router's `nonReentrant` guard blocks a
    ///      malicious-Splitter callback during `split`/`merge` (Splitter vector).
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterOn;

    function setVerseAssets(uint256 verseId, address pt, address yt, address pol) external {
        _assets[verseId] = VerseAssets(pt, yt, pol);
    }

    function getPTAndYTAndPOL(uint256 verseId) external view returns (address pt, address yt, address pol) {
        VerseAssets storage a = _assets[verseId];
        return (a.pt, a.yt, a.pol);
    }

    /// @notice Scripts the return values, optional POL allowance residual, and optional YT over-mint bonus for the next
    ///         `split(verseId, ...)`. `ytMintBonus > 0` mints `ytReturn + ytMintBonus` YT to the caller while still
    ///         returning `ytReturn`, leaving a router-side YT residual only the baseline guard catches.
    function scriptSplit(
        uint256 verseId,
        uint256 ptReturn,
        uint256 ytReturn,
        uint256 allowanceResidual,
        uint256 ytMintBonus
    ) external {
        _splitScripts[verseId] = SplitScript(ptReturn, ytReturn, allowanceResidual, ytMintBonus, true);
    }

    /// @notice Scripts the POL return value and optional YT under-burn for the next `merge(verseId, ...)`. Default is a
    ///         faithful 1:1 merge. `ytShortBurn > 0` burns only `amount - ytShortBurn` YT while still minting/returning
    ///         `polReturn`, leaving `ytShortBurn` YT on the router for the baseline guard to catch.
    function scriptMerge(uint256 verseId, uint256 polReturn, uint256 ytShortBurn) external {
        _mergeScripts[verseId] = MergeScript(polReturn, ytShortBurn, true);
    }

    /// @notice Arms the split/merge reentrancy hook. The next `split`/`merge` re-enters `target` with `data`.
    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
        reenterOn = true;
    }

    /// @notice Disarms the reentrancy hook.
    function clearReenter() external {
        reenterOn = false;
    }

    /// @notice Arms the split ordering pin: every subsequent `split` reverts with `SplitRanBeforeGuard()`. Persists
    ///         across reverted calls (the flag is set outside the reverting frame); call `disarmSplitRanBeforeGuard()`
    ///         before any happy-path `split` in the same test.
    function armSplitRanBeforeGuard() external {
        splitRanBeforeGuardArmed = true;
    }

    /// @notice Disarms the split ordering pin so `split` resumes its normal behavior.
    function disarmSplitRanBeforeGuard() external {
        splitRanBeforeGuardArmed = false;
    }

    /// @notice Arms the merge ordering pin: every subsequent `merge` reverts with `MergeRanBeforeGuard()`. Persists
    ///         across reverted calls; call `disarmMergeRanBeforeGuard()` before any happy-path `merge` in the same test.
    function armMergeRanBeforeGuard() external {
        mergeRanBeforeGuardArmed = true;
    }

    /// @notice Disarms the merge ordering pin so `merge` resumes its normal behavior.
    function disarmMergeRanBeforeGuard() external {
        mergeRanBeforeGuardArmed = false;
    }

    /// @dev Mirrors real `POLSplitterUpgradeable.split`: pull POL collateral from the caller via `transferFrom`, then mint PT and
    ///      YT to the caller. Defaults to a faithful 1:1 split (`polAmount` in, `polAmount` PT + `polAmount` YT out,
    ///      full allowance consumed). A scripted `allowanceResidual` pulls less POL so the router->splitter allowance
    ///      stays non-zero, and scripted returns cover the mismatch/residual revert paths.
    function split(uint256 verseId, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount) {
        // Ordering pin: if armed, `split` was reached at all, which only happens when a router guard that should fire
        // before split was reordered after it. Revert with a distinct selector so the test's `expectRevert(guardSelector)`
        // fails and catches the reorder. Placed first so it fires even before `splitCount += 1`. The flag persists across
        // this revert (it is set in the test body); disarm before any happy-path split in the same test.
        if (splitRanBeforeGuardArmed) revert SplitRanBeforeGuard();
        splitCount += 1;
        _reenter();
        VerseAssets storage a = _assets[verseId];
        SplitScript storage s = _splitScripts[verseId];
        uint256 residual = s.active ? s.allowanceResidual : 0;
        uint256 pullAmount = polAmount > residual ? polAmount - residual : 0;
        require(YTMockERC20(a.pol).transferFrom(msg.sender, address(this), pullAmount));
        ptAmount = s.active ? s.ptReturn : polAmount;
        ytAmount = s.active ? s.ytReturn : polAmount;
        // A malformed splitter may mint more YT than it reports back. The returned value still passes the router's
        // `SplitResultMismatch` check, but the surplus (`ytMintBonus`) remains on the router until the baseline guard
        // catches it. Defaults to zero, so existing tests are unaffected.
        uint256 ytBonus = s.active ? s.ytMintBonus : 0;
        if (ptAmount > 0) YTMockERC20(a.pt).mint(msg.sender, ptAmount);
        if (ytAmount + ytBonus > 0) YTMockERC20(a.yt).mint(msg.sender, ytAmount + ytBonus);
        return (ptAmount, ytAmount);
    }

    /// @dev Mirrors real `POLSplitterUpgradeable.merge`: burn the caller's PT and YT directly (the Splitter is the minter, so no
    ///      ERC20 approval or `transferFrom` is involved), then send `amount` POL to the caller 1:1. Defaults to a
    ///      faithful merge; a scripted `polReturn` exercises the router's `MergeResultMismatch` guard. The mock mints
    ///      the payout rather than tracking real POL backing, matching how `split` mints PT/YT without backing.
    function merge(uint256 verseId, uint256 amount) external returns (uint256 polAmount) {
        // Ordering pin: if armed, `merge` was reached at all, which only happens when a router guard that should fire
        // before merge was reordered after it. Revert with a distinct selector so the test's `expectRevert(guardSelector)`
        // fails and catches the reorder. Placed first so it fires even before `mergeCount += 1`. The flag persists across
        // this revert (it is set in the test body); disarm before any happy-path merge in the same test.
        if (mergeRanBeforeGuardArmed) revert MergeRanBeforeGuard();
        mergeCount += 1;
        _reenter();
        VerseAssets storage a = _assets[verseId];
        MergeScript storage m = _mergeScripts[verseId];
        YTMockERC20(a.pt).burn(msg.sender, amount);
        // A malformed splitter may under-burn YT (while still minting/returning the correct POL). The returned POL
        // still passes the router's `MergeResultMismatch` check, but the unburnt YT (`ytShortBurn`) remains on the
        // router until the baseline guard catches it. Defaults to zero, so existing tests are unaffected.
        uint256 ytShortBurn = m.active ? m.ytShortBurn : 0;
        uint256 ytToBurn = amount > ytShortBurn ? amount - ytShortBurn : 0;
        YTMockERC20(a.yt).burn(msg.sender, ytToBurn);
        polAmount = m.active ? m.polReturn : amount;
        YTMockERC20(a.pol).mint(msg.sender, polAmount);
        return polAmount;
    }

    /// @dev Mirrors `YTMockERC20._move`'s reentrancy bubble: calls `reenterTarget` with `reenterData` and bubbles any
    ///      revert reason (e.g. `ReentrancyGuardReentrantCall`) so the outer settlement reverts atomically.
    function _reenter() internal {
        if (reenterOn && reenterTarget != address(0)) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @notice Standard passive ERC20 for the YT Flash Swap suite, with scriptable `transferFrom`/`approve` failure
///         switches (Task 4/5 pull/approve revert coverage) and a transfer-time reentrancy hook (Task 7 nonReentrant
///         guard coverage).
contract YTMockERC20 {
    string public name;
    string public symbol;
    // solhint-disable-next-line const-name-snakecase
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public transferFromOk = true;
    /// @dev When false, `approve` returns false without mutating allowance, exercising the router's
    ///      `ApprovalFailed` guard.
    bool public approveOk = true;

    /// @dev Per-`from` count of `transferFrom` calls. Backs `test_NoRefundLoop`'s "payer pulled exactly once" proof.
    mapping(address => uint256) public transferFromAsFrom;

    /// @dev Reentrancy hook: when enabled and `reenterTarget != address(0)`, every `_move` performs a low-level call
    ///      to `reenterTarget` with `reenterData` and bubbles any revert. Used to prove the router's `nonReentrant`
    ///      guard blocks a token-callback reentry into a public entry.
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterOn;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    /// @dev Test-only `burn` callable by the mock splitter (which plays the minter role) to mirror
    ///      `POLSplitterUpgradeable.merge` burning PT/YT directly off the caller without an ERC20 approval path.
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function setTransferFromOk(bool ok) external {
        transferFromOk = ok;
    }

    function setApproveOk(bool ok) external {
        approveOk = ok;
    }

    /// @notice Arms the transfer-time reentrancy hook. The next (and every) `_move` re-enters `target` with `data`.
    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
        reenterOn = true;
    }

    /// @notice Disarms the reentrancy hook.
    function clearReenter() external {
        reenterOn = false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (!approveOk) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (!transferFromOk) return false;
        transferFromAsFrom[from] += 1;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // Reentrancy hook: bubbles the reentrant call's revert reason (e.g. `ReentrancyGuardReentrantCall`) so the
        // outer settlement reverts atomically.
        if (reenterOn && reenterTarget != address(0)) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @notice Test-only harness that inherits the non-upgradeable router and exposes its pure PT/POL mapping helpers so
///         `test_DeltaMapping_MapsBothCurrencyOrders` can cover both `ptIsCurrency0` branches directly without claiming
///         one token-ordering fixture represents both.
contract YTFlashSwapRouterHarness is MemeverseYTFlashSwapRouter {
    constructor(IPoolManager manager_, IMemeverseUniswapHook hook_, IPOLSplitter splitter_)
        MemeverseYTFlashSwapRouter(manager_, hook_, splitter_)
    {}

    function exposed_deltasForPTAndPOL(BalanceDelta d, bool ptIsCurrency0)
        external
        pure
        returns (int128 ptDelta, int128 polDelta)
    {
        return _deltasForPTAndPOL(d, ptIsCurrency0);
    }

    function exposed_hookData(address referrer) external pure returns (bytes memory) {
        return _hookData(referrer);
    }
}
