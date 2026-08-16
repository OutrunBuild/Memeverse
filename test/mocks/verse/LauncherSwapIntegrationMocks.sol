// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {
    MockIntegrationLiquidProof,
    MockIntegrationMemecoin,
    MockPOLendForPreorderIntegration
} from "./LauncherPreorderIntegrationMocks.sol";

/// @notice Yield vault stand-in for the swap-launcher integration test.
/// @dev Captures the initialize arguments verbatim so the launcher can treat it as a
///      configured yield vault without a real vault implementation.
contract MockLauncherSwapIntegrationYieldVault {
    string public name;
    string public symbol;
    address public asset;
    uint256 public verseId;
    uint256 public virtualAssets;

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address asset_,
        uint256 verseId_,
        uint256 virtualAssets_
    ) external {
        name = name_;
        symbol = symbol_;
        asset = asset_;
        verseId = verseId_;
        virtualAssets = virtualAssets_;
    }
}

/// @notice POLendUpgradeable swap-path override that turns settlement-dust hooks into no-ops.
/// @dev Inherits the preorder integration base so the rest of the launcher-facing POLendUpgradeable
///      surface stays identical to the preorder test, only overriding the dust flow.
contract MockPOLendForSwapIntegration is MockPOLendForPreorderIntegration {
    function settlementDustStates(address) external pure override returns (uint128 reserve, uint128 maxReserve) {
        return (0, type(uint128).max);
    }

    function fundSettlementDustReserve(address, uint256) external override {}
}

/// @notice Proxy deployer stand-in for the swap-launcher integration test.
/// @dev Adds a yield-vault deployment path (and a quorum numerator) on top of the
///      preorder deployer surface, since the swap test drives the full launch lifecycle.
contract MockLauncherSwapIntegrationProxyDeployer {
    address internal immutable predictedGovernor;
    address internal immutable predictedIncentivizer;
    uint256 public lastProposalThreshold;
    uint256 public lastMemecoinSupply;

    constructor(address _predictedGovernor, address _predictedIncentivizer) {
        predictedGovernor = _predictedGovernor;
        predictedIncentivizer = _predictedIncentivizer;
    }

    function deployMemecoin(uint256 uniqueId) external returns (address memecoin) {
        uniqueId;
        memecoin = address(new MockIntegrationMemecoin());
    }

    function deployPOL(uint256 uniqueId) external returns (address pol) {
        uniqueId;
        pol = address(new MockIntegrationLiquidProof());
    }

    function deployYieldVault(uint256 uniqueId) external returns (address yieldVault) {
        uniqueId;
        yieldVault = address(new MockLauncherSwapIntegrationYieldVault());
    }

    function deployGovernorAndIncentivizer(
        string calldata memecoinName,
        address uAsset,
        address memecoin,
        address pol,
        address yieldVault,
        uint256 uniqueId,
        uint256 proposalThreshold
    ) external returns (address governor, address incentivizer) {
        memecoinName;
        uAsset;
        pol;
        yieldVault;
        uniqueId;
        // Record the governance threshold inputs so tests can anchor the launcher's /50 formula (F-101).
        lastProposalThreshold = proposalThreshold;
        lastMemecoinSupply = MockIntegrationMemecoin(memecoin).totalSupply();
        return (predictedGovernor, predictedIncentivizer);
    }

    function predictYieldVaultAddress(uint256 uniqueId) external pure returns (address yieldVault) {
        uniqueId;
        return address(0);
    }

    function computeGovernorAndIncentivizerAddress(uint256 uniqueId)
        external
        view
        returns (address governor, address incentivizer)
    {
        uniqueId;
        return (predictedGovernor, predictedIncentivizer);
    }

    function quorumNumerator() external pure returns (uint256) {
        return 25;
    }
}
