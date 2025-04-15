// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IOFTCompose } from "../common/layerzero/oft/IOFTCompose.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IOmnichainMemecoinStaker } from "./interfaces/IOmnichainMemecoinStaker.sol";

/**
 * @title Omnichain Memecoin Staker
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard, 
 *      accepts Memecoin and stakes to the yield vault.
 */
contract OmnichainMemecoinStaker is IOmnichainMemecoinStaker, TokenHelper, Ownable {
    address public immutable localEndpoint;

    constructor(address _owner, address _localEndpoint) Ownable(_owner) {
        localEndpoint = _localEndpoint;
    }

    /**
     * @notice Redirect the yields of different Memecoins to their yield vault.
     * @param token - The token address initiating the composition, typically the OFT where the lzReceive was called.
     * @param guid The unique identifier for the received LayerZero message.
     * @param message - The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
     */
    function lzCompose(
        address token,
        bytes32 guid,
        bytes calldata message,
        address /*executor*/,
        bytes calldata /*extraData*/
    ) external payable override {
        require(msg.sender == localEndpoint, PermissionDenied());
        require(!IOFTCompose(token).getComposeTxExecutedStatus(guid), AlreadyExecuted());

        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        (address receiver, address yieldVault) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, address));
        if (yieldVault.code.length == 0) {
            _transferOut(token, receiver, amount);
        } else {
            _safeApproveInf(token, yieldVault);
            IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
        }
        IOFTCompose(token).notifyComposeExecuted(guid);

        emit OmnichainMemecoinStakingProcessed(token, yieldVault, receiver, amount);
    }
}
