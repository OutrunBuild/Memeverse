// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ITokenDeployer } from "../token/deployer/interfaces/ITokenDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */ 
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, Ownable {
    address public memecoinDeployer;
    address public liquidProofDeployer;

    mapping(address UPT => address memeverseLauncher) public uptToLauncher;
    mapping(address memeverseLauncher => address UPT) public launcherToUPT;

    constructor(
        address _owner,
        address _memecoinDeployer,
        address _liquidProofDeployer
    ) Ownable(_owner) {
        memecoinDeployer = _memecoinDeployer;
        liquidProofDeployer = _liquidProofDeployer;
    }

    function setMemecoinDeployer(address _memecoinDeployer) external override onlyOwner {
        require(_memecoinDeployer != address(0), ZeroAddress());

        memecoinDeployer = _memecoinDeployer;
    }

    function setLiquidProofDeployer(address _liquidProofDeployer) external override onlyOwner {
        require(_liquidProofDeployer != address(0), ZeroAddress());
        
        liquidProofDeployer = _liquidProofDeployer;
    }

    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            UPTLauncherPair calldata pair = pairs[i];
            if (pair.upt == address(0) || pair.memeverseLauncher == address(0)) continue;

            uptToLauncher[pair.upt] = pair.memeverseLauncher;
            launcherToUPT[pair.memeverseLauncher] = pair.upt;
        }
    }

    function registerAtCenter(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) virtual external payable;

    function cancelRegistration(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress
    ) virtual external payable;

    function _registerMemeverse(MemeverseParam memory param) internal returns (address memecoin, address liquidProof) {
        string memory name = param.name;
        string memory symbol = param.symbol;
        uint256 uniqueId = param.uniqueId;
        uint32[] memory omnichainIds = param.omnichainIds;
        address memeverseLauncher = uptToLauncher[param.upt];

        // deploy memecoin, liquidProof and configure layerzero
        memecoin = ITokenDeployer(memecoinDeployer).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, memeverseLauncher, omnichainIds);
        liquidProof = ITokenDeployer(liquidProofDeployer).deployTokenAndConfigure(name, symbol, uniqueId, param.creator, memecoin, memeverseLauncher, omnichainIds);

        // register
        IMemeverseLauncher(memeverseLauncher).registerMemeverse(
            name, symbol, param.uri, param.creator, memecoin, liquidProof, uniqueId, 
            param.endTime, param.unlockTime, param.maxFund, omnichainIds
        );
    }
}
