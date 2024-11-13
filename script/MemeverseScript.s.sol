// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./BaseScript.s.sol";
import "../src/verse/MemeverseLauncher.sol";

contract MemeverseScript is BaseScript {
    function run() public broadcaster {
        address UBNB = vm.envAddress("UBNB");
        address owner = vm.envAddress("OWNER");
        address signer = vm.envAddress("SIGNER");
        address revenuePool = vm.envAddress("REVENUPOOL");
        address factory = vm.envAddress("OUTRUN_AMM_FACTORY");
        address router = vm.envAddress("OUTRUN_AMM_ROUTER");
        
        MemeverseLauncher UBNBMemeverseLauncher = new MemeverseLauncher(
            "UBNBMemeverseLauncher",
            "MVS-UBNB",
            UBNB,
            owner,
            signer,
            revenuePool,
            factory,
            router
        );
        address UBNBMemeverseLauncherAddr = address(UBNBMemeverseLauncher);
        console.log("UBNBMemeverseLauncher deployed on %s", UBNBMemeverseLauncherAddr);

        uint256 genesisFee = 0.001 ether;
        uint256 minTotalFund = 20 * 1e18;
        uint256 fundBasedAmount = 1000;
        uint128 minDurationDays = 1;
        uint128 maxDurationDays = 7;
        uint128 minLockupDays = 365;
        uint128 maxLockupDays = 1095;

        UBNBMemeverseLauncher.initialize(
            genesisFee,
            minTotalFund,
            fundBasedAmount,
            minDurationDays, 
            maxDurationDays, 
            minLockupDays, 
            maxLockupDays
        );
    }
}
