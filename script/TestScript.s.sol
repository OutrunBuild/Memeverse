// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import "./BaseScript.s.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "../src/verse/interfaces/IMemeverseRegistrar.sol";
import { MemeverseRegistrarOmnichain, IMemeverseRegistrarOmnichain } from "../src/verse/MemeverseRegistrarOmnichain.sol";

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
        param.name = "xzxcc";
        param.symbol = "xzxcc";
        param.uri = "xxzcc";
        param.durationDays = 1;
        param.lockupDays = 1;
        uint32[] memory ids = new uint32[](2);
        ids[0] = 97;
        ids[1] = 84532;
        param.omnichainIds = ids;
        param.creator = owner;
        param.upt = UETH;

        // IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
        //     name: param.name,
        //     symbol: param.symbol,
        //     uri: param.uri,
        //     uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, block.timestamp, msg.sender))),
        //     endTime: uint64(block.timestamp + param.durationDays * DAY),
        //     unlockTime: uint64(block.timestamp + param.lockupDays * DAY),
        //     omnichainIds: param.omnichainIds,
        //     creator: param.creator,
        //     upt: param.upt
        // });
        // (uint256 totalFee, , ) = IMemeverseRegistrationCenter(MEMEVERSE_REGISTRATION_CENTER).quoteSend(ids, abi.encode(memeverseParam));
        // console.log("totalFee=", totalFee);

        uint256 totalFee = 0.00033 ether;
        uint256 lzFee = IMemeverseRegistrarOmnichain(MEMEVERSE_REGISTRAR).quoteRegister(param, uint128(totalFee));
        IMemeverseRegistrar(MEMEVERSE_REGISTRAR).registerAtCenter{value: lzFee}(param, uint128(totalFee));
    }
}
