// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";

import { MemecoinDeployer } from "./MemecoinDeployer.sol";
import { Memecoin } from "../../token/Memecoin.sol";
import { BlastGovernorable } from "../../common/blast/BlastGovernorable.sol";

/**
 * @title Memecoin deployer
 */
contract MemecoinDeployerOnBlast is MemecoinDeployer, BlastGovernorable {
    constructor(
        address _owner,
        address _blastGovernor,
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _implementation
    ) MemecoinDeployer(
        _owner, 
        _localLzEndpoint, 
        _memeverseRegistrar,
        _implementation
    ) BlastGovernorable(_blastGovernor) {
    }
}
