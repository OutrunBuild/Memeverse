//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Registry interface for mapping EVM chain IDs to LayerZero endpoint IDs.
 */
interface ILzEndpointRegistry {
    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    /// @dev Reverted when a pair has a zero chainId or endpointId.
    error InvalidEndpointIdPair();

    /// @notice Looks up the LayerZero endpoint ID configured for an EVM chain.
    /// @dev Returns zero when the chain has not been configured yet.
    /// @param chainId EVM chain ID.
    /// @return endpointId LayerZero endpoint ID mapped to `chainId`.
    function lzEndpointIdOfChain(uint32 chainId) external view returns (uint32);

    /// @notice Applies a batch of chain-to-endpoint mappings.
    /// @dev Implementations may restrict this to an admin path and reject invalid pairs.
    /// @param pairs Batch of `(chainId, endpointId)` pairs to apply.
    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external;

    event SetLzEndpointIds(LzEndpointIdPair[] pairs);
}
