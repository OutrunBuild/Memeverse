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
    /// @dev Expected to be restricted by the implementation's ownership checks. Only `> 0` is validated: a
    ///      `oftReceiveGasLimit` below the destination execution budget stalls the message (executor delivery always
    ///      runs out of gas; no protocol-internal settle for the receive side — recovery is a permissionless
    ///      `EndpointV2.lzReceive` re-delivery on the destination chain); a too-low `omnichainStakingGasLimit` is
    ///      recoverable via `settlePendingCompose` (bare-token release).
    /// @param oftReceiveGasLimit Gas allocated to the governance-chain OFT receive hook.
    /// @param omnichainStakingGasLimit Gas allocated to the compose staking callback.
    function setGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit) external;

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 omnichainStakingGasLimit);

    /// @notice Emitted for a remote-path staking send, with the OFT-truncated amounts.
    /// @dev For a non-exact-multiple `amount`, the OFT send burns only `amountSentLD` (truncated to the shared-decimal
    ///      rate) and the un-burnt `remainder` (`amount - amountSentLD`) is refunded to `sender` in the same
    ///      transaction, so `amountSentLD + remainder == amount`. `remainder` is zero for exact multiples.
    /// @param guid LayerZero send guid.
    /// @param sender Caller of `memecoinStaking`.
    /// @param receiver Final staking beneficiary on the governance chain.
    /// @param memecoin Memecoin staked.
    /// @param amount Original input amount requested by the caller.
    /// @param amountSentLD Amount actually burned/staked after OFT truncation.
    /// @param remainder Un-burnt remainder refunded to `sender` in the same transaction.
    event OmnichainMemecoinStaking(
        bytes32 indexed guid,
        address indexed sender,
        address receiver,
        address indexed memecoin,
        uint256 amount,
        uint256 amountSentLD,
        uint256 remainder
    );

    error ZeroInput();

    error EmptyYieldVault();

    error InvalidLzFee(uint256 expected, uint256 actual);

    error ZeroAddress();
}
