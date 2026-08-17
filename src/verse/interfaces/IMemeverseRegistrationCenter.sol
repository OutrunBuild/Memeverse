// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title Memeverse Registration Center Interface
 */
interface IMemeverseRegistrationCenter {
    struct RegistrationParam {
        string name; // Token name
        string symbol; // Token symbol
        string uri; // Token icon uri
        string desc; // Description
        string[] communities; // Community, index -> 0:Website, 1:X, 2:Discord, 3:Telegram, >4:Others
        uint256 durationDays; // DurationDays of genesis stage
        uint32[] omnichainIds; // ChainIds of the token's omnichain(EVM)
        address uAsset; // uAsset of Memeverse
        bool flashGenesis; // Allowing the transition to the liquidity lock stage once the minimum funding requirement is met, without waiting for the genesis stage to end.
    }

    struct SymbolRegistration {
        uint256 uniqueId; // unique verseId
        uint64 endTime; // Memeverse genesis endTime
        uint192 nonce; // Number of replication
    }

    /**
     * @notice Checks whether a symbol is currently eligible for registration.
     * @dev Returns false while symbol lock window is active.
     * @param symbol Candidate ticker symbol.
     * @return True when the symbol can be registered at current state.
     */
    function previewRegistration(string calldata symbol) external view returns (bool);

    function DAY() external view returns (uint256);

    function symbolRegistry(string calldata symbol)
        external
        view
        returns (uint256 uniqueId, uint64 endTime, uint192 nonce);

    /**
     * @notice Quotes LayerZero native fee requirements for registration broadcasts.
     * @dev Aggregates per-destination send fee and returns endpoint ids in aligned order.
     * @param omnichainIds Target chain ids to receive registration payload.
     * @param message Encoded registration message payload.
     * @return totalFee Total native fee required for all destinations.
     * @return chainFees Per-chain native fee list aligned with `endpointIds`.
     * @return endpointIds Destination endpoint ids used for each quote entry.
     */
    function quoteSend(uint32[] memory omnichainIds, bytes memory message)
        external
        view
        returns (uint256, uint256[] memory, uint32[] memory);

    /**
     * @notice Registers a new verse and optionally dispatches omnichain replication messages.
     * @dev Consumes native fee for LayerZero sends when omnichain targets are requested.
     * @param param Registration payload including metadata, timing, and omnichain targets.
     */
    function registration(RegistrationParam calldata param) external payable;

    /**
     * @notice Sweeps residual native gas dust from the contract.
     * @dev Intended for owner-controlled housekeeping after batched sends.
     * @param receiver Address receiving recovered dust.
     */
    function removeGasDust(address receiver) external;

    /**
     * @notice Sends a raw LayerZero message to a destination endpoint.
     * @dev Low-level send helper used by registration broadcast flow.
     * @param dstEid Destination endpoint id.
     * @param message Encoded payload.
     * @param options LayerZero execution options.
     * @param fee LayerZero fee struct for native/lz-token costs.
     * @param refundAddress Address receiving unused fee refund.
     */
    function lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory options,
        MessagingFee memory fee,
        address refundAddress
    ) external payable;

    /**
     * @notice Enables or disables a uAsset token for registration funding.
     * @dev Token allowlist gate for verse creation. Membership-only: `uAsset` must be a plain
     *      ERC20 with no external-callback semantics (transfer/transferFrom/approve/mint/repay
     *      must not trigger external callbacks), guaranteed by governance and deployment — not
     *      enforced at runtime here.
     * @param uAsset uAsset token address.
     * @param isSupported Support status to apply.
     */
    function setSupportedUAsset(address uAsset, bool isSupported) external;

    /**
     * @notice Updates allowed genesis duration range for new verses.
     * @dev Values are interpreted in days and validated by registration flow.
     * @param minDurationDays Minimum allowed duration in days.
     * @param maxDurationDays Maximum allowed duration in days.
     */
    function setDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays) external;

    /**
     * @notice Sets default gas limit used for registration broadcast messages.
     * @dev Applied when building LayerZero options for cross-chain registration.
     * @param registerGasLimit New registration message gas limit.
     */
    function setRegisterGasLimit(uint256 registerGasLimit) external;

    /**
     * @notice Replaces the registrar pointer used by registration fan-out and inbound origin checks.
     * @dev Owner-only deadlock-unlock path (the registrar was previously constructor-baked). Inbound
     *      re-pointing must be paired with `setPeer` for each relevant eid: the OApp base enforces the
     *      peer check before `_lzReceive`, so until the peer is updated, inbound messages from the new
     *      registrar fail closed at the peer check (`OnlyPeer`), while messages from the OLD origin
     *      still pass it and die at `_lzReceive`'s storage-pointer origin check (`PermissionDenied`),
     *      burning LayerZero retry gas until the pairing completes — monitor both errors. The
     *      local-chain callback follows the storage pointer alone.
     * @param newRegistrar New registrar address (must not be zero).
     */
    function setMemeverseRegistrar(address newRegistrar) external;

    event Registration(uint256 indexed uniqueId, RegistrationParam param);

    event RemoveGasDust(address indexed receiver, uint256 dust);

    event SetSupportedUAsset(address uAsset, bool isSupported);

    event SetDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays);

    event SetRegisterGasLimit(uint256 registerGasLimit);

    event SetMemeverseRegistrar(address indexed oldRegistrar, address indexed newRegistrar);

    error ZeroInput();

    error InvalidUAsset();

    error InvalidInput();

    error InvalidLength();

    error PermissionDenied();

    error InsufficientLzFee();

    error InvalidDurationDays();

    error SymbolNotUnlock(uint64 unlockTime);

    error InvalidOmnichainId(uint32 omnichainId);

    /// @notice Reverts when a UUPS upgrade target's LayerZero endpoint differs from this center's.
    /// @dev Operational guardrail, not a security boundary — see `_authorizeUpgrade` dev comment.
    error UpgradeEndpointMismatch(address expected, address actual);

    /// @notice Reverts when a UUPS upgrade target's LayerZero endpoint getter cannot be read.
    /// @dev The target has code but the `IOAppCore.endpoint()` probe reverts or the getter is missing —
    ///      surfaced as this named error instead of a bare revert, the same greppable honest-failure
    ///      class as `UpgradeTargetCodeNotReady`. A successful call with non-decodable return data is
    ///      outside Solidity try/catch semantics and bubbles up as the raw decode revert; the upgrade
    ///      is rejected (fail-closed) either way.
    error UpgradeEndpointUnreadable(address newImplementation);

    /// @notice Reverts when a UUPS upgrade target address has no deployed code.
    /// @dev Pre-check so a no-code target fails with a named, locatable error instead of an opaque
    ///      ABI-decode revert from the endpoint probe.
    error UpgradeTargetCodeNotReady(address target);
}
