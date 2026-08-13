// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IGenesisCreditFactory} from "../../../src/credit/interfaces/IGenesisCreditFactory.sol";

/// @title MockGenesisCreditFactory
/// @notice Minimal `IGenesisCreditFactory` stub for POLendUpgradeable unit tests. Test code wires
///         (uAsset -> credit) pairs directly via `setCreditOf`, avoiding any reliance on the
///         real factory/clone deployment path (those are exercised in dedicated factory tests).
contract MockGenesisCreditFactory is IGenesisCreditFactory {
    mapping(address => address) internal _credits;

    /// @notice Register a credit token for the given uAsset.
    /// @dev Tests-only setter; bypasses the deterministic clone deployment used in production.
    function setCreditOf(address uAsset, address credit) external {
        _credits[uAsset] = credit;
    }

    /// @inheritdoc IGenesisCreditFactory
    function creditOf(address uAsset) external view returns (address) {
        return _credits[uAsset];
    }

    /// @inheritdoc IGenesisCreditFactory
    function predictCredit(address uAsset) external view returns (address) {
        return _credits[uAsset];
    }

    /// @inheritdoc IGenesisCreditFactory
    function deployCredit(address, string calldata, string calldata, address) external pure returns (address) {
        revert("not implemented");
    }
}
