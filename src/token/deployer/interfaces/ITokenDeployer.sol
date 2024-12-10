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

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external;

    function deployTokenAndConfigure(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        uint32[] calldata omnichainIds
    ) external returns (address token);

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);
}