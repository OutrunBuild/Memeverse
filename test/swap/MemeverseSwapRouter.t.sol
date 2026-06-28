// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {LiquidityAmounts} from "../../src/swap/libraries/LiquidityAmounts.sol";
import {LiquidityQuote} from "../../src/swap/libraries/LiquidityQuote.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {IMemeverseDynamicFeeEngine} from "../../src/swap/interfaces/IMemeverseDynamicFeeEngine.sol";
import {IMemeverseUniswapHookLens} from "../../src/swap/interfaces/IMemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";

import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract DirectProtectedSwapCaller {
    MockPoolManagerForRouterTest internal immutable manager;

    constructor(MockPoolManagerForRouterTest _manager) {
        manager = _manager;
    }

    function swapDirect(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        result = abi.encode(manager.swap(key, params, ""));
    }
}

/// @dev Test boundary:
/// - These cases lock router-side behavior under the local manager mock.
/// - They do not establish real market execution, partial-fill economics, rollback guarantees,
///   or fee-side correctness beyond this deterministic harness.
contract MemeverseSwapRouterTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant FULL_RANGE_MIN_SQRT_PRICE_X96 = 4_310_618_292;
    uint160 internal constant FULL_RANGE_MAX_SQRT_PRICE_X96 =
        1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;
    uint256 internal constant ALICE_PK = 0xA11CE;
    bytes4 internal constant PUBLIC_SWAP_DISABLED_SELECTOR = bytes4(keccak256("PublicSwapDisabled()"));
    bytes4 internal constant UNAUTHORIZED_LAUNCHER_SELECTOR = bytes4(keccak256("UnauthorizedLauncher()"));

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MemeverseUniswapHookLens internal lens;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    address internal alice;
    PoolKey internal key;
    PoolId internal poolId;

    function _setPublicSwapResumeTime(address targetHook, address tokenA, address tokenB, uint40 resumeTime)
        internal
        returns (bool ok, bytes memory data)
    {
        return targetHook.call(
            abi.encodeWithSignature("setPublicSwapResumeTime(address,address,uint40)", tokenA, tokenB, resumeTime)
        );
    }

    function _readPublicSwapResumeTime(address targetHook, PoolId targetPoolId)
        internal
        view
        returns (bool ok, uint40 resumeTime)
    {
        (bool success, bytes memory data) =
            targetHook.staticcall(abi.encodeWithSignature("publicSwapResumeTime(bytes32)", targetPoolId));
        if (!success || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint40)));
    }

    function _deployHookProxyForManager(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        (address hookProxy,) = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHook(hookProxy);
    }

    /// @notice Deploys the mock manager, hook, router, and test tokens.
    /// @dev Seeds balances and approvals used throughout the router test suite.
    function setUp() public {
        manager = new MockPoolManagerForRouterTest();
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_PK);
        hook = _deployHookProxyForManager(IPoolManager(address(manager)), address(this), treasury);
        lens = new MemeverseUniswapHookLens(IPoolManager(address(manager)));
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            IMemeverseUniswapHookLens(address(lens)),
            IPermit2(address(0xBEEF))
        );

        MockERC20 tokenA = new MockERC20("Token0", "TK0", 18);
        MockERC20 tokenB = new MockERC20("Token1", "TK1", 18);
        // `token0` and `token1` mean Uniswap currency order here, not deployment order.
        // Proxy deployment changes can move token addresses, so sort once before building the PoolKey.
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(router), type(uint256).max);

        key = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        poolId = key.toId();
        hook.setLauncher(address(this));
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setPoolInitializer(address(router));
        seedActiveLiquiditySharesForTest(address(hook), poolId, address(this), 1e18);
    }

    function _initializePoolDirect(PoolKey memory targetKey, uint160 sqrtPriceX96) internal {
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(targetKey, sqrtPriceX96);
        manager.initialize(targetKey, sqrtPriceX96);
        hook.setPoolInitializer(address(router));
    }

    /// @notice Configures which currency the hook should collect protocol fees in.
    /// @dev Helper invoked by tests before swaps to keep protocol-fee context consistent.
    function _setProtocolFeeCurrency(Currency feeCurrency) internal {
        hook.setProtocolFeeCurrency(feeCurrency, true);
    }

    /// @notice Verifies router quotes are delegated through the configured hook lens.
    function testQuoteSwap_UsesConfiguredHookLens() external {
        _setProtocolFeeCurrency(key.currency0);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});

        IMemeverseUniswapHook.SwapQuote memory routerQuote = router.quoteSwap(key, params, address(this));
        IMemeverseUniswapHook.SwapQuote memory lensQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));

        assertEq(routerQuote.feeBps, lensQuote.feeBps, "fee bps");
        assertEq(routerQuote.estimatedUserInputAmount, lensQuote.estimatedUserInputAmount, "user input");
        assertEq(routerQuote.estimatedUserOutputAmount, lensQuote.estimatedUserOutputAmount, "user output");
        assertEq(routerQuote.estimatedProtocolFeeAmount, lensQuote.estimatedProtocolFeeAmount, "protocol fee");
        assertEq(routerQuote.estimatedLpFeeAmount, lensQuote.estimatedLpFeeAmount, "lp fee");
        assertEq(routerQuote.protocolFeeOnInput, lensQuote.protocolFeeOnInput, "fee side");
    }

    /// @notice Verifies the router constructor rejects a lens address with no deployed code.
    function testConstructor_RevertsWhenLensHasNoCode() external {
        vm.expectRevert(abi.encodeWithSelector(IMemeverseSwapRouter.HookLensCodeNotReady.selector, address(0xCAFE)));
        new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            IMemeverseUniswapHookLens(address(0xCAFE)),
            IPermit2(address(0xBEEF))
        );
    }

    /// @notice Verifies the router constructor rejects a lens bound to a different PoolManager.
    function testConstructor_RevertsWhenLensUsesDifferentPoolManager() external {
        MockPoolManagerForRouterTest wrongManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHookLens wrongLens = new MemeverseUniswapHookLens(IPoolManager(address(wrongManager)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseSwapRouter.HookLensPoolManagerMismatch.selector, address(manager), address(wrongManager)
            )
        );
        new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            IMemeverseUniswapHookLens(address(wrongLens)),
            IPermit2(address(0xBEEF))
        );
    }

    /// @notice Progresses the block timestamp past the launch window.
    /// @dev Ensures tests can trigger post-launch behavior without waiting in real time.
    function _matureLaunchWindow() internal {
        vm.warp(block.timestamp + 900);
    }

    function _validExecutionPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _dynamicPoolKeyForHook(address hookAddress, Currency currency0, Currency currency1)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(hookAddress)
        });
    }

    /// @notice Verifies explicit launcher binding rejects the zero address.
    /// @dev Launch settlement authorization now depends only on the launcher binding.
    function testSetLauncher_RevertsOnZeroAddress() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setLauncher(address(0));
    }

    /// @notice Verifies swaps reject pool keys wired to a different hook address.
    /// @dev Covers router validation that only its configured hook may be used.
    function testSwapReverts_WhenHookAddressDoesNotMatchRouterHook() external {
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0x1234))
        });

        vm.expectRevert(IMemeverseSwapRouter.InvalidHook.selector);
        router.swap(
            invalidKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Verifies swaps reject zero `amountSpecified`.
    /// @dev Covers router validation for meaningless swap requests.
    function testSwapReverts_WhenAmountSpecifiedIsZero() external {
        vm.expectRevert(IMemeverseSwapRouter.SwapAmountCannotBeZero.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Covers the local manager revert surface for execution swaps that pass a zero price limit.
    /// @dev Locks that the router forwards `sqrtPriceLimitX96` into the mock execution path instead of silently bypassing it.
    function testSwapReverts_WhenExecutionPriceLimitIsZero() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        manager.setEnforceV4PriceLimitValidation(true);

        vm.expectRevert(abi.encodeWithSelector(MockPoolManagerForRouterTest.PriceLimitOutOfBounds.selector, uint160(0)));
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Verifies exact-output swaps require a non-zero `amountInMaximum`.
    /// @dev Prevents exact-output callers from omitting the user input budget.
    function testSwapReverts_WhenExactOutputOmitsAmountInMaximum() external {
        vm.expectRevert(IMemeverseSwapRouter.AmountInMaximumRequired.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            0,
            ""
        );
    }

    /// @notice Verifies setting the treasury to the zero address reverts.
    /// @dev Covers owner configuration validation.
    function testSetTreasury_RevertsOnZeroAddress() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setTreasury(address(0));
    }

    /// @notice Verifies native protocol-fee pools now fail before reaching treasury handling.
    function testSwapReverts_WhenProtocolFeePoolUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert();
        router.swap(
            nativeKey,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );
    }

    /// @notice Verifies successful swaps record an anti-snipe attempt and execute.
    /// @dev Covers the standard exact-input happy path.
    function testSwapPass_RecordsAttemptAndExecutes() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        assertLt(token0.balanceOf(address(this)), balance0Before, "token0 spent");
        assertGt(token1.balanceOf(address(this)), balance1Before, "token1 received");
        assertGt(token0.balanceOf(treasury), treasury0Before, "treasury collected token0");
        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
    }

    /// @notice Verifies direct ERC20 swaps enter the manager unlock with router-prefunded input.
    /// @dev The simplified shared `_swap()` core should use router balance for regular swaps too.
    function testSwap_RegularPathUsesRouterAsUnlockPayer() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();

        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        assertEq(manager.lastUnlockPayer(), address(router), "router should prefund regular swaps");
        assertEq(token0.balanceOf(address(router)), 0, "router should not retain input");
    }

    /// @notice Verifies the regular ERC20 swap path stays below the current gas ceiling.
    /// @dev This captures the router-only gas cleanup target without changing swap semantics.
    function testSwap_RegularPathGasStaysBelowCeiling() external {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();

        uint256 gasBefore = gasleft();
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(int256(delta.amount0()), 0, "delta0");
        assertGt(int256(delta.amount1()), 0, "delta1");
        assertLt(gasUsed, 590_000, "swap gas ceiling");
    }

    /// @notice Verifies routed swaps do not pay for a redundant launch-fee quote round-trip.
    /// @dev A successful swap should read the pool slot0 storage once for quote math and once for state update.
    function testSwapPass_AntiSnipePathAvoidsRedundantFailureQuoteRead() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));

        vm.expectCall(
            address(manager), abi.encodeCall(MockPoolManagerForRouterTest.extsload, (poolStateSlot)), uint64(2)
        );

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
    }

    /// @notice Verifies router swaps revert during the post-unlock protection window.
    /// @dev Protection now comes from hook-local pool state, not a launcher pair verdict.
    function testSwap_RevertsDuringPostUnlockProtectionWindow() external {
        MockPoolManagerForRouterTest guardedManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHook guardedHook =
            _deployHookProxyForManager(IPoolManager(address(guardedManager)), address(this), treasury);
        MemeverseSwapRouter guardedRouter = new MemeverseSwapRouter(
            IPoolManager(address(guardedManager)),
            IMemeverseUniswapHook(address(guardedHook)),
            new MemeverseUniswapHookLens(IPoolManager(address(guardedManager))),
            IPermit2(address(0xBEEF))
        );
        PoolKey memory guardedKey = _dynamicPoolKeyForHook(
            address(guardedHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );

        guardedHook.setLauncher(address(this));
        guardedHook.setPoolInitializer(address(this));
        guardedHook.authorizePoolInitialization(guardedKey, SQRT_PRICE_1_1);
        guardedManager.initialize(guardedKey, SQRT_PRICE_1_1);
        guardedHook.setPoolInitializer(address(guardedRouter));
        guardedHook.setProtocolFeeCurrency(guardedKey.currency0, true);
        (bool setOk, bytes memory setData) = _setPublicSwapResumeTime(
            address(guardedHook), address(token0), address(token1), uint40(block.timestamp + 1 hours)
        );
        assertTrue(setOk, string(setData));
        token0.mint(address(guardedManager), 1_000_000 ether);
        token1.mint(address(guardedManager), 1_000_000 ether);
        token0.approve(address(guardedRouter), type(uint256).max);
        token1.approve(address(guardedRouter), type(uint256).max);

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        guardedRouter.swap(
            guardedKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Verifies public-swap protection blocks swaps until resumeTime and allows them after.
    function testSwap_PublicProtectionWindowBlocksUntilResumeTime() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        hook.setLauncher(address(this));

        uint40 resumeTime = uint40(block.timestamp + 24 hours);
        (bool setOk, bytes memory setData) =
            _setPublicSwapResumeTime(address(hook), address(token0), address(token1), resumeTime);
        assertTrue(setOk, string(setData));

        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        vm.warp(resumeTime);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        assertLt(delta.amount0(), 0, "post-resume swap input");
        assertGt(delta.amount1(), 0, "post-resume swap output");
    }

    /// @notice Verifies a blocked pool does not leak protection to unrelated pools.
    /// @dev `publicSwapResumeTime == 0` must remain a no-op for other pool ids.
    function testSwap_LocalProtectionBlocksOnlyTargetPool() external {
        MockPoolManagerForRouterTest guardedManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHook guardedHook =
            _deployHookProxyForManager(IPoolManager(address(guardedManager)), address(this), treasury);
        MemeverseSwapRouter guardedRouter = new MemeverseSwapRouter(
            IPoolManager(address(guardedManager)),
            IMemeverseUniswapHook(address(guardedHook)),
            new MemeverseUniswapHookLens(IPoolManager(address(guardedManager))),
            IPermit2(address(0xBEEF))
        );
        MockERC20 otherToken = new MockERC20("Token2", "TK2", 18);
        otherToken.mint(address(this), 1_000_000 ether);
        otherToken.mint(address(guardedManager), 1_000_000 ether);

        PoolKey memory blockedKey = _dynamicPoolKeyForHook(
            address(guardedHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );
        PoolKey memory openKey = _dynamicPoolKeyForHook(
            address(guardedHook), Currency.wrap(address(otherToken)), Currency.wrap(address(token1))
        );

        guardedHook.setLauncher(address(this));
        guardedHook.setPoolInitializer(address(this));
        guardedHook.authorizePoolInitialization(blockedKey, SQRT_PRICE_1_1);
        guardedManager.initialize(blockedKey, SQRT_PRICE_1_1);
        guardedHook.authorizePoolInitialization(openKey, SQRT_PRICE_1_1);
        guardedManager.initialize(openKey, SQRT_PRICE_1_1);
        guardedHook.setPoolInitializer(address(guardedRouter));
        seedActiveLiquiditySharesForTest(address(guardedHook), blockedKey.toId(), address(this), 1e18);
        seedActiveLiquiditySharesForTest(address(guardedHook), openKey.toId(), address(this), 1e18);
        guardedHook.setProtocolFeeCurrency(blockedKey.currency0, true);
        guardedHook.setProtocolFeeCurrency(openKey.currency0, true);
        (bool setOk, bytes memory setData) = _setPublicSwapResumeTime(
            address(guardedHook), address(token0), address(token1), uint40(block.timestamp + 1 hours)
        );
        assertTrue(setOk, string(setData));
        (bool readOk, uint40 resumeTime) = _readPublicSwapResumeTime(address(guardedHook), blockedKey.toId());
        assertTrue(readOk, "resume getter missing");
        assertEq(resumeTime, uint40(block.timestamp + 1 hours), "resume time stored");

        token0.mint(address(guardedManager), 1_000_000 ether);
        token1.mint(address(guardedManager), 1_000_000 ether);
        token0.approve(address(guardedRouter), type(uint256).max);
        token1.approve(address(guardedRouter), type(uint256).max);
        otherToken.approve(address(guardedRouter), type(uint256).max);

        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        guardedRouter.swap(
            blockedKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );

        BalanceDelta openDelta = guardedRouter.swap(
            openKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
        assertLt(openDelta.amount0(), 0, "open pool should swap");
        assertGt(openDelta.amount1(), 0, "open pool output");
    }

    /// @notice Verifies explicit preorder settlement can only be initiated by the configured launcher.
    /// @dev Settlement no longer routes through router marker swap mode.
    function testExecutePreorderSettlement_RevertsWhenCallerIsNotLauncher() external {
        _setProtocolFeeCurrency(key.currency0);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        hook.setLauncher(address(this));

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.Unauthorized.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies explicit preorder settlement uses fixed 1% economics.
    /// @dev Confirms the treasury receives the 35% protocol slice of the fixed fee.
    function testExecutePreorderSettlement_UsesFixedOnePercentFee() external {
        _setProtocolFeeCurrency(key.currency0);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        uint256 treasury0Before = token0.balanceOf(treasury);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);

        IMemeverseUniswapHook.SwapQuote memory quoteAtLaunch = router.quoteSwap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this)
        );
        assertEq(quoteAtLaunch.feeBps, 5000, "public launch fee");

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
        assertEq(token0.balanceOf(treasury) - treasury0Before, 0.35 ether, "fixed 1% protocol fee");
    }

    /// @notice Verifies explicit preorder settlement on an output-fee pool only collects the output-side protocol fee once.
    /// @dev The treasury/output balances should match a single 35 bps output fee on the post-LP-fee swap output.
    function testExecutePreorderSettlement_OutputSideProtocolFeeCollectedExactlyOnce() external {
        _setProtocolFeeCurrency(key.currency1);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);

        uint256 sender1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertEq(token0.balanceOf(treasury) - treasury0Before, 0, "no input-side protocol fee");
        assertEq(token1.balanceOf(treasury) - treasury1Before, 0.1738625 ether, "single output-side protocol fee");
        assertEq(token1.balanceOf(address(this)) - sender1Before, 49.5011375 ether, "recipient gets net output once");
        assertEq(delta.amount0(), -int128(int256(99.35 ether)), "delta0 tracks post-LP-fee swap input");
        assertEq(delta.amount1(), int128(int256(49.5011375 ether)), "delta1 reduced by one output-side fee");
    }

    /// @notice Verifies changing launch-fee floor does not change explicit settlement pricing.
    /// @dev Settlement remains fixed-fee while public swaps still use launch fee schedule.
    function testExecutePreorderSettlement_IgnoresConfigurableLaunchFeeFloor() external {
        _setProtocolFeeCurrency(key.currency0);
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 4000, minFeeBps: 300, decayDurationSeconds: 900})
        );
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        uint256 treasury0Before = token0.balanceOf(treasury);

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
        assertEq(token0.balanceOf(treasury) - treasury0Before, 0.35 ether, "settlement remains fixed 1%");
    }

    /// @notice Verifies explicit settlement updates dynamic-fee state even though the pool-manager self-call skips hook callbacks.
    /// @dev The immediate follow-up quote should observe carried short/volatility state, not a pristine fee engine.
    function testExecutePreorderSettlement_UpdatesDynamicFeeStateAndSubsequentQuote() external {
        _setProtocolFeeCurrency(key.currency0);
        hook.setLauncher(address(this));
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 100, minFeeBps: 100, decayDurationSeconds: 1})
        );
        token0.approve(address(hook), type(uint256).max);

        uint160 postSettlementPrice = uint160((uint256(SQRT_PRICE_1_1) * 120) / 100);
        manager.setNextSwapSqrtPriceX96(poolId, postSettlementPrice);

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        (
            uint256 weightedVolume0,
            uint256 weightedPriceVolume0,
            uint256 ewVWAPX18,,,
            uint24 volDeviationAccumulator,,
            uint24 shortImpactPpm,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

        assertGt(weightedVolume0, 0, "weighted volume");
        assertGt(weightedPriceVolume0, 0, "weighted price volume");
        assertGt(ewVWAPX18, 0, "ewvwap");
        assertGt(volDeviationAccumulator, 0, "volatility accumulator");
        assertGt(shortImpactPpm, 0, "short impact");

        MockPoolManagerForRouterTest pristineManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHook pristineHook =
            _deployHookProxyForManager(IPoolManager(address(pristineManager)), address(this), treasury);
        PoolKey memory pristineKey = _dynamicPoolKeyForHook(
            address(pristineHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );
        pristineHook.setPoolInitializer(address(this));
        pristineHook.authorizePoolInitialization(pristineKey, postSettlementPrice);
        pristineManager.initialize(pristineKey, postSettlementPrice);
        seedActiveLiquiditySharesForTest(address(pristineHook), pristineKey.toId(), address(this), 1e18);
        pristineHook.setProtocolFeeCurrency(pristineKey.currency0, true);
        pristineHook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 100, minFeeBps: 100, decayDurationSeconds: 1})
        );
        MemeverseUniswapHookLens pristineLens = new MemeverseUniswapHookLens(IPoolManager(address(pristineManager)));

        SwapParams memory followUpParams =
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        IMemeverseUniswapHook.SwapQuote memory settledQuote = router.quoteSwap(key, followUpParams, address(this));
        IMemeverseUniswapHook.SwapQuote memory pristineQuote = pristineLens.quoteSwap(
            IMemeverseUniswapHook(address(pristineHook)), pristineKey, followUpParams, address(this)
        );

        assertGt(settledQuote.feeBps, pristineQuote.feeBps, "settlement quote should carry dynamic state");
    }

    /// @notice Verifies direct/custom swap paths are also blocked during the protection window.
    /// @dev This adversarial path bypasses the router and proves the hook gate is the true enforcement layer.
    function testDirectPoolManagerSwap_RevertsDuringPostUnlockProtectionWindow() external {
        MockPoolManagerForRouterTest guardedManager = new MockPoolManagerForRouterTest();
        MemeverseUniswapHook guardedHook =
            _deployHookProxyForManager(IPoolManager(address(guardedManager)), address(this), treasury);
        new MemeverseSwapRouter(
            IPoolManager(address(guardedManager)),
            IMemeverseUniswapHook(address(guardedHook)),
            new MemeverseUniswapHookLens(IPoolManager(address(guardedManager))),
            IPermit2(address(0xBEEF))
        );
        PoolKey memory guardedKey = _dynamicPoolKeyForHook(
            address(guardedHook), Currency.wrap(address(token0)), Currency.wrap(address(token1))
        );
        DirectProtectedSwapCaller directCaller = new DirectProtectedSwapCaller(guardedManager);

        guardedHook.setLauncher(address(this));
        guardedHook.setPoolInitializer(address(this));
        guardedHook.authorizePoolInitialization(guardedKey, SQRT_PRICE_1_1);
        guardedManager.initialize(guardedKey, SQRT_PRICE_1_1);
        guardedHook.setProtocolFeeCurrency(guardedKey.currency0, true);
        (bool setOk, bytes memory setData) = _setPublicSwapResumeTime(
            address(guardedHook), address(token0), address(token1), uint40(block.timestamp + 1 hours)
        );
        assertTrue(setOk, string(setData));
        token0.mint(address(guardedManager), 1_000_000 ether);
        token1.mint(address(guardedManager), 1_000_000 ether);

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        vm.expectRevert(PUBLIC_SWAP_DISABLED_SELECTOR);
        directCaller.swapDirect(
            guardedKey, SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit})
        );
    }

    /// @notice Covers the basic one-for-zero exact-input routing branch under the local manager harness.
    /// @dev This is plumbing coverage for the routed mock path, not proof of production execution quality.
    function testSwapPass_OneForZeroExactInputExecutes() external {
        _setProtocolFeeCurrency(key.currency1);
        _matureLaunchWindow();
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 101) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        assertGt(token0.balanceOf(address(this)), balance0Before, "token0 received");
        assertLt(token1.balanceOf(address(this)), balance1Before, "token1 spent");
        assertGt(token1.balanceOf(treasury), treasury1Before, "treasury collected token1");
        assertGt(delta.amount0(), 0, "delta0");
        assertLt(delta.amount1(), 0, "delta1");
    }

    /// @notice Covers the mock harness branch for zero-for-one exact-input output-side fee accounting.
    /// @dev Locks router-side handling under deterministic local manager deltas.
    function testSwapPass_ZeroForOneExactInput_OutputSideProtocolFee() external {
        _setProtocolFeeCurrency(key.currency1);
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            20 ether,
            100 ether,
            ""
        );

        assertGt(token1.balanceOf(address(this)), balance1Before, "token1 received");
        assertLt(delta.amount1(), int128(int256(50 ether)), "output reduced by output-side fee");
        assertGt(token1.balanceOf(treasury), treasury1Before, "treasury collected token1");
    }

    /// @notice Covers the mock harness branch for one-for-zero exact-input output-side fee accounting.
    /// @dev Locks router-side handling under deterministic local manager deltas.
    function testSwapPass_OneForZeroExactInput_OutputSideProtocolFee() external {
        _setProtocolFeeCurrency(key.currency0);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 101) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            20 ether,
            100 ether,
            ""
        );

        assertGt(token0.balanceOf(address(this)), balance0Before, "token0 received");
        assertLt(delta.amount0(), int128(int256(50 ether)), "output reduced by output-side fee");
        assertGt(token0.balanceOf(treasury), treasury0Before, "treasury collected token0");
    }

    /// @notice Covers the zero-for-one exact-output branch with input-side fee handling under the local manager harness.
    /// @dev This locks router bookkeeping against deterministic mock deltas rather than proving real execution economics.
    function testSwapPass_ZeroForOneExactOutputExecutesAndChargesInputFee() external {
        _setProtocolFeeCurrency(key.currency0);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );

        assertEq(token1.balanceOf(address(this)) - balance1Before, 100 ether, "exact output received");
        assertGt(balance0Before - token0.balanceOf(address(this)), 200 ether, "input includes fee");
        assertGt(token0.balanceOf(treasury), treasury0Before, "treasury collected token0");
        assertEq(delta.amount1(), int128(int256(100 ether)), "delta1");
        assertLt(delta.amount0(), -int128(int256(200 ether)), "delta0 fee-adjusted");
    }

    /// @notice Verifies exact-output ERC20 swaps refund unused prefunded input.
    /// @dev The router should prefund `amountInMaximum`, spend only the realized input, then return the remainder.
    function testSwap_ExactOutputRefundsUnusedPrefundedInput() external {
        _setProtocolFeeCurrency(key.currency0);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 amountInMaximum = 500 ether;

        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            amountInMaximum,
            ""
        );

        assertEq(manager.lastUnlockPayer(), address(router), "router should pay exact-output input");
        assertEq(balance0Before - token0.balanceOf(address(this)), 300 ether, "unused input refunded");
        assertEq(token0.balanceOf(address(router)), 0, "router should not retain refunded input");
    }

    /// @notice Covers the one-for-zero exact-output branch with input-side fee handling under the local manager harness.
    /// @dev This locks router bookkeeping against deterministic mock deltas rather than proving real execution economics.
    function testSwapPass_OneForZeroExactOutputExecutesAndChargesInputFee() external {
        _setProtocolFeeCurrency(key.currency1);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 101) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );

        assertEq(token0.balanceOf(address(this)) - balance0Before, 100 ether, "exact output received");
        assertGt(balance1Before - token1.balanceOf(address(this)), 200 ether, "input includes fee");
        assertGt(token1.balanceOf(treasury), treasury1Before, "treasury collected token1");
        assertEq(delta.amount0(), int128(int256(100 ether)), "delta0");
        assertLt(delta.amount1(), -int128(int256(200 ether)), "delta1 fee-adjusted");
    }

    /// @notice Covers the mock harness branch for zero-for-one exact-output output-side fee gross-up handling.
    /// @dev Locks router-side gross-up bookkeeping under deterministic local manager deltas.
    function testSwapPass_ZeroForOneExactOutput_OutputSideProtocolFeeGrossesUp() external {
        _setProtocolFeeCurrency(key.currency1);
        _matureLaunchWindow();
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );

        assertEq(token1.balanceOf(address(this)) - balance1Before, 100 ether, "exact net output");
        assertGt(balance0Before - token0.balanceOf(address(this)), 200 ether, "gross-up raises input");
        assertEq(delta.amount1(), int128(int256(100 ether)), "delta1 net output");
        assertGt(token1.balanceOf(treasury), treasury1Before, "treasury collected token1");
    }

    /// @notice Covers the mock harness branch for one-for-zero exact-output output-side fee gross-up handling.
    /// @dev Locks router-side gross-up bookkeeping under deterministic local manager deltas.
    function testSwapPass_OneForZeroExactOutput_OutputSideProtocolFeeGrossesUp() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury0Before = token0.balanceOf(treasury);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 101) / 100);

        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );

        assertEq(token0.balanceOf(address(this)) - balance0Before, 100 ether, "exact net output");
        assertGt(balance1Before - token1.balanceOf(address(this)), 200 ether, "gross-up raises input");
        assertEq(delta.amount0(), int128(int256(100 ether)), "delta0 net output");
        assertGt(token0.balanceOf(treasury), treasury0Before, "treasury collected token0");
    }

    /// @notice Verifies launch-floor-dominant exact-output swaps can execute with the hook quote guardrail.
    /// @dev Locks quote/output-side floor gross-up so `estimatedUserInputAmount` stays aligned with real swap execution.
    function testSwapPass_ZeroForOneExactOutput_OutputSideLaunchFloorQuoteGuardrailExecutes() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });
        _setProtocolFeeCurrency(key.currency1);
        manager.setQuoteAlignedSwapMath(true);
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 treasury1Before = token1.balanceOf(treasury);

        BalanceDelta delta =
            router.swap(key, params, address(this), block.timestamp, 0, quote.estimatedUserInputAmount, "");

        assertFalse(quote.protocolFeeOnInput, "protocolFeeOnInput");
        assertEq(quote.feeBps, 5000, "launch fee floor");
        assertEq(token1.balanceOf(address(this)) - balance1Before, 1 ether, "exact net output");
        assertEq(balance0Before - token0.balanceOf(address(this)), quote.estimatedUserInputAmount, "quote guardrail");
        assertEq(token1.balanceOf(treasury) - treasury1Before, quote.estimatedProtocolFeeAmount, "floored protocol fee");
        assertEq(delta.amount1(), int128(int256(1 ether)), "delta1 net output");
    }

    /// @notice Verifies swaps skip attempt recording after the anti-snipe window ends.
    /// @dev Covers the post-window fast path.
    function testSwapPass_AfterAntiSnipeWindow_SkipsAttemptRecording() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        vm.roll(block.number + 11);

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        assertLt(token0.balanceOf(address(this)), balance0Before, "token0 spent");
        assertGt(token1.balanceOf(address(this)), balance1Before, "token1 received");
        assertLt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
    }

    /// @notice Verifies exact-output swaps revert when the required input exceeds the maximum.
    /// @dev Covers router slippage protection.
    function testSwapReverts_WhenExactOutputExceedsAmountInMaximum() external {
        _setProtocolFeeCurrency(key.currency0);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        vm.expectRevert();
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            200 ether,
            ""
        );
    }

    /// @notice Covers the hook-level underfill revert surface when the mock execution path returns less than requested.
    /// @dev Hook fail-closed output checks run before router-side minimum-output validation.
    function testSwapReverts_WhenExactOutputUnderfillsRequestedAmount() external {
        _setProtocolFeeCurrency(key.currency0);
        manager.setNextExactOutputAmount(poolId, 80 ether);
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        vm.expectRevert(IMemeverseUniswapHook.ExactOutputPartialFill.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );
    }

    /// @notice Verifies swaps reject expired deadlines.
    /// @dev Covers the router deadline guard before any swap side effects happen.
    function testSwapReverts_WhenDeadlineExpired() external {
        _setProtocolFeeCurrency(key.currency0);
        vm.expectRevert(IMemeverseSwapRouter.ExpiredPastDeadline.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp - 1,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Verifies exact-input swaps revert when output falls below the minimum.
    /// @dev Covers router slippage protection.
    function testSwapReverts_WhenExactInputFallsBelowAmountOutMinimum() external {
        _setProtocolFeeCurrency(key.currency0);
        _matureLaunchWindow();
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseSwapRouter.OutputAmountBelowMinimum.selector, 49.5 ether, 60 ether)
        );
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            60 ether,
            100 ether,
            ""
        );
    }

    /// @notice Covers the local fail-closed branch for exact-input underfills on input-side fee pools.
    /// @dev Uses the mock harness to witness router-facing rollback of payer, treasury, and LP-fee state.
    function testSwapReverts_WhenExactInputPartialFillsOnInputFeePool() external {
        _setProtocolFeeCurrency(key.currency0);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(true)
            }),
            address(this),
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();

        // Scope 1: balances + fee-per-share unchanged (swap reverts, so state is safe to re-check)
        {
            uint256 payer0Before = token0.balanceOf(address(this));
            uint256 payer1Before = token1.balanceOf(address(this));
            uint256 treasury0Before = token0.balanceOf(treasury);
            uint256 treasury1Before = token1.balanceOf(treasury);
            (, uint256 fee0PerShareBefore, uint256 fee1PerShareBefore) = hook.poolInfo(poolId);

            manager.setNextExactInputPoolInputAmount(poolId, 98 ether);
            vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
            router.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                address(this),
                block.timestamp,
                0,
                100 ether,
                ""
            );

            assertEq(token0.balanceOf(address(this)), payer0Before, "payer token0 unchanged");
            assertEq(token1.balanceOf(address(this)), payer1Before, "payer token1 unchanged");
            assertEq(token0.balanceOf(treasury), treasury0Before, "treasury token0 unchanged");
            assertEq(token1.balanceOf(treasury), treasury1Before, "treasury token1 unchanged");
            (, uint256 fee0After, uint256 fee1After) = hook.poolInfo(poolId);
            assertEq(fee0After, fee0PerShareBefore, "fee0 per share unchanged");
            assertEq(fee1After, fee1PerShareBefore, "fee1 per share unchanged");
        }

        // Scope 2: EWVWAP state unchanged
        {
            (
                uint256 wv0Before,,
                uint256 ewVWAPBefore,
                uint160 volAnchorBefore,,
                uint24 volDevBefore,,
                uint24 shortImpactBefore,
            ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

            manager.setNextExactInputPoolInputAmount(poolId, 98 ether);
            vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
            router.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                address(this),
                block.timestamp,
                0,
                100 ether,
                ""
            );

            (
                uint256 wv0After,,
                uint256 ewVWAPAfter,
                uint160 volAnchorAfter,,
                uint24 volDevAfter,,
                uint24 shortImpactAfter,
            ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
            assertEq(wv0After, wv0Before, "ewvwap weightedVolume0 unchanged");
            assertEq(ewVWAPAfter, ewVWAPBefore, "ewvwap unchanged");
            assertEq(volAnchorAfter, volAnchorBefore, "vol anchor unchanged");
            assertEq(volDevAfter, volDevBefore, "volatility unchanged");
            assertEq(shortImpactAfter, shortImpactBefore, "short impact unchanged");
        }
    }

    /// @notice Covers the mirrored local fail-closed branch for one-for-zero exact-input underfills on input-fee pools.
    /// @dev Uses the mock harness to witness routed rollback symmetry rather than proving full production partial-fill semantics.
    function testSwapReverts_WhenOneForZeroExactInputPartialFillsOnInputFeePool() external {
        _setProtocolFeeCurrency(key.currency1);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: _validExecutionPriceLimit(false)
            }),
            address(this),
            block.timestamp,
            0,
            10 ether,
            ""
        );
        _matureLaunchWindow();

        // Scope 1: balances + fee-per-share unchanged
        {
            uint256 payer0Before = token0.balanceOf(address(this));
            uint256 payer1Before = token1.balanceOf(address(this));
            uint256 treasury0Before = token0.balanceOf(treasury);
            uint256 treasury1Before = token1.balanceOf(treasury);
            (, uint256 fee0PerShareBefore, uint256 fee1PerShareBefore) = hook.poolInfo(poolId);

            manager.setNextExactInputPoolInputAmount(poolId, 98 ether);
            vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
            router.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                address(this),
                block.timestamp,
                0,
                100 ether,
                ""
            );

            assertEq(token0.balanceOf(address(this)), payer0Before, "payer token0 unchanged");
            assertEq(token1.balanceOf(address(this)), payer1Before, "payer token1 unchanged");
            assertEq(token0.balanceOf(treasury), treasury0Before, "treasury token0 unchanged");
            assertEq(token1.balanceOf(treasury), treasury1Before, "treasury token1 unchanged");
            (, uint256 fee0After, uint256 fee1After) = hook.poolInfo(poolId);
            assertEq(fee0After, fee0PerShareBefore, "fee0 per share unchanged");
            assertEq(fee1After, fee1PerShareBefore, "fee1 per share unchanged");
        }

        // Scope 2: EWVWAP state unchanged
        {
            (
                uint256 wv0Before,,
                uint256 ewVWAPBefore,
                uint160 volAnchorBefore,,
                uint24 volDevBefore,,
                uint24 shortImpactBefore,
            ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);

            manager.setNextExactInputPoolInputAmount(poolId, 98 ether);
            vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
            router.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                address(this),
                block.timestamp,
                0,
                100 ether,
                ""
            );

            (
                uint256 wv0After,,
                uint256 ewVWAPAfter,
                uint160 volAnchorAfter,,
                uint24 volDevAfter,,
                uint24 shortImpactAfter,
            ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
            assertEq(wv0After, wv0Before, "ewvwap weightedVolume0 unchanged");
            assertEq(ewVWAPAfter, ewVWAPBefore, "ewvwap unchanged");
            assertEq(volAnchorAfter, volAnchorBefore, "vol anchor unchanged");
            assertEq(volDevAfter, volDevBefore, "volatility unchanged");
            assertEq(shortImpactAfter, shortImpactBefore, "short impact unchanged");
        }
    }

    /// @notice Verifies exact-output quotes include input-side fees in the user input amount.
    /// @dev Covers quote semantics for exact-output swaps.
    function testPreviewSwap_ExactOutputInputSideIncludesFeeInUserInput() external {
        _setProtocolFeeCurrency(key.currency0);
        IMemeverseUniswapHook.SwapQuote memory preview = router.quoteSwap(
            key, SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: 0}), address(this)
        );

        assertTrue(preview.protocolFeeOnInput, "protocolFeeOnInput");
        assertEq(preview.estimatedUserOutputAmount, 100 ether, "net output");
        assertGt(preview.estimatedUserInputAmount, preview.estimatedProtocolFeeAmount, "user input > protocol fee");
        assertGt(preview.estimatedUserInputAmount, preview.estimatedLpFeeAmount, "user input > lp fee");
        assertGt(
            preview.estimatedUserInputAmount,
            preview.estimatedProtocolFeeAmount + preview.estimatedLpFeeAmount,
            "user input covers both fee components"
        );
    }

    /// @notice Verifies router quotes delegate to the configured hook lens.
    /// @dev Covers the router quote passthrough to the stateless lens.
    function testRouterQuoteSwap_DelegatesToConfiguredLens() external {
        _setProtocolFeeCurrency(key.currency0);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: 0});

        IMemeverseUniswapHook.SwapQuote memory lensQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        IMemeverseUniswapHook.SwapQuote memory routerQuote = router.quoteSwap(key, params, address(this));

        assertEq(routerQuote.feeBps, lensQuote.feeBps, "feeBps");
        assertEq(routerQuote.estimatedUserInputAmount, lensQuote.estimatedUserInputAmount, "user input");
        assertEq(routerQuote.estimatedUserOutputAmount, lensQuote.estimatedUserOutputAmount, "user output");
        assertEq(routerQuote.estimatedProtocolFeeAmount, lensQuote.estimatedProtocolFeeAmount, "protocol fee");
        assertEq(routerQuote.estimatedLpFeeAmount, lensQuote.estimatedLpFeeAmount, "lp fee");
        assertEq(routerQuote.protocolFeeOnInput, lensQuote.protocolFeeOnInput, "fee side");
    }

    /// @notice Verifies native-input native-pair swaps fail before router prefunding.
    /// @dev Native pairs must use the documented router-level `NativeCurrencyUnsupported` selector.
    function testSwapRevertsAtRouter_WhenNativePairUsesNativeInputCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.swap(
            nativeKey,
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            300 ether,
            ""
        );
        assertEq(manager.lastUnlockPayer(), address(0), "router-local failure should not enter unlock");
    }

    /// @notice Verifies ERC20-input native-pair swaps use the same router native-pair selector.
    /// @dev The router must reject native pairs before hook validation.
    function testSwapRevertsAtRouter_WhenNativePairUsesErc20InputCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.swap(
            nativeKey,
            SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this),
            block.timestamp,
            0,
            100 ether,
            ""
        );
    }

    /// @notice Verifies createPoolAndAddLiquidity fails closed for native pairs.
    function testCreatePoolAndAddLiquidityReverts_WhenPairUsesNativeCurrency() external {
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.createPoolAndAddLiquidity(
            address(0), address(token1), 300 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );
    }

    /// @notice Verifies addLiquidity fails closed for native pairs.
    function testAddLiquidityReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.addLiquidity(
            nativeKey.currency0,
            nativeKey.currency1,
            300 ether,
            100 ether,
            90 ether,
            90 ether,
            address(this),
            block.timestamp
        );
    }

    /// @notice Verifies router-accrued LP fees are claimed directly through the hook without router relays.
    /// @dev Covers the new owner-direct claim flow while keeping router swap/liquidity integration in scope.
    function testClaimFeesCore_DirectOwnerClaimCanRedirectRecipient() external {
        _setProtocolFeeCurrency(key.currency0);

        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        _matureLaunchWindow();

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        address recipient = address(0xCAFE);
        uint256 balanceBefore = token0.balanceOf(recipient);

        vm.prank(alice);
        (uint256 fee0Amount, uint256 fee1Amount) =
            hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: recipient}));

        assertGt(fee0Amount, 0, "fee0 claimed");
        assertEq(fee1Amount, 0, "fee1 claimed");
        assertEq(token0.balanceOf(recipient), balanceBefore + fee0Amount, "recipient received claimed fee");
    }

    /// @notice Verifies claimable-fee previews match claims and do not mutate state.
    /// @dev Covers the router preview surface for LP fees.
    function testClaimableFees_ViewMatchesClaimAndDoesNotMutateState() external {
        _setProtocolFeeCurrency(key.currency0);

        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        _matureLaunchWindow();

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        (uint256 fee0OffsetBefore, uint256 fee1OffsetBefore, uint256 pendingFee0Before, uint256 pendingFee1Before) =
            hook.userFeeState(poolId, alice);

        (uint256 previewFee0, uint256 previewFee1) =
            lens.claimableFees(IMemeverseUniswapHook(address(hook)), key, alice);

        (uint256 fee0OffsetAfter, uint256 fee1OffsetAfter, uint256 pendingFee0After, uint256 pendingFee1After) =
            hook.userFeeState(poolId, alice);

        assertEq(fee0OffsetAfter, fee0OffsetBefore, "fee0 offset mutated");
        assertEq(fee1OffsetAfter, fee1OffsetBefore, "fee1 offset mutated");
        assertEq(pendingFee0After, pendingFee0Before, "pending fee0 mutated");
        assertEq(pendingFee1After, pendingFee1Before, "pending fee1 mutated");
        assertGt(previewFee0, 0, "preview fee0");
        assertEq(previewFee1, 0, "preview fee1");

        vm.prank(alice);
        (uint256 claimedFee0, uint256 claimedFee1) =
            hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: alice}));

        assertEq(claimedFee0, previewFee0, "preview fee0 mismatch");
        assertEq(claimedFee1, previewFee1, "preview fee1 mismatch");
    }

    /// @notice Verifies the router derives the expected dynamic-fee hook pool key.
    /// @dev Covers pair normalization and hook wiring.
    function testRouterGetHookPoolKey_ReturnsDynamicHookKey() external view {
        address tokenA = address(token0);
        address tokenB = address(token1);
        if (tokenB < tokenA) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        PoolKey memory expected = _dynamicPoolKey(Currency.wrap(tokenA), Currency.wrap(tokenB));
        PoolKey memory routerKey = router.getHookPoolKey(address(token0), address(token1));

        assertEq(Currency.unwrap(routerKey.currency0), Currency.unwrap(expected.currency0), "currency0");
        assertEq(Currency.unwrap(routerKey.currency1), Currency.unwrap(expected.currency1), "currency1");
        assertEq(routerKey.fee, expected.fee, "fee");
        assertEq(routerKey.tickSpacing, expected.tickSpacing, "tickSpacing");
        assertEq(address(routerKey.hooks), address(expected.hooks), "hooks");
    }

    /// @notice Verifies router fee previews match the hook claimable-fee view.
    /// @dev Covers router passthrough behavior for pair fee previews.
    function testRouterPreviewClaimableFees_MatchesHookClaimableFees() external {
        _setProtocolFeeCurrency(key.currency0);

        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        _matureLaunchWindow();

        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
            address(this),
            block.timestamp,
            40 ether,
            100 ether,
            ""
        );

        PoolKey memory routerKey = router.getHookPoolKey(address(token0), address(token1));
        (uint256 hookFee0, uint256 hookFee1) =
            lens.claimableFees(IMemeverseUniswapHook(address(hook)), routerKey, alice);
        (uint256 routerFee0, uint256 routerFee1) = router.previewClaimableFees(address(token0), address(token1), alice);

        assertEq(routerFee0, hookFee0, "fee0");
        assertEq(routerFee1, hookFee1, "fee1");
    }

    /// @notice Verifies the router returns the hook LP token for a pair.
    /// @dev Covers the new pair-to-LP-token view helper.
    function testRouterLpToken_ReturnsHookPoolLpTokenAddress() external {
        PoolKey memory normalizedKey = router.getHookPoolKey(address(token0), address(token1));
        _initializePoolDirect(normalizedKey, SQRT_PRICE_1_1);

        (address poolLpToken,,) = hook.poolInfo(normalizedKey.toId());
        assertEq(router.lpToken(address(token0), address(token1)), poolLpToken, "lp token");
    }

    /// @notice Verifies the router quotes enough pair amounts to mint at least the target liquidity.
    /// @dev The quote is an upper bound for exact-liquidity callers, not a floor-rounded under-estimate.
    function testRouterQuoteAmountsForLiquidity_ReturnsAmountsThatCoverTargetLiquidity() external {
        uint128 liquidityDesired = 10 ether;
        PoolKey memory normalizedKey = router.getHookPoolKey(address(token0), address(token1));
        _initializePoolDirect(normalizedKey, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(normalizedKey.toId());
        (uint256 amount0Floor, uint256 amount1Floor) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, FULL_RANGE_MIN_SQRT_PRICE_X96, FULL_RANGE_MAX_SQRT_PRICE_X96, liquidityDesired
        );

        (uint256 amountToken0, uint256 amountToken1) =
            router.quoteAmountsForLiquidity(address(token0), address(token1), liquidityDesired);

        uint128 quotedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, FULL_RANGE_MIN_SQRT_PRICE_X96, FULL_RANGE_MAX_SQRT_PRICE_X96, amountToken0, amountToken1
        );

        assertGe(amountToken0, amount0Floor, "token0 floor");
        assertGe(amountToken1, amount1Floor, "token1 floor");
        assertGe(quotedLiquidity, liquidityDesired, "quoted liquidity covers target");
    }

    /// @notice Verifies quoting a single unit of liquidity does not hang and still covers the request.
    /// @dev Guards the exact-liquidity boundary used by launcher-side POL minting.
    function testRouterQuoteAmountsForLiquidity_SingleUnitCoverageAtParity() external {
        uint128 liquidityDesired = 1;
        PoolKey memory normalizedKey = router.getHookPoolKey(address(token0), address(token1));
        _initializePoolDirect(normalizedKey, SQRT_PRICE_1_1);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(normalizedKey.toId());
        (uint256 amountToken0, uint256 amountToken1) =
            router.quoteAmountsForLiquidity(address(token0), address(token1), liquidityDesired);

        uint128 quotedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, FULL_RANGE_MIN_SQRT_PRICE_X96, FULL_RANGE_MAX_SQRT_PRICE_X96, amountToken0, amountToken1
        );

        assertGe(quotedLiquidity, liquidityDesired, "quoted liquidity covers unit target");
    }

    /// @notice Verifies the exact-liquidity quote can be used verbatim for addLiquidityDetailed at an unchanged price.
    /// @dev Guards the launcher exact-liquidity flow against underfunding when using the router's exact quote path.
    function testQuoteExactAmountsForLiquidity_FeedsDetailedAddLiquidityAtUnchangedPrice() external {
        uint128 liquidityDesired = 10 ether;
        PoolKey memory normalizedKey = router.getHookPoolKey(address(token0), address(token1));
        _initializePoolDirect(normalizedKey, SQRT_PRICE_1_1);

        (uint256 amountToken0, uint256 amountToken1) =
            router.quoteExactAmountsForLiquidity(address(token0), address(token1), liquidityDesired);
        (uint128 liquidity,,) = router.addLiquidityDetailed(
            normalizedKey.currency0,
            normalizedKey.currency1,
            amountToken0,
            amountToken1,
            0,
            0,
            address(this),
            block.timestamp
        );

        assertEq(liquidity, liquidityDesired, "exact quote mints target liquidity");
    }

    /// @notice Verifies the exact-liquidity quote uses the requested liquidity on an initialized empty pool.
    /// @dev Fresh pools no longer require an extra first-mint locked-liquidity buffer.
    function testQuoteExactAmountsForLiquidity_FeedsDetailedAddLiquidityOnInitializedEmptyPool() external {
        uint128 liquidityDesired = 10 ether;
        MockERC20 freshToken0 = new MockERC20("Fresh0", "F0", 18);
        MockERC20 freshToken1 = new MockERC20("Fresh1", "F1", 18);
        freshToken0.mint(address(this), 1_000_000 ether);
        freshToken1.mint(address(this), 1_000_000 ether);
        freshToken0.mint(address(manager), 1_000_000 ether);
        freshToken1.mint(address(manager), 1_000_000 ether);
        freshToken0.approve(address(router), type(uint256).max);
        freshToken1.approve(address(router), type(uint256).max);

        PoolKey memory freshKey = router.getHookPoolKey(address(freshToken0), address(freshToken1));
        PoolId freshPoolId = freshKey.toId();
        _initializePoolDirect(freshKey, SQRT_PRICE_1_1);
        manager.setLiquidity(freshPoolId, 0);

        uint256 expectedToken0 =
            SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, LiquidityQuote.MAX_SQRT_PRICE_X96, liquidityDesired, true);
        uint256 expectedToken1 =
            SqrtPriceMath.getAmount1Delta(LiquidityQuote.MIN_SQRT_PRICE_X96, SQRT_PRICE_1_1, liquidityDesired, true);
        (uint256 amountToken0, uint256 amountToken1) =
            router.quoteExactAmountsForLiquidity(address(freshToken0), address(freshToken1), liquidityDesired);
        assertEq(amountToken0, expectedToken0, "amount0 has no first-mint buffer");
        assertEq(amountToken1, expectedToken1, "amount1 has no first-mint buffer");

        (uint128 liquidity,,) = router.addLiquidityDetailed(
            freshKey.currency0, freshKey.currency1, amountToken0, amountToken1, 0, 0, address(this), block.timestamp
        );

        assertEq(liquidity, liquidityDesired, "exact quote mints target liquidity");
    }

    /// @notice Verifies liquidity-related router selectors remain aligned with the public interface.
    /// @dev Guards ABI stability while internal parameter plumbing is refactored.
    function testRouterLiquiditySelectors_MatchInterface() external pure {
        assertEq(MemeverseSwapRouter.addLiquidity.selector, IMemeverseSwapRouter.addLiquidity.selector, "add");
        assertEq(
            MemeverseSwapRouter.addLiquidityWithPermit2.selector,
            IMemeverseSwapRouter.addLiquidityWithPermit2.selector,
            "add permit2"
        );
        assertEq(MemeverseSwapRouter.removeLiquidity.selector, IMemeverseSwapRouter.removeLiquidity.selector, "remove");
        assertEq(
            MemeverseSwapRouter.removeLiquidityWithPermit2.selector,
            IMemeverseSwapRouter.removeLiquidityWithPermit2.selector,
            "remove permit2"
        );
        assertEq(
            MemeverseSwapRouter.createPoolAndAddLiquidity.selector,
            IMemeverseSwapRouter.createPoolAndAddLiquidity.selector,
            "create"
        );
    }

    /// @notice Verifies pool bootstrap and initial liquidity use the hook core path.
    /// @dev Covers the router bootstrap helper.
    function testRouterCreatePoolAndAddLiquidity_UsesHookCore() external {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        (uint128 liquidity, PoolKey memory createdKey, uint256 amountAUsed, uint256 amountBUsed) = router.createPoolAndAddLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );

        (address liquidityToken,,) = hook.poolInfo(createdKey.toId());
        assertEq(address(createdKey.hooks), address(hook), "hook");
        assertEq(createdKey.fee, 0x800000, "dynamic fee");
        assertGt(liquidity, 0, "liquidity");
        assertGt(UniswapLP(liquidityToken).balanceOf(address(this)), 0, "lp balance");
        assertEq(tokenA.balanceOf(address(this)), 1_000_000 ether - amountAUsed, "amountA used");
        assertEq(tokenB.balanceOf(address(this)), 1_000_000 ether - amountBUsed, "amountB used");
    }

    function testRouterCreatePoolAndAddLiquidity_RevertsForNonLauncher() external {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        hook.setLauncher(alice);

        vm.expectRevert(UNAUTHORIZED_LAUNCHER_SELECTOR);
        router.createPoolAndAddLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );
    }

    /// @notice Verifies pool bootstrap uses the caller-provided start price.
    /// @dev Confirms the router no longer derives a bootstrap price from token budgets.
    function testRouterCreatePoolAndAddLiquidity_UsesProvidedStartPrice() external {
        MockERC20 token18 = new MockERC20("Token18", "T18", 18);
        MockERC20 token6 = new MockERC20("Token6", "T6", 6);
        uint160 startPrice = SQRT_PRICE_1_1 / 2;
        token18.mint(address(this), 1_000_000 ether);
        token6.mint(address(this), 1_000_000 * 1e6);
        token18.approve(address(router), type(uint256).max);
        token6.approve(address(router), type(uint256).max);

        (, PoolKey memory createdKey,,) = router.createPoolAndAddLiquidity(
            address(token18), address(token6), 100 ether, 100 * 1e6, startPrice, address(this), block.timestamp
        );

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(createdKey.toId());
        assertEq(sqrtPriceX96, startPrice, "provided sqrt price");
    }

    /// @notice Verifies bootstrap returns actual spend when desired budgets are larger than execution needs.
    /// @dev Bootstrap now follows the same desired-budget and refund semantics as other liquidity paths.
    function testCreatePoolAndAddLiquidity_ReturnsActualSpendBelowDesiredBudgets() external {
        MockERC20 tokenA = new MockERC20("PreviewA", "PA", 18);
        MockERC20 tokenB = new MockERC20("PreviewB", "PB", 18);
        if (address(tokenB) < address(tokenA)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        uint256 amountADesired = 100 ether;
        uint256 amountBDesired = 150 ether;
        uint160 startPrice = SQRT_PRICE_1_1;
        _mintAndApproveBootstrapPair(tokenA, amountADesired, tokenB, amountBDesired);

        (uint128 liquidity,, uint256 amountAUsed, uint256 amountBUsed) = router.createPoolAndAddLiquidity(
            address(tokenA), address(tokenB), amountADesired, amountBDesired, startPrice, address(this), block.timestamp
        );

        assertGt(liquidity, 0, "liquidity");
        assertLe(amountAUsed, amountADesired, "amountA budget");
        assertLe(amountBUsed, amountBDesired, "amountB budget");
        assertEq(tokenA.balanceOf(address(this)), amountADesired - amountAUsed, "amountA refunded");
        assertEq(tokenB.balanceOf(address(this)), amountBDesired - amountBUsed, "amountB refunded");
    }

    /// @notice Verifies bootstrap actual-spend reporting stays in caller order for unsorted inputs.
    /// @dev Launcher residual accounting depends on caller-order returned spend.
    function testCreatePoolAndAddLiquidity_ReturnsActualSpendInCallerOrderWhenInputsAreUnsorted() external {
        MockERC20 lowToken = new MockERC20("PreviewLow", "PL", 18);
        MockERC20 highToken = new MockERC20("PreviewHigh", "PH", 18);
        if (address(highToken) < address(lowToken)) {
            (lowToken, highToken) = (highToken, lowToken);
        }
        uint256 amountADesired = 150 ether;
        uint256 amountBDesired = 100 ether;
        uint160 startPrice = SQRT_PRICE_1_1 / 2;
        _mintAndApproveBootstrapPair(highToken, amountADesired, lowToken, amountBDesired);

        (uint128 liquidity,, uint256 amountAUsed, uint256 amountBUsed) = router.createPoolAndAddLiquidity(
            address(highToken),
            address(lowToken),
            amountADesired,
            amountBDesired,
            startPrice,
            address(this),
            block.timestamp
        );

        assertGt(liquidity, 0, "liquidity");
        assertLe(amountAUsed, amountADesired, "amountA budget");
        assertLe(amountBUsed, amountBDesired, "amountB budget");
    }

    /// @notice Verifies off-ratio bootstrap budgets execute with actual spend instead of a preview-padding revert.
    /// @dev Final bootstrap rules intentionally accept partial spend and return actual usage.
    function testRouterCreatePoolAndAddLiquidity_ExecutesFromDesiredBudgetsWithoutPaddingRevert() external {
        MockERC20 tokenA = new MockERC20("UnstableBootstrapA", "UBA", 18);
        MockERC20 tokenB = new MockERC20("UnstableBootstrapB", "UBB", 18);
        uint256 amountADesired = 100 ether;
        uint256 amountBDesired = 100 ether;
        uint160 startPrice = SQRT_PRICE_1_1 / 2;
        _mintAndApproveBootstrapPair(tokenA, amountADesired, tokenB, amountBDesired);

        (uint128 liquidity,, uint256 amountAUsed, uint256 amountBUsed) = router.createPoolAndAddLiquidity(
            address(tokenA), address(tokenB), amountADesired, amountBDesired, startPrice, address(this), block.timestamp
        );
        assertGt(liquidity, 0, "liquidity");
        assertLe(amountAUsed, amountADesired, "amountA");
        assertLe(amountBUsed, amountBDesired, "amountB");
    }

    /// @notice Verifies addLiquidity rejects expired deadlines.
    /// @dev Covers the router deadline guard before any liquidity side effects happen.
    function testAddLiquidityReverts_WhenDeadlineExpired() external {
        vm.expectRevert(IMemeverseSwapRouter.ExpiredPastDeadline.selector);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp - 1
        );
    }

    /// @notice Verifies the detailed add-liquidity entrypoint reports actual spend in pool-currency order.
    /// @dev Locks the new router surface that Launcher exact-liquidity now relies on to avoid balance snapshots.
    function testAddLiquidityDetailed_ReturnsActualUsageInPoolCurrencyOrder() external {
        uint256 token0Before = token0.balanceOf(address(this));
        uint256 token1Before = token1.balanceOf(address(this));

        (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = router.addLiquidityDetailed(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp
        );

        assertGt(liquidity, 0, "liquidity");
        assertEq(token0Before - token0.balanceOf(address(this)), amount0Used, "amount0 used");
        assertEq(token1Before - token1.balanceOf(address(this)), amount1Used, "amount1 used");
        assertLe(amount0Used, 100 ether, "amount0 budget");
        assertLe(amount1Used, 100 ether, "amount1 budget");
    }

    /// @notice Verifies unsorted addLiquidityDetailed inputs still report spend in caller order.
    /// @dev Guards the launcher path that now passes `(UAsset, memecoin)` directly and relies on router-side normalization.
    function testAddLiquidityDetailed_ReturnsActualUsageInCallerOrderWhenInputsAreUnsorted() external {
        _initializePoolDirect(key, SQRT_PRICE_1_1 / 2);

        uint256 token0Before = token0.balanceOf(address(this));
        uint256 token1Before = token1.balanceOf(address(this));

        (uint128 liquidity, uint256 amountFirstCurrencyUsed, uint256 amountSecondCurrencyUsed) = router.addLiquidityDetailed(
            key.currency1, key.currency0, 100 ether, 150 ether, 0, 0, address(this), block.timestamp
        );

        assertGt(liquidity, 0, "liquidity");
        assertEq(token1Before - token1.balanceOf(address(this)), amountFirstCurrencyUsed, "first currency used");
        assertEq(token0Before - token0.balanceOf(address(this)), amountSecondCurrencyUsed, "second currency used");
        assertNotEq(amountFirstCurrencyUsed, amountSecondCurrencyUsed, "price skew ensures caller-order coverage");
    }

    /// @notice Verifies removeLiquidity rejects expired deadlines.
    /// @dev Covers the router deadline guard on liquidity removal.
    function testRemoveLiquidityReverts_WhenDeadlineExpired() external {
        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint128 liquidity = uint128(UniswapLP(liquidityToken).balanceOf(alice));

        vm.prank(alice);
        vm.expectRevert(IMemeverseSwapRouter.ExpiredPastDeadline.selector);
        router.removeLiquidity(key.currency0, key.currency1, liquidity, 0, 0, alice, block.timestamp - 1);
    }

    /// @notice Verifies removeLiquidity rejects the zero-address recipient before forwarding assets.
    /// @dev Locks in the router-side defensive parity with the hook payout helper.
    function testRemoveLiquidityReverts_WhenRecipientIsZeroAddress() external {
        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint128 liquidity = uint128(UniswapLP(liquidityToken).balanceOf(alice));

        vm.prank(alice);
        UniswapLP(liquidityToken).approve(address(router), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        router.removeLiquidity(key.currency0, key.currency1, liquidity, 0, 0, address(0), block.timestamp);
    }

    /// @notice Verifies removeLiquidity resolves the canonical pool when caller supplies reversed currencies.
    /// @dev Returned BalanceDelta remains in canonical pool order while min outputs are accepted in caller order.
    function testRemoveLiquidity_UsesCanonicalPoolWhenCurrenciesAreReversed() external {
        vm.prank(alice);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, alice, block.timestamp
        );
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint128 liquidity = uint128(UniswapLP(liquidityToken).balanceOf(alice));

        vm.prank(alice);
        UniswapLP(liquidityToken).approve(address(router), type(uint256).max);

        uint256 token0Before = token0.balanceOf(alice);
        uint256 token1Before = token1.balanceOf(alice);

        vm.prank(alice);
        BalanceDelta delta =
            router.removeLiquidity(key.currency1, key.currency0, liquidity, 1, 1, alice, block.timestamp);

        assertGt(int256(delta.amount0()), 0, "canonical delta0");
        assertGt(int256(delta.amount1()), 0, "canonical delta1");
        assertEq(token0.balanceOf(alice) - token0Before, uint256(uint128(delta.amount0())), "token0 returned");
        assertEq(token1.balanceOf(alice) - token1Before, uint256(uint128(delta.amount1())), "token1 returned");
        assertEq(UniswapLP(liquidityToken).balanceOf(alice), 0, "lp burned");
    }

    /// @notice Verifies reversed removeLiquidity mins accept caller-order amounts on the success path.
    /// @dev Uses skewed pool pricing so caller-order mins differ from canonical pool-order mins.
    function testRemoveLiquidity_ReversedCurrenciesRemapAsymmetricMinsFromCallerOrder() external {
        (address liquidityToken, uint128 liquidity, uint256 canonicalAmount0, uint256 canonicalAmount1) =
            _prepareAsymmetricReversedRemoveLiquidity();
        uint256 token0Before = token0.balanceOf(alice);
        uint256 token1Before = token1.balanceOf(alice);

        vm.prank(alice);
        BalanceDelta delta = router.removeLiquidity(
            key.currency1, key.currency0, liquidity, canonicalAmount1, canonicalAmount0, alice, block.timestamp
        );

        assertEq(uint256(uint128(delta.amount0())), canonicalAmount0, "canonical delta0");
        assertEq(uint256(uint128(delta.amount1())), canonicalAmount1, "canonical delta1");
        assertEq(token0.balanceOf(alice) - token0Before, canonicalAmount0, "token0 returned");
        assertEq(token1.balanceOf(alice) - token1Before, canonicalAmount1, "token1 returned");
        assertEq(UniswapLP(liquidityToken).balanceOf(alice), 0, "lp burned");
    }

    /// @notice Verifies canonical-order mins still fail when the caller supplies reversed currencies.
    /// @dev The same asymmetric quote that succeeds in caller order must fail in canonical order.
    function testRemoveLiquidity_ReversedCurrenciesRejectCanonicalOrderAsCallerMins() external {
        (, uint128 liquidity, uint256 canonicalAmount0, uint256 canonicalAmount1) =
            _prepareAsymmetricReversedRemoveLiquidity();

        vm.prank(alice);
        vm.expectRevert(IMemeverseUniswapHook.TooMuchSlippage.selector);
        router.removeLiquidity(
            key.currency1, key.currency0, liquidity, canonicalAmount0, canonicalAmount1, alice, block.timestamp
        );
    }

    function _prepareAsymmetricReversedRemoveLiquidity()
        internal
        returns (address liquidityToken, uint128 liquidity, uint256 canonicalAmount0, uint256 canonicalAmount1)
    {
        _initializePoolDirect(key, SQRT_PRICE_1_1 / 2);

        vm.prank(alice);
        router.addLiquidity(key.currency0, key.currency1, 100 ether, 100 ether, 0, 0, alice, block.timestamp);
        (liquidityToken,,) = hook.poolInfo(poolId);
        liquidity = uint128(UniswapLP(liquidityToken).balanceOf(alice));

        vm.prank(alice);
        UniswapLP(liquidityToken).approve(address(router), type(uint256).max);

        uint256 readyState = vm.snapshotState();
        vm.prank(alice);
        BalanceDelta quotedDelta =
            router.removeLiquidity(key.currency1, key.currency0, liquidity, 0, 0, alice, block.timestamp);
        vm.revertToState(readyState);

        canonicalAmount0 = uint256(uint128(quotedDelta.amount0()));
        canonicalAmount1 = uint256(uint128(quotedDelta.amount1()));
        assertGt(canonicalAmount0, 0, "canonical amount0");
        assertGt(canonicalAmount1, 0, "canonical amount1");
        assertNotEq(canonicalAmount0, canonicalAmount1, "asymmetric mins");
    }

    /// @notice Verifies pool bootstrap rejects identical token pairs.
    /// @dev Covers router validation that a pool must contain two distinct assets.
    function testCreatePoolAndAddLiquidityReverts_WhenTokenPairIsIdentical() external {
        vm.expectRevert(IMemeverseSwapRouter.InvalidTokenPair.selector);
        router.createPoolAndAddLiquidity(
            address(token0), address(token0), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp
        );
    }

    /// @notice Verifies pool bootstrap rejects expired deadlines.
    /// @dev Covers the router deadline guard on create-and-add flows.
    function testCreatePoolAndAddLiquidityReverts_WhenDeadlineExpired() external {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 1_000 ether);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        vm.expectRevert(IMemeverseSwapRouter.ExpiredPastDeadline.selector);
        router.createPoolAndAddLiquidity(
            address(tokenA), address(tokenB), 100 ether, 100 ether, SQRT_PRICE_1_1, address(this), block.timestamp - 1
        );
    }

    /// @notice Builds a normalized pool key wired to the test hook.
    /// @dev Encapsulates the pair ordering and hook wiring shared by the router tests.
    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
    }

    function _mintAndApproveBootstrapPair(MockERC20 tokenA, uint256 amountA, MockERC20 tokenB, uint256 amountB)
        internal
    {
        tokenA.mint(address(this), amountA);
        tokenB.mint(address(this), amountB);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
    }

    /// @notice Accepts native refunds delivered during router tests.
    /// @dev Lets the test contract receive ETH when the router funnels leftover native funds.
    receive() external payable {}
}
