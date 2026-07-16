// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseHookStorage} from "./interfaces/IMemeverseHookStorage.sol";

/// @title FacetGuard
/// @notice Shared Router-call guard and hook storage anchor for the diamond facets.
/// @dev The storage anchor is `internal` (not `private`) so inheriting facets can read/write — safe because
///      facets are plain non-proxy contracts that execute through Router delegatecall in the hook's trust
///      domain. Every read/write targets `_memeverseUniswapHookStorage` in the shared hook namespace. The
///      slot is derived from each facet's `layout at erc7201("outrun.storage.MemeverseUniswapHook")` and the
///      frozen struct field order in `IMemeverseHookStorage`. Field order FROZEN (append-only); see
///      `IMemeverseHookStorage.MemeverseUniswapHookStorage` for the slot-derivation rationale.
///      Inheritors MUST declare `layout at erc7201("outrun.storage.MemeverseUniswapHook")` — without it
///      the anchor lands at slot 0 of the inheritor's own namespace, colliding with its native state.
abstract contract FacetGuard is IMemeverseHookStorage {
    MemeverseUniswapHookStorage internal _memeverseUniswapHookStorage;

    /// @dev Facet's own address, baked into bytecode at construction (immutable → no SLOAD). Used by
    ///      `onlyViaRouter` to distinguish a Router `delegatecall` (where `address(this)` is the hook
    ///      proxy) from a direct CALL (where `address(this)` is the facet itself).
    address private immutable __self = address(this);

    /// @notice Reverts when a required address parameter is the zero address.
    /// @dev Selector (`keccak256("ZeroAddress()")`) depends only on name + args, not declaration site.
    error ZeroAddress();

    /// @notice Reverts when a facet logic function is called directly instead of via the Router delegatecall.
    /// @dev Under direct CALL, `address(this)` is the facet's own address, which equals `__self`.
    error DirectFacetCallForbidden();

    /// @notice Reverts unless the call is reaching this facet through the Router's delegatecall.
    /// @dev Under `delegatecall`, `address(this)` is the hook proxy (≠ `__self`, the facet's own address),
    ///      so the guard passes. Under a direct CALL, `address(this)` is the facet itself (== `__self`),
    ///      so the guard trips. This self-compare is the OpenZeppelin `Initializable._checkProxy` pattern:
    ///      it needs no storage read and does not bind the facet to a single hook proxy address.
    modifier onlyViaRouter() {
        if (address(this) == __self) revert DirectFacetCallForbidden();
        _;
    }
}
