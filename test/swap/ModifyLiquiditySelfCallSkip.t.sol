// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {RealisticSwapManagerHarness} from "../mocks/swap/RealisticSwapMocks.sol";

/// @notice Locks the modifyLiquidity self-call skip in RealisticSwapManagerHarness.
/// @dev Background: production `addLiquidityCore`/`removeLiquidityCore` route through
///      `poolManager.unlock()` reentry (MemeverseUniswapHook.sol:647), so `msg.sender` to
///      `poolManager.modifyLiquidity` is `address(hook)` itself. Real v4 skips
///      beforeModifyLiquidity/afterModifyLiquidity callbacks when `msg.sender == address(key.hooks)`
///      (Hooks.sol `noSelfCall` guard). The mock must replicate this skip, otherwise it
///      double-fires the hook's beforeAddLiquidityLogic on every LP add/remove. The production
///      hook's beforeAddLiquidityLogic is idempotent on the self-call path, so this bug is
///      invisible to the real-hook integration tests — it can only be caught by a spy that
///      records the callback. These tests pin the mock contract directly.
contract ModifyLiquiditySelfCallSkipTest is Test, IUnlockCallback {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    RealisticSwapManagerHarness internal manager;
    BeforeAddLiquiditySpyHook internal spyHook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    /// @dev What the test's unlockCallback should do: drive modifyLiquidity as the hook itself
    ///      (self-call, MODE_SELF) or as a distinct pranked address (MODE_NON_HOOK).
    bytes32 internal constant MODE_SELF = bytes32(uint256(1));
    bytes32 internal constant MODE_NON_HOOK = bytes32(uint256(2));

    PoolKey internal pendingKey;
    int256 internal pendingLiquidityDelta;
    bytes32 internal pendingMode;

    function setUp() public {
        manager = new RealisticSwapManagerHarness();
        spyHook = new BeforeAddLiquiditySpyHook();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(spyHook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        // Fund both caller identities so they can pay their add-liquidity deltas inside the callback.
        token0.mint(address(spyHook), 1_000 ether);
        token1.mint(address(spyHook), 1_000 ether);
        token0.mint(address(0xBEEF), 1_000 ether);
        token1.mint(address(0xBEEF), 1_000 ether);
    }

    /// @dev When the hook itself calls modifyLiquidity (self-call, msg.sender == address(key.hooks)),
    ///      the mock must skip beforeAddLiquidity, matching real v4. The spy records the call count.
    function testModifyLiquidity_SelfCallSkipsBeforeAddLiquidity() public {
        _driveModifyLiquidity(key, 1 ether, MODE_SELF);

        assertEq(spyHook.beforeAddLiquidityCallCount(), 0, "self-call must skip beforeAddLiquidity");
    }

    /// @dev Control group: a non-hook caller must still trigger beforeAddLiquidity. Proves the skip
    ///      is conditioned on msg.sender == address(key.hooks), not an unconditional suppression.
    function testModifyLiquidity_NonHookCallerFiresBeforeAddLiquidity() public {
        _driveModifyLiquidity(key, 1 ether, MODE_NON_HOOK);

        assertEq(spyHook.beforeAddLiquidityCallCount(), 1, "non-hook caller must fire beforeAddLiquidity");
    }

    // ------------------------------------------------------------------
    // Internal: the test contract owns the unlock callback so it can vm.prank the non-hook
    // caller. The spy only records the beforeAddLiquidity callback.
    // ------------------------------------------------------------------

    function _driveModifyLiquidity(PoolKey memory key_, int256 liquidityDelta, bytes32 mode) internal {
        pendingKey = key_;
        pendingLiquidityDelta = liquidityDelta;
        pendingMode = mode;
        manager.unlock(bytes(""));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: 0, tickUpper: 0, liquidityDelta: pendingLiquidityDelta, salt: bytes32(0)
        });

        // Determine the caller identity: the hook itself (self-call) or a distinct address (non-hook).
        address caller = pendingMode == MODE_SELF ? address(spyHook) : address(0xBEEF);

        // modifyLiquidity accounts a negative delta (caller owes token0 + token1) to `caller`. Settle
        // it under that identity so the manager's nonzeroDeltaCount returns to zero before unlock exits.
        vm.startPrank(caller);
        (BalanceDelta delta,) = manager.modifyLiquidity(pendingKey, params, bytes(""));

        // Add-liquidity delta is negative on both legs (caller pays in). Sync + pay + settle each.
        if (delta.amount0() < 0) {
            manager.sync(pendingKey.currency0);
            require(token0.transfer(address(manager), uint256(int256(-delta.amount0()))), "t0 transfer");
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(pendingKey.currency1);
            require(token1.transfer(address(manager), uint256(int256(-delta.amount1()))), "t1 transfer");
            manager.settle();
        }
        vm.stopPrank();
        return bytes("");
    }
}

/// @notice Minimal spy hook that records beforeAddLiquidity invocations.
/// @dev Implements the full IHooks surface so it can serve as `key.hooks`. Only
///      beforeAddLiquidity is instrumented; the other callbacks return canonical values.
contract BeforeAddLiquiditySpyHook is IHooks {
    uint256 public beforeAddLiquidityCallCount;

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        beforeAddLiquidityCallCount += 1;
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
