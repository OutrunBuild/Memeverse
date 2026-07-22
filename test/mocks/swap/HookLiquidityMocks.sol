// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LiquidityAmounts} from "../../../src/swap/libraries/LiquidityAmounts.sol";
import {ISettlementFacet} from "../../../src/swap/interfaces/ISettlementFacet.sol";

/// @dev Mock-harness boundary:
/// - This file's local hook-liquidity manager mock only covers plumbing, local revert surface,
///   deterministic branch coverage, and rollback witnesses inside the hook-local harness.
/// - The newer integration tests only cover a narrow direct-manager exact-input subset under a stricter manager
///   harness. One-for-zero symmetry beyond that subset, launch-settlement swap semantics, and broader fee-side
///   execution claims are not proven by this file and must not be inferred from this mock manager.
contract MockPoolManagerForHookLiquidity {
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
    address internal hookAddress;
    address internal lastTakeRecipient;
    /// @dev One-shot: next unlock return inflates SettlementResult.protocolFeeOutputAmount by 1 wei.
    bool internal inflateSettlementProtocolFeeByOne;

    mapping(bytes32 => bytes32) internal extStorage;
    mapping(PoolId => Slot0State) internal slot0State;
    mapping(PoolId => uint128) internal liquidityState;
    mapping(PoolId => uint256) internal nextExactInputPoolInputAmount;

    /// @notice Initializes a mock pool and notifies the hook.
    /// @dev Seeds slot0 and liquidity-related storage so the hook sees the pool as configured.
    /// @param key Pool key being initialized.
    /// @param sqrtPriceX96 Initial sqrt price for the pool.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        PoolId poolId = key.toId();
        slot0State[poolId] = Slot0State({sqrtPriceX96: sqrtPriceX96, tick: 0, protocolFee: 0, lpFee: 0});
        _syncPoolStorage(poolId);
        hookAddress = address(key.hooks);
        key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
    }

    /// @notice Opens a temporary unlock window and forwards the callback payload.
    /// @dev Mimics the pool-manager unlock pattern expected by router and hook tests.
    ///      When armed, mutates only `SettlementResult.protocolFeeOutputAmount` after the real
    ///      unlockCallback so production `PreorderSettlementFeeMismatch` can be exercised without
    ///      replacing SettlementFacet.
    /// @param data Encoded callback payload.
    /// @return result Callback return data.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;

        if (inflateSettlementProtocolFeeByOne) {
            inflateSettlementProtocolFeeByOne = false;
            ISettlementFacet.SettlementResult memory settlementResult =
                abi.decode(result, (ISettlementFacet.SettlementResult));
            settlementResult.protocolFeeOutputAmount += 1;
            result = abi.encode(settlementResult);
        }
    }

    function swapAsUnlocked(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        unlocked = true;
        delta = this.swap(key, params, hookData);
        unlocked = false;
    }

    /// @notice Applies a mocked liquidity modification for the pool.
    /// @dev Returns deterministic deltas while enforcing the unlock-window guard used by the hook.
    /// @param key Pool key being modified.
    /// @param params Liquidity change parameters.
    /// @param hookData Hook payload forwarded by the caller.
    /// @return delta Principal token delta for the modification.
    /// @return feesAccrued Fee delta, left empty in this mock.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        hookData;
        if (!unlocked) revert ManagerLocked();
        uint256 amount0Used;
        uint256 amount1Used;

        if (params.liquidityDelta > 0) {
            // Real v4 skips beforeModifyLiquidity/afterModifyLiquidity when msg.sender == address(key.hooks)
            // (Hooks.sol noSelfCall guard). Production addLiquidityCore/removeLiquidityCore route through
            // poolManager.unlock() reentry (MemeverseUniswapHook.sol:647), so msg.sender here IS the hook;
            // the beforeAddLiquidity callback must be skipped to match v4, otherwise the mock double-fires
            // the hook's beforeAddLiquidityLogic on every LP add/remove.
            if (msg.sender != address(key.hooks)) {
                key.hooks.beforeAddLiquidity(msg.sender, key, params, ZERO_BYTES);
            }

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

    /// @notice Executes a mocked swap during hook-controlled unlock callbacks.
    /// @dev Produces deterministic hook-local branch coverage only; it does not model real swap economics.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        if (!unlocked) revert ManagerLocked();

        bool callSwapHooks = msg.sender != address(key.hooks);
        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (callSwapHooks) {
            (, beforeSwapDelta,) = key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }
        int256 amountToSwap = params.amountSpecified + beforeSwapDelta.getSpecifiedDelta();

        if (amountToSwap < 0) {
            uint256 exactInputAmount = uint256(-amountToSwap);
            uint256 configuredInputAmount = nextExactInputPoolInputAmount[key.toId()];
            if (configuredInputAmount != 0) {
                exactInputAmount = configuredInputAmount;
                delete nextExactInputPoolInputAmount[key.toId()];
            }
            uint256 exactOutputAmount = exactInputAmount / 2;
            if (params.zeroForOne) {
                delta = toBalanceDelta(-int128(int256(exactInputAmount)), int128(int256(exactOutputAmount)));
            } else {
                delta = toBalanceDelta(int128(int256(exactOutputAmount)), -int128(int256(exactInputAmount)));
            }
        } else {
            uint256 requestedOutputAmount = uint256(amountToSwap);
            uint256 requiredInputAmount = requestedOutputAmount * 2;
            if (params.zeroForOne) {
                delta = toBalanceDelta(-int128(int256(requiredInputAmount)), int128(int256(requestedOutputAmount)));
            } else {
                delta = toBalanceDelta(int128(int256(requestedOutputAmount)), -int128(int256(requiredInputAmount)));
            }
        }

        if (callSwapHooks) key.hooks.afterSwap(msg.sender, key, params, delta, hookData);
    }

    /// @notice Pays tokens or native currency out of the mock manager.
    /// @dev Records the recipient so tests can assert router settlement targets.
    /// @param currency Currency being paid out.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function take(Currency currency, address to, uint256 amount) external {
        lastTakeRecipient = to;
        if (currency.isAddressZero()) {
            (bool success,) = to.call{value: amount}("");
            require(success, "native take");
        } else {
            require(MockERC20(Currency.unwrap(currency)).transfer(to, amount), "erc20 take");
        }
    }

    /// @notice Accepts a sync call from the hook test harness.
    /// @dev This mock treats sync as a no-op while preserving interface compatibility.
    /// @param currency Currency being synced.
    function sync(Currency currency) external pure {
        currency;
    }

    /// @notice Accepts settlement value from the router or hook.
    /// @dev Mirrors the real pool-manager settle entry so ETH bookkeeping can be validated.
    /// @return paidAmount Amount considered settled by the mock.
    function settle() external payable returns (uint256) {
        return msg.value;
    }

    /// @notice Returns extsload.
    /// @dev Exposes the mock storage slot values used by the hook.
    /// @param slot slot.
    /// @return Returned value.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return extStorage[slot];
    }

    /// @notice Returns get slot0.
    /// @dev Lets tests observe price and fee state returned by the mock manager.
    /// @param poolId pool id.
    /// @return Returned value.
    /// @return Returned value.
    /// @return Returned value.
    /// @return Returned value.
    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0State memory state = slot0State[poolId];
        return (state.sqrtPriceX96, state.tick, state.protocolFee, state.lpFee);
    }

    /// @notice Returns get liquidity.
    /// @dev Allows tests to assert pool liquidity matches the hook view.
    /// @param poolId pool id.
    /// @return Returned value.
    function getLiquidity(PoolId poolId) external view returns (uint128) {
        return liquidityState[poolId];
    }

    function setNextExactInputPoolInputAmount(PoolId poolId, uint256 inputAmount) external {
        nextExactInputPoolInputAmount[poolId] = inputAmount;
    }

    /// @notice Next `unlock` return will inflate SettlementResult.protocolFeeOutputAmount by 1 wei.
    /// @dev One-shot. Used to exercise production `PreorderSettlementFeeMismatch` without replacing SettlementFacet.
    function setInflateSettlementProtocolFeeByOne() external {
        inflateSettlementProtocolFeeByOne = true;
    }

    /// @notice Returns last take recipient address.
    /// @dev Observes which recipient the hook forwarded liquidity outputs to.
    /// @return Returned value.
    function lastTakeRecipientAddress() external view returns (address) {
        return lastTakeRecipient;
    }

    function _syncPoolStorage(PoolId poolId) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        Slot0State memory state = slot0State[poolId];

        extStorage[stateSlot] = bytes32(uint256(state.sqrtPriceX96));
        extStorage[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidityState[poolId]));
    }
}
