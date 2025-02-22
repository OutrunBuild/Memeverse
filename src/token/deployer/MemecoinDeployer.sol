// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMemecoin } from "../../token/interfaces/IMemecoin.sol";
import { IMemecoinDeployer } from "./interfaces/IMemecoinDeployer.sol";

/**
 * @title Memecoin deployer
 */
contract MemecoinDeployer is IMemecoinDeployer, Ownable {
    using Clones for address;

    address public immutable LOCAL_LZ_ENDPOINT;
    address public memeverseRegistrar;
    address public implementation;

    /**
     * @notice Constructor of MemecoinDeployer.
     * @param _owner - The owner of the contract.
     * @param _localLzEndpoint - The local LayerZero endpoint.
     * @param _memeverseRegistrar - The memeverse registrar.
     * @param _implementation - The implementation of the memecoin.
     */
    constructor(
        address _owner, 
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _implementation
    ) Ownable(_owner) {
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        memeverseRegistrar = _memeverseRegistrar;
        implementation = _implementation;
    }

    /**
     * @dev Deploy Memecoin on the current chain
     * @param name - The name of the memecoin.
     * @param symbol - The symbol of the memecoin.
     * @param uniqueId - The unique id of the memecoin.
     * @param creator - The creator of the memecoin.
     * @param memeverseLauncher - The memeverse launcher.
     * @return memecoin - The address of the memecoin.
     */ 
    function deployMemecoin(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memeverseLauncher
    ) external override returns (address memecoin) {
        require(msg.sender == memeverseRegistrar, PermissionDenied());
        
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        memecoin = implementation.cloneDeterministic(salt);
        IMemecoin(memecoin).initialize(name, symbol, 18, memeverseLauncher, LOCAL_LZ_ENDPOINT, memeverseRegistrar);

        emit DeployMemecoin(memecoin, creator);
    }

    /**
     * @dev Set the memeverse registrar.
     * @param _memeverseRegistrar - The memeverse registrar.
     */
    function setMemeverseRegistrar(address _memeverseRegistrar) external override onlyOwner {
        require(_memeverseRegistrar != address(0), ZeroAddress());

        memeverseRegistrar = _memeverseRegistrar;
    }

    /**
     * @dev Set the memecoin implementation.
     * @param _implementation - The memecoin implementation.
     */
    function setImplementation(address _implementation) external override onlyOwner {
        require(_implementation != address(0), ZeroAddress());

        implementation = _implementation;
    }
}
