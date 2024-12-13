//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

interface IMemeverseRegistrarOmnichain {
    function setRegisterGasLimit(uint128 registerGasLimit) external;

    function setCancelRegisterGasLimit(uint128 cancelRegisterGasLimit) external;

    error InsufficientFee();
}