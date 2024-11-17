// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ISymbolRegistrationCenter } from "./interfaces/ISymbolRegistrationCenter.sol";

/**
 * @title Memeverse Omnichain Symbol Registration Center
 */
contract SymbolRegistrationCenter is ISymbolRegistrationCenter, Ownable {
    address public signer;
    uint256 public expireTime;      // SymbolRegistration: lockedTime = block.timestamp + expireTime
    uint256 public confirmDelay;    // Avoid duplicate Symbol creation when about to confirm

    // Main symbol mapping, recording the latest registration information
    mapping(string => SymbolRegistration) public symbolRegistry;

    // Symbol history mapping, storing all valid registration records
    mapping(string => SymbolRegistration[]) public symbolHistory;

    constructor(address _owner, address _signer, uint256 _expireTime, uint256 _confirmDelay) Ownable(_owner) {
        signer = _signer;
        expireTime = _expireTime;
        confirmDelay = _confirmDelay;
    }

    /**
     * @dev Preview if the symbol can be pre-registered
     */
    function previewPreRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;

        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        bool confirmed = currentRegistration.confirmed;
        uint256 validityPeriod = currentRegistration.validityPeriod;
        if (
            (confirmed && currentTime > validityPeriod) || 
            (!confirmed && currentTime > currentRegistration.lockedTime + confirmDelay)
        ) {
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Pre-registration symbol
     * @notice Pre-registration is not the actual registration. If the symbol is not 
     * successfully entered into the Memeverse Genesis stage before the symbol lock 
     * period expires, causing it to remain unconfirmed, others can still register the 
     * symbol. Additionally, the symbol registration has a validity period, which is
     * until the Memeverse unlockedTime. After the validity period expires, others can 
     * also register the symbol.
     */
    function preRegistration(string calldata symbol, address registrar) external override returns (uint256 uniqueId) {
        require(bytes(symbol).length < 32, InvalidSymbolLength());
        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        bool confirmed = currentRegistration.confirmed;
        uint256 validityPeriod = currentRegistration.validityPeriod;
        require(
            (confirmed && currentTime > validityPeriod) || 
            (!confirmed && currentTime > currentRegistration.lockedTime + confirmDelay), 
            AlreadyRegistered()
        );
        
        if (confirmed) {
            symbolHistory[symbol].push(SymbolRegistration({
                uniqueId: currentRegistration.uniqueId,
                registrar: currentRegistration.registrar,
                lockedTime: 0,      // save gas
                validityPeriod: 0,  // save gas
                confirmed: false    // save gas
            }));
        }
        
        uint256 lockedTime = currentTime + expireTime;
        uniqueId = uint256(keccak256(abi.encodePacked(symbol, currentTime, msg.sender)));
        currentRegistration.uniqueId = uniqueId;
        currentRegistration.registrar = registrar;
        currentRegistration.lockedTime = uint64(lockedTime);
        if (validityPeriod != 0) currentRegistration.validityPeriod = 0;
        if (confirmed) currentRegistration.confirmed = false;

        emit PreRegistration(uniqueId, symbol, registrar, lockedTime);
    }

    /**
     * @dev Confirm registration
     */
    function confirmRegistration(
        uint256 uniqueId, 
        string calldata symbol, 
        uint256 validityPeriod,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external /*override*/ {
        require(block.timestamp > deadline, ExpiredSignature(deadline));
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        uint256 registrationLockedTime = currentRegistration.lockedTime;
        require(
            !currentRegistration.confirmed && registrationLockedTime > block.timestamp, 
            PreRegistrationHasExpired(registrationLockedTime)
        );
        
        bytes32 messageHash = keccak256(abi.encode(
            uniqueId,
            symbol, 
            validityPeriod,
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        currentRegistration.confirmed = true;
        currentRegistration.validityPeriod = uint64(validityPeriod);

        emit ConfirmRegistration(uniqueId, symbol, validityPeriod);
    }

    /**
     * @dev Cancel registration when Memeverse enters the refund phase on all chains.
     */
    function cancelRegistration(
        uint256 uniqueId, 
        string calldata symbol, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external /*override*/ {
        require(block.timestamp > deadline, ExpiredSignature(deadline));
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        uint256 validityPeriod = currentRegistration.validityPeriod;
        require(
            currentRegistration.confirmed && block.timestamp < validityPeriod,
            RegistrationNotConfirmed()
        );
        
        bytes32 messageHash = keccak256(abi.encode(
            uniqueId,
            symbol, 
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        currentRegistration.confirmed = false;
        currentRegistration.validityPeriod = 0;

        emit CancelRegistration(uniqueId, symbol);
    }

    function updateExpireTime(uint256 _expireTime) external override onlyOwner {
        expireTime = _expireTime;
    }

    function updateConfirmDelay(uint256 _confirmDelay) external override onlyOwner {
        confirmDelay = _confirmDelay;
    }
}
