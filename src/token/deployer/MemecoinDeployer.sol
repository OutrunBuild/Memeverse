// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { TokenDeployer } from "./TokenDeployer.sol";
import { Memecoin, IMemecoin } from "../../token/Memecoin.sol";

/**
 * @title Memecoin deployer
 */
contract MemecoinDeployer is TokenDeployer {
    using Clones for address;

    constructor(
        address _owner,
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _implementation
    ) TokenDeployer(_owner, _localLzEndpoint, _memeverseRegistrar, _implementation) {
    }

    function _deployToken(
        string memory name, 
        string memory symbol,
        uint256 uniqueId,
        address creator,
        address /*memecoin*/,
        address memeverseLauncher
    ) internal virtual override returns (address token) {
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        token = implementation.cloneDeterministic(salt);
        IMemecoin(token).initialize(name, symbol, 18, memeverseLauncher, LOCAL_LZ_ENDPOINT, address(this));

        emit DeployMemecoin(token, creator);
    }
}
