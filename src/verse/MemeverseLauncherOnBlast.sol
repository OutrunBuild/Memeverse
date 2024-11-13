// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { GasManagerable } from "../blast/GasManagerable.sol";
import { MemecoinOnBlast } from "../token/MemecoinOnBlast.sol";
import { MemeLiquidProofOnBlast } from "../token/MemeLiquidProofOnBlast.sol";
import { MemecoinVaultOnBlast } from "../yield/MemecoinVaultOnBlast.sol";
import { MemeverseLauncher, ECDSA, MessageHashUtils } from "./MemeverseLauncher.sol";

/**
 * @title Trapping into the memeverse on blast
 */
contract MemeverseLauncherOnBlast is MemeverseLauncher, GasManagerable {
    constructor(
        string memory _name,
        string memory _symbol,
        address _UPT,
        address _owner,
        address _signer,
        address _gasManager,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter
    ) MemeverseLauncher(
        _name, 
        _symbol,
        _UPT,
        _owner,
        _signer,
        _revenuePool,
        _outrunAMMFactory,
        _outrunAMMRouter
    ) GasManagerable(_gasManager) {
    }

    /**
     * @dev register memeverse(single chain)
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param uniqueId - Unique verseId
     * @param durationDays - Duration days of launchpool
     * @param lockupDays - LockupDay of liquidity
     */
    function registerMemeverse(
        string calldata _name,
        string calldata _symbol,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable override {
        require(
            lockupDays >= minLockupDays && 
            lockupDays <= maxLockupDays && 
            durationDays >= minDurationDays && 
            durationDays <= maxDurationDays && 
            bytes(_name).length < 32 && 
            bytes(_symbol).length < 32, 
            InvalidRegisterInfo()
        );

        require(block.timestamp > deadline, ExpiredSignature(deadline));
        bytes32 messageHash = keccak256(abi.encode(
            _name, 
            _symbol, 
            uniqueId, 
            durationDays, 
            lockupDays, 
            block.chainid, 
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        uint256 _genesisFee = genesisFee;
        require(msg.value >= _genesisFee, InsufficientGenesisFee(_genesisFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        // Deploy memecoin and liquidProof token
        address memecoin = address(new MemecoinOnBlast(_name, _symbol, 18, address(this), gasManager));
        address liquidProof = address(new MemeLiquidProofOnBlast(
            string(abi.encodePacked(_name, " Liquid")),
            string(abi.encodePacked(_symbol, " LIQUID")),
            18,
            memecoin,
            address(this),
            gasManager
        ));

        // Deploy memecoin vault
        address memecoinVault = address(new MemecoinVaultOnBlast(
            string(abi.encodePacked("Staked ", _name)),
            string(abi.encodePacked("s", _symbol)),
            memecoin,
            address(this),
            gasManager,
            uniqueId
        ));

        uint32[] memory omnichainIds;
        Memeverse memory verse = Memeverse(
            _name, 
            _symbol, 
            memecoin, 
            liquidProof, 
            memecoinVault, 
            0,
            block.timestamp + durationDays * DAY,
            lockupDays, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        address msgSender = msg.sender;
        _safeMint(msgSender, uniqueId);

        emit RegisterMemeverse(uniqueId, msgSender, memecoin, liquidProof, memecoinVault);
    }

    /**
     * @dev register omnichain memeverse
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param memecoin - Already created omnichain memecoin address
     * @param uniqueId - Unique verseId
     * @param durationDays - Duration days of launchpool
     * @param lockupDays - LockupDay of liquidity
     * @param maxFund - Max fundraising(UPT) limit, if 0 => no limit
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
    function registerOmnichainMemeverse(
        string calldata _name,
        string calldata _symbol,
        address memecoin,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint128 maxFund,
        uint32[] calldata omnichainIds,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable override {
        require(
            lockupDays >= minLockupDays && 
            lockupDays <= maxLockupDays && 
            durationDays >= minDurationDays && 
            durationDays <= maxDurationDays && 
            maxFund > 0 && 
            bytes(_name).length < 32 && 
            bytes(_symbol).length < 32, 
            InvalidRegisterInfo()
        );

        require(block.timestamp > deadline, ExpiredSignature(deadline));
        bytes32 messageHash = keccak256(abi.encode(
            _name, 
            _symbol, 
            uniqueId, 
            durationDays, 
            lockupDays, 
            maxFund, 
            omnichainIds, 
            block.chainid, 
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        uint256 _genesisFee = genesisFee;
        require(msg.value >= _genesisFee, InsufficientGenesisFee(_genesisFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        // Deploy  liquidProof token
        address liquidProof = address(new MemeLiquidProofOnBlast(
            string(abi.encodePacked(_name, " Liquid")),
            string(abi.encodePacked(_symbol, " LIQUID")),
            18,
            memecoin,
            address(this),
            gasManager
        ));

        // Deploy memecoin vault
        address memecoinVault = address(new MemecoinVaultOnBlast(
            string(abi.encodePacked("Staked ", _name)),
            string(abi.encodePacked("s", _symbol)),
            memecoin,
            address(this),
            gasManager,
            uniqueId
        ));

        Memeverse memory verse = Memeverse(
            _name, 
            _symbol, 
            memecoin, 
            liquidProof, 
            memecoinVault, 
            maxFund,
            block.timestamp + durationDays * DAY,
            lockupDays, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        address msgSender = msg.sender;
        _safeMint(msgSender, uniqueId);

        emit RegisterMemeverse(uniqueId, msgSender, memecoin, liquidProof, memecoinVault);
    }
}
