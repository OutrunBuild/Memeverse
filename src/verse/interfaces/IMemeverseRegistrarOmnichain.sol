//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

/**
 * @dev Interface for the Memeverse Registrar on Omnichain.
 */
interface IMemeverseRegistrarOmnichain {
    function setBaseRegisterGasLimit(uint64 baseRegisterGasLimit) external;

    function setLocalRegisterGasLimit(uint64 localRegisterGasLimit) external;

    function setOmnichainRegisterGasLimit(uint64 omnichainRegisterGasLimit) external;

    function setCancelRegisterGasLimit(uint64 cancelRegisterGasLimit) external;

    error InsufficientLzFee();
}
