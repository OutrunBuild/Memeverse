// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IDynamicFeeFacet} from "./IDynamicFeeFacet.sol";

/**
 * @title IMemeverseHookStorage
 * @notice Single source of truth for the Memeverse Uniswap v4 hook ERC-7201 storage structs.
 * @dev The hook Router (`MemeverseUniswapHookUpgradeable`) and its delegatecall facets
 *      (`SwapFacet`, `DynamicFeeFacet`, `SettlementFacet`) all bind the same
 *      `MemeverseUniswapHookStorage` struct to the same ERC-7201 namespace base via
 *      `layout at erc7201("outrun.storage.MemeverseUniswapHook")`. Solidity derives each
 *      storage slot from (namespace base, struct field declaration order), so any field
 *      drift between the four declarations would silently re-slot every mapping and lose
 *      realized swap state, rebate balances, and LP per-share accounting.
 *
 *      This interface provides the canonical struct declaration to each host contract. Interface
 *      inheritance propagates member visibility, so `MemeverseUniswapHookStorage` / `PoolInfo` /
 *      `UserFeeState` / `PoolInitializationAuth` are referenced without an interface prefix.
 *
 *      Field order is FROZEN — see the `MemeverseUniswapHookStorage` struct below for the
 *      slot-derivation rationale and the append-only rule.
 *
 *      Nested value types (`LaunchFeeConfig`, `DynamicFeeState`, `AddressBatchState`) are
 *      members of `IDynamicFeeFacet`, so they are referenced via that interface rather
 *      than redeclared here.
 *
 * @custom:storage-location erc7201:outrun.storage.MemeverseUniswapHook
 */
interface IMemeverseHookStorage {
    /// @notice Pool information tracked by the hook.
    struct PoolInfo {
        /// @notice Custom ERC20 LP token address for this pool.
        address liquidityToken;
        /// @notice Accumulated LP fees for currency0 (per share, scaled by Q128 in the implementation).
        uint256 fee0PerShare;
        /// @notice Accumulated LP fees for currency1 (per share, scaled by Q128 in the implementation).
        uint256 fee1PerShare;
    }

    /// @notice Per-user fee accounting state for a pool.
    struct UserFeeState {
        /// @notice Snapshot offset of `fee0PerShare` at the last user update, in Q128 per-share units.
        uint256 fee0Offset;
        /// @notice Snapshot offset of `fee1PerShare` at the last user update, in Q128 per-share units.
        uint256 fee1Offset;
        /// @notice Earned but unclaimed currency0 fees.
        uint256 pendingFee0;
        /// @notice Earned but unclaimed currency1 fees.
        uint256 pendingFee1;
    }

    /// @notice One-time pool initialization authorization written by
    ///         `authorizePoolInitialization` and consumed by `swapFacet.beforeInitializeLogic`.
    struct PoolInitializationAuth {
        uint160 startPriceX96;
        bool active;
    }

    /// @notice Storage layout for the MemeverseUniswapHookUpgradeable ERC-7201 namespace.
    /// @dev Field order is FROZEN. Solidity derives each storage slot from (namespace base, struct
    ///      field declaration order), so any reorder / rename / retype / insert would silently re-slot
    ///      every mapping and lose realized swap state, rebate balances, and LP per-share accounting.
    ///      Only append at the end, and append in lockstep with any downstream storage-layout consumers.
    struct MemeverseUniswapHookStorage {
        address treasury;
        address launcher;
        mapping(address => bool) supportedProtocolFeeCurrencies;
        mapping(PoolId => PoolInfo) poolInfo;
        mapping(PoolId => uint256) cachedLpTotalSupply;
        mapping(PoolId => uint40) poolLaunchTimestamp;
        mapping(PoolId => uint40) publicSwapResumeTime;
        mapping(PoolId => mapping(address => UserFeeState)) userFeeState;
        IDynamicFeeFacet.LaunchFeeConfig defaultLaunchFeeConfig;
        address poolInitializer;
        mapping(PoolId => PoolInitializationAuth) poolInitializationAuth;
        address lpTokenImplementation;
        // === Dynamic fee state ===
        mapping(PoolId => IDynamicFeeFacet.DynamicFeeState) dynamicFeeState;
        // Written by DynamicFeeFacet.updateAfterSwap; read by prepareSwapFee/quote (facet) and by the
        // Router via `dynamicFeeStateOf` (direct view, NOT delegatecall). The sibling `addressBatchState`
        // below is read the same way via `addressBatchStateOf`. A namespace relocation MUST update BOTH
        // Router getters in lockstep — a direct read does not auto-follow a storage move.
        mapping(address trader => mapping(PoolId => IDynamicFeeFacet.AddressBatchState)) addressBatchState;
        // === Referral rebate state ===
        uint24 referrerRebateBps;
        mapping(address => mapping(Currency => uint256)) pendingRebate;
        // === Facet pointers ===
        address swapFacet;
        address dynamicFeeFacet;
        address settlementFacet;
    }
}
