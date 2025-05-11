// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMemeverseRegistrar } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseCommonInfo } from "../verse/interfaces/IMemeverseCommonInfo.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */ 
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, Ownable {
    address public immutable MEMEVERSE_LAUNCHER;
    address public immutable MEMEVERSE_COMMON_INFO;

    /**
     * @notice Constructor to initialize the MemeverseRegistrar.
     * @param _owner - The owner of the contract.
     * @param _memeverseLauncher - Address of memeverseLauncher.
     * @param _memeverseCommonInfo - Address of MemeverseCommonInfo.
     */
    constructor(address _owner, address _memeverseLauncher, address _memeverseCommonInfo) Ownable(_owner) {
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        MEMEVERSE_COMMON_INFO = _memeverseCommonInfo;
    }

    /**
     * @notice Register a memeverse.
     * @param param - The memeverse parameters.
     */
    function _registerMemeverse(MemeverseParam memory param) internal {
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).registerMemeverse(
            param.name, param.symbol, param.uniqueId, param.endTime, 
            param.unlockTime, param.omnichainIds, param.UPT, param.flashGenesis
        );
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).setExternalInfo(
            param.uniqueId, param.uri, param.desc, param.communities
        );
    }
}
