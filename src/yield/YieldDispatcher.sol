// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { IBurnable } from "../common/IBurnable.sol";
import { TokenHelper } from "../common/TokenHelper.sol";
import { IYieldDispatcher } from "./interfaces/IYieldDispatcher.sol";
import { IOFTCompose } from "../common/layerzero/oft/IOFTCompose.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";

/**
 * @title Memecoin Yield Dispatcher
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard, 
 *      accepts Memecoin Yield from other chains and then forwards it to the corresponding yield vault.
 */
contract YieldDispatcher is IYieldDispatcher, TokenHelper, Ownable {
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
        bool isMemecoin;
        address receiver;
        if (msg.sender ==  memeverseLauncher) {
            (receiver, isMemecoin, amount) = abi.decode(message, (address, bool, uint256));
        } else {
            amount = OFTComposeMsgCodec.amountLD(message);
            (receiver, isMemecoin) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, bool));
            IOFTCompose(token).notifyComposeExecuted(guid);
        }

        if (receiver.code.length == 0) {
            IBurnable(token).burn(amount);
            isBurned = true;
        } else {
            if (isMemecoin) {
                _safeApproveInf(token, receiver);
                IMemecoinYieldVault(receiver).accumulateYields(amount);
            } else {
                _transferOut(token, receiver, amount);
            }
        }

        emit OmnichainYieldsProcessed(guid, token, isMemecoin, receiver, amount, isBurned);
    }
}
