// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OutrunOwnable} from "./OutrunOwnable.sol";

/**
 * @title OutrunOwnableUpgradeable
 * @notice Lightweight Ownable base for contracts that use OpenZeppelin upgradeable initialization.
 * @dev The Ownable body lives in `OutrunOwnable`; this contract only adds the OZ
 *      `Initializable`-guarded initializer. Uses the same ERC7201 namespace as
 *      the non-OZ Outrun ownable base so ownership lives at `outrun.storage.Ownable`.
 *
 * @dev Initialization domain: this family uses OZ
 * `Initializable` (`openzeppelin.storage.Initializable`). Do NOT mix with
 * `OutrunOwnableInit` / `OutrunERC20Init` / `OutrunOFTInit` /
 * `OutrunOAppCoreInit` (custom `Initializable`,
 * `outrun.storage.Initializable`) in the same contract — the two locks live
 * in different ERC-7201 slots and are mutually unaware; mixing would require
 * explicit `override` of `initializer`/`onlyInitializing` and risks exposing
 * two `initialize*` entries with independent locks.
 * See `src/common/access/Initializable.sol` header and
 * `script/harness/check-no-dual-initializable.sh`.
 */
abstract contract OutrunOwnableUpgradeable is OutrunOwnable, Initializable {
    /// @notice Initializes ownership for the proxy during the OZ initializer flow.
    /// @dev Must only be called while OpenZeppelin `Initializable` is in its initializing state.
    /// @param initialOwner Address that becomes the initial owner.
    function __OutrunOwnable_init(address initialOwner) internal onlyInitializing {
        __OutrunOwnable_init_unchanged(initialOwner);
    }
}
