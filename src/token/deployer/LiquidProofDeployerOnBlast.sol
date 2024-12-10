// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";

import { TokenDeployer } from "./TokenDeployer.sol";
import { MemeLiquidProof } from "../../token/MemeLiquidProof.sol";
import { BlastGovernorable } from "../../common/blast/BlastGovernorable.sol";

/**
 * @title LiquidProof deployer
 */
contract LiquidProofDeployer is TokenDeployer, BlastGovernorable {
    constructor(
        address _owner,
        address _blastGovernor,
        address _localLzEndpoint,
        address _memeverseLauncher, 
        address _memeverseRegistrar,
        address _localSendLibrary, 
        address _localReceiveLibrary
    ) TokenDeployer(
        _owner, 
        _localLzEndpoint, 
        _memeverseLauncher, 
        _memeverseRegistrar, 
        _localSendLibrary, 
        _localReceiveLibrary
    ) BlastGovernorable(_blastGovernor) {
    }

    function _deployToken(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        address memeverseLauncher,
        address lzEndpoint
    ) internal virtual override returns (address token) {
        bytes memory constructorArgs = abi.encode(
            string(abi.encodePacked(name, " Liquid")), 
            string(abi.encodePacked(symbol, " LIQUID")), 
            18, 
            memecoin, 
            memeverseLauncher, 
            lzEndpoint,
            address(this)
        );
        bytes memory initCode = abi.encodePacked(type(MemeLiquidProof).creationCode, constructorArgs);
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        token = CREATE3.deploy(salt, initCode, 0);
    }
}
