// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IMemeverseProxyDeployer } from "./interfaces/IMemeverseProxyDeployer.sol";
import { IMemecoinDaoGovernor } from "../governance/interfaces/IMemecoinDaoGovernor.sol";

/**
 * @title MemeverseProxyDeployer Contract
 */ 
contract MemeverseProxyDeployer is IMemeverseProxyDeployer, Ownable {
    using Clones for address;

    address public immutable memeverseLauncher;
    address public immutable memecoinImplementation;
    address public immutable polImplementation;
    address public immutable vaultImplementation;
    address public immutable governorImplementation;

    uint256 public quorumNumerator;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    constructor(
        address _owner,
        address _memeverseLauncher,
        address _memecoinImplementation,
        address _polImplementation,
        address _vaultImplementation,
        address _governorImplementation,
        uint256 _quorumNumerator
    ) Ownable(_owner) {
        memeverseLauncher = _memeverseLauncher;
        memecoinImplementation = _memecoinImplementation;
        polImplementation = _polImplementation;
        vaultImplementation = _vaultImplementation;
        governorImplementation = _governorImplementation;
        quorumNumerator = _quorumNumerator;
    }

    /**
     * @dev Predict memecoin yield vault address
     */
    function predictYieldVaultAddress(uint256 uniqueId) external view override returns (address) {
        return vaultImplementation.predictDeterministicAddress(keccak256(abi.encode(uniqueId)));
    }

    /**
     * @dev Compute memecoin DAO governor contract address
     */
    function computeDAOGovernorAddress(
        string calldata memecoinName,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external view override returns (address) {
        bytes memory proxyBytecode = _computeProxyBytecode(memecoinName, yieldVault, proposalThreshold);

        return Create2.computeAddress(keccak256(abi.encode(uniqueId)), keccak256(proxyBytecode));
    }

    /**
     * @dev Deploy memecoin proxy contract
     */
    function deployMemecoin(uint256 uniqueId) external onlyMemeverseLauncher override returns (address memecoin) {
        memecoin = memecoinImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployMemecoin(uniqueId, memecoin);
    }

    /**
     * @dev Deploy POL proxy contract
     */
    function deployPOL(uint256 uniqueId) external onlyMemeverseLauncher override returns (address pol) {
        pol = polImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployPOL(uniqueId, pol);
    }

    /**
     * @dev Deploy memecoin yield vault proxy contract
     */
    function deployYieldVault(uint256 uniqueId) external onlyMemeverseLauncher override returns (address yieldVault) {
        yieldVault = vaultImplementation.cloneDeterministic(keccak256(abi.encode(uniqueId)));

        emit DeployYieldVault(uniqueId, yieldVault);
    }

    /**
     * @dev Deploy memecoin DAO governor proxy contract
     * @param memecoinName - The name of memecoin
     * @param yieldVault - The yield vault of memecoin
     * @param proposalThreshold - Proposal Threshold
     */
    function deployDAOGovernor(
        string calldata memecoinName,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external onlyMemeverseLauncher override returns (address daoGovernor) {
        bytes memory proxyBytecode = _computeProxyBytecode(memecoinName, yieldVault, proposalThreshold);

        daoGovernor = Create2.deploy(0, keccak256(abi.encode(uniqueId)), proxyBytecode);

        emit DeployDAOGovernor(uniqueId, daoGovernor);
    }

    function _computeProxyBytecode(string memory memecoinName, address yieldVault, uint256 proposalThreshold) internal view returns (bytes memory proxyBytecode) {
        bytes memory initData = abi.encodeWithSelector(
            IMemecoinDaoGovernor.initialize.selector,
            string(abi.encodePacked(memecoinName, " DAO")),
            IVotes(yieldVault),    // voting token
            1 days,                 // voting delay
            1 weeks,                // voting period
            proposalThreshold,     // proposal threshold
            quorumNumerator         // quorum (quorumNumerator%)
        );
        proxyBytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(governorImplementation, initData)
        );
    }

    /**
     * @dev Set quorumNumerator
     * @param _quorumNumerator - quorumNumerator
     */
    function setQuorumNumerator(uint256 _quorumNumerator) external override onlyOwner {
        require(_quorumNumerator != 0, ZeroInput());

        quorumNumerator = _quorumNumerator;

        emit SetQuorumNumerator(_quorumNumerator);
    }
}
