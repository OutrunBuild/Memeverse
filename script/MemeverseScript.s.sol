// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import "./BaseScript.s.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { ITokenDeployer } from "../src/token/deployer/interfaces/ITokenDeployer.sol";
import { MemecoinDeployer } from "../src/token/deployer/MemecoinDeployer.sol";
import { MemecoinDeployerOnBlast } from "../src/token/deployer/MemecoinDeployerOnBlast.sol";
import { LiquidProofDeployer } from "../src/token/deployer/LiquidProofDeployer.sol";
import { LiquidProofDeployerOnBlast } from "../src/token/deployer/LiquidProofDeployerOnBlast.sol";
import { MemeverseRegistrarOmnichain, MemeverseRegistrarOnBlast } from "../src/verse/MemeverseRegistrarOnBlast.sol";
import { MemeverseLauncherOnBlast } from "../src/verse/MemeverseLauncherOnBlast.sol";
import { IMemeverseRegistrar } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarAtLocal } from "../src/verse/MemeverseRegistrarAtLocal.sol";
import { MemeverseRegistrationCenter } from "../src/verse/MemeverseRegistrationCenter.sol";
import { IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrationCenter.sol";


contract MemeverseScript is BaseScript {
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;

    address internal UETH;
    address internal BLAST_GOVERNOR;
    address internal OUTRUN_DEPLOYER;
    address internal UETH_MEMEVERSE_LAUNCHER;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_REGISTRATION_CENTER;

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
        BLAST_GOVERNOR = vm.envAddress("BLAST_GOVERNOR");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");
        UETH_MEMEVERSE_LAUNCHER = vm.envAddress("UETH_MEMEVERSE_LAUNCHER");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");
        
        _getDeployedTokenDeployer(2);
        _getDeployedMemeverseRegistrar(2);
        _getDeployedRegistrationCenter(2);
        _getDeployedUETHMemeverseLauncher(2);

        // _deployRegistrationCenter(2);

        // _deployTokenDeployer(2);
        // _deployMemeverseRegistrar(2);
        // _deployUETHMemeverseLauncher(2);

        // IMemeverseRegistrationCenter.RegistrationParam memory param;
        // param.name = "abcc";
        // param.symbol = "abcc";
        // param.uri = "abcc";
        // param.durationDays = 3;
        // param.lockupDays = 200;
        // param.maxFund = 1 ether;
        // uint32[] memory ids = new uint32[](1);
        // ids[0] = 168587773;
        // param.omnichainIds = ids;
        // param.registrar = owner;

        // IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
        //     name: param.name,
        //     symbol: param.symbol,
        //     uri: param.uri,
        //     uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, block.timestamp, msg.sender))),
        //     maxFund: uint128(param.maxFund),
        //     endTime: uint64(block.timestamp + param.durationDays * DAY),
        //     unlockTime: uint64(block.timestamp + param.lockupDays * DAY),
        //     omnichainIds: param.omnichainIds,
        //     creator: param.registrar
        // });
        // bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(8000000) , 0);
        // (uint256 totalFee, , ) = IMemeverseRegistrationCenter(MEMEVERSE_REGISTRATION_CENTER).quoteSend(ids, options, abi.encode(memeverseParam));

        // IMemeverseRegistrationCenter(MEMEVERSE_REGISTRATION_CENTER).registration{value: totalFee}(param);
    }

    function _getDeployedUETHMemeverseLauncher(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", UETH, nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("UETHMemeverseLauncher deployed on %s", deployed);
    }

    function _getDeployedTokenDeployer(uint256 nonce) internal view {
        bytes32 memecoinSalt = keccak256(abi.encodePacked("TokenDeployer", "Memecoin", nonce));
        bytes32 liquidProofSalt = keccak256(abi.encodePacked("TokenDeployer", "LiquidProof", nonce));
        address memecoinDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, memecoinSalt);
        address liquidProofDeployer = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, liquidProofSalt);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployer);
        console.log("LiquidProofDeployer deployed on %s", liquidProofDeployer);
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

    function _deployRegistrationCenter(uint256 nonce) internal {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrationCenter", nonce));
        bytes memory creationCode = abi.encodePacked(
            type(MemeverseRegistrationCenter).creationCode,
            abi.encode(
                owner,
                vm.envAddress("BSC_TESTNET_ENDPOINT"),
                MEMEVERSE_REGISTRAR,
                8000000
            )
        );
        address centerAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        IMemeverseRegistrationCenter.LzEndpointIdPair[] memory endpointPairs = new IMemeverseRegistrationCenter.LzEndpointIdPair[](3);
        endpointPairs[0] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: 84532, endpointId: 40245});
        endpointPairs[1] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: 168587773, endpointId: 40243});
        endpointPairs[2] = IMemeverseRegistrationCenter.LzEndpointIdPair({ chainId: 5003, endpointId: 40246});
        IMemeverseRegistrationCenter(centerAddr).setLzEndpointIds(endpointPairs);

        IMemeverseRegistrationCenter.RegisterGasLimitPair[] memory gasLimitPairs = new IMemeverseRegistrationCenter.RegisterGasLimitPair[](3);
        gasLimitPairs[0] = IMemeverseRegistrationCenter.RegisterGasLimitPair({ chainId: 84532, gasLimit: 8000000});
        gasLimitPairs[1] = IMemeverseRegistrationCenter.RegisterGasLimitPair({ chainId: 168587773, gasLimit: 8000000});
        gasLimitPairs[2] = IMemeverseRegistrationCenter.RegisterGasLimitPair({ chainId: 5003, gasLimit: 40000000000});
        IMemeverseRegistrationCenter(centerAddr).setRegisterGasLimits(gasLimitPairs);

        IMemeverseRegistrationCenter(centerAddr).setDurationDaysRange(1, 7);
        IMemeverseRegistrationCenter(centerAddr).setLockupDaysRange(180, 365);

        IOAppCore(centerAddr).setPeer(uint32(vm.envUint("BASE_SEPOLIA_EID")), bytes32(abi.encode(MEMEVERSE_REGISTRAR)));
        IOAppCore(centerAddr).setPeer(uint32(vm.envUint("BLAST_SEPOLIA_EID")), bytes32(abi.encode(MEMEVERSE_REGISTRAR)));
        IOAppCore(centerAddr).setPeer(uint32(vm.envUint("MANTLE_SEPOLIA_EID")), bytes32(abi.encode(MEMEVERSE_REGISTRAR)));

        console.log("MemeverseRegistrationCenter deployed on %s", centerAddr);
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
                MEMEVERSE_REGISTRAR
            );
            memecoinDeployercreationBytecode = type(MemecoinDeployerOnBlast).creationCode;
            liquidProofDeployercreationBytecode = type(LiquidProofDeployerOnBlast).creationCode;
        } else if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BSC_TESTNET_ENDPOINT"),
                MEMEVERSE_REGISTRAR
            );
            memecoinDeployercreationBytecode = type(MemecoinDeployer).creationCode;
            liquidProofDeployercreationBytecode = type(LiquidProofDeployer).creationCode;
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BASE_SEPOLIA_ENDPOINT"),
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

        ITokenDeployer.LzEndpointIdPair[] memory endpointPairs = new ITokenDeployer.LzEndpointIdPair[](3);
        endpointPairs[0] = ITokenDeployer.LzEndpointIdPair({ chainId: 84532, endpointId: 40245});
        endpointPairs[1] = ITokenDeployer.LzEndpointIdPair({ chainId: 168587773, endpointId: 40243});
        endpointPairs[2] = ITokenDeployer.LzEndpointIdPair({ chainId: 5003, endpointId: 40246});
        ITokenDeployer(memecoinDeployerAddr).setLzEndpointIds(endpointPairs);
        ITokenDeployer(liquidProofDeployerAddr).setLzEndpointIds(endpointPairs);

        console.log("MemecoinDeployer deployed on %s", memecoinDeployerAddr);
        console.log("LiquidProofDeployer deployed on %s", liquidProofDeployerAddr);
    }

    function _deployMemeverseRegistrar(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        if (block.chainid == vm.envUint("BSC_TESTNET_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                MEMEVERSE_REGISTRATION_CENTER,
                vm.envAddress("MEMECOIN_DEPLOYER"),
                vm.envAddress("LIQUID_PROOF_DEPLOYER")
            );
            creationBytecode = type(MemeverseRegistrarAtLocal).creationCode;
        } else if (block.chainid == vm.envUint("BLAST_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                BLAST_GOVERNOR,
                vm.envAddress("BLAST_SEPOLIA_ENDPOINT"),
                vm.envAddress("MEMECOIN_DEPLOYER"),
                vm.envAddress("LIQUID_PROOF_DEPLOYER"),
                12000000,
                2000000,
                uint32(vm.envUint("BSC_TESTNET_EID"))
            );
            creationBytecode = type(MemeverseRegistrarOnBlast).creationCode;
        } else if (block.chainid == vm.envUint("BASE_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                owner,
                vm.envAddress("BASE_SEPOLIA_ENDPOINT"),
                vm.envAddress("MEMECOIN_DEPLOYER"),
                vm.envAddress("LIQUID_PROOF_DEPLOYER"),
                12000000,
                2000000,
                uint32(vm.envUint("BSC_TESTNET_EID"))
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
    }

    function _deployUETHMemeverseLauncher(uint256 nonce) internal {
        bytes memory encodedArgs;
        bytes memory creationBytecode;
        if (block.chainid == vm.envUint("BLAST_SEPOLIA_CHAINID")) {
            encodedArgs = abi.encode(
                "UETHMemeverseLauncher",
                "MVS-UETH",
                UETH,
                owner,
                signer,
                BLAST_GOVERNOR,
                revenuePool,
                factory,
                router,
                MEMEVERSE_REGISTRAR,
                1e16,
                1000
            );
            creationBytecode = type(MemeverseLauncherOnBlast).creationCode;
        } else {
            encodedArgs = abi.encode(
                "UETHMemeverseLauncher",
                "MVS-UETH",
                UETH,
                owner,
                signer,
                revenuePool,
                factory,
                router,
                MEMEVERSE_REGISTRAR,
                1e16,
                1000
            );
            creationBytecode = type(MemeverseLauncher).creationCode;
        }

        bytes32 salt = keccak256(abi.encodePacked("MemeverseLauncher", UETH, nonce));
        bytes memory creationCode = abi.encodePacked(
            creationBytecode,
            encodedArgs
        );
        address UETHMemeverseLauncherAddr = IOutrunDeployer(OUTRUN_DEPLOYER).deploy(salt, creationCode);

        console.log("UETHMemeverseLauncher deployed on %s", UETHMemeverseLauncherAddr);
    }
}
