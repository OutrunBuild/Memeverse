//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IMemeverseLiquidityRouter {
    function addExactTokensForLiquidity(
        address tokenA,
        address tokenB,
        uint256 feeRate,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 triggerTime,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addTokensForExactLiquidity(
        address tokenA,
        address tokenB,
        uint256 feeRate,
        uint256 liquidityDesired,
        uint256 amountAMax,
        uint256 amountBMax,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
