// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseRegistrationCenter} from "./IMemeverseRegistrationCenter.sol";

/**
 * @title Memeverse Registrar Interface
 */
interface IMemeverseRegistrar {
    struct MemeverseParam {
        string name; // Token name
        string symbol; // Token symbol
        string uri; // Token icon uri
        string desc; // Description
        string[] communities; // Community, index -> 0:Website, 1:X, 2:Discord, 3:Telegram, >4:Others
        uint256 uniqueId; // Memeverse uniqueId
        uint64 endTime; // EndTime of launchPool
        uint64 unlockTime; // UnlockTime of liquidity
        uint32[] omnichainIds; // ChainIds of the token's omnichain(EVM)
        address uAsset; // uAsset of Memeverse
        bool flashGenesis; // Allowing the transition to the liquidity lock stage once the minimum funding requirement is met, without waiting for the genesis stage to end.
    }

    /// @notice Quotes the registration fee for this registrar implementation.
    /// @dev The meaning of `value` depends on the concrete registrar. Omnichain registrars use it as the
    /// executor-native drop encoded into LayerZero receive options, while the local registrar ignores it.
    /// @param param Registration request forwarded toward the registration center.
    /// @param value Registrar-specific native-drop value used when building the quote.
    /// @return lzFee Native fee required to execute the registration flow.
    function quoteRegister(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value)
        external
        view
        returns (uint256 lzFee);

    /// @notice Forwards a registration request toward the registration center.
    /// @dev The caller must supply the native fee expected by the concrete registrar path.
    /// @param param Registration request to submit.
    /// @param value Registrar-specific native-drop value or forwarded center fee, depending on the implementation.
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value)
        external
        payable;
}
