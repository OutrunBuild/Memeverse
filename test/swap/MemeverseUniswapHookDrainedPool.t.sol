// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {OrdinarySwapMath} from "../../src/swap/libraries/OrdinarySwapMath.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";

/// @notice Regression coverage for non-zero quotes against a drained pool.
/// @dev Ordinary swap quotes require active liquidity and must fail instead of returning an executable zero quote.
contract MemeverseUniswapHookDrainedPoolTest is RealisticSwapIntegrationBase {
    /// @dev The mock manager mirrors real PoolManager storage via extsload (see RealisticSwapMocks
    ///      `_syncPoolStorage`), so StateLibrary reads the same liquidity slot the production code does.
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));
    }

    /// @dev Removes all LP liquidity so the pool reaches the drained state the bugs require:
    ///      `poolManager.getLiquidity(poolId) == 0` and `cachedLpTotalSupply == 0`. Asserts both are zero
    ///      so a future setup change cannot silently leave residual liquidity and mask the regression.
    function _drainPool() internal {
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 lpBalance = IERC20(liquidityToken).balanceOf(address(this));
        assertGt(lpBalance, 0, "setup: LP balance present before drain");

        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                liquidity: uint128(lpBalance),
                recipient: address(this)
            })
        );

        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0, "drained: pool liquidity is zero");
        assertEq(hook.cachedLpTotalSupply(poolId), 0, "drained: cached LP supply is zero");
    }

    /// @notice Quotes against a drained pool must revert for every direction and protocol-fee side.
    /// @dev All branches reach the same active-liquidity guard before fee-side or direction math can
    ///      matter; fuzzing the bool pair covers the exact-input/exact-output × input-fee/output-fee matrix.
    function test_RevertWhen_QuoteSwapOnDrainedPool(bool feeOnCurrency0, bool exactInput) external {
        hook.setProtocolFeeCurrency(feeOnCurrency0 ? key.currency0 : key.currency1, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: exactInput ? -int256(1 ether) : int256(1 ether),
            sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
    }
}
