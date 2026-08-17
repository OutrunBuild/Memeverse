// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OAppUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";

/**
 * @title OutrunOAppUpgradeable
 * @notice Shared base for repo UUPS contracts built on the LayerZero upgradeable OApp stack.
 * @dev Hoists the repo's never-renounceable ownership invariant from per-contract overrides up to the
 *      base level, mirroring the `src/common/access/` Outrun ownable family's encoding philosophy:
 *      `OutrunOwnable` simply omits the renounce entrypoint, while the OZ `OwnableUpgradeable` inherited
 *      here already exposes `renounceOwnership`, so this base overrides it to always revert.
 */
abstract contract OutrunOAppUpgradeable is OAppUpgradeable {
    /// @notice Reverts when ownership renunciation is attempted.
    /// @dev Repo invariant: ownership is never renounceable.
    error OwnershipRenounceDisabled();

    /**
     * @dev Constructor forwarding the local LayerZero endpoint to the OApp base.
     * @param _lzEndpoint The address of the LOCAL LayerZero endpoint.
     */
    constructor(address _lzEndpoint) OAppUpgradeable(_lzEndpoint) {}

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev The OZ `OwnableUpgradeable` base (inherited through the OApp stack) exposes
    ///      `renounceOwnership`; this override makes it always revert, keeping the repo-wide
    ///      never-renounceable ownership invariant.
    function renounceOwnership() public override {
        revert OwnershipRenounceDisabled();
    }
}
