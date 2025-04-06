// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title Memeverse Omnichain Interoperation Interface
 */ 
interface IMemeverseOmnichainInteroperation {
    function quoteMemecoinStaking(
        address memecoin,
        address receiver,
        uint256 amount
    ) external view returns (uint256 lzFee);

    function memecoinStaking(
        address memecoin,
        address receiver,
        uint256 amount
    ) external payable;

    function setGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit) external;

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit);

    error ZeroInput();

    error EmptyYieldVault();

    error InsufficientLzFee();
}
