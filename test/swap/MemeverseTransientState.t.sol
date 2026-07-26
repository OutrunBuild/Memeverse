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

        vm.prank(address(mockManager));
        hook.beforeSwap(address(this), key, params, bytes(""));

        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);

        BalanceDelta delta = toBalanceDelta(-int128(int256(expectedPoolInput)), int128(int256(50 ether)));

        vm.prank(address(mockManager));
        (, int128 unspecifiedDelta) = hook.afterSwap(address(this), key, params, delta, bytes(""));

        assertEq(unspecifiedDelta, 0, "input-side exact-input swap should not emit output delta");
    }

    function test_SamePoolPopThenPushUsesOnlyReplacementContext() external {
        (
            uint256 firstFee,
            uint160 firstPrice,
            uint256 firstCoreTarget,
            uint256 secondFee,
            uint160 secondPrice,
            uint256 secondCoreTarget
        ) = transientStateHarness.samePoolPopThenPush(poolId, 65, 11, 101, 35, 22, 202);

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
        ) = transientStateHarness.nestedDifferentPools(poolId, otherPoolId, 65, 11, 101, 35, 22, 202);

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
            transientStateHarness.popThenPushMode(poolId, inputModeFee, outputModeFee);

        assertEq(firstFee, inputModeFee, "input mode fee");
        assertEq(secondFee, outputModeFee, "output mode fee");
    }

    function test_PoppedContextIsUnreachableAtDepthZero() external {
        (uint256 emptyFee, uint160 emptyPrice, uint256 emptyCoreTarget) =
            transientStateHarness.consumeAfterPop(poolId, 65, 11);

        assertEq(emptyFee, 0, "empty context fee");
        assertEq(emptyPrice, 0, "empty context price");
        assertEq(emptyCoreTarget, 0, "empty context core target");
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
