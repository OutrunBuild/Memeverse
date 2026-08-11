// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title Swap router settlement treasury accounting invariant
/// @notice Invariant fuzz test over the native router.swap's three entrypoints (regular swap,
///         public-swap-marker swap, and spoof public-swap attempts), asserting the treasury's
///         token0 balance always equals the sum of per-call balance deltas accumulated by each
///         handler. This invariant really protects treasury accounting consistency: ensuring no
///         path outside the handlers transfers funds into the treasury.
/// @dev Known sensitivity boundary (intentionally recorded, not a defect):
///      each handler's expected treasury fee is accumulated from `balanceOf(treasury) - treasuryBefore`.
///      Because the treasury starts at 0 and no path outside the handlers funds it, the top-level
///      invariant `balanceOf(treasury) == Σ(delta)` degenerates into a mathematical identity, so it
///      is blind to systemic fee errors (e.g. a wrong `FeeMath.PROTOCOL_FEE_SHARE_BPS` constant, or
///      a shared `OrdinarySwapMath.deriveFeeSplit -> FeeMath.splitFeeBps` formula bug) — quote and
///      execution paths share the same fee math, so errors shift both in lockstep and go unnoticed.
///      The per-call `assertEq(treasuryDelta, quote.estimatedProtocolFeeAmount)` likewise only covers
///      divergence between the quote and execution paths and cannot catch shared fee-math errors.
///      Actual coverage of fee-amount correctness is borne by hardcoded-amount unit tests:
///      `test/swap/MemeverseSwapRouter.t.sol` and `test/swap/FeeMath.t.sol`.
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract RouterSettlementAccountingHandler is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MemeverseSwapRouter internal router;
    MemeverseUniswapHook internal immutable hook;
    MockERC20 internal immutable token0;
    address internal immutable treasury;
    PoolKey internal key;

    uint256 public expectedRegularTreasuryFee;
    uint256 public expectedMarkerTreasuryFee;

    constructor(MemeverseUniswapHook _hook, MockERC20 _token0, address _treasury, PoolKey memory _key) {
        hook = _hook;
        token0 = _token0;
        treasury = _treasury;
        key = _key;
    }

    /// @notice Binds the deployed router to the accounting handler.
    /// @dev One-time wiring step used by the invariant harness.
    /// @param _router Router under test.
    function setRouter(MemeverseSwapRouter _router) external {
        require(address(router) == address(0), "router already set");
        router = _router;
        token0.approve(address(router), type(uint256).max);
    }

    /// @notice Advances time for the invariant harness.
    /// @dev Used to explore fee decay and launch window transitions.
    /// @param deltaSeed Fuzzed time delta seed.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 40 minutes));
    }

    /// @notice Executes a regular routed swap and records treasury fee accounting.
    /// @dev Exercises the non-settlement path under invariant fuzzing.
    /// @param amountSeed Fuzzed swap amount seed.
    function regularSwap(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});

        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);

        // Open an account session on the hook for this handler call so the routed swap passes the session gate.
        hook.beginAccountSession();
        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, amount, bytes("regular"));
        hook.endAccountSession();

        assertLt(delta.amount0(), 0, "regular delta0");
        assertGt(delta.amount1(), 0, "regular delta1");

        uint256 treasuryDelta = token0.balanceOf(treasury) - treasuryBefore;
        assertEq(treasuryDelta, quote.estimatedProtocolFeeAmount, "regular protocol fee");
        // Self-referential: expected accumulates the actual treasury balance delta, blind to systemic fee errors (see the sensitivity-boundary note in the file header).
        expectedRegularTreasuryFee += treasuryDelta;
    }

    /// @notice Executes a public-swap-marker routed swap and records treasury accounting.
    /// @dev Differs from `regularSwap` only in the hookData marker string (`bytes("public-swap")`
    ///      vs. `bytes("regular")`). The marker is a non-settlement path: it does NOT call
    ///      `executePreorderSettlement`, and since both markers are < 20 bytes, `_decodeReferrer`
    ///      returns `address(0)` for both — no referral/rebate behavior is exercised either.
    ///      Named `markerSwap` (not `settlementSwap`) so the invariant name reflects the path it runs.
    /// @param amountSeed Fuzzed swap amount seed.
    function markerSwap(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);

        // Open an account session on the hook for this handler call so the routed swap passes the session gate.
        hook.beginAccountSession();
        BalanceDelta delta = router.swap(key, params, address(this), block.timestamp, 0, amount, bytes("public-swap"));
        hook.endAccountSession();

        assertLt(delta.amount0(), 0, "marker delta0");
        assertGt(delta.amount1(), 0, "marker delta1");

        uint256 treasuryDelta = token0.balanceOf(treasury) - treasuryBefore;
        assertEq(treasuryDelta, quote.estimatedProtocolFeeAmount, "marker protocol fee");
        // Self-referential: expected accumulates the actual treasury balance delta, blind to systemic fee errors (see the sensitivity-boundary note in the file header).
        expectedMarkerTreasuryFee += treasuryDelta;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract RouterSettlementSpoofHandler is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MemeverseSwapRouter internal immutable router;
    MemeverseUniswapHook internal immutable hook;
    MockERC20 internal immutable token0;
    address internal immutable treasury;
    PoolKey internal key;

    uint256 public expectedSpoofTreasuryFee;

    constructor(
        MemeverseSwapRouter _router,
        MemeverseUniswapHook _hook,
        MockERC20 _token0,
        address _treasury,
        PoolKey memory _key
    ) {
        router = _router;
        hook = _hook;
        token0 = _token0;
        treasury = _treasury;
        key = _key;
        token0.approve(address(router), type(uint256).max);
    }

    /// @notice Advances time for the spoof handler.
    /// @dev Keeps spoof attempts independent from a fixed timestamp.
    /// @param deltaSeed Fuzzed time delta seed.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 40 minutes));
    }

    /// @notice Executes a public-swap-marker public swap from an arbitrary caller.
    /// @dev Marker payload is treated as regular hook data; named `spoofSettlement` because it
    ///      attempts to mimic the marker path of `markerSwap` from an external caller.
    /// @param amountSeed Fuzzed swap amount seed.
    function spoofSettlement(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);

        // Open a session on the hook for this handler call so the routed swap passes the session gate. The
        // session is closed after the try/catch whether or not the swap reverted.
        hook.beginAccountSession();
        try router.swap(key, params, address(this), block.timestamp, 0, amount, bytes("public-swap")) returns (
            BalanceDelta delta
        ) {
            assertLt(delta.amount0(), 0, "spoof delta0");
            assertGt(delta.amount1(), 0, "spoof delta1");
            uint256 treasuryDelta = token0.balanceOf(treasury) - treasuryBefore;
            assertEq(treasuryDelta, quote.estimatedProtocolFeeAmount, "spoof protocol fee");
            // Self-referential: accumulates the actual treasury balance delta (see the sensitivity-boundary note in the file header).
            expectedSpoofTreasuryFee += treasuryDelta;
        } catch {}
        hook.endAccountSession();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract MemeverseSwapRouterSettlementInvariantTest is StdInvariant, Test, HookStorageHelper {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    PoolKey internal key;

    RouterSettlementAccountingHandler internal accountingHandler;
    RouterSettlementSpoofHandler internal spoofHandler;

    function _deployHookProxy(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Deploy the real MemeverseUniswapHook behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHook(hookProxy);
    }

    /// @notice Deploys the router settlement invariant harness.
    /// @dev Wires router, hook, handlers, and seeded balances before invariant fuzzing.
    function setUp() external {
        manager = new MockPoolManagerForRouterTest();
        treasury = makeAddr("treasury");
        hook = _deployHookProxy(IPoolManager(address(manager)), address(this), treasury);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setProtocolFeeCurrency(key.currency0, true);

        accountingHandler = new RouterSettlementAccountingHandler(hook, token0, treasury, key);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0xBEEF))
        );
        hook.setPoolInitializer(address(router));
        accountingHandler.setRouter(router);
        spoofHandler = new RouterSettlementSpoofHandler(router, hook, token0, treasury, key);
        token0.mint(address(accountingHandler), 1_000_000 ether);
        token0.mint(address(spoofHandler), 1_000_000 ether);

        targetContract(address(accountingHandler));
        targetContract(address(spoofHandler));
    }

    /// @notice Ensures treasury fees equal the sum of regular and marker expectations.
    /// @dev Guards end-to-end accounting across both router paths (regular + public-swap-marker).
    function invariant_treasuryAccountingMatchesRegularPlusMarkerPaths() external view {
        assertEq(
            token0.balanceOf(treasury),
            accountingHandler.expectedRegularTreasuryFee() + accountingHandler.expectedMarkerTreasuryFee()
                + spoofHandler.expectedSpoofTreasuryFee(),
            "treasury accounting"
        );
    }
}
