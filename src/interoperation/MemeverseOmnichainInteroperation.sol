// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, MessagingFee, MessagingReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {IMemeverseLauncher} from "../verse/interfaces/IMemeverseLauncher.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {ILzEndpointRegistry} from "../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IMemeverseOmnichainInteroperation} from "./interfaces/IMemeverseOmnichainInteroperation.sol";

/**
 * @title Memeverse Omnichain Interoperation
 */
contract MemeverseOmnichainInteroperation is IMemeverseOmnichainInteroperation, TokenHelper, Ownable {
    using OptionsBuilder for bytes;

    address public immutable LZ_ENDPOINT_REGISTRY;
    address public immutable MEMEVERSE_LAUNCHER;
    address public immutable OMNICHAIN_MEMECOIN_STAKER;

    uint128 public oftReceiveGasLimit;
    uint128 public omnichainStakingGasLimit;

    /**
     * @dev Constructor
     * @param _owner - The owner of the contract
     * @param _lzEndpointRegistry - Address of LzEndpointRegistry
     * @param _memeverseLauncher - Address of MemeverseLauncher
     * @param _omnichainMemecoinStaker - Address of OmnichainMemecoinStaker
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _omnichainStakingGasLimit - Gas limit for omnichain memecoin staking
     */
    constructor(
        address _owner,
        address _lzEndpointRegistry,
        address _memeverseLauncher,
        address _omnichainMemecoinStaker,
        uint128 _oftReceiveGasLimit,
        uint128 _omnichainStakingGasLimit
    ) Ownable(_owner) {
        LZ_ENDPOINT_REGISTRY = _lzEndpointRegistry;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        OMNICHAIN_MEMECOIN_STAKER = _omnichainMemecoinStaker;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        omnichainStakingGasLimit = _omnichainStakingGasLimit;
    }

    /// @notice Quotes the native fee for staking a memecoin on the governance chain.
    /// @dev Uses `verse.omnichainIds[0]` as the governance chain. Same-chain routes return a zero fee; the actual
    ///      same-chain staking call still requires a deployed yield vault. Remote routes quote the exact LayerZero
    ///      fee for the staking parameters built below.
    /// @param memecoin memecoin address.
    /// @param receiver receiver address.
    /// @param amount token amount.
    /// @return lzFee LayerZero fee.
    function quoteMemecoinStaking(address memecoin, address receiver, uint256 amount)
        external
        view
        override
        returns (uint256 lzFee)
    {
        require(memecoin != address(0) && receiver != address(0) && amount != 0, ZeroInput());

        IMemeverseLauncher.Memeverse memory verse =
            IMemeverseLauncher(MEMEVERSE_LAUNCHER).getMemeverseByMemecoin(memecoin);
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;

        address yieldVault = verse.yieldVault;
        SendParam memory sendParam = _buildStakingSendParam(govChainId, receiver, yieldVault, amount);
        lzFee = IOFT(memecoin).quoteSend(sendParam, false).nativeFee;
    }

    /// @notice Stakes memecoin either locally or through the omnichain staker.
    /// @dev Uses `verse.omnichainIds[0]` as the governance chain. On the same chain, it requires zero native fee and
    ///      reverts with `EmptyYieldVault` when the vault is missing before depositing locally. On a remote chain, it
    ///      quotes and sends with the same parameters, requiring the exact native fee. A successful source send still
    ///      leaves destination `lzReceive`/`lzCompose` failures for LayerZero to retry.
    /// @param memecoin memecoin address.
    /// @param receiver receiver address.
    /// @param amount token amount.
    function memecoinStaking(address memecoin, address receiver, uint256 amount) external payable override {
        require(memecoin != address(0) && receiver != address(0) && amount != 0, ZeroInput());

        IMemeverseLauncher.Memeverse memory verse =
            IMemeverseLauncher(MEMEVERSE_LAUNCHER).getMemeverseByMemecoin(memecoin);
        uint32 govChainId = verse.omnichainIds[0];
        address yieldVault = verse.yieldVault;

        _transferIn(memecoin, msg.sender, amount);
        if (govChainId == block.chainid) {
            if (msg.value != 0) revert InvalidLzFee(0, msg.value);
            require(yieldVault.code.length != 0, EmptyYieldVault());
            _safeApproveInf(memecoin, yieldVault);
            IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
            return;
        }

        SendParam memory sendParam = _buildStakingSendParam(govChainId, receiver, yieldVault, amount);
        MessagingFee memory messagingFee = IOFT(memecoin).quoteSend(sendParam, false);
        if (msg.value != messagingFee.nativeFee) revert InvalidLzFee(messagingFee.nativeFee, msg.value);

        (
            MessagingReceipt memory rec,
            // solhint-disable-next-line check-send-result
        ) = IOFT(memecoin).send{value: messagingFee.nativeFee}(sendParam, messagingFee, msg.sender);

        emit OmnichainMemecoinStaking(rec.guid, msg.sender, receiver, memecoin, amount);
    }

    /// @notice Updates the gas limits used by remote staking sends.
    /// @dev Only callable by the owner.
    /// @param _oftReceiveGasLimit OFT receive gas limit.
    /// @param _omnichainStakingGasLimit omnichain staking gas limit.
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _omnichainStakingGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _omnichainStakingGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        omnichainStakingGasLimit = _omnichainStakingGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _omnichainStakingGasLimit);
    }

    /// @dev Maps the selected governance chain to its LayerZero endpoint and encodes the receiver and vault for the
    ///      destination staker. Quote and send use these exact parameters.
    /// @param govChainId Governance chain ID.
    /// @param receiver Final staking beneficiary.
    /// @param yieldVault Yield vault on the governance chain.
    /// @param amount Token amount to stake.
    /// @return sendParam LayerZero OFT send parameters.
    function _buildStakingSendParam(uint32 govChainId, address receiver, address yieldVault, uint256 amount)
        internal
        view
        returns (SendParam memory sendParam)
    {
        bytes memory omnichainStakingOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, omnichainStakingGasLimit, 0);
        sendParam = SendParam({
            dstEid: ILzEndpointRegistry(LZ_ENDPOINT_REGISTRY).lzEndpointIdOfChain(govChainId),
            to: bytes32(uint256(uint160(OMNICHAIN_MEMECOIN_STAKER))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: omnichainStakingOptions,
            composeMsg: abi.encode(receiver, yieldVault),
            oftCmd: abi.encode()
        });
    }
}
