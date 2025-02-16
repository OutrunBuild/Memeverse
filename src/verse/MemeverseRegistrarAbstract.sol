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
    address public memecoinDeployer;

    mapping(uint32 chainId => uint32) public endpointIds;
    mapping(address UPT => address memeverseLauncher) public uptToLauncher;
    mapping(address memeverseLauncher => address UPT) public launcherToUPT;

    modifier onlyMemeverseLauncher() {
        require(launcherToUPT[msg.sender] != address(0), PermissionDenied());
        _;
    }

    constructor(
        address _owner,
        address _memecoinDeployer
    ) Ownable(_owner) {
        memecoinDeployer = _memecoinDeployer;
    }

    function getEndpointId(uint32 chainId) external view override returns (uint32 endpointId) {
        endpointId = endpointIds[chainId];
    }

    function setLzEndpointIds(LzEndpointIdPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            LzEndpointIdPair calldata pair = pairs[i];
            if (pair.chainId == 0 || pair.endpointId == 0) continue;

            endpointIds[pair.chainId] = pair.endpointId;
        }
    }

    function setMemecoinDeployer(address _memecoinDeployer) external override onlyOwner {
        require(_memecoinDeployer != address(0), ZeroAddress());

        memecoinDeployer = _memecoinDeployer;
    }

    function setUPTLauncher(UPTLauncherPair[] calldata pairs) external override onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            UPTLauncherPair calldata pair = pairs[i];
            if (pair.upt == address(0) || pair.memeverseLauncher == address(0)) continue;

            uptToLauncher[pair.upt] = pair.memeverseLauncher;
            launcherToUPT[pair.memeverseLauncher] = pair.upt;
        }
    }

    function registerAtCenter(
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        uint128 value
    ) virtual external payable;

    function cancelRegistration(
        uint256 uniqueId, 
        IMemeverseRegistrationCenter.RegistrationParam calldata param, 
        address lzRefundAddress
    ) virtual external payable;

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
        bytes32 peer = bytes32(uint256(uint160(memecoin)));
        uint32 currentChainId = uint32(block.chainid);

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == currentChainId) continue;

            uint32 endpointId = endpointIds[omnichainId];
            require(endpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(endpointId, peer);
        }
    }
}
