// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ICrossChainSendErrors} from "../../common/types/ICrossChainSendErrors.sol";

/**
 * @title Memeverse Omnichain Interoperation Interface
 */
interface IMemeverseOmnichainInteroperation is ICrossChainSendErrors {
    /// @notice Quotes the LayerZero fee required to stake a memecoin on the governance chain.
    /// @dev Returns zero when the memecoin already belongs to the local governance chain.
    /// @param memecoin Memecoin address to stake.
    /// @param receiver Final staking beneficiary on the governance chain.
    /// @param amount Token amount to stake.
    /// @return lzFee Native LayerZero fee required for the remote staking path.
    function quoteMemecoinStaking(address memecoin, address receiver, uint256 amount)
        external
        view
        returns (uint256 lzFee);

    /// @notice Stakes memecoin either locally or through the omnichain staker.
    /// @dev Local paths require `msg.value == 0`; remote paths require the exact quoted LayerZero fee.
    /// @param memecoin Memecoin address to stake.
    /// @param receiver Final staking beneficiary.
    /// @param amount Token amount to stake.
    function memecoinStaking(address memecoin, address receiver, uint256 amount) external payable;

    /// @notice Updates the gas limits used by remote staking sends.
    /// @dev Expected to be restricted by the implementation's ownership checks.
    /// @param oftReceiveGasLimit Gas allocated to the governance-chain OFT receive hook.
    /// @param omnichainStakingGasLimit Gas allocated to the compose staking callback.
    function setGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit) external;

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit);

    event OmnichainMemecoinStaking(
        bytes32 indexed guid, address indexed sender, address receiver, address indexed memecoin, uint256 amount
    );

    error ZeroInput();

    error EmptyYieldVault();

    error InvalidLzFee(uint256 expected, uint256 actual);

    error ZeroAddress();
}
