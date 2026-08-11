// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Interface for the Memeverse Proxy Contract Deployer.
 */
interface IMemeverseProxyDeployer {
    /**
     * @notice Predicts the deterministic yield vault clone address for a verse id.
     * @dev Uses the deployer's CREATE2 scheme without mutating state.
     * @param uniqueId Verse unique identifier.
     * @return Predicted yield vault clone address.
     */
    function predictYieldVaultAddress(uint256 uniqueId) external view returns (address);

    /**
     * @notice Computes deterministic governor and incentivizer addresses for a verse id.
     * @dev Pure address derivation helper used before deploying governance components.
     * @param uniqueId Verse unique identifier.
     * @return governor Predicted governor proxy address.
     * @return incentivizer Predicted incentivizer proxy address.
     */
    function computeGovernorAndIncentivizerAddress(uint256 uniqueId)
        external
        view
        returns (address governor, address incentivizer);

    /**
     * @notice Deploys the memecoin clone for a verse.
     * @dev Reverts if the verse id is invalid or already consumed by deployment flow.
     * @param uniqueId Verse unique identifier.
     * @return memecoin Deployed memecoin clone address.
     */
    function deployMemecoin(uint256 uniqueId) external returns (address memecoin);

    /**
     * @notice Deploys the POL clone for a verse.
     * @dev Reverts if required dependencies for the verse are not ready.
     * @param uniqueId Verse unique identifier.
     * @return pol Deployed POL clone address.
     */
    function deployPOL(uint256 uniqueId) external returns (address pol);

    /**
     * @notice Deploys the yield vault clone for a verse.
     * @dev Deployment follows deterministic clone salts keyed by verse id.
     * @param uniqueId Verse unique identifier.
     * @return yieldVault Deployed yield vault clone address.
     */
    function deployYieldVault(uint256 uniqueId) external returns (address yieldVault);

    /**
     * @notice Deploys governor and incentivizer proxies for a verse.
     * @dev Wires token addresses and governance thresholds into deployment payload.
     * @param memecoinName Governance display name derived from memecoin metadata.
     * @param uAsset Verse quote asset address.
     * @param memecoin Deployed memecoin clone address.
     * @param pol Deployed POL clone address.
     * @param yieldVault Deployed yield vault clone address.
     * @param uniqueId Verse unique identifier.
     * @param proposalThreshold Governor proposal threshold.
     * @return governor Deployed governor proxy address.
     * @return incentivizer Deployed incentivizer proxy address.
     */
    function deployGovernorAndIncentivizer(
        string calldata memecoinName,
        address uAsset,
        address memecoin,
        address pol,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external returns (address governor, address incentivizer);

    /**
     * @notice Returns the quorum numerator used for governor deployments.
     * @return Current quorum numerator value.
     */
    function quorumNumerator() external view returns (uint256);

    /**
     * @notice Updates quorum numerator used for subsequent governor deployments.
     * @dev Affects deployment-time governor config, not already deployed instances.
     * @param quorumNumerator New quorum numerator value.
     */
    function setQuorumNumerator(uint256 quorumNumerator) external;

    /**
     * @notice Returns the min quorum numerator used to calculate the quorum floor.
     * @return Current min quorum numerator value (percentage denominator = 100).
     */
    function minQuorumNumerator() external view returns (uint256);

    /**
     * @notice Returns the bootstrap period applied to new governor deployments.
     * @return Bootstrap period in seconds.
     */
    function bootstrapPeriod() external view returns (uint256);

    /**
     * @notice Updates min quorum numerator for subsequent governor deployments.
     * @param minQuorumNumerator New min quorum numerator value.
     */
    function setMinQuorumNumerator(uint256 minQuorumNumerator) external;

    /**
     * @notice Updates bootstrap period for subsequent governor deployments.
     * @param bootstrapPeriod New bootstrap period in seconds.
     */
    function setBootstrapPeriod(uint256 bootstrapPeriod) external;

    /**
     * @notice Returns the max treasury spend ratio used for governor deployments.
     * @return Current max treasury spend ratio (basis points, 1000 = 10%).
     */
    function maxTreasurySpendRatio() external view returns (uint256);

    /**
     * @notice Returns the upgrade supermajority ratio used for governor deployments.
     * @return Current upgrade supermajority ratio (basis points, 6000 = 60%).
     */
    function upgradeSupermajorityRatio() external view returns (uint256);

    /**
     * @notice Updates max treasury spend ratio for subsequent governor deployments.
     * @param maxTreasurySpendRatio New max treasury spend ratio value.
     */
    function setMaxTreasurySpendRatio(uint256 maxTreasurySpendRatio) external;

    /**
     * @notice Updates upgrade supermajority ratio for subsequent governor deployments.
     * @param upgradeSupermajorityRatio New upgrade supermajority ratio value.
     */
    function setUpgradeSupermajorityRatio(uint256 upgradeSupermajorityRatio) external;

    event DeployMemecoin(uint256 indexed uniqueId, address memecoin);

    event DeployPOL(uint256 indexed uniqueId, address pol);

    event DeployYieldVault(uint256 indexed uniqueId, address yieldVault);

    event DeployGovernorAndIncentivizer(uint256 indexed uniqueId, address governor, address incentivizer);

    event SetQuorumNumerator(uint256 quorumNumerator);

    event SetMinQuorumNumerator(uint256 minQuorumNumerator);
    event SetBootstrapPeriod(uint256 bootstrapPeriod);
    event SetMaxTreasurySpendRatio(uint256 maxTreasurySpendRatio);
    event SetUpgradeSupermajorityRatio(uint256 upgradeSupermajorityRatio);

    error ZeroInput();

    error PermissionDenied();
}
