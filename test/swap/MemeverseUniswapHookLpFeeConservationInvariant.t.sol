// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// Global LP-fee conservation invariant on the REAL v4-core PoolManager.
//
// Existing suites assert per-user claim semantics pointwise (snapshot math, claim payouts, zero-balance
// offsets). None of them asserts the SUM-level guarantee that per-share accounting can never issue more
// claimable fees than were actually collected for LPs. Per-share Q128 accumulation floors twice (once when
// a fee event is spread over `totalSupply`, once per user when shares crystallize), so global conservation
// is exactly where accumulated rounding would surface first.
//
// Oracle used here: with no referrer (empty hookData) and no settlement activity, the ONLY flows that move
// the hook's token balances are LP-fee takes (poolManager.take -> hook custody, `SwapFacet._collectLpFee`)
// and claimFeesCore payouts. Protocol fees are taken straight to treasury and never touch hook custody.
// Therefore, per currency:
//     collected = hookBalanceNow - hookBalanceAtStart + ghostClaimed
// and the invariant is
//     sumOfClaimableOverAllLpHolders + ghostClaimed <= collected.
// Floor subadditivity (sum of per-user floors <= floor of the sum) makes `<=` exact, not approximate:
// rounding may strand dust in the per-share accumulator, but can never mint claimable fees from nothing.

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {RealV4SwapIntegrator} from "./MemeverseReferralRebateRealV4.t.sol";

/// @notice Handler that drives swap / liquidity / LP-transfer / claim ops for a fixed actor set and
///         keeps ghost ledgers for the fee-conservation invariant.
/// @dev Actors are the only LP holders: the initial full-range position is minted `to` actors[0], and no
///      op ever sends LP outside the actor set, so summing `claimableFees` over the actors is exhaustive.
contract LpFeeConservationHandler is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal immutable manager;
    IMemeverseUniswapHook internal immutable hook;
    MemeverseUniswapHookLens internal immutable lens;
    RealV4SwapIntegrator internal immutable integrator;
    MockERC20 internal immutable token0;
    MockERC20 internal immutable token1;
    UniswapLP internal immutable lpToken;
    PoolKey internal key;

    address[] internal actors;

    // Ghost ledgers, per currency: cumulative fee amounts paid OUT of hook custody by claims.
    uint256 public ghostClaimed0;
    uint256 public ghostClaimed1;

    // Successful swap count: the non-vacuity guard proves fees actually accrued during the run.
    uint256 public ghostSuccessfulSwaps;

    // Hook custody balances at handler construction (after the initial full-range add).
    uint256 internal immutable initialHookBalance0;
    uint256 internal immutable initialHookBalance1;

    constructor(
        IPoolManager manager_,
        IMemeverseUniswapHook hook_,
        MemeverseUniswapHookLens lens_,
        RealV4SwapIntegrator integrator_,
        MockERC20 token0_,
        MockERC20 token1_,
        PoolKey memory key_,
        address[] memory actors_
    ) {
        manager = manager_;
        hook = hook_;
        lens = lens_;
        integrator = integrator_;
        token0 = token0_;
        token1 = token1_;
        key = key_;
        lpToken = UniswapLP(hook_.liquidityTokenOf(PoolIdLibrary.toId(key_)));
        actors = actors_;

        initialHookBalance0 = token0_.balanceOf(address(hook_));
        initialHookBalance1 = token1_.balanceOf(address(hook_));
    }

    // ------------------------------------------------------------------ ops

    /// @notice Exact-input swap in a random direction; fees accrue in the input currency.
    function swap(uint8 actorSeed, uint8 directionSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        bool zeroForOne = directionSeed % 2 == 0;
        uint256 amount = _bound(amountSeed, 0.01 ether, 5 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Public swaps require an active account session; the handler is a contract, so it can open one
        // (as the session principal) around the integrator's swap, mirroring the real caller flow.
        hook.beginAccountSession();
        vm.prank(actor);
        integrator.swap(key, params, actor, "");
        hook.endAccountSession();
        ghostSuccessfulSwaps++;
    }

    /// @notice Add balanced liquidity as a random actor (LP minted to that actor).
    function addLiquidity(uint8 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 desiredPerSide = _bound(amountSeed, 0.1 ether, 5 ether);

        vm.prank(actor);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: desiredPerSide,
                amount1Desired: desiredPerSide,
                to: actor
            })
        );
    }

    /// @notice Remove a bounded slice of a random actor's LP position.
    function removeLiquidity(uint8 actorSeed, uint256 liquiditySeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = lpToken.balanceOf(actor);
        uint256 liquidity = _bound(liquiditySeed, 1, balance);

        vm.prank(actor);
        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: uint128(liquidity), recipient: actor
            })
        );
    }

    /// @notice Transfer LP between two different actors, triggering the snapshot callback on transfer.
    function transferLp(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[(toSeed % (actors.length - 1) + fromSeed + 1) % actors.length];
        uint256 balance = lpToken.balanceOf(from);
        uint256 amount = _bound(amountSeed, 1, balance);

        vm.prank(from);
        lpToken.transfer(to, amount);
    }

    /// @notice Self-claim fees as a random actor; ghost-record the exact amounts paid out.
    function claimFees(uint8 actorSeed) external {
        address actor = actors[actorSeed % actors.length];

        uint256 before0 = token0.balanceOf(actor);
        uint256 before1 = token1.balanceOf(actor);

        vm.prank(actor);
        hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: actor}));

        ghostClaimed0 += token0.balanceOf(actor) - before0;
        ghostClaimed1 += token1.balanceOf(actor) - before1;
    }

    // ------------------------------------------------------------- views

    /// @notice Sum of currently claimable fees over every LP holder (pending + uncrystallized part).
    function totalClaimable0() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 fee0,) = lens.claimableFees(hook, key, actors[i]);
            total += fee0;
        }
    }

    function totalClaimable1() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            (, uint256 fee1) = lens.claimableFees(hook, key, actors[i]);
            total += fee1;
        }
    }

    /// @notice Total LP fee that ever entered hook custody for currency0, net of claims already paid.
    function collectedFee0() external view returns (uint256) {
        return token0.balanceOf(address(hook)) - initialHookBalance0 + ghostClaimed0;
    }

    function collectedFee1() external view returns (uint256) {
        return token1.balanceOf(address(hook)) - initialHookBalance1 + ghostClaimed1;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Stateful fuzz: per-share LP-fee accounting must never over-issue across the whole user set.
contract MemeverseUniswapHookLpFeeConservationInvariants is StdInvariant, Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseUniswapHookLens internal lens;
    RealV4SwapIntegrator internal integrator;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    LpFeeConservationHandler internal handler;
    address[] internal actors;

    function setUp() public {
        actors = new address[](3);
        actors[0] = makeAddr("lpAlice");
        actors[1] = makeAddr("lpBob");
        actors[2] = makeAddr("lpCarol");

        // 1. Real v4-core PoolManager (v4 pins solc 0.8.26, so it is deployed from bytecode, not imported).
        manager = deployRealPoolManager();

        // 2. Tokens with sorted addresses (token0 < token1).
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        require(address(token0) < address(token1), "token order");

        // 3. Real hook/LP stack behind a flag-address UUPS proxy.
        address hookProxy = deployHookAtFlagAddress(manager, address(this), address(this));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        lens = new MemeverseUniswapHookLens(manager);
        integrator = new RealV4SwapIntegrator(manager);

        // 4. Fund every actor; approvals let the hook pull LP/fee inputs and the integrator pull swap input.
        for (uint256 i = 0; i < actors.length; i++) {
            token0.mint(actors[i], 1_000_000 ether);
            token1.mint(actors[i], 1_000_000 ether);
            vm.startPrank(actors[i]);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            token0.approve(address(integrator), type(uint256).max);
            token1.approve(address(integrator), type(uint256).max);
            vm.stopPrank();
        }
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // 5. Pool key: dynamic fee, tickSpacing 200, hook = proxy.
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000, // LPFeeLibrary.DYNAMIC_FEE_FLAG
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        // 6. Initialize the pool, then seed the initial full-range position minted to actors[0] so the
        //    actor set remains the exhaustive set of LP holders.
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, 79228162514264337593543950336); // sqrt price 1.0
        manager.initialize(key, 79228162514264337593543950336);

        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: actors[0]
            })
        );

        // 7. Move past the launch-fee decay window so swap fees are the stable base fee.
        vm.warp(block.timestamp + 900);

        // 8. Handler owns the ghost ledgers; baseline custody is captured after the initial add.
        handler = new LpFeeConservationHandler(manager, hook, lens, integrator, token0, token1, key, actors);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------- invariants

    /// @notice Currency0 leg: claimable-over-all-holders + already-claimed must stay within what the
    ///         hook ever collected for LPs in currency0. Floor rounding may strand dust in the per-share
    ///         accumulator (collected - claimed - claimable >= 0) but can never over-issue.
    function invariant_Currency0FeesNeverOverIssue() external view {
        uint256 outstanding = handler.totalClaimable0() + handler.ghostClaimed0();
        assertLe(outstanding, handler.collectedFee0(), "currency0 per-share over-issuance");
    }

    /// @notice Currency1 leg of the same conservation bound.
    function invariant_Currency1FeesNeverOverIssue() external view {
        uint256 outstanding = handler.totalClaimable1() + handler.ghostClaimed1();
        assertLe(outstanding, handler.collectedFee1(), "currency1 per-share over-issuance");
    }

    /// @notice Non-vacuity guard: the base fee floor makes every successful swap accrue LP fees, so a
    ///         run with successful swaps must show non-zero collected fees (otherwise the conservation
    ///         invariants above would pass on an empty ledger without testing anything).
    function afterInvariant() external view {
        if (handler.ghostSuccessfulSwaps() > 0) {
            assertGt(
                handler.collectedFee0() + handler.collectedFee1(), 0, "swaps succeeded but no LP fee was ever collected"
            );
        }
    }
}
