// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Memeverse Registration Center V2 (UUPS upgrade-target shell)
 * @notice Bare upgrade-target shell used by the registration center UUPS upgrade tests. Does NOT inherit
 *         the production center: Solidity Error 8894 forbids inheriting any contract that declares
 *         `layout at`, and V1 uses `layout at erc7201("outrun.storage.MemeverseRegistrationCenter")`.
 * @dev Storage preservation across the V1 -> shell upgrade is verified via `vm.load` against the V1
 *      ERC-7201 namespace in the upgrade test, so this shell only needs the `upgradeVersion()` marker and
 *      an `endpoint()` getter that satisfies V1's `_authorizeUpgrade` endpoint-drift guard (the guard
 *      reads `IOAppCore(newImplementation).endpoint()`; a same-file `address` return decodes to the same
 *      32-byte word the interface's `ILayerZeroEndpointV2` return uses). During the V1 -> shell upgrade
 *      the proxy runs V1's `_authorizeUpgrade` (onlyOwner + no-code/endpoint guards); this contract's
 *      `_authorizeUpgrade` exists only to satisfy the abstract UUPS requirement and is never exercised
 *      through this shell.
 */
contract MemeverseRegistrationCenterUpgradeableV2 is UUPSUpgradeable {
    /// @dev Local LayerZero endpoint burned into the shell at construction. Constructing the shell with
    ///      the SAME endpoint as V1 passes the drift guard; a DIFFERENT endpoint exercises the guard's
    ///      `UpgradeEndpointMismatch` negative side.
    address private immutable ENDPOINT;

    /// @param endpoint_ Endpoint reported to V1's `_authorizeUpgrade` endpoint guard.
    constructor(address endpoint_) {
        ENDPOINT = endpoint_;
    }

    /// @notice Endpoint reported to V1's upgrade guard (IOAppCore-compatible 32-byte return).
    /// @return endpoint_ The constructor-burned endpoint address.
    function endpoint() external view returns (address) {
        return ENDPOINT;
    }

    /// @notice Returns the upgrade-target version marker.
    function upgradeVersion() external pure returns (uint256) {
        return 2;
    }

    /// @dev No-op: upgrade authorization is enforced by the V1 implementation while it is still live.
    function _authorizeUpgrade(address) internal pure override {}
}
