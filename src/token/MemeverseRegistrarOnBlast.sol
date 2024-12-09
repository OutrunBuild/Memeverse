// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { MemeverseRegistrar } from "./MemeverseRegistrar.sol";
import { BlastGovernorable } from "../common/blast/BlastGovernorable.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof
 */ 
contract MemeverseRegistrarOnBlast is MemeverseRegistrar, BlastGovernorable {
    constructor(
        address _owner, 
        address _blastGovernor,
        address _localLzEndpoint, 
        address _localSendLibrary, 
        address _localReceiveLibrary, 
        address _memeverseLauncher, 
        address _registrationCenter, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid
    ) MemeverseRegistrar(
        _owner, 
        _localLzEndpoint, 
        _localSendLibrary, 
        _localReceiveLibrary, 
        _memeverseLauncher, 
        _registrationCenter, 
        _registerGasLimit,
        _cancelRegisterGasLimit,
        _registrationCenterEid,
        _registrationCenterChainid
    ) BlastGovernorable(_blastGovernor) {
    }
}
