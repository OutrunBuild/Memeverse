// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

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
    
    RegistrationGasLimit public registrationGasLimit;

    /**
     * @dev Constructor
     * @param _owner - The owner of the contract
     * @param _localEndpoint - The local endpoint
     * @param _registrationCenterEid - The registration center eid
     * @param _registrationCenterChainid - The registration center chainid
     * @param _baseRegistrationGasLimit - The base registration gas limit
     * @param _localRegistrationGasLimit - The local registration gas limit
     * @param _omnichainRegistrationGasLimit - The omnichain registration gas limit
     */
    constructor(
        address _owner,
        address _localEndpoint,
        address _memeverseLauncher,
        address _memeverseCommonInfo,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid,
        uint80 _baseRegistrationGasLimit,
        uint80 _localRegistrationGasLimit,
        uint80 _omnichainRegistrationGasLimit
    ) MemeverseRegistrarAbstract(_owner, _memeverseLauncher, _memeverseCommonInfo) OApp(_localEndpoint, _owner) {
        REGISTRATION_CENTER_EID = _registrationCenterEid;
        REGISTRATION_CENTER_CHAINID = _registrationCenterChainid;

        registrationGasLimit = RegistrationGasLimit({
            baseRegistrationGasLimit: _baseRegistrationGasLimit,
            localRegistrationGasLimit: _localRegistrationGasLimit,
            omnichainRegistrationGasLimit: _omnichainRegistrationGasLimit
        });
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
        RegistrationGasLimit memory _registrationGasLimit = registrationGasLimit;
        uint80 gasLimit = _registrationGasLimit.baseRegistrationGasLimit;
        for (uint256 i = 0; i < length; i++) {
            if (param.omnichainIds[i] == REGISTRATION_CENTER_CHAINID) {
                gasLimit += _registrationGasLimit.localRegistrationGasLimit;
            } else {
                gasLimit += _registrationGasLimit.omnichainRegistrationGasLimit;
            }
        }
        
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, value);
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
        bytes memory message = abi.encode(param);
        uint256 length = param.omnichainIds.length;
        RegistrationGasLimit memory _registrationGasLimit = registrationGasLimit;
        uint80 gasLimit = _registrationGasLimit.baseRegistrationGasLimit;
        for (uint256 i = 0; i < length; i++) {
            if (param.omnichainIds[i] == REGISTRATION_CENTER_CHAINID) {
                gasLimit += _registrationGasLimit.localRegistrationGasLimit;
            } else {
                gasLimit += _registrationGasLimit.omnichainRegistrationGasLimit;
            }
        }

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, value);
        uint256 lzFee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
        require(msg.value >= lzFee, InsufficientLzFee());

        _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender);
    }

    /**
     * @dev Set the registration gas limit
     * @param _registrationGasLimit - The registration gas limit
     */
    function setRegistrationGasLimit(RegistrationGasLimit calldata _registrationGasLimit) external override onlyOwner {
        registrationGasLimit = _registrationGasLimit;

        emit SetRegistrationGasLimit(_registrationGasLimit);
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
