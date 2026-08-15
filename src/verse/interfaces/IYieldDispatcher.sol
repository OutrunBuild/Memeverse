// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import {IMemeverseOFTEnum} from "../../common/types/IMemeverseOFTEnum.sol";
import {IComposeState} from "../../common/types/IComposeState.sol";

interface IYieldDispatcher is IMemeverseOFTEnum, IComposeState, ILayerZeroComposer {
    /// @dev Emitted on every compose settlement (`lzCompose`, real compose guid) and on the same-chain fee
    ///      distribution (`distributeSameChain`, guid `bytes32(0)`). `burnedAtDispatcher` reports the dispatcher's
    ///      own action, not actual token destruction: `true` when `receiver` is an EOA and the dispatcher executed
    ///      the burn call; `false` when the dispatcher only initiated approve + pull to a contract receiver — the
    ///      receiver may internally destroy the pulled tokens (e.g., the empty yield vault burns first-yield), so
    ///      reconcile destruction via the underlying token's `Transfer(to = address(0))`.
    event OFTProcessed(
        bytes32 indexed guid,
        address indexed token,
        TokenType indexed tokenType,
        address receiver,
        uint256 amount,
        bool burnedAtDispatcher
    );

    /// @notice Emitted when a stuck compose payload is settled via `settlePendingCompose`.
    /// @dev `burnedAtDispatcher` reports the dispatcher's own action, not actual token destruction: `true` when
    ///      `receiver` is an EOA and the dispatcher executed the burn call (actual destruction holds only for
    ///      tokens implementing a caller-callable single-arg `burn(uint256)` — others revert the EOA branch;
    ///      fallback-absorbing tokens may no-op with a `true` report); `false` when the dispatcher only initiated
    ///      approve + pull to a contract receiver — the receiver may pull nothing (fallback/no-op) or may
    ///      internally destroy the pulled tokens (the empty yield vault burns first-yield), so reconcile
    ///      destruction via the underlying token's `Transfer(to = address(0))` and pulls via balance/allowance.
    ///      The `token` key is not guaranteed to be a genuine bridged token: `sendCompose` is permissionless and
    ///      keyed on `msg.sender`, so any third party can forge a delivered slot and settle it (attacker-owned
    ///      token + no-op callbacks; no funds move) — reconcile by filtering known token addresses. `tokenType` is
    ///      the settlement type decoded from the message (same source as `OFTProcessed`'s `tokenType`):
    ///      `MEMECOIN` settles to the message-named yield vault, `UASSET` to the governor.
    event ComposeSettled(
        bytes32 indexed guid,
        address indexed token,
        address indexed receiver,
        TokenType tokenType,
        uint256 amount,
        bool burnedAtDispatcher
    );

    /// @notice Emitted by `setProtocolTreasury` on an owner treasury rotation.
    /// @dev `oldTreasury` is the initialize-time treasury on the first rotation.
    /// @param oldTreasury The treasury address before the rotation.
    /// @param newTreasury The treasury address after the rotation.
    event ProtocolTreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    /// @dev Shared compose errors (`NotDelivered` / `AlreadyExecuted` / `InvalidProof` /
    ///      `MalformedComposeMsg`) and the `ComposeRejected` event are declared once in `IComposeState`,
    ///      inherited by both composer interfaces.

    error PermissionDenied();

    error InvalidTokenType();

    /// @dev The guid has already been resolved (settled or released); the mutex forbids a second resolution.
    error AlreadyResolved();

    /// @dev An address argument is the zero address. Covers `initialize` (localEndpoint / memeverseLauncher /
    ///      protocolTreasury) and `setProtocolTreasury`; the dispatcher would be permanently unusable or route
    ///      UASSET settlement to a black hole. The initial owner zero-check is enforced separately by
    ///      `OutrunOwnableUpgradeable.__OutrunOwnable_init` (`OwnableInvalidOwner`).
    error ZeroAddress();

    /// @dev The compose payload carries a zero amount; nothing to settle or release.
    error ZeroInput();

    /// @dev The message-named yield vault's underlying asset does not equal the delivered memecoin, so a forged
    ///      (token, vault) pairing is rejected before any fund movement. Same selector as
    ///      `IOmnichainMemecoinStaker.TokenVaultMismatch` (identical signature, one shared binding error).
    error TokenVaultMismatch();

    /// @notice Initializes the dispatcher proxy.
    /// @dev Sets the owner and the three single-purpose addresses. The initial owner zero-check is enforced by
    ///      `__OutrunOwnable_init`; the other three are checked here (`ZeroAddress`). Intended to be called once via
    ///      the proxy constructor's delegatecall; `_disableInitializers` blocks any re-initialization of the impl.
    /// @param initialOwner Address that becomes the initial owner.
    /// @param localEndpoint Local LayerZero endpoint allowed to call `lzCompose`.
    /// @param memeverseLauncher Launcher allowed to call `distributeSameChain`.
    /// @param protocolTreasury Sink for UASSET no-code-receiver settlement (see `distributeSameChain` / `_settle`).
    function initialize(
        address initialOwner,
        address localEndpoint,
        address memeverseLauncher,
        address protocolTreasury
    ) external;

    /// @notice Sets the protocol treasury that receives UASSET settlement when a no-code receiver is named.
    /// @dev Only callable by the owner. The treasury is intended to be the same address across all chains.
    /// @param protocolTreasury The new protocol treasury address.
    function setProtocolTreasury(address protocolTreasury) external;

    /// @notice The local LayerZero endpoint allowed to call `lzCompose`.
    function localEndpoint() external view returns (address);

    /// @notice The launcher allowed to call `distributeSameChain`.
    function memeverseLauncher() external view returns (address);

    /// @notice The protocol treasury sink for UASSET no-code-receiver settlement.
    function protocolTreasury() external view returns (address);

    /// @notice Per-(token, guid) compose mutex shared by `lzCompose` and `settlePendingCompose`.
    function composeStates(address token, bytes32 guid) external view returns (ComposeState);

    /// @notice Settles same-chain fee proceeds routed by the launcher.
    /// @dev Same-chain fast path: the launcher has already transferred the fee token into this dispatcher, then calls
    ///      this entry, so the same settlement logic that handles bridged compose payloads also serves the local
    ///      fast path. A no-code `receiver` (EOA / undeployed) splits by `tokenType` in `_settle`: a MEMECOIN is
    ///      burned (`OFTProcessed.burnedAtDispatcher` is `true`); a UASSET is transferred to `protocolTreasury`
    ///      (`OFTProcessed.burnedAtDispatcher` is `false`). A contract `receiver` is settled via approve + pull
    ///      (`OFTProcessed.burnedAtDispatcher` is `false`). A zero `amount` short-circuits in `_settle`
    ///      (`if (amount == 0) return false`) as a no-op: no burn, no routing, no bookkeeping, and no downstream
    ///      approve + pull call.
    /// @param token Fee token to settle.
    /// @param receiver Yield vault, governor, or EOA burn target.
    /// @param tokenType Whether the token is a memecoin or a uAsset.
    /// @param amount Amount to settle, derived by the launcher from on-chain claimed fees. For the governor
    ///      uAsset path this is a two-bucket sum: launcher-held uAsset
    ///      transferred in via `_transferOut` (visible `Transfer`) plus PT-redeemed uAsset minted/redeemed
    ///      directly to the dispatcher via `preRedeemPTFee`/`redeemPT` with `mintTo = dispatcher` (no
    ///      launcher→dispatcher `Transfer`). Reconciliation must not use the launcher→dispatcher `Transfer`
    ///      amount alone or it undercounts the PT-redeem bucket.
    function distributeSameChain(address token, address receiver, TokenType tokenType, uint256 amount) external;

    /// @notice Settles a stuck compose payload to the beneficiary encoded in `message` when `lzCompose` never ran.
    /// @dev Permissionless: anyone may call, but the beneficiary is decoded from `message` and cannot be tampered with.
    ///      Delivery and authenticity are proven via the shared `OFTComposeSettleVerify.verifySettle` against the
    ///      endpoint's public `composeQueue` (three-state queue semantics — zero / RECEIVED_MESSAGE_HASH /
    ///      keccak256(message) — see `OFTComposeSettleVerify`'s @dev note).
    ///      Guards against double resolution with the same `composeStates` mutex used by `lzCompose`.
    ///      All checks run before any state change or state-changing external call (CEI), and the mutex is advanced to `Released`
    ///      before settlement. Settlement is identical to `_settle`: a no-code receiver splits by `tokenType` — a MEMECOIN
    ///      is burned (`ComposeSettled.burnedAtDispatcher` is `true`; actual destruction only for tokens implementing a
    ///      caller-callable single-arg `burn(uint256)`), and a UASSET is transferred to `protocolTreasury`
    ///      (`ComposeSettled.burnedAtDispatcher` is `false`); a contract receiver is settled via approve + pull
    ///      (initiated, not guaranteed to be pulled). An out-of-range TokenType cannot reach `_settle`: the
    ///      `abi.decode` below rejects it at the decode boundary (empty-data revert). `_settle`'s
    ///      `InvalidTokenType` branch is currently an unreachable defense-in-depth backstop.
    ///      Self-harm boundary: `lzReceive`/`sendCompose` is permissionless, so any token holder can send an OFT
    ///      payload naming a no-code `receiver`. For a UASSET such a payload now routes the sender's own uAsset to
    ///      `protocolTreasury` (`burnedAtDispatcher=false`) instead of reverting/stranding — a self-harm donation
    ///      reachable only via a permissionless direct OFT send (the protocol send-side always encodes a
    ///      governor/vault contract receiver).
    /// @param token Bridged token to settle.
    /// @param guid LayerZero compose guid.
    /// @param message The original compose payload (reconstructable from the endpoint's `ComposeSent` event log).
    /// @return amount Released amount.
    function settlePendingCompose(address token, bytes32 guid, bytes calldata message) external returns (uint256 amount);
}
