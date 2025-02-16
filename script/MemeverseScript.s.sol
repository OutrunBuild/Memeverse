// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import "./BaseScript.s.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { Memecoin } from "../src/token/Memecoin.sol";
import { MemeLiquidProof } from "../src/token/MemeLiquidProof.sol";
import { MemecoinYieldVault } from "../src/yield/MemecoinYieldVault.sol";
import { MemecoinDaoGovernor } from "../src/governance/MemecoinDaoGovernor.sol";
import { YieldDispatcher } from "../src/yield/YieldDispatcher.sol";
import { MemecoinDeployer } from "../src/token/deployer/MemecoinDeployer.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { MemeverseRegistrarOmnichain } from "../src/verse/MemeverseRegistrarOmnichain.sol";
import { IMemeverseRegistrar } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { MemeverseRegistrationCenter } from "../src/verse/MemeverseRegistrationCenter.sol";
import { IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";

contract MemeverseScript is BaseScript {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;

    address internal UETH;
    address internal OUTRUN_DEPLOYER;
    address internal MEMECOIN_DEPLOYER;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_REGISTRATION_CENTER;
    address internal MEMECOIN_IMPLEMENTATION;
    address internal POL_IMPLEMENTATION;
    address internal MEMECOIN_VAULT_IMPLEMENTATION;
    address internal MEMECOIN_GOVERNOR_IMPLEMENTATION;
    address internal UETH_YIELD_DISPATCHER;
    address internal UETH_MEMEVERSE_LAUNCHER;
    
    address internal owner;
    address internal signer;
    address internal revenuePool;
    address internal factory;
    address internal router;

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        owner = vm.envAddress("OWNER");
        signer = vm.envAddress("SIGNER");
        revenuePool = vm.envAddress("REVENUE_POOL");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("OUTRUN_AMM_ROUTER");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");
        MEMECOIN_DEPLOYER = vm.envAddress("MEMECOIN_DEPLOYER");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");
        MEMECOIN_IMPLEMENTATION = vm.envAddress("MEMECOIN_IMPLEMENTATION");
        POL_IMPLEMENTATION = vm.envAddress("POL_IMPLEMENTATION");
        MEMECOIN_VAULT_IMPLEMENTATION = vm.envAddress("MEMECOIN_VAULT_IMPLEMENTATION");
        MEMECOIN_GOVERNOR_IMPLEMENTATION = vm.envAddress("MEMECOIN_GOVERNOR_IMPLEMENTATION");
        UETH_YIELD_DISPATCHER = vm.envAddress("UETH_YIELD_DISPATCHER_");
        UETH_MEMEVERSE_LAUNCHER = vm.envAddress("UETH_MEMEVERSE_LAUNCHER");

        // _getDeployedImplementation(6);

        // _getDeployedRegistrationCenter(14);

        // _getDeployedMemecoinDeployer(14);
        // _getDeployedMemeverseRegistrar(14);

        // _getDeployedUETHMemeverseLauncher(14);
        // _getDeployedUETHYieldDispatcher(14);


        // _deployImplementation(6);

        // _deployRegistrationCenter(14);

        _deployMemecoinDeployer(14);
        _deployMemeverseRegistrar(14);

        _deployUETHMemeverseLauncher(14);
        _deployUETHYieldDispatcher(14);
    }

    function _getDeployedImplementation(uint256 nonce) internal view {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("LiquidProofImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        
        address deployedMemecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinSalt);
        address deployedLiquidProofImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, liquidProofSalt);
        address deployedMemecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinYieldVaultSalt);
        address deployedMemecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinDaoGovernorSalt);

        console.log("MemecoinImplementation deployed on %s", deployedMemecoinImplementation);
        console.log("LiquidProofImplementation deployed on %s", deployedLiquidProofImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", deployedMemecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", deployedMemecoinDaoGovernorImplementation);
    }

    function _getDeployedMemecoinDeployer(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemecoinDeployer", nonce));
        address memecoinDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployer);
    }

    function _getDeployedMemeverseRegistrar(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrar deployed on %s", deployed);
    }

    function _getDeployedRegistrationCenter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrationCenter deployed on %s", deployed);
    }

    function _getDeployedUETHMemeverseLauncher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", "UETH", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("UETHMemeverseLauncher deployed on %s", deployed);
    }

    function _getDeployedUETHYieldDispatcher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", "UETH", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("UETHYieldDispatcher deployed on %s", deployed);
    }


    /** DEPLOY **/

    function _deployImplementation(uint256 nonce) internal {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("LiquidProofImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        
        address memecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinSalt, type(Memecoin).creationCode);
        address liquidProofImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(liquidProofSalt, type(MemeLiquidProof).creationCode);
        address memecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinYieldVaultSalt, type(MemecoinYieldVault).creationCode);
        address memecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinDaoGovernorSalt, type(MemecoinDaoGovernor).creationCode);
        
        console.log("MemecoinImplementation deployed on %s", memecoinImplementation);
        console.log("LiquidProofImplementation deployed on %s", liquidProofImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", memecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", memecoinDaoGovernorImplementation);
    }

    function _deployMemecoinDeployer(uint256 nonce) internal {
        address localEndpoint;
       if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            localEndpoint = vm.envAddress("BSC_TESTNET_ENDPOINT");
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            localEndpoint = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        } else if (block.chainid == vm.envUint("SCROLL_SEPOLIA_CHAINID")) {
            localEndpoint = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        }

        bytes memory encodedArgs = abi.encode(
            owner,
            localEndpoint,
            MEMEVERSE_REGISTRAR,
            MEMECOIN_IMPLEMENTATION
        );

        bytes memory creationCode = abi.encodePacked(
            type(MemecoinDeployer).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("MemecoinDeployer", nonce));
        address memecoinDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployer);
    }

    function _deployRegistrationCenter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(
                owner,
                vm.envAddress("BSC_TESTNET_ENDPOINT"),
                MEMEVERSE_REGISTRAR
            )
        );
        address centerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        // Testnet id
        IMemeverseRegistrationCenter.LzEndpointIdPair[] memory endpointPairs = new IMemeverseRegistrationCenter.LzEndpointIdPair[](2);
        endpointPairs[0] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: 84532, endpointId: 40245});
        endpointPairs[1] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: 534351, endpointId: 40170});
        IMemeverseRegistrationCenter(centerAddr).setLzEndpointIds(endpointPairs);

        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimit(600000);
        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 3);
        IMemeverseRegistrationCenter(centerAddr).setLockupDaysRange(1, 365);

        IOAppCore(centerAddr).setPeer(uint32(vm.envUint("BASE_SEPOLIA_EID")), bytes32(abi.encode(MEMEVERSE_REGISTRAR)));
        IOAppCore(centerAddr).setPeer(uint32(vm.envUint("SCROLL_SEPOLIA_EID")), bytes32(abi.encode(MEMEVERSE_REGISTRAR)));

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        address endpoint;
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                MEMEVERSE_REGISTRATION_CENTER,
                MEMECOIN_DEPLOYER
            );
            creationBytecode = type(MemeverseRegistrarAtLocal).creationCode;
        } else {
            if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
                endpoint = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
            } else if (block.chainid == vm.envUint("SCROLL_SEPOLIA_CHAINID")) {
                endpoint = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
            }
            encodedArgs = abi.encode(
                owner,
                endpoint,
                MEMECOIN_DEPLOYER,
                uint32(vm.envUint("BSC_TESTNET_EID")),
                uint32(vm.envUint("BSC_TESTNET_CHAINID")),
                100000,
                500000,
                250000,
                250000
            );
            creationBytecode = type(MemeverseRegistrarOmnichain).creationCode;
        }

        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        bytes memory creationCode = abi.encodePacked(
            creationBytecode,
            encodedArgs
        );
        address memeverseRegistrarAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);
        console.log("MemeverseRegistrar deployed on %s", memeverseRegistrarAddr);

        IMemeverseRegistrar.UPTLauncherPair[] memory pairs = new IMemeverseRegistrar.UPTLauncherPair[](1);
        pairs[0] = IMemeverseRegistrar.UPTLauncherPair({ upt: UETH, memeverseLauncher: UETH_MEMEVERSE_LAUNCHER});
        IMemeverseRegistrar(memeverseRegistrarAddr).setUPTLauncher(pairs);

        if (block.chainid != vm.envUint("BSC_TESTNET_CHAINID")) {
            IOAppCore(memeverseRegistrarAddr).setPeer(
                uint32(vm.envUint("BSC_TESTNET_EID")), 
                bytes32(abi.encode(MEMEVERSE_REGISTRATION_CENTER))
            );
        }

        // TODO Testnet id
        IMemeverseRegistrar.LzEndpointIdPair[] memory endpointPairs = new IMemeverseRegistrar.LzEndpointIdPair[](3);
        endpointPairs[0] = IMemeverseRegistrar.LzEndpointIdPair({ chainId: 97, endpointId: 40102});
        endpointPairs[1] = IMemeverseRegistrar.LzEndpointIdPair({ chainId: 84532, endpointId: 40245});
        endpointPairs[2] = IMemeverseRegistrar.LzEndpointIdPair({ chainId: 534351, endpointId: 40170});
        IMemeverseRegistrar(memeverseRegistrarAddr).setLzEndpointIds(endpointPairs);
    }

    function _deployUETHMemeverseLauncher(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            UETH,
            owner,
            signer,
            revenuePool,
            factory,
            router,
            MEMEVERSE_REGISTRAR,
            POL_IMPLEMENTATION,
            MEMECOIN_VAULT_IMPLEMENTATION,
            MEMECOIN_GOVERNOR_IMPLEMENTATION,
            UETH_YIELD_DISPATCHER,
            1e19,
            1000000,
            10,
            60000,
            300000
        );
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseLauncher).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", "UETH", nonce));
        address UETHMemeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHMemeverseLauncher deployed on %s", UETHMemeverseLauncherAddr);
    }

    function _deployUETHYieldDispatcher(uint256 nonce) internal {
        address localEndpoint;
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            localEndpoint = vm.envAddress("BSC_TESTNET_ENDPOINT");
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            localEndpoint = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        } else if (block.chainid == vm.envUint("SCROLL_SEPOLIA_CHAINID")) {
            localEndpoint = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        }

        bytes memory creationCode = abi.encodePacked(
            type(YieldDispatcher).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                UETH_MEMEVERSE_LAUNCHER,
                revenuePool,
                1000
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", "UETH", nonce));
        address UETHYieldDispatcher = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHYieldDispatcher deployed on %s", UETHYieldDispatcher);
    }
}
