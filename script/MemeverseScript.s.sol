// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import "./BaseScript.s.sol";
import { Memecoin } from "../src/token/Memecoin.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { MemeLiquidProof } from "../src/token/MemeLiquidProof.sol";
import { YieldDispatcher } from "../src/yield/YieldDispatcher.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { MemecoinYieldVault } from "../src/yield/MemecoinYieldVault.sol";
import { MemecoinDeployer } from "../src/token/deployer/MemecoinDeployer.sol";
import { MemecoinDaoGovernor } from "../src/governance/MemecoinDaoGovernor.sol";
import { IMemeverseRegistrar } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { MemeverseRegistrationCenter } from "../src/verse/MemeverseRegistrationCenter.sol";
import { MemeverseRegistrarOmnichain } from "../src/verse/MemeverseRegistrarOmnichain.sol";
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

    uint32[] public omnichainIds;
    mapping(uint32 chainId => uint32) public endpointIds;

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

        // OutrunTODO Testnet id
        omnichainIds = [97, 84532, 534351];
        endpointIds[97] = 40102;
        endpointIds[84532] = 40245;
        endpointIds[534351] = 40170;

        // _getDeployedImplementation(6);

        // _getDeployedRegistrationCenter(28);

        // _getDeployedMemecoinDeployer(28);
        // _getDeployedMemeverseRegistrar(28);

        // _getDeployedUETHMemeverseLauncher(28);
        // _getDeployedUETHYieldDispatcher(28);


        // _deployImplementation(6);

        // _deployRegistrationCenter(28);

        _deployMemecoinDeployer(28);
        _deployMemeverseRegistrar(28);

        _deployUETHMemeverseLauncher(28);
        _deployUETHYieldDispatcher(28);
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
        address localEndpoint = vm.envAddress("BSC_TESTNET_ENDPOINT");
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_REGISTRAR
            )
        );
        address centerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        uint256 chainCount = omnichainIds.length;
        IMemeverseRegistrationCenter.LzEndpointIdPair[] memory endpointIdPairs = new IMemeverseRegistrationCenter.LzEndpointIdPair[](chainCount);
        for (uint32 i = 0; i < chainCount; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            endpointIdPairs[i] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: chainId, endpointId: endpointId});
            if (block.chainid == chainId) continue;

            IOAppCore(centerAddr).setPeer(endpointId, bytes32(abi.encode(MEMEVERSE_REGISTRAR)));

            UlnConfig memory config = UlnConfig({
                confirmations: 1,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            });
            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: abi.encode(config)
            });

            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(centerAddr, endpointId);
            console.log("SendLibrary is %s", sendLib);
            (address receiveLib, ) = IMessageLibManager(localEndpoint).getReceiveLibrary(centerAddr, endpointId);
            console.log("ReceiveLibrary is %s", receiveLib);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, receiveLib, params);
        }

        IMemeverseRegistrationCenter(centerAddr).setLzEndpointIds(endpointIdPairs);
        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimit(800000);
        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 3);
        IMemeverseRegistrationCenter(centerAddr).setLockupDaysRange(1, 365);

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        address endpoint;
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BSC_TESTNET_ENDPOINT"),
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
            uint32 centerEndpointId = uint32(vm.envUint("BSC_TESTNET_EID"));
            IOAppCore(memeverseRegistrarAddr).setPeer(
                centerEndpointId, 
                bytes32(abi.encode(MEMEVERSE_REGISTRATION_CENTER))
            );

            UlnConfig memory config = UlnConfig({
                confirmations: 1,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            });
            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({
                eid: centerEndpointId,
                configType: 2,
                config: abi.encode(config)
            });

            address sendLib = IMessageLibManager(endpoint).getSendLibrary(memeverseRegistrarAddr, centerEndpointId);
            (address receiveLib, ) = IMessageLibManager(endpoint).getReceiveLibrary(memeverseRegistrarAddr, centerEndpointId);
            IMessageLibManager(endpoint).setConfig(memeverseRegistrarAddr, sendLib, params);
            IMessageLibManager(endpoint).setConfig(memeverseRegistrarAddr, receiveLib, params);
        }

        uint256 chainCount = omnichainIds.length;
        IMemeverseRegistrar.LzEndpointIdPair[] memory endpointPairs = new IMemeverseRegistrar.LzEndpointIdPair[](chainCount);
        for (uint32 i = 0; i < chainCount; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            endpointPairs[i] = IMemeverseRegistrar.LzEndpointIdPair({ chainId: chainId, endpointId: endpointId});
        }
        IMemeverseRegistrar(memeverseRegistrarAddr).setLzEndpointIds(endpointPairs);
    }

    function _deployUETHMemeverseLauncher(uint256 nonce) internal {
        bytes memory encodedArgs = abi.encode(
            UETH,
            owner,
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
            85000,
            1200000
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
                UETH_MEMEVERSE_LAUNCHER
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", "UETH", nonce));
        address UETHYieldDispatcher = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHYieldDispatcher deployed on %s", UETHYieldDispatcher);
    }
}
