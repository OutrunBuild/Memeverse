//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrar } from "../../verse/interfaces/IMemeverseRegistrar.sol";

interface IMemeverseRegistrarAtLocal {
    function localRegistration(IMemeverseRegistrar.MemeverseParam calldata param) external returns (address memecoin);

    function setRegistrationCenter(address registrationCenter) external;

    event SetRegistrationCenter(address registrationCenter);
}