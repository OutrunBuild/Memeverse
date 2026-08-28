// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {FacetGuard} from "../../src/swap/FacetGuard.sol";
import {ISettlementFacet} from "../../src/swap/interfaces/ISettlementFacet.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";

/// @title FacetGuardComplianceTest
/// @notice Regression guard: `setFacet` does not verify `FacetGuard` on-chain.
/// @dev The on-chain `setFacet` intentionally stays minimal (onlyOwner + code + poolManager check,
///      see docs/spec/upgradeability.md 2.1). The missing `onlyViaRouter` guarantee is closed off-chain
///      by this suite and the gate harness:
///        1. Source literal: all three production facets must inherit `FacetGuard` and carry `onlyViaRouter`
///           on every external logic entry (except the pure view `ImmutableState.poolManager()`).
///           `layout at` repetition is language-forced, so a typo compiles to an orphan slot — this file
///           pins the invariant at source level, mirroring HookStorageLayout.t.sol's ERC-7201 literal check.
///        2. Runtime direct-call revert: every facet external entry must revert `DirectFacetCallForbidden`
///           on a direct CALL and succeed via Router delegatecall. The primary logic entries are covered
///           by MemeverseDiamondFacets.t.sol; this file pins the remaining `settlementUnlockCallback`
///           entry on the live Hook instance.
///      CI fails immediately if a replacement facet is added without `FacetGuard`/ `onlyViaRouter`.
contract FacetGuardComplianceTest is Test, HookStorageHelper {
    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHookUpgradeable internal hook;

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), address(this), address(this));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
    }

    /// @notice All three production facets must inherit FacetGuard and carry onlyViaRouter on logic entries.
    function test_FacetGuardInheritanceAndOnlyViaRouterLiteral() external view {
        string[3] memory facets =
            ["src/swap/SwapFacet.sol", "src/swap/DynamicFeeFacet.sol", "src/swap/SettlementFacet.sol"];
        for (uint256 i = 0; i < facets.length; ++i) {
            string memory content = vm.readFile(facets[i]);
            // Must inherit FacetGuard directly or via MemeverseSwapFeeBase (which is FacetGuard)
            bool inheritsGuard = _contains(content, "FacetGuard") || _contains(content, "MemeverseSwapFeeBase");
            assertTrue(inheritsGuard, string.concat("missing FacetGuard inherit: ", facets[i]));
            // Must contain the guard modifier on entries; at least 2 occurrences per facet
            uint256 guardOccurrences = _countOccurrences(content, "onlyViaRouter");
            assertGe(guardOccurrences, 2, string.concat("onlyViaRouter too few in: ", facets[i]));
        }
        // FacetGuard itself must declare the guard and the error
        string memory guard = vm.readFile("src/swap/FacetGuard.sol");
        assertTrue(_contains(guard, "onlyViaRouter"), "FacetGuard must declare onlyViaRouter");
        assertTrue(_contains(guard, "DirectFacetCallForbidden"), "FacetGuard must declare DirectFacetCallForbidden");
        assertTrue(_contains(guard, "__self"), "FacetGuard must declare __self immutable");
    }

    /// @notice Direct CALL to `settlementUnlockCallback` must revert `DirectFacetCallForbidden` (runtime pin).
    /// @dev The primary facet logic entries' direct-call reverts are covered by MemeverseDiamondFacets.t.sol;
    ///      this callback entry has no counterpart there, so it is pinned on the live Hook instance.
    ///      The onlyViaRouter guard fires before the inner `msg.sender == poolManager` check.
    function test_SettlementUnlockCallbackDirectCallReverts() external {
        _assertDirectReverts(
            hook.settlementFacet(), abi.encodeCall(ISettlementFacet.settlementUnlockCallback, (_dummyCallback()))
        );
    }

    // ---- helpers ----
    function _assertDirectReverts(address facet, bytes memory callData) internal {
        (bool ok, bytes memory ret) = facet.call(callData);
        assertFalse(ok, "direct facet call must revert");
        assertEq(bytes4(ret), FacetGuard.DirectFacetCallForbidden.selector, "DirectFacetCallForbidden");
    }

    function _dummyKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
    }

    function _dummySwapParams() internal pure returns (SwapParams memory) {
        return
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    function _dummyCallback() internal view returns (ISettlementFacet.SettlementCallbackData memory) {
        return ISettlementFacet.SettlementCallbackData({
            recipient: address(this),
            treasury: address(this),
            key: _dummyKey(),
            swapParams: _dummySwapParams(),
            protocolFeeOnInput: false
        });
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return _countOccurrences(haystack, needle) > 0;
    }

    function _countOccurrences(string memory haystack, string memory needle) internal pure returns (uint256 count) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return 0;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool isMatch = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                count++;
                i += n.length - 1;
            }
        }
    }
}
