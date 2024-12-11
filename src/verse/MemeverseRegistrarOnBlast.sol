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
        address _memecoinDeployer,
        address _liquidProofDeployer,
        address _memeverseLauncher, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid
    ) MemeverseRegistrar(
        _owner, 
        _localLzEndpoint, 
        _memecoinDeployer,
        _liquidProofDeployer,
        _memeverseLauncher, 
        _registerGasLimit,
        _cancelRegisterGasLimit,
        _registrationCenterEid
    ) BlastGovernorable(_blastGovernor) {
    }
}
