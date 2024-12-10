// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./BaseScript.s.sol";

import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { ITokenDeployer } from "../src/token/deployer/interfaces/ITokenDeployer.sol";
import { MemecoinDeployer } from "../src/token/deployer/MemecoinDeployer.sol";
import { MemecoinDeployerOnBlast } from "../src/token/deployer/MemecoinDeployerOnBlast.sol";
import { LiquidProofDeployer } from "../src/token/deployer/LiquidProofDeployer.sol";
import { LiquidProofDeployerOnBlast } from "../src/token/deployer/LiquidProofDeployerOnBlast.sol";
import { MemeverseRegistrar } from "../src/verse/MemeverseRegistrar.sol";
import { MemeverseLauncherOnBlast } from "../src/verse/MemeverseLauncherOnBlast.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";


contract MemeverseScript is BaseScript {
    address internal UETH;
    address internal BLAST_GOVERNOR;
    address internal OUTRUN_DEPLOYER;
    address internal MEMEVERSE_LAUNCHER;
    address internal MEMEVERSE_REGISTRAR;

    address internal owner;
    address internal revenuePool;
    address internal factory;
    address internal router;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("OUTRUN_AMM_ROUTER");
        BLAST_GOVERNOR = vm.envAddress("BLAST_GOVERNOR");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");
        MEMEVERSE_LAUNCHER = vm.envAddress("MEMEVERSE_LAUNCHER");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        
        ITokenDeployer.LzEndpointId[] memory endpoints1 = new ITokenDeployer.LzEndpointId[](2);
        endpoints1[0] = ITokenDeployer.LzEndpointId({ chainId: 84532, endpointId: 40245});
        endpoints1[1] = ITokenDeployer.LzEndpointId({ chainId: 168587773, endpointId: 40243});

        ITokenDeployer(0xff33db242D0F89340A436D26964b9b8FE52fe152).setLzEndpointId(endpoints1);
        ITokenDeployer(0x9AE58a261C2381CD3fB4E8aCbbEc142D3126c129).setLzEndpointId(endpoints1);

        // _deployMemeverseRegistrar(2);
        // _getDeployedRegistrar(2);
        // _getDeployedRegistrationCenter(2);
        // _deployTokenDeployer(2);
        // _deployUETHMemeverseLauncher(2);
        // _deployUETHMemeverseLauncherOnBlast(2);
    }

    function _getDeployedRegistrar(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrar deployed on %s", deployed);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrarAtLocal).creationCode,
            abi.encode(
                vm.envAddress("MEMECOIN_DEPLOYER"),
                vm.envAddress("LIQUID_PROOF_DEPLOYER"),
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_REGISTRAR
            )
        );
        address memeverseRegistrarAtLocalAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("memeverseRegistrarAtLocal deployed on %s", memeverseRegistrarAtLocalAddr);
    }

    function _deployTokenDeployer(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory memecoinDeployercreationBytecode;
        bytes memory liquidProofDeployercreationBytecode;
        if (block.chainid == vm.envUint("BLAST_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                BLAST_GOVERNOR,
                vm.envAddress("BLAST_SEPOLIA_ENDPOINT"),
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_REGISTRAR
            );
            memecoinDeployercreationBytecode = type(MemecoinDeployerOnBlast).creationCode;
            liquidProofDeployercreationBytecode = type(LiquidProofDeployerOnBlast).creationCode;
        } else if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BSC_TESTNET_ENDPOINT"),
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_REGISTRAR
            );
            memecoinDeployercreationBytecode = type(MemecoinDeployer).creationCode;
            liquidProofDeployercreationBytecode = type(LiquidProofDeployer).creationCode;
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BASE_SEPOLIA_ENDPOINT"),
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_REGISTRAR
            );
            memecoinDeployercreationBytecode = type(MemecoinDeployer).creationCode;
            liquidProofDeployercreationBytecode = type(LiquidProofDeployer).creationCode;
        }

        bytes memory memecoinDeployerCreationCode = abi.encodePacked(
            memecoinDeployercreationBytecode,
            encodedArgs
        );

        bytes memory liquidProofDeployerCreationCode = abi.encodePacked(
            liquidProofDeployercreationBytecode,
            encodedArgs
        );

        bytes32 memecoinSalt = keccak256(abi.encodePacked("TokenDeployer", "Memecoin", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("TokenDeployer", "LiquidProof", nonce));
        address memecoinDeployerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinSalt, memecoinDeployerCreationCode);
        address liquidProofDeployerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(liquidProofSalt, liquidProofDeployerCreationCode);

        ITokenDeployer.LzEndpointId[] memory endpoints = new ITokenDeployer.LzEndpointId[](2);
        endpoints[0] = ITokenDeployer.LzEndpointId({ chainId: 84532, endpointId: 40245});
        endpoints[1] = ITokenDeployer.LzEndpointId({ chainId: 168587773, endpointId: 40243});
        ITokenDeployer(memecoinDeployerAddr).setLzEndpointId(endpoints);
        ITokenDeployer(liquidProofDeployerAddr).setLzEndpointId(endpoints);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployerAddr);
        console.log("LiquidProofDeployer deployed on %s", liquidProofDeployerAddr);
    }

    function _getDeployedRegistrationCenter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrationCenter deployed on %s", deployed);
    }

    function _deployUETHMemeverseLauncher(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", UETH, nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseLauncher).creationCode,
            abi.encode(
                "UETHMemeverseLauncher",
                "MVS-UETH",
                UETH,
                owner,
                revenuePool,
                factory,
                router,
                1e16,
                1000
            )
        );
        address UETHMemeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHMemeverseLauncher deployed on %s", UETHMemeverseLauncherAddr);
    }

    function _deployUETHMemeverseLauncherOnBlast(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", UETH, nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseLauncherOnBlast).creationCode,
            abi.encode(
                "UETHMemeverseLauncher",
                "MVS-UETH",
                UETH,
                owner,
                BLAST_GOVERNOR,
                revenuePool,
                factory,
                router,
                1e16,
                1000
            )
        );
        address UETHMemeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHMemeverseLauncherOnBlast deployed on %s", UETHMemeverseLauncherAddr);
    }
}
