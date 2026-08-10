// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title Memeverse Omnichain Registrar Interface
 */
interface IMemeverseRegistrarOmnichain {
    struct RegistrationGasLimit {
        uint80 baseRegistrationGasLimit;
        uint80 localRegistrationGasLimit;
        uint80 omnichainRegistrationGasLimit;
    }

    /// @notice Updates the LayerZero gas schedule used for omnichain registrations.
    /// @dev Expected to be restricted by the implementation's ownership checks.
    /// @param registrationGasLimit New gas schedule for the center-chain registration receive path.
    function setRegistrationGasLimit(RegistrationGasLimit calldata registrationGasLimit) external;

    error InsufficientLzFee();

    event SetRegistrationGasLimit(RegistrationGasLimit registrationGasLimit);
}
