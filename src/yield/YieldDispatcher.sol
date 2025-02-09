// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

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
    using SafeERC20 for IERC20;

    uint256 public constant RATIO = 10000;
    address public immutable endpoint;
    address public immutable memeverseLauncher;

    address public revenuePool;
    uint256 public protocolFeeRate;

    constructor(
        address _owner, 
        address _endpoint, 
        address _memeverseLauncher, 
        address _revenuePool, 
        uint256 _protocolFeeRate
    ) Ownable(_owner) {
        endpoint = _endpoint;
        memeverseLauncher = _memeverseLauncher;
        revenuePool = _revenuePool;
        protocolFeeRate = _protocolFeeRate;
    }

    /**
     * @notice Redirect the yields of different Memecoins to their yield vault.
     * @param _memecoin Memecoin OFT Address.
     * @param _message The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
     */
    function lzCompose(
        address _memecoin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override {
        require(msg.sender == endpoint, PermissionDenied());

        address yieldVault = IMemeverseLauncher(memeverseLauncher).getYieldVaultByMemecoin(_memecoin);
        _safeApproveInf(_memecoin, yieldVault);
        uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);
        uint256 protocolFee = _amountLD * protocolFeeRate / RATIO;
        _transferOut(_memecoin, revenuePool, protocolFee);
        uint256 yield = _amountLD - protocolFee;
        IMemecoinYieldVault(yieldVault).accumulateYields(yield);

        emit OmnichainAccumulateYields(_memecoin, yieldVault, yield, protocolFee);
    }

    function setRevenuePool(address _revenuePool) external override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());

        revenuePool = _revenuePool;
    }

    function setProtocolFeeRate(uint256 _protocolFeeRate) external override onlyOwner {
        require(_protocolFeeRate < RATIO, FeeRateOverFlow());

        protocolFeeRate = _protocolFeeRate;
    }
}
