// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { ITokenDeployer } from "../token/deployer/interfaces/ITokenDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrarAtLocal } from "./interfaces/IMemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title Omnichain Factory for deploying memecoin and liquidProof (At registration center chain)
 */ 
contract MemeverseRegistrarAtLocal is IMemeverseRegistrarAtLocal, IMemeverseRegistrar {
    address public immutable MEMECOIN_DEPLOYER;
    address public immutable LIQUID_PROOF_DEPLOYER;
    address public immutable REGISTRATION_CENTER;
    address public immutable MEMEVERSE_LAUNCHER;

    constructor(
        address _memecoinDeployer,
        address _liquidProofDeployer,
        address _memeverseLauncher, 
        address _registrationCenter
    ) {
        MEMECOIN_DEPLOYER = _memecoinDeployer;
        LIQUID_PROOF_DEPLOYER = _liquidProofDeployer;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        REGISTRATION_CENTER = _registrationCenter;
    }

    /**
     * @dev Register on the chain where the registration center is located
     * @notice Only RegistrationCenter can call
     */
    function registerAtLocal(MemeverseParam calldata param) external override returns (address memecoin, address liquidProof) {
        require(msg.sender == REGISTRATION_CENTER, PermissionDenied());

        return _registerMemeverse(param);
    }

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 /*value*/) external payable override {
        IMemeverseRegistrationCenter(REGISTRATION_CENTER).registration(param);
    }

    function cancelRegistration(uint256 uniqueId, IMemeverseRegistrationCenter.RegistrationParam calldata param, address /*lzRefundAddress*/) external payable override {
        require(msg.sender == MEMEVERSE_LAUNCHER, PermissionDenied());

        IMemeverseRegistrationCenter(REGISTRATION_CENTER).cancelRegistration(uniqueId, param.symbol);
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
