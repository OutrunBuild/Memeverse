// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @title SettlementSequentialExecutionTest
/// @notice Verifies consecutive settlements remain independent and preserve observable accounting.
contract SettlementSequentialExecutionTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q128 = uint256(1) << 128;

    IPoolManager internal manager;
    MemeverseUniswapHook internal hook;
    MockERC20 internal inputToken;
    MockERC20 internal outputToken;
    PoolKey internal settlementPoolKey;
    bool internal zeroForOne;
    address internal treasury = address(0xFEE);

    function setUp() public {
        manager = deployRealPoolManager();
        inputToken = new MockERC20("Input", "IN", 18);
        outputToken = new MockERC20("Output", "OUT", 18);
        inputToken.mint(address(this), 1_000_000 ether);
        outputToken.mint(address(this), 1_000_000 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHook(hookProxy);

        hook.setPoolInitializer(address(this));
        inputToken.approve(address(hook), type(uint256).max);
        outputToken.approve(address(hook), type(uint256).max);

        settlementPoolKey = _dynamicPoolKey(address(inputToken), address(outputToken));
        zeroForOne = Currency.unwrap(settlementPoolKey.currency0) == address(inputToken);
        hook.authorizePoolInitialization(settlementPoolKey, SQRT_PRICE_1_1);
        manager.initialize(settlementPoolKey, SQRT_PRICE_1_1);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: settlementPoolKey.currency0,
                currency1: settlementPoolKey.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
        hook.setProtocolFeeCurrency(Currency.wrap(address(inputToken)), true);
    }

    function test_SequentialSettlementsPreserveIndependentAccounting() external {
        uint256 payerInputBefore = inputToken.balanceOf(address(this));
        uint256 recipientOutputBefore = outputToken.balanceOf(address(this));
        uint256 treasuryInputBefore = inputToken.balanceOf(treasury);
        uint256 hookInputBefore = inputToken.balanceOf(address(hook));
        (address liquidityToken,,) = hook.poolInfo(settlementPoolKey.toId());
        uint256 activeLiquidityTokenSupply = IERC20(liquidityToken).totalSupply();

        _settle();
        uint256 recipientOutputAfterFirst = outputToken.balanceOf(address(this));
        _settle();
        uint256 recipientOutputAfterSecond = outputToken.balanceOf(address(this));

        assertEq(payerInputBefore - inputToken.balanceOf(address(this)), 20 ether, "payer funded both settlements");
        assertEq(inputToken.balanceOf(treasury) - treasuryInputBefore, 0.07 ether, "treasury received both fees");
        assertEq(inputToken.balanceOf(address(hook)) - hookInputBefore, 0.13 ether, "hook retained both LP fees");
        assertGt(recipientOutputAfterFirst, recipientOutputBefore, "first settlement delivered output");
        assertGt(recipientOutputAfterSecond, recipientOutputAfterFirst, "second settlement delivered output");

        (, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(settlementPoolKey.toId());
        uint256 expectedFeePerShare = 2 * FullMath.mulDiv(0.065 ether, Q128, activeLiquidityTokenSupply);
        assertEq(
            zeroForOne ? fee0PerShare : fee1PerShare, expectedFeePerShare, "LP accounting includes both settlements"
        );
    }

    function _settle() internal {
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: settlementPoolKey,
                params: SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(10 ether),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                recipient: address(this)
            })
        );
    }

    function _dynamicPoolKey(address currencyA, address currencyB) internal view returns (PoolKey memory) {
        (address currency0, address currency1) = currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }
}

