// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {LiquidityAmounts} from "../../../src/swap/libraries/LiquidityAmounts.sol";

/// @dev Mock-harness boundary:
/// - This file's mock manager only covers local plumbing, witness/deadline handling,
///   local revert surface, and deterministic branch coverage used by SwapRouter router tests.
/// - The newer integration tests only cover a narrow exact-input subset under a stricter manager harness.
///   Exact-output, one-for-zero symmetry outside that subset, and other broader swap economics claims are not
///   proven by this mock manager and must not be inferred from it.
contract MockPoolManagerForRouterTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error ManagerLocked();

    struct Slot0State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    bytes internal constant ZERO_BYTES = bytes("");
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint160 internal constant SQRT_PRICE_LOWER_X96 = 4_310_618_292;
    uint160 internal constant SQRT_PRICE_UPPER_X96 = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;

    bool internal unlocked;
    bool internal quoteAlignedSwapMath;
    address internal lastUnlockCallbackPayer;
    mapping(bytes32 => bytes32) internal extStorage;
    mapping(PoolId => Slot0State) internal slot0State;
    mapping(PoolId => uint128) internal liquidityState;
    mapping(PoolId => uint160) internal nextSwapSqrtPriceX96;
    mapping(PoolId => uint256) internal nextExactInputPoolInputAmount;
    mapping(PoolId => uint256) internal nextExactOutputAmount;

    /// @notice Initializes mock pool state for a hook-managed pair.
    /// @dev Seeds slot0 and liquidity before calling the hook initialize callback.
    /// @param key Pool key to initialize.
    /// @param sqrtPriceX96 Initial square-root price for the pool.
    /// @return tick Mock initial tick returned to the caller.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId poolId = key.toId();
        slot0State[poolId] = Slot0State({sqrtPriceX96: sqrtPriceX96, tick: 0, protocolFee: 0, lpFee: 0});
        liquidityState[poolId] = 1e24;
        _syncPoolStorage(poolId);
        key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
        tick = 0;
    }

    /// @notice Opens the mock manager unlock window and forwards the callback.
    /// @dev Mimics the pool manager unlock flow expected by the router and hook.
    /// @param data Encoded callback payload.
    /// @return result Raw callback return data.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        // Production CallbackData no longer has a payer field; the router always settles from
        // its own balance, so record the unlock initiator as a semantic proxy for lastUnlockPayer.
        lastUnlockCallbackPayer = msg.sender;
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function setQuoteAlignedSwapMath(bool enabled) external {
        quoteAlignedSwapMath = enabled;
    }

    /// @notice Applies a mocked liquidity modification for a pool key.
    /// @dev Tracks liquidity and returns deterministic token deltas for tests.
    /// @param key Pool key whose liquidity is modified.
    /// @param params Liquidity modification parameters.
    /// @param hookData Unused hook data forwarded by the router test harness.
    /// @return delta Mock balance delta for the liquidity change.
    /// @return feesAccrued Mock accrued fees, always zero in this harness.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        hookData;
        if (!unlocked) revert ManagerLocked();
        uint256 amount0Used;
        uint256 amount1Used;

        if (params.liquidityDelta > 0) {
            key.hooks.beforeAddLiquidity(msg.sender, key, params, ZERO_BYTES);
            liquidityState[key.toId()] += uint128(uint256(params.liquidityDelta));
            _syncPoolStorage(key.toId());
            (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
                slot0State[key.toId()].sqrtPriceX96,
                SQRT_PRICE_LOWER_X96,
                SQRT_PRICE_UPPER_X96,
                uint128(uint256(params.liquidityDelta))
            );
            delta = toBalanceDelta(-int128(int256(amount0Used)), -int128(int256(amount1Used)));
            return (delta, feesAccrued);
        }

        liquidityState[key.toId()] -= uint128(uint256(-params.liquidityDelta));
        _syncPoolStorage(key.toId());
        (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
            slot0State[key.toId()].sqrtPriceX96,
            SQRT_PRICE_LOWER_X96,
            SQRT_PRICE_UPPER_X96,
            uint128(uint256(-params.liquidityDelta))
        );
        delta = toBalanceDelta(int128(int256(amount0Used)), int128(int256(amount1Used)));
    }

    /// @notice Executes a mocked swap against the configured hook callbacks.
    /// @dev Produces deterministic deltas for local router-harness branch coverage only.
    /// @param key Pool key to swap against.
    /// @param params Swap parameters.
    /// @param hookData Opaque hook data forwarded into the mock hook callbacks.
    /// @return delta Mock balance delta for the swap.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        if (!unlocked) revert ManagerLocked();

        PoolId poolId = key.toId();
        // Real v4 skips both swap callbacks when the hook itself calls PoolManager.swap. Other callers retain
        // the normal callback path.
        bool callSwapHooks = msg.sender != address(key.hooks);
        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        int256 amountToSwap = params.amountSpecified;
        if (callSwapHooks) {
            (, beforeSwapDelta,) = key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }
        amountToSwap += beforeSwapDelta.getSpecifiedDelta();

        BalanceDelta poolDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if (amountToSwap != 0) {
            if (quoteAlignedSwapMath) {
                Slot0State memory state = slot0State[poolId];
                uint128 liquidity = liquidityState[poolId];
                if (params.amountSpecified < 0) {
                    uint256 inputAmount = uint256(-amountToSwap);
                    uint256 configuredInputAmount = nextExactInputPoolInputAmount[poolId];
                    if (configuredInputAmount != 0) {
                        inputAmount = configuredInputAmount;
                        delete nextExactInputPoolInputAmount[poolId];
                    }
                    uint160 alignedNextSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        state.sqrtPriceX96, liquidity, inputAmount, params.zeroForOne
                    );
                    uint256 outputAmount = params.zeroForOne
                        ? SqrtPriceMath.getAmount1Delta(alignedNextSqrtPriceX96, state.sqrtPriceX96, liquidity, false)
                        : SqrtPriceMath.getAmount0Delta(state.sqrtPriceX96, alignedNextSqrtPriceX96, liquidity, false);
                    poolDelta = params.zeroForOne
                        ? toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)))
                        : toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                    slot0State[poolId].sqrtPriceX96 = alignedNextSqrtPriceX96;
                    _syncPoolStorage(poolId);
                } else {
                    uint256 outputAmount = uint256(amountToSwap);
                    uint160 alignedNextSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                        state.sqrtPriceX96, liquidity, outputAmount, params.zeroForOne
                    );
                    uint256 inputAmount = params.zeroForOne
                        ? SqrtPriceMath.getAmount0Delta(alignedNextSqrtPriceX96, state.sqrtPriceX96, liquidity, true)
                        : SqrtPriceMath.getAmount1Delta(state.sqrtPriceX96, alignedNextSqrtPriceX96, liquidity, true);
                    poolDelta = params.zeroForOne
                        ? toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)))
                        : toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                    slot0State[poolId].sqrtPriceX96 = alignedNextSqrtPriceX96;
                    _syncPoolStorage(poolId);
                }
            } else if (params.amountSpecified < 0) {
                uint256 inputAmount = uint256(-amountToSwap);
                uint256 configuredInputAmount = nextExactInputPoolInputAmount[poolId];
                if (configuredInputAmount != 0) {
                    inputAmount = configuredInputAmount;
                    delete nextExactInputPoolInputAmount[poolId];
                }
                uint256 outputAmount = inputAmount / 2;
                if (params.zeroForOne) {
                    poolDelta = toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)));
                } else {
                    poolDelta = toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                }
            } else {
                uint256 outputAmount = uint256(amountToSwap);
                uint256 configuredOutputAmount = nextExactOutputAmount[poolId];
                if (configuredOutputAmount != 0) {
                    outputAmount = configuredOutputAmount;
                    delete nextExactOutputAmount[poolId];
                }
                uint256 inputAmount = outputAmount * 2;
                if (params.zeroForOne) {
                    poolDelta = toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)));
                } else {
                    poolDelta = toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                }
            }
        }

        uint160 nextSqrtPriceX96 = nextSwapSqrtPriceX96[poolId];
        if (nextSqrtPriceX96 != 0) {
            slot0State[poolId].sqrtPriceX96 = nextSqrtPriceX96;
            _syncPoolStorage(poolId);
            delete nextSwapSqrtPriceX96[poolId];
        }

        int128 afterSwapUnspecifiedDelta;
        if (callSwapHooks) {
            (, afterSwapUnspecifiedDelta) = key.hooks.afterSwap(msg.sender, key, params, poolDelta, hookData);
        }

        int128 hookDeltaSpecified = beforeSwapDelta.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapDelta.getUnspecifiedDelta() + afterSwapUnspecifiedDelta;
        if (hookDeltaSpecified != 0 || hookDeltaUnspecified != 0) {
            BalanceDelta hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
            delta = poolDelta - hookDelta;
        } else {
            delta = poolDelta;
        }
    }

    /// @notice Transfers a mocked currency out of the manager.
    /// @dev Supports both native and ERC20 payouts for router settlement tests.
    /// @param currency Currency to transfer.
    /// @param to Recipient of the transfer.
    /// @param amount Amount to transfer.
    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool success,) = to.call{value: amount}("");
            require(success, "native take");
        } else {
            require(MockERC20(Currency.unwrap(currency)).transfer(to, amount), "erc20 take");
        }
    }

    /// @notice No-op sync hook for the mock manager.
    /// @dev Present only to satisfy the router integration surface.
    /// @param currency Unused currency argument required by the interface.
    function sync(Currency currency) external pure {
        currency;
    }

    /// @notice Accepts native settlement in the mock manager.
    /// @dev Returns the attached value to mimic manager settlement accounting.
    /// @return Amount of native value received.
    function settle() external payable returns (uint256) {
        return msg.value;
    }

    /// @notice Reads a mocked external storage slot.
    /// @dev Used by the hook to inspect pool manager state.
    /// @param slot Storage slot to read.
    /// @return Mocked slot value.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return extStorage[slot];
    }

    /// @notice Returns the mocked slot0 tuple for a pool.
    /// @dev Exposes the harness state to tests.
    /// @param poolId Pool id whose slot0 is requested.
    /// @return sqrtPriceX96 Mock square-root price.
    /// @return tick Mock current tick.
    /// @return protocolFee Mock protocol fee.
    /// @return lpFee Mock LP fee.
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        Slot0State memory state = slot0State[poolId];
        return (state.sqrtPriceX96, state.tick, state.protocolFee, state.lpFee);
    }

    /// @notice Returns the mocked active liquidity for a pool.
    /// @dev Exposes the harness state to tests.
    /// @param poolId Pool id whose liquidity is requested.
    /// @return liquidity Mock active liquidity.
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return liquidityState[poolId];
    }

    /// @notice Overrides the mocked active liquidity for a pool.
    /// @dev Used by router regression tests that need an initialized pool with zero active liquidity.
    /// @param poolId Pool id whose liquidity should be updated.
    /// @param liquidity New mocked active liquidity.
    function setLiquidity(PoolId poolId, uint128 liquidity) external {
        liquidityState[poolId] = liquidity;
        _syncPoolStorage(poolId);
    }

    /// @notice Configures the next post-swap price written into slot0 for a pool.
    /// @dev Used by settlement regression tests to simulate realized price movement.
    /// @param poolId Pool whose next swap should update price.
    /// @param sqrtPriceX96 Price to write after the next swap.
    function setNextSwapSqrtPriceX96(PoolId poolId, uint160 sqrtPriceX96) external {
        nextSwapSqrtPriceX96[poolId] = sqrtPriceX96;
    }

    function setNextExactInputPoolInputAmount(PoolId poolId, uint256 inputAmount) external {
        nextExactInputPoolInputAmount[poolId] = inputAmount;
    }

    function setNextExactOutputAmount(PoolId poolId, uint256 outputAmount) external {
        nextExactOutputAmount[poolId] = outputAmount;
    }

    function lastUnlockPayer() external view returns (address payer) {
        return lastUnlockCallbackPayer;
    }

    function _syncPoolStorage(PoolId poolId) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        Slot0State memory state = slot0State[poolId];
        extStorage[stateSlot] = bytes32(uint256(state.sqrtPriceX96));
        extStorage[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidityState[poolId]));
    }

    receive() external payable {}
}
