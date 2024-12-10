// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";

import { TokenDeployer } from "./TokenDeployer.sol";
import { Memecoin } from "../../token/Memecoin.sol";

/**
 * @title Memecoin deployer
 */
contract MemecoinDeployer is TokenDeployer {
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
        address /*memecoin*/
    ) internal virtual override returns (address token) {
        bytes memory constructorArgs = abi.encode(name, symbol, 18, MEMEVERSE_LAUNCHER, LOCAL_LZ_ENDPOINT, address(this));
        bytes memory initCode = abi.encodePacked(type(Memecoin).creationCode, constructorArgs);
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        token = CREATE3.deploy(salt, initCode, 0);
    }
}
