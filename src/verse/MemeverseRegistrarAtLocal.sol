// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MemeverseRegistrarAbstract } from "./MemeverseRegistrarAbstract.sol";
import { IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseRegistrarAtLocal } from "./interfaces/IMemeverseRegistrarAtLocal.sol";

/**
 * @title Local MemeverseRegistrar for deploying memecoin and registering memeverse
 */ 
contract MemeverseRegistrarAtLocal is IMemeverseRegistrarAtLocal, MemeverseRegistrarAbstract {
    address public registrationCenter;

    constructor(
        address _owner, 
        address _registrationCenter, 
        address _memecoinDeployer
    ) MemeverseRegistrarAbstract(
        _owner,
        _memecoinDeployer
    ) {
        registrationCenter = _registrationCenter;
    }

    /**
     * @dev On the same chain, the registration center directly calls this method
     * @notice Only RegistrationCenter can call
     */
    function localRegistration(MemeverseParam calldata param) external override returns (address memecoin) {
        require(msg.sender == registrationCenter, PermissionDenied());

        return _registerMemeverse(param);
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     * @param value - The gas cost required for omni-chain registration at the registration center, 
     *                can be estimated through the LayerZero API on the registration center contract.
     *                The value must be sufficient, otherwise, the registration will fail, and the 
     *                consumed gas will not be refunded.
     * @notice Only users can call this method.
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable override {
        IMemeverseRegistrationCenter(registrationCenter).registration{value: value}(param);
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
