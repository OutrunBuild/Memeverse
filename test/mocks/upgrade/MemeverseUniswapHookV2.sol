// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OutrunOwnableUpgradeable} from "../../../src/common/access/OutrunOwnableUpgradeable.sol";

/**
 * @title Memeverse Uniswap Hook V2 (UUPS upgrade-target shell)
 * @notice UUPS upgrade-target shell used by the hook proxy upgrade tests.
 * @dev Carries `UUPSUpgradeable` + `OutrunOwnableUpgradeable` so the proxy can keep upgrading after the
 *      V1 -> V2 jump: without UUPSUpgradeable on the new implementation, the proxy would permanently lock.
 *
 *      Does NOT inherit `MemeverseUniswapHookUpgradeable`: Solidity Error 8894 forbids inheriting any contract that
 *      declares `layout at`, and V1 uses `layout at erc7201("outrun.storage.MemeverseUniswapHook")`.
 *      Storage-layout compatibility after the V1 -> V2 upgrade is verified through raw slot reads
 *      (`vm.load` against the V1 ERC7201 namespace) in the upgrade-preservation test, so V2 only needs the
 *      upgrade authorization path (`UUPSUpgradeable._authorizeUpgrade` reading the same
 *      `outrun.storage.Ownable` owner slot V1 uses) and the `version()` marker.
 *
 *      `version()` is new (V1 does not declare it), so it is not an override.
 */
contract MemeverseUniswapHookV2 is OutrunOwnableUpgradeable, UUPSUpgradeable {
    /// @notice PoolManager constructor argument kept for upgrade tests that document operator-side compatibility.
    IPoolManager public immutable poolManager;

    /// @param poolManager_ Bound to the immutable field; no runtime storage effect.
    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        // Defense-in-depth, mirrors V1: lock the implementation's initializer so the V2 impl cannot be
        // initialized directly (only the proxy's initializer runs).
        _disableInitializers();
    }

    /// @notice Returns the upgrade-target version marker.
    function version() external pure returns (uint256) {
        return 2;
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Mirrors V1's upgrade gate so the post-upgrade proxy remains owner-gated and upgradeable.
    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
