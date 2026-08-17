// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {IComposeState} from "../types/IComposeState.sol";

/// @dev Shared delivery + authenticity proof for the two composers' `settlePendingCompose`. Both `YieldDispatcherUpgradeable` and
///      `OmnichainMemecoinStakerUpgradeable` previously inlined the same verification prefix (endpoint `composeQueue` read,
///      NotDelivered / AlreadyExecuted / keccak256 binding, amountLD); single-sourcing it here prevents the two
///      copies from drifting apart (a one-sided edit of the fund-release authorization gate would create a hole).
library OFTComposeSettleVerify {
    /// @dev Sentinel written by the LayerZero MessagingComposer into `composeQueue` after `lzCompose` runs, in place
    ///      of deletion, so replay is blocked. Declared privately inside the protocol's `MessagingComposer`; mirrored here.
    bytes32 internal constant RECEIVED_MESSAGE_HASH = bytes32(uint256(1));

    /// @dev Full length of the OFT compose header (the codec's `COMPOSE_FROM_OFFSET`): nonce 8 + srcEid 4 + amountLD
    ///      32 + composeFrom 32 = 76. The upstream `OFTComposeMsgCodec` declares this value `private`, so it cannot be
    ///      imported; mirror it here once and reference `COMPOSE_HEADER_LENGTH` from every site that needs the 76-byte
    ///      header length, so a one-sided edit becomes a compile-time break instead of a silent behavioral divergence.
    uint256 internal constant COMPOSE_HEADER_LENGTH = 76;

    /// @dev The revert errors used below (`NotDelivered` / `AlreadyExecuted` / `InvalidProof` /
    ///      `MalformedComposeMsg`) are declared once in `IComposeState` (imported above), which both composer
    ///      interfaces inherit. Referencing them here by qualified name keeps a single declaration for the
    ///      library and the two composer ABIs — no mirror copies to keep in sync.

    /// @notice Proves a compose guid was delivered-but-not-executed and that `message` is the genuine payload.
    /// @dev Reads the endpoint's public `composeQueue[token][address(this)][guid][0]` (zero = never delivered,
    ///      RECEIVED_MESSAGE_HASH = lzCompose already ran, keccak256(message) = delivered and pending) and binds
    ///      `message` by hash. `internal` library functions inline into the caller, so `address(this)` is the calling
    ///      composer. Pure verification: the caller keeps its own per-contract `composeStates` mutex check, decode,
    ///      auth, state write, and settlement. Callers also reject zero-amount payloads — refusing keeps the
    ///      (token, guid) slot resolvable instead of pinning it to Released with zero funds moved. Both protocol
    ///      send paths now reject truncate-to-zero before sending, so a zero-amount compose cannot reach here via a
    ///      protocol path — this zero check is defense-in-depth against third-party permissionless OFT `send`
    ///      (self-harm) frames:
    ///        - Staking path (`MemeverseOmnichainInteroperation.memecoinStaking` / `quoteMemecoinStaking`) rejects
    ///          amounts that `_removeDust` would collapse to zero (`amount < decimalConversionRate`). For non-zero
    ///          remainders (`amount >= rate` but `amount % rate != 0`), instead of reverting it refunds the un-burnt
    ///          remainder (`amount - amountSentLD`) to the caller on the source chain right after the OFT send, so
    ///          nothing strands here.
    ///        - Fee-distribution path (`MemeverseSettlementImpl._sendRedeemedFeesCrossChain`) rejects only the
    ///          truncate-to-zero case (`amountReceivedLD != 0`); fee amounts are protocol-computed (swap-fee
    ///          accumulation), so a non-zero remainder remains the documented dust-stranding trade-off for that path.
    ///      Callers MUST pass their immutable trusted `localEndpoint` and the genuine bridged `token` — this library
    ///      performs no trust anchoring of its own, so a caller supplying an attacker-controlled endpoint could be
    ///      shown a fabricated `composeQueue` entry.
    /// @param endpoint Local LayerZero endpoint address (the MessagingComposer).
    /// @param token Bridged token address owning the compose payload.
    /// @param guid Compose guid.
    /// @param message The original compose payload (reconstructable from the endpoint's `ComposeSent` event log).
    /// @return amount Released amount in local decimals.
    /// @return composeMsg The decoded compose payload, for the caller to decode its own receiver schema.
    function verifySettle(address endpoint, address token, bytes32 guid, bytes calldata message)
        internal
        view
        returns (uint256 amount, bytes memory composeMsg)
    {
        bytes32 queueHash = IMessagingComposer(endpoint).composeQueue(token, address(this), guid, 0);
        require(queueHash != bytes32(0), IComposeState.NotDelivered());
        require(queueHash != RECEIVED_MESSAGE_HASH, IComposeState.AlreadyExecuted());
        require(keccak256(message) == queueHash, IComposeState.InvalidProof());
        // Reject a short frame (<76 bytes, header incomplete) with a named error before the codec slices
        // (`amountLD` reads [12:44], `composeMsg` reads [76:]) would revert with an opaque bare revert. 76 is
        // OFTComposeMsgCodec's COMPOSE_FROM_OFFSET — the full compose header length (nonce 8 + srcEid 4 + amountLD 32
        // + composeFrom 32). The callers separately enforce their own inner schema-shape guards — `YieldDispatcherUpgradeable`
        // requires `composeMsg.length >= 64` and `OmnichainMemecoinStakerUpgradeable` requires `>= 32`; this guard only secures
        // header integrity.
        require(message.length >= COMPOSE_HEADER_LENGTH, IComposeState.MalformedComposeMsg());

        amount = OFTComposeMsgCodec.amountLD(message);
        composeMsg = OFTComposeMsgCodec.composeMsg(message);
    }
}
