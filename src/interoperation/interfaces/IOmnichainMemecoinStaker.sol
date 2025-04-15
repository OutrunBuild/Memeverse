// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IOmnichainMemecoinStaker is ILayerZeroComposer {
    event OmnichainMemecoinStakingProcessed(
        address indexed memecoin, 
        address indexed yieldVault, 
        address indexed receiver, 
        uint256 amount
    );

    error AlreadyExecuted();

    error PermissionDenied();
}
