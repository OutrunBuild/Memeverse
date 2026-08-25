// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.35;

import {Owned} from "solmate/auth/Owned.sol";

import {OutrunERC20PermitInit} from "../../common/token/OutrunERC20PermitInit.sol";
import {IMemeverseUniswapHook, PoolId} from "../interfaces/IMemeverseUniswapHook.sol";

/// @notice LP Token For MemeverseUniswapHookUpgradeable — callback-type ERC20.
/// @dev The ERC20 + EIP-2612 permit surface is inherited from the common `OutrunERC20PermitInit` base
///      (`OutrunERC20Init` / `OutrunNoncesInit` / `OutrunEIP712Init`); this contract adds only the
///      clone-specific pool fields, the owner-gated mint/burn, and the transfer snapshot callback.
///      EIP-712 read values (`DOMAIN_SEPARATOR`, `name`) on an UNINITIALIZED clone are undefined
///      (the base caches name/version hashes at init); clones are initialized in the same transaction
///      they are deployed (SwapFacet), so production paths always read initialized values.
///
///      Integration note — callback-type token: every `transfer`/`transferFrom` with
///      `from != address(0) && to != address(0)` triggers 1-2 external calls to
///      `MemeverseUniswapHook.updateUserSnapshot(poolId, user)` before `super._update` to
///      crystallize per-share fee snapshots. This makes the token ERC-777-like:
///      - gas cost of `transfer` is dominated by the hook and may change after hook/facet upgrades;
///      - if `updateUserSnapshot` reverts, the whole `transfer` reverts (fail-closed, no silent skip);
///      - callers that custody LP (vaults, restaking, lending, farming) must treat `transfer` as an
///        untrusted external call: apply checks-effects-interactions / `nonReentrant` and do not
///        assume it is cheap or non-reverting.
///      `mint`/`burn` (`from == address(0)` / `to == address(0)`) do not trigger the callback.
///      Self-transfer (`from == to != address(0)`) crystallizes once (idempotent via SwapFacet
///      zero-growth fast path). Upgrade invariant: `updateUserSnapshot` must remain low-gas and
///      snapshot-only (no permission writes); hook upgrades must preserve it or liveness of all LP
///      transfers is lost.
contract UniswapLP is Owned, OutrunERC20PermitInit {
    error ZeroAddressHook();

    uint8 private _decimals;
    PoolId public poolId;
    address public memeverseUniswapHook;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Owned(address(1)) {
        // The common Initializable constructor lock marks the implementation as initialized, so only
        // clones (which skip constructors) can run `initialize`.
    }

    /// @notice Initializes a pool-specific LP clone.
    /// @dev The hook becomes the token owner so mint/burn permissions stay hook-only. ERC20 and EIP-712
    ///      state live in the common base storage; the EIP-712 domain is bound to the clone's name and
    ///      address during initialization so permit signatures stay valid for this clone.
    /// @param _name ERC20 name for the LP clone.
    /// @param _symbol ERC20 symbol for the LP clone.
    /// @param decimals_ ERC20 decimals for the LP clone.
    /// @param _poolId Hook-managed pool id represented by this LP clone.
    /// @param _memeverseUniswapHook Hook that owns this LP clone and receives transfer snapshot callbacks.
    function initialize(
        string calldata _name,
        string calldata _symbol,
        uint8 decimals_,
        PoolId _poolId,
        address _memeverseUniswapHook
    ) external initializer {
        if (_memeverseUniswapHook == address(0)) revert ZeroAddressHook();
        __OutrunERC20_init(_name, _symbol);
        __OutrunERC20Permit_init(_name);
        _decimals = decimals_;
        poolId = _poolId;
        memeverseUniswapHook = _memeverseUniswapHook;
        owner = _memeverseUniswapHook;

        emit OwnershipTransferred(address(0), _memeverseUniswapHook);
    }

    /// @notice Mints LP tokens to `account`.
    /// @dev Minting routes `from == address(0)` through `_update`, so no snapshot callback fires; the
    ///      hook-side liquidity paths crystallize fee snapshots themselves via `_updateUserSnapshotViaFacet`
    ///      before minting.
    /// @param account Recipient of the LP tokens.
    /// @param amount Amount of LP tokens to mint.
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    /// @notice Burns LP tokens from `account`.
    /// @dev Burning routes `to == address(0)` through `_update`, so no snapshot callback fires.
    /// @param account Account whose LP tokens are burned.
    /// @param amount Amount of LP tokens to burn.
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    /// @notice Exposes the decimal precision used for display and accounting.
    /// @dev Per-clone configurable, unlike the base default of 18.
    /// @return tokenDecimals Number of decimals for UI/display conversions.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Applies a balance change, crystallizing fee snapshots before any mutation.
    /// @dev Callback-type token — snapshot callbacks fire only on real transfers (both `from` and `to`
    ///      non-zero): the base mint routes `from == address(0)` and burn routes `to == address(0)`, so
    ///      gating on both non-zero preserves the pinned mint/burn-excluded snapshot semantics.
    ///      The hook calls precede `super._update` so `updateUserSnapshot` reads the pre-mutation balance
    ///      baseline. Self-transfer (from == to) crystallizes once: `updateUserSnapshot` is idempotent per
    ///      address within one transaction (SwapFacet zero-growth fast path).
    ///      External-call properties for integrators: see the contract-level integration note.
    /// @param from Account the tokens leave (zero for mint).
    /// @param to Account the tokens arrive at (zero for burn).
    /// @param amount Amount of tokens moved.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            IMemeverseUniswapHook(memeverseUniswapHook).updateUserSnapshot(poolId, from);
            if (from != to) IMemeverseUniswapHook(memeverseUniswapHook).updateUserSnapshot(poolId, to);
        }
        super._update(from, to, amount);
    }
}
