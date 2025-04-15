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

        bool isBurned = false;
        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        (address receiver, string memory tokenType) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, string));
        if (receiver.code.length == 0) {
            IBurnable(token).burn(amount);
            isBurned = true;
        } else {
            if (tokenType.equal("Memecoin")) {
                _safeApproveInf(token, receiver);
                IMemecoinYieldVault(receiver).accumulateYields(amount);
            } else if (tokenType.equal("UPT")) {
                _transferOut(token, receiver, amount);
            }
        }
        IOFTCompose(token).notifyComposeExecuted(guid);

        emit OmnichainYieldsProcessed(token, tokenType, receiver, amount, isBurned);
    }
}
