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
import { MemecoinYieldVault } from "../src/yield/MemecoinYieldVault.sol";
import { MemecoinDaoGovernor } from "../src/governance/MemecoinDaoGovernor.sol";
import { MemeverseProxyDeployer } from "../src/verse/MemeverseProxyDeployer.sol";
import { IMemeverseRegistrar } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { MemeverseRegistrationCenter } from "../src/verse/MemeverseRegistrationCenter.sol";
import { MemeverseRegistrarOmnichain } from "../src/verse/MemeverseRegistrarOmnichain.sol";
import { MemeverseLauncher, IMemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { MemeverseCommonInfo, IMemeverseCommonInfo } from "../src/verse/MemeverseCommonInfo.sol";
import { IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";
import { OmnichainMemecoinStaker } from "../src/interoperation/OmnichainMemecoinStaker.sol";
import { MemeverseOmnichainInteroperation } from "../src/interoperation/MemeverseOmnichainInteroperation.sol";

contract MemeverseScript is BaseScript {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;

    address internal owner;
    address internal signer;
    address internal factory;
    address internal router;

    address internal UETH;
    address internal OUTRUN_DEPLOYER;

    address internal MEMECOIN_IMPLEMENTATION;
    address internal POL_IMPLEMENTATION;
    address internal MEMECOIN_VAULT_IMPLEMENTATION;
    address internal MEMECOIN_GOVERNOR_IMPLEMENTATION;

    address internal MEMEVERSE_REGISTRATION_CENTER;
    address internal MEMEVERSE_COMMON_INFO;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_PROXY_DEPLOYER;
    address internal MEMEVERSE_LAUNCHER;
    address internal YIELD_DISPATCHER;
    address internal OMNICHAIN_MEMECOIN_STAKER;

    uint32[] public omnichainIds;
    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        signer = vm.envAddress("SIGNER");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("LIQUIDITY_ROUTER");
        UETH = vm.envAddress("UETH");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");

        MEMECOIN_IMPLEMENTATION = vm.envAddress("MEMECOIN_IMPLEMENTATION");
        POL_IMPLEMENTATION = vm.envAddress("POL_IMPLEMENTATION");
        MEMECOIN_VAULT_IMPLEMENTATION = vm.envAddress("MEMECOIN_VAULT_IMPLEMENTATION");
        MEMECOIN_GOVERNOR_IMPLEMENTATION = vm.envAddress("MEMECOIN_GOVERNOR_IMPLEMENTATION");

        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");
        MEMEVERSE_COMMON_INFO = vm.envAddress("MEMEVERSE_COMMON_INFO");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR"); 
        MEMEVERSE_PROXY_DEPLOYER = vm.envAddress("MEMEVERSE_PROXY_DEPLOYER"); 
        MEMEVERSE_LAUNCHER = vm.envAddress("MEMEVERSE_LAUNCHER");
        YIELD_DISPATCHER = vm.envAddress("YIELD_DISPATCHER");
        OMNICHAIN_MEMECOIN_STAKER = vm.envAddress("OMNICHAIN_MEMECOIN_STAKER");

        // OutrunTODO Testnet id
        omnichainIds = [97, 84532, 421614, 43113, 80002, 57054, 168587773, 534351];
        _chainsInit();

        // _getDeployedImplementation(8);

        // _getDeployedRegistrationCenter(13);

        // _getDeployedMemeverseCommonInfo(13);
        // _getDeployedMemeverseRegistrar(13);
        // _getDeployedMemeverseProxyDeployer(13);
        // _getDeployedYieldDispatcher(13);
        // _getDeployedMemeverseOmnichainInteroperation(13);
        // _getDeployedOmnichainMemecoinStaker(13);
        // _getDeployedMemeverseLauncher(13);


        // _deployRegistrationCenter(13);

        // _deployImplementation(8);

        // _deployMemeverseCommonInfo(13);
        // _deployMemeverseRegistrar(13);
        // _deployMemeverseProxyDeployer(13);
        // _deployYieldDispatcher(13);
        // _deployMemeverseOmnichainInteroperation(13);
        // _deployOmnichainMemecoinStaker(13);

        //_deployMemeverseLauncher(13);    // optimizer-runs: 1000

        _deployMemecoinDaoGovernorImplementation(13);    // optimizer-runs: 10000
    }

    function _chainsInit() internal {
        endpoints[97] = vm.envAddress("BSC_TESTNET_ENDPOINT");
        endpoints[84532] = vm.envAddress("BASE_SEPOLIA_ENDPOINT");
        endpoints[421614] = vm.envAddress("ARBITRUM_SEPOLIA_ENDPOINT");
        endpoints[43113] = vm.envAddress("AVALANCHE_FUJI_ENDPOINT");
        endpoints[80002] = vm.envAddress("POLYGON_AMOY_ENDPOINT");
        endpoints[57054] = vm.envAddress("SONIC_BLAZE_ENDPOINT");
        endpoints[168587773] = vm.envAddress("BLAST_SEPOLIA_ENDPOINT");
        endpoints[534351] = vm.envAddress("SCROLL_SEPOLIA_ENDPOINT");
        // endpoints[10143] = vm.envAddress("MONAD_TESTNET_ENDPOINT");
        // endpoints[11155420] = vm.envAddress("OPTIMISTIC_SEPOLIA_ENDPOINT");
        // endpoints[300] = vm.envAddress("ZKSYNC_SEPOLIA_ENDPOINT");
        // endpoints[59141] = vm.envAddress("LINEA_SEPOLIA_ENDPOINT");
        
        endpointIds[97] = uint32(vm.envUint("BSC_TESTNET_EID"));
        endpointIds[84532] = uint32(vm.envUint("BASE_SEPOLIA_EID"));
        endpointIds[421614] = uint32(vm.envUint("ARBITRUM_SEPOLIA_EID"));
        endpointIds[43113] = uint32(vm.envUint("AVALANCHE_FUJI_EID"));
        endpointIds[80002] = uint32(vm.envUint("POLYGON_AMOY_EID"));
        endpointIds[57054] = uint32(vm.envUint("SONIC_BLAZE_EID"));
        endpointIds[168587773] = uint32(vm.envUint("BLAST_SEPOLIA_EID"));
        endpointIds[534351] = uint32(vm.envUint("SCROLL_SEPOLIA_EID"));
        // endpointIds[10143] = uint32(vm.envUint("MONAD_TESTNET_EID"));
        // endpointIds[11155420] = uint32(vm.envUint("OPTIMISTIC_SEPOLIA_EID"));
        // endpointIds[300] = uint32(vm.envUint("ZKSYNC_SEPOLIA_EID"));
        // endpointIds[59141] = uint32(vm.envUint("LINEA_SEPOLIA_EID"));
    }

    function _getDeployedImplementation(uint256 nonce) internal view {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 memecoinPOLSalt = keccak256(abi.encodePacked("MemecoinPOLImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));

        address deployedMemecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinSalt);
        address deployedMemecoinPOLImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinPOLSalt);
        address deployedMemecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinYieldVaultSalt);
        address deployedMemecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinDaoGovernorSalt);

        console.log("MemecoinImplementation deployed on %s", deployedMemecoinImplementation);
        console.log("MemecoinPOLImplementation deployed on %s", deployedMemecoinPOLImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", deployedMemecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", deployedMemecoinDaoGovernorImplementation);
    }

    function _getDeployedRegistrationCenter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrationCenter deployed on %s", deployed);
    }

    function _getDeployedMemeverseCommonInfo(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseCommonInfo", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseCommonInfo deployed on %s", deployed);
    }

    function _getDeployedMemeverseRegistrar(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrar deployed on %s", deployed);
    }

    function _getDeployedMemeverseProxyDeployer(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseProxyDeployer", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseProxyDeployer deployed on %s", deployed);
    }

    function _getDeployedMemeverseLauncher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseLauncher deployed on %s", deployed);
    }

    function _getDeployedYieldDispatcher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("YieldDispatcher deployed on %s", deployed);
    }

    function _getDeployedMemeverseOmnichainInteroperation(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseOmnichainInteroperation", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseOmnichainInteroperation deployed on %s", deployed);
    }

    function _getDeployedOmnichainMemecoinStaker(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("OmnichainMemecoinStaker", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("OmnichainMemecoinStaker deployed on %s", deployed);
    }

    /** DEPLOY **/

    function _deployImplementation(uint256 nonce) internal {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 memecoinPOLSalt = keccak256(abi.encodePacked("MemecoinPOLImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
 
        address memecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinSalt, type(Memecoin).creationCode);
        address memecoinPOLImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinPOLSalt, type(MemeLiquidProof).creationCode);
        address memecoinYieldVaultImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinYieldVaultSalt, type(MemecoinYieldVault).creationCode);

        console.log("MemecoinImplementation deployed on %s", memecoinImplementation);
        console.log("MemecoinPOLImplementation deployed on %s", memecoinPOLImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", memecoinYieldVaultImplementation);
    }

    function _deployMemecoinDaoGovernorImplementation(uint256 nonce) internal {
        bytes32 memecoinDaoGovernorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        address memecoinDaoGovernorImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinDaoGovernorSalt, type(MemecoinDaoGovernor).creationCode);
        
        console.log("MemecoinDaoGovernorImplementation deployed on %s", memecoinDaoGovernorImplementation);
    }

    function _deployRegistrationCenter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address localEndpoint = endpoints[uint32(block.chainid)];
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_REGISTRAR,
                MEMEVERSE_COMMON_INFO
            )
        );
        address centerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        uint256 chainCount = omnichainIds.length;
        for (uint32 i = 0; i < chainCount; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
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
            (address receiveLib, ) = IMessageLibManager(localEndpoint).getReceiveLibrary(centerAddr, endpointId);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, receiveLib, params);
        }

        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimit(1000000);
        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 3);
        IMemeverseRegistrationCenter(centerAddr).setLockupDaysRange(1, 365);

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
    }

    function _deployMemeverseCommonInfo(uint256 nonce) internal {
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseCommonInfo).creationCode,
            abi.encode(owner)
        );
        bytes32 salt = keccak256(abi.encodePacked("MemeverseCommonInfo", nonce));
        address memeverseCommonInfoAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        uint256 length = omnichainIds.length;
        IMemeverseCommonInfo.LzEndpointIdPair[] memory lzEndpointPairs = new IMemeverseCommonInfo.LzEndpointIdPair[](length);
        for (uint32 i = 0; i < length; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            lzEndpointPairs[i] = IMemeverseCommonInfo.LzEndpointIdPair({ chainId: chainId, endpointId: endpointId});
        }
        IMemeverseCommonInfo(memeverseCommonInfoAddr).setLzEndpointIdMap(lzEndpointPairs);

        console.log("MemeverseCommonInfo deployed on %s", memeverseCommonInfoAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        address localEndpoint = endpoints[uint32(block.chainid)];
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                MEMEVERSE_REGISTRATION_CENTER,
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_COMMON_INFO
            );
            creationBytecode = type(MemeverseRegistrarAtLocal).creationCode;
        } else {
            encodedArgs = abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_LAUNCHER,
                MEMEVERSE_COMMON_INFO,
                uint32(vm.envUint("BSC_TESTNET_EID")),
                uint32(vm.envUint("BSC_TESTNET_CHAINID")),
                150000,
                750000,
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

            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(memeverseRegistrarAddr, centerEndpointId);
            (address receiveLib, ) = IMessageLibManager(localEndpoint).getReceiveLibrary(memeverseRegistrarAddr, centerEndpointId);
            IMessageLibManager(localEndpoint).setConfig(memeverseRegistrarAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(memeverseRegistrarAddr, receiveLib, params);
        }
    }

    function _deployMemeverseProxyDeployer(uint256 nonce) internal {
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseProxyDeployer).creationCode,
            abi.encode(
                owner,
                MEMEVERSE_LAUNCHER,
                MEMECOIN_IMPLEMENTATION,
                POL_IMPLEMENTATION,
                MEMECOIN_VAULT_IMPLEMENTATION,
                MEMECOIN_GOVERNOR_IMPLEMENTATION,
                1000000e18,
                25
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("MemeverseProxyDeployer", nonce));
        address memeverseProxyDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemeverseProxyDeployer deployed on %s", memeverseProxyDeployer);
    }

    function _deployMemeverseLauncher(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];
        bytes memory encodedArgs = abi.encode(
            owner,
            factory,
            router,
            localEndpoint,
            MEMEVERSE_REGISTRAR,
            MEMEVERSE_PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            MEMEVERSE_COMMON_INFO,
            25,
            115000,
            135000
        );
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseLauncher).creationCode,
            encodedArgs
        );
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address memeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);
        IMemeverseLauncher(memeverseLauncherAddr).setFundMetaData(UETH, 1e19, 10000000);

        console.log("MemeverseLauncher deployed on %s", memeverseLauncherAddr);
    }

    function _deployYieldDispatcher(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory creationCode = abi.encodePacked(
            type(YieldDispatcher).creationCode,
            abi.encode(
                owner,
                localEndpoint,
                MEMEVERSE_LAUNCHER
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", nonce));
        address yieldDispatcher = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("YieldDispatcher deployed on %s", yieldDispatcher);
    }

    function _deployMemeverseOmnichainInteroperation(uint256 nonce) internal {
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseOmnichainInteroperation).creationCode,
            abi.encode(
                owner,
                MEMEVERSE_COMMON_INFO,
                MEMEVERSE_LAUNCHER,
                OMNICHAIN_MEMECOIN_STAKER,
                115000,
                135000
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("MemeverseOmnichainInteroperation", nonce));
        address staker = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemeverseOmnichainInteroperation deployed on %s", staker);
    }

    function _deployOmnichainMemecoinStaker(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory creationCode = abi.encodePacked(
            type(OmnichainMemecoinStaker).creationCode,
            abi.encode(owner, localEndpoint)
        );

        bytes32 salt = keccak256(abi.encodePacked("OmnichainMemecoinStaker", nonce));
        address staker = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("OmnichainMemecoinStaker deployed on %s", staker);
    }
}
