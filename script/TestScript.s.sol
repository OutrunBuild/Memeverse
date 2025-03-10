// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import "./BaseScript.s.sol";
import { IMemecoinDaoGovernor } from "../src/governance/interfaces/IMemecoinDaoGovernor.sol";
import { IMemeverseRegistrarAtLocal } from "../src/verse/interfaces/IMemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrarOmnichain } from "../src/verse/interfaces/IMemeverseRegistrarOmnichain.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrar.sol";

contract TestScript is BaseScript {
    using OptionsBuilder for bytes;
    using Clones for address;

    uint256 public constant DAY = 24 * 3600;

    address internal owner;
    address internal UETH;
    address internal MEMEVERSE_REGISTRAR;
    address internal MEMEVERSE_REGISTRATION_CENTER;

    function run() public broadcaster {
        owner = vm.envAddress("OWNER");
        UETH = vm.envAddress("UETH");
        MEMEVERSE_REGISTRAR = vm.envAddress("MEMEVERSE_REGISTRAR");
        MEMEVERSE_REGISTRATION_CENTER = vm.envAddress("MEMEVERSE_REGISTRATION_CENTER");

        _registerTest();
        // _memecoinDaoGovernorData();
        // _testQuoteDistributionLzFee();
    }

    function _registerTest() internal {
        IMemeverseRegistrationCenter.RegistrationParam memory param;
        param.name = "GGG";
        param.symbol = "GGG";
        param.uri = "GGG";
        param.durationDays = 1;
        param.lockupDays = 1;
        uint32[] memory ids = new uint32[](2);
        ids[0] = 84532;
        ids[1] = 10143;

        param.omnichainIds = ids;
        param.creator = owner;
        param.upt = UETH;

        // Center Chain - MemeverseRegistrarAtLocal
        // uint256 totalFee = IMemeverseRegistrar(MEMEVERSE_REGISTRAR).quoteRegister(param, 0);
        // console.log("totalFee=", totalFee);
        
        uint256 totalFee = 0.01 ether;

        // IMemeverseRegistrar(MEMEVERSE_REGISTRAR).registerAtCenter{value: totalFee}(param, uint128(totalFee));

        uint256 lzFee = IMemeverseRegistrar(MEMEVERSE_REGISTRAR).quoteRegister(param, uint128(totalFee));
        IMemeverseRegistrar(MEMEVERSE_REGISTRAR).registerAtCenter{value: lzFee}(param, uint128(totalFee));
    }

    function _memecoinDaoGovernorData() internal view {
        bytes memory initData = abi.encodeWithSelector(
            IMemecoinDaoGovernor.initialize.selector,
            string(abi.encodePacked("aaa", " DAO")),
            IVotes(0x454c7b0b4dded6BC81f44737965d43AFC294b399),  // voting token
            1 days,              // voting delay
            1 weeks,             // voting period
            10000e18,            // proposal threshold (10000 tokens)
            30                   // quorum (30%)
        );

        console.logBytes(initData);
    }
}
