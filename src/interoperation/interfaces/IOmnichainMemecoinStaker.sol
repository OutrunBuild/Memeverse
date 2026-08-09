// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import {IComposeState} from "../../common/types/IComposeState.sol";

interface IOmnichainMemecoinStaker is IComposeState, ILayerZeroComposer {
    event OmnichainMemecoinStakingProcessed(
        bytes32 indexed guid, address indexed memecoin, address indexed yieldVault, address receiver, uint256 amount
    );

    /// @notice Emitted when a stuck staking compose payload is settled because `lzCompose` never executed.
    event StakingComposeSettled(
        bytes32 indexed guid, address indexed memecoin, address indexed receiver, uint256 amount
    );

    /// @dev Shared compose errors (`NotDelivered` / `AlreadyExecuted` / `InvalidProof` /
    ///      `MalformedComposeMsg`) and the `ComposeRejected` event are declared once in `IComposeState`,
    ///      inherited by both composer interfaces.

    error PermissionDenied();

    /// @dev The compose guid has already been resolved (settled or released) and cannot be acted on again.
    error AlreadyResolved();

    /// @dev Only the beneficiary decoded from `message` may settle the stuck stake; this blocks a third party from
    ///      front-running the settle before `lzCompose` runs.
    error NotBeneficiary();

    /// @dev The compose payload carries a zero amount; nothing to release.
    error ZeroInput();

    /// @dev The message-named yieldVault's underlying asset does not equal the delivered memecoin, so a forged
    /// (token, vault) pairing is rejected before any fund movement.
    error TokenVaultMismatch();

    /// @dev A constructor argument is the zero address; the contract would be permanently unusable.
    error ZeroAddress();

    /// @dev `MalformedComposeMsg` (declared in `IComposeState`) reverts on invalid schema shape. The two
    ///      entrypoints are intentionally asymmetric:
    ///      - `lzCompose` (the entry/staking path) must read both `receiver` and `yieldVault`, so it requires an exact
    ///        64-byte `(address, address)` composeMsg and reverts this error on any other length. The 64-byte check
    ///        bounds the shape only: a 64-byte frame with dirty-high-bit words does not revert this error —
    ///        `lzCompose` consumes it with `ComposeRejected` (dirty receiver word) or releases it via the
    ///        vault-absent fallback (dirty vault word). Frames shorter than the 76-byte compose header
    ///        (`message.length < 76`) are also rejected with this error, by the header-integrity guard —
    ///        `lzCompose`'s own `message.length >= 76` check, and `verifySettle`'s identical guard on the release
    ///        path — before any codec slice can run; the 64-byte check above is the inner-schema guard only.
    ///      - `settlePendingCompose` (the release path) only needs the beneficiary and always pushes via
    ///        `_transferOut`, never touching `yieldVault`, so it accepts any composeMsg of at least one 32-byte word
    ///        and reads only the first word as `receiver`, discarding trailing bytes. This lets the beneficiary
    ///        recover a self-stranded malformed (non-64 but >=32 byte) payload rather than trap it permanently.
    ///      Remaining revert cases on the release path: a frame shorter than the 76-byte compose header (rejected by
    ///      `verifySettle`'s header-integrity guard before the 32-byte check), composeMsg shorter than 32 bytes (no
    ///      receiver word to read), or a receiver word whose high 96 bits are non-zero (would truncate into a forged
    ///      address). A zero
    ///      receiver never reaches this error: it passes the shape check and falls through to `NotBeneficiary`, whose
    ///      `msg.sender == address(0)` test is permanently unsatisfiable.

    /// @notice Settles a stuck staking compose payload to the beneficiary encoded in `message` when `lzCompose` never ran.
    /// @dev Only the beneficiary (`msg.sender ==` the receiver read from `message`) may call, which blocks a third
    ///      party from front-running the settle before `lzCompose` runs; the beneficiary is bound to `message` via the
    ///      endpoint's `composeQueue` hash proof (immutable). Proves delivery against the endpoint's public
    ///      `composeQueue` mapping (three-state queue semantics: see `OFTComposeSettleVerify`'s @dev note), which is the
    ///      canonical record of whether a compose was delivered and still pending.
    ///      The receiver here is the original staker (an EOA or a contract able to self-initiate this settle call — a
    ///      contract receiver without any callable path cannot satisfy the `msg.sender == receiver` check, see
    ///      operations.md §3.13.1), released via direct push since there is no separate accounting step (unlike a
    ///      pull-based yield-vault release path).
    ///      Shape asymmetry with `lzCompose`: see `MalformedComposeMsg` above for the full asymmetry; the release
    ///      path reads only the first 32-byte word of the inner composeMsg as `receiver` and ignores trailing
    ///      bytes, so a non-64 but >=32-byte malformed payload is recoverable by the beneficiary.
    /// @param memecoin Bridged memecoin address that owns the compose payload.
    /// @param guid Compose guid used for replay protection.
    /// @param message Encoded compose payload proving the beneficiary and amount via the endpoint's composeQueue hash.
    /// @return amount Released memecoin amount in local decimals.
    function settlePendingCompose(address memecoin, bytes32 guid, bytes calldata message)
        external
        returns (uint256 amount);
}
