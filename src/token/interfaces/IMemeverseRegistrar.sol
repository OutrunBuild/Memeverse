//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

interface IMemeverseRegistrar {
    struct LzEndpointId {
        uint32 chainId;
        uint32 endpointId;
    }

    function registerMemeverse(
        string memory name, 
        string memory symbol,
        string memory uri,
        uint8 decimals,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint256 maxFund,
        uint32[] calldata omnichainIds,
        address creator
    ) external returns (address memecoin, address liquidProof);

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external;

    function setLzExecutor(address executor) external;


    error ZeroAddress();
    
    error PermissionDenied();

    event SetLzExecutor(address executor);

    event SetLzEndpointId(uint256 indexed chainId, uint256 indexed endpointId);
}