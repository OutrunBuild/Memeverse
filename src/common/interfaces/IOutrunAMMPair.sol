// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IOutrunAMMPair {
    function token0() external view returns (address);
    
    function token1() external view returns (address);

    function previewMakerFee() external view returns (uint256 amount0, uint256 amount1);

    function claimMakerFee() external returns (uint256 amount0, uint256 amount1);
}
