//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev Interface for the Memeverse Proxy Contract Deployer.
 */
interface IMemeverseProxyDeployer {
    function predictYieldVaultAddress(bytes32 salt) external view returns (address);

    function computeDAOGovernorAddress(
        string calldata memecoinName,
        address yieldVault,
        bytes32 salt
    ) external view returns (address);
    
    function deployMemecoin(bytes32 salt) external returns (address memecoin);

    function deployPOL(bytes32 salt) external returns (address pol);

    function deployYieldVault(bytes32 salt) external returns (address yieldVault);

    function deployDAOGovernor(
        string calldata memecoinName,
        address yieldVault,
        bytes32 salt
    ) external returns (address daoGovernor);


    function setProposalThreshold(uint256 proposalThreshold) external;

    function setQuorumNumerator(uint256 quorumNumerator) external;


    event DeployMemecoin(address memecoin);

    event DeployPOL(address pol);

    event DeployYieldVault(address yieldVault);

    event DeployDAOGovernor(address daoGovernor);

    event SetProposalThreshold(uint256 proposalThreshold);

    event SetQuorumNumerator(uint256 quorumNumerator);

    error ZeroInput();
    error PermissionDenied();
}