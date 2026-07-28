// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseTransientState} from "../../src/swap/libraries/MemeverseTransientState.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {TransientStateHarness} from "../mocks/swap/TransientStateHarness.sol";

contract MemeverseTransientStateTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHook internal hook;
    MemeverseUniswapHookLens internal lens;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;
    TransientStateHarness internal transientStateHarness;

    address internal accountA = makeAddr("accountA");
    address internal accountB = makeAddr("accountB");

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        hook = _deployHookProxy(address(this), address(this));
        lens = new MemeverseUniswapHookLens(IPoolManager(address(mockManager)));

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        transientStateHarness = new TransientStateHarness();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        mockManager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity();
    }

    function testAfterSwapUsesCachedProtocolFeeSideFromBeforeSwap() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        assertTrue(quote.protocolFeeOnInput, "expected input-side protocol fee");

        uint256 expectedPoolInput =
            quote.estimatedUserInputAmount - quote.estimatedLpFeeAmount - quote.estimatedProtocolFeeAmount;

        // The transient session principal must be established before the PoolManager fires beforeSwap; the
        // hook's own transient store is keyed by hook proxy address, so begin via the hook entry here.
        hook.beginAccountSession();
        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);

        BalanceDelta delta = toBalanceDelta(-int128(int256(expectedPoolInput)), int128(int256(50 ether)));

        vm.prank(address(mockManager));
        (, int128 unspecifiedDelta) = hook.afterSwap(address(this), key, params, delta, bytes(""));

        assertEq(unspecifiedDelta, 0, "input-side exact-input swap should not emit output delta");
        hook.endAccountSession();
    }

    // -----------------------------------------------------------------
    // activePrincipal lifecycle
    // -----------------------------------------------------------------

    function test_activePrincipalStartsZeroAndClears() external {
        assertEq(transientStateHarness.activePrincipal(), address(0), "starts at zero");
        transientStateHarness.setActivePrincipal(accountA);
        assertEq(transientStateHarness.activePrincipal(), accountA, "set to accountA");
        transientStateHarness.clearActivePrincipal();
        assertEq(transientStateHarness.activePrincipal(), address(0), "cleared back to zero");
    }

    // -----------------------------------------------------------------
    // Per-pool swap-lifecycle lock still uses its own original key (the original four tests below are byte-for-byte).
    // -----------------------------------------------------------------

    function test_existingPerPoolReentrancyLockStillUsesItsOriginalKey() external {
        // Acquiring the lifecycle lock must NOT touch the swap-context depth or the active-principal slot:
        // all three share the `mv.ts.*` namespace but use independent collision-domain tags.
        assertEq(transientStateHarness.swapContextDepth(), 0, "depth zero before lock");
        assertEq(transientStateHarness.activePrincipal(), address(0), "principal zero before lock");
        bool alreadyLocked = transientStateHarness.acquireOnce(poolId);
        assertFalse(alreadyLocked, "first acquire gets the lock");
        assertEq(transientStateHarness.swapContextDepth(), 0, "lock does not touch context depth");
        assertEq(transientStateHarness.activePrincipal(), address(0), "lock does not touch principal");
    }

    function test_FirstAcquireReturnsFalse() external {
        bool alreadyLocked = transientStateHarness.acquireOnce(poolId);
        assertFalse(alreadyLocked, "first acquire gets the lock");
    }

    function test_SecondAcquireSamePoolReturnsTrue() external {
        (bool firstAlreadyLocked, bool secondAlreadyLocked) = transientStateHarness.acquireTwiceSamePool(poolId);

        assertFalse(firstAlreadyLocked, "first acquire gets the lock");
        assertTrue(secondAlreadyLocked, "second acquire is reentrancy signal");
    }

    function test_AfterReleaseAcquireReturnsFalseAgain() external {
        (bool firstAlreadyLocked, bool afterReleaseAlreadyLocked) = transientStateHarness.acquireReleaseAcquire(poolId);

        assertFalse(firstAlreadyLocked, "first acquire gets the lock");
        assertFalse(afterReleaseAlreadyLocked, "release frees the lock");
    }

    function test_DifferentPoolsAcquireIndependently() external {
        PoolId otherPoolId = PoolId.wrap(bytes32(uint256(123)));
        (bool firstAlreadyLocked, bool secondAlreadyLocked) = transientStateHarness.acquireTwoPools(poolId, otherPoolId);

        assertFalse(firstAlreadyLocked, "pool A gets its lock");
        assertFalse(secondAlreadyLocked, "pool B has its own lock slot");
    }

    // -----------------------------------------------------------------
    // consumeCurrentSwapContext depth / presence semantics
    // -----------------------------------------------------------------

    function test_consumeEmptyContextLeavesDepthUnchanged() external {
        assertEq(transientStateHarness.swapContextDepth(), 0, "depth zero before");
        MemeverseTransientState.SwapContext memory empty = transientStateHarness.consumeCurrentSwapContextDirect(poolId);
        assertEq(empty.encodedFeeBps, 0, "empty context fee");
        assertEq(empty.preSqrtPriceX96, 0, "empty context price");
        assertEq(empty.coreTarget, 0, "empty context core target");
        assertEq(empty.principal, address(0), "empty context principal");
        assertEq(transientStateHarness.swapContextDepth(), 0, "depth unchanged after empty consume");
    }

    function test_consumeWrongPoolLeavesDepthUnchanged() external {
        PoolId otherPoolId = PoolId.wrap(bytes32(uint256(123)));
        transientStateHarness.pushSwapContextDirect(poolId, accountA, 65, 11, 101);
        assertEq(transientStateHarness.swapContextDepth(), 1, "depth one after push");

        // Consuming a DIFFERENT poolId sees no principal at the wrong tuple key and must NOT decrement depth.
        MemeverseTransientState.SwapContext memory wrong =
            transientStateHarness.consumeCurrentSwapContextDirect(otherPoolId);
        assertEq(wrong.principal, address(0), "wrong pool has no principal");
        assertEq(wrong.encodedFeeBps, 0, "wrong pool fee");
        assertEq(transientStateHarness.swapContextDepth(), 1, "depth unchanged after wrong-pool consume");

        // The pushed context at the original poolId is still consumable.
        MemeverseTransientState.SwapContext memory right = transientStateHarness.consumeCurrentSwapContextDirect(poolId);
        assertEq(right.principal, accountA, "right pool still has the pushed principal");
        assertEq(right.encodedFeeBps, 65, "right pool fee");
        assertEq(transientStateHarness.swapContextDepth(), 0, "depth zero after correct consume");
    }

    function test_consumeZeroPrincipalLeavesDepthUnchanged() external {
        // A push with address(0) principal represents the missing-principal / unsupported path. The sole
        // context-presence marker is `principal != address(0)`, so such a push must consume to a zero context
        // WITHOUT decrementing depth (no false "context present" signal, no depth leak).
        transientStateHarness.pushSwapContextDirect(poolId, address(0), 65, 11, 101);
        assertEq(transientStateHarness.swapContextDepth(), 1, "depth one after zero-principal push");

        MemeverseTransientState.SwapContext memory empty = transientStateHarness.consumeCurrentSwapContextDirect(poolId);
        assertEq(empty.principal, address(0), "zero-principal push consumes to zero context");
        assertEq(empty.encodedFeeBps, 0, "no fee surfaced for missing principal");
        assertEq(transientStateHarness.swapContextDepth(), 1, "depth unchanged after missing-principal consume");
    }

    function test_contextStoresPrincipalAtEachDepthAndConsumesLifo() external {
        // push A at accountA (depth 1), then push B at accountB (depth 2). LIFO consume returns B then A.
        transientStateHarness.pushSwapContextDirect(poolId, accountA, 65, 11, 101);
        transientStateHarness.pushSwapContextDirect(poolId, accountB, 35, 22, 202);
        assertEq(transientStateHarness.swapContextDepth(), 2, "depth two after two pushes");

        MemeverseTransientState.SwapContext memory inner = transientStateHarness.consumeCurrentSwapContextDirect(poolId);
        assertEq(inner.principal, accountB, "inner context principal is accountB");
        assertEq(inner.encodedFeeBps, 35, "inner context fee");
        assertEq(inner.preSqrtPriceX96, 22, "inner context price");
        assertEq(inner.coreTarget, 202, "inner context core target");
        assertEq(transientStateHarness.swapContextDepth(), 1, "depth one after inner consume");

        MemeverseTransientState.SwapContext memory outer = transientStateHarness.consumeCurrentSwapContextDirect(poolId);
        assertEq(outer.principal, accountA, "outer context principal is accountA");
        assertEq(outer.encodedFeeBps, 65, "outer context fee");
        assertEq(outer.preSqrtPriceX96, 11, "outer context price");
        assertEq(outer.coreTarget, 101, "outer context core target");
        assertEq(transientStateHarness.swapContextDepth(), 0, "depth zero after outer consume");
    }

    // -----------------------------------------------------------------
    // Adapted pop/push/context scenarios (new 5-arg signature + SwapContext return).
    // -----------------------------------------------------------------

    function test_SamePoolPopThenPushUsesOnlyReplacementContext() external {
        (
            uint256 firstFee,
            uint160 firstPrice,
            uint256 firstCoreTarget,
            uint256 secondFee,
            uint160 secondPrice,
            uint256 secondCoreTarget
        ) = transientStateHarness.samePoolPopThenPush(poolId, accountA, 65, 11, 101, 35, 22, 202);

        assertEq(firstFee, 65, "first context fee");
        assertEq(firstPrice, 11, "first context price");
        assertEq(firstCoreTarget, 101, "first context core target");
        assertEq(secondFee, 35, "replacement context fee");
        assertEq(secondPrice, 22, "replacement context price");
        assertEq(secondCoreTarget, 202, "replacement context core target");
    }

    function test_NestedDifferentPoolsPopInStackOrder() external {
        PoolId otherPoolId = PoolId.wrap(bytes32(uint256(123)));
        (
            uint256 innerFee,
            uint160 innerPrice,
            uint256 innerCoreTarget,
            uint256 outerFee,
            uint160 outerPrice,
            uint256 outerCoreTarget
        ) = transientStateHarness.nestedDifferentPools(poolId, otherPoolId, accountA, 65, 11, 101, 35, 22, 202);

        assertEq(innerFee, 35, "inner context fee");
        assertEq(innerPrice, 22, "inner context price");
        assertEq(innerCoreTarget, 202, "inner context core target");
        assertEq(outerFee, 65, "outer context fee");
        assertEq(outerPrice, 11, "outer context price");
        assertEq(outerCoreTarget, 101, "outer context core target");
    }

    function test_PopThenPushPreservesEncodedFeeMode() external {
        uint256 inputModeFee = (uint256(65) | (uint256(1) << 255));
        uint256 outputModeFee = 35;
        (uint256 firstFee, uint256 secondFee) =
            transientStateHarness.popThenPushMode(poolId, accountA, inputModeFee, outputModeFee);

        assertEq(firstFee, inputModeFee, "input mode fee");
        assertEq(secondFee, outputModeFee, "output mode fee");
    }

    function test_PoppedContextIsUnreachableAtDepthZero() external {
        (uint256 emptyFee, uint160 emptyPrice, uint256 emptyCoreTarget) =
            transientStateHarness.consumeAfterPop(poolId, accountA, 65, 11);

        assertEq(emptyFee, 0, "empty context fee");
        assertEq(emptyPrice, 0, "empty context price");
        assertEq(emptyCoreTarget, 0, "empty context core target");
    }

    function _deployHookProxy(address owner_, address treasury_) internal returns (MemeverseUniswapHook) {
        // Deploy the real MemeverseUniswapHook behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), owner_, treasury_);
        return MemeverseUniswapHook(hookProxy);
    }

    function _addLiquidity() internal {
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
