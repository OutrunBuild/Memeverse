// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

/**
 * @title Memecoin interface
 */
interface ITokenDeployer {
    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    function deployTokenAndConfigure(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        address memecoinDeployer,
        uint32[] calldata omnichainIds
    ) external returns (address token);

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external;

    function setMemeverseRegistrar(address _memeverseRegistrar) external;

    event DeployMemecoin(address indexed token, address indexed creator);

    event DeployLiquidProof(address indexed token, address indexed creator);

    error ZeroAddress();

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);
}