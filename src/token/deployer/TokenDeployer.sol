// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IMessageLibManager, SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

import { Memecoin } from "../../token/Memecoin.sol";
import { LzMessageConfig } from "../../common/LzMessageConfig.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";

/**
 * @title Token deployer
 */
abstract contract TokenDeployer is ITokenDeployer, Ownable, LzMessageConfig {
    address public immutable LOCAL_LZ_ENDPOINT;
    address public immutable MEMEVERSE_LAUNCHER;
    address public immutable MEMEVERSE_REGISTRAR;
    address public immutable LOCAL_SEND_LIBRARY;
    address public immutable LOCAL_RECEIVE_LIBRARY;

    mapping(uint32 chainId => uint32) endpointIds;

    constructor(
        address _owner, 
        address _localLzEndpoint,
        address _memeverseLauncher, 
        address _memeverseRegistrar,
        address _localSendLibrary, 
        address _localReceiveLibrary
    ) Ownable(_owner) {
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        MEMEVERSE_LAUNCHER = _memeverseLauncher;
        MEMEVERSE_REGISTRAR = _memeverseRegistrar;
        LOCAL_SEND_LIBRARY = _localSendLibrary;
        LOCAL_RECEIVE_LIBRARY = _localReceiveLibrary;
    }

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external override onlyOwner {
        for (uint256 i = 0; i < endpoints.length; i++) {
            endpointIds[endpoints[i].chainId] = endpoints[i].endpointId;
        }
    }

    /**
     * @dev Deploy Memecoin and LiquidProof on the current chain
     */ 
    function deployTokenAndConfigure(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        uint32[] calldata omnichainIds
    ) external override returns (address token) {
        require(msg.sender == MEMEVERSE_REGISTRAR, PermissionDenied());
        
        token = _deployToken(name, symbol, uniqueId, creator, memecoin, MEMEVERSE_LAUNCHER, LOCAL_LZ_ENDPOINT);
        _lzConfigure(token, omnichainIds);
    }

    /// @dev Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
    function _lzConfigure(address token, uint32[] memory omnichainIds) internal {
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
        SetConfigParam[] memory receiveConfigParams = new SetConfigParam[](0);
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, InvalidOmnichainId(omnichainId));

            append(sendConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 1,
                config: abi.encode(ExecutorConfig({maxMessageSize: 0, executor: address(0)}))
            }));

            append(sendConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: defaultUlnConfig
            }));

            append(receiveConfigParams, SetConfigParam({
                eid: endpointId,
                configType: 2,
                config: defaultUlnConfig
            }));

            IOAppCore(token).setPeer(endpointId, bytes32(uint256(uint160(token))));
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setSendLibrary(token, endpointId, LOCAL_SEND_LIBRARY);
            IMessageLibManager(LOCAL_LZ_ENDPOINT).setReceiveLibrary(token, endpointId, LOCAL_RECEIVE_LIBRARY, 0);
        }

        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(token, LOCAL_SEND_LIBRARY, sendConfigParams);
        IMessageLibManager(LOCAL_LZ_ENDPOINT).setConfig(token, LOCAL_RECEIVE_LIBRARY, receiveConfigParams);
    }

    function _deployToken(
        string calldata name, 
        string calldata symbol,
        uint256 uniqueId,
        address creator,
        address memecoin,
        address memeverseLauncher,
        address lzEndpoint
    ) internal virtual returns (address token);
}
