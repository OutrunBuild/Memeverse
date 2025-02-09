// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title MemecoinDeployer interface
 */
interface IMemecoinDeployer {
    function deployMemecoin(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoinLauncher
    ) external returns (address memecoin);

    function setMemeverseRegistrar(address _memeverseRegistrar) external;

    function setImplementation(address _implementation) external;

    event DeployMemecoin(address indexed token, address indexed creator);

    error ZeroAddress();

    error PermissionDenied();
}