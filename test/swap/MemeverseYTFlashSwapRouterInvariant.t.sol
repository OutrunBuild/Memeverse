// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IPOLSplitter} from "../../src/polend/interfaces/IPOLSplitter.sol";
import {MemeverseYTFlashSwapRouter} from "../../src/swap/MemeverseYTFlashSwapRouter.sol";
import {MockYTManager, MockYTHook, MockLauncher, MockYTSplitter, YTMockERC20} from "../mocks/swap/YTFlashSwapMocks.sol";

/// @title MemeverseYTFlashSwapRouterInvariantBase
/// @notice Shared Task 7 invariant fixture for the YT Flash Swap router. A handler exercises the two user entries (buy/sell)
///         with deterministic scripted mock deltas; after every fuzz sequence two invariants are checked:
///           1. The router's PT/YT/POL baselines, the splitter POL allowance, and the manager delta all close to zero.
///           2. Each successful flash performs exactly one underlying swap and exactly one split (buy) or merge (sell).
/// @dev Real v4 swap math is non-deterministic, so deltas are scripted (y -> y/2) and the manager/splitter mock counts
///      close the accounting. Each handler action funds and approves itself as the payer, so no call depends on prior
///      handler state. The handler inherits `Test` only to access the `bound` cheatcode.
///
///      COVERAGE SCOPE: this is a success-path state-accumulation campaign, NOT a guard-coverage suite. The handler
///      fuzzes only the swap size (`rawY`); every guard-triggering input is hardcoded to its guaranteed-success value
///      (see `YTFlashSwapHandler.buy`/`sell`), so none of the production guards in `_validateAndResolve`, `_executeBuy`,
///      `_executeSell`, or `_assertBalancesRestored` can revert under this harness. Each guard's revert path is instead
///      covered by the dedicated `test_RevertWhen_*` unit tests in `MemeverseYTFlashSwapRouter.t.sol`. This suite catches
///      state-accumulation regressions (baseline drift, residual delta, swap/split-merge count mismatch); it does NOT
///      catch guard deletion or guard reordering — those regressions must be caught by the unit-test suite.
abstract contract MemeverseYTFlashSwapRouterInvariantBase is Test {
    uint256 internal constant VERSE_ID = 42;
    uint160 internal constant PRICE_LIMIT = type(uint160).max;

    MockYTManager internal manager;
    MockYTHook internal hook;
    MockLauncher internal launcher;
    MockYTSplitter internal splitter;
    YTMockERC20 internal pt;
    YTMockERC20 internal yt;
    YTMockERC20 internal pol;
    MemeverseYTFlashSwapRouter internal router;
    YTFlashSwapHandler internal handler;

    uint256 internal ptBaseline;
    uint256 internal polBaseline;
    uint256 internal ytBaseline;

    function setUp() public {
        manager = new MockYTManager();
        hook = new MockYTHook();
        launcher = new MockLauncher();
        splitter = new MockYTSplitter();
        pt = new YTMockERC20("PT", "PT");
        yt = new YTMockERC20("YT", "YT");
        pol = new YTMockERC20("POL", "POL");

        // Wire the canonical dependency graph the router re-derives on every call.
        hook.setLauncher(address(launcher));
        hook.setPoolManager(IPoolManager(address(manager)));
        launcher.setCanonicalHook(address(hook));
        launcher.setCanonicalSplitter(address(splitter));
        splitter.setVerseAssets(VERSE_ID, address(pt), address(yt), address(pol));

        router = new MemeverseYTFlashSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), IPOLSplitter(address(splitter))
        );

        _seedRouterDust();

        handler = new YTFlashSwapHandler(router, manager, hook, splitter, pt, yt, pol);

        // Baselines include any fixture dust so each flash must preserve pre-existing router balances.
        ptBaseline = pt.balanceOf(address(router));
        polBaseline = pol.balanceOf(address(router));
        ytBaseline = yt.balanceOf(address(router));

        // Restrict the fuzzer to the two user entries only.
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = handler.buy.selector;
        sels[1] = handler.sell.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @dev Default fixture preserves the zero-balance router baseline.
    function _seedRouterDust() internal virtual {}

    /// @dev Router PT/YT/POL balances return to baseline, the splitter POL allowance is fully consumed, and every
    ///      currency delta touched during the flash closes to zero.
    function invariant_BaselineAllowanceAndDeltaClose() public view {
        assertEq(pt.balanceOf(address(router)), ptBaseline);
        assertEq(pol.balanceOf(address(router)), polBaseline);
        assertEq(yt.balanceOf(address(router)), ytBaseline);
        assertEq(pol.allowance(address(router), address(splitter)), 0);
        assertEq(manager.openDeltaCount(address(router)), 0);
    }

    /// @dev Each successful flash drives exactly one underlying swap and exactly one split (buy) or merge (sell), so
    ///      both the manager swap-window count and the splitter split+merge count equal the handler's successful-flash
    ///      count.
    function invariant_OneSwapAndOneSplitOrMergePerSuccess() public view {
        assertEq(manager.successfulUnlockSwapCount(), handler.successfulFlashCount());
        assertEq(splitter.splitCount() + splitter.mergeCount(), handler.successfulFlashCount());
    }
}

/// @title MemeverseYTFlashSwapRouterInvariantTest
/// @notice Runs the shared YT Flash Swap router invariant campaign from a zero token-balance baseline.
contract MemeverseYTFlashSwapRouterInvariantTest is MemeverseYTFlashSwapRouterInvariantBase {}

/// @title MemeverseYTFlashSwapRouterDustInvariantTest
/// @notice Runs the shared YT Flash Swap router invariant campaign with non-zero PT, YT, and POL router balances.
contract MemeverseYTFlashSwapRouterDustInvariantTest is MemeverseYTFlashSwapRouterInvariantBase {
    /// @dev Distinct router balances verify flash settlement preserves each pre-existing asset independently.
    function _seedRouterDust() internal override {
        pt.mint(address(router), 17);
        yt.mint(address(router), 19);
        pol.mint(address(router), 23);
    }
}

/// @title YTFlashSwapHandler
/// @notice Fuzzer handler that exercises the router's two user entries. Each action funds and approves itself as the
///         payer, scripts a deterministic y -> y/2 delta, and bumps the successful-flash counter only on a non-reverting
///         flash. A reverting flash rolls the counter back together with the handler call.
/// @dev `y` is bounded to `[2, type(int128).max]` so `r = y / 2` always satisfies `0 < r < y` and `cost = y - r` is
///      non-zero. The handler is its own payer and recipient, so router baseline (not handler balance) is what matters.
contract YTFlashSwapHandler is Test {
    uint256 internal constant VERSE_ID = 42;
    uint160 internal constant PRICE_LIMIT = type(uint160).max;

    MemeverseYTFlashSwapRouter public immutable router;
    MockYTManager public immutable manager;
    MockYTHook public immutable hook;
    MockYTSplitter public immutable splitter;
    YTMockERC20 public immutable pt;
    YTMockERC20 public immutable yt;
    YTMockERC20 public immutable pol;

    uint256 internal _successfulFlashCount;

    constructor(
        MemeverseYTFlashSwapRouter router_,
        MockYTManager manager_,
        MockYTHook hook_,
        MockYTSplitter splitter_,
        YTMockERC20 pt_,
        YTMockERC20 yt_,
        YTMockERC20 pol_
    ) {
        router = router_;
        manager = manager_;
        hook = hook_;
        splitter = splitter_;
        pt = pt_;
        yt = yt_;
        pol = pol_;
    }

    /// @notice Number of flashes that completed without reverting. Read by the invariant assertions.
    function successfulFlashCount() external view returns (uint256) {
        return _successfulFlashCount;
    }

    /// @dev Buy `y` YT: fund/approve the handler as payer, script a y PT -> y/2 POL delta so `cost = y - r`, then call
    ///         the buy entry as the active session principal. `maxPOLIn` is set to the actual cost (not `r`) so odd `y`
    ///         does not trip `MaxPOLInExceeded` (`cost = (y + 1) / 2 > r = y / 2` for odd `y`); this keeps every fuzz
    ///         input on the success path. Increments the counter only after the entry returns.
    function buy(uint96 rawY) external {
        uint256 y = bound(uint256(rawY), 2, uint256(uint128(type(int128).max)));
        uint256 r = y / 2;
        _fundApprovePOL(y);
        _scriptBuy(y, r);
        hook.setActivePrincipal(address(this));
        router.swapPOLForExactYT(VERSE_ID, y, y - r, PRICE_LIMIT, address(this), block.timestamp, address(0));
        _successfulFlashCount += 1;
    }

    /// @dev Sell `y` YT: fund/approve the handler as payer, script a y PT / -(y/2) POL delta so `out = y/2`, then call
    ///         the sell entry as the active session principal. Increments the counter only after the entry returns.
    function sell(uint96 rawY) external {
        uint256 y = bound(uint256(rawY), 2, uint256(uint128(type(int128).max)));
        uint256 q = y / 2;
        _fundApproveYT(y);
        _scriptSell(y, q);
        hook.setActivePrincipal(address(this));
        router.swapExactYTForPOL(VERSE_ID, y, 0, PRICE_LIMIT, address(this), block.timestamp, address(0));
        _successfulFlashCount += 1;
    }

    /// @dev Mints and approves enough POL for the buy cost `y - r` (funds `y` to stay safely above cost).
    function _fundApprovePOL(uint256 y) internal {
        pol.mint(address(this), y);
        pol.approve(address(router), y);
    }

    /// @dev Mints and approves `y` YT for the sell pull.
    function _fundApproveYT(uint256 y) internal {
        yt.mint(address(this), y);
        yt.approve(address(router), y);
    }

    /// @dev Scripts the buy swap delta honoring the canonical currency ordering: the router takes `r` POL and owes `y`
    ///      PT to the pool.
    function _scriptBuy(uint256 y, uint256 r) internal {
        bool ptIsCurrency0 = address(pt) < address(pol);
        if (ptIsCurrency0) {
            manager.scriptSwapDelta(-int128(int256(y)), int128(int256(r)));
        } else {
            manager.scriptSwapDelta(int128(int256(r)), -int128(int256(y)));
        }
    }

    /// @dev Scripts the sell swap delta honoring the canonical currency ordering: the router takes `y` PT and owes `q`
    ///      POL to the pool.
    function _scriptSell(uint256 y, uint256 q) internal {
        bool ptIsCurrency0 = address(pt) < address(pol);
        int128 ptDelta = int128(int256(y));
        int128 polDelta = -int128(int256(q));
        if (ptIsCurrency0) {
            manager.scriptSwapDelta(ptDelta, polDelta);
        } else {
            manager.scriptSwapDelta(polDelta, ptDelta);
        }
    }
}
