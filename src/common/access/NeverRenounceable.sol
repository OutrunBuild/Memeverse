// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NeverRenounceable
 * @notice Shared base for repo contracts built directly on the plain OZ `Ownable` family.
 * @dev Hoists the repo's never-renounceable ownership invariant to a single point for the plain
 *      `Ownable` family, mirroring the `src/common/access/` Outrun ownable family's encoding
 *      philosophy: `OutrunOwnable` simply omits the renounce entrypoint, while the OZ `Ownable`
 *      inherited here already exposes `renounceOwnership`, so this base overrides it to always
 *      revert. Leaves on official-stack diamonds keep the language-forced merge-override that
 *      references this single error declaration (e.g. `MemeverseRegistrarOmnichain`); vendored
 *      official-stack leaves that bind `Ownable(delegate)` at construction keep a local override
 *      instead (e.g. `GenesisCredit`).
 */
abstract contract NeverRenounceable is Ownable {
    /// @notice Reverts when ownership renunciation is attempted.
    /// @dev Repo invariant: ownership is never renounceable.
    error OwnershipRenounceDisabled();

    /// @dev Constructor forwarding the initial owner to the OZ `Ownable` base.
    /// @param initialOwner Initial owner; renunciation is permanently disabled.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev The OZ `Ownable` base exposes `renounceOwnership`; this override makes it always revert,
    ///      keeping the repo-wide never-renounceable ownership invariant. Marked `virtual` so a leaf
    ///      sitting on a shared-`Ownable` diamond can merge-override with an explicit base list.
    function renounceOwnership() public virtual override {
        revert OwnershipRenounceDisabled();
    }
}
