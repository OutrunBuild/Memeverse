//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev Interface for the Memeverse Registrar on Omnichain.
 */
interface IMemeverseRegistrarOmnichain {
    struct RegistrationGasLimit {
        uint80 baseRegistrationGasLimit;
        uint80 localRegistrationGasLimit;
        uint80 omnichainRegistrationGasLimit;
    }

    function setRegistrationGasLimit(RegistrationGasLimit calldata registrationGasLimit) external;

    error InsufficientLzFee();

    event SetRegistrationGasLimit(RegistrationGasLimit registrationGasLimit);
}
