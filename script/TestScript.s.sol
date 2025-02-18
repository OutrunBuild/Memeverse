// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import "./BaseScript.s.sol";
import { IMemeverseRegistrarAtLocal } from "../src/verse/interfaces/IMemeverseRegistrarAtLocal.sol";
import { IMemeverseRegistrarOmnichain } from "../src/verse/interfaces/IMemeverseRegistrarOmnichain.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrar.sol";

contract TestScript is BaseScript {
    using OptionsBuilder for bytes;

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
    }

    function _registerTest() internal {
        IMemeverseRegistrationCenter.RegistrationParam memory param;
        param.name = "aasa";
        param.symbol = "asaa";
        param.uri = "aasa";
        param.durationDays = 1;
        param.lockupDays = 1;
        uint32[] memory ids = new uint32[](2);
        ids[0] = 97;
        ids[1] = 84532;
        param.omnichainIds = ids;
        param.creator = owner;
        param.upt = UETH;

        // uint256 totalFee = IMemeverseRegistrar(MEMEVERSE_REGISTRAR).quoteRegister(param, 0);
        // console.log("totalFee=", totalFee);
        
        uint256 totalFee = 0.00033 ether;

        // IMemeverseRegistrar(MEMEVERSE_REGISTRAR).registerAtCenter{value: totalFee}(param, uint128(totalFee));

        uint256 lzFee = IMemeverseRegistrar(MEMEVERSE_REGISTRAR).quoteRegister(param, uint128(totalFee));
        IMemeverseRegistrar(MEMEVERSE_REGISTRAR).registerAtCenter{value: lzFee}(param, uint128(totalFee));
    }
}
