// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { MemeverseRegistrarAbstract } from "./MemeverseRegistrarAbstract.sol";
import { IMemeverseRegistrarAtLocal } from "./interfaces/IMemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Local MemeverseRegistrar for deploying memecoin and registering memeverse
 */ 
contract MemeverseRegistrarAtLocal is IMemeverseRegistrarAtLocal, MemeverseRegistrarAbstract {
    uint256 public constant DAY = 24 * 3600;

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
     * @dev Quote the LayerZero fee for the registration at the registration center.
     * @param param - The registration parameter.
     * @return lzFee - The LayerZero fee for the registration at the registration center.
         */
    function quoteRegister(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 /*value*/
    ) external view override returns (uint256 lzFee) {
        IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, block.timestamp, msg.sender))),
            endTime: uint64(block.timestamp + param.durationDays * DAY),
            unlockTime: uint64(block.timestamp + param.lockupDays * DAY),
            omnichainIds: param.omnichainIds,
            creator: param.creator,
            upt: param.upt
        });
        (lzFee, , ) = IMemeverseRegistrationCenter(registrationCenter).quoteSend(param.omnichainIds, abi.encode(memeverseParam));
    }

    /**
     * @dev Quote the LayerZero fee for the cancellation of the registration at the registration center.
     * @return lzFee - The LayerZero fee for the cancellation of the registration at the registration center.
     */
    function quoteCancel(
        uint256 /*uniqueId*/, 
        IMemeverseRegistrationCenter.RegistrationParam calldata /*param*/
    ) external view onlyMemeverseLauncher returns (uint256 lzFee) {
        return 0;
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
    ) external payable onlyMemeverseLauncher override {
        IMemeverseRegistrationCenter(registrationCenter).cancelRegistration(uniqueId, param.symbol);
    }

    function setRegistrationCenter(address _registrationCenter) external override onlyOwner {
        require(_registrationCenter != address(0), ZeroAddress());
        
        registrationCenter = _registrationCenter;
    }
}
