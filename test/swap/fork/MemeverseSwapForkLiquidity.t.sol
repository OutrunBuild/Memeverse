// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {OrdinarySwapMath} from "../../../src/swap/libraries/OrdinarySwapMath.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

contract MemeverseSwapForkLiquidityTest is MemeverseSwapForkBase {
    function setUp() public {
        _setUpBase(IPermit2(address(0)));
    }

    function testAddLiquidity_RemoveLiquidity_ClaimFees() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        // Second LP joins.
        address lp2 = makeAddr("lp2");
        token0.mint(lp2, 1000 ether);
        token1.mint(lp2, 1000 ether);
        vm.startPrank(lp2);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.addLiquidity(key.currency0, key.currency1, 100 ether, 100 ether, 0, 0, lp2, block.timestamp);
        vm.stopPrank();

        // Generate fees via a swap.
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -50 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        _swapInSession(key, params, 0, 50 ether, "");

        // Preview and claim LP fees for lp2.
        (uint256 fee0Preview, uint256 fee1Preview) = router.previewClaimableFees(address(token0), address(token1), lp2);
        assertGt(fee0Preview + fee1Preview, 0, "fees accrued");

        uint256 lp2Token0Before = token0.balanceOf(lp2);
        uint256 lp2Token1Before = token1.balanceOf(lp2);
        vm.prank(lp2);
        (uint256 claimed0, uint256 claimed1) =
            _hook().claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: lp2}));
        assertEq(claimed0, fee0Preview, "claimed fee0 matches preview");
        assertEq(claimed1, fee1Preview, "claimed fee1 matches preview");
        assertEq(token0.balanceOf(lp2) - lp2Token0Before, fee0Preview, "lp2 received fee0");
        assertEq(token1.balanceOf(lp2) - lp2Token1Before, fee1Preview, "lp2 received fee1");
        (uint256 fee0AfterClaim, uint256 fee1AfterClaim) =
            router.previewClaimableFees(address(token0), address(token1), lp2);
        assertEq(fee0AfterClaim + fee1AfterClaim, 0, "fees reset after claim");

        // lp2 removes all liquidity.
        address lpToken = router.lpToken(address(token0), address(token1));
        uint256 lpBal = IERC20(lpToken).balanceOf(lp2);
        vm.startPrank(lp2);
        IERC20(lpToken).approve(address(router), lpBal);
        router.removeLiquidity(key.currency0, key.currency1, uint128(lpBal), 0, 0, lp2, block.timestamp);
        vm.stopPrank();
        // No revert == remove succeeded on real V4.
    }

    /// @dev Drains the pool by removing all router-held LP shares. Used by the drained-pool
    ///      regression tests below so each starts from a confirmed zero-liquidity / zero-LP-supply state.
    function _drainAllLiquidity() internal {
        address lpToken = router.lpToken(address(token0), address(token1));
        uint256 lpBal = IERC20(lpToken).balanceOf(address(this));
        IERC20(lpToken).approve(address(router), lpBal);
        router.removeLiquidity(key.currency0, key.currency1, uint128(lpBal), 0, 0, address(this), block.timestamp);
    }

    function testDrainedPool_QuoteSwap_ExactOutput_OutputFee_Reverts() external {
        _hook().setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainAllLiquidity();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        vm.expectRevert(OrdinarySwapMath.InvalidActiveLiquidity.selector);
        router.quoteSwap(key, params, address(this));
    }

    /// @dev Real V4 wraps hook errors, so inspect the nested revert bytes for the active-liquidity selector.
    function testDrainedPool_Swap_ExactOutput_OutputFee_RevertsForInactiveLiquidity() external {
        _hook().setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainAllLiquidity();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        uint256 inputBudget = token0.balanceOf(address(this));

        bytes memory revertData = _swapCapturingRevert(key, params, address(this), inputBudget);
        assertEq(bytes4(revertData), CustomRevert.WrappedError.selector, "outer selector");
        (address target, bytes4 callbackSelector, uint256 reasonLength, bytes4 reasonSelector) =
            _wrappedReason(revertData);
        assertEq(target, address(key.hooks), "wrapped target");
        assertEq(callbackSelector, IHooks.beforeSwap.selector, "wrapped callback");
        assertEq(reasonLength, 4, "nested reason length");
        assertEq(reasonSelector, OrdinarySwapMath.InvalidActiveLiquidity.selector, "nested reason selector");
    }

    function testCreatePoolAndAddLiquidity_OnlyLauncher() external {
        // Fresh token pair -> unique poolId on the real V4 singleton.
        MockERC20 newToken = new MockERC20("New0", "NW0", 18);
        MockERC20 otherToken = new MockERC20("New1", "NW1", 18);
        newToken.mint(address(this), 1_000_000 ether);
        otherToken.mint(address(this), 1_000_000 ether);
        newToken.approve(address(router), type(uint256).max);
        otherToken.approve(address(router), type(uint256).max);

        // authorizePoolInitialization is called BY the router; it requires msg.sender == poolInitializer,
        // so point poolInitializer at the router.
        _hook().setPoolInitializer(address(router));

        // createPoolAndAddLiquidity: 7 POSITIONAL params (tokenA, tokenB, amountADesired, amountBDesired, startPrice, recipient, deadline).
        router.createPoolAndAddLiquidity(
            address(newToken), address(otherToken), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );
        // No revert == pool created on real V4.
    }

    /// @dev createPoolAndAddLiquidity is launcher-only (router onlyLauncher modifier). A non-launcher
    ///      caller is rejected at the router entry (not V4-wrapped).
    function test_RevertWhen_CreatePool_NonLauncher() external {
        // The fork base deploys this contract as the launcher; attacker != launcher.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IMemeverseSwapRouter.UnauthorizedLauncher.selector);
        router.createPoolAndAddLiquidity(
            address(token0), address(token1), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );
    }

    /// @dev Two equal LPs (100 ether each) -> accrued fee split equally. feePerShare accumulates
    ///      proportionally, so equal balances claim equal fees. Guards against any per-LP fee bias.
    function testMultipleLp_FeeDistributedProportionally() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        // lp2 joins with the same 100 ether as the base LP (address(this)).
        address lp2 = makeAddr("lp2");
        token0.mint(lp2, 1000 ether);
        token1.mint(lp2, 1000 ether);
        vm.startPrank(lp2);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.addLiquidity(key.currency0, key.currency1, 100 ether, 100 ether, 0, 0, lp2, block.timestamp);
        vm.stopPrank();

        // Generate fees via swap (zeroForOne -> fee accrues on currency0 = token0).
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -50 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        _swapInSession(key, params, 0, 50 ether, "");

        (uint256 thisFee0, uint256 thisFee1) =
            router.previewClaimableFees(address(token0), address(token1), address(this));
        (uint256 lp2Fee0, uint256 lp2Fee1) = router.previewClaimableFees(address(token0), address(token1), lp2);
        assertGt(thisFee0, 0, "fees accrued on currency0");
        assertEq(thisFee0, lp2Fee0, "equal LPs get equal fee0");
        assertEq(thisFee1, lp2Fee1, "equal LPs get equal fee1");
    }
}
