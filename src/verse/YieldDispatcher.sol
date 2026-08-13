// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";
import {OFTComposeSettleVerify} from "../common/omnichain/OFTComposeSettleVerify.sol";
import {ISettleCompose} from "../common/omnichain/ISettleCompose.sol";
import {IBurnable} from "../common/interfaces/IBurnable.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IYieldDispatcher} from "./interfaces/IYieldDispatcher.sol";
import {IMemecoinDaoGovernor} from "../governance/interfaces/IMemecoinDaoGovernor.sol";

/**
 * @title Yield Dispatcher
 * @dev Routes bridged or same-chain launcher fee proceeds to the yield vault or governor treasury.
 *      Cross-chain deliveries arrive through LayerZero's OFT compose flow (`lzCompose`); the launcher's
 *      same-chain fast path uses the dedicated `distributeSameChain` entry.
 */
contract YieldDispatcher layout at erc7201("outrun.storage.YieldDispatcher")
    is
    IYieldDispatcher,
    ISettleCompose,
    Initializable,
    OutrunOwnableUpgradeable,
    UUPSUpgradeable,
    TokenHelper
{
    // Compose payload wire offsets (see `_parseCompose`): 44 / 76 are OFTComposeMsgCodec's AMOUNT_LD_OFFSET /
    // COMPOSE_FROM_OFFSET constants (amountLD spans [12:44], composeFrom [44:76]); the 64-byte abi-encoded
    // (address, TokenType) tuple follows them, its two words at RECEIVER_OFFSET / TOKEN_TYPE_OFFSET.
    uint256 private constant AMOUNT_LD_OFFSET = 44;
    uint256 private constant COMPOSE_FROM_OFFSET = OFTComposeSettleVerify.COMPOSE_HEADER_LENGTH;
    uint256 private constant TUPLE_LENGTH = 64;
    uint256 private constant RECEIVER_OFFSET = COMPOSE_FROM_OFFSET + 32;
    uint256 private constant TOKEN_TYPE_OFFSET = COMPOSE_FROM_OFFSET + TUPLE_LENGTH;

    /// @notice Storage layout for the YieldDispatcher ERC-7201 namespace.
    ///         When adding fields in upgrades, append only at the end. Never reorder or insert fields.
    /// @custom:storage-location erc7201:outrun.storage.YieldDispatcher
    struct YieldDispatcherStorage {
        address localEndpoint;
        address memeverseLauncher;
        address protocolTreasury;
        mapping(address token => mapping(bytes32 guid => ComposeState)) composeStates;
    }

    /// @dev Namespaced storage. The contract header's `layout at erc7201(...)` binds this struct to the ERC-7201
    ///      base slot of "outrun.storage.YieldDispatcher".
    ///      The `composeStates` mapping is the per-(token, guid) compose mutex shared by `lzCompose` (sets Settled)
    ///      and `settlePendingCompose` (sets Released). Both entries reject any (token, guid) pair that is no longer
    ///      `None`, so a pair can be resolved at most once, regardless of which path runs first. Keying on the
    ///      genuine bridged `token` (not just the guid) prevents an attacker from burning a real guid's mutex by
    ///      settling with a forged token address: a forged settle touches at most the attacker's own (token, guid)
    ///      slot — mismatched token↔vault pairings are reverted by the MEMECOIN binding before even that
    ///      (see `_settleToContract`) — and leaves the real pair untouched.
    YieldDispatcherStorage private yieldDispatcherStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice This is the UUPS implementation contract. Do not call directly.
    ///         Use the proxy contract for all interactions.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the dispatcher proxy.
    /// @dev Deterministic dependencies may be predicted addresses during CREATE3 deployment, so initialization
    ///      checks non-zero addresses without requiring code to exist yet. The initial owner zero-check is enforced
    ///      by `__OutrunOwnable_init` (`OwnableInvalidOwner`).
    /// @param initialOwner Address that becomes the initial owner.
    /// @param _localEndpoint Local LayerZero endpoint that is allowed to call `lzCompose`.
    /// @param _memeverseLauncher Launcher allowed to call `distributeSameChain`.
    /// @param _protocolTreasury Sink for UASSET no-code-receiver settlement (see `_settle`).
    function initialize(
        address initialOwner,
        address _localEndpoint,
        address _memeverseLauncher,
        address _protocolTreasury
    ) external initializer {
        __OutrunOwnable_init(initialOwner);
        require(
            _localEndpoint != address(0) && _memeverseLauncher != address(0) && _protocolTreasury != address(0),
            ZeroAddress()
        );
        yieldDispatcherStorage.localEndpoint = _localEndpoint;
        yieldDispatcherStorage.memeverseLauncher = _memeverseLauncher;
        yieldDispatcherStorage.protocolTreasury = _protocolTreasury;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @notice Sets the protocol treasury that receives UASSET settlement when a no-code receiver is named.
    /// @dev Only callable by the owner. The treasury is intended to be the same address across all chains
    ///      (a protocol-level single sink); cross-chain consistency is a deployment convention, not an invariant.
    /// @param _protocolTreasury The new protocol treasury address.
    function setProtocolTreasury(address _protocolTreasury) external onlyOwner {
        address prev = yieldDispatcherStorage.protocolTreasury;
        require(_protocolTreasury != address(0), ZeroAddress());
        yieldDispatcherStorage.protocolTreasury = _protocolTreasury;
        emit ProtocolTreasuryChanged(prev, _protocolTreasury);
    }

    function localEndpoint() external view returns (address) {
        return yieldDispatcherStorage.localEndpoint;
    }

    function memeverseLauncher() external view returns (address) {
        return yieldDispatcherStorage.memeverseLauncher;
    }

    function protocolTreasury() external view returns (address) {
        return yieldDispatcherStorage.protocolTreasury;
    }

    function composeStates(address token, bytes32 guid) external view returns (ComposeState) {
        return yieldDispatcherStorage.composeStates[token][guid];
    }

    /// @notice Processes an incoming OFT compose payload for protocol treasury routing.
    /// @dev Only the local LayerZero endpoint may call this. The per-(token, guid) `composeStates` mutex is set to
    ///      `Settled` before settlement (CEI) so a reentrant or repeated delivery cannot double-resolve the same
    ///      guid. A `Released` pair is absorbed as a no-op; structurally invalid payloads (undecodable or
    ///      out-of-range TokenType) and a clean parseable payload naming this dispatcher as its own receiver
    ///      (`receiver == address(this)`) are consumed with `Settled` + `ComposeRejected` and no settlement —
    ///      shared convergence / hash-binding / self-harm rationale: see `IComposeState`'s @dev note (authoritative).
    ///      Local specifics: `_parseCompose` rejects a payload exactly when it can never decode (strict-ABI
    ///      mirror); the self-reference branch exists because `_settleToContract` would fail on this contract,
    ///      which implements neither `asset()` (the MEMECOIN binding probe) nor the settle callbacks and has no
    ///      fallback, so settlement would always revert. Replay protection lives entirely in this mutex; there is
    ///      no token-side executed-status tracking.
    /// @param token Bridged token being routed.
    /// @param guid LayerZero compose guid used for replay protection.
    /// @param message Encoded treasury-routing payload.
    function lzCompose(address token, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        require(msg.sender == yieldDispatcherStorage.localEndpoint, PermissionDenied());
        // Released pairs are absorbed as a no-op — see the @dev above for the rationale.
        ComposeState state = yieldDispatcherStorage.composeStates[token][guid];
        if (state == ComposeState.Released) return;
        require(state == ComposeState.None, AlreadyResolved());

        // Every path through this section resolves the slot to Settled before any terminal action
        // (reject event or settlement), so a future branch cannot forget the mutex write. A payload
        // that can never settle (its content is hash-bound to the guid by the endpoint) is consumed
        // with NO settlement: the endpoint state machine converges (RECEIVED sentinel +
        // ComposeDelivered) instead of pinning the queue for executor retries, and consuming the
        // slot never blocks legitimate settlement.
        (uint256 amount, address receiver, TokenType tokenType, bool parseable) = _parseCompose(message);
        yieldDispatcherStorage.composeStates[token][guid] = ComposeState.Settled;
        if (!parseable) {
            emit ComposeRejected(guid, token, amount);
            return;
        }

        // Self-reference guard: a clean, parseable payload that names this dispatcher as its own
        // receiver can never settle — `_settleToContract` would call `accumulateYields`/`receiveTreasuryIncome`
        // on this contract, which implements neither and has no fallback, so the call reverts. Without this
        // branch the revert would roll the `Settled` write back to `None` and pin the endpoint queue forever
        // (no recovery entrypoint), contradicting the convergence goal stated in the @dev above. Mirroring the
        // `!parseable` consume path above, the slot stays `Settled` (written before this branch) and a
        // `ComposeRejected` signal lets the endpoint state machine converge. Reachable only via a permissionless
        // OFT direct send where a token holder encodes `receiver == address(this)` (the protocol send-side
        // always encodes governor/vault), so this is a self-harm boundary: the funds strand in the dispatcher
        // by the sender's own construction, but the endpoint no longer pins.
        if (receiver == address(this)) {
            emit ComposeRejected(guid, token, amount);
            return;
        }

        bool isBurned = _settle(token, receiver, tokenType, amount);
        emit OFTProcessed(guid, token, tokenType, receiver, amount, isBurned);
    }

    /// @inheritdoc IYieldDispatcher
    function distributeSameChain(address token, address receiver, TokenType tokenType, uint256 amount) external {
        require(msg.sender == yieldDispatcherStorage.memeverseLauncher, PermissionDenied());
        bool isBurned = _settle(token, receiver, tokenType, amount);
        emit OFTProcessed(bytes32(0), token, tokenType, receiver, amount, isBurned);
    }

    /// @inheritdoc IYieldDispatcher
    function settlePendingCompose(address token, bytes32 guid, bytes calldata message)
        external
        override(IYieldDispatcher, ISettleCompose)
        returns (uint256 amount)
    {
        require(yieldDispatcherStorage.composeStates[token][guid] == ComposeState.None, AlreadyResolved());

        bytes memory composeMsg;
        (amount, composeMsg) =
            OFTComposeSettleVerify.verifySettle(yieldDispatcherStorage.localEndpoint, token, guid, message);
        require(amount != 0, ZeroInput());
        // Schema-shape guard: the inner (address, TokenType) tuple must be at least 64 bytes to decode. `abi.decode`
        // reads only this static tuple's first two words and ignores anything past 64 bytes, so an overlong inner
        // (> 64 bytes, frame > 140) settles exactly as the forward `lzCompose` path settles it — `_parseCompose`
        // reads the same two words at the same offsets and ignores the tail — making this fallback a re-run of the
        // identical forward settlement (operations.md §3.13). Overlong frames are reachable only via a permissionless
        // OFT direct send (the protocol send-side always encodes a 64-byte inner), i.e. the self-harm boundary. An
        // inner < 64 bytes is still named-rejected (`MalformedComposeMsg`), matching the forward path's unparseable
        // set; a length-legal frame with a dirty-high-bit receiver word or an out-of-range TokenType word still
        // reverts at the bare `abi.decode` below (unchanged empty-data revert boundary, also recorded in
        // operations.md §3.13).
        require(composeMsg.length >= TUPLE_LENGTH, MalformedComposeMsg());
        (address receiver, TokenType tokenType) = abi.decode(composeMsg, (address, TokenType));

        yieldDispatcherStorage.composeStates[token][guid] = ComposeState.Released;
        bool isBurned = _settle(token, receiver, tokenType, amount);
        emit ComposeSettled(guid, token, receiver, tokenType, amount, isBurned);
    }

    /// @dev Defensive compose payload parser: returns `parseable = false` instead of reverting when
    ///      the payload can never decode as (address, TokenType). Mirrors the strict ABI decoder's
    ///      semantics (frame length, clean address slot, exact in-range enum word): on solc 0.8.x
    ///      strict decoding, unparseable exactly equals the `abi.decode` revert set — dirty-high-bit
    ///      address words, out-of-range/dirty enum words, and short tuples all revert — so rejection
    ///      ⇔ can never settle. If a future decoder variant ever relaxes that strictness, this
    ///      implementation stays the stricter side, which is the safe direction and never blocks
    ///      legitimate settlement (real senders encode clean addresses). Layout per
    ///      OFTComposeMsgCodec:
    ///      [nonce(8)][srcEid(4)][amountLD(32)][composeFrom(32)][composeMsg], with composeMsg the
    ///      (address, TokenType) tuple (see the offset constants below).
    function _parseCompose(bytes calldata message)
        internal
        pure
        returns (uint256 amount, address receiver, TokenType tokenType, bool parseable)
    {
        // amountLD lives at [12:44]; real endpoint deliveries are always >= 77 bytes, so it is
        // readable for every reachable malformed frame. The < AMOUNT_LD_OFFSET guard is defense-in-depth only.
        if (message.length >= AMOUNT_LD_OFFSET) amount = OFTComposeMsgCodec.amountLD(message);

        // composeMsg(message) slices at COMPOSE_FROM_OFFSET; the (address, TokenType) tuple needs TUPLE_LENGTH bytes.
        if (message.length < COMPOSE_FROM_OFFSET + TUPLE_LENGTH) return (amount, address(0), TokenType.UASSET, false);

        // Receiver slot: strict address encoding (the high 12 bytes must be zero). The two tuple words
        // are read straight from calldata at absolute offsets to avoid a memory copy of composeMsg and
        // keep the parse pure calldata reads; bytes32 slices of memory arrays are also not directly
        // convertible.
        uint256 receiverRaw = uint256(bytes32(message[COMPOSE_FROM_OFFSET:RECEIVER_OFFSET]));
        if (receiverRaw >> 160 != 0) return (amount, address(0), TokenType.UASSET, false);
        receiver = address(uint160(receiverRaw));

        // TokenType slot: the enum word must be exactly 0 (UASSET) or 1 (MEMECOIN); anything else
        // (including dirty high bits) is unparseable.
        uint256 typeRaw = uint256(bytes32(message[RECEIVER_OFFSET:TOKEN_TYPE_OFFSET]));
        if (typeRaw == 0) {
            tokenType = TokenType.UASSET;
        } else if (typeRaw == 1) {
            tokenType = TokenType.MEMECOIN;
        } else {
            return (amount, address(0), TokenType.UASSET, false);
        }

        parseable = true;
    }

    /// @dev Routes `amount` of `token` to `receiver` based on `tokenType`.
    ///      The unified settlement entry, shared by `lzCompose`, `distributeSameChain`, and `settlePendingCompose`,
    ///      so the settle path stays semantically identical to the forward settlement path.
    ///      For no-code receivers (EOA / undeployed) the route splits by `tokenType`: a MEMECOIN is burned (actual
    ///      destruction only for tokens implementing a caller-callable single-arg `burn(uint256)`, so `isBurned=true`);
    ///      a UASSET is transferred to `protocolTreasury` (uAsset OFTs expose no caller-callable single-arg
    ///      `burn(uint256)`, so the old burn path reverted/stranded the funds) and `isBurned=false`.
    ///      For contract receivers the token is approved for exactly `amount`
    ///      (since each receiver only pulls once per call) and the receiver pulls it via a callback — the exact-approval
    ///      cap bounds pulls only for genuine bridged frames (a forged frame's amountLD is sender-chosen up to
    ///      `type(uint256).max`, but its token key is the forger's own address, so no third-party exposure). That
    ///      key-side argument alone does not protect the vault side — a forged (fake token, real vault) frame would
    ///      approve the real vault against the dispatcher's standing real-token allowance — so the MEMECOIN branch
    ///      adds a binding layer: the delivered token must equal the vault's own `asset()` (see `_settleToContract`),
    ///      reverting before any approve, and the defense no longer depends on the no-standing-allowance invariant.
    ///      UASSET receivers carry no pairing class (the governor pulls the payload-named token), so no binding
    ///      applies there.
    ///      A zero amount is a no-op (returns isBurned=false): it converges a zero-amount compose without burning,
    ///      routing, or accounting, matching the vault branch's own zero-yield early return and the staker's
    ///      _transferOut(0).
    function _settle(address token, address receiver, TokenType tokenType, uint256 amount)
        internal
        returns (bool isBurned)
    {
        // Currently unreachable defense-in-depth backstop: every caller (lzCompose via _parseCompose,
        // distributeSameChain via calldata decoding, settlePendingCompose via abi.decode)
        // rejects out-of-range enums before reaching this point.
        if (tokenType != TokenType.MEMECOIN && tokenType != TokenType.UASSET) revert InvalidTokenType();
        // Zero amount carries no value; returning early lets a zero-amount compose converge (the EOA burn and
        // UASSET→governor branches would otherwise revert ZeroInput downstream). isBurned stays false.
        if (amount == 0) return false;
        if (receiver.code.length == 0) {
            if (tokenType == TokenType.MEMECOIN) {
                IBurnable(token).burn(amount);
                isBurned = true;
            } else {
                // UASSET: route to the protocol treasury instead of burning. uAsset OFTs expose no caller-callable
                // single-arg burn(uint256), so the prior unconditional burn reverted (stranding) for real uAssets.
                // `InvalidTokenType` above guarantees this else-branch is UASSET. `_transferOut` is `nonReentrant`.
                _transferOut(token, yieldDispatcherStorage.protocolTreasury, amount);
                isBurned = false;
            }
        } else {
            _settleToContract(token, receiver, tokenType, amount);
        }
    }

    /// @dev Routes `amount` of `token` to a contract `receiver` based on `tokenType`.
    ///      MEMECOIN→yieldVault approve + `accumulateYields` (pull + `totalAssets` accounting),
    ///      UASSET→governor approve + `receiveTreasuryIncome` (pull + `treasuryBalances` accounting).
    ///      The MEMECOIN branch binds the delivered token to the vault's underlying asset (`TokenVaultMismatch`
    ///      before the approve), mirroring the staker's deposit branch: a forged (fake token, real vault) frame is
    ///      intercepted before any fund movement. UASSET applies no binding: the governor pulls the payload-named
    ///      token, so no (token, receiver) mismatch class exists.
    function _settleToContract(address token, address receiver, TokenType tokenType, uint256 amount) internal {
        if (tokenType == TokenType.MEMECOIN) {
            // Bind the delivered token to the vault's own underlying asset: a forged (fake token, real vault)
            // pairing must revert here, before any approval, or the real vault's pull could drain real memecoin
            // from this contract's custody. Mirrors OmnichainMemecoinStaker's deposit-branch binding.
            require(IMemecoinYieldVault(receiver).asset() == token, TokenVaultMismatch());
            _safeApprove(token, receiver, amount);
            IMemecoinYieldVault(receiver).accumulateYields(amount);
        } else if (tokenType == TokenType.UASSET) {
            _safeApprove(token, receiver, amount);
            IMemecoinDaoGovernor(receiver).receiveTreasuryIncome(token, amount);
        }
    }
}
