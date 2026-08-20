// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Minimal-proxy (EIP-1167 clone) initializer — uses ERC-7201 slot `outrun.storage.Initializable`.
 *
 * Dual Initializable invariant: this contract and
 * `openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol` (OZ)
 * (exposed via `OutrunOwnableUpgradeable`) live in different ERC-7201 slots
 * (`outrun.storage.Initializable` vs `openzeppelin.storage.Initializable`) and are
 * mutually unaware. A single contract MUST NOT inherit both families — e.g.
 * mixing `OutrunERC20Init` / `OutrunOFTInit` / `OutrunOAppCoreInit` /
 * `OutrunOwnableInit` (this family) with `OutrunOwnableUpgradeable`
 * (OZ family) — would require explicit `override` of `initializer` /
 * `onlyInitializing` / `_checkInitializing` to compile and could then expose two
 * `initialize*` entries each guarded by a different lock, silently allowing
 * double initialization. If the same function were guarded by both modifiers it
 * would loudly revert, but separate entries would not. Keep the families
 * strictly segregated. Enforced by `script/harness/check-no-dual-initializable.sh`.
 */
abstract contract Initializable {
    error NotInitializing();
    error AlreadyInitialized();

    struct InitializableStorage {
        bool initialized;
        bool initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE_LOCATION =
        0x364b90b49cc5a06782669778ce5f4dc79d5c3891ab824b5e713b2409af81a500;

    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE_LOCATION
        }
    }

    // Lock initialization in logic contract
    constructor() {
        _getInitializableStorage().initialized = true;
    }

    modifier initializer() {
        InitializableStorage storage $ = _getInitializableStorage();
        if ($.initialized) {
            revert AlreadyInitialized();
        }

        $.initialized = true;
        $.initializing = true;
        _;
        $.initializing = false;
    }

    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    function _checkInitializing() internal view {
        if (!_getInitializableStorage().initializing) {
            revert NotInitializing();
        }
    }
}
