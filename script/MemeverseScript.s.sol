// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./BaseScript.s.sol";
import { IOutrunDeployer } from "./IOutrunDeployer.sol";
import { MemeverseLauncher } from "../src/verse/MemeverseLauncher.sol";

contract MemeverseScript is BaseScript {
    address internal UETH;
    address internal OUTRUN_DEPLOYER;
    address internal owner;
    address internal revenuePool;
    address internal factory;
    address internal router;
    

    function run() public broadcaster {
        UETH = vm.envAddress("UETH");
        owner = vm.envAddress("OWNER");
        revenuePool = vm.envAddress("REVENUPOOL");
        factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        router = vm.envAddress("OUTRUN_AMM_ROUTER");
        OUTRUN_DEPLOYER = vm.envAddress("OUTRUN_DEPLOYER");
        
        _deployUETHMemeverseLauncher(1);
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
}
