// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { MemeverseRegistrarAbstract } from "./MemeverseRegistrarAbstract.sol";
import { IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseRegistrarOmnichain } from "./interfaces/IMemeverseRegistrarOmnichain.sol";

/**
 * @title Omnichain MemeverseRegistrar for deploying memecoin and registering memeverse
 */ 
contract MemeverseRegistrarOmnichain is IMemeverseRegistrarOmnichain, MemeverseRegistrarAbstract, OApp {
    using OptionsBuilder for bytes;

    uint32 public immutable REGISTRATION_CENTER_EID;
    uint32 public immutable REGISTRATION_CENTER_CHAINID;
    
    uint64 public baseRegisterGasLimit;
    uint64 public localRegisterGasLimit;
    uint64 public omnichainRegisterGasLimit;
    uint64 public cancelRegisterGasLimit;

    constructor(
        address _owner,
        address _localLzEndpoint,
        address _memecoinDeployer,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid,
        uint64 _baseRegisterGasLimit,
        uint64 _localRegisterGasLimit,
        uint64 _omnichainRegisterGasLimit,
        uint64 _cancelRegisterGasLimit
    ) MemeverseRegistrarAbstract(
        _owner,
        _memecoinDeployer
    ) OApp(_localLzEndpoint, _owner) {
        REGISTRATION_CENTER_EID = _registrationCenterEid;
        REGISTRATION_CENTER_CHAINID = _registrationCenterChainid;

        baseRegisterGasLimit = _baseRegisterGasLimit;
        localRegisterGasLimit = _localRegisterGasLimit;
        omnichainRegisterGasLimit = _omnichainRegisterGasLimit;
        cancelRegisterGasLimit = _cancelRegisterGasLimit;
    }

    /**
     * @dev Quote the LayerZero fee for the registration at the registration center.
     * @param param - The registration parameter.
     * @param value - The gas cost required for omni-chain registration at the registration center, 
     *                can be estimated through the LayerZero API on the registration center contract.
     * @return lzFee - The LayerZero fee for the registration at the registration center.
         */
    function quoteRegister(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) external view override returns (uint256 lzFee) {
        bytes memory message = abi.encode(0, param);
        uint256 length = param.omnichainIds.length;
        uint64 gasLimit = baseRegisterGasLimit;
        for (uint256 i = 0; i < length; i++) {
            if (param.omnichainIds[i] == REGISTRATION_CENTER_CHAINID) {
                gasLimit += localRegisterGasLimit;
            } else {
                gasLimit += omnichainRegisterGasLimit;
            }
        }
        
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, value);
        lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
    }

    /**
     * @dev Quote the LayerZero fee for the cancellation of the registration at the registration center.
     * @param uniqueId - The unique identifier of the registration.
     * @param param - The registration parameter.
     * @return lzFee - The LayerZero fee for the cancellation of the registration at the registration center.
     */
    function quoteCancel(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param
    ) external view onlyMemeverseLauncher returns (uint256 lzFee) {
        bytes memory message = abi.encode(uniqueId, param);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(cancelRegisterGasLimit , 0);
        lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     * @param value - The gas cost required for omni-chain registration at the registration center, 
     *                can be estimated through the LayerZero API on the registration center contract.
     *                The value must be sufficient, it is recommended that the value be slightly higher
     *                than the quote value, otherwise, the registration may fail, and the consumed gas
     *                will not be refunded.
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable override {
        bytes memory message = abi.encode(0, param);
        uint256 length = param.omnichainIds.length;
        uint64 gasLimit = baseRegisterGasLimit;
        for (uint256 i = 0; i < length; i++) {
            if (param.omnichainIds[i] == REGISTRATION_CENTER_CHAINID) {
                gasLimit += localRegisterGasLimit;
            } else {
                gasLimit += omnichainRegisterGasLimit;
            }
        }

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, value);
        uint256 lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
        require(msg.value >= lzFee, InsufficientLzFee());

        _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender);
    }

    function cancelRegistration(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress
    ) external payable onlyMemeverseLauncher override {
        bytes memory message = abi.encode(uniqueId, param);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(cancelRegisterGasLimit , 0);
        uint256 lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
        require(msg.value >= lzFee, InsufficientLzFee());

        _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), lzRefundAddress);
    }

    function setBaseRegisterGasLimit(uint64 _baseRegisterGasLimit) external override onlyOwner {
        baseRegisterGasLimit = _baseRegisterGasLimit;
    }

    function setLocalRegisterGasLimit(uint64 _localRegisterGasLimit) external override onlyOwner {
        localRegisterGasLimit = _localRegisterGasLimit;
    }
    
    function setOmnichainRegisterGasLimit(uint64 _omnichainRegisterGasLimit) external override onlyOwner {
        omnichainRegisterGasLimit = _omnichainRegisterGasLimit;
    }

    function setCancelRegisterGasLimit(uint64 _cancelRegisterGasLimit) external override onlyOwner {
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
