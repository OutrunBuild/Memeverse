// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { IBurnable } from "../common/IBurnable.sol";
import { TokenHelper } from "../common/TokenHelper.sol";
import { IYieldDispatcher } from "./interfaces/IYieldDispatcher.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
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

    constructor(
        address _owner, 
        address _localEndpoint, 
        address _memeverseLauncher
    ) Ownable(_owner) {
        localEndpoint = _localEndpoint;
        memeverseLauncher = _memeverseLauncher;
    }

    /**
     * @notice Redirect the yields of different Memecoins to their yield vault.
     * @param token - The token address initiating the composition, typically the OFT where the lzReceive was called.
     * @param message - The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
     */
    function lzCompose(
        address token,
        bytes32 /*guid*/,
        bytes calldata message,
        address /*executor*/,
        bytes calldata /*extraData*/
    ) external payable override {
        require(msg.sender == localEndpoint, PermissionDenied());

        bool isBurned = false;
        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        (uint256 verseId, string memory tokenType) = abi.decode(OFTComposeMsgCodec.composeMsg(message), (uint256, string));
        if (tokenType.equal("Memecoin")) {
            address yieldVault = IMemeverseLauncher(memeverseLauncher).getYieldVaultByVerseId(verseId);
            if (yieldVault.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _safeApproveInf(token, yieldVault);
                IMemecoinYieldVault(yieldVault).accumulateYields(amount);
            }
        } else if (tokenType.equal("UPT")) {
            address governor = IMemeverseLauncher(memeverseLauncher).getGovernorByVerseId(verseId);
            if (governor.code.length == 0) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                _transferOut(token, governor, amount);
            }
        }

        emit OmnichainYieldsProcessed(verseId, token, isBurned, amount);
    }
}
