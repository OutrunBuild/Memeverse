// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";

contract MemeverseSwapRouterInterfaceTest is Test {
    /// @notice Verifies the router public interface selectors match the implementation selectors.
    /// @dev Guards against selector drift while refactoring router internals. The `hook()` and
    ///      `permit2()` accessors are pinned separately by `testAccessorSelectorsRemainStable`.
    function testInterfaceSelectorsMatchRouter() external pure {
        bytes4[] memory interfaceSelectors = new bytes4[](11);
        interfaceSelectors[0] = IMemeverseSwapRouter.quoteSwap.selector;
        interfaceSelectors[1] = IMemeverseSwapRouter.quoteAmountsForLiquidity.selector;
        interfaceSelectors[2] = IMemeverseSwapRouter.quoteExactAmountsForLiquidity.selector;
        interfaceSelectors[3] = IMemeverseSwapRouter.swap.selector;
        interfaceSelectors[4] = IMemeverseSwapRouter.swapWithPermit2.selector;
        interfaceSelectors[5] = IMemeverseSwapRouter.addLiquidity.selector;
        interfaceSelectors[6] = IMemeverseSwapRouter.addLiquidityDetailed.selector;
        interfaceSelectors[7] = IMemeverseSwapRouter.addLiquidityWithPermit2.selector;
        interfaceSelectors[8] = IMemeverseSwapRouter.removeLiquidity.selector;
        interfaceSelectors[9] = IMemeverseSwapRouter.removeLiquidityWithPermit2.selector;
        interfaceSelectors[10] = IMemeverseSwapRouter.createPoolAndAddLiquidity.selector;

        bytes4[] memory routerSelectors = new bytes4[](11);
        routerSelectors[0] = MemeverseSwapRouter.quoteSwap.selector;
        routerSelectors[1] = MemeverseSwapRouter.quoteAmountsForLiquidity.selector;
        routerSelectors[2] = MemeverseSwapRouter.quoteExactAmountsForLiquidity.selector;
        routerSelectors[3] = MemeverseSwapRouter.swap.selector;
        routerSelectors[4] = MemeverseSwapRouter.swapWithPermit2.selector;
        routerSelectors[5] = MemeverseSwapRouter.addLiquidity.selector;
        routerSelectors[6] = MemeverseSwapRouter.addLiquidityDetailed.selector;
        routerSelectors[7] = MemeverseSwapRouter.addLiquidityWithPermit2.selector;
        routerSelectors[8] = MemeverseSwapRouter.removeLiquidity.selector;
        routerSelectors[9] = MemeverseSwapRouter.removeLiquidityWithPermit2.selector;
        routerSelectors[10] = MemeverseSwapRouter.createPoolAndAddLiquidity.selector;

        for (uint256 i = 0; i < interfaceSelectors.length; ++i) {
            assertEq(interfaceSelectors[i], routerSelectors[i]);
        }
    }

    /// @notice Verifies the simplified swap selector no longer includes a refund-recipient parameter.
    /// @dev This guards the router-surface simplification that always refunds unused budgets back to the caller.
    function testSwapSelector_DropsRefundRecipientParameter() external pure {
        assertEq(
            IMemeverseSwapRouter.swap.selector,
            bytes4(
                keccak256(
                    "swap((address,address,uint24,int24,address),(bool,int256,uint160),address,uint256,uint256,uint256,bytes)"
                )
            )
        );
    }

    /// @notice Verifies the simplified Permit2 swap selector no longer includes a refund-recipient parameter.
    /// @dev Permit2 swaps now share the same caller-refund semantics as regular swaps.
    function testSwapWithPermit2Selector_DropsRefundRecipientParameter() external pure {
        bytes4 oldSelector = bytes4(
            keccak256(
                "swapWithPermit2(((address,uint256),uint256,uint256,(address,uint256),bytes),(address,address,uint24,int24,address),(bool,int256,uint160),address,address,uint256,uint256,uint256,bytes)"
            )
        );
        assertNotEq(IMemeverseSwapRouter.swapWithPermit2.selector, oldSelector);
        assertEq(IMemeverseSwapRouter.swapWithPermit2.selector, MemeverseSwapRouter.swapWithPermit2.selector);
    }

    /// @notice Verifies the router accessor selectors remain unchanged.
    /// @dev Keeps a tiny focused regression check on the immutable public accessors.
    function testAccessorSelectorsRemainStable() external pure {
        assertEq(IMemeverseSwapRouter.hook.selector, bytes4(keccak256("hook()")));
        assertEq(IMemeverseSwapRouter.permit2.selector, bytes4(keccak256("permit2()")));
    }

    /// @notice Verifies the detailed add-liquidity selector is pinned on the shared router surface.
    /// @dev Locks the new exact-spend reporting entrypoint without changing the legacy add-liquidity selector.
    function testAddLiquidityDetailedSelector_IsStable() external pure {
        assertEq(
            IMemeverseSwapRouter.addLiquidityDetailed.selector,
            bytes4(keccak256("addLiquidityDetailed(address,address,uint256,uint256,uint256,uint256,address,uint256)"))
        );
        assertEq(IMemeverseSwapRouter.addLiquidityDetailed.selector, MemeverseSwapRouter.addLiquidityDetailed.selector);
    }

    function testQuoteExactAmountsForLiquiditySelector_IsStable() external pure {
        assertEq(
            IMemeverseSwapRouter.quoteExactAmountsForLiquidity.selector,
            bytes4(keccak256("quoteExactAmountsForLiquidity(address,address,uint128)"))
        );
        assertEq(
            IMemeverseSwapRouter.quoteExactAmountsForLiquidity.selector,
            MemeverseSwapRouter.quoteExactAmountsForLiquidity.selector
        );
    }
}
