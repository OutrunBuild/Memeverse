// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

/**
 * @title Memeverse Symbol Registration Center Interface
 */
interface ISymbolRegistrationCenter {
    struct SymbolRegistration {
        uint256 uniqueId;       // unique verseId
        address registrar;      // registrar address
        uint64 lockedTime;      // Symbol locked Time
        uint64 validityPeriod;  // Registration validity period, valid until the memeverse unlockedTime(Not symbol locked time)
        bool confirmed;         // If the registration expires without being confirmed, and others may proceed to register this symbol
    }

    function previewPreRegistration(string calldata symbol) external view returns (bool);

    function preRegistration(string calldata symbol, address registrar) external returns (uint256 uniqueId);

    function updateExpireTime(uint256 expireTime) external;

    function updateConfirmDelay(uint256 _confirmDelay) external;

    event PreRegistration(
        uint256 indexed uniqueId,
        string indexed symbol,
        address indexed registrar,
        uint256 lockedTime
    );

    event ConfirmRegistration(
        uint256 indexed uniqueId, 
        string indexed symbol, 
        uint256 indexed validityPeriod
    );

    event CancelRegistration(
        uint256 indexed uniqueId, 
        string indexed symbol
    );

    error InvalidSigner();

    error AlreadyRegistered();

    error InvalidSymbolLength();

    error RegistrationNotConfirmed();

    error ExpiredSignature(uint256 deadline);

    error PreRegistrationHasExpired(uint256 registrationLockedTime);
}
