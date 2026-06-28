// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";

/// @notice Dummy contract used as the bootstrap implementation in readiness tests.
/// @dev The script-side readiness check (`_requireContractCode(launchImpl, ...)`) only verifies
/// the address has bytecode. Using a distinct dummy contract — instead of the launcher mock itself —
/// preserves the production invariant that the launcher and its bootstrap sibling are different
/// addresses; if a wiring bug ever made the launcher return its own address as `launchImpl`,
/// the mock would still expose that bug instead of rubber-stamping it.
contract LaunchImplDummy {}

/// @notice Shared launcher mock for script readiness tests.
/// @dev Owns the fields that back the production `getLauncherContracts()` view and the
/// `_requireSwapReady` / `_requireDeploymentReady` paths in `MemeverseScript`. Derived mocks
/// supply their own constructors, fund-metadata storage, and any extra setters their test
/// suite needs.
contract LauncherReadinessMockBase {
    address public owner;
    address internal memeverseRegistrar;
    address internal memeverseProxyDeployer;
    address internal yieldDispatcher;
    address public polend;
    address internal polSplitter;
    address internal memeverseSwapRouter;
    address internal memeverseUniswapHook;
    address internal launchImpl;
    address internal settlementImpl;
    address internal feePreviewReader;
    address internal liquidityImpl;

    constructor() {
        launchImpl = address(new LaunchImplDummy());
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setMemeverseSwapRouter(address router_) external {
        memeverseSwapRouter = router_;
    }

    function setMemeverseUniswapHook(address hook_) external {
        memeverseUniswapHook = hook_;
    }

    function setSettlementImpl(address impl) external {
        settlementImpl = impl;
    }

    function setFeePreviewReader(address reader) external {
        feePreviewReader = reader;
    }

    function setLiquidityImpl(address impl) external {
        liquidityImpl = impl;
    }

    /// @dev Returns a struct literal — every field of `LauncherContracts` is named explicitly.
    /// When the struct gains a new field, the Solidity compiler will reject this initializer and
    /// force the mock to be updated alongside the production struct (preventing a repeat of the
    /// 9985d46 regression where two mocks silently fell out of sync with the struct).
    function getLauncherContracts() external view returns (IMemeverseLauncher.LauncherContracts memory) {
        return IMemeverseLauncher.LauncherContracts({
            localLzEndpoint: address(0),
            lzEndpointRegistry: address(0),
            yieldDispatcher: yieldDispatcher,
            memeverseRegistrar: memeverseRegistrar,
            memeverseProxyDeployer: memeverseProxyDeployer,
            memeverseSwapRouter: memeverseSwapRouter,
            polSplitter: polSplitter,
            launchImpl: launchImpl,
            memeverseUniswapHook: memeverseUniswapHook,
            settlementImpl: settlementImpl,
            feePreviewReader: feePreviewReader,
            liquidityImpl: liquidityImpl
        });
    }
}
