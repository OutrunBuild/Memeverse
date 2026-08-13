// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {MemeverseUniswapHookUpgradeable} from "../../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {HookStorageHelper} from "./HookStorageHelper.sol";
import {MockPoolManagerForHookLiquidity} from "./HookLiquidityMocks.sol";

/// @notice Proves the facet and Router fixture deploys a real hook proxy at a flag address.
/// @dev Smoke-tests the proxy flags, Router configuration, and three delegatecall facet bindings established
///      by `deployHookAtFlagAddress`.
contract HookStorageHelperSanityTest is Test, HookStorageHelper {
    function test_deployHookAtFlagAddress_proxyCarriesFlagsAndFacets() external {
        IPoolManager manager = IPoolManager(address(new MockPoolManagerForHookLiquidity()));
        address treasury = address(0xBEEF);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);

        assertEq(uint160(hookProxy) & HOOK_FLAG_MASK, HOOK_REQUIRED_FLAGS, "proxy missing flags");

        assertEq(MemeverseUniswapHookUpgradeable(hookProxy).treasury(), treasury, "treasury");
        assertEq(MemeverseUniswapHookUpgradeable(hookProxy).owner(), address(this), "owner");

        // Facet pointers are bound during Router initialization.
        assertGt(MemeverseUniswapHookUpgradeable(hookProxy).swapFacet().code.length, 0, "swap facet bound");
        assertGt(MemeverseUniswapHookUpgradeable(hookProxy).dynamicFeeFacet().code.length, 0, "dynamic fee facet bound");
        assertGt(MemeverseUniswapHookUpgradeable(hookProxy).settlementFacet().code.length, 0, "settlement facet bound");

        Hooks.Permissions memory perms = MemeverseUniswapHookUpgradeable(hookProxy).getHookPermissions();
        assertTrue(perms.beforeInitialize, "beforeInitialize");
        assertTrue(perms.beforeAddLiquidity, "beforeAddLiquidity");
        assertTrue(perms.beforeSwap, "beforeSwap");
        assertTrue(perms.afterSwap, "afterSwap");
        assertTrue(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta");
    }
}
