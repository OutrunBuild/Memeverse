// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseRegistrar} from "./IMemeverseRegistrar.sol";

interface IMemeverseRegistrarAtLocal {
    /// @notice Registers the memeverse locally after the center has accepted the symbol.
    /// @dev Only the registration center is allowed to call this hook.
    /// @param param Fully expanded memeverse configuration derived by the registration center.
    function localRegistration(IMemeverseRegistrar.MemeverseParam calldata param) external;

    /// @notice Updates the registration center trusted by this registrar.
    /// @dev Expected to be restricted by the implementation's ownership checks.
    /// @param registrationCenter New registration center address.
    function setRegistrationCenter(address registrationCenter) external;

    event SetRegistrationCenter(address registrationCenter);

    error ZeroAddress();

    error PermissionDenied();
}
