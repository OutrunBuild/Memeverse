// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";

import { LiquidProofDeployer } from "./LiquidProofDeployer.sol";
import { MemeLiquidProof } from "../../token/MemeLiquidProof.sol";
import { BlastGovernorable } from "../../common/blast/BlastGovernorable.sol";

/**
 * @title LiquidProof deployer
 */
contract LiquidProofDeployerOnBlast is LiquidProofDeployer, BlastGovernorable {
    constructor(
        address _owner,
        address _blastGovernor,
        address _localLzEndpoint,
        address _memeverseLauncher, 
        address _memeverseRegistrar
    ) LiquidProofDeployer(
        _owner, 
        _localLzEndpoint, 
        _memeverseLauncher, 
        _memeverseRegistrar
    ) BlastGovernorable(_blastGovernor) {
    }
}
