// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {InitialPriceCalculator} from "../../../src/verse/libraries/InitialPriceCalculator.sol";

contract InitialPriceCalculatorTest is Test {
    uint160 internal constant Q96 = uint160(1 << 96);

    address internal constant LOWER = address(0x1000);
    address internal constant HIGHER = address(0x2000);

    /// @notice Exposes the amount-based start-price helper for external revert assertions.
    /// @dev Allows `vm.expectRevert` to target the library via an external call.
    /// @param tokenA The first token address supplied to the helper.
    /// @param tokenB The second token address supplied to the helper.
    /// @param amountADesired The raw amount for `tokenA`.
    /// @param amountBDesired The raw amount for `tokenB`.
    /// @return sqrtPriceX96 The computed Uniswap v4 start price.
    function calculateInitialSqrtPriceX96External(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external pure returns (uint160) {
        return InitialPriceCalculator.calculateInitialSqrtPriceX96(tokenA, tokenB, amountADesired, amountBDesired);
    }

    /// @notice Verifies equal budgets produce the canonical 1:1 `sqrtPriceX96`.
    /// @dev Confirms the helper returns `Q96` for a 1:1 18-decimal pair.
    function testCalculateInitialSqrtPriceX96AtOneToOne() external pure {
        uint160 sqrtPriceX96 = InitialPriceCalculator.calculateInitialSqrtPriceX96(LOWER, HIGHER, 1 ether, 1 ether);
        assertEq(sqrtPriceX96, Q96);
    }

    /// @notice Verifies the amount-based helper respects Uniswap token sorting.
    /// @dev The same economic ratio should resolve to the same sorted pool price.
    function testCalculateInitialSqrtPriceX96RespectsAddressSorting() external pure {
        uint160 sqrtPriceX96 = InitialPriceCalculator.calculateInitialSqrtPriceX96(LOWER, HIGHER, 4 ether, 1 ether);
        assertEq(sqrtPriceX96, Q96 / 2);

        sqrtPriceX96 = InitialPriceCalculator.calculateInitialSqrtPriceX96(HIGHER, LOWER, 1 ether, 4 ether);
        assertEq(sqrtPriceX96, Q96 / 2);
    }

    /// @notice Verifies the amount-based helper reproduces the legacy memecoin bootstrap ratio when uAsset sorts first.
    /// @dev Address ordering should still map `(fundBasedAmount, 1)` to the same sorted pool price as the removed helper.
    function testCalculateInitialSqrtPriceX96MatchesLegacyFundBasedRatioWhenUAssetSortsFirst() external pure {
        uint160 sqrtPriceX96 = InitialPriceCalculator.calculateInitialSqrtPriceX96(HIGHER, LOWER, 4, 1);
        assertEq(sqrtPriceX96, Q96 * 2);
    }

    /// @notice Verifies zero amount input is rejected for the amount-based helper.
    /// @dev Zero budgets must fail before any price math executes.
    function testCalculateInitialSqrtPriceX96RevertOnZeroInput() external {
        vm.expectRevert(InitialPriceCalculator.ZeroInput.selector);
        this.calculateInitialSqrtPriceX96External(LOWER, HIGHER, 0, 1 ether);
    }

    /// @notice Verifies extremely low price ratios still respect the TickMath lower bound.
    /// @dev Ratios below the supported TickMath floor must revert with `InvalidSqrtPrice`.
    function testCalculateInitialSqrtPriceX96RevertOnBelowMinSqrtPrice() external {
        vm.expectRevert(abi.encodeWithSelector(InitialPriceCalculator.InvalidSqrtPrice.selector, uint160(2)));
        this.calculateInitialSqrtPriceX96External(LOWER, HIGHER, 1 << 190, 1);

        assertGt(TickMath.MIN_SQRT_PRICE, 2);
    }

    /// @notice Verifies unsupported high amount ratios fail explicitly before overflow.
    /// @dev The helper exposes its `2^64` price-ratio ceiling through a dedicated custom error.
    function testCalculateInitialSqrtPriceX96RevertOnUnsupportedHighRatio() external {
        vm.expectRevert(
            abi.encodeWithSelector(InitialPriceCalculator.PriceRatioTooHigh.selector, uint256(1), uint256(1 << 64))
        );
        this.calculateInitialSqrtPriceX96External(LOWER, HIGHER, 1, 1 << 64);
    }
}
