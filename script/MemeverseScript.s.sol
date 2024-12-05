// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./BaseScript.s.sol";
import "../src/verse/MemeverseLauncher.sol";

contract MemeverseScript is BaseScript {
    function run() public broadcaster {
        address UBNB = vm.envAddress("UBNB");
        address owner = vm.envAddress("OWNER");
        address revenuePool = vm.envAddress("REVENUPOOL");
        address factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        address router = vm.envAddress("OUTRUN_AMM_ROUTER");
        
        MemeverseLauncher UBNBMemeverseLauncher = new MemeverseLauncher(
            "UBNBMemeverseLauncher",
            "MVS-UBNB",
            UBNB,
            owner,
            revenuePool,
            factory,
            router,
            20 * 1e18,
            1000
        );
        address UBNBMemeverseLauncherAddr = address(UBNBMemeverseLauncher);
        console.log("UBNBMemeverseLauncher deployed on %s", UBNBMemeverseLauncherAddr);
    }
}
