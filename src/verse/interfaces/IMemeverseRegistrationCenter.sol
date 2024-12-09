// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemeverseRegistrar } from "../../verse/interfaces/IMemeverseRegistrar.sol";

/**
 * @title Memeverse Registration Center Interface
 */
interface IMemeverseRegistrationCenter {
    struct RegistrationParam {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        string website;                 // Website link
        string x;                       // X account
        string telegram;                // Telegram account
        string discord;                 // Discord link
        string description;             // Memeverse description
        uint256 durationDays;           // DurationDays of genesis stage
        uint256 lockupDays;             // LockupDays of liquidity
        uint256 maxFund;                // Max fundraising(UPT) limit, if 0 => no limit
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        address registrar;              // Memeverse registrar
    }

    struct SymbolRegistration {
        uint256 uniqueId;               // unique verseId
        address registrar;              // registrar address
        uint64 unlockTime;              // Memeverse unlockTime
    }


    function previewRegistration(string calldata symbol) external view returns (bool);

    function registration(RegistrationParam calldata param) external payable;

    function cancelRegistration(uint256 uniqueId, string calldata symbol) external;

    function setDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays) external;

    function setLockupDaysRange(uint128 minLockupDays, uint128 maxLockupDays) external;

    function setLzEndpointId(IMemeverseRegistrar.LzEndpointId[] calldata endpoints) external;

    function setPeer(uint32[] calldata _eids, bytes32[] calldata _peers) external;


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

    error InvalidXLength();

    error LengthMismatch();

    error InsufficientFee();

    error PermissionDenied();

    error InvalidURILength();

    error EmptyOmnichainIds();

    error InvalidLockupDays();

    error InvalidNameLength();

    error InvalidDurationDays();
    
    error InvalidSymbolLength();
    
    error InvalidWebsiteLength();
    
    error InvalidDiscordLength();

    error ZeroRegistrarAddress();

    error InvalidTelegramLength();

    error MaxFundNotSetCorrectly();

    error InvalidDescriptionLength();

    error UniqueIdMismatch(uint256 uniqueId);

    error SymbolNotUnlock(uint64 unlockTime);

    error InvalidOmnichainId(uint32 omnichainId);
}
