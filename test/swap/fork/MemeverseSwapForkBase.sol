// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MemeverseSwapRouter} from "../../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../../mocks/swap/HookStorageHelper.sol";

// No bare integrator: every test routes through router.swap, which already reaches the real V4
// singleton (router -> hook -> poolManager.unlock -> swap -> settle/take).

abstract contract MemeverseSwapForkBase is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;
    // StateLibrary.getSlot0/getLiquidity read real V4 storage via extsload.
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 25400000;
    uint256 internal constant FEE_GROWTH_Q128 = uint256(1) << 128;

    IPoolManager internal manager;
    MemeverseUniswapHookLens internal lens;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    PoolKey internal key;
    PoolId internal poolId;

    function _setUpBase(IPermit2 permit2) internal {
        // CI degradation: when the mainnet RPC is absent (e.g. CI without the secret), skip the whole
        // suite instead of failing the gate on `createSelectFork`. foundry.toml resolves eth_mainnet
        // from ETH_MAINNET_RPC, so an empty env var means no usable endpoint.
        if (bytes(vm.envOr("ETH_MAINNET_RPC", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("eth_mainnet", FORK_BLOCK);

        manager = IPoolManager(V4_POOL_MANAGER);
        treasury = makeAddr("treasury");

        // Deploy both tokens, then bind token0 to the SMALLER address so token0 == key.currency0
        // (V4 requires currency0 < currency1). All tests rely on this identity.
        MockERC20 a = new MockERC20("TokenA", "TKA", 18);
        MockERC20 b = new MockERC20("TokenB", "TKB", 18);
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        (address hookProxy,) = deployHookAtFlagAddress(manager, address(this), treasury);
        IMemeverseUniswapHook hook = IMemeverseUniswapHook(hookProxy);
        lens = new MemeverseUniswapHookLens(manager);
        router = new MemeverseSwapRouter(manager, hook, lens, permit2);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        // token0 is guaranteed the smaller address above, so currency0 = token0.
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(hookProxy)
        });
        poolId = key.toId();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(address(this));
    }

    // Returns the concrete hook type (cast, not inherited) so tests can call owner-only setters
    // like setProtocolFeeCurrency that are NOT on IMemeverseUniswapHook. Mirrors the existing
    // harness pattern at test/swap/helpers/RealisticSwapManagerHarness.sol:198.
    function _hook() internal view returns (MemeverseUniswapHook) {
        return MemeverseUniswapHook(address(key.hooks));
    }

    /// @dev Wraps StateLibrary.getSlot0 so subclasses (which do not re-declare the `using` for IPoolManager)
    ///      can read real V4 slot0 via the inherited base.
    function _slot0(PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(id);
    }

    function _addLiquidity(address recipient) internal returns (uint128 liquidity) {
        (liquidity,) = _hook()
            .addLiquidityCore(
                IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: recipient
            })
            );
    }

    function _matureLaunchWindow() internal {
        vm.warp(block.timestamp + 900);
    }

    function _validExecutionPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // ── Rollback / fee-growth helpers (read only hook storage + ERC20 balances, not the manager) ──

    struct RollbackSnapshot {
        uint256 payer0;
        uint256 payer1;
        uint256 treasury0;
        uint256 treasury1;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
        uint256 weightedVolume0;
        uint256 ewVWAPX18;
        uint160 volAnchorSqrtPriceX96;
        uint24 volDeviationAccumulator;
        uint24 shortImpactPpm;
    }

    function _rollbackSnapshot(address payer) internal view returns (RollbackSnapshot memory snapshot) {
        snapshot.payer0 = token0.balanceOf(payer);
        snapshot.payer1 = token1.balanceOf(payer);
        snapshot.treasury0 = token0.balanceOf(treasury);
        snapshot.treasury1 = token1.balanceOf(treasury);
        (, snapshot.fee0PerShare, snapshot.fee1PerShare) = _hook().poolInfo(poolId);
        (
            snapshot.weightedVolume0,,
            snapshot.ewVWAPX18,
            snapshot.volAnchorSqrtPriceX96,,
            snapshot.volDeviationAccumulator,,
            snapshot.shortImpactPpm,
        ) = lens.poolDynamicFeeState(_hook(), poolId);
    }

    function _assertRollback(address payer, RollbackSnapshot memory before_) internal view {
        assertEq(token0.balanceOf(payer), before_.payer0, "payer token0 rollback");
        assertEq(token1.balanceOf(payer), before_.payer1, "payer token1 rollback");
        assertEq(token0.balanceOf(treasury), before_.treasury0, "treasury token0 rollback");
        assertEq(token1.balanceOf(treasury), before_.treasury1, "treasury token1 rollback");

        (, uint256 fee0PerShareAfter, uint256 fee1PerShareAfter) = _hook().poolInfo(poolId);
        assertEq(fee0PerShareAfter, before_.fee0PerShare, "fee0 per share rollback");
        assertEq(fee1PerShareAfter, before_.fee1PerShare, "fee1 per share rollback");

        (
            uint256 weightedVolume0After,,
            uint256 ewVWAPX18After,
            uint160 volAnchorSqrtPriceX96After,,
            uint24 volDeviationAccumulatorAfter,,
            uint24 shortImpactPpmAfter,
        ) = lens.poolDynamicFeeState(_hook(), poolId);
        assertEq(weightedVolume0After, before_.weightedVolume0, "weightedVolume0 rollback");
        assertEq(ewVWAPX18After, before_.ewVWAPX18, "ewvwap rollback");
        assertEq(volAnchorSqrtPriceX96After, before_.volAnchorSqrtPriceX96, "vol anchor rollback");
        assertEq(volDeviationAccumulatorAfter, before_.volDeviationAccumulator, "vol deviation rollback");
        assertEq(shortImpactPpmAfter, before_.shortImpactPpm, "short impact rollback");
    }

    /// @dev Uses the production hook's cached LP total supply (the same slot the hook divides by
    ///      when growing fee-per-share) instead of an LP-token balance proxy. The single-LP setup
    ///      makes them numerically equal, but reading the cached slot is the source of truth and
    ///      stays correct if the supply derivation ever diverges from a 1:1 LP-token mint.
    function _expectedLpFeeGrowth(uint256 lpFeeAmount) internal view returns (uint256) {
        uint256 activeSupply = getCachedLpTotalSupplyForTest(address(key.hooks), poolId);
        return lpFeeAmount == 0 ? 0 : (lpFeeAmount * FEE_GROWTH_Q128) / activeSupply;
    }

    /// @dev Blocks public swaps through the production setter instead of writing storage directly.
    ///      The test contract becomes the launcher so the onlyLauncher guard and pool-key derivation
    ///      are exercised on the real hook path.
    function _blockPublicSwap(uint256 futureTimestamp) internal {
        _hook().setLauncher(address(this));
        _hook().setPublicSwapResumeTime(address(token0), address(token1), uint40(futureTimestamp));
    }
}
