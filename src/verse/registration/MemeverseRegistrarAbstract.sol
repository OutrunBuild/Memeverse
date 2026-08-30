// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMemeverseRegistrar} from "../interfaces/IMemeverseRegistrar.sol";
import {IMemeverseLauncher} from "../interfaces/IMemeverseLauncher.sol";
import {IMemeverseRegistrarAtLocal} from "../interfaces/IMemeverseRegistrarAtLocal.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, Ownable {
    address public immutable MEMEVERSE_LAUNCHER;
    address public immutable LZ_ENDPOINT_REGISTRY;

    /// @notice Reverts when ownership renunciation is attempted.
    /// @dev Repo invariant: ownership is never renounceable.
    error OwnershipRenounceDisabled();

    constructor(address _owner, address _memeverseLauncher, address _lzEndpointRegistry) Ownable(_owner) {
        // Reuses the existing `IMemeverseRegistrarAtLocal.ZeroAddress()` declaration instead of declaring a
        // duplicate here: the local leaf inherits both this contract and that interface, and Solidity rejects
        // the same error name declared in two base contracts. Selector is identical to the repo-wide guards.
        require(
            _memeverseLauncher != address(0) && _lzEndpointRegistry != address(0),
            IMemeverseRegistrarAtLocal.ZeroAddress()
        );
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        LZ_ENDPOINT_REGISTRY = _lzEndpointRegistry;
    }

    /// @notice Ownership renunciation is permanently disabled.
    /// @dev The OZ `Ownable` base exposes `renounceOwnership`; this override makes it always revert,
    ///      keeping the repo-wide never-renounceable ownership invariant. Marked `virtual` only so
    ///      the omnichain leaf can re-pin it across the shared-`Ownable` diamond with the OApp stack.
    function renounceOwnership() public virtual override {
        revert OwnershipRenounceDisabled();
    }

    /**
     * @notice Register a memeverse.
     * @param param - The memeverse parameters.
     */
    function _registerMemeverse(MemeverseParam memory param) internal {
        IMemeverseLauncher(MEMEVERSE_LAUNCHER)
            .registerMemeverse(
                param.name,
                param.symbol,
                param.uniqueId,
                param.endTime,
                param.unlockTime,
                param.omnichainIds,
                param.uAsset,
                param.flashGenesis
            );
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).setExternalInfo(param.uniqueId, param.uri, param.desc, param.communities);
    }
}
