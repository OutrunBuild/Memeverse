// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// Shared LZ endpoint registry mock used by launcher, interoperation, and settlement test suites.

/// @notice Mock registry mapping chain ids to LayerZero endpoint ids.
contract LzEndpointRegistryMock {
    mapping(uint32 chainId => uint32 endpointId) public lzEndpointIdOfChain;

    /// @notice Set endpoint.
    /// @dev Mirrors the registry setter so tests can control chain/endpoint mapping.
    /// @param chainId See implementation.
    /// @param endpointId See implementation.
    function setEndpoint(uint32 chainId, uint32 endpointId) external {
        lzEndpointIdOfChain[chainId] = endpointId;
    }
}
