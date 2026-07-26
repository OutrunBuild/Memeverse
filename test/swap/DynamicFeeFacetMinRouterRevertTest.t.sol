// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";

import {DynamicFeeFacetMinRouter} from "../mocks/swap/DynamicFeeFacetMinRouter.sol";
import {
    RevertingDynamicFeeFacetMock,
    PREPARE_SWAP_FEE_POINT,
    UPDATE_AFTER_SWAP_POINT,
    QUOTE_POINT
} from "../mocks/swap/RevertingDynamicFeeFacetMock.sol";

/// @title DynamicFeeFacetMinRouterRevertTest
/// @notice Verifies minRouter forwarders bubble raw custom-error returndata, including selector and arguments.
/// @dev The forwarders use OZ `Address.functionDelegateCall`, matching the production dynamic-fee delegatecall
///      path and preserving returndata through `LowLevelCall.bubbleRevert`. Each case injects a
///      `RevertingDynamicFeeFacetMock` that reverts with `ForcedDynamicFeeFacetRevert(point)` and asserts the
///      selector and point argument survive the forwarder boundary.
contract DynamicFeeFacetMinRouterRevertTest is Test {
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x1234)));
    address internal constant TRADER_A = address(0xCAFE);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal mgr;

    function setUp() external {
        // The facet fee logic never calls back into PoolManager, and the reverting mock only checks
        // `onlyViaRouter` under delegatecall, so a stub address satisfies both. Mirrors
        // `DynamicFeeFacet.t.sol::setUp`.
        mgr = IPoolManager(makeAddr("manager"));
    }

    /// @notice `prepareSwapFee` forwarder must bubble `ForcedDynamicFeeFacetRevert(1)` selector + arg.
    function test_RevertWhen_PrepareSwapFeeBubblesCustomError() external {
        DynamicFeeFacetMinRouter router = _routerWith(new RevertingDynamicFeeFacetMock(mgr, PREPARE_SWAP_FEE_POINT));

        vm.expectRevert(
            abi.encodeWithSelector(
                RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, PREPARE_SWAP_FEE_POINT
            )
        );
        router.prepareSwapFee(_prepareParams());
    }

    /// @notice `updateAfterSwap` forwarder must bubble `ForcedDynamicFeeFacetRevert(2)` selector + arg.
    function test_RevertWhen_UpdateAfterSwapBubblesCustomError() external {
        DynamicFeeFacetMinRouter router = _routerWith(new RevertingDynamicFeeFacetMock(mgr, UPDATE_AFTER_SWAP_POINT));

        vm.expectRevert(
            abi.encodeWithSelector(
                RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, UPDATE_AFTER_SWAP_POINT
            )
        );
        router.updateAfterSwap(
            IDynamicFeeFacet.UpdateAfterSwapParams({
                poolId: POOL_ID,
                delta: toBalanceDelta(int128(-10 ether), int128(9 ether)),
                trader: TRADER_A,
                preSqrtPriceX96: SQRT_PRICE_1_1,
                postSqrtPriceX96: SQRT_PRICE_1_1
            })
        );
    }

    /// @notice `quote` forwarder must bubble `ForcedDynamicFeeFacetRevert(3)` selector + arg.
    function test_RevertWhen_QuoteBubblesCustomError() external {
        DynamicFeeFacetMinRouter router = _routerWith(new RevertingDynamicFeeFacetMock(mgr, QUOTE_POINT));

        vm.expectRevert(
            abi.encodeWithSelector(RevertingDynamicFeeFacetMock.ForcedDynamicFeeFacetRevert.selector, QUOTE_POINT)
        );
        router.quote(_prepareParams());
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Wraps a reverting facet into a fresh minRouter so each test binds its own failure point.
    function _routerWith(IDynamicFeeFacet facet) internal returns (DynamicFeeFacetMinRouter router) {
        router = new DynamicFeeFacetMinRouter(facet);
    }

    /// @dev Minimal legal shape; the reverting mock ignores every field (only the selector/arg matters).
    function _prepareParams() internal pure returns (IDynamicFeeFacet.PrepareSwapFeeParams memory params) {
        params = IDynamicFeeFacet.PrepareSwapFeeParams({
            poolId: POOL_ID,
            zeroForOne: true,
            amountSpecified: -1 ether,
            trader: TRADER_A,
            preSqrtPriceX96: SQRT_PRICE_1_1,
            liquidity: 1_000_000 ether,
            protocolFeeOnInput: true,
            sqrtPriceLimitX96: 1
        });
    }
}
