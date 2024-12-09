// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./BaseScript.s.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { MemeverseRegistrar } from "../src/token/MemeverseRegistrar.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";
import { MemeverseLauncherOnBlast } from "../src/verse/MemeverseLauncherOnBlast.sol";

contract MemeverseScript is BaseScript {
    address internal UETH;
    address internal BLAST_GOVERNOR;
    address internal OUTRUN_DEPLOYER;
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
        
        _getDeployedRegistrar(1);
        _getDeployedRegistrationCenter(1);
        // _deployUETHMemeverseLauncher(2);
        // _deployUETHMemeverseLauncherOnBlast(2);
    }

    function _getDeployedRegistrar(uint256 nonce) internal view {
        bytes32 salt = keccak256(abi.encodePacked("MemeverseRegistrar", nonce));
        address deployed = IOutrunDeployer(OUTRUN_DEPLOYER).getDeployed(owner, salt);

        console.log("MemeverseRegistrar deployed on %s", deployed);
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
