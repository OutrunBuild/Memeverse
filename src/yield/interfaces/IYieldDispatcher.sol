// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IYieldDispatcher is ILayerZeroComposer {
    event OmnichainYieldsProcessed(
        uint256 indexed verseId, 
        address indexed token, 
        bool indexed isBurned,
        uint256 amount
    );

    error PermissionDenied();
}
