// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import { Memecoin } from "../../token/Memecoin.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";

/**
 * @title Token deployer
 */
abstract contract TokenDeployer is ITokenDeployer, Ownable {
    using Clones for address;

    address public immutable LOCAL_LZ_ENDPOINT;
    address public memeverseRegistrar;
    address public implementation;

    mapping(uint32 chainId => uint32) public endpointIds;

    constructor(
        address _owner, 
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _implementation
    ) Ownable(_owner) {
        LOCAL_LZ_ENDPOINT = _localLzEndpoint;
        memeverseRegistrar = _memeverseRegistrar;
        implementation = _implementation;
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
        address memecoinDeployer,
        uint32[] calldata omnichainIds
    ) external override returns (address token) {
        require(msg.sender == memeverseRegistrar, PermissionDenied());
        
        token = _deployToken(name, symbol, uniqueId, creator, memecoin, memecoinDeployer);
        _lzConfigure(token, omnichainIds);
    }

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            endpointIds[pair.chainId] = pair.endpointId;
        }
    }

    function setMemeverseRegistrar(address _memeverseRegistrar) external override onlyOwner {
        require(_memeverseRegistrar != address(0), ZeroAddress());

        memeverseRegistrar = _memeverseRegistrar;
    }

    function setImplementation(address _implementation) external override onlyOwner {
        require(_implementation != address(0), ZeroAddress());

        implementation = _implementation;
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
        address memecoin,
        address memeverseLauncher
    ) internal virtual returns (address token);
}
