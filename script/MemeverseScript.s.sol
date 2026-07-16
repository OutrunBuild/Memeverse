// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    IMessageLibManager,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./BaseScript.s.sol";
import {Memecoin} from "../src/token/Memecoin.sol";
import {IOutrunDeployer} from "./IOutrunDeployer.sol";
import {MemePol} from "../src/token/MemePol.sol";
import {MemecoinYieldVault} from "../src/yield/MemecoinYieldVault.sol";
import {MemeverseProxyDeployer} from "../src/verse/deployment/MemeverseProxyDeployer.sol";
import {YieldDispatcher} from "../src/verse/YieldDispatcher.sol";
import {MemeverseRegistrarAtLocal} from "../src/verse/registration/MemeverseRegistrarAtLocal.sol";
import {MemeverseRegistrationCenter} from "../src/verse/registration/MemeverseRegistrationCenter.sol";
import {MemeverseRegistrarOmnichain} from "../src/verse/registration/MemeverseRegistrarOmnichain.sol";
import {MemeverseLauncher, IMemeverseLauncher} from "../src/verse/MemeverseLauncher.sol";
import {MemeverseBootstrap} from "../src/verse/MemeverseBootstrap.sol";
import {MemeverseFeeDistributor} from "../src/verse/MemeverseFeeDistributor.sol";
import {MemeverseFeePreviewReader} from "../src/verse/MemeverseFeePreviewReader.sol";
import {MemeversePOLMinter} from "../src/verse/MemeversePOLMinter.sol";
import {POLend} from "../src/polend/POLend.sol";
import {POLSplitter} from "../src/polend/POLSplitter.sol";
import {GenesisCreditFactory} from "../src/credit/GenesisCreditFactory.sol";
import {OmnichainMemecoinStaker} from "../src/interoperation/OmnichainMemecoinStaker.sol";
import {LzEndpointRegistry} from "../src/common/omnichain/LzEndpointRegistry.sol";
import {ILzEndpointRegistry} from "../src/common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {MemecoinDaoGovernorUpgradeable} from "../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {IMemeverseRegistrationCenter} from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";
import {MemeverseOmnichainInteroperation} from "../src/interoperation/MemeverseOmnichainInteroperation.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";

contract MemeverseScript is BaseScript {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;
    uint160 internal constant MEMEVERSE_HOOK_FLAGS = 0x28cc;
    uint160 internal constant UNISWAP_V4_HOOK_FLAG_MASK = 0x3fff;

    address internal owner;
    address internal factory;
    address internal router;

    address internal UUSD;
    address internal UETH;
    address internal OUTRUN_DEPLOYER;

    address internal MEMECOIN_IMPLEMENTATION;
    address internal POL_IMPLEMENTATION;
    address internal MEMECOIN_VAULT_IMPLEMENTATION;
    address internal MEMECOIN_GOVERNOR_IMPLEMENTATION;
    address internal CYCLE_INCENTIVIZER_IMPLEMENTATION;

    address internal MEMEVERSE_REGISTRATION_CENTER;
    address internal MEMEVERSE_COMMON_INFO;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_PROXY_DEPLOYER;
    address internal MEMEVERSE_LAUNCHER;
    address internal MEMEVERSE_YIELD_DISPATCHER;
    address internal OMNICHAIN_MEMECOIN_STAKER;
    address internal POLEND;
    address internal POLSPLITTER;
    address internal CREDIT_FACTORY;
    address internal MEMEVERSE_SWAP_ROUTER;

    uint256 internal POLEND_INTEREST_RATE;
    uint256 internal POLEND_LEVERAGED_DEBT_FACTOR;
    address internal POLEND_TREASURY;
    address internal MEMEVERSE_UNISWAP_HOOK;

    uint32[] public omnichainIds;
    mapping(uint32 chainId => address) public endpoints;
    mapping(uint32 chainId => uint32) public endpointIds;

    /// @notice Executes run.
    /// @dev See the implementation for behavior details.
    function run() public broadcaster {
        _loadScriptEnv();

        // OutrunTODO Testnet id
        omnichainIds = [97, 84532, 421614, 43113, 80002, 57054, 168587773, 534351, 11155111];
        _chainsInit();

        // _getDeployedImplementation(2);

        // _getDeployedRegistrationCenter(2);

        // _getDeployedLzEndpointRegistry(2);
        // _getDeployedMemeverseRegistrar(2);
        // _getDeployedMemeverseProxyDeployer(2);
        // _getDeployedYieldDispatcher(2);
        // _getDeployedMemeverseOmnichainInteroperation(2);
        // _getDeployedOmnichainMemecoinStaker(2);
        // _getDeployedMemeverseLauncher(2);
        // _getDeployedPOLend(2);
        // _getDeployedPOLSplitter(2);

        // Update OutrunRouter after deployed
        // _deployGenesisCreditFactory(2);             // R1-F5: homeChainEid guardrail — mandatory deploy path
        // _deployPOLend(2);                            // optimizer-runs: 200
        // _deployMemeverseLauncher(2);                 // optimizer-runs: 200
        // _deployPOLSplitter(2);                       // optimizer-runs: 200
        // _deployMemecoinGovernorImplementation(2);    // optimizer-runs: 2000
        // _deployMemecoinPOLImplementation(2);         // optimizer-runs: 5000
        // _deployImplementation(2);

        // _deployLzEndpointRegistry(2);
        // _deployMemeverseRegistrar(2);
        // _deployMemeverseProxyDeployer(2);
        // _deployYieldDispatcher(2);
        // _deployMemeverseOmnichainInteroperation(2);
        // _deployOmnichainMemecoinStaker(2);

        // _deployRegistrationCenter(2);
        // openSupportedUAssetsAfterReadiness(
        //     MEMEVERSE_REGISTRATION_CENTER,
        //     MEMEVERSE_SWAP_ROUTER,
        //     MEMEVERSE_UNISWAP_HOOK
        // );
    }

    function _loadScriptEnv() internal {
        owner = vm.envAddress("OWNER");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("LIQUIDITY_ROUTER");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");

        MEMECOIN_IMPLEMENTATION = vm.envAddress("MEMECOIN_IMPLEMENTATION");
        POL_IMPLEMENTATION = vm.envAddress("POL_IMPLEMENTATION");
        MEMECOIN_VAULT_IMPLEMENTATION = vm.envAddress("MEMECOIN_VAULT_IMPLEMENTATION");
        MEMECOIN_GOVERNOR_IMPLEMENTATION = vm.envAddress("MEMECOIN_GOVERNOR_IMPLEMENTATION");
        CYCLE_INCENTIVIZER_IMPLEMENTATION = vm.envAddress("CYCLE_INCENTIVIZER_IMPLEMENTATION");

        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");
        MEMEVERSE_COMMON_INFO = _envAddressWithFallback("LZ_ENDPOINT_REGISTRY", "MEMEVERSE_COMMON_INFO");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_PROXY_DEPLOYER = vm.envAddress("MEMEVERSE_PROXY_DEPLOYER");
        MEMEVERSE_YIELD_DISPATCHER = vm.envAddress("MEMEVERSE_YIELD_DISPATCHER");
        OMNICHAIN_MEMECOIN_STAKER = vm.envAddress("OMNICHAIN_MEMECOIN_STAKER");
        MEMEVERSE_SWAP_ROUTER = _optionalEnvAddress("MEMEVERSE_SWAP_ROUTER");
        MEMEVERSE_UNISWAP_HOOK = _optionalEnvAddress("MEMEVERSE_UNISWAP_HOOK");
        POLEND_INTEREST_RATE = vm.envUint("POLEND_INTEREST_RATE");
        POLEND_LEVERAGED_DEBT_FACTOR = vm.envUint("POLEND_LEVERAGED_DEBT_FACTOR");
        POLEND_TREASURY = vm.envAddress("POLEND_TREASURY");
        _loadReadinessEnv();
    }

    // POLEND/POLSPLITTER use optional loading: during deployment the deploy functions set them
    // directly; for standalone readiness checks (openSupportedUAssetsAfterReadiness) the env vars
    // must be set to the deployed addresses.
    function _loadReadinessEnv() internal {
        owner = vm.envAddress("OWNER");
        UUSD = vm.envAddress("UUSD");
        UETH = vm.envAddress("UETH");
        MEMEVERSE_LAUNCHER = vm.envAddress("MEMEVERSE_LAUNCHER");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_PROXY_DEPLOYER = vm.envAddress("MEMEVERSE_PROXY_DEPLOYER");
        MEMEVERSE_YIELD_DISPATCHER = vm.envAddress("MEMEVERSE_YIELD_DISPATCHER");
        POLEND = _optionalEnvAddress("POLEND");
        POLSPLITTER = _optionalEnvAddress("POLSPLITTER");
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
        endpoints[11155111] = vm.envAddress("ETHEREUM_SEPOLIA_ENDPOINT");
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
        endpointIds[11155111] = uint32(vm.envUint("ETHEREUM_SEPOLIA_EID"));
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
        bytes32 cycleIncentivizerSalt = keccak256(abi.encodePacked("GovernanceCycleIncentivizerImplementation", nonce));

        address deployedMemecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinSalt);
        address deployedMemecoinPOLImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinPOLSalt);
        address deployedMemecoinYieldVaultImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinYieldVaultSalt);
        address deployedMemecoinDaoGovernorImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinDaoGovernorSalt);
        address deployedCycleIncentivizerImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, cycleIncentivizerSalt);

        console.log("MemecoinImplementation deployed on %s", deployedMemecoinImplementation);
        console.log("MemecoinPOLImplementation deployed on %s", deployedMemecoinPOLImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", deployedMemecoinYieldVaultImplementation);
        console.log("MemecoinDaoGovernorImplementation deployed on %s", deployedMemecoinDaoGovernorImplementation);
        console.log("GovernanceCycleIncentivizerImplementation deployed on %s", deployedCycleIncentivizerImplementation);
    }

    function _getDeployedRegistrationCenter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrationCenter deployed on %s", deployed);
    }

    function _getDeployedLzEndpointRegistry(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("LzEndpointRegistry", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("LzEndpointRegistry deployed on %s", deployed);
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
        address deployCaller = _memeverseLauncherDeployCaller();
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, salt);

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

    function _getDeployedPOLend(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("POLend", nonce));
        address deployCaller = _memeverseLauncherDeployCaller();
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, salt);

        console.log("POLend deployed on %s", deployed);
    }

    function _getDeployedPOLSplitter(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("POLSplitter", nonce));
        address deployCaller = _memeverseLauncherDeployCaller();
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, salt);

        console.log("POLSplitter deployed on %s", deployed);
    }

    /**
     *
     */

    function _deployImplementation(uint256 nonce) internal {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", nonce));
        bytes32 memecoinYieldVaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", nonce));
        bytes32 incentivizerSalt = keccak256(abi.encodePacked("GovernanceCycleIncentivizerImplementation", nonce));

        bytes memory memecoinCreationCode =
            abi.encodePacked(type(Memecoin).creationCode, abi.encode(endpoints[uint32(block.chainid)]));

        address memecoinImplementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinSalt, memecoinCreationCode);
        address memecoinYieldVaultImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinYieldVaultSalt, type(MemecoinYieldVault).creationCode);
        address cycleIncentivizerImplementation = IOutrunDeployer(OUTRUN_DEPLOYER)
            .deploy(incentivizerSalt, type(GovernanceCycleIncentivizerUpgradeable).creationCode);

        console.log("MemecoinImplementation deployed on %s", memecoinImplementation);
        console.log("MemecoinYieldVaultImplementation deployed on %s", memecoinYieldVaultImplementation);
        console.log("GovernanceCycleIncentivizerImplementation deployed on %s", cycleIncentivizerImplementation);
    }

    function _deployMemecoinPOLImplementation(uint256 nonce) internal {
        bytes32 memecoinPOLSalt = keccak256(abi.encodePacked("MemecoinPOLImplementation", nonce));
        bytes memory memecoinPOLCreationCode =
            abi.encodePacked(type(MemePol).creationCode, abi.encode(endpoints[uint32(block.chainid)]));
        address memecoinPOLImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).deploy(memecoinPOLSalt, memecoinPOLCreationCode);

        console.log("MemecoinPOLImplementation deployed on %s", memecoinPOLImplementation);
    }

    function _deployMemecoinGovernorImplementation(uint256 nonce) internal {
        bytes32 governorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", nonce));
        address memecoinDaoGovernorImplementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).deploy(governorSalt, type(MemecoinDaoGovernorUpgradeable).creationCode);

        console.log("MemecoinDaoGovernorImplementation deployed on %s", memecoinDaoGovernorImplementation);
    }

    function _deployRegistrationCenter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        address localEndpoint = endpoints[uint32(block.chainid)];
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(owner, localEndpoint, MEMEVERSE_REGISTRAR, MEMEVERSE_COMMON_INFO)
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
            params[0] = SetConfigParam({eid: endpointId, configType: 2, config: abi.encode(config)});

            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(centerAddr, endpointId);
            (address receiveLib,) = IMessageLibManager(localEndpoint).getReceiveLibrary(centerAddr, endpointId);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, sendLib, params);
            IMessageLibManager(localEndpoint).setConfig(centerAddr, receiveLib, params);
        }

        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimit(1000000);
        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 3);

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
    }

    function _deployLzEndpointRegistry(uint256 nonce) internal {
        bytes memory creationCode = abi.encodePacked(type(LzEndpointRegistry).creationCode, abi.encode(owner));
        bytes32 salt = keccak256(abi.encodePacked("LzEndpointRegistry", nonce));
        address lzEndpointRegistryAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        uint256 length = omnichainIds.length;
        ILzEndpointRegistry.LzEndpointIdPair[] memory lzEndpointPairs =
            new ILzEndpointRegistry.LzEndpointIdPair[](length);
        for (uint32 i = 0; i < length; i++) {
            uint32 chainId = omnichainIds[i];
            uint32 endpointId = endpointIds[chainId];
            lzEndpointPairs[i] = ILzEndpointRegistry.LzEndpointIdPair({chainId: chainId, endpointId: endpointId});
        }
        ILzEndpointRegistry(lzEndpointRegistryAddr).setLzEndpointIds(lzEndpointPairs);

        console.log("LzEndpointRegistry deployed on %s", lzEndpointRegistryAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        address localEndpoint = endpoints[uint32(block.chainid)];
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(owner, MEMEVERSE_REGISTRATION_CENTER, MEMEVERSE_LAUNCHER, MEMEVERSE_COMMON_INFO);
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
        bytes memory creationCode = abi.encodePacked(creationBytecode, encodedArgs);
        address memeverseRegistrarAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);
        console.log("MemeverseRegistrar deployed on %s", memeverseRegistrarAddr);

        if (block.chainid != vm.envUint("BSC_TESTNET_CHAINID")) {
            uint32 centerEndpointId = uint32(vm.envUint("BSC_TESTNET_EID"));
            IOAppCore(memeverseRegistrarAddr)
                .setPeer(centerEndpointId, bytes32(abi.encode(MEMEVERSE_REGISTRATION_CENTER)));

            UlnConfig memory config = UlnConfig({
                confirmations: 1,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            });
            SetConfigParam[] memory params = new SetConfigParam[](1);
            params[0] = SetConfigParam({eid: centerEndpointId, configType: 2, config: abi.encode(config)});

            address sendLib = IMessageLibManager(localEndpoint).getSendLibrary(memeverseRegistrarAddr, centerEndpointId);
            (address receiveLib,) =
                IMessageLibManager(localEndpoint).getReceiveLibrary(memeverseRegistrarAddr, centerEndpointId);
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
                CYCLE_INCENTIVIZER_IMPLEMENTATION,
                50,
                10,
                7 days,
                1000,
                6000
            )
        );

        bytes32 salt = keccak256(abi.encodePacked("MemeverseProxyDeployer", nonce));
        address memeverseProxyDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemeverseProxyDeployer deployed on %s", memeverseProxyDeployer);
    }

    function _deployMemeverseLauncher(uint256 nonce) internal {
        address deployCaller = _memeverseLauncherDeployCaller();
        address initialOwner = owner;
        address localEndpoint = endpoints[uint32(block.chainid)];

        // Predict POLend and POLSplitter proxy addresses via CREATE3 salt
        bytes32 polendSalt = keccak256(abi.encodePacked("POLend", nonce));
        address polendProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, polendSalt);
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));
        address polSplitterProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, polSplitterSalt);

        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address predictedLauncherProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, salt);
        bytes32 implementationSalt = keccak256(abi.encodePacked("MemeverseLauncherImplementation", nonce));
        address implementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).deploy(implementationSalt, type(MemeverseLauncher).creationCode);

        bytes memory creationCode = _buildMemeverseLauncherCreationCode(
            implementation, initialOwner, localEndpoint, predictedLauncherProxy, polendProxy, polSplitterProxy
        );
        address memeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);
        require(memeverseLauncherAddr == predictedLauncherProxy, "LAUNCHER_PROXY_MISMATCH");

        IMemeverseLauncher launcher = IMemeverseLauncher(memeverseLauncherAddr);
        _beginMemeverseLauncherOwnerExecution(initialOwner);
        if (deployCaller == initialOwner) {
            _setMemeverseLauncherFundMetaData(launcher);
            // setBootstrapImpl is onlyOwner, so the bootstrap sibling can only be wired when the
            // broadcaster IS the owner. The launcher delegatecalls it from `_deployLiquidity`; when
            // deployer != owner the owner deploys and wires it afterwards (see WARNING below).
            MemeverseBootstrap bootstrapImpl = new MemeverseBootstrap();
            launcher.setBootstrapImpl(address(bootstrapImpl));
            // Wire the fee-distributor delegatecall sibling and the independent fee-preview reader
            // alongside the bootstrap sibling. Reader is injected the proxy address so its view calls
            // read facade state through the proxy getters.
            MemeverseFeeDistributor feeDistributorImpl = new MemeverseFeeDistributor();
            launcher.setFeeDistributorImpl(address(feeDistributorImpl));
            MemeverseFeePreviewReader feePreviewReader = new MemeverseFeePreviewReader(address(launcher));
            launcher.setFeePreviewReader(address(feePreviewReader));
            MemeversePOLMinter polMinterImpl = new MemeversePOLMinter();
            launcher.setPOLMinterImpl(address(polMinterImpl));
        } else {
            console.log(
                "WARNING: deployCaller(%s) != initialOwner(%s) -- fund metadata, bootstrapImpl, feeDistributorImpl, feePreviewReader and polMinterImpl must be set by initialOwner",
                deployCaller,
                initialOwner
            );
        }
        _endMemeverseLauncherOwnerExecution();
        _checkMemeverseLauncherDeployment(
            launcher, initialOwner, localEndpoint, polendProxy, polSplitterProxy, deployCaller == initialOwner
        );

        MEMEVERSE_LAUNCHER = memeverseLauncherAddr;
        console.log("MemeverseLauncher deployed on %s", memeverseLauncherAddr);
    }

    function _deployPOLend(uint256 nonce) internal {
        address deployCaller = _memeverseLauncherDeployCaller();
        address initialOwner = owner;

        // Predict Launcher and POLSplitter proxy addresses (not yet deployed)
        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address predictedLauncherProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, launcherSalt);
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));
        address predictedPOLSplitterProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, polSplitterSalt);

        // Predict POLend proxy address and deploy implementation via CREATE3
        bytes32 polendSalt = keccak256(abi.encodePacked("POLend", nonce));
        address predictedPolendProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, polendSalt);
        bytes32 implementationSalt = keccak256(abi.encodePacked("POLendImplementation", nonce));
        address implementation = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(implementationSalt, type(POLend).creationCode);

        // Build proxy creation code with predicted dependency addresses
        bytes memory creationCode =
            _buildPOLendCreationCode(implementation, initialOwner, predictedLauncherProxy, predictedPOLSplitterProxy);

        // Deploy POLend proxy via CREATE3 and verify against cached prediction
        address polendAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(polendSalt, creationCode);
        require(polendAddr == predictedPolendProxy, "POLEND_PROXY_MISMATCH");

        // Verify local config (owner, treasury, interest rate, leverage factor).
        // Cross-contract wiring (launcher, splitter) is verified after all three are deployed.
        require(_readAddress(polendAddr, "owner()") == initialOwner, "POLEND_OWNER_MISMATCH");
        require(_readAddress(polendAddr, "treasury()") == POLEND_TREASURY, "POLEND_TREASURY_MISMATCH");

        POLEND = polendAddr;
        console.log("POLend deployed on %s", polendAddr);
    }

    function _deployPOLSplitter(uint256 nonce) internal {
        address deployCaller = _memeverseLauncherDeployCaller();
        address initialOwner = owner;
        // Launcher must already be deployed; POLSplitter.initialize reads launcher.polend()
        address launcherProxy = MEMEVERSE_LAUNCHER;
        require(launcherProxy != address(0), "ZERO_LAUNCHER_FOR_SPLITTER");

        // Predict POLSplitter proxy address
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));
        address predictedPOLSplitterProxy = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(deployCaller, polSplitterSalt);

        // Deploy POLSplitter implementation via CREATE3
        bytes32 implementationSalt = keccak256(abi.encodePacked("POLSplitterImplementation", nonce));
        address implementation =
            IOutrunDeployer(OUTRUN_DEPLOYER).deploy(implementationSalt, type(POLSplitter).creationCode);

        // Build proxy creation code with actual Launcher address
        bytes memory creationCode = _buildPOLSplitterCreationCode(implementation, initialOwner, launcherProxy);

        // Deploy POLSplitter proxy via CREATE3
        address polSplitterAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(polSplitterSalt, creationCode);
        require(polSplitterAddr == predictedPOLSplitterProxy, "POLSPLITTER_PROXY_MISMATCH");

        // Verify wiring: polend() must match the already-deployed POLend proxy
        _checkPOLSplitterDeployment(polSplitterAddr, initialOwner, launcherProxy, POLEND);

        POLSPLITTER = polSplitterAddr;
        console.log("POLSplitter deployed on %s", polSplitterAddr);
    }

    /// @notice Deploys GenesisCreditFactory with the canonical home-chain eid baked in as an immutable.
    /// @dev R1-F5 guardrail. `homeChainEid` is immutable on the factory and on every credit it deploys
    ///      (injected into the credit init_code), and is the parameter source for `GenesisCredit.claim`'s
    ///      home-chain gate (`endpoint.eid() == homeChainEid`). A remote-chain factory that baked in the
    ///      remote eid would open merkle minting on the remote.
    ///
    ///      The script CANNOT auto-detect that mistake: a remote operator who sets `HOME_CHAIN_EID` to
    ///      the remote eid makes `homeChainEid == localEid` hold on the remote, indistinguishable from a
    ///      legitimate home-chain deploy. So the guardrail is procedural, in three parts:
    ///        1. Single source — `homeChainEid` is read from the `HOME_CHAIN_EID` env var and is NEVER
    ///           derived from the local endpoint. Every chain (home and remote) passes the same canonical
    ///           value, eliminating the "copy the local eid" footgun. The raw uint256 is bound-checked
    ///           before truncating to uint32, because the on-chain re-check below cannot catch truncation
    ///           (it compares the truncated value against the immutable baked from that same value).
    ///        2. On-chain re-check — after deploy the baked value is re-read and asserted equal to the
    ///           env var. This catches constructor-arg packing/order mistakes (abi.encode misuse), NOT
    ///           the semantic mistake of a wrong env value.
    ///        3. Log — `homeChainEid` and the local eid are both logged so the operator can eyeball the
    ///           relationship (home: equal; remote: not equal). The local-eid
    ///           read is best-effort: an unavailable endpoint in a no-fork simulate must not block the
    ///           deploy broadcast, so failure degrades to an `<unavailable>` log line.
    function _deployGenesisCreditFactory(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];
        require(localEndpoint != address(0), "ZERO_LOCAL_ENDPOINT");
        require(OUTRUN_DEPLOYER != address(0), "ZERO_OUTRUN_DEPLOYER");

        // Single source of truth: canonical home eid from env, never derived from the local endpoint.
        uint256 envEid = vm.envUint("HOME_CHAIN_EID");
        require(envEid != 0, "ZERO_HOME_CHAIN_EID");
        require(envEid <= type(uint32).max, "HOME_CHAIN_EID_OVERFLOW");
        uint32 homeChainEid = uint32(envEid);

        bytes32 salt = keccak256(abi.encodePacked("GenesisCreditFactory", nonce));
        bytes memory code =
            abi.encodePacked(type(GenesisCreditFactory).creationCode, abi.encode(localEndpoint, homeChainEid, owner));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, code);

        // On-chain re-check: the factory actually received the canonical home eid. Guards against
        // constructor-arg packing/order mistakes only; the semantic check is an operator step.
        require(_readUint32(deployed, "homeChainEid()") == homeChainEid, "HOME_CHAIN_EID_MISMATCH");

        console.log("GenesisCreditFactory deployed on %s", deployed);
        console.log("homeChainEid=%s", uint256(homeChainEid));
        // Best-effort local-eid log for operator eyeball (home: homeChainEid==localEid; remote: !=).
        // Wrapped so an unavailable endpoint in a no-fork simulate cannot block the deploy broadcast.
        (bool ok, bytes memory eidData) = localEndpoint.staticcall(abi.encodeWithSignature("eid()"));
        if (ok && eidData.length >= 32) {
            console.log("localEid=%s", uint256(uint32(uint256(bytes32(eidData)))));
        } else {
            console.log("localEid=<unavailable; run against a forked RPC to read endpoint eid>");
        }

        CREDIT_FACTORY = deployed;
    }

    /// @dev Staticcall peer of `_readAddress`, for uint32 return values (e.g. `homeChainEid()`, endpoint `eid()`).
    function _readUint32(address target, string memory signature) internal view returns (uint32 value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && data.length >= 32, "STATICCALL_UINT32_FAILED");
        value = uint32(uint256(bytes32(data)));
    }

    function _beginMemeverseLauncherOwnerExecution(address initialOwner) internal virtual {
        // Hook point for subclasses. The default implementation does nothing —
        // fund metadata is set inline when deployCaller == initialOwner, or
        // skipped with a warning when they differ (handled in _deployMemeverseLauncher).
        initialOwner; // silence unused parameter warning
    }

    function _endMemeverseLauncherOwnerExecution() internal virtual {}

    function _setMemeverseLauncherFundMetaData(IMemeverseLauncher launcher) internal {
        launcher.setFundMetaData(UETH, 1e19, 1000000);
        launcher.setFundMetaData(UUSD, 20000 * 1e18, 100000);
    }

    function _memeverseLauncherDeployCaller() internal view returns (address) {
        // OutrunDeployer hashes msg.sender into each CREATE3 salt; tests call through this harness without broadcast.
        if (deployer != address(0)) return deployer;
        return address(this);
    }

    function _buildMemeverseLauncherCreationCode(
        address implementation,
        address initialOwner,
        address localEndpoint,
        address launcherProxy,
        address polendProxy,
        address polSplitterProxy
    ) internal view returns (bytes memory) {
        require(implementation != address(0), "ZERO_LAUNCHER_IMPLEMENTATION");
        require(initialOwner != address(0), "ZERO_INITIAL_OWNER");
        require(launcherProxy != address(0), "ZERO_LAUNCHER_PROXY");
        require(localEndpoint != address(0), "ZERO_LOCAL_ENDPOINT");
        require(MEMEVERSE_REGISTRAR != address(0), "ZERO_MEMEVERSE_REGISTRAR");
        require(MEMEVERSE_PROXY_DEPLOYER != address(0), "ZERO_MEMEVERSE_PROXY_DEPLOYER");
        require(MEMEVERSE_YIELD_DISPATCHER != address(0), "ZERO_MEMEVERSE_YIELD_DISPATCHER");
        require(MEMEVERSE_COMMON_INFO != address(0), "ZERO_LZ_ENDPOINT_REGISTRY");
        require(polendProxy != address(0), "ZERO_POLEND_PROXY");
        require(polSplitterProxy != address(0), "ZERO_POLSPLITTER_PROXY");
        require(UETH != address(0), "ZERO_UETH");
        require(UUSD != address(0), "ZERO_UUSD");

        bytes memory initializeData = abi.encodeCall(
            MemeverseLauncher.initialize,
            (
                initialOwner,
                localEndpoint,
                MEMEVERSE_REGISTRAR,
                MEMEVERSE_PROXY_DEPLOYER,
                MEMEVERSE_YIELD_DISPATCHER,
                MEMEVERSE_COMMON_INFO,
                // These are canonical dependency proxy addresses, not the launcher proxy.
                polendProxy,
                polSplitterProxy,
                25,
                115000,
                135000,
                2500,
                7 days
            )
        );
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializeData));
    }

    function _buildPOLendCreationCode(
        address implementation,
        address initialOwner,
        address launcherProxy,
        address polSplitterProxy
    ) internal view returns (bytes memory) {
        require(implementation != address(0), "ZERO_POLEND_IMPLEMENTATION");
        require(initialOwner != address(0), "ZERO_INITIAL_OWNER");
        require(launcherProxy != address(0), "ZERO_LAUNCHER_PROXY");
        require(polSplitterProxy != address(0), "ZERO_POLSPLITTER_PROXY");
        require(POLEND_TREASURY != address(0), "ZERO_POLEND_TREASURY");
        require(POLEND_INTEREST_RATE > 0, "ZERO_POLEND_INTEREST_RATE");
        require(POLEND_INTEREST_RATE <= 1e18, "POLEND_INTEREST_RATE_OVERFLOW");
        require(POLEND_LEVERAGED_DEBT_FACTOR > 0, "ZERO_POLEND_LEVERAGED_DEBT_FACTOR");
        require(
            POLEND_LEVERAGED_DEBT_FACTOR <= uint256(type(uint128).max) * 1e18, "POLEND_LEVERAGED_DEBT_FACTOR_OVERFLOW"
        );

        // Wire the GenesisCreditFactory into POLend at initialize time. Prefer the factory
        // deployed earlier in this script run (`_deployGenesisCreditFactory` sets CREDIT_FACTORY);
        // fall back to the CREDIT_FACTORY_PROXY env var for a standalone POLend deploy where the
        // factory was deployed in a prior run. The deploy-owner fallback remains only so a
        // standalone POLend deploy with no factory still passes initialize's zero-check;
        // setCreditFactory is then the post-deploy remediation path that swaps in the real factory.
        address creditFactoryProxy =
            CREDIT_FACTORY != address(0) ? CREDIT_FACTORY : vm.envOr("CREDIT_FACTORY_PROXY", initialOwner);
        require(creditFactoryProxy != address(0), "ZERO_CREDIT_FACTORY_PROXY");

        bytes memory initializeData = abi.encodeCall(
            POLend.initialize,
            (
                initialOwner,
                POLEND_INTEREST_RATE,
                POLEND_LEVERAGED_DEBT_FACTOR,
                POLEND_TREASURY,
                launcherProxy,
                polSplitterProxy,
                creditFactoryProxy
            )
        );
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializeData));
    }

    function _buildPOLSplitterCreationCode(address implementation, address initialOwner, address launcherProxy)
        internal
        pure
        returns (bytes memory)
    {
        require(implementation != address(0), "ZERO_POLSPLITTER_IMPLEMENTATION");
        require(initialOwner != address(0), "ZERO_INITIAL_OWNER");
        require(launcherProxy != address(0), "ZERO_LAUNCHER_PROXY");

        bytes memory initializeData = abi.encodeCall(POLSplitter.initialize, (initialOwner, launcherProxy));
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initializeData));
    }

    function _checkPOLSplitterDeployment(
        address polSplitterProxy,
        address initialOwner,
        address launcherProxy,
        address polendProxy
    ) internal view {
        require(_readAddress(polSplitterProxy, "owner()") == initialOwner, "SPLITTER_OWNER_MISMATCH");
        require(_readAddress(polSplitterProxy, "launcher()") == launcherProxy, "SPLITTER_LAUNCHER_MISMATCH");
        require(_readAddress(polSplitterProxy, "polend()") == polendProxy, "SPLITTER_POLEND_MISMATCH");
    }

    function _checkMemeverseLauncherDeployment(
        IMemeverseLauncher launcher,
        address initialOwner,
        address localEndpoint,
        address polendProxy,
        address polSplitterProxy,
        bool checkFundMetaData
    ) internal view {
        require(MemeverseLauncher(address(launcher)).owner() == initialOwner, "LAUNCHER_OWNER_MISMATCH");
        require(
            MemeverseLauncher(address(launcher)).getLauncherContracts().localLzEndpoint == localEndpoint,
            "LAUNCHER_ENDPOINT_MISMATCH"
        );
        require(MemeverseLauncher(address(launcher)).polend() == polendProxy, "LAUNCHER_POLEND_MISMATCH");
        require(
            MemeverseLauncher(address(launcher)).getLauncherContracts().polSplitter == polSplitterProxy,
            "LAUNCHER_SPLITTER_MISMATCH"
        );

        if (checkFundMetaData) {
            (uint256 uethMinTotalFund, uint256 uethFundBasedAmount) = launcher.fundMetaDatas(UETH);
            (uint256 uusdMinTotalFund, uint256 uusdFundBasedAmount) = launcher.fundMetaDatas(UUSD);
            require(uethMinTotalFund == 1e19 && uethFundBasedAmount == 1000000, "LAUNCHER_UETH_META_MISMATCH");
            require(uusdMinTotalFund == 20000 * 1e18 && uusdFundBasedAmount == 100000, "LAUNCHER_UUSD_META_MISMATCH");
        }
    }

    function _envAddressWithFallback(string memory primary, string memory fallbackName)
        internal
        view
        returns (address)
    {
        if (vm.envExists(primary)) return vm.envAddress(primary);
        return vm.envAddress(fallbackName);
    }

    function _optionalEnvAddress(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _openSupportedUAssetsAfterReadiness(address registrationCenter, address swapRouter, address hook)
        internal
    {
        _requireContractCode(registrationCenter, "REGISTRATION_CENTER_CODE_NOT_READY");
        _requireDeploymentReady(swapRouter, hook);

        IMemeverseRegistrationCenter(registrationCenter).setSupportedUAsset(UETH, true);
        IMemeverseRegistrationCenter(registrationCenter).setSupportedUAsset(UUSD, true);
    }

    function openSupportedUAssetsAfterReadiness(address registrationCenter, address swapRouter, address hook)
        public
        broadcaster
    {
        _loadReadinessEnv();
        _openSupportedUAssetsAfterReadiness(registrationCenter, swapRouter, hook);
    }

    function _requireDeploymentReady(address swapRouter, address hook) internal view {
        _requireContractCode(MEMEVERSE_LAUNCHER, "LAUNCHER_CODE_NOT_READY");
        _requireContractCode(MEMEVERSE_REGISTRAR, "REGISTRAR_CODE_NOT_READY");
        _requireContractCode(MEMEVERSE_PROXY_DEPLOYER, "PROXY_DEPLOYER_CODE_NOT_READY");
        _requireContractCode(MEMEVERSE_YIELD_DISPATCHER, "YIELD_DISPATCHER_CODE_NOT_READY");
        _requireContractCode(POLEND, "POLEND_CODE_NOT_READY");
        _requireContractCode(POLSPLITTER, "POLSPLITTER_CODE_NOT_READY");

        require(_readAddress(MEMEVERSE_LAUNCHER, "owner()") == owner, "LAUNCHER_OWNER_NOT_READY");
        require(
            _readAddress(MEMEVERSE_LAUNCHER, "memeverseRegistrar()") == MEMEVERSE_REGISTRAR,
            "LAUNCHER_REGISTRAR_NOT_READY"
        );
        require(
            _readAddress(MEMEVERSE_LAUNCHER, "memeverseProxyDeployer()") == MEMEVERSE_PROXY_DEPLOYER,
            "LAUNCHER_PROXY_DEPLOYER_NOT_READY"
        );
        require(
            _readAddress(MEMEVERSE_LAUNCHER, "yieldDispatcher()") == MEMEVERSE_YIELD_DISPATCHER,
            "LAUNCHER_YIELD_DISPATCHER_NOT_READY"
        );
        require(_readAddress(MEMEVERSE_LAUNCHER, "polend()") == POLEND, "LAUNCHER_POLEND_NOT_READY");
        require(_readAddress(MEMEVERSE_LAUNCHER, "polSplitter()") == POLSPLITTER, "LAUNCHER_POLSPLITTER_NOT_READY");
        require(
            _readAddress(MEMEVERSE_REGISTRAR, "MEMEVERSE_LAUNCHER()") == MEMEVERSE_LAUNCHER,
            "REGISTRAR_LAUNCHER_NOT_READY"
        );
        require(
            _readAddress(MEMEVERSE_PROXY_DEPLOYER, "memeverseLauncher()") == MEMEVERSE_LAUNCHER,
            "PROXY_DEPLOYER_LAUNCHER_NOT_READY"
        );
        require(
            _readAddress(MEMEVERSE_YIELD_DISPATCHER, "memeverseLauncher()") == MEMEVERSE_LAUNCHER,
            "YIELD_DISPATCHER_LAUNCHER_NOT_READY"
        );
        require(_readAddress(POLEND, "launcher()") == MEMEVERSE_LAUNCHER, "POLEND_LAUNCHER_NOT_READY");
        require(_readAddress(POLEND, "splitter()") == POLSPLITTER, "POLEND_SPLITTER_NOT_READY");
        // creditFactory is a POLend runtime pointer resolved on the user path
        // (leveragedGenesisWithCredit -> IGenesisCreditFactory(creditFactory).creditOf). Like the
        // bootstrap/fee siblings it is lazy-wired at initialize (a standalone POLend deploy with
        // CREDIT_FACTORY_PROXY unset falls back to the deploy owner); readiness must confirm a real
        // contract is bound before opening, else the owner placeholder (an EOA with no code) lets the
        // first leveragedGenesisWithCredit silently revert until setCreditFactory. Has-code (not !=0):
        // the owner fallback is non-zero and would pass a zero-check.
        _requireContractCode(_readAddress(POLEND, "creditFactory()"), "POLEND_CREDIT_FACTORY_NOT_READY");
        require(_readAddress(POLSPLITTER, "launcher()") == MEMEVERSE_LAUNCHER, "POLSPLITTER_LAUNCHER_NOT_READY");
        require(_readPolSplitterPolend() == POLEND, "POLSPLITTER_POLEND_NOT_READY");

        _requireReserveReady(UETH, "UETH_RESERVE_NOT_READY");
        _requireReserveReady(UUSD, "UUSD_RESERVE_NOT_READY");
        _requireFundMetaDataReady(UETH, "UETH_FUND_METADATA_NOT_READY");
        _requireFundMetaDataReady(UUSD, "UUSD_FUND_METADATA_NOT_READY");
        _requireSwapReady(swapRouter, hook);

        // bootstrapImpl / feeDistributorImpl / feePreviewReader are all delegatecall/view siblings the
        // facade uses on user paths (bootstrap deploy, redeem, changeStage Locked->Unlocked, fee preview).
        // readiness checks all three for code, symmetric with bootstrapImpl — a missing sibling would
        // otherwise only surface as a runtime FeeDistributorImplNotSet (or a broken preview) after the
        // system is already open to users.
        (address bootstrapImpl, address feeDistributorImpl, address feePreviewReader, address polMinterImpl) =
            _readLauncherImplSiblings(MEMEVERSE_LAUNCHER);
        _requireContractCode(bootstrapImpl, "BOOTSTRAP_IMPL_NOT_READY");
        _requireContractCode(feeDistributorImpl, "FEE_DISTRIBUTOR_IMPL_NOT_READY");
        _requireContractCode(feePreviewReader, "FEE_PREVIEW_READER_NOT_READY");
        _requireContractCode(polMinterImpl, "POL_MINTER_IMPL_NOT_READY");
    }

    function _requireSwapReady(address swapRouter, address hook) internal view {
        _requireContractCode(swapRouter, "ROUTER_CODE_NOT_READY");
        _requireContractCode(hook, "HOOK_CODE_NOT_READY");
        require(_hookFlags(hook) == MEMEVERSE_HOOK_FLAGS, "HOOK_FLAGS_NOT_READY");

        IMemeverseLauncher.LauncherContracts memory launcherContracts =
            IMemeverseLauncher(MEMEVERSE_LAUNCHER).getLauncherContracts();
        require(launcherContracts.memeverseSwapRouter == swapRouter, "LAUNCHER_ROUTER_NOT_READY");
        require(launcherContracts.memeverseUniswapHook == hook, "LAUNCHER_HOOK_NOT_READY");
        require(_readAddress(swapRouter, "hook()") == hook, "ROUTER_HOOK_NOT_READY");
        require(_readAddress(hook, "launcher()") == MEMEVERSE_LAUNCHER, "HOOK_LAUNCHER_NOT_READY");
        require(_readAddress(hook, "poolInitializer()") == swapRouter, "HOOK_POOL_INITIALIZER_NOT_READY");

        // Router and Hook each bind an immutable PoolManager at construction. The Router unlocks/initializes
        // on its own PoolManager, which then calls back into the Hook; the Hook's onlyPoolManager guard
        // compares msg.sender against the Hook's PoolManager. If the two differ, every swap and pool
        // initialization reverts with NotPoolManager, so the system must not open until they match.
        // (mirrors hook.initialize _requireFacetPoolManager, extended to the router<->hook diagonal).
        address hookPoolManager = _readAddress(hook, "poolManager()");
        address routerPoolManager = _readAddress(swapRouter, "poolManager()");
        require(routerPoolManager == hookPoolManager, "ROUTER_POOL_MANAGER_NOT_READY");

        // Diamond facets must exist and share the hook's PoolManager (mirrors hook.initialize _requireFacetPoolManager).
        address swapFacet = _readAddress(hook, "swapFacet()");
        address dynamicFeeFacet = _readAddress(hook, "dynamicFeeFacet()");
        address settlementFacet = _readAddress(hook, "settlementFacet()");
        _requireContractCode(swapFacet, "SWAP_FACET_CODE_NOT_READY");
        _requireContractCode(dynamicFeeFacet, "DYNAMIC_FEE_FACET_CODE_NOT_READY");
        _requireContractCode(settlementFacet, "SETTLEMENT_FACET_CODE_NOT_READY");
        require(_readAddress(swapFacet, "poolManager()") == hookPoolManager, "SWAP_FACET_POOL_MANAGER_NOT_READY");
        require(
            _readAddress(dynamicFeeFacet, "poolManager()") == hookPoolManager,
            "DYNAMIC_FEE_FACET_POOL_MANAGER_NOT_READY"
        );
        require(
            _readAddress(settlementFacet, "poolManager()") == hookPoolManager, "SETTLEMENT_FACET_POOL_MANAGER_NOT_READY"
        );
        // Facets deploy under distinct CREATE3 salts, so equal addresses would already fail the atomic
        // deploy. This mirrors that invariant so a future initialize/deploy registering a duplicate
        // facet is caught before the system opens (defense-in-depth, not a runtime check).
        require(
            swapFacet != dynamicFeeFacet && swapFacet != settlementFacet && dynamicFeeFacet != settlementFacet,
            "FACETS_NOT_DISTINCT"
        );

        // HookLens must exist and read from the same PoolManager as the Router.
        address lens = _readAddress(swapRouter, "hookLens()");
        _requireContractCode(lens, "LENS_CODE_NOT_READY");
        require(_readAddress(lens, "poolManager()") == routerPoolManager, "LENS_POOL_MANAGER_NOT_READY");
    }

    function _hookFlags(address hook) internal pure returns (uint160) {
        return uint160(hook) & UNISWAP_V4_HOOK_FLAG_MASK;
    }

    function _requireReserveReady(address uAsset, string memory errorMessage) internal view {
        (, uint128 maxReserve) = _readSettlementDustState(uAsset);
        // POLend refuses market registration until this cap is configured.
        require(maxReserve > 0, errorMessage);
    }

    function _requireFundMetaDataReady(address uAsset, string memory errorMessage) internal view {
        (uint256 minTotalFund, uint256 fundBasedAmount) = _readFundMetaData(uAsset);
        // Registration must stay closed until launcher funding thresholds are usable.
        require(minTotalFund > 0 && fundBasedAmount > 0, errorMessage);
        // Derived virtual buffer must be non-zero, mirroring setFundMetaData's guard: a zero V would
        // make MemecoinYieldVault.initialize revert and DoS governance-chain deploy.
        require(minTotalFund * fundBasedAmount * 7 / 1000 > 0, errorMessage);
    }

    function _requireContractCode(address target, string memory errorMessage) internal view {
        require(target.code.length > 0, errorMessage);
    }

    function _readAddress(address target, string memory signature) internal view returns (address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && data.length >= 32, "STATICCALL_ADDRESS_FAILED");
        value = abi.decode(data, (address));
    }

    function _readPolSplitterPolend() internal view returns (address value) {
        return _readAddress(POLSPLITTER, "polend()");
    }

    function _readLauncherImplSiblings(address launcher)
        internal
        view
        returns (address bootstrapImpl, address feeDistributorImpl, address feePreviewReader, address polMinterImpl)
    {
        (bool success, bytes memory data) = launcher.staticcall(abi.encodeWithSignature("getLauncherContracts()"));
        require(success && data.length >= 384, "LAUNCHER_CONTRACTS_NOT_READY");
        // Typed decode (same pattern as _requireSwapReady's getLauncherContracts() call) avoids
        // positional index magic numbers — a field rename/reorder surfaces at compile time instead
        // of silently misindexing. 384 = 12 fields × 32 bytes (all-static LauncherContracts struct).
        IMemeverseLauncher.LauncherContracts memory contracts = abi.decode(data, (IMemeverseLauncher.LauncherContracts));
        bootstrapImpl = contracts.bootstrapImpl;
        feeDistributorImpl = contracts.feeDistributorImpl;
        feePreviewReader = contracts.feePreviewReader;
        polMinterImpl = contracts.polMinterImpl;
    }

    function _readSettlementDustState(address uAsset) internal view returns (uint128 reserve, uint128 maxReserve) {
        (bool success, bytes memory data) =
            POLEND.staticcall(abi.encodeWithSignature("settlementDustStates(address)", uAsset));
        require(success && data.length >= 64, "SETTLEMENT_DUST_STATE_NOT_READY");
        return abi.decode(data, (uint128, uint128));
    }

    function _readFundMetaData(address uAsset) internal view returns (uint256 minTotalFund, uint256 fundBasedAmount) {
        (bool success, bytes memory data) =
            MEMEVERSE_LAUNCHER.staticcall(abi.encodeWithSignature("fundMetaDatas(address)", uAsset));
        require(success && data.length >= 64, "FUND_METADATA_NOT_READY");
        return abi.decode(data, (uint256, uint256));
    }

    function _deployYieldDispatcher(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory creationCode =
            abi.encodePacked(type(YieldDispatcher).creationCode, abi.encode(owner, localEndpoint, MEMEVERSE_LAUNCHER));

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", nonce));
        address memeverseOFTDispatcher = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("YieldDispatcher deployed on %s", memeverseOFTDispatcher);
    }

    function _deployMemeverseOmnichainInteroperation(uint256 nonce) internal {
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseOmnichainInteroperation).creationCode,
            abi.encode(owner, MEMEVERSE_COMMON_INFO, MEMEVERSE_LAUNCHER, OMNICHAIN_MEMECOIN_STAKER, 115000, 135000)
        );

        bytes32 salt = keccak256(abi.encodePacked("MemeverseOmnichainInteroperation", nonce));
        address staker = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("MemeverseOmnichainInteroperation deployed on %s", staker);
    }

    function _deployOmnichainMemecoinStaker(uint256 nonce) internal {
        address localEndpoint = endpoints[uint32(block.chainid)];

        bytes memory creationCode =
            abi.encodePacked(type(OmnichainMemecoinStaker).creationCode, abi.encode(localEndpoint));

        bytes32 salt = keccak256(abi.encodePacked("OmnichainMemecoinStaker", nonce));
        address staker = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("OmnichainMemecoinStaker deployed on %s", staker);
    }
}
