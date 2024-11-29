// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { CREATE3 } from "@solmate/utils/CREATE3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import { Memecoin } from "./Memecoin.sol";
import { MemeLiquidProof } from "./MemeLiquidProof.sol";
import { LzMessageConfig } from "../common/LzMessageConfig.sol";
import { IMemeverseRegistrar } from "./interfaces/IMemeverseRegistrar.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";

/**
 * @title Factory for deploying memecoin to deterministic addresses via CREATE3
 */ 
contract MemeverseRegistrar is IMemeverseRegistrar, LzMessageConfig, Ownable {
    uint32 public constant BSC_CHAINID = 97;      // TODO update mainnet
    address public immutable LOCAL_LZ_ENDPOINT;
    address public immutable LOCAL_SEND_LIBRARY;
    address public immutable LOCAL_RECEIVE_LIBRARY;
    address public immutable MEMEVERSE_LAUNCHER;

    address public localLzExecutor;

    mapping(address caller => bool) callers;
    mapping(uint32 chainId => uint32) endpointIds;

    constructor(
        address _owner, 
        address _localLzEndpoint, 
        address _localSendLibrary, 
        address _localReceiveLibrary, 
        address _localLzExecutor,
        address _memeverseLauncher, 
        address _localRegistrationCenter
    ) Ownable(_owner) {
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        LOCAL_SEND_LIBRARY = _localSendLibrary;
        LOCAL_RECEIVE_LIBRARY = _localReceiveLibrary;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        localLzExecutor = _localLzExecutor;
        
        callers[_localLzExecutor] = true;
        if (block.chainid == BSC_CHAINID) {
            callers[_localRegistrationCenter] = true;
        }
    }

    function registerMemeverse(
        string memory name, 
        string memory symbol,
        string memory uri,
        uint8 decimals,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint256 maxFund,
        uint32[] calldata omnichainIds,
        address creator
    ) external override returns (address memecoin, address liquidProof) {
        require(callers[msg.sender], PermissionDenied());

        (memecoin, liquidProof) = _deployMemecoinAndLiquidProof(name, symbol, decimals, uniqueId, creator);
        IMemeverseLauncher(MEMEVERSE_LAUNCHER).registerOmnichainMemeverse(
            name, symbol, uri, memecoin, liquidProof, uniqueId, 
            durationDays, lockupDays, maxFund, omnichainIds
        );

        _lzConfigure(memecoin, liquidProof, omnichainIds);

    }

    /// @dev Deploy Memecoin and LiquidProof on the current chain simultaneously
    function _deployMemecoinAndLiquidProof(
        string memory name, 
        string memory symbol,
        uint8 decimals, 
        uint256 uniqueId,
        address creator
    ) internal returns (address memecoin, address liquidProof) {
        bytes memory constructorArgs = abi.encode(name, symbol, decimals, MEMEVERSE_LAUNCHER, LOCAL_LZ_ENDPOINT, address(this));
        bytes memory initCode = abi.encodePacked(type(Memecoin).creationCode, constructorArgs);
        bytes32 salt = keccak256(abi.encodePacked(symbol, creator, uniqueId, "Memeverse"));
        memecoin = CREATE3.deploy(salt, initCode, msg.value);

        constructorArgs = abi.encode(
            string(abi.encodePacked(name, " Liquid")), 
            string(abi.encodePacked(symbol, " LIQUID")), 
            18, 
            memecoin, 
            MEMEVERSE_LAUNCHER, 
            LOCAL_LZ_ENDPOINT,
            address(this)
        );
        initCode = abi.encodePacked(type(MemeLiquidProof).creationCode, constructorArgs);
        liquidProof = CREATE3.deploy(salt, initCode, msg.value);
    }

    /// @dev Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
    function _lzConfigure(address memecoin, address liquidProof, uint32[] memory omnichainIds) internal {
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            if (omnichainIds[i] == block.chainid) continue;

            IOAppCore(memecoin).setPeer(endpointIds[omnichainIds[i]], bytes32(uint256(uint160(memecoin))));
            IOAppCore(liquidProof).setPeer(endpointIds[omnichainIds[i]], bytes32(uint256(uint160(liquidProof))));
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setSendLibrary(memecoin, endpointIds[omnichainIds[i]], LOCAL_SEND_LIBRARY);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setReceiveLibrary(memecoin, endpointIds[omnichainIds[i]], LOCAL_RECEIVE_LIBRARY, 0);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setSendLibrary(liquidProof, endpointIds[omnichainIds[i]], LOCAL_SEND_LIBRARY);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setReceiveLibrary(liquidProof, endpointIds[omnichainIds[i]], LOCAL_RECEIVE_LIBRARY, 0);
        }

        bytes memory defaultExecutorConfig = abi.encode(
            ExecutorConfig({
                maxMessageSize: 0,
                executor: address(0)
            })
        );

        bytes memory defaultUlnConfig = abi.encode(
            UlnConfig({
                confirmations: 0,
                requiredDVNCount: 0,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: new address[](0),
                optionalDVNs: new address[](0)
            })
        );

        SetConfigParam[] memory sendConfigParams = new SetConfigParam[](0);
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            if (omnichainIds[i] == block.chainid) continue;
            append(sendConfigParams, SetConfigParam({
                eid: endpointIds[omnichainIds[i]],
                configType: 1,
                config: defaultExecutorConfig
            }));
            append(sendConfigParams, SetConfigParam({
                eid: endpointIds[omnichainIds[i]],
                configType: 2,
                config: defaultUlnConfig
            }));
        }
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(memecoin, LOCAL_SEND_LIBRARY, sendConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(liquidProof, LOCAL_SEND_LIBRARY, sendConfigParams);

        SetConfigParam[] memory receiveConfigParams = new SetConfigParam[](0);
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            if (omnichainIds[i] == block.chainid) continue;
            append(receiveConfigParams, SetConfigParam({
                eid: endpointIds[omnichainIds[i]],
                configType: 2,
                config: defaultUlnConfig
            }));
        }
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(memecoin, LOCAL_RECEIVE_LIBRARY, receiveConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(liquidProof, LOCAL_RECEIVE_LIBRARY, receiveConfigParams);
    }

    /*///////////////////////////////////////////////////////////////
                               LAYERZERO-RELATED
    //////////////////////////////////////////////////////////////*/

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external override onlyOwner {
        for (uint256 i = 0; i < endpoints.length; i++) {
            endpointIds[endpoints[i].chainId] = endpoints[i].endpointId;

            emit SetLzEndpointId(endpoints[i].chainId, endpoints[i].endpointId);
        }
    }

    function setLzExecutor(address executor) external override onlyOwner {
        require(executor != address(0), ZeroAddress());
        localLzExecutor = executor;

        emit SetLzExecutor(executor);
    }
}
