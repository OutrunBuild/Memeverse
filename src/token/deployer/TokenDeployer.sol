// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import { Memecoin } from "../../token/Memecoin.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";

/**
 * @title Token deployer
 */
abstract contract TokenDeployer is ITokenDeployer, Ownable {
    address public immutable LOCAL_LZ_ENDPOINT;
    address public memeverseLauncher;
    address public memeverseRegistrar;

    mapping(uint32 chainId => uint32) endpointIds;

    constructor(
        address _owner, 
        address _localLzEndpoint,
        address _memeverseLauncher, 
        address _memeverseRegistrar
    ) Ownable(_owner) {
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        memeverseLauncher = _memeverseLauncher;
        memeverseRegistrar = _memeverseRegistrar;
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
        require(msg.sender == memeverseRegistrar, PermissionDenied());
        
        token = _deployToken(name, symbol, uniqueId, creator, memecoin);
        _lzConfigure(token, omnichainIds);
    }

    function setLzEndpointId(LzEndpointId[] calldata endpoints) external override onlyOwner {
        for (uint256 i = 0; i < endpoints.length; i++) {
            endpointIds[endpoints[i].chainId] = endpoints[i].endpointId;
        }
    }

    function setMemeverseLauncher(address _memeverseLauncher) external override onlyOwner {
        require(_memeverseLauncher != address(0), ZeroAddress());
        
        memeverseLauncher = _memeverseLauncher;
    }

    function setMemeverseRegistrar(address _memeverseRegistrar) external override onlyOwner {
        require(_memeverseRegistrar != address(0), ZeroAddress());

        memeverseRegistrar = _memeverseRegistrar;
    }

    /// @dev Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
    function _lzConfigure(address token, uint32[] memory omnichainIds) internal {
        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == block.chainid) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(token).setPeer(endpointId, bytes32(uint256(uint160(token))));
        }
    }

    function _deployToken(
        string memory name, 
        string memory symbol,
        uint256 uniqueId,
        address creator,
        address memecoin
    ) internal virtual returns (address token);
}
