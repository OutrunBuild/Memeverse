//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

/**
 * @dev Interface for the Memeverse Registrar.
 */
interface IMemeverseRegistrar {
    struct MemeverseParam {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        uint256 uniqueId;               // Memeverse uniqueId
        uint64 endTime;                 // EndTime of launchPool
        uint64 unlockTime;              // UnlockTime of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        address creator;                // Memeverse creator
        address upt;                    // UPT of Memeverse
    }

    struct UPTLauncherPair {
        address upt;
        address memeverseLauncher;
    }

    function quoteRegister(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) external view returns (uint256 lzFee);

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable;

    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external;


    error ZeroAddress();

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);


    event SetLocalEndpoint(address indexed localEndpoint);

    event SetUPTLauncher(UPTLauncherPair[] pairs);
}