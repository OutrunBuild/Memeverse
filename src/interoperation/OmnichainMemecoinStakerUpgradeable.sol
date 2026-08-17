// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {OutrunOwnableUpgradeable} from "../common/access/OutrunOwnableUpgradeable.sol";
import {OFTComposeSettleVerify} from "../common/omnichain/OFTComposeSettleVerify.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IOmnichainMemecoinStaker} from "./interfaces/IOmnichainMemecoinStaker.sol";

/**
 * @title OmnichainMemecoinStakerUpgradeable
 * @dev The contract is designed to interact with LayerZero's Omnichain Fungible Token (OFT) Standard,
 *      accepts Memecoin and stakes to the yield vault. UUPS form of the former constructor-deployed
 *      OmnichainMemecoinStaker: identical business logic and storage semantics behind an ERC1967Proxy,
 *      so the custody of stranded bridged memecoin survives implementation repair at a stable address.
 *      The owner holds upgrade authorization only — `lzCompose` / `settlePendingCompose` carry zero
 *      owner permissions, and there is no pause or rescue path.
 */
contract OmnichainMemecoinStakerUpgradeable layout at erc7201("outrun.storage.OmnichainMemecoinStaker")
    is
    IOmnichainMemecoinStaker,
    Initializable,
    OutrunOwnableUpgradeable,
    UUPSUpgradeable,
    TokenHelper
{
    /// @notice Storage layout for the OmnichainMemecoinStakerUpgradeable ERC-7201 namespace.
    ///         When adding fields in upgrades, append only at the end. Never reorder or insert fields.
    /// @custom:storage-location erc7201:outrun.storage.OmnichainMemecoinStaker
    struct OmnichainMemecoinStakerStorage {
        address localEndpoint;
        /// @dev Single-resolution state per (memecoin, guid), shared by `lzCompose` (Settled) and
        ///      `settlePendingCompose` (Released). Keying on the bridged memecoin (not just the guid) means
        ///      a forged settle with an arbitrary token only advances the attacker's own slot, never a real
        ///      guid's mutex.
        mapping(address memecoin => mapping(bytes32 guid => ComposeState)) composeStates;
    }

    /// @dev Namespaced storage. The contract header's `layout at erc7201(...)` binds this struct to the
    ///      ERC-7201 base slot of "outrun.storage.OmnichainMemecoinStaker".
    OmnichainMemecoinStakerStorage private omnichainMemecoinStakerStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice This is the UUPS implementation contract. Do not call directly.
    ///         Use the proxy contract for all interactions.
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time proxy initializer. Binds the owner and the local LayerZero endpoint.
    /// @dev Deterministic dependencies may be predicted addresses during CREATE3 deployment, so
    ///      initialization checks non-zero addresses without requiring code to exist yet. The initial
    ///      owner zero-check is enforced by `__OutrunOwnable_init` (`OwnableInvalidOwner`).
    /// @param initialOwner Address that becomes the initial owner (upgrade authorization only).
    /// @param _localEndpoint Local LayerZero endpoint that is allowed to call `lzCompose`.
    function initialize(address initialOwner, address _localEndpoint) external initializer {
        __OutrunOwnable_init(initialOwner);
        require(_localEndpoint != address(0), ZeroAddress());
        omnichainMemecoinStakerStorage.localEndpoint = _localEndpoint;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @notice Local LayerZero endpoint that is allowed to call `lzCompose` (set once by `initialize`).
    /// @return Configured local endpoint address.
    function localEndpoint() external view returns (address) {
        return omnichainMemecoinStakerStorage.localEndpoint;
    }

    /// @notice Per-(memecoin, guid) compose mutex shared by `lzCompose` (writes Settled) and
    ///         `settlePendingCompose` (writes Released); a pair resolves at most once.
    /// @param memecoin Bridged memecoin address keying the mutex.
    /// @param guid Compose guid keying the mutex.
    /// @return Current ComposeState of the pair (None / Settled / Released).
    function composeStates(address memecoin, bytes32 guid) external view returns (ComposeState) {
        return omnichainMemecoinStakerStorage.composeStates[memecoin][guid];
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
    ///      receiver==0 self-harm boundary (the fallback's zero-address guard reverts and the slot stays pinned).
    /// @param memecoin Bridged memecoin address.
    /// @param guid Compose guid used for replay protection.
    /// @param message Encoded compose payload containing the receiver and yield-vault target.
    function lzCompose(address memecoin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        require(msg.sender == omnichainMemecoinStakerStorage.localEndpoint, PermissionDenied());
        // Single-resolution guard shared with `settlePendingCompose`: a guid settles at most once via this path.
        ComposeState state = omnichainMemecoinStakerStorage.composeStates[memecoin][guid];
        if (state == ComposeState.Released) return;
        require(state == ComposeState.None, AlreadyResolved());
        // CEI: mark settled first; a revert below rolls the write back, leaving the guid releasable and retryable.
        omnichainMemecoinStakerStorage.composeStates[memecoin][guid] = ComposeState.Settled;

        // Reject a short frame (header incomplete) with a named error before the codec slices (`amountLD` [12:44],
        // `composeMsg` [76:]) revert opaquely. Mirrors `verifySettle`'s header guard. CEI rolls the `Settled` write
        // back, so a short frame leaves the guid `None`.
        require(message.length >= OFTComposeSettleVerify.COMPOSE_HEADER_LENGTH, MalformedComposeMsg());

        uint256 amount = OFTComposeMsgCodec.amountLD(message);
        // composeMsg = message[76:], so this length check is the former `composeMsg.length == 64` (cannot underflow:
        // header guard above proved message.length >= 76). A non-64 frame reverts here (CEI Settled rolls back); inner
        // >= 32 bytes stays releasable via `settlePendingCompose`, inner < 32 is a dead class with no recovery.
        // Read raw words from calldata at fixed offsets instead of `composeMsg()`+`abi.decode`
        // to skip a 64-byte memory copy — mirrors `YieldDispatcherUpgradeable._parseCompose`.
        require(message.length - OFTComposeSettleVerify.COMPOSE_HEADER_LENGTH == 64, MalformedComposeMsg());
        // Decode as uint256, not (address, address): solc's strict decoder rejects dirty-high-bit address words with
        // an empty unreadable revert, pinning the endpoint queue (no named error, CEI rolled back, no consumption).
        // Raw uint256 words skip that validator so every content class resolves explicitly. Offsets (composeMsg =
        // message[76:]): word0 at [76:108] (receiver), word1 at [108:140] (vault).
        uint256 receiverRaw = uint256(bytes32(message[76:108]));
        uint256 vaultRaw = uint256(bytes32(message[108:140]));
        // A dirty receiver word can never be released (`settlePendingCompose` rejects it) and is hash-bound to this
        // guid, so the Settled slot is consumed with a rejection signal — the queue converges instead of pinning for
        // retries; funds stay in staker custody (self-harm boundary).
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
            // return 0 by the interface contract and are exempt (zero-amount convergence).
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
        require(omnichainMemecoinStakerStorage.composeStates[memecoin][guid] == ComposeState.None, AlreadyResolved());

        bytes memory composeMsg;
        (amount, composeMsg) =
            OFTComposeSettleVerify.verifySettle(omnichainMemecoinStakerStorage.localEndpoint, memecoin, guid, message);
        require(amount != 0, ZeroInput());
        // Release-path schema guard. Unlike `lzCompose`, which reads both `receiver` and `yieldVault` and enforces an
        // exact 64-byte composeMsg, the release path only needs the beneficiary (always pushes via `_transferOut`,
        // never touches `yieldVault`). So the shape is asymmetric on purpose: it accepts any composeMsg of at least
        // one 32-byte word, reads only the first as `receiver`, discarding trailing bytes. This makes a self-stranded
        // malformed payload (non-64 but >=32 bytes) recoverable rather than permanently trapped. Length checked
        // before the read (no OOB).
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
        omnichainMemecoinStakerStorage.composeStates[memecoin][guid] = ComposeState.Released;
        _transferOut(memecoin, receiver, amount);

        emit StakingComposeSettled(guid, memecoin, receiver, amount);
    }
}
