// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { ITokenDeployer } from "../token/deployer/interfaces/ITokenDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof
 */ 
contract MemeverseRegistrar is IMemeverseRegistrar, OApp {
    using OptionsBuilder for bytes;
    
    address public immutable MEMECOIN_DEPLOYER;
    address public immutable LIQUID_PROOF_DEPLOYER;
    address public immutable REGISTRATION_CENTER;
    address public immutable MEMEVERSE_LAUNCHER;
    uint128 public immutable REGISTER_GAS_LIMIT;
    uint128 public immutable CANCEL_REGISTER_GAS_LIMIT;
    uint32 public immutable REGISTRATION_CENTER_EID;
    uint32 public immutable REGISTRATION_CENTER_CHAINID;

    constructor(
        address _owner, 
        address _localLzEndpoint, 
        address _memecoinDeployer,
        address _liquidProofDeployer,
        address _memeverseLauncher, 
        address _registrationCenter, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid,
        uint32 _registrationCenterChainid
    ) OApp(_localLzEndpoint, _owner) Ownable(_owner) {
        MEMECOIN_DEPLOYER = _memecoinDeployer;
        LIQUID_PROOF_DEPLOYER = _liquidProofDeployer;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        REGISTRATION_CENTER = _registrationCenter;

        REGISTER_GAS_LIMIT = _registerGasLimit;
        CANCEL_REGISTER_GAS_LIMIT = _cancelRegisterGasLimit;
        REGISTRATION_CENTER_EID = _registrationCenterEid;
        REGISTRATION_CENTER_CHAINID = _registrationCenterChainid;
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

        // deploy memecoin, liquidProof and configure layerzero
        memecoin = ITokenDeployer(MEMECOIN_DEPLOYER).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, omnichainIds);
        liquidProof = ITokenDeployer(LIQUID_PROOF_DEPLOYER).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, omnichainIds);

        // register
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).registerMemeverse(
            name, symbol, param.uri, memecoin, liquidProof, uniqueId, 
            param.endTime, param.unlockTime, param.maxFund, omnichainIds
        );
    }
}
