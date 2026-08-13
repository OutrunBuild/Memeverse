// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

contract VerifySlots {
    function run() external pure {
        // All 15 outrun.storage.* / outrun.layerzerov2.storage.* namespaces
        bytes32 s1 =
            keccak256(abi.encode(uint256(keccak256("outrun.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s2 = keccak256(abi.encode(uint256(keccak256("outrun.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s3 = keccak256(abi.encode(uint256(keccak256("outrun.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s4 = keccak256(abi.encode(uint256(keccak256("outrun.storage.Nonces")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s5 = keccak256(abi.encode(uint256(keccak256("outrun.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s6 = keccak256(abi.encode(uint256(keccak256("outrun.storage.Votes")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s7 = keccak256(abi.encode(uint256(keccak256("outrun.storage.GovernanceCycleIncentivizer")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s8 = keccak256(abi.encode(uint256(keccak256("outrun.storage.MemecoinDaoGovernor")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s9 = keccak256(abi.encode(uint256(keccak256("outrun.storage.POLend")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s10 =
            keccak256(abi.encode(uint256(keccak256("outrun.storage.POLSplitter")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 s11 = keccak256(abi.encode(uint256(keccak256("outrun.storage.MemeverseUniswapHook")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s12 = keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OAppCore")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s13 = keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OAppOptionsType3")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s14 = keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OAppPreCrimeSimulator")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 s15 = keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OFTCore")) - 1))
            & ~bytes32(uint256(0xff));

        console2.log("Initializable:");
        console2.logBytes32(s1);
        console2.log("Ownable:");
        console2.logBytes32(s2);
        console2.log("ERC20:");
        console2.logBytes32(s3);
        console2.log("Nonces:");
        console2.logBytes32(s4);
        console2.log("EIP712:");
        console2.logBytes32(s5);
        console2.log("Votes:");
        console2.logBytes32(s6);
        console2.log("GovernanceCycleIncentivizer:");
        console2.logBytes32(s7);
        console2.log("MemecoinDaoGovernor:");
        console2.logBytes32(s8);
        console2.log("POLendUpgradeable:");
        console2.logBytes32(s9);
        console2.log("POLSplitterUpgradeable:");
        console2.logBytes32(s10);
        console2.log("MemeverseUniswapHookUpgradeable:");
        console2.logBytes32(s11);
        console2.log("OAppCore:");
        console2.logBytes32(s12);
        console2.log("OAppOptionsType3:");
        console2.logBytes32(s13);
        console2.log("OAppPreCrimeSimulator:");
        console2.logBytes32(s14);
        console2.log("OFTCore:");
        console2.logBytes32(s15);
    }
}
