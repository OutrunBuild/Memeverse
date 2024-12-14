//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemeverseRegistrationCenter } from "../../verse/interfaces/IMemeverseRegistrationCenter.sol";

interface IMemeverseRegistrar {
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
    }

    function registerAtCenter(IMemeverseRegistrationCenter.RegistrationParam calldata param, uint128 value) external payable;

    /**
     * @dev The registration will be cancelled if the total liquidity of the Omnichain fails to meet the requirement.
     */
    function cancelRegistration( 
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable;

    function setMemecoinDeployer(address memecoinDeployer) external;

    function setLiquidProofDeployer(address liquidProofDeployer) external;

    function setMemeverseLauncher(address memeverseLauncher) external;

    function updateSigner(address signer) external;

    error ZeroAddress();

    error InvalidSigner();

    error ExpiredSignature(uint256 deadline);
}