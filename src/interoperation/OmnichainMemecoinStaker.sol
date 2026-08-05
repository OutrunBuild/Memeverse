// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {IOFTCompose} from "../common/omnichain/oft/IOFTCompose.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IOmnichainMemecoinStaker} from "./interfaces/IOmnichainMemecoinStaker.sol";

/**
 * @title Omnichain Memecoin Staker
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard,
 *      accepts Memecoin and stakes to the yield vault.
 */
contract OmnichainMemecoinStaker is IOmnichainMemecoinStaker, TokenHelper {
    address public immutable localEndpoint;

    constructor(address _localEndpoint) {
        localEndpoint = _localEndpoint;
    }

    /// @notice Finalizes a remote memecoin staking compose message.
    /// @dev Only the local OFT endpoint may call this after bridged memecoin arrives on the governance chain. If the
    ///      destination vault exists, the tokens are deposited there for the receiver; otherwise they are transferred
    ///      directly to the receiver as a fallback. The compose guid is marked executed only after local settlement
    ///      succeeds, so a settlement revert leaves the message available for endpoint retry.
    /// @param memecoin Bridged memecoin address.
    /// @param guid Compose guid used for replay protection.
    /// @param message Encoded compose payload containing the receiver and yield-vault target.
    /// @param executor Compose executor reported by the endpoint.
    /// @param extraData Extra endpoint-provided metadata, currently ignored.
    function lzCompose(
        address memecoin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable override {
        executor;
        extraData;
        require(msg.sender == localEndpoint, PermissionDenied());
        require(!IOFTCompose(memecoin).getComposeTxExecutedStatus(guid), AlreadyExecuted());

        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        (address receiver, address yieldVault) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, address));
        if (yieldVault.code.length == 0) {
            // If the predicted vault is not deployed on the destination chain yet, release the bridged memecoin to the user instead of trapping it.
            _transferOut(memecoin, receiver, amount);
        } else {
            // Otherwise complete the happy path locally by staking the bridged memecoin into the target vault for the receiver.
            _safeApproveInf(memecoin, yieldVault);
            IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
        }
        // Mark the compose as consumed only after one of the local delivery branches succeeds.
        IOFTCompose(memecoin).notifyComposeExecuted(guid);

        emit OmnichainMemecoinStakingProcessed(guid, memecoin, yieldVault, receiver, amount);
    }
}
