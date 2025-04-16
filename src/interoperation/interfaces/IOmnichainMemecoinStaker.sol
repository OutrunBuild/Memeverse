// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IOmnichainMemecoinStaker is ILayerZeroComposer {
    event OmnichainMemecoinStakingProcessed(
        bytes32 indexed guid,
        address indexed memecoin, 
        address indexed yieldVault, 
        address receiver, 
        uint256 amount
    );

    error AlreadyExecuted();

    error PermissionDenied();
}
