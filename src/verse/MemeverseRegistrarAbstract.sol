// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import { IMemecoinDeployer } from "../token/deployer/interfaces/IMemecoinDeployer.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemeverseRegistrar, IMemeverseRegistrationCenter } from "./interfaces/IMemeverseRegistrar.sol";

/**
 * @title MemeverseRegistrar Abstract Contract
 */ 
abstract contract MemeverseRegistrarAbstract is IMemeverseRegistrar, Ownable {
    address public localEndpoint;
    address public memecoinDeployer;

    mapping(uint32 chainId => uint32) public endpointIds;
    mapping(address UPT => address memeverseLauncher) public uptToLauncher;
    mapping(address memeverseLauncher => address UPT) public launcherToUPT;

    modifier onlyMemeverseLauncher() {
        require(launcherToUPT[msg.sender] != address(0), PermissionDenied());
        _;
    }

    /**
     * @notice Constructor to initialize the MemeverseRegistrar.
     * @param _owner The owner of the contract.
     * @param _memecoinDeployer The memecoin deployer to set.
     * @param _localEndpoint The local endpoint to set.
     */
    constructor(
        address _owner,
        address _localEndpoint,
        address _memecoinDeployer
    ) Ownable(_owner) {
        memecoinDeployer = _memecoinDeployer;
        localEndpoint = _localEndpoint;
    }

    /**
     * @notice Get the endpoint id for a given chain id.
     * @param chainId The chain id to get the endpoint id for.
     * @return endpointId The endpoint id for the given chain id.
     */
    function getEndpointId(uint32 chainId) external view override returns (uint32 endpointId) {
        endpointId = endpointIds[chainId];
    }

    /**
     * @notice Set the local endpoint.
     * @param _localEndpoint The local endpoint to set.
     */
    function setLocalEndpoint(address _localEndpoint) external override onlyOwner {
        require(_localEndpoint != address(0), ZeroAddress());

        localEndpoint = _localEndpoint;

        emit SetLocalEndpoint(_localEndpoint);
    }

    /**
     * @notice Set the memecoin deployer.
     * @param _memecoinDeployer The memecoin deployer to set.
     */
    function setMemecoinDeployer(address _memecoinDeployer) external override onlyOwner {
        require(_memecoinDeployer != address(0), ZeroAddress());

        memecoinDeployer = _memecoinDeployer;

        emit SetMemecoinDeployer(_memecoinDeployer);
    }

    /**
     * @notice Set the endpoint ids for the given chain ids.
     * @param pairs The pairs of chain ids and endpoint ids to set.
     */
    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            endpointIds[pair.chainId] = pair.endpointId;
        }

        emit SetLzEndpointIds(pairs);
    }

    /**
     * @notice Set the UPT launcher for the given pairs.
     * @param pairs The pairs of UPT and memeverse launcher to set.
     */
    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            UPTLauncherPair calldata pair = pairs[i];
            if (pair.upt == address(0) || pair.memeverseLauncher == address(0)) continue;

            uptToLauncher[pair.upt] = pair.memeverseLauncher;
            launcherToUPT[pair.memeverseLauncher] = pair.upt;
        }

        emit SetUPTLauncher(pairs);
    }

    /**
     * @notice Register a memeverse.
     * @param param The memeverse parameters.
     * @return memecoin The address of the memecoin deployed.
     */
    function _registerMemeverse(MemeverseParam memory param) internal returns (address memecoin) {
        string memory name = param.name;
        string memory symbol = param.symbol;
        uint256 uniqueId = param.uniqueId;
        uint32[] memory omnichainIds = param.omnichainIds;
        address memeverseLauncher = uptToLauncher[param.upt];

        // deploy memecoin and configure layerzero
        memecoin = IMemecoinDeployer(memecoinDeployer).deployMemecoin(name, symbol, uniqueId, param.creator, memeverseLauncher);
        _lzConfigure(memecoin, omnichainIds);

        // register
        IMemeverseLauncher(memeverseLauncher).registerMemeverse(
            name, symbol, param.uri, param.creator, memecoin, uniqueId, 
            param.endTime, param.unlockTime, omnichainIds
        );
    }

    /**
     * @dev Memecoin Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
     */
    function _lzConfigure(address memecoin, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = endpointIds[omnichainId];
            require(remoteEndpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
        }
    }
}
