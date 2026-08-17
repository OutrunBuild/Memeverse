// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Origin} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {TokenHelper} from "../../common/token/TokenHelper.sol";
import {DelegatecallOnly} from "../../common/access/DelegatecallOnly.sol";
import {ILzEndpointRegistry} from "../../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {OutrunOAppUpgradeable} from "../../common/omnichain/oapp/OutrunOAppUpgradeable.sol";
import {IMemeverseRegistrationCenter, MessagingFee} from "../interfaces/IMemeverseRegistrationCenter.sol";
import {IMemeverseRegistrarAtLocal, IMemeverseRegistrar} from "../interfaces/IMemeverseRegistrarAtLocal.sol";
import {MemeverseRegistrationLib} from "../libraries/MemeverseRegistrationLib.sol";

/**
 * @title Memeverse Omnichain Registration Center
 * @dev UUPS form of the former constructor-deployed MemeverseRegistrationCenter: identical business logic
 *      and storage semantics, deployed behind an ERC1967Proxy so implementation defects are repairable
 *      in place and the registrar pointer is owner-replaceable (`setMemeverseRegistrar`).
 *
 *      Deviation from the repo's `OutrunOwnableUpgradeable` convention: the LayerZero `OAppUpgradeable`
 *      base already inherits OZ `OwnableUpgradeable`, whose single owner lives in the shared
 *      `openzeppelin.storage.OwnableUpgradeable` namespace. Mixing in `OutrunOwnableUpgradeable` would
 *      create a second owner slot (`outrun.storage.Ownable`) that nothing keeps in sync, so the OZ base's
 *      owner is used directly. The base's exposed `renounceOwnership` always reverts via the shared
 *      `OutrunOAppUpgradeable` base — repo invariant: ownership is never renounceable.
 */
contract MemeverseRegistrationCenterUpgradeable layout at erc7201("outrun.storage.MemeverseRegistrationCenter")
    is
    IMemeverseRegistrationCenter,
    OutrunOAppUpgradeable,
    UUPSUpgradeable,
    TokenHelper,
    DelegatecallOnly
{
    using Address for address;
    using OptionsBuilder for bytes;

    // uint256 public constant DAY = 24 * 3600;
    uint256 public constant DAY = 180; // OutrunTODO 180 seconds for testing

    /// @notice Storage layout for the MemeverseRegistrationCenterUpgradeable ERC-7201 namespace.
    ///         When adding fields in upgrades, append only at the end. Never reorder or insert fields.
    /// @custom:storage-location erc7201:outrun.storage.MemeverseRegistrationCenter
    struct MemeverseRegistrationCenterStorage {
        address memeverseRegistrar;
        address lzEndpointRegistry;
        uint128 minDurationDays;
        uint128 maxDurationDays;
        uint256 registerGasLimit;
        // Main symbol mapping, recording the latest registration information
        mapping(string symbol => SymbolRegistration) symbolRegistry;
        // Symbol history mapping, storing all valid registration records
        mapping(string symbol => mapping(uint256 uniqueId => SymbolRegistration)) symbolHistory;
        mapping(address uAsset => bool) supportedUAssets;
    }

    /// @dev Namespaced storage. The contract header's `layout at erc7201(...)` binds this struct to the
    ///      ERC-7201 base slot of "outrun.storage.MemeverseRegistrationCenter". The registrar pointer is
    ///      mutable owner storage (see `setMemeverseRegistrar`); `lzEndpointRegistry` has no setter.
    MemeverseRegistrationCenterStorage private registrationCenterStorage;

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice This is the UUPS implementation contract. Do not call directly.
    ///         Use the proxy contract for all interactions.
    /// @param _lzEndpoint Local LayerZero endpoint, burned into the implementation as an immutable shared
    ///        by every upgrade (guarded by `_authorizeUpgrade`).
    constructor(address _lzEndpoint) OutrunOAppUpgradeable(_lzEndpoint) {
        // Named zero-check: OAppCoreUpgradeable's constructor accepts a zero endpoint silently; without
        // this guard the mistake would only surface at initialize's `endpoint.setDelegate` CALL with an
        // opaque revert (the endpoint is baked immutably here, initialize can no longer catch it).
        require(_lzEndpoint != address(0), ZeroInput());
        _disableInitializers();
    }

    // LayerZero native fee refunds target address(this); this fallback keeps them receivable so
    // removeGasDust can sweep them. The inherited `onlyDelegatecall` guard (see `DelegatecallOnly`)
    // keeps that acceptance proxy-only: a refund arrives at the ERC1967Proxy as an empty-calldata value
    // call, falls through to the proxy fallback's delegatecall, and passes the guard because
    // address(this) is the proxy, not the implementation's own `_SELF`. A direct plain send to the raw
    // implementation instead reverts `DelegatecallOnlyCall`, bouncing misdirected ETH back to the
    // sender — the implementation's owner is permanently zero (`_disableInitializers`), so balance
    // landing there could never be swept via the owner-only `removeGasDust`.
    receive() external payable onlyDelegatecall {}

    /// @notice One-time proxy initializer. Binds the owner, the registrar pointer, and the registry pointer.
    /// @dev `__OApp_init(initialOwner)` also performs `endpoint.setDelegate(initialOwner)` on the proxy, handing the
    ///      owner the endpoint-side send/receive library configuration rights. The owner zero-check is
    ///      enforced by `__Ownable_init` (`OwnableInvalidOwner`).
    /// @param initialOwner Address that becomes the initial owner.
    /// @param _memeverseRegistrar Registrar authorized to drive registrations (mutable via `setMemeverseRegistrar`).
    /// @param _lzEndpointRegistry Registry resolving omnichain ids to LayerZero eids (no setter).
    function initialize(address initialOwner, address _memeverseRegistrar, address _lzEndpointRegistry)
        external
        initializer
    {
        __Ownable_init(initialOwner);
        __OApp_init(initialOwner);
        require(_memeverseRegistrar != address(0) && _lzEndpointRegistry != address(0), ZeroInput());

        registrationCenterStorage.memeverseRegistrar = _memeverseRegistrar;
        registrationCenterStorage.lzEndpointRegistry = _lzEndpointRegistry;
    }

    /// @notice Checks whether a symbol can be registered right now.
    /// @dev A symbol becomes available again only after its latest registration window has fully expired.
    /// @param symbol Symbol to check.
    /// @return available True when the symbol is unlocked and can be registered again.
    function previewRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;
        SymbolRegistration storage currentRegistration = registrationCenterStorage.symbolRegistry[symbol];
        return block.timestamp > currentRegistration.endTime;
    }

    /// @notice Quotes the center's outbound registration fan-out cost.
    /// @dev Local targets contribute zero fee; each remote target contributes one LayerZero quote.
    /// @param omnichainIds Target chain ids included in the registration.
    /// @param message Encoded memeverse registration payload sent to remote registrars.
    /// @return totalFee Sum of all remote native fees.
    /// @return fees Per-target native fee aligned with `omnichainIds`.
    /// @return eids Per-target endpoint ids aligned with `omnichainIds`, with zero for local targets.
    function quoteSend(uint32[] memory omnichainIds, bytes memory message)
        public
        view
        override
        returns (uint256 totalFee, uint256[] memory fees, uint32[] memory eids)
    {
        uint256 length = omnichainIds.length;
        fees = new uint256[](length);
        eids = new uint32[](length);
        uint32 currentChainId = uint32(block.chainid);
        // Registry pointer read once before the loop: nothing writes the slot during quoting and the loop
        // body only makes STATICCALLs, so one read is equivalent per iteration and restores the
        // pre-conversion immutable-read cost profile.
        ILzEndpointRegistry registry = ILzEndpointRegistry(registrationCenterStorage.lzEndpointRegistry);
        bytes memory options = _registerOptions(uint128(registrationCenterStorage.registerGasLimit));

        for (uint256 i = 0; i < length;) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == currentChainId) {
                fees[i] = 0;
                eids[i] = 0;
                unchecked {
                    ++i;
                }
                continue;
            }

            uint32 eid = registry.lzEndpointIdOfChain(omnichainId);
            require(eid != 0, InvalidOmnichainId(omnichainId));

            uint256 fee = _quote(eid, message, options, false).nativeFee;
            totalFee += fee;
            fees[i] = fee;
            eids[i] = eid;
            unchecked {
                ++i;
            }
        }

        return (totalFee, fees, eids);
    }

    /// @notice Registers a symbol at the center and fans the registration out to all target chains.
    /// @dev Stores the current registration record, archives the previous one if needed, and dispatches local or
    /// remote registration hooks for every target chain.
    /// @param param Registration request submitted by a local or omnichain registrar.
    function registration(RegistrationParam memory param) public payable override {
        _registrationParamValidation(param);

        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = registrationCenterStorage.symbolRegistry[param.symbol];
        uint64 currentEndTime = currentRegistration.endTime;
        uint192 currentNonce = currentRegistration.nonce;
        require(currentTime > currentEndTime, SymbolNotUnlock(currentEndTime));

        if (currentEndTime != 0) {
            registrationCenterStorage.symbolHistory[param.symbol][currentRegistration.uniqueId] = SymbolRegistration({
                uniqueId: currentRegistration.uniqueId, endTime: currentEndTime, nonce: currentNonce
            });
        }

        uint256 endTimeRaw = currentTime + param.durationDays * DAY;
        require(endTimeRaw <= MemeverseRegistrationLib.MAX_END_TIME, InvalidInput());

        uint192 nextNonce = currentNonce + 1;
        uint64 endTime = uint64(endTimeRaw);
        uint64 unlockTime = uint64(endTimeRaw + MemeverseRegistrationLib.FIXED_LOCKUP_DURATION);
        uint256 uniqueId = MemeverseRegistrationLib.deriveUniqueId(param.symbol, nextNonce, param.uAsset);
        currentRegistration.uniqueId = uniqueId;
        currentRegistration.endTime = endTime;
        currentRegistration.nonce = nextNonce;

        IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uniqueId,
            endTime: endTime,
            unlockTime: unlockTime,
            omnichainIds: param.omnichainIds,
            uAsset: param.uAsset,
            flashGenesis: param.flashGenesis
        });
        _omnichainSend(param.omnichainIds, memeverseParam);

        emit Registration(uniqueId, param);
    }

    /// @notice Sweeps any native-token dust sitting on the center.
    /// @dev Intended for owner-side cleanup of refunds or residual gas balances.
    /// @param receiver Address that receives the withdrawn dust.
    function removeGasDust(address receiver) external override onlyOwner {
        uint256 dust = address(this).balance;
        _transferOut(NATIVE, receiver, dust);

        emit RemoveGasDust(receiver, dust);
    }

    /// @notice Forwards a LayerZero send through the center contract itself.
    /// @dev Only the center itself may reach this wrapper; it exists so `_omnichainSend` can reuse the OApp send path
    /// through a normal external call with value.
    /// @param dstEid Destination LayerZero endpoint id.
    /// @param message Encoded registration payload.
    /// @param options LayerZero options.
    /// @param fee Native and lzToken fee bundle supplied to the endpoint.
    /// @param refundAddress Address that should receive any unused LayerZero native refund.
    function lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory options,
        MessagingFee memory fee,
        address refundAddress
    ) public payable override {
        require(msg.sender == address(this), PermissionDenied());

        _lzSend(dstEid, message, options, fee, refundAddress);
    }

    /**
     * @notice Omnichain send
     * @param omnichainIds - The omnichain ids
     * @param param - The registration parameter
     */
    function _omnichainSend(uint32[] memory omnichainIds, IMemeverseRegistrar.MemeverseParam memory param) internal {
        bytes memory message = abi.encode(param);
        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = quoteSend(omnichainIds, message);
        require(msg.value >= totalFee, InsufficientLzFee());

        // Single `registerGasLimit` slot read for the send-time options; `quoteSend` above already read
        // the same slot once for pricing. No writer can run between the two reads
        // (`setRegisterGasLimit` is owner-only external), so both observe the same value.
        uint128 registerGasLimit_ = uint128(registrationCenterStorage.registerGasLimit);
        bytes memory options = _registerOptions(registerGasLimit_);
        uint256 eidsLength = eids.length;
        // Registrar pointer read once before the fan-out: the loop's only consumer is the local branch's
        // call, and nothing can re-point it mid-loop (`setMemeverseRegistrar` is owner-only while the loop's
        // external calls are the registrar callback and the self-call wrapper, neither holding owner rights).
        address registrar = registrationCenterStorage.memeverseRegistrar;
        for (uint256 i = 0; i < eidsLength;) {
            uint256 fee = fees[i];
            uint32 eid = eids[i];
            unchecked {
                ++i;
            }
            if (eid == 0) {
                IMemeverseRegistrarAtLocal(registrar).localRegistration(param);
                continue;
            }

            bytes memory functionSignature = abi.encodeCall(
                this.lzSend, (eid, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), address(this))
            );
            address(this).functionCallWithValue(functionSignature, fee);
        }
    }

    /// @dev Single source for the outbound registration receive options, shared by `quoteSend` (fee
    ///      quoting) and `_omnichainSend` (actual sends) so the two can never drift apart. Storage-free:
    ///      each caller reads the `registerGasLimit` slot once and passes the value in. Within one
    ///      `registration` call no writer can run between the quote-time read and the send-time read
    ///      (`setRegisterGasLimit` is owner-only external), so the send options are always built from the
    ///      exact value the just-completed quote was priced with.
    function _registerOptions(uint128 registerGasLimit_) internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(registerGasLimit_, 0);
    }

    /**
     * @notice Registration parameter validation
     * @param param - The registration parameter
     */
    function _registrationParamValidation(RegistrationParam memory param) internal view {
        require(
            param.durationDays >= registrationCenterStorage.minDurationDays
                && param.durationDays <= registrationCenterStorage.maxDurationDays,
            InvalidDurationDays()
        );
        require(bytes(param.name).length > 0 && bytes(param.name).length < 32, InvalidLength());
        require(bytes(param.symbol).length > 0 && bytes(param.symbol).length < 32, InvalidLength());
        require(bytes(param.uri).length > 0, InvalidLength());
        require(bytes(param.desc).length > 0 && bytes(param.desc).length < 256, InvalidLength());
        // Whitelist membership is the only uAsset gate here; the plain-ERC20 (no external callback)
        // token-kind precondition is guaranteed by governance and deployment, not checked at runtime.
        require(registrationCenterStorage.supportedUAssets[param.uAsset], InvalidUAsset());

        uint32[] memory omnichainIds = param.omnichainIds;
        require(omnichainIds.length > 0 && omnichainIds.length < 32, InvalidLength());
        param.omnichainIds = MemeverseRegistrationLib.deduplicate(omnichainIds);
    }

    /**
     * @notice Internal function to implement lzReceive logic
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        virtual
        override
    {
        address registrar = registrationCenterStorage.memeverseRegistrar;
        require(_origin.sender == bytes32(uint256(uint160(registrar))), PermissionDenied());
        registration(abi.decode(_message, (RegistrationParam)));
    }

    /*/////////////////////////////////////////////////////
                Memeverse Registration Config
    /////////////////////////////////////////////////////*/

    /// @notice Updates whether a fundraising token is accepted for new registrations.
    /// @dev Only callable by the owner.
    ///      `uAsset` must be a plain ERC20 with no external-callback semantics: `transfer` /
    ///      `transferFrom` / `approve` / `mint` / `repay` must not trigger any external callback
    ///      during execution. Callback-capable assets are outside the protocol's supported scope;
    ///      this precondition is guaranteed by governance and deployment, not runtime detection
    ///      (this setter only manages whitelist membership). A callback-capable `uAsset` would
    ///      conditionally enable the LP per-share accounting reentrancy window (F-020) at
    ///      `MemeverseUniswapHookUpgradeable.sol::_addLiquidityCore`.
    /// @param uAsset Fundraising token address to update.
    /// @param isSupported Whether the token should be accepted for future registrations.
    function setSupportedUAsset(address uAsset, bool isSupported) external override onlyOwner {
        require(uAsset != address(0), ZeroInput());
        registrationCenterStorage.supportedUAssets[uAsset] = isSupported;

        emit SetSupportedUAsset(uAsset, isSupported);
    }

    /// @notice Updates the allowed registration duration range.
    /// @dev Only callable by the owner.
    /// @param _minDurationDays New minimum registration duration, measured in `DAY` units.
    /// @param _maxDurationDays New maximum registration duration, measured in `DAY` units.
    function setDurationDaysRange(uint128 _minDurationDays, uint128 _maxDurationDays) external override onlyOwner {
        require(_minDurationDays != 0 && _maxDurationDays != 0 && _minDurationDays < _maxDurationDays, InvalidInput());

        registrationCenterStorage.minDurationDays = _minDurationDays;
        registrationCenterStorage.maxDurationDays = _maxDurationDays;

        emit SetDurationDaysRange(_minDurationDays, _maxDurationDays);
    }

    /// @notice Updates the remote receive gas used for outbound registration sends.
    /// @dev Only callable by the owner.
    /// @param _registerGasLimit New gas limit forwarded into remote registration receive options.
    function setRegisterGasLimit(uint256 _registerGasLimit) external override onlyOwner {
        require(_registerGasLimit > 0, ZeroInput());
        // Storage keeps the full uint256, but every consumer (`quoteSend` / `_omnichainSend`) narrows the
        // stored limit to uint128 when building the LayerZero receive options. Reject values above
        // `type(uint128).max` so that narrowing cast can never silently truncate a stored limit; the sibling
        // `setGasLimits` entries are uint128-typed at the ABI already, so this setter is the only truncation
        // surface.
        require(_registerGasLimit <= type(uint128).max, InvalidInput());

        registrationCenterStorage.registerGasLimit = _registerGasLimit;

        emit SetRegisterGasLimit(_registerGasLimit);
    }

    /// @notice Replaces the registrar pointer used by the local fan-out callback and the inbound origin check.
    /// @dev Only callable by the owner. Deadlock-unlock path: the registrar pointer was previously a
    ///      constructor-baked immutable, so a broken or key-compromised registrar left the whole
    ///      cross-chain registration flow deadlocked with redeploy as the only recovery. Coupling with
    ///      `setPeer`: the OApp base enforces `peers[srcEid] == origin.sender` BEFORE `_lzReceive` runs,
    ///      so re-pointing inbound traffic to a new registrar requires pairing this setter with `setPeer`
    ///      for each relevant eid. Intermediate state (pointer moved, peer not yet) fails closed on BOTH
    ///      inbound sides but with different errors — monitor both, not just `OnlyPeer`: messages from the
    ///      NEW registrar origin die at the base's peer check with `OnlyPeer`; messages from the OLD origin
    ///      still pass the peer check (peers still names it) and die at `_lzReceive`'s storage-pointer
    ///      origin check with `PermissionDenied`, burning LayerZero retry gas until the pairing completes.
    ///      The local-chain `localRegistration` callback follows the storage
    ///      pointer alone (no peer check on that path).
    /// @param newRegistrar New registrar address (must not be zero).
    function setMemeverseRegistrar(address newRegistrar) external override onlyOwner {
        require(newRegistrar != address(0), ZeroInput());

        address oldRegistrar = registrationCenterStorage.memeverseRegistrar;
        registrationCenterStorage.memeverseRegistrar = newRegistrar;

        emit SetMemeverseRegistrar(oldRegistrar, newRegistrar);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev UUPS upgrade gate, restricted to the owner. Also guards against LayerZero endpoint drift: a
    ///      new implementation constructed with a different endpoint would silently break every send and
    ///      receive path, so we revert `UpgradeEndpointMismatch`. This is an operational guardrail,
    ///      not a security boundary — a malicious owner could ship a fake `endpoint()` getter;
    ///      the guard catches honest constructor mistakes during upgrade.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // Named pre-check for a no-code target: without it the probe's STATICCALL to a codeless
        // address would SUCCEED with empty returndata, and that success-path decode failure is
        // outside Solidity try/catch — it bubbles as a raw decode revert (see the boundary note
        // below), losing the precise `UpgradeTargetCodeNotReady` label.
        if (newImplementation.code.length == 0) revert UpgradeTargetCodeNotReady(newImplementation);
        // Read the new implementation's immutable endpoint through the IOAppCore getter, then reject
        // drift. The try/catch folds the unreadable-target failures it can see (getter missing, probe
        // reverts) into the named `UpgradeEndpointUnreadable` instead of a bare revert. One class stays
        // outside the catch: a successful call whose return data cannot be ABI-decoded is NOT caught by
        // Solidity try/catch semantics and bubbles up as the raw decode revert — still fail-closed, the
        // upgrade is rejected either way, only the error label differs. `currentEndpoint` is the local
        // immutable self-read, not a call.
        address currentEndpoint = address(endpoint);
        try IOAppCore(newImplementation).endpoint() returns (ILayerZeroEndpointV2 newEndpoint) {
            if (address(newEndpoint) != currentEndpoint) {
                revert UpgradeEndpointMismatch(currentEndpoint, address(newEndpoint));
            }
        } catch {
            revert UpgradeEndpointUnreadable(newImplementation);
        }
    }

    // --- View functions (replacing auto-generated public getters) ---

    /// @notice Registrar currently authorized to drive registrations.
    /// @return Configured registrar address.
    function memeverseRegistrar() external view returns (address) {
        return registrationCenterStorage.memeverseRegistrar;
    }

    /// @notice Registry resolving omnichain chain ids to LayerZero endpoint ids.
    /// @return Configured registry address.
    function lzEndpointRegistry() external view returns (address) {
        return registrationCenterStorage.lzEndpointRegistry;
    }

    /// @notice Minimum allowed registration duration, measured in `DAY` units.
    /// @return Configured minimum duration.
    function minDurationDays() external view returns (uint128) {
        return registrationCenterStorage.minDurationDays;
    }

    /// @notice Maximum allowed registration duration, measured in `DAY` units.
    /// @return Configured maximum duration.
    function maxDurationDays() external view returns (uint128) {
        return registrationCenterStorage.maxDurationDays;
    }

    /// @notice Remote receive gas limit forwarded into outbound registration send options.
    /// @return Configured gas limit.
    function registerGasLimit() external view returns (uint256) {
        return registrationCenterStorage.registerGasLimit;
    }

    /// @notice Latest registration record for a symbol.
    /// @param symbol Ticker symbol to look up.
    /// @return uniqueId Unique verse id of the latest registration.
    /// @return endTime Genesis end time of that registration.
    /// @return nonce Replication counter of that registration.
    function symbolRegistry(string calldata symbol)
        external
        view
        override
        returns (uint256 uniqueId, uint64 endTime, uint192 nonce)
    {
        SymbolRegistration storage currentRegistration = registrationCenterStorage.symbolRegistry[symbol];
        return (currentRegistration.uniqueId, currentRegistration.endTime, currentRegistration.nonce);
    }

    /// @notice Archived historical registration record for a symbol and unique id.
    /// @param symbol Ticker symbol to look up.
    /// @param uniqueId Archived verse id.
    /// @return uniqueId Unique verse id of the archived registration.
    /// @return endTime Genesis end time of the archived registration.
    /// @return nonce Replication counter of the archived registration.
    function symbolHistory(string calldata symbol, uint256 uniqueId) external view returns (uint256, uint64, uint192) {
        SymbolRegistration storage archivedRegistration = registrationCenterStorage.symbolHistory[symbol][uniqueId];
        return (archivedRegistration.uniqueId, archivedRegistration.endTime, archivedRegistration.nonce);
    }

    /// @notice Whether a fundraising token is whitelisted for new registrations.
    /// @param uAsset Fundraising token address.
    /// @return True when the token is accepted for future registrations.
    function supportedUAssets(address uAsset) external view returns (bool) {
        return registrationCenterStorage.supportedUAssets[uAsset];
    }
}
