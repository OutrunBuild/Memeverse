// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "./Initializable.sol";
import {OutrunOwnable} from "./OutrunOwnable.sol";

/**
 * @dev Outrun's minimal-proxy-friendly Ownable base. The Ownable body (storage
 * slot, accessors, errors, event) lives in `OutrunOwnable`; this contract only
 * adds the Outrun `Initializable`-guarded initializer on top. Ownership is never
 * renounceable.
 *
 * @dev Initialization domain: this family uses the custom
 * `src/common/access/Initializable.sol` (`outrun.storage.Initializable`).
 * Do NOT mix with `OutrunOwnableUpgradeable` (OZ `Initializable`,
 * `openzeppelin.storage.Initializable`) in the same contract — the two locks
 * live in different ERC-7201 slots and are mutually unaware; mixing would
 * require explicit `override` of `initializer`/`onlyInitializing` and risks
 * exposing two `initialize*` entries with independent locks.
 * See `Initializable.sol` header and `script/harness/check-no-dual-initializable.sh`.
 */
abstract contract OutrunOwnableInit is OutrunOwnable, Initializable {
    /// @dev Initializes the contract setting the address provided by the deployer as the initial owner.
    function __OutrunOwnable_init(address initialOwner) internal onlyInitializing {
        __OutrunOwnable_init_unchanged(initialOwner);
    }
}
