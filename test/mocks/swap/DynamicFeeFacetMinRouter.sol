// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IDynamicFeeFacet} from "../../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseHookStorage} from "../../../src/swap/interfaces/IMemeverseHookStorage.sol";

/// @title DynamicFeeFacetMinRouter
/// @notice Test-only mini-Router that drives `DynamicFeeFacet` external entries via `delegatecall` so the
///         facet's storage-writing logic runs in this contract's storage namespace.
/// @dev The facet uses `layout at erc7201("outrun.storage.MemeverseUniswapHook")` for its
///      `_memeverseUniswapHookStorage` anchor. Solidity Error 8894 forbids a second `layout at` declaration
///      on a contract that already inherits one (inheriting `DynamicFeeFacet` directly would re-declare the
///      same namespace). To stay ERC-7201-compatible without triggering 8894, this Router:
///        - inherits only the `IMemeverseHookStorage` interface (no custom layout, legal to inherit);
///        - re-declares `layout at erc7201("outrun.storage.MemeverseUniswapHook")` on itself so its own
///          `_memeverseUniswapHookStorage` state variable lands at the SAME slot the facet computes; and
///        - forwards each external entry through `delegatecall` so the facet code reads/writes the Router's
///          storage.
///      The facet's `onlyViaRouter` guard uses an immutable self-address (`__self`): under `delegatecall`
///      the facet observes `address(this)` == this Router (≠ `__self`, the facet's own address), so the guard
///      passes with no storage seeding. Tests never call the facet code directly.
contract DynamicFeeFacetMinRouter layout at erc7201("outrun.storage.MemeverseUniswapHook") is IMemeverseHookStorage {
    /// @notice Facet implementation forwarded to by every external entry. Typed as the interface so tests
    ///         can inject a replacement (e.g. `RevertingDynamicFeeFacetMock`) to exercise sad-path revert
    ///         bubbling; happy-path callers pass a `new DynamicFeeFacet(...)`.
    IDynamicFeeFacet public immutable facet;

    /// @dev Storage anchor bound to the shared ERC-7201 namespace declared on this contract. Inheriting
    ///      `IMemeverseHookStorage` only exposes the struct type (interfaces cannot carry state variables),
    ///      so the anchor must be declared here, mirroring `FacetGuard`.
    MemeverseUniswapHookStorage internal _memeverseUniswapHookStorage;

    /// @param facet_ Facet implementation to forward every external entry to. Happy-path tests pass a
    ///               `new DynamicFeeFacet(poolManager)`; sad-path tests pass a `RevertingDynamicFeeFacetMock`.
    constructor(IDynamicFeeFacet facet_) {
        facet = facet_;
    }

    // -----------------------------------------------------------------
    // External entry forwarders (mirror IDynamicFeeFacet surface)
    // -----------------------------------------------------------------
    // All three forwarders must use OZ `Address.functionDelegateCall` so custom errors bubble raw
    // (same contract as production `MemeverseSwapFeeBase`). Do not hand-roll delegatecall failure handling.
    // Covered by `DynamicFeeFacetMinRouterRevertTest`.

    /// @notice Forwards `IDynamicFeeFacet.prepareSwapFee` into the facet via delegatecall.
    /// @dev Hot path returns only the two settlement fields used by SwapFacet.
    function prepareSwapFee(IDynamicFeeFacet.PrepareSwapFeeParams calldata params)
        external
        returns (uint256 feeBps, uint256 estimatedGrossOutputAmount)
    {
        bytes memory ret = Address.functionDelegateCall(
            address(facet), abi.encodeCall(IDynamicFeeFacet.prepareSwapFee, (params))
        );
        return abi.decode(ret, (uint256, uint256));
    }

    /// @notice Forwards `IDynamicFeeFacet.updateAfterSwap` into the facet via delegatecall.
    function updateAfterSwap(IDynamicFeeFacet.UpdateAfterSwapParams calldata params) external {
        Address.functionDelegateCall(address(facet), abi.encodeCall(IDynamicFeeFacet.updateAfterSwap, (params)));
    }

    /// @notice Forwards `IDynamicFeeFacet.quote` into the facet via delegatecall.
    /// @dev Non-view wrapper: delegatecall is treated as state-changing by the compiler even when the target
    ///      is a view function, so this cannot be marked `view`.
    function quote(IDynamicFeeFacet.PrepareSwapFeeParams calldata context)
        external
        returns (IDynamicFeeFacet.PreparedSwapFee memory quote)
    {
        bytes memory ret =
            Address.functionDelegateCall(address(facet), abi.encodeCall(IDynamicFeeFacet.quote, (context)));
        return abi.decode(ret, (IDynamicFeeFacet.PreparedSwapFee));
    }

    // -----------------------------------------------------------------
    // Seed / read helpers (direct storage access, no delegatecall)
    // -----------------------------------------------------------------
    // `readDynamicFeeState` reads this Router's `dynamicFeeState[poolId]` storage slot directly, mirroring
    // the production Router's view-direct read path (no facet delegatecall). Tests use `readDynamicFeeState`.

    /// @notice Seeds the per-pool dynamic fee state directly in this Router's storage.
    function seedDynamicFeeState(PoolId poolId, IDynamicFeeFacet.DynamicFeeState memory state) external {
        _memeverseUniswapHookStorage.dynamicFeeState[poolId] = state;
    }

    /// @notice Reads the per-pool dynamic fee state directly from this Router's storage.
    function readDynamicFeeState(PoolId poolId) external view returns (IDynamicFeeFacet.DynamicFeeState memory state) {
        return _memeverseUniswapHookStorage.dynamicFeeState[poolId];
    }

    /// @notice Seeds the per-trader/per-pool batch state directly in this Router's storage.
    function seedAddressBatchState(address trader, PoolId poolId, IDynamicFeeFacet.AddressBatchState memory state)
        external
    {
        _memeverseUniswapHookStorage.addressBatchState[trader][poolId] = state;
    }

    /// @notice Reads the per-trader/per-pool batch state directly from this Router's storage.
    function readAddressBatchState(address trader, PoolId poolId)
        external
        view
        returns (IDynamicFeeFacet.AddressBatchState memory state)
    {
        return _memeverseUniswapHookStorage.addressBatchState[trader][poolId];
    }

    /// @notice Seeds the default launch-fee schedule used by facet self-reads.
    function seedDefaultLaunchFeeConfig(IDynamicFeeFacet.LaunchFeeConfig memory config) external {
        _memeverseUniswapHookStorage.defaultLaunchFeeConfig = config;
    }
}
