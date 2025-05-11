// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title Memeverse Registration Center Interface
 */
interface IMemeverseRegistrationCenter {
    struct RegistrationParam {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        string desc;                    // Description
        string[] communities;           // Community, index -> 0:Website, 1:X, 2:Discord, 3:Telegram, >4:Others
        uint256 durationDays;           // DurationDays of genesis stage
        uint256 lockupDays;             // LockupDays of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        address UPT;                    // UPT of Memeverse
        bool flashGenesis;              // Allowing the transition to the liquidity lock stage once the minimum funding requirement is met, without waiting for the genesis stage to end.
    }

    struct SymbolRegistration {
        uint256 uniqueId;               // unique verseId
        uint64 endTime;                 // Memeverse genesis endTime
        uint192 nonce;                  // Number of replication
    }

    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    struct RegisterGasLimitPair {
        uint32 chainId;
        uint128 gasLimit;
    }


    function previewRegistration(string calldata symbol) external view returns (bool);

    function quoteSend(
        uint32[] memory omnichainIds, 
        bytes memory message
    ) external view returns (uint256, uint256[] memory, uint32[] memory);

    function registration(RegistrationParam calldata param) external payable;

    function removeGasDust(address receiver) external;

    function lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory options,
        MessagingFee memory fee,
        address refundAddress
    ) external payable;

    function setDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays) external;

    function setLockupDaysRange(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setRegisterGasLimit(uint256 registerGasLimit) external;


    event Registration(
        uint256 indexed uniqueId,
        RegistrationParam param
    );

    event RemoveGasDust(address indexed receiver, uint256 dust);

    event SetDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays);

    event SetLockupDaysRange(uint128 minLockupDays, uint128 maxLockupDays);

    event SetRegisterGasLimit(uint256 registerGasLimit);


    error ZeroInput();

    error InvalidInput();

    error InvalidLength();

    error ZeroUPTAddress();

    error PermissionDenied();

    error EmptyOmnichainIds();

    error InvalidLockupDays();

    error InsufficientLzFee();

    error InvalidDurationDays();

    error SymbolNotUnlock(uint64 unlockTime);

    error InvalidOmnichainId(uint32 omnichainId);
}
