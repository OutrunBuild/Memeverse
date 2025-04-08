//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev Interface for the Memeverse Registrar.
 */
interface IMemeverseCommonInfo {
    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    function lzEndpointIdMap(uint32 chainId) external view returns (uint32);

    function setLzEndpointIdMap(LzEndpointIdPair[] calldata pairs) external;

    event SetLzEndpointIdMap(LzEndpointIdPair[] pairs);
}