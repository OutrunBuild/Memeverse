// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library MemeversePoolKeyLib {
    int24 internal constant DEFAULT_TICK_SPACING = 200;

    // FULL_RANGE_LOWER_TICK / FULL_RANGE_UPPER_TICK bound full-range liquidity and must remain multiples of
    // DEFAULT_TICK_SPACING — V4 modifyLiquidity requires tickLower % tickSpacing == 0. If DEFAULT_TICK_SPACING
    // changes, update both to the largest multiples within V4's ±887272 tick bound, else full-range
    // addLiquidity/removeLiquidity reverts and LP funds lock.
    int24 internal constant FULL_RANGE_LOWER_TICK = -887200;
    int24 internal constant FULL_RANGE_UPPER_TICK = 887200;

    function sortedCurrencies(address tokenA, address tokenB)
        internal
        pure
        returns (Currency currency0, Currency currency1, bool tokenAIsCurrency0)
    {
        tokenAIsCurrency0 = tokenA < tokenB;
        currency0 = Currency.wrap(tokenAIsCurrency0 ? tokenA : tokenB);
        currency1 = Currency.wrap(tokenAIsCurrency0 ? tokenB : tokenA);
    }

    function hookPoolKey(address tokenA, address tokenB, address hookAddress)
        internal
        pure
        returns (PoolKey memory key)
    {
        (Currency currency0, Currency currency1,) = sortedCurrencies(tokenA, tokenB);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
    }
}
