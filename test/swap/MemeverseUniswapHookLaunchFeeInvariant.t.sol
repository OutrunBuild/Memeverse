// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title Launch fee decay quote invariant
/// @notice Invariant fuzz suite over the lens quote path: the quoted fee must track the launch fee
///         decay formula, never increase with time, and leave the pool launch timestamp stable.
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {wadExp} from "solmate/utils/SignedWadMath.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

function _validExecutionPriceLimit(bool zeroForOne) pure returns (uint160) {
    return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
}

contract LaunchFeeQuoteHandler is Test {
    MemeverseUniswapHookUpgradeable internal immutable hook;
    MemeverseUniswapHookLens internal immutable lens;
    PoolKey internal key;
    uint256 public lastObservedFeeBps;

    constructor(MemeverseUniswapHookUpgradeable _hook, MemeverseUniswapHookLens _lens, PoolKey memory _key) {
        hook = _hook;
        lens = _lens;
        key = _key;
        lastObservedFeeBps = _currentQuoteFee();
    }

    /// @notice Test helper for warp.
    /// @param deltaSeed See implementation.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 30 minutes));

        uint256 currentFee = _currentQuoteFee();
        assertLe(currentFee, lastObservedFeeBps, "launch fee must not increase with time");
        lastObservedFeeBps = currentFee;
    }

    /// @notice Test helper for quoteVariants.
    /// @param amountSeed See implementation.
    function quoteVariants(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1 ether, 10_000 ether);
        uint256 expectedFee = _currentQuoteFee();

        IMemeverseUniswapHook.SwapQuote memory zeroForOneExactInput = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this)
        );
        IMemeverseUniswapHook.SwapQuote memory zeroForOneExactOutput = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amount), sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this)
        );
        IMemeverseUniswapHook.SwapQuote memory oneForZeroExactInput = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            address(this)
        );
        IMemeverseUniswapHook.SwapQuote memory oneForZeroExactOutput = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(amount), sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            address(this)
        );

        assertEq(zeroForOneExactInput.feeBps, expectedFee, "zfo exact-input fee");
        assertEq(zeroForOneExactOutput.feeBps, expectedFee, "zfo exact-output fee");
        assertEq(oneForZeroExactInput.feeBps, expectedFee, "ofz exact-input fee");
        assertEq(oneForZeroExactOutput.feeBps, expectedFee, "ofz exact-output fee");
    }

    function _currentQuoteFee() internal returns (uint256 feeBps) {
        return lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this)
        )
        .feeBps;
    }
}

contract MemeverseUniswapHookLaunchFeeQuoteInvariantTest is StdInvariant, Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForHookLiquidity internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseUniswapHookLens internal lens;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;
    LaunchFeeQuoteHandler internal handler;

    function _deployHookProxy(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHookUpgradeable deployed)
    {
        // Deploy the real MemeverseUniswapHookUpgradeable behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        return MemeverseUniswapHookUpgradeable(hookProxy);
    }

    /// @notice Test helper for setUp.
    function setUp() external {
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

        uint256 liquidityAmount = 1_000_000_000_000 ether;
        token0.mint(address(this), liquidityAmount);
        token1.mint(address(this), liquidityAmount);
        token0.approve(address(hook), liquidityAmount);
        token1.approve(address(hook), liquidityAmount);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: liquidityAmount,
                amount1Desired: liquidityAmount,
                to: address(this)
            })
        );

        handler = new LaunchFeeQuoteHandler(hook, lens, key);
        targetContract(address(handler));
    }

    /// @notice Test helper for invariant_quoteFeeMatchesLaunchDecayFormula.
    function invariant_quoteFeeMatchesLaunchDecayFormula() external {
        uint256 expectedFee = _expectedLaunchFee();

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this)
        );

        assertEq(quote.feeBps, expectedFee, "launch quote mismatch");
        assertGe(quote.feeBps, 100, "fee below min");
        assertLe(quote.feeBps, 5000, "fee above start");
    }

    /// @notice Test helper for invariant_poolLaunchTimestampRemainsStable.
    function invariant_poolLaunchTimestampRemainsStable() external view {
        assertEq(hook.poolLaunchTimestamp(poolId), 1, "pool launch timestamp");
    }

    function _expectedLaunchFee() internal view returns (uint256 feeBps) {
        uint256 elapsed = block.timestamp > 1 ? block.timestamp - 1 : 0;
        if (elapsed >= 900) return 100;

        uint256 startFee = 5000;
        uint256 minFee = 100;
        int256 expAtElapsedWad = wadExp(-int256(elapsed * 4e18 / 900));
        int256 expAtEndWad = wadExp(-4e18);
        uint256 normalizedWad = uint256((expAtElapsedWad - expAtEndWad) * 1e18 / (1e18 - expAtEndWad));
        return minFee + (startFee - minFee) * normalizedWad / 1e18;
    }
}
