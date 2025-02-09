// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemeverseRegistrationCenter, MessagingFee } from "./interfaces/IMemeverseRegistrationCenter.sol";
import { IMemeverseRegistrarAtLocal, IMemeverseRegistrar } from "../verse/interfaces/IMemeverseRegistrarAtLocal.sol";

/**
 * @title Memeverse Omnichain Registration Center
 */
contract MemeverseRegistrationCenter is IMemeverseRegistrationCenter, OApp, TokenHelper {
    using Address for address;
    using OptionsBuilder for bytes;

    uint256 public constant DAY = 24 * 3600;
    address public immutable LOCAL_MEMEVERSE_REGISTRAR;

    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint128 public minLockupDays;
    uint128 public maxLockupDays;

    // Main symbol mapping, recording the latest registration information
    mapping(string symbol => SymbolRegistration) public symbolRegistry;

    // Symbol history mapping, storing all valid registration records
    mapping(string symbol => mapping(uint256 uniqueId => SymbolRegistration)) public symbolHistory;

    mapping(uint32 chainId => uint32) public endpointIds;

    mapping(uint32 chainId => uint128) public registerGasLimits;

    constructor(
        address _owner, 
        address _lzEndpoint, 
        address _localMemeverseRegistrar
    ) OApp(_lzEndpoint, _owner) Ownable(_owner) {
        LOCAL_MEMEVERSE_REGISTRAR = _localMemeverseRegistrar;
    }

    /**
     * @dev Preview if the symbol can be registered
     */
    function previewRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        return block.timestamp > currentRegistration.unlockTime;
    }

    /**
     * @dev Calculate the fee quotation for cross-chain transactions
     */
    function quoteSend(
        uint32[] memory omnichainIds, 
        bytes memory message
    ) public view override returns (uint256, uint256[] memory, uint32[] memory) {
        uint256 length = omnichainIds.length;
        uint256 totalFee;
        uint256[] memory fees = new uint256[](length);
        uint32[] memory eids = new uint32[](length);
        for (uint256 i = 0; i < length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) {
                fees[i] = 0;
                eids[i] = 0;
            } else {
                uint32 eid = endpointIds[omnichainId];
                require(eid != 0, InvalidOmnichainId(omnichainId));

                bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(registerGasLimits[omnichainId] , 0);
                uint256 fee = _quote(eid, message, options, false).nativeFee;
                totalFee += fee;
                fees[i] = fee;
                eids[i] = eid;
            }
        }

        return (totalFee, fees, eids);
    }

    /**
     * @dev Registration memeverse
     */
    function registration(RegistrationParam memory param) public payable override {
        _registrationParamValidation(param);

        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = symbolRegistry[param.symbol];
        uint64 currentUnlockTime = currentRegistration.unlockTime;
        require(currentTime > currentUnlockTime, SymbolNotUnlock(currentUnlockTime));
        
        if (currentUnlockTime != 0) {
            symbolHistory[param.symbol][currentRegistration.uniqueId] = SymbolRegistration({
                uniqueId: currentRegistration.uniqueId,
                registrar: currentRegistration.registrar,
                unlockTime: currentUnlockTime
            });
        }
        
        uint64 unlockTime = uint64(currentTime + param.lockupDays * DAY);
        uint256 uniqueId = uint256(keccak256(abi.encodePacked(param.symbol, currentTime, msg.sender)));
        currentRegistration.uniqueId = uniqueId;
        currentRegistration.registrar = param.registrar;
        currentRegistration.unlockTime = unlockTime;

        IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            uniqueId: uniqueId,
            maxFund: uint128(param.maxFund),
            endTime: uint64(currentTime + param.durationDays * DAY),
            unlockTime: unlockTime,
            omnichainIds: param.omnichainIds,
            creator: param.registrar,
            upt: param.upt
        });
        _omnichainSend(param.omnichainIds,  memeverseParam);

        emit Registration(uniqueId, param);
    }

    /**
     * @dev Cancel registration at local chain
     */
    function cancelRegistration(uint256 uniqueId, string calldata symbol) external override {
        require(msg.sender == LOCAL_MEMEVERSE_REGISTRAR, PermissionDenied());

        _cancelRegistration(uniqueId, symbol);
    }

    /**
     * @dev lzSend external call. Only called by self.
     */
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

    function _omnichainSend(uint32[] memory omnichainIds, IMemeverseRegistrar.MemeverseParam memory param) internal {
        bytes memory message = abi.encode(param);
        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = quoteSend(omnichainIds, message);
        require(msg.value >= totalFee, InsufficientLzFee());

        for (uint256 i = 0; i < eids.length; i++) {
            uint256 fee = fees[i];
            uint32 eid = eids[i];
            if (eid == 0) {
                IMemeverseRegistrarAtLocal(LOCAL_MEMEVERSE_REGISTRAR).localRegistration(param);
            } else {
                bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(registerGasLimits[omnichainIds[i]] , 0);
                bytes memory functionSignature = abi.encodeWithSignature(
                    "lzSend(uint32,bytes,bytes,(uint256,uint256),address)",
                    eid,
                    message,
                    options,
                    MessagingFee({nativeFee: fee, lzTokenFee: 0}),
                    param.creator
                );
                address(this).functionCallWithValue(functionSignature, fee);
            }
        }
    }

    function _registrationParamValidation(RegistrationParam memory param) internal view {
        require(param.lockupDays >= minLockupDays && param.lockupDays <= maxLockupDays, InvalidLockupDays());
        require(param.durationDays >= minDurationDays && param.durationDays <= maxDurationDays, InvalidDurationDays());
        require(bytes(param.name).length > 0 && bytes(param.name).length < 32, InvalidNameLength());
        require(bytes(param.symbol).length > 0 && bytes(param.symbol).length < 32, InvalidSymbolLength());
        require(bytes(param.uri).length > 0, InvalidURILength());
        require(param.omnichainIds.length > 0, EmptyOmnichainIds());
        require(param.registrar != address(0), ZeroRegistrarAddress());
        require(param.upt != address(0), ZeroUPTAddress());

        if (param.omnichainIds.length > 1) {
            require(param.maxFund > 0 && param.maxFund < type(uint128).max, MaxFundNotSetCorrectly());
        }
    }

    /**
     * @dev Internal function to implement lzReceive logic(Cancel Registration)
     */
    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal virtual override {
        (uint256 uniqueId, RegistrationParam memory param) = abi.decode(_message, (uint256, RegistrationParam));
        if (uniqueId == 0) {
            registration(param);
        } else {
            _cancelRegistration(uniqueId, param.symbol);
        }
    }

    /**
     * @dev Cancel registration when Memeverse enters the refund stage on all chains.
     */
    function _cancelRegistration(uint256 uniqueId, string memory symbol) internal {
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        uint256 currentUniqueId = currentRegistration.uniqueId;
        if (currentUniqueId == uniqueId) {
            currentRegistration.uniqueId = 0;
            currentRegistration.registrar = address(0);
            currentRegistration.unlockTime = 0;
        } else {
            SymbolRegistration storage history = symbolHistory[symbol][uniqueId];
            history.uniqueId = 0;
            history.registrar = address(0);
            history.unlockTime = 0;
        }
        
        emit CancelRegistration(uniqueId, symbol);
    }


    /*/////////////////////////////////////////////////////
                Memeverse Registration Config
    /////////////////////////////////////////////////////*/

    /**
     * @dev Set genesis stage duration days range
     * @param _minDurationDays - Min genesis stage duration days
     * @param _maxDurationDays - Max genesis stage duration days
     */
    function setDurationDaysRange(uint128 _minDurationDays, uint128 _maxDurationDays) external override onlyOwner {
        require(
            _minDurationDays != 0 && 
            _maxDurationDays != 0 && 
            _minDurationDays < _maxDurationDays, 
            InvalidInput()
        );

        minDurationDays = _minDurationDays;
        maxDurationDays = _maxDurationDays;
    }

    /**
     * @dev Set liquidity lockup days range
     * @param _minLockupDays - Min liquidity lockup days
     * @param _maxLockupDays - Max liquidity lockup days
     */
    function setLockupDaysRange(uint128 _minLockupDays, uint128 _maxLockupDays) external override onlyOwner {
        require(
            _minLockupDays != 0 && 
            _maxLockupDays != 0 && 
            _minLockupDays < _maxLockupDays, 
            InvalidInput()
        );

        minLockupDays = _minLockupDays;
        maxLockupDays = _maxLockupDays;
    }
    
    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            endpointIds[pair.chainId] = pair.endpointId;
        }
    }

    function setRegisterGasLimits(RegisterGasLimitPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            RegisterGasLimitPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.gasLimit == 0) continue;

            registerGasLimits[pair.chainId] = pair.gasLimit;
        }
    }
}
