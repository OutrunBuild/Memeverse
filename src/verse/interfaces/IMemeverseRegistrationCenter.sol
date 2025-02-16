// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrar } from "../../verse/interfaces/IMemeverseRegistrar.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title Memeverse Registration Center Interface
 */
interface IMemeverseRegistrationCenter {
    struct RegistrationParam {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        uint256 durationDays;           // DurationDays of genesis stage
        uint256 lockupDays;             // LockupDays of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        address creator;                // Memeverse creator
        address upt;                    // UPT of Memeverse
    }

    struct SymbolRegistration {
        uint256 uniqueId;               // unique verseId
        address creator;                // creator address
        uint64 unlockTime;              // Memeverse unlockTime
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

    function cancelRegistration(uint256 uniqueId, string calldata symbol) external;

    function lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory options,
        MessagingFee memory fee,
        address refundAddress
    ) external payable;

    function setDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays) external;

    function setLockupDaysRange(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external;

    function setRegisterGasLimit(uint256 registerGasLimit) external;


    event Registration(
        uint256 indexed uniqueId,
        RegistrationParam param
    );

    event CancelRegistration(
        uint256 indexed uniqueId, 
        string indexed symbol
    );


    error ZeroInput();

    error InvalidInput();

    error ZeroUPTAddress();

    error LengthMismatch();

    error PermissionDenied();

    error InvalidURILength();

    error EmptyOmnichainIds();

    error InvalidLockupDays();

    error InvalidNameLength();

    error InsufficientLzFee();

    error InvalidDurationDays();
    
    error InvalidSymbolLength();
    
    error ZeroCreatorAddress();

    error MaxFundNotSetCorrectly();

    error SymbolNotUnlock(uint64 unlockTime);

    error InvalidOmnichainId(uint32 omnichainId);
}
