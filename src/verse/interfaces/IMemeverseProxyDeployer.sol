//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev Interface for the Memeverse Proxy Contract Deployer.
 */
interface IMemeverseProxyDeployer {
    function predictYieldVaultAddress(uint256 uniqueId) external view returns (address);

    function computeDAOGovernorAddress(
        string calldata memecoinName,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external view returns (address);
    
    function deployMemecoin(uint256 uniqueId) external returns (address memecoin);

    function deployPOL(uint256 uniqueId) external returns (address pol);

    function deployYieldVault(uint256 uniqueId) external returns (address yieldVault);

    function deployDAOGovernor(
        string calldata memecoinName,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external returns (address daoGovernor);

    function setQuorumNumerator(uint256 quorumNumerator) external;

    event DeployMemecoin(uint256 indexed uniqueId, address memecoin);

    event DeployPOL(uint256 indexed uniqueId, address pol);

    event DeployYieldVault(uint256 indexed uniqueId, address yieldVault);

    event DeployDAOGovernor(uint256 indexed uniqueId, address daoGovernor);

    event SetQuorumNumerator(uint256 quorumNumerator);

    error ZeroInput();
    
    error PermissionDenied();
}