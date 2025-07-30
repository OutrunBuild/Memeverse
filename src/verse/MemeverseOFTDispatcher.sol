// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IBurnable } from "../common/interfaces/IBurnable.sol";
import { IOFTCompose } from "../common/layerzero/oft/IOFTCompose.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IMemeverseOFTDispatcher } from "./interfaces/IMemeverseOFTDispatcher.sol";
import { IMemecoinDaoGovernor } from "../governance/interfaces/IMemecoinDaoGovernor.sol";

/**
 * @title Memeverse OFT Dispatcher
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard, 
 *      accepts Memecoin Yield from other chains and then forwards it to the corresponding yield vault.
 */
contract MemeverseOFTDispatcher is IMemeverseOFTDispatcher, TokenHelper, Ownable {
    using Strings for string;

    address public immutable localEndpoint;
    address public immutable memeverseLauncher;

    constructor(address _owner, address _localEndpoint, address _memeverseLauncher) Ownable(_owner) {
        localEndpoint = _localEndpoint;
        memeverseLauncher = _memeverseLauncher;
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
        require(msg.sender == localEndpoint || msg.sender == memeverseLauncher, PermissionDenied());
        if (msg.sender == localEndpoint) require(!IOFTCompose(token).getComposeTxExecutedStatus(guid), AlreadyExecuted());

        bool isBurned;
        uint256 amount;
        TokenType tokenType;
        address receiver;
        if (msg.sender ==  memeverseLauncher) {
            (receiver, tokenType, amount) = abi.decode(message, (address, TokenType, uint256));
        } else {
            amount = OFTComposeMsgCodec.amountLD(message);
            (receiver, tokenType) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, TokenType));
            IOFTCompose(token).notifyComposeExecuted(guid);
        }

        if (tokenType == TokenType.MEMECOIN) {
            if (receiver.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _safeApproveInf(token, receiver);
                IMemecoinYieldVault(receiver).accumulateYields(amount);
            }
        } else if (tokenType == TokenType.UPT) {
            if (receiver.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _safeApproveInf(token, receiver);
                IMemecoinDaoGovernor(receiver).receiveTreasuryIncome(token, amount);
            }
        } else {
            IMemeverseLauncher.Stage stage = IMemeverseLauncher(memeverseLauncher).getStageByMemecoin(token);
            if (receiver.code.length == 0 && stage == IMemeverseLauncher.Stage.Refund) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _transferOut(token, receiver, amount);
            }
        }

        emit OFTProcessed(guid, token, tokenType, receiver, amount, isBurned);
    }
}
