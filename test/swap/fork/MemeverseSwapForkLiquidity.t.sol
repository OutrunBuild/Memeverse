// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
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
        router.swap(key, params, address(this), block.timestamp, 0, 50 ether, "");

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

    function testRemoveAllLiquidity_ZeroLiquiditySwapDoesNotRevert() external {
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        address lpToken = router.lpToken(address(token0), address(token1));
        uint256 lpBal = IERC20(lpToken).balanceOf(address(this));
        IERC20(lpToken).approve(address(router), lpBal);
        router.removeLiquidity(key.currency0, key.currency1, uint128(lpBal), 0, 0, address(this), block.timestamp);

        // Zero-liquidity quote path must not revert.
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        router.quoteSwap(key, params, address(this));
    }

    /// @dev Drains the pool the same way `testRemoveAllLiquidity_*` does. Reused by the drained-pool
    ///      regression tests below so each starts from a confirmed zero-liquidity / zero-LP-supply state.
    function _drainAllLiquidity() internal {
        address lpToken = router.lpToken(address(token0), address(token1));
        uint256 lpBal = IERC20(lpToken).balanceOf(address(this));
        IERC20(lpToken).approve(address(router), lpBal);
        router.removeLiquidity(key.currency0, key.currency1, uint128(lpBal), 0, 0, address(this), block.timestamp);
    }

    /// @notice CI-016 regression (quote path, real V4 SwapMath). On a drained pool, an exact-output quote
    ///         with the protocol fee on the OUTPUT leg used to underflow
    ///         (`estimatedGrossOutputAmount(0) - requestedOutputAmount` → Panic 0x11). It must now return a
    ///         zero-fee quote without reverting.
    function testDrainedPool_QuoteSwap_ExactOutput_OutputFee_ReturnsZeroNotRevert() external {
        // Output currency (currency1) carries the protocol fee -> protocolFeeOnInput == false, the buggy branch.
        _hook().setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainAllLiquidity();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        // Pre-fix this reverted with Panic 0x11. LR-001 now makes a drained pool advertise no net
        // take/output/input/fees (gross==0 gates), matching the mock regression in
        // MemeverseUniswapHookDrainedPool.t.sol. Asserting every amount is zero pins the full drained
        // quote semantics rather than just the clamped fee.
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        assertEq(quote.estimatedUserOutputAmount, 0, "drained pool delivers no net output (LR-001)");
        assertEq(quote.estimatedUserInputAmount, 0, "drained pool requires no net input");
        assertEq(quote.estimatedProtocolFeeAmount, 0, "grossed-up protocol fee clamped to 0");
        assertEq(quote.estimatedLpFeeAmount, 0, "no LP fee on drained pool");
    }

    /// @notice CI-012 regression (execution path, real V4 SwapMath). On a drained pool, an exact-output
    ///         swap with the protocol fee on the OUTPUT leg used to underflow inside `beforeSwapLogic`
    ///         (`estimatedGrossOutputAmount(0) - absSpecified` → Panic 0x11). With the bounded subtraction
    ///         the swap now reaches afterSwap's partial-fill guard and reverts `ExactOutputPartialFill`
    ///         (the pool can deliver none of the requested output), never panicking.
    /// @dev A bare `vm.expectRevert()` would pass even if the CI-012 fix regressed: beforeSwap's Panic 0x11
    ///      reverts just the same. V4 invokes hooks via low-level CALL (`Hooks.callHook`), so ANY hook
    ///      revert — `ExactOutputPartialFill` (afterSwap) OR a regressed Panic 0x11 (beforeSwap) — is captured
    ///      and re-raised as `CustomRevert.WrappedError` (selector 0x90bfb865) carrying the raw revert data in
    ///      its `reason` field. Asserting `WrappedError.selector` alone therefore CANNOT distinguish the two
    ///      paths. Instead, capture the revert bytes and scan them for `ExactOutputPartialFill.selector`: that
    ///      selector is present only on the fixed afterSwap path and absent from a Panic's reason bytes,
    ///      making the test fail loudly if the bounded subtraction is removed.
    function testDrainedPool_Swap_ExactOutput_OutputFee_RevertsPartialFillNotPanic() external {
        _hook().setProtocolFeeCurrency(key.currency1, true);
        _matureLaunchWindow();
        _drainAllLiquidity();

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        // The router pulls the exact-output input budget up front; fund it from the test account.
        uint256 inputBudget = token0.balanceOf(address(this));

        // Must revert AND surface ExactOutputPartialFill, not Panic 0x11. Capture the v4-wrapped bytes and
        // assert the partial-fill selector is present somewhere inside them (see _containsSelector).
        bytes memory revertData = _swapCapturingRevert(key, params, address(this), inputBudget);
        assertTrue(revertData.length > 0, "drained exact-output swap must revert");
        assertTrue(
            _containsSelector(revertData, IMemeverseUniswapHook.ExactOutputPartialFill.selector),
            "revert carries ExactOutputPartialFill (afterSwap partial-fill path), not a beforeSwap Panic"
        );
    }

    /// @dev Runs the router swap inside a try/catch so the reverted bytes are inspectable. Required because a
    ///      `vm.expectRevert()` with no selector matches any revert (including a regressed Panic 0x11); the
    ///      caller asserts on the captured bytes instead. The catch body needs an external call (forge-std
    ///      cheatcode rule), so the runner is `external` and only invoked from the test. Mirrors the pattern in
    ///      test/swap/BeforeSwapReentrancyGuard.t.sol (`_swapViaUnlockCapturingRevert`).
    function _swapCapturingRevert(
        PoolKey memory swapKey,
        SwapParams memory params,
        address recipient,
        uint256 inputBudget
    ) internal returns (bytes memory revertData) {
        try this._runSwapReverting(swapKey, params, recipient, inputBudget) {
            revert("expected drained exact-output swap to revert");
        } catch (bytes memory reason) {
            return reason;
        }
    }

    /// @notice External swap runner used only by `_swapCapturingRevert` so the revert can be caught.
    function _runSwapReverting(PoolKey memory swapKey, SwapParams memory params, address recipient, uint256 inputBudget)
        external
    {
        router.swap(swapKey, params, recipient, block.timestamp, 0, inputBudget, "");
    }

    /// @dev Scans raw revert bytes (incl. v4 WrappedError payloads) for a 4-byte selector. v4 wraps hook
    ///      reverts as `WrappedError(target, selector, reason, details)` and copies the hook's raw revert data
    ///      verbatim into `reason`, so a partial-fill revert surfaces its selector inside the wrapper rather
    ///      than as the outermost word. Scanning finds it there but NOT inside a Panic(0x11) reason (which is
    ///      just `0x4e487b71` + a uint256), which is what distinguishes the two control-flow paths.
    ///      Mirrors `test/swap/BeforeSwapReentrancyGuard.t.sol:_containsSelector`.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            bytes4 word;
            assembly ("memory-safe") {
                // Read 4 bytes starting at data[i]; the 4 target bytes sit in the low half-word (bytes4 is
                // right-aligned), then mask.
                word := and(
                    mload(add(add(data, 0x20), i)),
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            }
            if (word == selector) return true;
        }
        return false;
    }

    function testCreatePoolAndAddLiquidity_OnlyLauncher() external {
        // Fresh token pair -> unique poolId on the real V4 singleton.
        MockERC20 newToken = new MockERC20("New0", "NW0", 18);
        MockERC20 otherToken = new MockERC20("New1", "NW1", 18);
        newToken.mint(address(this), 1_000_000 ether);
        otherToken.mint(address(this), 1_000_000 ether);
        newToken.approve(address(router), type(uint256).max);
        otherToken.approve(address(router), type(uint256).max);

        _hook().setLauncher(address(this));
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
        _hook().setLauncher(address(this)); // this is the launcher; attacker != launcher
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
        router.swap(key, params, address(this), block.timestamp, 0, 50 ether, "");

        (uint256 thisFee0, uint256 thisFee1) =
            router.previewClaimableFees(address(token0), address(token1), address(this));
        (uint256 lp2Fee0, uint256 lp2Fee1) = router.previewClaimableFees(address(token0), address(token1), lp2);
        assertGt(thisFee0, 0, "fees accrued on currency0");
        assertEq(thisFee0, lp2Fee0, "equal LPs get equal fee0");
        assertEq(thisFee1, lp2Fee1, "equal LPs get equal fee1");
    }
}
