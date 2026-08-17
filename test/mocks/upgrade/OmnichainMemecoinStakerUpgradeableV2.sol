// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Omnichain Memecoin Staker V2 (upgrade-target shell)
 * @notice Bare upgrade-target shell used by the staker UUPS upgrade test. Does NOT inherit the staker:
 *         Solidity Error 8894 forbids inheriting any contract that declares `layout at`, and V1 uses
 *         `layout at erc7201("outrun.storage.OmnichainMemecoinStaker")`.
 * @dev Post-upgrade state is verified via `vm.load` against the V1 ERC-7201 namespace
 *      ("outrun.storage.OmnichainMemecoinStaker"); this contract only exposes `upgradeVersion()` to
 *      confirm the new code is live. During the V1 -> shell upgrade, the proxy runs V1's
 *      `_authorizeUpgrade` (plain onlyOwner); this contract's `_authorizeUpgrade` exists only to satisfy
 *      the abstract UUPS requirement and is never exercised through this shell.
 */
contract OmnichainMemecoinStakerUpgradeableV2 is UUPSUpgradeable {
    /// @notice Returns the upgrade-target version marker.
    function upgradeVersion() external pure returns (uint256) {
        return 2;
    }

    /// @dev No-op: upgrade authorization is enforced by the V1 implementation while it is still live.
    function _authorizeUpgrade(address) internal pure override {}
}
