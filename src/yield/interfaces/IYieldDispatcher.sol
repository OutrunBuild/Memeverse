// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

interface IYieldDispatcher is ILayerZeroComposer {
    function setRevenuePool(address _revenuePool) external;
    
    function setProtocolFeeRate(uint256 _protocolFeeRate) external;

    event OmnichainAccumulateYields(
        address indexed memecoin, 
        address indexed yieldVault, 
        uint256 yield, 
        uint256 protocolFee
    );

    error ZeroInput();

    error FeeRateOverFlow();

    error PermissionDenied();
}
