// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { ITokenDeployer } from "../token/deployer/interfaces/ITokenDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrarOmnichain } from "./interfaces/IMemeverseRegistrarOmnichain.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof
 */ 
contract MemeverseRegistrarOmnichain is IMemeverseRegistrarOmnichain, IMemeverseRegistrar, OApp {
    using OptionsBuilder for bytes;

    uint32 public immutable REGISTRATION_CENTER_EID;
    
    uint128 public registerGasLimit;
    uint128 public cancelRegisterGasLimit;
    address public signer;
    address public memecoinDeployer;
    address public liquidProofDeployer;
    address public memeverseLauncher;

    constructor(
        address _owner, 
        address _signer,
        address _localLzEndpoint, 
        address _memecoinDeployer,
        address _liquidProofDeployer,
        address _memeverseLauncher, 
        uint128 _registerGasLimit,
        uint128 _cancelRegisterGasLimit,
        uint32 _registrationCenterEid
    ) OApp(_localLzEndpoint, _owner) Ownable(_owner) {
        signer = _signer;
        memecoinDeployer = _memecoinDeployer;
        liquidProofDeployer = _liquidProofDeployer;
        memeverseLauncher = _memeverseLauncher;
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
        address lzRefundAddress,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable override {
        uint256 currentTime = block.timestamp;
        require(currentTime > deadline, ExpiredSignature(deadline));

        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(uniqueId, deadline))
        );
        require(signer == ECDSA.recover(signedHash, v, r, s), InvalidSigner());

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

    function setMemecoinDeployer(address _memecoinDeployer) external override onlyOwner {
        require(_memecoinDeployer != address(0), ZeroAddress());

        memecoinDeployer = _memecoinDeployer;
    }

    function setLiquidProofDeployer(address _liquidProofDeployer) external override onlyOwner {
        require(_liquidProofDeployer != address(0), ZeroAddress());
        
        liquidProofDeployer = _liquidProofDeployer;
    }

    function setMemeverseLauncher(address _memeverseLauncher) external override onlyOwner {
        require(_memeverseLauncher != address(0), ZeroAddress());
        
        memeverseLauncher = _memeverseLauncher;
    }

    function updateSigner(address _signer) external override onlyOwner {
        require(_signer != address(0), ZeroAddress());
        
        signer = _signer;
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
        memecoin = ITokenDeployer(memecoinDeployer).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, omnichainIds);
        liquidProof = ITokenDeployer(liquidProofDeployer).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, omnichainIds);

        // register
        IMemeverseLauncher(memeverseLauncher).registerMemeverse(
            name, symbol, param.uri, param.creator, memecoin, liquidProof, uniqueId, 
            param.endTime, param.unlockTime, param.maxFund, omnichainIds
        );
    }
}
