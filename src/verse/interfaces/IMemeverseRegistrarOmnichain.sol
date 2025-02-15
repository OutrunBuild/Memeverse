//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

interface IMemeverseRegistrarOmnichain {
    function quoteRegister(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) external view returns (uint256 lzFee);

    function setBaseRegisterGasLimit(uint64 baseRegisterGasLimit) external;

    function setLocalRegisterGasLimit(uint64 localRegisterGasLimit) external;

    function setOmnichainRegisterGasLimit(uint64 omnichainRegisterGasLimit) external;

    function setCancelRegisterGasLimit(uint64 cancelRegisterGasLimit) external;

    error InsufficientLzFee();
}
