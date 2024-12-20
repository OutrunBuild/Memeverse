// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MemeverseRegistrarAbstract } from "./MemeverseRegistrarAbstract.sol";
import { IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseRegistrarAtLocal } from "./interfaces/IMemeverseRegistrarAtLocal.sol";

/**
 * @title Local MemeverseRegistrar for deploying memecoin, liquidProof and registering memeverse
 */ 
contract MemeverseRegistrarAtLocal is IMemeverseRegistrarAtLocal, MemeverseRegistrarAbstract {
    address public registrationCenter;

    constructor(
        address _owner, 
        address _registrationCenter, 
        address _memecoinDeployer, 
        address _liquidProofDeployer
    ) MemeverseRegistrarAbstract(
        _owner,
        _memecoinDeployer,
        _liquidProofDeployer
    ) {
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

    function cancelRegistration(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address /*lzRefundAddress*/
    ) external payable override {
        require(launcherToUPT[msg.sender] != address(0), PermissionDenied());

        IMemeverseRegistrationCenter(registrationCenter).cancelRegistration(uniqueId, param.symbol);
    }

    function setRegistrationCenter(address _registrationCenter) external override onlyOwner {
        require(_registrationCenter != address(0), ZeroAddress());
        
        registrationCenter = _registrationCenter;
    }
}
