// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrar } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */ 
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, Ownable {
    mapping(address UPT => address memeverseLauncher) public uptToLauncher;

    /**
     * @notice Constructor to initialize the MemeverseRegistrar.
     * @param _owner The owner of the contract.
     */
    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Set the UPT launcher for the given pairs.
     * @param pairs The pairs of UPT and memeverse launcher to set.
     */
    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            UPTLauncherPair calldata pair = pairs[i];
            if (pair.upt == address(0) || pair.memeverseLauncher == address(0)) continue;

            uptToLauncher[pair.upt] = pair.memeverseLauncher;
        }

        emit SetUPTLauncher(pairs);
    }

    /**
     * @notice Register a memeverse.
     * @param param The memeverse parameters.
     */
    function _registerMemeverse(MemeverseParam memory param) internal {
        IMemeverseLauncher(uptToLauncher[param.upt]).registerMemeverse(
            param.name, param.symbol, param.uri, param.uniqueId, 
            param.endTime, param.unlockTime, param.omnichainIds
        );
    }
}
