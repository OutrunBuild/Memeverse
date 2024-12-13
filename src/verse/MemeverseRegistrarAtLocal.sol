// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ITokenDeployer } from "../token/deployer/interfaces/ITokenDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrarAtLocal } from "./interfaces/IMemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof (At registration center chain)
 */ 
contract MemeverseRegistrarAtLocal is IMemeverseRegistrarAtLocal, IMemeverseRegistrar, Ownable {
    address public memecoinDeployer;
    address public liquidProofDeployer;
    address public memeverseLauncher;
    address public registrationCenter;

    constructor(
        address _owner,
        address _memecoinDeployer,
        address _liquidProofDeployer,
        address _memeverseLauncher, 
        address _registrationCenter
    ) Ownable(_owner) {
        memecoinDeployer = _memecoinDeployer;
        liquidProofDeployer = _liquidProofDeployer;
        memeverseLauncher = _memeverseLauncher;
        registrationCenter = _registrationCenter;
    }

    /**
     * @dev Register on the chain where the registration center is located
     * @notice Only RegistrationCenter can call
     */
    function registerAtLocal(MemeverseParam calldata param) external override returns (address memecoin, address liquidProof) {
        require(msg.sender == registrationCenter, PermissionDenied());

        return _registerMemeverse(param);
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 /*value*/) external payable override {
        IMemeverseRegistrationCenter(registrationCenter).registration(param);
    }

    function cancelRegistration(uint256 uniqueId, IMemeverseRegistrationCenter.RegistrationParam calldata param, address /*lzRefundAddress*/) external payable override {
        require(msg.sender == memeverseLauncher, PermissionDenied());

        IMemeverseRegistrationCenter(registrationCenter).cancelRegistration(uniqueId, param.symbol);
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

    function setRegistrationCenter(address _registrationCenter) external override onlyOwner {
        require(_registrationCenter != address(0), ZeroAddress());
        
        registrationCenter = _registrationCenter;
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
            name, symbol, param.uri, memecoin, liquidProof, uniqueId, 
            param.endTime, param.unlockTime, param.maxFund, omnichainIds
        );
    }
}
