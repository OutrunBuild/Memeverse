// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "./Initializable.sol";
import {OutrunOwnable} from "./OutrunOwnable.sol";

/**
 * @dev Outrun's minimal-proxy-friendly Ownable base. The Ownable body (storage
 * slot, accessors, errors, event) lives in `OutrunOwnable`; this contract only
 * adds the Outrun `Initializable`-guarded initializer on top. Ownership is never
 * renounceable.
 */
abstract contract OutrunOwnableInit is OutrunOwnable, Initializable {
    /// @dev Initializes the contract setting the address provided by the deployer as the initial owner.
    function __OutrunOwnable_init(address initialOwner) internal onlyInitializing {
        __OutrunOwnable_init_unchanged(initialOwner);
    }
}
