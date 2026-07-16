// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title ISwapFacet
/// @notice Diamond facet surface for the Memeverse swap hook callback logic.
/// @dev The Router (`MemeverseUniswapHook`) forwards each v4 hook callback into the matching `*Logic`
///      function on the selected facet via `_forwardCalldata` (selector swap only — it reuses the outer v4
///      callback calldata verbatim, no `abi.encodeCall` re-encoding). Because the facet executes in the
///      Router's storage context via delegatecall, the parameter list mirrors the v4 `IHooks` callback
///      signature exactly (same order and types), including the leading `address sender`. Signature
///      stability here is load-bearing: any drift in the `*Logic` parameter layout breaks the forwarded-
///      calldata mirror and silently disables the corresponding hook callback.
interface ISwapFacet {
    /// @notice Logic entry for the v4 `beforeSwap` hook callback.
    /// @dev Computes the dynamic fee, collects any exact-input input-side fees, and stores swap context for
    ///      `afterSwapLogic`. Return shape matches `IHooks.beforeSwap`.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key of the swap.
    /// @param params Uniswap v4 swap parameters.
    /// @param hookData Opaque hook data forwarded by PoolManager; the first 20 bytes optionally encode a referrer.
    /// @return selector The `beforeSwap` selector expected by PoolManager.
    /// @return delta Hook delta used to reserve input/output-side fees.
    /// @return lpFeeBps LP fee basis points reported to PoolManager for this swap.
    function beforeSwapLogic(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeBps);

    /// @notice Logic entry for the v4 `afterSwap` hook callback.
    /// @dev Updates ewVWAP, reference-price volatility state, short-term impact state, and optionally takes
    ///      protocol fees. Return shape matches `IHooks.afterSwap`.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key of the swap.
    /// @param params Uniswap v4 swap parameters.
    /// @param delta Pool balance delta from the swap.
    /// @param hookData Extra hook data forwarded by PoolManager.
    /// @return selector The `afterSwap` selector expected by PoolManager.
    /// @return unspecifiedDelta Hook delta used to settle output-side or exact-output fees.
    function afterSwapLogic(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 unspecifiedDelta);

    /// @notice Logic entry for the v4 `beforeInitialize` hook callback.
    /// @dev Validates pool settings (tick spacing, dynamic fee, pre-authorization) and deploys the
    ///      pool-specific LP token. Return shape matches `IHooks.beforeInitialize`.
    /// @param sender Original caller forwarded by PoolManager (must be the authorized pool initializer).
    /// @param key Pool key being initialized.
    /// @param sqrtPriceX96 Initial pool price.
    /// @return selector The `beforeInitialize` selector expected by PoolManager.
    function beforeInitializeLogic(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (bytes4 selector);

    /// @notice Logic entry for the v4 `beforeAddLiquidity` hook callback.
    /// @dev Restricts add-liquidity modifications to calls originating from this hook itself.
    ///      Return shape matches `IHooks.beforeAddLiquidity`.
    /// @param sender Original caller forwarded by PoolManager.
    /// @param key Pool key of the liquidity modification.
    /// @param params Uniswap v4 modify-liquidity parameters.
    /// @param hookData Extra hook data forwarded by PoolManager.
    /// @return selector The `beforeAddLiquidity` selector expected by PoolManager.
    function beforeAddLiquidityLogic(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4 selector);

    /// @notice Logic entry for LP per-share fee snapshot synchronization.
    /// @dev The Router's liquidity entries (`addLiquidityCore` / `removeLiquidityCore` / `claimFeesCore`)
    ///      and the external `updateUserSnapshot` selector (called by the LP token on transfer) all
    ///      delegatecall into this wrapper, which runs the shared per-share accounting in the Router's
    ///      storage context. A direct CALL still trips `onlyViaRouter`.
    /// @param id The hook-managed pool id.
    /// @param user The user whose fee snapshot is synchronized.
    function updateUserSnapshotLogic(PoolId id, address user) external;
}
