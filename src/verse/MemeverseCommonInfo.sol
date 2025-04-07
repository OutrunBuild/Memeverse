// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IMemeverseCommonInfo } from "./interfaces/IMemeverseCommonInfo.sol";

/**
 * @title Memeverse Common Info Contract
 */ 
contract MemeverseCommonInfo is IMemeverseCommonInfo, Ownable {
    mapping(uint32 chainId => uint32) public lzEndpointIdMap;

    constructor(address _owner) Ownable(_owner) {}

    function setLzEndpointIdMap(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            lzEndpointIdMap[pair.chainId] = pair.endpointId;
        }

        emit SetLzEndpointIdMap(pairs);
    }
}
