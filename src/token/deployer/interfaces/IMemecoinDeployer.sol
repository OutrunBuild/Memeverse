// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

/**
 * @title MemecoinDeployer interface
 */
interface IMemecoinDeployer {
    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    function deployMemecoinAndConfigure(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoinLauncher,
        uint32[] calldata omnichainIds
    ) external returns (address memecoin);

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external;

    function setMemeverseRegistrar(address _memeverseRegistrar) external;

    function setImplementation(address _implementation) external;

    event DeployMemecoin(address indexed token, address indexed creator);

    error ZeroAddress();

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);
}