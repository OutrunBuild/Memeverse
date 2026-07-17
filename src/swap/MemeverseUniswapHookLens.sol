// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FeeMath} from "./libraries/FeeMath.sol";
import {SwapFeeMath} from "./libraries/SwapFeeMath.sol";
import {SwapGuardMath} from "./libraries/SwapGuardMath.sol";
import {UniswapLP} from "./tokens/UniswapLP.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseUniswapHookLens} from "./interfaces/IMemeverseUniswapHookLens.sol";

/// @title MemeverseUniswapHookLens
/// @notice Stateless read-only calculator for Memeverse hook quote and fee preview APIs.
/// @dev This contract assumes the queried hook and this lens are bound to the same PoolManager.
contract MemeverseUniswapHookLens is IMemeverseUniswapHookLens {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    /// @param manager_ Uniswap v4 PoolManager that owns the pools being quoted.
    constructor(IPoolManager manager_) {
        if (address(manager_) == address(0)) revert IMemeverseUniswapHook.ZeroAddress();
        poolManager = manager_;
    }

    /// @inheritdoc IMemeverseUniswapHookLens
    function quoteSwap(IMemeverseUniswapHook hook, PoolKey calldata key, SwapParams calldata params, address trader)
        external
        view
        returns (IMemeverseUniswapHook.SwapQuote memory quote)
    {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(key.currency0, key.currency1);
        if (address(key.hooks) != address(hook)) revert IMemeverseUniswapHook.HookAddressMismatch();
        PoolId poolId = key.toId();
        // Gate logic lives in SwapGuardMath so the quote path cannot drift from the execution path.
        SwapGuardMath.revertIfPublicSwapBlocked(hook.publicSwapResumeTime(poolId));
        // Read liquidity once and reuse it for both the orphan-liquidity gate and the fee quote,
        // mirroring the execution path (SwapFacet reads getLiquidity once, threads it through).
        uint128 liquidity = poolManager.getLiquidity(poolId);
        _revertIfNoActiveLiquidityShares(hook, poolId, params.amountSpecified, liquidity);

        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        bool protocolFeeOnInput = _protocolFeeOnInput(hook, key, params.zeroForOne);

        // STATICCALL keeps the public quote read-only and its EIP-214 flag propagates through the hook's delegatecall.
        bytes memory feeQuoteData = Address.functionStaticCall(
            address(hook),
            abi.encodeCall(
                IMemeverseUniswapHook.quoteSwapFeeWithContext,
                (poolId, params, trader, preSqrtPriceX96, liquidity, protocolFeeOnInput)
            )
        );
        IDynamicFeeFacet.PreparedSwapFee memory feeQuote = abi.decode(feeQuoteData, (IDynamicFeeFacet.PreparedSwapFee));
        (uint256 lpFeeBps, uint256 protocolFeeBps) = FeeMath.splitFeeBps(feeQuote.feeBps);

        quote.feeBps = feeQuote.feeBps;
        quote.protocolFeeOnInput = protocolFeeOnInput;

        if (params.amountSpecified < 0) {
            uint256 userInputAmount = uint256(-params.amountSpecified);
            quote.estimatedUserInputAmount = userInputAmount;
            quote.estimatedLpFeeAmount = FeeMath.feeOnAmount(userInputAmount, lpFeeBps);
            if (protocolFeeOnInput) {
                quote.estimatedProtocolFeeAmount = FeeMath.feeOnAmount(userInputAmount, protocolFeeBps);
                quote.estimatedUserOutputAmount = feeQuote.estimatedOutputAmount;
            } else {
                quote.estimatedProtocolFeeAmount =
                    FeeMath.feeOnAmount(feeQuote.estimatedGrossOutputAmount, protocolFeeBps);
                quote.estimatedUserOutputAmount = feeQuote.estimatedGrossOutputAmount - quote.estimatedProtocolFeeAmount;
            }
        } else {
            uint256 requestedOutputAmount = uint256(params.amountSpecified);
            // Bounded: a drained pool (liquidity == 0) yields estimatedGrossOutputAmount == 0, so the user
            // receives nothing despite requesting a positive output. Gate on the gross estimate so the
            // quote does not advertise a free positive-sum swap that cannot be filled.
            quote.estimatedUserOutputAmount = feeQuote.estimatedGrossOutputAmount > 0 ? requestedOutputAmount : 0;
            quote.estimatedLpFeeAmount = FeeMath.feeOnAmount(feeQuote.estimatedInputAmount, lpFeeBps);
            if (protocolFeeOnInput) {
                quote.estimatedProtocolFeeAmount = FeeMath.feeOnAmount(feeQuote.estimatedInputAmount, protocolFeeBps);
                quote.estimatedUserInputAmount =
                    feeQuote.estimatedInputAmount + quote.estimatedLpFeeAmount + quote.estimatedProtocolFeeAmount;
            } else {
                // Bounded: drained pools (liquidity == 0) yield estimatedGrossOutputAmount == 0, so
                // subtracting requestedOutputAmount would underflow. Clamp to 0 to keep the quote a
                // pure preview that returns zero instead of panicking on drained pools.
                quote.estimatedProtocolFeeAmount = feeQuote.estimatedGrossOutputAmount > requestedOutputAmount
                    ? feeQuote.estimatedGrossOutputAmount - requestedOutputAmount
                    : 0;
                quote.estimatedUserInputAmount = feeQuote.estimatedInputAmount + quote.estimatedLpFeeAmount;
            }
        }
    }

    /// @inheritdoc IMemeverseUniswapHookLens
    function poolDynamicFeeState(IMemeverseUniswapHook hook, PoolId poolId)
        external
        view
        returns (
            uint256 weightedVolume0,
            uint256 weightedPriceVolume0,
            uint256 ewVWAPX18,
            uint160 volAnchorSqrtPriceX96,
            uint40 volLastMoveTs,
            uint24 volDeviationAccumulator,
            uint24 volCarryAccumulator,
            uint24 shortImpactPpm,
            uint40 shortLastTs
        )
    {
        // `dynamicFeeStateOf` reads the hook-owned per-pool state directly from the hook's ERC7201 storage.
        IDynamicFeeFacet.DynamicFeeState memory state = hook.dynamicFeeStateOf(poolId);
        return (
            state.weightedVolume0,
            state.weightedPriceVolume0,
            state.ewVWAPX18,
            state.volAnchorSqrtPriceX96,
            state.volLastMoveTs,
            state.volDeviationAccumulator,
            state.volCarryAccumulator,
            state.shortImpactPpm,
            state.shortLastTs
        );
    }

    /// @inheritdoc IMemeverseUniswapHookLens
    function claimableFees(IMemeverseUniswapHook hook, PoolKey calldata key, address owner)
        external
        view
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(key.currency0, key.currency1);
        PoolId poolId = key.toId();
        (address liquidityToken, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(poolId);
        if (liquidityToken == address(0) || owner == address(0)) return (0, 0);

        (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1) =
            hook.userFeeState(poolId, owner);
        fee0Amount = pendingFee0;
        fee1Amount = pendingFee1;

        uint256 balance = UniswapLP(liquidityToken).balanceOf(owner);
        if (balance == 0) return (fee0Amount, fee1Amount);

        // Fee growth is Q128-scaled by the hook; round down to avoid over-previewing claimable fees.
        if (fee0PerShare > fee0Offset) {
            fee0Amount += FullMath.mulDiv(balance, fee0PerShare - fee0Offset, FeeMath.FEE_GROWTH_Q128);
        }
        if (fee1PerShare > fee1Offset) {
            fee1Amount += FullMath.mulDiv(balance, fee1PerShare - fee1Offset, FeeMath.FEE_GROWTH_Q128);
        }
    }

    /// @dev Mirrors `MemeverseSwapFeeBase._resolveSwapFeeContext`'s protocol-fee leg resolution
    ///      (`inputSupported || !outputSupported`).
    function _protocolFeeOnInput(IMemeverseUniswapHook hook, PoolKey calldata key, bool zeroForOne)
        internal
        view
        returns (bool)
    {
        (Currency currencyIn, Currency currencyOut) = SwapFeeMath.swapCurrencies(key, zeroForOne);
        // `||` short-circuits: skip the second hook view call when the input is a registered token.
        return hook.supportedProtocolFeeCurrencies(Currency.unwrap(currencyIn))
            || !hook.supportedProtocolFeeCurrencies(Currency.unwrap(currencyOut));
    }

    /// @dev Gate logic lives in SwapGuardMath. `liquidity` is read once by the caller (quoteSwap) and
    ///      reused for both this orphan-liquidity gate and the fee quote. The cached/liquidity branches
    ///      mirror the execution path (SwapFacet._activeLpSupplyForSwap); the `amountSpecified == 0`
    ///      early-return below is quote-path-only — a zero-amount quote is a legitimate no-op, unlike the
    ///      execution path where v4 guarantees amountSpecified is non-zero.
    function _revertIfNoActiveLiquidityShares(
        IMemeverseUniswapHook hook,
        PoolId poolId,
        int256 amountSpecified,
        uint128 liquidity
    ) internal view {
        if (amountSpecified == 0) return;
        if (hook.cachedLpTotalSupply(poolId) != 0) return;
        SwapGuardMath.revertIfNoActiveLiquidityShares(liquidity);
    }
}
