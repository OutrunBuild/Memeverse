// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";

import { TokenDeployer } from "./TokenDeployer.sol";
import { MemeLiquidProof } from "../../token/MemeLiquidProof.sol";

/**
 * @title LiquidProof deployer
 */
contract LiquidProofDeployer is TokenDeployer {
    constructor(
        address _owner,
        address _localLzEndpoint,
        address _memeverseLauncher, 
        address _memeverseRegistrar
    ) TokenDeployer(_owner, _localLzEndpoint, _memeverseLauncher, _memeverseRegistrar) {
    }

    function _deployToken(
        string memory name, 
        string memory symbol,
        uint256 uniqueId,
        address creator,
        address memecoin
    ) internal virtual override returns (address token) {
        bytes memory constructorArgs = abi.encode(
            string(abi.encodePacked(name, " Liquid")), 
            string(abi.encodePacked(symbol, " LIQUID")), 
            18, 
            memecoin, 
            MEMEVERSE_LAUNCHER, 
            LOCAL_LZ_ENDPOINT, 
            address(this)
        );
        bytes memory initCode = abi.encodePacked(type(MemeLiquidProof).creationCode, constructorArgs);
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        token = CREATE3.deploy(salt, initCode, 0);
    }
}
