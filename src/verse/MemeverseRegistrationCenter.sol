// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemeverseCommonInfo } from "./interfaces/IMemeverseCommonInfo.sol";
import { IMemeverseRegistrationCenter, MessagingFee } from "./interfaces/IMemeverseRegistrationCenter.sol";
import { IMemeverseRegistrarAtLocal, IMemeverseRegistrar } from "../verse/interfaces/IMemeverseRegistrarAtLocal.sol";

/**
 * @title Memeverse Omnichain Registration Center
 */
contract MemeverseRegistrationCenter is IMemeverseRegistrationCenter, OApp, TokenHelper {
    using Address for address;
    using OptionsBuilder for bytes;

    // uint256 public constant DAY = 24 * 3600;
    uint256 public constant DAY = 180;  // OutrunTODO 180 seconds for testing
    address public immutable MEMEVERSE_REGISTRAR;
    address public immutable MEMEVERSE_COMMON_INFO;

    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint128 public minLockupDays;
    uint128 public maxLockupDays;
    uint256 public registerGasLimit;

    // Main symbol mapping, recording the latest registration information
    mapping(string symbol => SymbolRegistration) public symbolRegistry;

    // Symbol history mapping, storing all valid registration records
    mapping(string symbol => mapping(uint256 uniqueId => SymbolRegistration)) public symbolHistory;

    /**
     * @notice Constructor
     * @param _owner - The owner of the contract
     * @param _lzEndpoint - The lz endpoint
     * @param _memeverseRegistrar - The memeverse registrar
     */
    constructor(
        address _owner, 
        address _lzEndpoint, 
        address _memeverseRegistrar,
        address _memeverseCommonInfo
    ) OApp(_lzEndpoint, _owner) Ownable(_owner) {
        MEMEVERSE_REGISTRAR = _memeverseRegistrar;
        MEMEVERSE_COMMON_INFO = _memeverseCommonInfo;
    }

    /**
     * @notice Preview if the symbol can be registered
     * @param symbol - The symbol to preview
     * @return true if the symbol can be registered, false otherwise
     */
    function previewRegistration(string calldata symbol) external view override returns (bool) {
        if (bytes(symbol).length >= 32) return false;
        SymbolRegistration storage currentRegistration = symbolRegistry[symbol];
        return block.timestamp > currentRegistration.endTime;
    }

    /**
     * @notice Calculate the fee quotation for cross-chain transactions
     * @param omnichainIds - The omnichain ids
     * @param message - The message to send
     * @return totalFee - The total cross-chain fee
     * @return fees - The cross-chain fee for each omnichain id
     * @return eids - The lz endpoint id for each omnichain id
     */
    function quoteSend(
        uint32[] memory omnichainIds, 
        bytes memory message
    ) public view override returns (uint256, uint256[] memory, uint32[] memory) {
        uint256 totalFee;
        uint256 length = omnichainIds.length;
        uint256[] memory fees = new uint256[](length);
        uint32[] memory eids = new uint32[](length);
        uint32 currentChainId = uint32(block.chainid); 
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(registerGasLimit) , 0);
        
        unchecked {
            for (uint256 i = 0; i < length; i++) {
                uint32 omnichainId = omnichainIds[i];
                if (omnichainId == currentChainId) {
                    fees[i] = 0;
                    eids[i] = 0;
                    continue;
                }

                uint32 eid = IMemeverseCommonInfo(MEMEVERSE_COMMON_INFO).lzEndpointIdMap(omnichainId);
                require(eid != 0, InvalidOmnichainId(omnichainId));

                uint256 fee = _quote(eid, message, options, false).nativeFee;
                totalFee += fee;
                fees[i] = fee;
                eids[i] = eid;
            }
        }

        return (totalFee, fees, eids);
    }

    /**
     * @notice Registration memeverse
     * @param param - The registration parameter
     */
    function registration(RegistrationParam memory param) public payable override {
        _registrationParamValidation(param);

        uint256 currentTime = block.timestamp;
        SymbolRegistration storage currentRegistration = symbolRegistry[param.symbol];
        uint64 currentEndTime = currentRegistration.endTime;
        uint192 currentNonce = currentRegistration.nonce;
        require(currentTime > currentEndTime, SymbolNotUnlock(currentEndTime));
        
        if (currentEndTime != 0) {
            symbolHistory[param.symbol][currentRegistration.uniqueId] = SymbolRegistration({
                uniqueId: currentRegistration.uniqueId,
                endTime: currentEndTime,
                nonce: currentNonce
            });
        }
        
        uint64 endTime = uint64(currentTime + param.durationDays * DAY);
        uint256 uniqueId = uint256(keccak256(abi.encodePacked(param.symbol, currentNonce + 1, param.UPT)));
        currentRegistration.uniqueId = uniqueId;
        currentRegistration.endTime = endTime;

        IMemeverseRegistrar.MemeverseParam memory memeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uniqueId,
            endTime: endTime,
            unlockTime: endTime + uint64(param.lockupDays * DAY),
            omnichainIds: param.omnichainIds,
            UPT: param.UPT,
            flashGenesis: param.flashGenesis
        });
        _omnichainSend(param.omnichainIds, memeverseParam);

        emit Registration(uniqueId, param);
    }

    /**
     * @dev Remove gas dust from the contract
     */
    function removeGasDust(address receiver) external override onlyOwner {
        uint256 dust = address(this).balance;
        _transferOut(NATIVE, receiver, dust);

        emit RemoveGasDust(receiver, dust);
    }

    /**
     * @notice lzSend external call. Only called by self.
     * @param dstEid - The destination eid
     * @param message - The message
     * @param options - The options
     * @param fee - The cross-chain fee
     * @param refundAddress - The refund address
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

    /**
     * @notice Omnichain send
     * @param omnichainIds - The omnichain ids
     * @param param - The registration parameter
     */
    function _omnichainSend(uint32[] memory omnichainIds, IMemeverseRegistrar.MemeverseParam memory param) internal {
        bytes memory message = abi.encode(param);
        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = quoteSend(omnichainIds, message);
        require(msg.value >= totalFee, InsufficientLzFee());

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(registerGasLimit) , 0);
        for (uint256 i = 0; i < eids.length; i++) {
            uint256 fee = fees[i];
            uint32 eid = eids[i];
            if (eid == 0) {
                IMemeverseRegistrarAtLocal(MEMEVERSE_REGISTRAR).localRegistration(param);
                continue;
            }
            
            bytes memory functionSignature = abi.encodeWithSignature(
                "lzSend(uint32,bytes,bytes,(uint256,uint256),address)",
                eid,
                message,
                options,
                MessagingFee({nativeFee: fee, lzTokenFee: 0}),
                msg.sender
            );
            address(this).functionCallWithValue(functionSignature, fee);
        }
    }

    /**
     * @notice Registration parameter validation
     * @param param - The registration parameter
     */
    function _registrationParamValidation(RegistrationParam memory param) internal view {
        require(param.lockupDays >= minLockupDays && param.lockupDays <= maxLockupDays, InvalidLockupDays());
        require(param.durationDays >= minDurationDays && param.durationDays <= maxDurationDays, InvalidDurationDays());
        require(bytes(param.name).length > 0 && bytes(param.name).length < 32, InvalidLength());
        require(bytes(param.symbol).length > 0 && bytes(param.symbol).length < 32, InvalidLength());
        require(bytes(param.uri).length > 0, InvalidLength());
        require(bytes(param.desc).length > 0 && bytes(param.desc).length < 256, InvalidLength());
        require(param.UPT != address(0), ZeroUPTAddress());

        uint32[] memory omnichainIds = param.omnichainIds;
        require(omnichainIds.length > 0 && omnichainIds.length < 32, InvalidLength());
        param.omnichainIds = _deduplicate(omnichainIds);
    }

    function _deduplicate(uint32[] memory input) internal pure returns (uint32[] memory) {
        if (input.length == 0) {
            return new uint32[](0);
        }

        uint32[] memory temp = new uint32[](input.length);
        uint uniqueCount = 0;
        bool found;

        for (uint i = 0; i < input.length; i++) {
            found = false;
            for (uint j = 0; j < uniqueCount; j++) {
                if (temp[j] == input[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[uniqueCount] = input[i];
                uniqueCount++;
            }
        }

        uint32[] memory unique = new uint32[](uniqueCount);
        for (uint i = 0; i < uniqueCount; i++) {
            unique[i] = temp[i];
        }

        return unique;
    }

    /**
     * @notice Internal function to implement lzReceive logic
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal virtual override {
        require(_origin.sender == bytes32(uint256(uint160(MEMEVERSE_REGISTRAR))), PermissionDenied());
        registration(abi.decode(_message, (RegistrationParam)));
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

        emit SetDurationDaysRange(_minDurationDays, _maxDurationDays);
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

        emit SetLockupDaysRange(_minLockupDays, _maxLockupDays);
    }

    /**
     * @dev Set the register gas limit
     * @param _registerGasLimit - The register gas limit
     */
    function setRegisterGasLimit(uint256 _registerGasLimit) external override onlyOwner {
        require(_registerGasLimit > 0, ZeroInput());

        registerGasLimit = _registerGasLimit;

        emit SetRegisterGasLimit(_registerGasLimit);
    }
}
