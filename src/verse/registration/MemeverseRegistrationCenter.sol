// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp, Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {TokenHelper} from "../../common/token/TokenHelper.sol";
import {ILzEndpointRegistry} from "../../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IMemeverseRegistrationCenter, MessagingFee} from "../interfaces/IMemeverseRegistrationCenter.sol";
import {IMemeverseRegistrarAtLocal, IMemeverseRegistrar} from "../interfaces/IMemeverseRegistrarAtLocal.sol";
import {MemeverseRegistrationLib} from "../libraries/MemeverseRegistrationLib.sol";

/**
 * @title Memeverse Omnichain Registration Center
 */
contract MemeverseRegistrationCenter is IMemeverseRegistrationCenter, OApp, TokenHelper {
    using Address for address;
    using OptionsBuilder for bytes;

    // uint256 public constant DAY = 24 * 3600;
    uint256 public constant DAY = 180; // OutrunTODO 180 seconds for testing
    address public immutable MEMEVERSE_REGISTRAR;
    address public immutable LZ_ENDPOINT_REGISTRY;

    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint256 public registerGasLimit;

    // Main symbol mapping, recording the latest registration information
    mapping(string symbol => SymbolRegistration) public symbolRegistry;

    // Symbol history mapping, storing all valid registration records
    mapping(string symbol => mapping(uint256 uniqueId => SymbolRegistration)) public symbolHistory;

    mapping(address uAsset => bool) public supportedUAssets;

    /**
     * @notice Constructor
     * @param _owner - The owner of the contract
     * @param _lzEndpoint - The lz endpoint
     * @param _memeverseRegistrar - The memeverse registrar
     */
    constructor(address _owner, address _lzEndpoint, address _memeverseRegistrar, address _lzEndpointRegistry)
        OApp(_lzEndpoint, _owner)
        Ownable(_owner)
    {
        require(_memeverseRegistrar != address(0) && _lzEndpointRegistry != address(0), ZeroInput());
        MEMEVERSE_REGISTRAR = _memeverseRegistrar;
        LZ_ENDPOINT_REGISTRY = _lzEndpointRegistry;
    }

    receive() external payable {}

    /// @notice Checks whether a symbol can be registered right now.
    /// @dev A symbol becomes available again only after its latest registration window has fully expired.
    /// @param symbol Symbol to check.
    /// @return available True when the symbol is unlocked and can be registered again.
    function previewRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
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
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(registerGasLimit), 0);

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

            uint32 eid = ILzEndpointRegistry(LZ_ENDPOINT_REGISTRY).lzEndpointIdOfChain(omnichainId);
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
        SymbolRegistration storage currentRegistration = symbolRegistry[param.symbol];
        uint64 currentEndTime = currentRegistration.endTime;
        uint192 currentNonce = currentRegistration.nonce;
        require(currentTime > currentEndTime, SymbolNotUnlock(currentEndTime));

        if (currentEndTime != 0) {
            symbolHistory[param.symbol][currentRegistration.uniqueId] = SymbolRegistration({
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

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(registerGasLimit), 0);
        uint256 eidsLength = eids.length;
        for (uint256 i = 0; i < eidsLength;) {
            uint256 fee = fees[i];
            uint32 eid = eids[i];
            unchecked {
                ++i;
            }
            if (eid == 0) {
                IMemeverseRegistrarAtLocal(MEMEVERSE_REGISTRAR).localRegistration(param);
                continue;
            }

            bytes memory functionSignature = abi.encodeCall(
                this.lzSend, (eid, message, options, MessagingFee({nativeFee: fee, lzTokenFee: 0}), address(this))
            );
            address(this).functionCallWithValue(functionSignature, fee);
        }
    }

    /**
     * @notice Registration parameter validation
     * @param param - The registration parameter
     */
    function _registrationParamValidation(RegistrationParam memory param) internal view {
        require(param.durationDays >= minDurationDays && param.durationDays <= maxDurationDays, InvalidDurationDays());
        require(bytes(param.name).length > 0 && bytes(param.name).length < 32, InvalidLength());
        require(bytes(param.symbol).length > 0 && bytes(param.symbol).length < 32, InvalidLength());
        require(bytes(param.uri).length > 0, InvalidLength());
        require(bytes(param.desc).length > 0 && bytes(param.desc).length < 256, InvalidLength());
        // Whitelist membership is the only uAsset gate here; the plain-ERC20 (no external callback)
        // token-kind precondition is guaranteed by governance and deployment, not checked at runtime.
        require(supportedUAssets[param.uAsset], InvalidUAsset());

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
        require(_origin.sender == bytes32(uint256(uint160(MEMEVERSE_REGISTRAR))), PermissionDenied());
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
        supportedUAssets[uAsset] = isSupported;

        emit SetSupportedUAsset(uAsset, isSupported);
    }

    /// @notice Updates the allowed registration duration range.
    /// @dev Only callable by the owner.
    /// @param _minDurationDays New minimum registration duration, measured in `DAY` units.
    /// @param _maxDurationDays New maximum registration duration, measured in `DAY` units.
    function setDurationDaysRange(uint128 _minDurationDays, uint128 _maxDurationDays) external override onlyOwner {
        require(_minDurationDays != 0 && _maxDurationDays != 0 && _minDurationDays < _maxDurationDays, InvalidInput());

        minDurationDays = _minDurationDays;
        maxDurationDays = _maxDurationDays;

        emit SetDurationDaysRange(_minDurationDays, _maxDurationDays);
    }

    /// @notice Updates the remote receive gas used for outbound registration sends.
    /// @dev Only callable by the owner.
    /// @param _registerGasLimit New gas limit forwarded into remote registration receive options.
    function setRegisterGasLimit(uint256 _registerGasLimit) external override onlyOwner {
        require(_registerGasLimit > 0, ZeroInput());

        registerGasLimit = _registerGasLimit;

        emit SetRegisterGasLimit(_registerGasLimit);
    }
}
