// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IMemeverseCommonInfo } from "../verse/interfaces/IMemeverseCommonInfo.sol";
import { IMemeverseOmnichainInteroperation } from "./interfaces/IMemeverseOmnichainInteroperation.sol";

/**
 * @title Memeverse Omnichain Interoperation
 */ 
contract MemeverseOmnichainInteroperation is IMemeverseOmnichainInteroperation, TokenHelper, Ownable {
    using OptionsBuilder for bytes;

    address public immutable MEMEVERSE_COMMON_INFO;
    address public immutable MEMEVERSE_LAUNCHER;
    address public immutable OMNICHAIN_MEMECOIN_STAKER;
    
    uint128 public oftReceiveGasLimit;
    uint128 public omnichainStakingGasLimit;

    /**
     * @dev Constructor
     * @param _owner - The owner of the contract
     * @param _memeverseCommonInfo - Address of MemeverseCommonInfo
     * @param _memeverseLauncher - Address of MemeverseLauncher
     * @param _omnichainMemecoinStaker - Address of OmnichainMemecoinStaker
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _omnichainStakingGasLimit - Gas limit for omnichain memecoin staking
     */
    constructor(
        address _owner,
        address _memeverseCommonInfo,
        address _memeverseLauncher,
        address _omnichainMemecoinStaker,
        uint128 _oftReceiveGasLimit,
        uint128 _omnichainStakingGasLimit
    ) Ownable(_owner) {
        MEMEVERSE_COMMON_INFO = _memeverseCommonInfo;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        OMNICHAIN_MEMECOIN_STAKER = _omnichainMemecoinStaker;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        omnichainStakingGasLimit = _omnichainStakingGasLimit;
    }

    /**
     * @dev Quote the LayerZero fee for the Memecoin Omnichain Staking
     * @param memecoin - Address of memecoin.
     * @param receiver - Address of staked memecoin receiver.
     * @param amount - Amount of memecoin will be staked.
     * @return lzFee - The LayerZero fee for the Memecoin Omnichain Staking. The value must be sufficient, 
                       it is recommended that the value be slightly higher than the quote value, otherwise, 
                       the registration may fail, and the consumed gas will not be refunded.
    */
    function quoteMemecoinStaking(
        address memecoin,
        address receiver,
        uint256 amount
    ) external view override returns (uint256 lzFee) {
        require(memecoin != address(0) && receiver != address(0) && amount != 0, ZeroInput());

        IMemeverseLauncher.Memeverse memory verse = IMemeverseLauncher(MEMEVERSE_LAUNCHER).getMemeverseByMemecoin(memecoin);
        uint32 govChainId = verse.omnichainIds[0];
        address yieldVault = verse.yieldVault;
        require(yieldVault.code.length != 0, EmptyYieldVault());
        if (govChainId == block.chainid) return 0;

        bytes memory omnichainStakingOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, omnichainStakingGasLimit, 0);
        SendParam memory sendParam = SendParam({
            dstEid: IMemeverseCommonInfo(MEMEVERSE_COMMON_INFO).lzEndpointIdMap(govChainId),
            to: bytes32(uint256(uint160(OMNICHAIN_MEMECOIN_STAKER))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: omnichainStakingOptions,
            composeMsg: abi.encode(memecoin, yieldVault, receiver),
            oftCmd: abi.encode()
        });
        lzFee = IOFT(memecoin).quoteSend(sendParam, false).nativeFee;
    }

    /**
     * @dev Memecoin Omnichain Staking(Cross to GovChain)
     * @param memecoin - Address of memecoin.
     * @param receiver - Address of staked memecoin receiver.
     * @param amount - Amount of memecoin will be staked.
     */
    function memecoinStaking(
        address memecoin,
        address receiver,
        uint256 amount
    ) external payable override {
        require(memecoin != address(0) && receiver != address(0) && amount != 0, ZeroInput());

        IMemeverseLauncher.Memeverse memory verse = IMemeverseLauncher(MEMEVERSE_LAUNCHER).getMemeverseByMemecoin(memecoin);
        uint32 govChainId = verse.omnichainIds[0];
        address yieldVault = verse.yieldVault;
        
        _transferIn(memecoin, msg.sender, amount);
        if (govChainId == block.chainid) {
            require(yieldVault.code.length != 0, EmptyYieldVault());
            _safeApproveInf(memecoin, yieldVault);
            IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
            return;
        }

        bytes memory omnichainStakingOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, omnichainStakingGasLimit, 0);
        SendParam memory sendParam = SendParam({
            dstEid: IMemeverseCommonInfo(MEMEVERSE_COMMON_INFO).lzEndpointIdMap(govChainId),
            to: bytes32(uint256(uint160(OMNICHAIN_MEMECOIN_STAKER))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: omnichainStakingOptions,
            composeMsg: abi.encode(yieldVault, receiver),
            oftCmd: abi.encode()
        });
        MessagingFee memory messagingFee = IOFT(memecoin).quoteSend(sendParam, false);
        require(msg.value >= messagingFee.nativeFee, InsufficientLzFee());

        IOFT(memecoin).send{value: messagingFee.nativeFee}(sendParam, messagingFee, msg.sender);
    }

    /**
     * @dev Set gas limits for OFT receive and omnichain memecoin staker
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _omnichainStakingGasLimit - Gas limit for omnichain memecoin staking
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _omnichainStakingGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _omnichainStakingGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        omnichainStakingGasLimit = _omnichainStakingGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _omnichainStakingGasLimit);
    }
}
