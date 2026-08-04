// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {IBurnable} from "../common/interfaces/IBurnable.sol";
import {IOFTCompose} from "../common/omnichain/oft/IOFTCompose.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IYieldDispatcher} from "./interfaces/IYieldDispatcher.sol";
import {IMemecoinDaoGovernor} from "../governance/interfaces/IMemecoinDaoGovernor.sol";

/**
 * @title Yield Dispatcher
 * @dev Routes bridged or same-chain launcher fee proceeds to the yield vault or governor treasury.
 *      Cross-chain deliveries arrive through LayerZero's OFT compose flow (`lzCompose`); the launcher's
 *      same-chain fast path uses the dedicated `distributeSameChain` entry.
 */
contract YieldDispatcher is IYieldDispatcher, TokenHelper, Ownable {
    address public immutable localEndpoint;
    address public immutable memeverseLauncher;

    constructor(address _owner, address _localEndpoint, address _memeverseLauncher) Ownable(_owner) {
        localEndpoint = _localEndpoint;
        memeverseLauncher = _memeverseLauncher;
    }

    /// @notice Processes an incoming OFT compose payload for protocol treasury routing.
    /// @dev Only the local LayerZero endpoint may call this. Replay protection relies on the token tracking the
    ///      compose guid; we refuse already-executed guids and mark the guid as executed before settling.
    /// @param token Bridged token being routed.
    /// @param guid LayerZero compose guid used for replay protection.
    /// @param message Encoded treasury-routing payload.
    function lzCompose(address token, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        require(msg.sender == localEndpoint, PermissionDenied());
        require(!IOFTCompose(token).getComposeTxExecutedStatus(guid), AlreadyExecuted());

        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        (address receiver, TokenType tokenType) =
            abi.decode(OFTComposeMsgCodec.composeMsg(message), (address, TokenType));
        IOFTCompose(token).notifyComposeExecuted(guid);

        bool isBurned = _settle(token, receiver, tokenType, amount);
        emit OFTProcessed(guid, token, tokenType, receiver, amount, isBurned);
    }

    /// @notice Settles same-chain fee proceeds routed by the launcher.
    /// @dev Same-chain fast path: the launcher has already `_transferOut` the fee token into this dispatcher, then
    ///      calls this entry. `amount` is computed by the launcher from on-chain claimed fees and `receiver` is the
    ///      deterministic governor or yield vault.
    /// @param token Fee token to settle.
    /// @param receiver Yield vault, governor, or EOA burn target.
    /// @param tokenType Whether the token is a memecoin or a uAsset.
    /// @param amount Amount to settle.
    function distributeSameChain(address token, address receiver, TokenType tokenType, uint256 amount) external {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        bool isBurned = _settle(token, receiver, tokenType, amount);
        emit OFTProcessed(bytes32(0), token, tokenType, receiver, amount, isBurned);
    }

    /// @dev Routes `amount` of `token` to `receiver` based on `tokenType`.
    ///      For EOA receivers the token is burned; for contract receivers the token is approved for exactly `amount`
    ///      (since each receiver only pulls once per call) and the receiver pulls it via a callback.
    function _settle(address token, address receiver, TokenType tokenType, uint256 amount)
        internal
        returns (bool isBurned)
    {
        if (tokenType == TokenType.MEMECOIN) {
            if (receiver.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _safeApprove(token, receiver, amount);
                IMemecoinYieldVault(receiver).accumulateYields(amount);
            }
        } else if (tokenType == TokenType.UASSET) {
            if (receiver.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _safeApprove(token, receiver, amount);
                IMemecoinDaoGovernor(receiver).receiveTreasuryIncome(token, amount);
            }
        } else {
            revert InvalidTokenType();
        }
    }
}
