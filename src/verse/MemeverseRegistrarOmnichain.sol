// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { MemeverseRegistrarAbstract } from "./MemeverseRegistrarAbstract.sol";
import { IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseRegistrarOmnichain } from "./interfaces/IMemeverseRegistrarOmnichain.sol";

/**
 * @title Omnichain MemeverseRegistrar for deploying memecoin, liquidProof and registering memeverse
 */ 
contract MemeverseRegistrarOmnichain is IMemeverseRegistrarOmnichain, MemeverseRegistrarAbstract, OApp {
    using OptionsBuilder for bytes;

    uint32 public immutable REGISTRATION_CENTER_EID;
    
    uint128 public registerGasLimit;
    uint128 public cancelRegisterGasLimit;

    constructor(
        address _owner, 
        address _localLzEndpoint, 
        address _memecoinDeployer, 
        address _liquidProofDeployer, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid
    ) MemeverseRegistrarAbstract(
        _owner,
        _memecoinDeployer,
        _liquidProofDeployer
    ) OApp(_localLzEndpoint, _owner) {
        registerGasLimit = _registerGasLimit;
        cancelRegisterGasLimit = _cancelRegisterGasLimit;

        REGISTRATION_CENTER_EID = _registrationCenterEid;
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable override {
        bytes memory message = abi.encode(0, param);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(registerGasLimit, value);
        uint256 fee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
        require(msg.value >= fee, InsufficientFee());

        _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), msg.sender);
    }

    function cancelRegistration(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress
    ) external payable override {
        require(launcherToUPT[msg.sender] != address(0), PermissionDenied());
        
        bytes memory message = abi.encode(uniqueId, param);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(cancelRegisterGasLimit , 0);
        uint256 fee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
        require(msg.value >= fee, InsufficientFee());

        _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), lzRefundAddress);
    }

    function setRegisterGasLimit(uint128 _registerGasLimit) external override onlyOwner {
        registerGasLimit = _registerGasLimit;
    }

    function setCancelRegisterGasLimit(uint128 _cancelRegisterGasLimit) external override onlyOwner {
        cancelRegisterGasLimit = _cancelRegisterGasLimit;
    }

    /**
     * @dev Internal function to implement lzReceive logic
     */
    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal virtual override {
        MemeverseParam memory param = abi.decode(_message, (MemeverseParam));
        _registerMemeverse(param);
    }
}
