//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

interface IMemeverseRegistrar {
    struct LzEndpointIdPair {
        uint32 chainId;
        uint32 endpointId;
    }

    struct MemeverseParam {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        uint256 uniqueId;               // Memeverse uniqueId
        uint128 maxFund;                // Max fundraising(UPT) limit, if 0 => no limit
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

    function getEndpointId(uint32 chainId) external view returns (uint32 endpointId);

    function quoteCancel(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param
    ) external view returns (uint256 lzFee);

    /**
     * @dev Register through cross-chain at the RegistrationCenter
     */
    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable;

    function cancelRegistration( 
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress
    ) external payable;

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external;

    function setMemecoinDeployer(address memecoinDeployer) external;

    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external;

    error ZeroAddress();

    error PermissionDenied();

    error InvalidOmnichainId(uint32 omnichainId);
}