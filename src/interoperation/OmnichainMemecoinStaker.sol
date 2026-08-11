// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {OFTComposeSettleVerify} from "../common/omnichain/OFTComposeSettleVerify.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IOmnichainMemecoinStaker} from "./interfaces/IOmnichainMemecoinStaker.sol";

/**
 * @title Omnichain Memecoin Staker
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard,
 *      accepts Memecoin and stakes to the yield vault.
 */
contract OmnichainMemecoinStaker is IOmnichainMemecoinStaker, TokenHelper {
    address public immutable localEndpoint;

    /// @dev Single-resolution state per (memecoin, guid), shared between `lzCompose` (Settled) and
    ///      `settlePendingCompose` (Released). Keying on the genuine bridged memecoin (not just the guid) prevents a
    ///      forged settle with an arbitrary token from burning a real guid's mutex: a forged settle only advances
    ///      the attacker's own slot.
    mapping(address memecoin => mapping(bytes32 guid => ComposeState)) public composeStates;

    constructor(address _localEndpoint) {
        require(_localEndpoint != address(0), ZeroAddress());
        localEndpoint = _localEndpoint;
    }

    /// @notice Finalizes a remote memecoin staking compose message.
    /// @dev Only the local OFT endpoint may call this after bridged memecoin arrives on the governance chain. If the
    ///      destination vault exists, the tokens are deposited there for the receiver; otherwise they are transferred
    ///      directly to the receiver as a fallback. The compose guid is marked Settled before settlement (CEI); a
    ///      settlement revert rolls back the write and leaves the guid available for endpoint retry. A `Released`
    ///      pair is absorbed as a no-op; content-invalid 64-byte frames are likewise never reverted — shared
    ///      convergence / hash-binding / self-harm rationale: see `IComposeState`'s @dev note (authoritative). Local
    ///      branch selection: a dirty-high-bit receiver word is consumed with `ComposeRejected`; a dirty-high-bit
    ///      vault word is released via the vault-absent fallback; a zero receiver word keeps the documented
    ///      receiver==0 self-harm boundary (the fallback's zero-address guard reverts and the slot stays pinned,
    ///      see operations.md §3.13.1).
    /// @param memecoin Bridged memecoin address.
    /// @param guid Compose guid used for replay protection.
    /// @param message Encoded compose payload containing the receiver and yield-vault target.
    function lzCompose(address memecoin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        require(msg.sender == localEndpoint, PermissionDenied());
        // Single-resolution guard shared with `settlePendingCompose`: a guid may be settled at most once via this path.
        // Released pairs are absorbed as a no-op — see the @dev above for the rationale.
        ComposeState state = composeStates[memecoin][guid];
        if (state == ComposeState.Released) return;
        require(state == ComposeState.None, AlreadyResolved());
        // CEI: mark settled first; a revert below rolls the write back, leaving the guid releasable and retryable.
        composeStates[memecoin][guid] = ComposeState.Settled;

        // Reject a short frame (<76 bytes, header incomplete) with a named error before the codec slices
        // (`amountLD` reads [12:44], `composeMsg` reads [76:]) would revert opaquely. Mirrors `verifySettle`'s
        // header-integrity guard (see OFTComposeSettleVerify). The CEI `Settled` write rolls back on revert, so a
        // short frame leaves the guid `None` — same rollback behavior as the inner `composeMsg.length == 64` guard.
        require(message.length >= OFTComposeSettleVerify.COMPOSE_HEADER_LENGTH, MalformedComposeMsg());

        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        // The 64-byte check bounds the schema shape only: a non-64-byte frame reverts this named error (CEI `Settled`
        // write rolls back). A non-64 frame with inner composeMsg >= 32 bytes (total >= 108) stays releasable via
        // `settlePendingCompose`; an inner < 32-byte frame (total < 108) is a dead class rejected by both entrypoints
        // with no recovery exit (operations.md §3.13.1). Word content is resolved explicitly below.
        // The length guard is equivalent to the former `composeMsg.length == 64` (composeMsg = message[76:], so its
        // length == message.length - 76); `message.length >= 76` is already required at the header guard above, so
        // this subtraction cannot underflow. Read the two tuple words straight from calldata at fixed offsets, instead
        // of `OFTComposeMsgCodec.composeMsg(message)` (a `bytes memory` slice) + `abi.decode`, to avoid the 64-byte
        // calldata→memory copy and keep this parse pure-calldata — mirroring `YieldDispatcher._parseCompose`.
        require(message.length - OFTComposeSettleVerify.COMPOSE_HEADER_LENGTH == 64, MalformedComposeMsg());
        // Decode as uint256, not (address, address): solc's strict ABI decoder validates address words (160-bit clean)
        // and would revert with an EMPTY unreadable revert on dirty-high-bit words, pinning the endpoint queue forever
        // (no named error, CEI `Settled` rolled back, no consumption). Reading raw uint256 words skips that validator
        // so every content class can be resolved explicitly. Offsets: composeMsg = message[76:], tuple word0 at
        // [76:108] (receiver), word1 at [108:140] (vault).
        uint256 receiverRaw = uint256(bytes32(message[76:108]));
        uint256 vaultRaw = uint256(bytes32(message[108:140]));
        // A dirty receiver word can never be released (`settlePendingCompose` rejects it with `MalformedComposeMsg`)
        // and is hash-bound to this guid, so the slot (already Settled, CEI) is consumed with a rejection signal —
        // the endpoint queue converges instead of pinning for executor retries; funds stay in staker custody
        // (documented self-harm boundary).
        if (receiverRaw >> 160 != 0) {
            emit ComposeRejected(guid, memecoin, amount);
            return;
        }
        address receiver = address(uint160(receiverRaw));
        // A dirty vault word carries no readable vault target, treated as vault-absent, so the existing fallback
        // branch releases to the receiver (yieldVault reported as address(0) in the event).
        address yieldVault = vaultRaw >> 160 == 0 ? address(uint160(vaultRaw)) : address(0);
        if (yieldVault.code.length == 0) {
            // If the predicted vault is not deployed on the destination chain yet, release the bridged memecoin to the user instead of trapping it.
            _transferOut(memecoin, receiver, amount);
        } else {
            // Otherwise complete the happy path locally by staking the bridged memecoin into the target vault for the receiver.
            // Bind the delivered token to the vault's underlying asset: a forged (fake token, real vault) pairing
            // must revert here, before any approval or deposit moves funds, or the real vault's pull would drain
            // real memecoin from this contract's custody. `asset()` is the vault's own underlying asset.
            require(IMemecoinYieldVault(yieldVault).asset() == memecoin, TokenVaultMismatch());
            // Exact-amount approval: the yieldVault address is decoded from a forgeable compose message, so it is not
            // trustworthy. An unlimited approval would expose the staker's entire custody balance (including other
            // users' stranded compose funds) to any contract named in a forged message; the exact amount caps a
            // malicious vault's pull to the bridged amount.
            _safeApprove(memecoin, yieldVault, amount);
            uint256 shares = IMemecoinYieldVault(yieldVault).deposit(amount, receiver);
            // A non-zero deposit that returns 0 shares (a vault variant not reverting like the real vault does)
            // would settle silently with no shares and no recovery exit (the Settled slot blocks settlePendingCompose).
            // Revert instead so the CEI write rolls back and the beneficiary can still settle; zero-amount deposits
            // return 0 by the interface contract and are exempt (zero-amount convergence, operations.md §3.13.1).
            require(amount == 0 || shares != 0, IMemecoinYieldVault.ZeroSharesDeposit());
            // Zero any residual allowance: a vault that pulls less than the approved amount would otherwise keep a
            // live allowance over the staker's custody balance (which includes other users' stranded funds) and
            // could drain it later. The revert path needs no cleanup — the whole call rolls back.
            _safeApprove(memecoin, yieldVault, 0);
        }

        emit OmnichainMemecoinStakingProcessed(guid, memecoin, yieldVault, receiver, amount);
    }

    /// @inheritdoc IOmnichainMemecoinStaker
    function settlePendingCompose(address memecoin, bytes32 guid, bytes calldata message)
        external
        override
        returns (uint256 amount)
    {
        // Single-resolution guard shared with `lzCompose`: a guid may be settled at most once, and only if never settled.
        require(composeStates[memecoin][guid] == ComposeState.None, AlreadyResolved());

        bytes memory composeMsg;
        (amount, composeMsg) = OFTComposeSettleVerify.verifySettle(localEndpoint, memecoin, guid, message);
        require(amount != 0, ZeroInput());
        // Release-path schema guard. Unlike `lzCompose` (the entry path), which must read both `receiver` AND
        // `yieldVault` and therefore enforces an exact 64-byte `(address, address)` composeMsg, the release path
        // (`settlePendingCompose`) only ever needs the beneficiary address: it always pushes via `_transferOut` and
        // never touches `yieldVault`. So the shape is asymmetric on purpose — the release path accepts any composeMsg
        // of at least one 32-byte word and reads only the first word as `receiver`, discarding any trailing bytes
        // (the unused `yieldVault` field or anything else). This makes a self-stranded malformed payload (non-64 but
        // >=32 bytes) recoverable by the beneficiary rather than permanently trapped.
        // Order matters: the length check precedes the first-word read so it can never read out of bounds.
        require(composeMsg.length >= 32, MalformedComposeMsg());
        uint256 receiverWord = abi.decode(composeMsg, (uint256));
        // Reject a dirty high-96-bits receiver word: `uint160` would silently truncate it into a forged address
        // A genuine `abi.encode(address, ...)` always packs the address low.
        require(receiverWord >> 160 == 0, MalformedComposeMsg());
        address receiver = address(uint160(receiverWord));

        // Only the beneficiary may release their own stuck stake; the receiver is bound to the queued message hash
        // and cannot be tampered with.
        require(msg.sender == receiver, NotBeneficiary());

        // CEI: flip to Released before the outward transfer so the same guid cannot be released twice.
        composeStates[memecoin][guid] = ComposeState.Released;
        _transferOut(memecoin, receiver, amount);

        emit StakingComposeSettled(guid, memecoin, receiver, amount);
    }
}
