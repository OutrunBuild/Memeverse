// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IYieldDispatcher is ILayerZeroComposer {
    event OmnichainYieldsProcessed(
        bytes32 indexed guid,
        address indexed token, 
        bool indexed isMemecoin,
        address receiver,
        uint256 amount,
        bool isBurned
    );

    error AlreadyExecuted();
    
    error PermissionDenied();
}
