// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILzEndpointRegistry} from "./interfaces/ILzEndpointRegistry.sol";

/**
 * @title LayerZero Endpoint Registry
 */
contract LzEndpointRegistry is ILzEndpointRegistry, Ownable {
    mapping(uint32 chainId => uint32) public lzEndpointIdOfChain;

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Batch-updates chain-to-endpoint mappings.
    /// @dev Reverts with `InvalidEndpointIdPair` if any pair has `chainId == 0`
    ///      or `endpointId == 0`, and with `DuplicateChainIdInBatch` if a chainId
    ///      repeats within the batch; otherwise stores and emits all pairs.
    /// @param pairs List of `(chainId, endpointId)` pairs to store.
    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        uint256 pairsLength = pairs.length;
        for (uint256 i = 0; i < pairsLength;) {
            LzEndpointIdPair calldata pair = pairs[i];
            unchecked {
                ++i;
            }

            if (pair.chainId == 0 || pair.endpointId == 0) revert InvalidEndpointIdPair();

            // Reject a chainId repeated within this batch: silently letting the last
            // pair win would hide a misconfiguration. Re-pointing across separate
            // transactions remains allowed.
            // `pair` is read from `pairs[i]` before `++i`, so it sits at index i - 1;
            // the scan must cover only the already-processed elements [0, i - 1).
            for (uint256 j = 0; j + 1 < i;) {
                if (pairs[j].chainId == pair.chainId) revert DuplicateChainIdInBatch(pair.chainId);
                unchecked {
                    ++j;
                }
            }

            lzEndpointIdOfChain[pair.chainId] = pair.endpointId;
        }

        emit SetLzEndpointIds(pairs);
    }
}
