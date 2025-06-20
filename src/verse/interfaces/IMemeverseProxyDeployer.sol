//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev Interface for the Memeverse Proxy Contract Deployer.
 */
interface IMemeverseProxyDeployer {
    function predictYieldVaultAddress(uint256 uniqueId) external view returns (address);

    function computeGovernorAndIncentivizerAddress(uint256 uniqueId) external view returns (address governor, address incentivizer);
    
    function deployMemecoin(uint256 uniqueId) external returns (address memecoin);

    function deployPOL(uint256 uniqueId) external returns (address pol);

    function deployYieldVault(uint256 uniqueId) external returns (address yieldVault);

    function deployGovernorAndIncentivizer(
        string calldata memecoinName,
        address UPT,
        address memecoin,
        address pol,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external returns (address governor, address incentivizer);

    function setQuorumNumerator(uint256 quorumNumerator) external;

    event DeployMemecoin(uint256 indexed uniqueId, address memecoin);

    event DeployPOL(uint256 indexed uniqueId, address pol);

    event DeployYieldVault(uint256 indexed uniqueId, address yieldVault);

    event DeployGovernorAndIncentivizer(uint256 indexed uniqueId, address governor, address incentivizer);

    event SetQuorumNumerator(uint256 quorumNumerator);

    error ZeroInput();
    
    error PermissionDenied();
}