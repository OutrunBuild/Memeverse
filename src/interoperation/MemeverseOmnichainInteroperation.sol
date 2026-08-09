// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    IOFT,
    OFTReceipt,
    SendParam,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

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
        require(_omnichainMemecoinStaker != address(0), ZeroAddress());
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
        _requireNonZeroRemoteDelivery(memecoin, sendParam);
        lzFee = IOFT(memecoin).quoteSend(sendParam, false).nativeFee;
    }

    /// @notice Stakes memecoin either locally or through the omnichain staker.
    /// @dev Uses `verse.omnichainIds[0]` as the governance chain. On the same chain, it requires zero native fee and
    ///      reverts with `EmptyYieldVault` when the vault is missing before depositing locally. On a remote chain, it
    ///      quotes and sends with the same parameters, requiring the exact native fee. A successful source send still
    ///      leaves destination `lzReceive`/`lzCompose` failures for LayerZero to retry.
    /// @dev Remote sends additionally reject amounts that `_removeDust` would truncate ALL THE WAY to zero
    ///      (`amount < decimalConversionRate`, e.g. < 1e12 for an 18-decimal memecoin with 6 shared decimals): such a
    ///      send burns nothing, delivers a zero-amount compose (zero position), charges the full LayerZero fee, and
    ///      strands the full amount here with no sweep. The pre-check runs BEFORE `_transferIn` so a rejected amount
    ///      never moves the caller's tokens.
    /// @dev For non-zero-remainder truncation (`amount >= decimalConversionRate` but `amount % decimalConversionRate
    ///      != 0`), the caller's intent is to stake, so instead of reverting the send refunds the un-burnt remainder
    ///      (`amount - amountSentLD`) back to `msg.sender` on the source chain, in the same transaction, right after
    ///      the OFT send — nothing strands here.
    /// @param memecoin memecoin address.
    /// @param receiver receiver address.
    /// @param amount token amount.
    function memecoinStaking(address memecoin, address receiver, uint256 amount) external payable override {
        require(memecoin != address(0) && receiver != address(0) && amount != 0, ZeroInput());

        IMemeverseLauncher.Memeverse memory verse =
            IMemeverseLauncher(MEMEVERSE_LAUNCHER).getMemeverseByMemecoin(memecoin);
        uint32 govChainId = verse.omnichainIds[0];
        address yieldVault = verse.yieldVault;

        SendParam memory sendParam;
        bool isRemote = govChainId != block.chainid;
        // Reject sub-rate amounts BEFORE pulling funds: a remote send whose truncated amount is zero would strand the
        // dust here (no sweep/withdraw) while charging the full LayerZero fee for a zero-position result.
        if (isRemote) {
            sendParam = _buildStakingSendParam(govChainId, receiver, yieldVault, amount);
            _requireNonZeroRemoteDelivery(memecoin, sendParam);
        }

        _transferIn(memecoin, msg.sender, amount);
        if (!isRemote) {
            if (msg.value != 0) revert InvalidLzFee(0, msg.value);
            require(yieldVault.code.length != 0, EmptyYieldVault());
            _safeApproveInf(memecoin, yieldVault);
            IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
            return;
        }

        MessagingFee memory messagingFee = IOFT(memecoin).quoteSend(sendParam, false);
        if (msg.value != messagingFee.nativeFee) revert InvalidLzFee(messagingFee.nativeFee, msg.value);

        (
            MessagingReceipt memory rec,
            // solhint-disable-next-line check-send-result
            OFTReceipt memory oftReceipt
        ) = IOFT(memecoin).send{value: messagingFee.nativeFee}(sendParam, messagingFee, msg.sender);

        // OFT `_debit` burns the truncated `amountSentLD`; the remainder (`amount - amountSentLD`, the part
        // `_removeDust` dropped) was pulled in by `_transferIn` but never burnt, so refund it to the caller on the
        // source chain here — nothing strands. Zero for exact multiples (no truncation); up to rate-1 wei otherwise.
        // The refund quantity is derived from router-balance conservation (`_transferIn` pulled `amount`, `_debit` burnt
        // `amountSentLD`), so it uses `amountSentLD` (what was actually burnt), not `amountReceivedLD`. For the default
        // memecoin OFT `amountSentLD == amountReceivedLD` (`OutrunOFTCoreInit._debitView`); a future fee-taking OFT
        // override that makes them differ would need this refund re-examined.
        uint256 remainder = amount - oftReceipt.amountSentLD;
        if (remainder != 0) _transferOut(memecoin, msg.sender, remainder);

        emit OmnichainMemecoinStaking(rec.guid, msg.sender, receiver, memecoin, amount);
    }

    /// @dev Pre-send guard for the remote staking path. OFT `_debitView`/`_removeDust` truncates the local-decimal
    ///      amount to `(amount / decimalConversionRate) * decimalConversionRate` before burning and encoding the shared-
    ///      decimal amount on the wire. An `amount` smaller than `decimalConversionRate` (e.g. < 1e12 for an 18-decimal
    ///      memecoin with 6 shared decimals) therefore truncates to ZERO: `_burn` is a no-op, the message carries
    ///      amountSD = 0, the destination mints 0 and fires a zero-amount compose, yet `_transferIn` already pulled the
    ///      full amount into this contract (which has no sweep/withdraw/receive/fallback). The caller would pay the full
    ///      LayerZero fee for a zero-position result with no revert/refund signal. `quoteOFT` re-runs the same
    ///      `_debitView` truncation, so `amountReceivedLD != 0` is the precise "did truncation collapse to zero" test.
    ///      Non-zero-remainder truncation is NOT rejected here — it is handled by refunding the remainder after the
    ///      send in `memecoinStaking`.
    function _requireNonZeroRemoteDelivery(address memecoin, SendParam memory sendParam) internal view {
        (,, OFTReceipt memory receipt) = IOFT(memecoin).quoteOFT(sendParam);
        require(receipt.amountReceivedLD != 0, DustAmount());
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
