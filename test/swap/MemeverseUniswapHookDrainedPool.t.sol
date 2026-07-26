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

    function testQuoteSwap_DrainedPool_ExactOutput_OutputFee_Reverts() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
    }

    function testQuoteSwap_DrainedPool_ExactOutput_InputFee_Reverts() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
    }

    function testQuoteSwap_DrainedPool_ExactInput_OutputFee_Reverts() external {
        hook.setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainPool();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
    }
}
