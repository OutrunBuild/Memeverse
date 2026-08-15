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
     * @param _memeverseLauncher - Address of MemeverseLauncherUpgradeable
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
        require(_lzEndpointRegistry != address(0), ZeroAddress());
        require(_memeverseLauncher != address(0), ZeroAddress());
        LZ_ENDPOINT_REGISTRY = _lzEndpointRegistry;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        OMNICHAIN_MEMECOIN_STAKER = _omnichainMemecoinStaker;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        omnichainStakingGasLimit = _omnichainStakingGasLimit;
    }

    /// @inheritdoc IMemeverseOmnichainInteroperation
    /// @dev Governance chain is `verse.omnichainIds[0]`. Same-chain routes return a zero fee but still need a
    ///      deployed yield vault for the actual staking call; remote routes quote the exact LayerZero fee.
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

    /// @inheritdoc IMemeverseOmnichainInteroperation
    /// @dev Governance chain is `verse.omnichainIds[0]`. Same-chain: native fee must be 0, reverts `EmptyYieldVault`
    ///      if the vault is missing. Remote: quotes and sends with the exact native fee; a successful source send may
    ///      still leave destination `lzReceive`/`lzCompose` failures for LayerZero to retry.
    /// @dev Remote sends reject amounts that `_removeDust` truncates to zero (`amount < decimalConversionRate`,
    ///      e.g. < 1e12 for an 18-decimal memecoin with 6 shared decimals): such a send burns nothing, delivers a
    ///      zero-amount compose, charges the full LayerZero fee, and strands the full amount (no sweep). Pre-checked
    ///      before `_transferIn`, so a rejected amount never moves the caller's tokens.
    /// @dev Non-zero-remainder truncation (`amount >= decimalConversionRate` but not a clean multiple) is NOT
    ///      rejected: the caller meant to stake, so the un-burnt remainder (`amount - amountSentLD`) is refunded to
    ///      `msg.sender` on the source chain in the same tx right after the OFT send — nothing strands.
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
        // Pre-check before `_transferIn`: a zero-truncated remote send strands the dust (no sweep) for a full fee.
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

        // `_debit` burnt the truncated `amountSentLD`; the remainder (`amount - amountSentLD`, the part `_removeDust`
        // dropped) was pulled in by `_transferIn` but never burnt, so refund it here — nothing strands. The refund uses
        // `amountSentLD` (burnt), not `amountReceivedLD`, by router-balance conservation. For the default memecoin OFT
        // the two are equal (`OutrunOFTCoreInit._debitView`); a future fee-taking override would need this re-examined.
        // The event below carries `amountSentLD` and `remainder`, so indexers can verify `amountSentLD + remainder == amount`.
        uint256 remainder = amount - oftReceipt.amountSentLD;
        if (remainder != 0) _transferOut(memecoin, msg.sender, remainder);

        emit OmnichainMemecoinStaking(
            rec.guid, msg.sender, receiver, memecoin, amount, oftReceipt.amountSentLD, remainder
        );
    }

    /// @dev Pre-send guard for the remote path. OFT `_debitView`/`_removeDust` truncates `amount` to
    ///      `(amount / decimalConversionRate) * decimalConversionRate` before burning/encoding. An amount below
    ///      `decimalConversionRate` (e.g. < 1e12 for an 18-decimal memecoin with 6 shared decimals) truncates to zero:
    ///      no-op `_burn`, amountSD = 0 on the wire, destination mints 0 and fires a zero-amount compose, yet
    ///      `_transferIn` already pulled the full amount into this contract (no sweep/withdraw/receive/fallback) — the
    ///      caller pays the full LayerZero fee for a zero-position result with no revert/refund signal. `quoteOFT`
    ///      re-runs the same truncation, so `amountReceivedLD != 0` is the precise zero-collapse test. Non-zero-
    ///      remainder truncation is NOT rejected here — refunded after the send in `memecoinStaking`.
    function _requireNonZeroRemoteDelivery(address memecoin, SendParam memory sendParam) internal view {
        (,, OFTReceipt memory receipt) = IOFT(memecoin).quoteOFT(sendParam);
        require(receipt.amountReceivedLD != 0, DustAmount());
    }

    /// @inheritdoc IMemeverseOmnichainInteroperation
    /// @dev Only callable by the owner. Both values are validated only for `> 0`; no minimum execution budget is
    ///      enforced, so a value below the destination's actual execution cost permanently breaks that path:
    ///      - `_oftReceiveGasLimit` too low: the LayerZero executor's delivery (gas-capped by this option) always
    ///        runs out of gas in the governance-chain memecoin OFT `lzReceive` (mint). The source amount is already
    ///        burned and there is no protocol-internal settle for the receive side (`settlePendingCompose` only
    ///        covers the compose side); recovery is a permissionless manual re-delivery of the verified payload via
    ///        the destination-chain `EndpointV2.lzReceive` with caller-provided gas (same class as the permissionless
    ///        `lzCompose` re-drive) — funds are not lost, but stay undelivered until then.
    ///      - `_omnichainStakingGasLimit` too low: the destination `lzCompose` runs out of gas; the beneficiary can
    ///        still recover the bare amount via `settlePendingCompose` (no position is created) — UX degradation,
    ///        not a loss.
    ///      When adjusting, keep `_omnichainStakingGasLimit` at or above the benchmarked compose-side gas budget, and
    ///      keep `_oftReceiveGasLimit` at or above a receive-side budget benchmarked by the same methodology.
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
