// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "solmate/src/utils/CREATE3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import { Memecoin } from "./Memecoin.sol";
import { MemeLiquidProof } from "./MemeLiquidProof.sol";
import { LzMessageConfig } from "../common/LzMessageConfig.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof
 */ 
contract MemeverseRegistrar is IMemeverseRegistrar, OApp, LzMessageConfig {
    using OptionsBuilder for bytes;

    address public immutable REGISTRATION_CENTER;
    address public immutable LOCAL_LZ_ENDPOINT;
    address public immutable LOCAL_SEND_LIBRARY;
    address public immutable LOCAL_RECEIVE_LIBRARY;
    address public immutable MEMEVERSE_LAUNCHER;
    uint128 public immutable REGISTER_GAS_LIMIT;
    uint128 public immutable CANCEL_REGISTER_GAS_LIMIT;
    uint32 public immutable REGISTRATION_CENTER_EID;
    uint32 public immutable REGISTRATION_CENTER_CHAINID;

    mapping(uint32 chainId => uint32) endpointIds;

    constructor(
        address _owner, 
        address _localLzEndpoint, 
        address _localSendLibrary, 
        address _localReceiveLibrary, 
        address _memeverseLauncher, 
        address _registrationCenter, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid
    ) OApp(_localLzEndpoint, _owner) Ownable(_owner) {
        REGISTRATION_CENTER = _registrationCenter;
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        LOCAL_SEND_LIBRARY = _localSendLibrary;
        LOCAL_RECEIVE_LIBRARY = _localReceiveLibrary;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        REGISTER_GAS_LIMIT = _registerGasLimit;
        CANCEL_REGISTER_GAS_LIMIT = _cancelRegisterGasLimit;
        REGISTRATION_CENTER_EID = _registrationCenterEid;
        REGISTRATION_CENTER_CHAINID = _registrationCenterChainid;
    }

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external override onlyOwner {
        for (uint256 i = 0; i < endpoints.length; i++) {
            endpointIds[endpoints[i].chainId] = endpoints[i].endpointId;
        }
    }

    /**
     * @dev Register on the chain where the registration center is located
     * @notice Only RegistrationCenter can call
     */
    function registerAtLocal(MemeverseParam calldata param) external returns (address memecoin, address liquidProof) {
        require(
            block.chainid == REGISTRATION_CENTER_CHAINID || 
            msg.sender == REGISTRATION_CENTER, 
            PermissionDenied()
        );

        return _registerMemeverse(param);
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(uint256 uniqueId, IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable override {
        require(block.chainid != REGISTRATION_CENTER_CHAINID, PermissionDenied());

        if (block.chainid == REGISTRATION_CENTER_CHAINID) {
            IMemeverseRegistrationCenter(REGISTRATION_CENTER).registration(param);
        } else {
            bytes memory message = abi.encode(uniqueId, param);
            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(REGISTER_GAS_LIMIT, value);
            uint256 fee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
            require(msg.value >= fee, InsufficientFee());

            _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), msg.sender);
        }
    }

    function cancelRegistration(uint256 uniqueId, IMemeverseRegistrationCenter.RegistrationParam calldata param, address lzRefundAddress) external payable override {
        require(msg.sender == MEMEVERSE_LAUNCHER, PermissionDenied());

        if (block.chainid == REGISTRATION_CENTER_CHAINID) {
            IMemeverseRegistrationCenter(REGISTRATION_CENTER).cancelRegistration(uniqueId, param.symbol);
        } else {
            bytes memory message = abi.encode(uniqueId, param);
            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(CANCEL_REGISTER_GAS_LIMIT , 0);
            uint256 fee = _quote(REGISTRATION_CENTER_EID, message, options, false).nativeFee;
            require(msg.value >= fee, InsufficientFee());

            _lzSend(REGISTRATION_CENTER_EID, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), lzRefundAddress);
        }
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

    function _registerMemeverse(MemeverseParam memory param) internal returns (address memecoin, address liquidProof) {
        string memory name = param.name;
        string memory symbol = param.symbol;
        uint256 uniqueId = param.uniqueId;
        uint32[] memory omnichainIds = param.omnichainIds;

        // deploy memecoin and liquidProof
        (memecoin, liquidProof) = _deployMemecoinAndLiquidProof(name, symbol, uniqueId, param.creator);
        _lzConfigure(memecoin, liquidProof, omnichainIds);

        // register
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).registerMemeverse(
            name, symbol, param.uri, memecoin, liquidProof, uniqueId, 
            param.endTime, param.unlockTime, param.maxFund, omnichainIds
        );
    }

    /// @dev Deploy Memecoin and LiquidProof on the current chain simultaneously
    function _deployMemecoinAndLiquidProof(
        string memory name, 
        string memory symbol,
        uint256 uniqueId,
        address creator
    ) internal returns (address memecoin, address liquidProof) {
        bytes memory constructorArgs = abi.encode(name, symbol, 18, MEMEVERSE_LAUNCHER, LOCAL_LZ_ENDPOINT, address(this));
        bytes memory initCode = abi.encodePacked(type(Memecoin).creationCode, constructorArgs);
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId));
        memecoin = CREATE3.deploy(salt, initCode, msg.value);

        constructorArgs = abi.encode(
            string(abi.encodePacked(name, " Liquid")), 
            string(abi.encodePacked(symbol, " LIQUID")), 
            18, 
            memecoin, 
            MEMEVERSE_LAUNCHER, 
            LOCAL_LZ_ENDPOINT,
            address(this)
        );
        initCode = abi.encodePacked(type(MemeLiquidProof).creationCode, constructorArgs);
        liquidProof = CREATE3.deploy(salt, initCode, msg.value);
    }

    /// @dev Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
    function _lzConfigure(address memecoin, address liquidProof, uint32[] memory omnichainIds) internal {
        bytes memory defaultExecutorConfig = abi.encode(
            ExecutorConfig({
                maxMessageSize: 0,
                executor: address(0)
            })
        );

        bytes memory defaultUlnConfig = abi.encode(
            UlnConfig({
                confirmations: 0,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            })
        );

        SetConfigParam[] memory sendConfigParams = new SetConfigParam[](0);
        SetConfigParam[] memory receiveConfigParams = new SetConfigParam[](0);
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, InvalidOmnichainId(omnichainId));

            append(sendConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 1,
                config: defaultExecutorConfig
            }));

            append(sendConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: defaultUlnConfig
            }));

            append(receiveConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: defaultUlnConfig
            }));

            IOAppCore(memecoin).setPeer(endpointId, bytes32(uint256(uint160(memecoin))));
            IOAppCore(liquidProof).setPeer(endpointId, bytes32(uint256(uint160(liquidProof))));
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setSendLibrary(memecoin, endpointId, LOCAL_SEND_LIBRARY);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setReceiveLibrary(memecoin, endpointId, LOCAL_RECEIVE_LIBRARY, 0);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setSendLibrary(liquidProof, endpointId, LOCAL_SEND_LIBRARY);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setReceiveLibrary(liquidProof, endpointId, LOCAL_RECEIVE_LIBRARY, 0);
        }

        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(memecoin, LOCAL_SEND_LIBRARY, sendConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(liquidProof, LOCAL_SEND_LIBRARY, sendConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(memecoin, LOCAL_RECEIVE_LIBRARY, receiveConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(liquidProof, LOCAL_RECEIVE_LIBRARY, receiveConfigParams);
    }
}
