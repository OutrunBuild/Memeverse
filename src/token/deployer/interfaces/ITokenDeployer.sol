// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

/**
 * @title Memecoin interface
 */
interface ITokenDeployer {
    struct LzEndpointId {
        uint32 chainId;
        uint32 endpointId;
    }

    function deployTokenAndConfigure(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        uint32[] calldata omnichainIds
    ) external returns (address token);

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external;

    function setMemeverseLauncher(address memeverseLauncher) external;

    function setMemeverseRegistrar(address _memeverseRegistrar) external;

    event DeployMemecoin(address indexed token, address indexed creator);

    event DeployLiquidProof(address indexed token, address indexed creator);

    error ZeroAddress();

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);
}