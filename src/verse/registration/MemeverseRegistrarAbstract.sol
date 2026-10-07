// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseRegistrar} from "../interfaces/IMemeverseRegistrar.sol";
import {IMemeverseLauncher} from "../interfaces/IMemeverseLauncher.sol";
import {IMemeverseRegistrarAtLocal} from "../interfaces/IMemeverseRegistrarAtLocal.sol";
import {NeverRenounceable} from "../../common/access/NeverRenounceable.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, NeverRenounceable {
    address public immutable MEMEVERSE_LAUNCHER;

    constructor(address _owner, address _memeverseLauncher) NeverRenounceable(_owner) {
        // Reuses the existing `IMemeverseRegistrarAtLocal.ZeroAddress()` declaration instead of declaring a
        // duplicate here: the local leaf inherits both this contract and that interface, and Solidity rejects
        // the same error name declared in two base contracts. Selector is identical to the repo-wide guards.
        require(_memeverseLauncher != address(0), IMemeverseRegistrarAtLocal.ZeroAddress());
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
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
