//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

interface IMemeverseRegistrarOmnichain {
    function quoteRegister(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) external view returns (uint256 lzFee);

    function setRegisterGasLimit(uint128 registerGasLimit) external;

    function setCancelRegisterGasLimit(uint128 cancelRegisterGasLimit) external;

    error InsufficientLzFee();
}
