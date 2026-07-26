// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {SwapGuardMath} from "../../src/swap/libraries/SwapGuardMath.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @title MemeverseQuoteReadOnlyInvariantTest
/// @notice Pins the read-only invariant of `quoteSwapFeeWithContext` under a direct ordinary CALL.
/// @dev `quoteSwapFeeWithContext` cannot be marked `view` because solc rejects `view` + `delegatecall`
///      (Error 8961), yet it must stay read-only: `DynamicFeeFacet.quote` refreshes the volatility anchor
///      on a `memory` copy, so an ordinary CALL must not mutate hook storage. The Lens enforces STATICCALL,
///      but an ordinary CALL path exists too; this test nails it down so a future change that swaps the
///      facet's `memory` refresh for a `storage` write fails CI immediately instead of silently mutating
///      state on every public quote.
contract MemeverseQuoteReadOnlyInvariantTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForHookLiquidity internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseUniswapHookLens internal lens;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    function _deployHookProxy(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (same pattern as MemeverseUniswapHookLaunchFeeQuoteInvariantTest), so `_validateProxyHookAddress`
        // and the diamond facet wiring run identically to production.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        return MemeverseUniswapHook(hookProxy);
    }

    function setUp() external {
        // The deployed manager, lens, tokens, key, hook, and poolId are shared fixtures for later checks.
        manager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        hook = _deployHookProxy(IPoolManager(address(manager)), address(this), address(this));
        lens = new MemeverseUniswapHookLens(IPoolManager(address(manager)));

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setProtocolFeeCurrency(key.currency0, true);
        seedActiveLiquiditySharesForTest(address(hook), poolId, address(this), 1_000_000 ether);
    }

    /// @dev Captures all `DynamicFeeState` fields into a flat uint256 array so two snapshots can be
    ///      compared field-by-field. Comparing the struct memory pointer is not possible in Solidity, and
    ///      a single packed hash would hide which field drifted; per-field assertEq pinpoints regressions.
    function _snapshotFeeState(PoolId id) internal view returns (uint256[9] memory snap) {
        IDynamicFeeFacet.DynamicFeeState memory s = hook.dynamicFeeStateOf(id);
        snap[0] = s.weightedVolume0;
        snap[1] = s.weightedPriceVolume0;
        snap[2] = s.ewVWAPX18;
        snap[3] = uint256(s.volAnchorSqrtPriceX96);
        snap[4] = uint256(s.volLastMoveTs);
        snap[5] = uint256(s.volDeviationAccumulator);
        snap[6] = uint256(s.volCarryAccumulator);
        snap[7] = uint256(s.shortImpactPpm);
        snap[8] = uint256(s.shortLastTs);
    }

    function _assertFeeStateUnchanged(uint256[9] memory pre, uint256[9] memory post) internal pure {
        // On the first-ever quote the storage state is all-zero, so `quote` hits the
        // `volAnchorSqrtPriceX96 == 0 -> params.preSqrtPriceX96` branch on a memory copy. If that refresh
        // were ever redirected to storage, `volAnchorSqrtPriceX96` would flip from 0 to preSqrtPriceX96
        // here; this assertEq catches exactly that regression.
        assertEq(post[0], pre[0], "weightedVolume0 mutated");
        assertEq(post[1], pre[1], "weightedPriceVolume0 mutated");
        assertEq(post[2], pre[2], "ewVWAPX18 mutated");
        assertEq(post[3], pre[3], "volAnchorSqrtPriceX96 mutated");
        assertEq(post[4], pre[4], "volLastMoveTs mutated");
        assertEq(post[5], pre[5], "volDeviationAccumulator mutated");
        assertEq(post[6], pre[6], "volCarryAccumulator mutated");
        assertEq(post[7], pre[7], "shortImpactPpm mutated");
        assertEq(post[8], pre[8], "shortLastTs mutated");
    }

    /// @notice A direct ordinary CALL to `quoteSwapFeeWithContext` must not mutate any dynamic fee state.
    /// @dev This is the core read-only invariant. The Lens forces STATICCALL, but `quoteSwapFeeWithContext`
    ///      is an unrestricted `external` entry, so the ordinary-CALL path must be independently read-only.
    function testQuoteSwapFeeWithContext_OrdinaryCallLeavesDynamicFeeStateUntouched() external {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256[9] memory pre = _snapshotFeeState(poolId);

        // Ordinary CALL — NOT routed through the Lens STATICCALL. This exercises the exact path that the
        // EIP-214 static flag does NOT protect. `quoteSwapFeeWithContext` is non-view (delegatecall) so a
        // direct call compiles and executes; correctness rests on the facet's memory-only refresh.
        IDynamicFeeFacet.PreparedSwapFee memory quote = IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, address(this), SQRT_PRICE_1_1, 1_000_000 ether, true);

        // The quote must still return a sane value — read-only does not mean no-op.
        assertGt(quote.feeBps, 0, "quote returned zero fee");

        uint256[9] memory post = _snapshotFeeState(poolId);
        _assertFeeStateUnchanged(pre, post);
    }

    /// @notice Repeated ordinary CALLs must stay read-only even when the volatility refresh plan fires.
    /// @dev `DynamicFeeMath.volatilityRefreshPlan` can return `shouldRefresh=true` when `volLastMoveTs`
    ///      is old; the refresh must still write only the memory copy. We warp forward to force the
    ///      refresh branch on the second call so this path is covered, not just the all-zero first call.
    function testQuoteSwapFeeWithContext_RepeatedOrdinaryCallsStayReadOnly() external {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256[9] memory beforeFirst = _snapshotFeeState(poolId);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, address(this), SQRT_PRICE_1_1, 1_000_000 ether, true);
        _assertFeeStateUnchanged(beforeFirst, _snapshotFeeState(poolId));

        // Warp past the volatility refresh window so the next quote takes the `shouldRefresh` branch.
        vm.warp(block.timestamp + 1 days);

        uint256[9] memory beforeSecond = _snapshotFeeState(poolId);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, address(this), SQRT_PRICE_1_1, 1_000_000 ether, true);
        _assertFeeStateUnchanged(beforeSecond, _snapshotFeeState(poolId));
    }

    /// @notice A non-zero direct quote observes the same active public-swap pause as execution.
    function testQuoteSwapFeeWithContext_NonZeroAmountRejectsActivePublicSwapPause() external {
        hook.setLauncher(address(this));
        hook.setPublicSwapResumeTime(address(token0), address(token1), uint40(block.timestamp + 1 hours));
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert(SwapGuardMath.PublicSwapDisabled.selector);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, address(this), SQRT_PRICE_1_1, 1_000_000 ether, true);
    }

    /// @notice Direct bridge, Lens, and execution all reject live pool liquidity with no active LP shares.
    function testQuoteAndExecutionRejectOrphanLiquidityWithTheSameError() external {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );

        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0, "live pool liquidity");
        _writeSlot(address(hook), _poolIdMappingSlot(OFF_CACHED_LP_TOTAL_SUPPLY, poolId), bytes32(0));
        assertEq(hook.cachedLpTotalSupply(poolId), 0, "orphaned cached supply");

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert(SwapGuardMath.NoActiveLiquidityShares.selector);
        IMemeverseUniswapHook(address(hook))
            .quoteSwapFeeWithContext(poolId, params, address(this), SQRT_PRICE_1_1, liquidity, true);

        vm.expectRevert(SwapGuardMath.NoActiveLiquidityShares.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        vm.expectRevert(SwapGuardMath.NoActiveLiquidityShares.selector);
        manager.swapAsUnlocked(key, params, "");
    }

    /// @notice Zero direct quote skips liquidity and raw-limit validation and remains read-only.
    function testQuoteSwapFeeWithContext_ZeroAmountAllowsZeroContext() external {
        hook.setLauncher(address(this));
        hook.setPublicSwapResumeTime(address(token0), address(token1), uint40(block.timestamp + 1 hours));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        uint256[9] memory beforeQuote = _snapshotFeeState(poolId);

        IDynamicFeeFacet.PreparedSwapFee memory quote =
            IMemeverseUniswapHook(address(hook)).quoteSwapFeeWithContext(poolId, params, address(this), 0, 0, true);

        assertEq(quote.feeBps, 5000, "current launch/base floor");
        assertEq(quote.estimatedInputAmount, 0, "zero user input");
        assertEq(quote.estimatedOutputAmount, 0, "zero user output");
        _assertFeeStateUnchanged(beforeQuote, _snapshotFeeState(poolId));
    }
}
