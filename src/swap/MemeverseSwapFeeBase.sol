// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {FacetGuard} from "./FacetGuard.sol";
import {IDynamicFeeFacet} from "./interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {SwapFeeMath} from "./libraries/SwapFeeMath.sol";

/// @title MemeverseSwapFeeBase
/// @notice Shared fee-accounting base for SwapFacet and SettlementFacet, including their
///         facet-to-facet DynamicFeeFacet delegatecall wrappers.
/// @dev Inherited helpers are `internal` and inlined into each facet; under Router `delegatecall`
///      they execute in the hook proxy storage context (`address(this) == hook`). Every read/write
///      targets the shared ERC-7201 hook namespace through the `FacetGuard` storage anchor. Field
///      order is frozen and append-only; see `IMemeverseHookStorage.MemeverseUniswapHookStorage`.
abstract contract MemeverseSwapFeeBase is FacetGuard {
    // --- shared fee-accounting helpers inherited by SwapFacet & SettlementFacet ---
    // `CurrencyNotSupported` lives in `SwapFeeMath` (shared with Lens); same 4-byte selector.
    // `CurrencyLibrary` members used elsewhere (e.g. `Currency.isAddressZero`) reach this contract via
    // the global `using CurrencyLibrary for Currency global;` in v4-core; no file-level `using` needed here.

    /// @dev Credits LP fee into the per-share accumulator (bookkeeping only). Does NOT transfer tokens —
    ///      callers must handle token collection separately (via `poolManager.take` for public swaps, or
    ///      direct `transferFrom` for settlement). Use `_collectLpFee` when the full take+accrue lifecycle is needed.
    ///      Reverts with `NoActiveLiquidityShares` if `effectiveSupply == 0` to prevent a FullMath.mulDiv
    ///      divide-by-zero (Panic 0x12). All current callers gate this themselves; the guard is a defense-
    ///      in-depth backstop for any future direct caller that forgets the gate.
    function _accrueLpFee(
        PoolId poolId,
        Currency feeCurrency,
        bool feeCurrencyIsCurrency0,
        uint256 lpFeeAmount,
        uint256 effectiveSupply
    ) internal {
        // Single source of truth: per-share accrual requires effectiveSupply > 0. Callers that skip LP fee
        // on drained pools (_collectLpFee, the SwapFacet beforeSwap merge path, SettlementFacet) gate
        // effectiveSupply == 0 themselves for the take decision; this guard prevents Panic 0x12 (FullMath
        // mulDiv divide-by-zero) if a future direct caller forgets the gate.
        if (effectiveSupply == 0) revert IMemeverseUniswapHook.NoActiveLiquidityShares();
        PoolInfo storage pool = _memeverseUniswapHookStorage.poolInfo[poolId];
        uint256 feePerShareDelta = FullMath.mulDiv(lpFeeAmount, FeeMath.FEE_GROWTH_Q128, effectiveSupply);
        if (feeCurrencyIsCurrency0) {
            uint256 newFee0PerShare = pool.fee0PerShare + feePerShareDelta;
            pool.fee0PerShare = newFee0PerShare;
            emit IMemeverseUniswapHook.LPFeeCollected(poolId, feeCurrency, lpFeeAmount, newFee0PerShare, block.number);
        } else {
            uint256 newFee1PerShare = pool.fee1PerShare + feePerShareDelta;
            pool.fee1PerShare = newFee1PerShare;
            emit IMemeverseUniswapHook.LPFeeCollected(poolId, feeCurrency, lpFeeAmount, newFee1PerShare, block.number);
        }
    }

    // -----------------------------------------------------------------
    // Facet-to-facet internal delegatecall to DynamicFeeFacet
    // -----------------------------------------------------------------
    // These wrappers are the ONLY seam between the inheriting facet (SwapFacet/SettlementFacet)
    // and DynamicFeeFacet. They encode the call via `abi.encodeCall(IDynamicFeeFacet.<func>, (...))`
    // and `delegatecall` into the Router-configured `dynamicFeeFacet` address. Because both facets
    // share the hook ERC7201 namespace via `layout at`, the delegated execution runs in the hook
    // proxy storage context (`address(this) == hook`), so all state reads/writes land in the shared
    // hook storage. This is facet-to-facet collaboration via delegatecall — NOT an external CALL
    // (which would lose the storage context and re-key state).

    /// @dev Realized-state update via internal delegatecall to DynamicFeeFacet. Reverts propagate.
    function _updateAfterSwap(IDynamicFeeFacet.UpdateAfterSwapParams memory params) internal {
        _delegatecallDynamicFeeFacet(abi.encodeCall(IDynamicFeeFacet.updateAfterSwap, (params)));
    }

    /// @dev Performs the delegatecall into the Router-configured `dynamicFeeFacet` and bubbles up revert,
    ///      via OZ `Address.functionDelegateCall` (also reverts `AddressEmptyCode` if the facet has no code).
    ///      The facet address is read fresh from shared hook storage each call so an owner `setFacet`
    ///      swap takes effect immediately without redeployment. The target is an owner-controlled facet
    ///      (`setFacet` under `onlyOwner` + `_requireFacetPoolManager`), so the controlled-delegatecall
    ///      detector here is an EIP-2535 diamond inherent rather than an exploitable low-level call.
    ///
    ///      The facet address is read from shared hook storage at each call boundary. An owner `setFacet`
    ///      update therefore takes effect for the next transaction without redeploying the calling facets.
    // slither-disable-next-line controlled-delegatecall
    function _delegatecallDynamicFeeFacet(bytes memory payload) internal returns (bytes memory ret) {
        return Address.functionDelegateCall(_memeverseUniswapHookStorage.dynamicFeeFacet, payload);
    }

    function _isProtocolFeeCurrencySupported(Currency currency) internal view returns (bool) {
        return _memeverseUniswapHookStorage.supportedProtocolFeeCurrencies[Currency.unwrap(currency)];
    }

    function _resolveSwapFeeContext(PoolKey calldata key, bool zeroForOne)
        internal
        view
        returns (SwapFeeMath.SwapFeeContext memory ctx)
    {
        (ctx.currencyIn, ctx.currencyOut) = SwapFeeMath.swapCurrencies(key, zeroForOne);
        // `||` short-circuits: skip the output-side storage read when input is the fee leg.
        ctx.protocolFeeOnInput = _isProtocolFeeCurrencySupported(ctx.currencyIn)
            || SwapFeeMath.protocolFeeOnInputOrRevert(_isProtocolFeeCurrencySupported(ctx.currencyOut));
        ctx.inputIsCurrency0 = zeroForOne;
    }

    /// @dev Single source of truth for the exact-input LP + protocol fee split. Both facets and
    ///      the partial-fill guard route through this helper so the charge and the guard use the
    ///      identical formula.
    function _exactInputFeeAmounts(
        uint256 grossAmount,
        uint256 lpFeeBps,
        uint256 protocolFeeBps,
        bool protocolFeeOnInput
    ) internal pure returns (uint256 lpFeeInputAmount, uint256 protocolFeeInputAmount) {
        lpFeeInputAmount = FeeMath.feeOnAmount(grossAmount, lpFeeBps);
        protocolFeeInputAmount = protocolFeeOnInput ? FeeMath.feeOnAmount(grossAmount, protocolFeeBps) : 0;
    }
}
