// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IYieldDispatcher is ILayerZeroComposer {
    event OmnichainYieldsProcessed(
        address indexed token, 
        string tokenType,
        address indexed receiver,
        uint256 amount,
        bool indexed isBurned
    );

    error AlreadyExecuted();
    
    error PermissionDenied();
}
