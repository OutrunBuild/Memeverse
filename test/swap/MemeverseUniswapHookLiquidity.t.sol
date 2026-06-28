// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseDynamicFeeEngine} from "../../src/swap/MemeverseDynamicFeeEngine.sol";
import {OutrunOwnableUpgradeable} from "../../src/common/access/OutrunOwnableUpgradeable.sol";
import {MemeversePreorderSettlementExecutor} from "../../src/swap/MemeversePreorderSettlementExecutor.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IMemeverseDynamicFeeEngine} from "../../src/swap/interfaces/IMemeverseDynamicFeeEngine.sol";
import {IMemeversePreorderSettlementExecutor} from "../../src/swap/interfaces/IMemeversePreorderSettlementExecutor.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";

import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {PreorderSettlementReenterer} from "../mocks/swap/PreorderSettlementReenterer.sol";
import {PreorderSettlementTransferFromReenterer} from "../mocks/swap/PreorderSettlementTransferFromReenterer.sol";
import {FeeMismatchSettlementExecutor} from "../mocks/swap/FeeMismatchSettlementExecutor.sol";
import {FeeEngineStorageSlots} from "../mocks/swap/FeeEngineStorageSlots.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

import {TestableMemeverseDynamicFeeEngineV2} from "../mocks/upgrade/TestableMemeverseDynamicFeeEngineV2.sol";
import {MemeverseUniswapHookV2} from "../mocks/upgrade/MemeverseUniswapHookV2.sol";

/// @dev Test boundary:
/// - These cases lock hook-side handling under the local hook-liquidity manager mock.
/// - They do not establish real market execution, partial-fill economics, rollback guarantees,
///   or fee-side correctness beyond this deterministic harness.
contract MemeverseUniswapHookLiquidityTest is Test, HookStorageHelper {
    using FeeEngineStorageSlots for *;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q128 = uint256(1) << 128;
    bytes4 internal constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    bytes4 internal constant UNAUTHORIZED_POOL_INITIALIZER_SELECTOR =
        bytes4(keccak256("UnauthorizedPoolInitializer()"));
    bytes4 internal constant DYNAMIC_FEE_ENGINE_POOL_MANAGER_MISMATCH_SELECTOR =
        bytes4(keccak256("DynamicFeeEnginePoolManagerMismatch(address,address)"));
    bytes4 internal constant DYNAMIC_FEE_ENGINE_OWNER_MISMATCH_SELECTOR =
        bytes4(keccak256("DynamicFeeEngineOwnerMismatch(address,address,address)"));
    event DynamicFeeEngineUpdated(address oldEngine, address newEngine);

    // ERC7201 namespace base slot of MemeverseDynamicFeeEngine (matches the src constant). The V2 facade
    // shell does not inherit the engine, so engine-upgrade tests verify fee-state survival via `vm.load`
    // against these slots instead of V1 getters. `dynamicFeeStates` is the first namespace field (base + 0);
    // `authorizedHook` is the third field (base + 2). The per-(hook,poolId) DynamicFeeState is a compact
    // 9-field struct living at the mapping-value slot (see FeeEngineStorageSlots.dynamicFeeStateSlot).
    bytes32 internal constant FEE_ENGINE_STORAGE_LOCATION = FeeEngineStorageSlots.LOCATION;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHook internal hook;
    MemeverseUniswapHookLens internal lens;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    function _deployHookProxyForManager(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared helper
        // (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`). Engine proxy is
        // created and bound by the helper; hook impl is the production contract.
        (address hookProxy,) = deployHookAtFlagAddress(manager_, owner_, treasury_);
        return MemeverseUniswapHook(hookProxy);
    }

    function _deployEngineProxyForManager(IPoolManager manager_, address owner_)
        internal
        returns (MemeverseDynamicFeeEngine deployed)
    {
        deployed = _deployEngineProxyForManager(manager_, owner_, address(0xBAD));
    }

    function _deployEngineProxyForManager(IPoolManager manager_, address owner_, address authorizedHook_)
        internal
        returns (MemeverseDynamicFeeEngine deployed)
    {
        MemeverseDynamicFeeEngine implementation = new MemeverseDynamicFeeEngine(manager_);
        deployed = MemeverseDynamicFeeEngine(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(MemeverseDynamicFeeEngine.initialize, (owner_, authorizedHook_))
                )
            )
        );
    }

    function _deployHookProxy(address owner_, address treasury_) internal returns (MemeverseUniswapHook deployed) {
        deployed = _deployHookProxyForManager(IPoolManager(address(mockManager)), owner_, treasury_);
    }

    function _hasExpectedHookPermissions(address hookAddress) internal pure returns (bool) {
        uint160 flags = uint160(hookAddress) & uint160((1 << 14) - 1);
        uint160 expectedFlags = uint160(1 << 13) // beforeInitialize
            | uint160(1 << 11) // beforeAddLiquidity
            | uint160(1 << 7) // beforeSwap
            | uint160(1 << 6) // afterSwap
            | uint160(1 << 3) // beforeSwapReturnDelta
            | uint160(1 << 2); // afterSwapReturnDelta
        return flags == expectedFlags;
    }

    function _nextInvalidProductionHookProxyAddress() internal returns (address predictedProxy) {
        // Hook proxy is 5 CREATEs away: LP impl, preorder executor, engine impl, engine proxy, hook impl, then hook proxy.
        predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        for (uint256 i = 0; _hasExpectedHookPermissions(predictedProxy); i++) {
            require(i < 256, "ProxyDeploy: max burns exceeded");
            new MockERC20("DUMMY", "DUMMY", 18);
            predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        }

        require(!_hasExpectedHookPermissions(predictedProxy), "hook-valid proxy");
    }

    /// @notice Executes set up.
    /// @dev Deploys the hook, router, tokens, and approvals shared by the liquidity tests.
    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        hook = _deployHookProxyForManager(IPoolManager(address(mockManager)), address(this), address(this));
        lens = new MemeverseUniswapHookLens(IPoolManager(address(mockManager)));
        router = new MemeverseSwapRouter(
            IPoolManager(address(mockManager)), IMemeverseUniswapHook(address(hook)), lens, IPermit2(address(0xBEEF))
        );

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        key = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        poolId = key.toId();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        mockManager.initialize(key, SQRT_PRICE_1_1);
        hook.setPoolInitializer(address(router));
    }

    function testBeforeInitialize_DeploysInitializedLpClone() external view {
        (address lpToken,,) = hook.poolInfo(poolId);

        assertGt(lpToken.code.length, 0, "lp code");
        assertEq(MemeverseUniswapHook(address(hook)).lpTokenImplementation().code.length > 0, true, "impl code");
        assertEq(UniswapLP(lpToken).owner(), address(hook), "owner");
        assertEq(PoolId.unwrap(UniswapLP(lpToken).poolId()), PoolId.unwrap(poolId), "pool id");
        assertEq(UniswapLP(lpToken).memeverseUniswapHook(), address(hook), "hook");
        assertEq(UniswapLP(lpToken).name(), "Memeverse LP", "name");
        assertEq(UniswapLP(lpToken).symbol(), "MLP", "symbol");
        assertEq(UniswapLP(lpToken).decimals(), 18, "decimals");
    }

    function _initializePoolDirect(PoolKey memory targetKey, uint160 sqrtPriceX96) internal {
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(targetKey, sqrtPriceX96);
        mockManager.initialize(targetKey, sqrtPriceX96);
        hook.setPoolInitializer(address(router));
    }

    /// @notice Calls the hook-local pair-based public-swap protection setter.
    /// @dev Mirrors the launcher-side unlock-protection write path without depending on router helpers.
    function _setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime)
        internal
        returns (bool ok, bytes memory data)
    {
        return address(hook)
            .call(
                abi.encodeWithSignature("setPublicSwapResumeTime(address,address,uint40)", tokenA, tokenB, resumeTime)
            );
    }

    function _readPublicSwapResumeTime(PoolId targetPoolId) internal view returns (bool ok, uint40 resumeTime) {
        (bool success, bytes memory data) =
            address(hook).staticcall(abi.encodeWithSignature("publicSwapResumeTime(bytes32)", targetPoolId));
        if (!success || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint40)));
    }

    function testBeforeInitialize_RevertsWithoutAuthorizedInitializer() external {
        MockPoolManagerForHookLiquidity freshManager = new MockPoolManagerForHookLiquidity();
        MemeverseUniswapHook freshHook =
            _deployHookProxyForManager(IPoolManager(address(freshManager)), address(this), address(this));
        MockERC20 freshToken0 = new MockERC20("Fresh0", "F0", 18);
        MockERC20 freshToken1 = new MockERC20("Fresh1", "F1", 18);
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(freshToken0)),
            currency1: Currency.wrap(address(freshToken1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(freshHook))
        });

        vm.expectRevert(UNAUTHORIZED_POOL_INITIALIZER_SELECTOR);
        freshManager.initialize(freshKey, SQRT_PRICE_1_1);
    }

    function testBeforeInitialize_RevertsWhenNoPreAuthorization() external {
        hook.setPoolInitializer(address(this));
        PoolKey memory freshKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X0", "X0", 18))), Currency.wrap(address(token1)));

        vm.expectRevert(IMemeverseUniswapHook.UnauthorizedPoolInitialization.selector);
        mockManager.initialize(freshKey, SQRT_PRICE_1_1);

        hook.setPoolInitializer(address(router));
    }

    function testBeforeInitialize_RevertsWhenPriceMismatchesAuthorization() external {
        hook.setPoolInitializer(address(this));
        PoolKey memory freshKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X0", "X0", 18))), Currency.wrap(address(token1)));
        hook.authorizePoolInitialization(freshKey, SQRT_PRICE_1_1);

        uint160 wrongPrice = SQRT_PRICE_1_1 + 100;
        vm.expectRevert(IMemeverseUniswapHook.InvalidInitialPrice.selector);
        mockManager.initialize(freshKey, wrongPrice);

        hook.setPoolInitializer(address(router));
    }

    function testBeforeInitialize_AuthorizationConsumedAfterUse() external {
        hook.setPoolInitializer(address(this));
        PoolKey memory freshKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X0", "X0", 18))), Currency.wrap(address(token1)));
        hook.authorizePoolInitialization(freshKey, SQRT_PRICE_1_1);
        mockManager.initialize(freshKey, SQRT_PRICE_1_1);

        // After successful init, auth is deleted. Re-initializing the same pool reverts.
        vm.expectRevert(IMemeverseUniswapHook.UnauthorizedPoolInitialization.selector);
        mockManager.initialize(freshKey, SQRT_PRICE_1_1);

        hook.setPoolInitializer(address(router));
    }

    function testAuthorizePoolInitialization_RevertsWhenAuthorizationAlreadyActive() external {
        hook.setPoolInitializer(address(this));
        PoolKey memory freshKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X0", "X0", 18))), Currency.wrap(address(token1)));
        hook.authorizePoolInitialization(freshKey, SQRT_PRICE_1_1);

        vm.expectRevert(IMemeverseUniswapHook.PoolInitializationAlreadyAuthorized.selector);
        hook.authorizePoolInitialization(freshKey, SQRT_PRICE_1_1 + 1);

        hook.setPoolInitializer(address(router));
    }

    function testBeforeInitialize_FailedInitDoesNotConsumeAuth() external {
        hook.setPoolInitializer(address(this));
        PoolKey memory freshKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X0", "X0", 18))), Currency.wrap(address(token1)));
        hook.authorizePoolInitialization(freshKey, SQRT_PRICE_1_1);

        // Init with wrong price reverts. The revert unwinds the entire call so auth remains.
        uint160 wrongPrice = SQRT_PRICE_1_1 + 100;
        vm.expectRevert(IMemeverseUniswapHook.InvalidInitialPrice.selector);
        mockManager.initialize(freshKey, wrongPrice);

        // Auth is still active after the reverted attempt; retry with correct price succeeds.
        mockManager.initialize(freshKey, SQRT_PRICE_1_1);

        hook.setPoolInitializer(address(router));
    }

    /// @notice Verifies hook-local protection state is keyed only by `PoolId`.
    /// @dev The new unlock gate must not need token-pair guessing or launcher verdict helpers.
    function testPublicSwapResumeTime_StoresPerPoolWithoutAffectingOtherPools() external {
        hook.setLauncher(address(this));

        PoolKey memory secondKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("Token2", "TK2", 18))), Currency.wrap(address(token1)));
        PoolId secondPoolId = secondKey.toId();
        _initializePoolDirect(secondKey, SQRT_PRICE_1_1);

        (bool initialOk, uint40 initialResumeTime) = _readPublicSwapResumeTime(poolId);
        assertTrue(initialOk, "getter missing");
        assertEq(initialResumeTime, 0, "default resume time");

        (bool setOk, bytes memory setData) =
            _setPublicSwapResumeTime(address(token0), address(token1), uint40(block.timestamp + 1 hours));
        assertTrue(setOk, string(setData));

        (bool firstOk, uint40 firstResumeTime) = _readPublicSwapResumeTime(poolId);
        (bool secondOk, uint40 secondResumeTime) = _readPublicSwapResumeTime(secondPoolId);
        assertTrue(firstOk, "first getter missing");
        assertTrue(secondOk, "second getter missing");
        assertEq(firstResumeTime, uint40(block.timestamp + 1 hours), "first pool resume time");
        assertEq(secondResumeTime, 0, "second pool unchanged");
    }

    /// @notice Verifies hook-local protection can be cleared by writing zero.
    /// @dev `0` is the canonical "no active post-unlock public-swap protection" value.
    function testPublicSwapResumeTime_CanBeClearedBackToZero() external {
        hook.setLauncher(address(this));

        (bool setOk, bytes memory setData) =
            _setPublicSwapResumeTime(address(token0), address(token1), uint40(block.timestamp + 2 hours));
        assertTrue(setOk, string(setData));

        (bool clearOk, bytes memory clearData) = _setPublicSwapResumeTime(address(token0), address(token1), 0);
        assertTrue(clearOk, string(clearData));

        (bool readOk, uint40 resumeTime) = _readPublicSwapResumeTime(poolId);
        assertTrue(readOk, "getter missing");
        assertEq(resumeTime, 0, "resume time cleared");
    }

    function testPublicSwapResumeTime_StoresAndReadsResumeTime() external {
        hook.setLauncher(address(this));

        uint40 resumeTime = uint40(block.timestamp + 1 hours);
        (bool setOk, bytes memory setData) = _setPublicSwapResumeTime(address(token0), address(token1), resumeTime);
        assertTrue(setOk, string(setData));

        (bool resumeOk, uint40 storedResumeTime) = _readPublicSwapResumeTime(poolId);
        assertTrue(resumeOk, "resume getter missing");
        assertEq(storedResumeTime, resumeTime, "resumeTime");
    }

    /// @notice Executes test add liquidity uses unlock flow.
    /// @dev Confirms the hook uses the unlock flow before minting liquidity.
    function testAddLiquidity_UsesUnlockFlow() external {
        uint128 liquidity = _addLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        assertGt(liquidity, 0, "liquidity");
        assertGt(UniswapLP(liquidityToken).balanceOf(address(this)), 0, "lp balance");
        assertGt(mockManager.getLiquidity(poolId), 0, "pool liquidity");
    }

    /// @notice Executes test remove liquidity uses original sender for take.
    /// @dev Ensures liquidity outputs still go back to the txn sender when no custom recipient is provided.
    function testRemoveLiquidity_UsesOriginalSenderForTake() external {
        uint128 liquidity = _addLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        BalanceDelta delta = hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: liquidity, recipient: address(this)
            })
        );

        uint256 amount0Out = uint256(uint128(delta.amount0()));
        uint256 amount1Out = uint256(uint128(delta.amount1()));

        assertGt(amount0Out, 0, "amount0 out");
        assertGt(amount1Out, 0, "amount1 out");
        assertEq(mockManager.lastTakeRecipientAddress(), address(this), "take recipient");
        assertEq(UniswapLP(liquidityToken).balanceOf(address(this)), 0, "lp burned");
        assertEq(token0.balanceOf(address(this)), balance0Before + amount0Out, "token0 returned");
        assertEq(token1.balanceOf(address(this)), balance1Before + amount1Out, "token1 returned");
    }

    /// @notice Verifies native pairs are rejected during hook-managed pool initialization.
    function testInitializeReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        mockManager.initialize(nativeKey, SQRT_PRICE_1_1);
    }

    /// @notice Verifies addLiquidityCore rejects native pairs.
    function testAddLiquidityCoreReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: nativeKey.currency0,
                currency1: nativeKey.currency1,
                amount0Desired: 300 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }

    /// @notice Verifies pool initialization rejects non-default tick spacing.
    /// @dev Covers the hook's beforeInitialize validation for unsupported pool config.
    function testInitializeReverts_WhenTickSpacingIsNotDefault() external {
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(IMemeverseUniswapHook.TickSpacingNotDefault.selector);
        mockManager.initialize(invalidKey, SQRT_PRICE_1_1);
    }

    /// @notice Verifies pool initialization rejects non-dynamic fees.
    /// @dev Covers the hook's beforeInitialize validation for static-fee pools.
    function testInitializeReverts_WhenFeeIsNotDynamic() external {
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(IMemeverseUniswapHook.FeeMustBeDynamic.selector);
        mockManager.initialize(invalidKey, SQRT_PRICE_1_1);
    }

    /// @notice Verifies removeLiquidityCore rejects native pairs.
    function testRemoveLiquidityCoreReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: nativeKey.currency0,
                currency1: nativeKey.currency1,
                liquidity: 1 ether,
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies addLiquidity rejects pools that have not been initialized.
    /// @dev Covers the `PoolNotInitialized` branch before any quote or settlement logic.
    function testAddLiquidityCoreReverts_WhenPoolNotInitialized() external {
        PoolKey memory uninitializedKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X", "X", 18))), Currency.wrap(address(token1)));

        vm.expectRevert(IMemeverseUniswapHook.PoolNotInitialized.selector);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: uninitializedKey.currency0,
                currency1: uninitializedKey.currency1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                to: address(this)
            })
        );
    }

    /// @notice Verifies removeLiquidity rejects pools with no initialized liquidity.
    /// @dev Covers the `PoolNotInitialized` branch on liquidity exit.
    function testRemoveLiquidityCoreReverts_WhenPoolNotInitialized() external {
        PoolKey memory uninitializedKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X", "X", 18))), Currency.wrap(address(token1)));

        vm.expectRevert(IMemeverseUniswapHook.PoolNotInitialized.selector);
        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: uninitializedKey.currency0,
                currency1: uninitializedKey.currency1,
                liquidity: 1 ether,
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies direct removeLiquidityCore forwards assets when recipient differs from sender.
    /// @dev Covers the direct output-forwarding path inside `removeLiquidityCore`.
    function testRemoveLiquidityCore_ForwardsOutputsToDifferentRecipient() external {
        uint128 liquidity = _addLiquidity();
        (address liquidityToken,,) = hook.poolInfo(poolId);
        address recipient = address(0xCAFE);

        uint256 recipient0Before = token0.balanceOf(recipient);
        uint256 recipient1Before = token1.balanceOf(recipient);

        BalanceDelta delta = hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: liquidity, recipient: recipient
            })
        );

        assertEq(UniswapLP(liquidityToken).balanceOf(address(this)), 0, "lp burned");
        assertGt(token0.balanceOf(recipient), recipient0Before, "recipient token0");
        assertGt(token1.balanceOf(recipient), recipient1Before, "recipient token1");
        assertGt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
    }

    /// @notice Executes test router add liquidity uses hook core.
    /// @dev Confirms the router add-liquidity helper goes through the hook's liquidity plumbing.
    function testRouterAddLiquidity_UsesHookCore() external {
        uint128 liquidity = router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp
        );

        (address liquidityToken,,) = hook.poolInfo(poolId);
        assertGt(liquidity, 0, "liquidity");
        assertGt(UniswapLP(liquidityToken).balanceOf(address(this)), 0, "lp balance");
    }

    /// @notice Verifies router-mediated addLiquidity rejects native pairs.
    function testRouterAddLiquidityReverts_WhenPairUsesNativeCurrency() external {
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

    /// @notice Verifies router LP token lookup rejects native pairs.
    function testRouterLpTokenReverts_WhenPairUsesNativeCurrency() external {
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        router.lpToken(address(0), address(token1));
    }

    /// @notice Executes test router remove liquidity uses hook core.
    /// @dev Ensures the router remove path reuses the hook core logic for exits.
    function testRouterRemoveLiquidity_UsesHookCore() external {
        uint128 liquidity = router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp
        );
        (address liquidityToken,,) = hook.poolInfo(poolId);
        UniswapLP(liquidityToken).approve(address(router), liquidity);

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        BalanceDelta delta =
            router.removeLiquidity(key.currency0, key.currency1, liquidity, 1, 1, address(this), block.timestamp);

        assertGt(delta.amount0(), 0, "delta0");
        assertGt(delta.amount1(), 0, "delta1");
        assertGt(token0.balanceOf(address(this)), balance0Before, "token0 returned");
        assertGt(token1.balanceOf(address(this)), balance1Before, "token1 returned");
    }

    /// @notice Verifies claiming fees on an uninitialized pool reverts.
    /// @dev Covers the `PoolNotInitialized` branch in the low-level claim flow.
    function testClaimFeesCoreReverts_WhenPoolNotInitialized() external {
        PoolKey memory uninitializedKey =
            _dynamicPoolKey(Currency.wrap(address(new MockERC20("X", "X", 18))), Currency.wrap(address(token1)));

        vm.expectRevert(IMemeverseUniswapHook.PoolNotInitialized.selector);
        hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: uninitializedKey, recipient: address(this)}));
    }

    /// @notice Verifies `updateUserSnapshot` handles zero LP balances by only moving offsets.
    /// @dev Covers the zero-balance early branch without accruing pending fees.
    function testUpdateUserSnapshot_ZeroBalanceOnlyUpdatesOffsets() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp
        );

        (address lpToken,,) = hook.poolInfo(poolId);
        uint256 lpBalance = UniswapLP(lpToken).balanceOf(address(this));
        assertTrue(UniswapLP(lpToken).transfer(address(0xCAFE), lpBalance));

        hook.updateUserSnapshot(poolId, address(this));

        (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1) =
            hook.userFeeState(poolId, address(this));
        (, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(poolId);
        assertEq(fee0Offset, fee0PerShare, "fee0 offset");
        assertEq(fee1Offset, fee1PerShare, "fee1 offset");
        assertEq(pendingFee0, 0, "pending fee0");
        assertEq(pendingFee1, 0, "pending fee1");
    }

    /// @notice Verifies direct LP transfers cannot target the zero address.
    /// @dev Users must exit through hook-managed burn paths so total supply stays synchronized with fee accounting.
    function testUniswapLPTransfer_RevertsToZeroAddress() external {
        _addLiquidity();

        (address lpToken,,) = hook.poolInfo(poolId);
        vm.expectRevert();
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        UniswapLP(lpToken).transfer(address(0), 1);
    }

    /// @notice Verifies delegated LP transfers cannot target the zero address.
    /// @dev Prevents `transferFrom` from acting like an unsynchronized user burn.
    function testUniswapLPTransferFrom_RevertsToZeroAddress() external {
        _addLiquidity();

        (address lpToken,,) = hook.poolInfo(poolId);
        UniswapLP(lpToken).approve(address(0xBEEF), 1);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        UniswapLP(lpToken).transferFrom(address(this), address(0), 1);
    }

    /// @notice Verifies LP fee growth uses the live-share supply and Q128 precision.
    /// @dev With no permanently locked LP, all minted liquidity participates in fee growth.
    function testLpFeeGrowth_UsesEffectiveSupplyAndQ128Accumulator() external {
        uint128 liquidity = _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );

        vm.prank(address(mockManager));
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        (, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(poolId);
        uint256 expectedFeeGrowthX128 = FullMath.mulDiv(quote.estimatedLpFeeAmount, Q128, liquidity);

        assertEq(fee0PerShare, expectedFeeGrowthX128, "fee0 growth");
        assertEq(fee1PerShare, 0, "fee1 growth");
    }

    /// @notice Verifies LP-fee hot paths do not call the LP token's external `totalSupply()`.
    /// @dev Locks both public swap fee collection and launch-settlement LP fee credit to the hook-side cached supply path.
    function testLpFeeHotPaths_UseCachedSupplyInsteadOfExternalTotalSupply() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);

        (address lpToken,,) = hook.poolInfo(poolId);
        vm.mockCallRevert(lpToken, abi.encodeWithSelector(TOTAL_SUPPLY_SELECTOR), bytes("unexpected totalSupply"));

        vm.prank(address(mockManager));
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        vm.clearMockedCalls();
        vm.mockCallRevert(lpToken, abi.encodeWithSelector(TOTAL_SUPPLY_SELECTOR), bytes("unexpected totalSupply"));

        hook.setLauncher(address(this));
        token1.mint(address(mockManager), 1_000_000 ether);

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies all LP shares and pool liquidity can be removed after the final burn.
    /// @dev Removing the last user position must not leave protocol-locked LP dust behind.
    function testFullRemovalLeavesNoLockedLiquidityOrSupply() external {
        uint128 liquidity = _addLiquidity();
        (address lpToken,,) = hook.poolInfo(poolId);

        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: liquidity, recipient: address(this)
            })
        );

        assertEq(UniswapLP(lpToken).totalSupply(), 0, "no locked LP supply");
        assertEq(UniswapLP(lpToken).balanceOf(address(0)), 0, "zero address LP balance");
        assertEq(getCachedLpTotalSupplyForTest(address(hook), poolId), 0, "cached supply");
        assertEq(mockManager.getLiquidity(poolId), 0, "pool liquidity");
    }

    /// @notice Verifies the hook's cached LP total supply stays in sync with the actual LP token contract.
    /// @dev A mismatch would corrupt fee-per-share accounting.
    function testCachedLpTotalSupply_MatchesActualTotalSupply() external {
        // After addLiquidity: cached should equal LP token totalSupply
        uint128 liquidity = _addLiquidity();
        (address lpToken,,) = hook.poolInfo(poolId);

        uint256 actualSupply = UniswapLP(lpToken).totalSupply();
        uint256 cachedSupply = getCachedLpTotalSupplyForTest(address(hook), poolId);
        assertEq(cachedSupply, actualSupply, "cached supply after add");

        // After partial removal: still in sync
        uint128 halfLiquidity = liquidity / 2;
        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: halfLiquidity, recipient: address(this)
            })
        );

        actualSupply = UniswapLP(lpToken).totalSupply();
        cachedSupply = getCachedLpTotalSupplyForTest(address(hook), poolId);
        assertEq(cachedSupply, actualSupply, "cached supply after partial remove");

        // After full removal: still in sync with no permanently locked supply
        hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                liquidity: liquidity - halfLiquidity,
                recipient: address(this)
            })
        );

        actualSupply = UniswapLP(lpToken).totalSupply();
        cachedSupply = getCachedLpTotalSupplyForTest(address(hook), poolId);
        assertEq(cachedSupply, actualSupply, "cached supply after full remove");
        assertEq(actualSupply, 0, "no locked supply remains");
        assertEq(mockManager.getLiquidity(poolId), 0, "pool liquidity after full remove");
    }

    /// @notice Verifies liquidity cannot be minted directly to the zero address.
    /// @dev Only hook-managed burn paths may move LP supply out of circulation.
    function testAddLiquidityCoreReverts_WhenRecipientIsZeroAddress() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(0)
            })
        );
    }

    /// @notice Verifies the first liquidity add does not mint permanently locked LP shares.
    /// @dev Zero address remains fee-neutral because it receives no LP balance.
    function testFirstLiquidityAdd_DoesNotMintLockedZeroAddressShares() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        (address lpToken,,) = hook.poolInfo(poolId);

        vm.prank(address(mockManager));
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        assertEq(UniswapLP(lpToken).balanceOf(address(0)), 0, "zero address LP balance");

        (uint256 fee0Amount, uint256 fee1Amount) =
            lens.claimableFees(IMemeverseUniswapHook(address(hook)), key, address(0));
        assertEq(fee0Amount, 0, "zero address claimable fee0");
        assertEq(fee1Amount, 0, "zero address claimable fee1");

        hook.updateUserSnapshot(poolId, address(0));

        (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1) =
            hook.userFeeState(poolId, address(0));
        (, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(poolId);

        assertEq(fee0Offset, fee0PerShare, "zero address fee0 offset");
        assertEq(fee1Offset, fee1PerShare, "zero address fee1 offset");
        assertEq(pendingFee0, 0, "zero address pending fee0");
        assertEq(pendingFee1, 0, "zero address pending fee1");
    }

    /// @notice Verifies callers can redirect claimed fees to a different recipient without signatures.
    /// @dev Covers the owner-direct claim surface after relay support was removed.
    function testClaimFeesCore_DirectClaimCanRedirectRecipient() external {
        router.addLiquidity(
            key.currency0, key.currency1, 100 ether, 100 ether, 90 ether, 90 ether, address(this), block.timestamp
        );
        hook.setProtocolFeeCurrency(key.currency0, true);

        vm.prank(address(mockManager));
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        address recipient = address(0xCAFE);
        uint256 balanceBefore = token0.balanceOf(recipient);
        (uint256 fee0Amount, uint256 fee1Amount) =
            hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: key, recipient: recipient}));

        assertGt(fee0Amount, 0, "fee0 claimed");
        assertEq(fee1Amount, 0, "fee1 claimed");
        assertEq(token0.balanceOf(recipient), balanceBefore + fee0Amount, "recipient received fee");
    }

    function testClaimFeesCoreReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams({key: nativeKey, recipient: address(this)}));
    }

    /// @notice Verifies owner config setters reject invalid inputs and update state.
    /// @dev Covers treasury and launch-fee configuration branches on the hook.
    function testOwnerSetters_UpdateStateAndRejectInvalidInputs() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setTreasury(address(0));

        hook.setTreasury(address(0xBEEF));
        assertEq(hook.treasury(), address(0xBEEF), "treasury");

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.setProtocolFeeCurrency(CurrencyLibrary.ADDRESS_ZERO, true);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.setProtocolFeeCurrency(CurrencyLibrary.ADDRESS_ZERO, true);
    }

    /// @notice Verifies swap quoting reverts when neither side is enabled for protocol fees.
    /// @dev Covers the `CurrencyNotSupported` branch in fee-context resolution.
    function testQuoteSwapReverts_WhenProtocolFeeCurrencyUnsupported() external {
        vm.expectRevert(IMemeverseUniswapHook.CurrencyNotSupported.selector);
        lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
    }

    function testQuoteSwapReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            nativeKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
    }

    function testQuoteSwapReverts_WhenPoolKeyUsesDifferentHook() external {
        hook.setProtocolFeeCurrency(key.currency0, true);

        PoolKey memory mismatchedKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(address(0xBEEF))
        });

        vm.expectRevert(IMemeverseUniswapHook.HookAddressMismatch.selector);
        lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            mismatchedKey,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
    }

    function testDirectManagerSwapReverts_WhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        mockManager.swapAsUnlocked(
            nativeKey, SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
    }

    /// @notice Covers the local direct/core fail-closed branch for exact-input underfills without router checks.
    /// @custom:dev-only-harness Uses the hook-liquidity manager mock to witness fee-accounting rollback on revert.
    function testDirectManagerSwapReverts_WhenExactInputPartialFills() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency1, true);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        vm.warp(block.timestamp + 900);
        mockManager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        RollbackSnapshot memory s = _snapshotRollback();

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        _assertRollbackUnchanged(s);
    }

    /// @notice Covers the local direct/core branch where output-fee exact-input swaps consume the net pool input from `beforeSwap`.
    /// @custom:dev-only-harness Locks hook-side handling under the local hook-liquidity manager mock instead of proving full v4 execution semantics.
    function testDirectManagerSwapPasses_WhenOneForZeroExactInputUsesNetPoolInputOnOutputFeePool() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
        uint256 expectedPoolInput = quote.estimatedUserInputAmount - quote.estimatedLpFeeAmount;
        uint256 treasury0Before = token0.balanceOf(hook.treasury());

        mockManager.setNextExactInputPoolInputAmount(poolId, expectedPoolInput);
        BalanceDelta delta = mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        assertEq(uint256(uint128(-delta.amount1())), expectedPoolInput, "pool input net of lp fee");
        assertGt(uint256(uint128(delta.amount0())), 0, "output received");
        assertGt(token0.balanceOf(hook.treasury()), treasury0Before, "output-side protocol fee collected");
    }

    /// @notice Covers the local direct/core fail-closed branch for exact-input underfills on input-side fee pools.
    /// @custom:dev-only-harness Uses the hook-liquidity manager mock to witness atomic rollback instead of proving production partial-fill semantics.
    function testDirectManagerSwapReverts_WhenExactInputPartialFillsOnInputFeePool() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true); // input-side fee for zeroForOne=true
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        vm.warp(block.timestamp + 900);
        mockManager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        RollbackSnapshot memory s = _snapshotRollback();

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        _assertRollbackUnchanged(s);
    }

    /// @notice Covers the mirrored local direct/core fail-closed branch for one-for-zero exact-input underfills on output-fee pools.
    /// @custom:dev-only-harness Uses the hook-liquidity manager mock to witness rollback symmetry instead of proving production partial-fill semantics.
    function testDirectManagerSwapReverts_WhenOneForZeroExactInputPartialFillsOnOutputFeePool() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        vm.warp(block.timestamp + 900);
        mockManager.setNextExactInputPoolInputAmount(poolId, 99 ether);

        RollbackSnapshot memory s = _snapshotRollback();

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        _assertRollbackUnchanged(s);
    }

    /// @notice Covers the local launch-settlement fail-closed branch for exact-input underfills.
    /// @custom:dev-only-harness Uses the hook-liquidity manager mock to witness rollback for balances, fee growth, and dynamic state.
    function testExecutePreorderSettlement_RevertsWhenExactInputPartiallyFills() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);
        // Seed non-zero EWVWAP state so rollback assertions are non-trivial.
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        mockManager.setNextExactInputPoolInputAmount(poolId, 98 ether);

        RollbackSnapshot memory s = _snapshotRollback();
        uint256 hookToken0Before = token0.balanceOf(address(hook));

        vm.expectRevert(IMemeverseUniswapHook.ExactInputPartialFill.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        _assertRollbackUnchanged(s);
        assertEq(token0.balanceOf(address(hook)), hookToken0Before, "hook token0 unchanged");
    }

    function testExecutePreorderSettlement_RevertsWhenDynamicFeeEngineUnauthorized() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);

        // Bypass the admin guard so settlement exercises a broken bound engine directly.
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this));
        bytes32 baseSlot = HOOK_SLOT;
        vm.store(address(hook), bytes32(uint256(baseSlot) + 11), bytes32(uint256(uint160(address(newEngine)))));

        vm.expectRevert(abi.encodeWithSelector(IMemeverseDynamicFeeEngine.UnauthorizedCaller.selector, address(hook)));
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies launch fee floor dominates immediately after pool initialization and decays to the minimum fee.
    /// @dev Covers the new launch fee scheduler on top of the existing dynamic fee engine.
    function testQuoteSwap_UsesLaunchFeeFloorAndDecaysToMinFee() external {
        hook.setProtocolFeeCurrency(key.currency0, true);

        IMemeverseUniswapHook.SwapQuote memory initialQuote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
        assertEq(initialQuote.feeBps, 5000, "initial launch fee");

        vm.warp(block.timestamp + 900);

        IMemeverseUniswapHook.SwapQuote memory maturedQuote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );
        assertEq(maturedQuote.feeBps, 100, "matured fee");
    }

    /// @notice Verifies preorder settlement can only be initiated by the bound launcher.
    function testExecutePreorderSettlement_RevertsWhenCallerNotLauncher() external {
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setLauncher(address(0xABCD));

        vm.expectRevert(IMemeverseUniswapHook.Unauthorized.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    function testExecutePreorderSettlement_RevertsWhenPairUsesNativeCurrency() external {
        PoolKey memory nativeKey = _dynamicPoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token1)));
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setLauncher(address(this));

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: nativeKey,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies preorder settlement requires the pool to be initialized.
    function testExecutePreorderSettlement_RevertsWhenPoolNotInitialized() external {
        MockPoolManagerForHookLiquidity uninitializedManager = new MockPoolManagerForHookLiquidity();
        MemeverseUniswapHook uninitializedHook =
            _deployHookProxyForManager(IPoolManager(address(uninitializedManager)), address(this), address(this));
        PoolKey memory uninitializedKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(uninitializedHook))
        });
        uninitializedHook.setProtocolFeeCurrency(uninitializedKey.currency0, true);
        uninitializedHook.setLauncher(address(this));

        vm.expectRevert(IMemeverseUniswapHook.PoolNotInitialized.selector);
        uninitializedHook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: uninitializedKey,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    /// @notice Verifies preorder settlement output-side protocol fee path.
    /// @dev When the output currency is the supported protocol fee currency, the executor takes the fee
    ///      from the output before delivering to the recipient. Covers the executor's `!data.protocolFeeOnInput` branch.
    function testExecutePreorderSettlement_OutputSideProtocolFee() external {
        _addLiquidity();
        // currency1 is the output currency for zeroForOne=true swaps.
        hook.setProtocolFeeCurrency(key.currency1, true);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);
        // Mint output tokens to the mock manager so it can pay out the swap result.
        token1.mint(address(mockManager), 1_000_000 ether);

        address treasuryAddr = hook.treasury();
        uint256 treasury1Before = token1.balanceOf(treasuryAddr);
        uint256 recipient1Before = token1.balanceOf(address(this));

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        uint256 treasury1After = token1.balanceOf(treasuryAddr);
        uint256 recipient1After = token1.balanceOf(address(this));

        // Treasury must receive the output-side protocol fee.
        assertGt(treasury1After, treasury1Before, "treasury received output-side protocol fee");
        // Recipient must receive a net positive output.
        assertGt(recipient1After, recipient1Before, "recipient received output");
    }

    /// @notice Verifies owner launch-fee and launcher setters update state and reject invalid inputs.
    /// @dev Covers the launch scheduler plus explicit launcher binding configuration surface.
    function testOwnerSetters_UpdateLaunchFeeConfigAndLauncher() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setLauncher(address(0));

        hook.setLauncher(address(0xD00D));
        assertEq(hook.launcher(), address(0xD00D), "launcher");

        vm.expectRevert(IMemeverseUniswapHook.ZeroValue.selector);
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 5000, minFeeBps: 100, decayDurationSeconds: 0})
        );

        vm.expectRevert(IMemeverseUniswapHook.ZeroValue.selector);
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 99, minFeeBps: 100, decayDurationSeconds: 900})
        );

        vm.expectRevert(IMemeverseUniswapHook.ZeroValue.selector);
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 10_001, minFeeBps: 100, decayDurationSeconds: 900})
        );

        vm.expectRevert(IMemeverseUniswapHook.ZeroValue.selector);
        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({
                startFeeBps: 5_000, minFeeBps: 10_001, decayDurationSeconds: 900
            })
        );

        hook.setDefaultLaunchFeeConfig(
            IMemeverseDynamicFeeEngine.LaunchFeeConfig({startFeeBps: 4000, minFeeBps: 100, decayDurationSeconds: 900})
        );

        (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds) = hook.defaultLaunchFeeConfig();
        assertEq(startFeeBps, 4000, "start fee");
        assertEq(minFeeBps, 100, "min fee");
        assertEq(decayDurationSeconds, 900, "duration");
    }

    function testOwnerSetter_UpdatesPreorderSettlementExecutor() external {
        MemeversePreorderSettlementExecutor newExecutor = new MemeversePreorderSettlementExecutor(address(hook));

        vm.expectEmit(true, true, true, true, address(hook));
        emit IMemeverseUniswapHook.PreorderSettlementExecutorUpdated(
            address(hook.preorderSettlementExecutor()), address(newExecutor)
        );
        hook.setPreorderSettlementExecutor(newExecutor);

        assertEq(address(hook.preorderSettlementExecutor()), address(newExecutor), "executor");
    }

    function testOwnerSetter_RevertsForZeroAddressOrUnreadyExecutor() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setPreorderSettlementExecutor(MemeversePreorderSettlementExecutor(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.PreorderSettlementExecutorCodeNotReady.selector, address(0xBEEF)
            )
        );
        hook.setPreorderSettlementExecutor(MemeversePreorderSettlementExecutor(address(0xBEEF)));
    }

    function testOwnerSetter_UpdatesLpTokenImplementation() external {
        UniswapLP newImpl = new UniswapLP();

        vm.expectEmit(true, true, true, true, address(hook));
        emit IMemeverseUniswapHook.LPTokenImplementationUpdated(hook.lpTokenImplementation(), address(newImpl));
        hook.setLpTokenImplementation(address(newImpl));

        assertEq(hook.lpTokenImplementation(), address(newImpl), "lp impl");
    }

    function testOwnerSetter_RevertsForZeroOrUnreadyLpImplementation() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setLpTokenImplementation(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.LPTokenImplementationCodeNotReady.selector, address(0xBEEF))
        );
        hook.setLpTokenImplementation(address(0xBEEF));
    }

    /// @notice Verifies the hook reverts when the executor reports a protocol fee that does not
    ///         match the hook's own derivation from the realized swap output.
    /// @dev Deploys a mock executor that performs a real swap but inflates the reported fee by 1 wei,
    ///      exercising the `PreorderSettlementFeeMismatch` guard in `executePreorderSettlement`.
    function testExecutePreorderSettlement_RevertsOnFeeMismatch() external {
        _addLiquidity();
        // Use output-side protocol fee so the mismatch branch is exercised.
        hook.setProtocolFeeCurrency(key.currency1, true);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);
        token1.mint(address(mockManager), 1_000_000 ether);

        FeeMismatchSettlementExecutor mockExec = new FeeMismatchSettlementExecutor(address(hook));
        hook.setPreorderSettlementExecutor(IMemeversePreorderSettlementExecutor(address(mockExec)));

        vm.expectRevert(IMemeverseUniswapHook.PreorderSettlementFeeMismatch.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
    }

    function testPreorderSettlementExecutorRejectsDirectCalls() external {
        MemeversePreorderSettlementExecutor executor =
            MemeversePreorderSettlementExecutor(address(hook.preorderSettlementExecutor()));

        vm.expectRevert(MemeversePreorderSettlementExecutor.Unauthorized.selector);
        executor.execute(
            IMemeversePreorderSettlementExecutor.ExecuteParams({
                poolManager: IPoolManager(address(mockManager)),
                recipient: address(this),
                treasury: address(this),
                key: key,
                swapParams: SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: 0}),
                protocolFeeOnInput: true,
                protocolFeeOutputBps: 0
            })
        );
    }

    /// @dev The setter rejects an executor immutable-bound to a different hook, so a stray executor
    ///      cannot be wired into this hook's settlement path. `wrongExecutor.HOOK() == address(0xDEAD)`
    ///      while `address(hook)` is the current hook, so validation reverts HookMismatch.
    function testSetPreorderSettlementExecutor_RejectsExecutorBoundToOtherHook() external {
        MemeversePreorderSettlementExecutor wrongExecutor = new MemeversePreorderSettlementExecutor(address(0xDEAD));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.PreorderSettlementExecutorHookMismatch.selector,
                address(wrongExecutor),
                address(hook),
                address(0xDEAD)
            )
        );
        hook.setPreorderSettlementExecutor(wrongExecutor);
    }

    /// @dev Proxy initialize runs the same executor-binding check before engine ownership validation, so
    ///      an executor immutable-bound to the wrong hook aborts initialization outright. The predicted
    ///      hook-proxy address is computed from the deploy order: executor and lp-token are created before
    ///      `vm.getNonce` is read, then `_deployEngineProxyForManager` (engine impl + proxy) plus the hook
    ///      impl plus the hook proxy land the proxy at `getNonce + 3`.
    function testProxyInitialize_RejectsExecutorBoundToOtherHook() external {
        UniswapLP lpTokenImplementation = new UniswapLP();
        MemeversePreorderSettlementExecutor wrongExecutor = new MemeversePreorderSettlementExecutor(address(0xDEAD));
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        MemeverseDynamicFeeEngine engine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), predictedHook, predictedHook);
        MemeverseUniswapHook implementation = new MemeverseUniswapHook(IPoolManager(address(mockManager)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.PreorderSettlementExecutorHookMismatch.selector,
                address(wrongExecutor),
                predictedHook,
                address(0xDEAD)
            )
        );
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                MemeverseUniswapHook.initialize,
                (address(this), address(this), engine, address(lpTokenImplementation), wrongExecutor)
            )
        );
    }

    /// @dev The executor is immutable-bound to its hook (`HOOK`) and `execute` rejects
    ///      any caller with `msg.sender != HOOK` (and any `key.hooks != HOOK`). A forged `key.hooks == caller`
    ///      therefore cannot impersonate the hook — the forged direct call reverts at the `msg.sender != HOOK`
    ///      guard before any swap can move funds. Seeds the executor with tokens and asserts a forged direct
    ///      call leaves its balance (and the manager's) untouched. try/catch tolerates the revert so the
    ///      no-funds-move invariant is asserted regardless.
    function testPreorderExecutor_ForgedHookDirectCallCannotDrainExecutor() external {
        MemeversePreorderSettlementExecutor executor =
            MemeversePreorderSettlementExecutor(address(hook.preorderSettlementExecutor()));
        token0.mint(address(executor), 100 ether); // prove even a funded executor cannot be drained
        uint256 executorBefore = token0.balanceOf(address(executor));
        uint256 managerBefore = token0.balanceOf(address(mockManager));

        // Attacker forges key.hooks == caller; the `msg.sender != HOOK` guard still rejects it.
        PoolKey memory forgedKey = _dynamicPoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        forgedKey.hooks = IHooks(address(this));

        // try/catch tolerates either outcome on purpose: the forged hooks have no beforeSwap so the call
        // reverts today, but the invariant we lock is "no funds move" regardless. executor.execute is a
        // single external call, so any mid-execution revert rolls back all of its state changes — the
        // bidirectional balance assertions below hold whether the forged call reverts or returns.
        try executor.execute(
            IMemeversePreorderSettlementExecutor.ExecuteParams({
                poolManager: IPoolManager(address(mockManager)),
                recipient: address(this),
                treasury: address(this),
                key: forgedKey,
                swapParams: SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: 0}),
                protocolFeeOnInput: true,
                protocolFeeOutputBps: 0
            })
        ) {}
            catch {}

        assertEq(token0.balanceOf(address(executor)), executorBefore, "executor drained via forged call");
        assertEq(token0.balanceOf(address(mockManager)), managerBefore, "manager balance mutated");
    }

    /// @notice A malicious ERC20 reentering a swap during preorder settlement must NOT hit the fee-neutral bypass.
    /// @dev While the settlement marker is set, the executor's `settle` fires the input token's `transfer`, which
    ///      reenters a pool swap. That reentrant swap runs with `sender == token` (not the executor), so it misses
    ///      the bypass and takes the normal path — here, the public-swap block rejects it. The reenterer swallows
    ///      that revert so the settlement still completes (its own executor swap did bypass), and the test asserts
    ///      the reentry both fired and was rejected. This locks the design comment on the executor marker
    ///      (see MemeverseUniswapHook.executePreorderSettlement).
    function testExecutePreorderSettlement_ReentrantTokenSwapDoesNotBypassFees() external {
        // Evil token becomes the settlement input currency. Respect V4 pair ordering; keep it on the input side.
        PreorderSettlementReenterer evil = new PreorderSettlementReenterer();
        evil.mint(address(this), 1_000_000 ether);
        bool evilIsCurrency0 = address(evil) < address(token1);
        PoolKey memory evilKey = evilIsCurrency0
            ? _dynamicPoolKey(Currency.wrap(address(evil)), Currency.wrap(address(token1)))
            : _dynamicPoolKey(Currency.wrap(address(token1)), Currency.wrap(address(evil)));
        PoolId evilPoolId = evilKey.toId();
        // Input is currency0 when zeroForOne=true, currency1 otherwise — keep evil as the input either way.
        bool zeroForOne = evilIsCurrency0;

        // Initialize the evil pool on the hook + mock manager, mirroring setUp's sequence.
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(evilKey, SQRT_PRICE_1_1);
        mockManager.initialize(evilKey, SQRT_PRICE_1_1);

        // Seed active LP shares so the settlement's liquidity guard passes (mock manager liquidity is irrelevant).
        seedActiveLiquiditySharesForTest(address(hook), evilPoolId, address(this), 100 ether);

        // Configure the settlement path: evil as the input-side fee currency, this contract as launcher,
        // and a public-swap-block window so the reentrant swap fails closed and deterministically.
        hook.setProtocolFeeCurrency(Currency.wrap(address(evil)), true);
        hook.setLauncher(address(this));
        _setPublicSwapResumeTime(address(evil), address(token1), uint40(block.timestamp + 1 hours));
        evil.approve(address(hook), type(uint256).max);
        // Fund the output currency so the settlement can complete (the executor's take pays token1 out).
        token1.mint(address(mockManager), 1_000_000 ether);

        // Arm the evil token to reenter exactly one swap from inside the executor's settle window.
        evil.arm(
            mockManager,
            evilKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: 0})
        );

        // The settlement completes: its own swap runs as sender=executor and takes the bypass, so the
        // public-swap block does not affect it. (If the bypass check were removed, this would revert
        // PublicSwapDisabled and fail the test — isolating the reentry as the only blocked swap.)
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        // The reentrant swap fired from inside settle and was rejected (it hit the public-swap block),
        // proving it did NOT take the executor bypass despite the marker being set for the whole window.
        assertTrue(evil.reentryFired(), "reentrant swap fired during executor settle");
        assertTrue(evil.reentryBlocked(), "reentrant swap rejected - did not bypass fees");
    }

    /// @notice A callback-token firing `transferFrom` while the hook credits `netInput` to the executor
    ///         cannot forge the hook to drive its own settlement swap.
    /// @dev The settlement moves `netInput` to the executor via `transferFrom`; the evil token reenters
    ///      `executor.execute` AFTER that credit, forging `key.hooks == address(this)` (which would have
    ///      passed a legacy `msg.sender == key.hooks` guard). The executor's immutable-HOOK guard rejects
    ///      the reentrant call with `Unauthorized` because `msg.sender == evil token != HOOK`, even though
    ///      the executor now holds the credited `netInput`. The settlement's own legit executor call
    ///      (`msg.sender == hook == HOOK`) still completes.
    function testExecutePreorderSettlement_TransferFromCallbackCannotForgeHook() external {
        PreorderSettlementTransferFromReenterer evil = new PreorderSettlementTransferFromReenterer();
        evil.mint(address(this), 1_000_000 ether);
        bool evilIsCurrency0 = address(evil) < address(token1);
        PoolKey memory evilKey = evilIsCurrency0
            ? _dynamicPoolKey(Currency.wrap(address(evil)), Currency.wrap(address(token1)))
            : _dynamicPoolKey(Currency.wrap(address(token1)), Currency.wrap(address(evil)));
        PoolId evilPoolId = evilKey.toId();
        bool zeroForOne = evilIsCurrency0;

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(evilKey, SQRT_PRICE_1_1);
        mockManager.initialize(evilKey, SQRT_PRICE_1_1);
        seedActiveLiquiditySharesForTest(address(hook), evilPoolId, address(this), 100 ether);
        hook.setProtocolFeeCurrency(Currency.wrap(address(evil)), true);
        hook.setLauncher(address(this));
        evil.approve(address(hook), type(uint256).max);
        token1.mint(address(mockManager), 1_000_000 ether);

        evil.arm(
            hook.preorderSettlementExecutor(),
            IPoolManager(address(mockManager)),
            evilKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: 0})
        );

        // Settlement completes: the evil token's transferFrom reenters executor.execute with a forged
        // key.hooks, but msg.sender (the evil token) != HOOK, so it reverts Unauthorized (swallowed by the
        // mock). The settlement's own legit executor call (msg.sender == hook == HOOK) still proceeds.
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        assertTrue(evil.reentryFired(), "transferFrom reentry fired during netInput transfer");
        assertTrue(evil.reentryBlocked(), "forged executor.execute rejected - immutable-HOOK guard held");
    }

    function testImplementationInitializeReverts() external {
        MemeverseDynamicFeeEngine engineImpl = new MemeverseDynamicFeeEngine(IPoolManager(address(mockManager)));
        MemeverseDynamicFeeEngine engine = MemeverseDynamicFeeEngine(
            address(
                new ERC1967Proxy(
                    address(engineImpl),
                    abi.encodeCall(MemeverseDynamicFeeEngine.initialize, (address(this), address(this)))
                )
            )
        );
        MemeverseUniswapHook implementation = new MemeverseUniswapHook(IPoolManager(address(mockManager)));
        UniswapLP lpTokenImplementation = new UniswapLP();
        MemeversePreorderSettlementExecutor preorderSettlementExecutor =
            new MemeversePreorderSettlementExecutor(address(implementation));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(this), address(this), engine, address(lpTokenImplementation), preorderSettlementExecutor
        );
    }

    function testProxyInitializeSetsOwnerTreasuryAndLaunchFeeConfig() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(0xA11CE), address(0xFEE));

        assertEq(initialized.owner(), address(0xA11CE), "owner");
        assertEq(initialized.treasury(), address(0xFEE), "treasury");

        (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds) = initialized.defaultLaunchFeeConfig();
        assertEq(startFeeBps, 5000, "start fee");
        assertEq(minFeeBps, 100, "min fee");
        assertEq(decayDurationSeconds, 900, "duration");
    }

    function testProductionProxyInitializeRevertsWhenProxyAddressHasInvalidHookFlags() external {
        address predictedProxy = _nextInvalidProductionHookProxyAddress();
        MemeverseDynamicFeeEngine engine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), predictedProxy, predictedProxy);
        MemeverseUniswapHook implementation = new MemeverseUniswapHook(IPoolManager(address(mockManager)));
        bytes memory data = abi.encodeCall(
            MemeverseUniswapHook.initialize,
            (
                address(this),
                address(this),
                engine,
                address(new UniswapLP()),
                new MemeversePreorderSettlementExecutor(predictedProxy)
            )
        );

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predictedProxy));
        new TransparentUpgradeableProxy(address(implementation), address(this), data);
    }

    function testProxyInitializeRevertsWhenEngineOwnerIsNotHook() external {
        UniswapLP lpTokenImplementation = new UniswapLP();
        address predictedHook = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        MemeversePreorderSettlementExecutor preorderSettlementExecutor =
            new MemeversePreorderSettlementExecutor(predictedHook);
        MemeverseDynamicFeeEngine engine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this), predictedHook);
        MemeverseUniswapHook implementation = new MemeverseUniswapHook(IPoolManager(address(mockManager)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DYNAMIC_FEE_ENGINE_OWNER_MISMATCH_SELECTOR, address(engine), predictedHook, address(this)
            )
        );
        new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            abi.encodeCall(
                MemeverseUniswapHook.initialize,
                (address(this), address(this), engine, address(lpTokenImplementation), preorderSettlementExecutor)
            )
        );
    }

    function testNonOwnerCannotUpgrade() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(this));
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));
        address proxyAdmin = address(uint160(uint256(vm.load(address(initialized), ERC1967Utils.ADMIN_SLOT))));

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(initialized))), address(newImplementation), bytes("")
            );
    }

    /// @notice Verifies a ProxyAdmin upgrade to the V2 facade preserves V1 hook storage (owner, treasury, launcher,
    ///         poolInitializer).
    /// @dev Mirrors the #9 engine facade upgrade test: the facade shell does not inherit MemeverseUniswapHook, so
    ///      it exposes no V1 getters and post-upgrade storage is read via `vm.load` against the V1 storage slots
    ///      (OutrunOwnableUpgradeable owner slot + the hook ERC7201 namespace struct field offsets). Transparent proxy
    ///      upgrade authorization lives on ProxyAdmin, so implementation runtime does not carry an upgrade guard.
    function testOwnerCanUpgradeAndPreserveStorage() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(0xFEE));
        initialized.setLauncher(address(0xD00D));
        initialized.setPoolInitializer(address(0xBEEF));

        // Snapshot the V1-set storage through the V1 getters while V1 is still live.
        bytes32 ownableSlot = 0x7f241041d6960443a72c6e46e3b41069d0f1a8933ddb434b1da86a3f3cba9f00;
        bytes32 snapshotOwner = vm.load(address(initialized), ownableSlot);
        bytes32 snapshotTreasury = vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_TREASURY));
        bytes32 snapshotLauncher = vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_LAUNCHER));
        bytes32 snapshotPoolInitializer =
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_POOL_INITIALIZER));

        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));
        address proxyAdmin = address(uint160(uint256(vm.load(address(initialized), ERC1967Utils.ADMIN_SLOT))));
        assertTrue(proxyAdmin != address(0), "proxy admin");
        assertEq(ProxyAdmin(proxyAdmin).owner(), address(this), "proxy admin owner");

        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(initialized))), address(newImplementation), bytes("")
            );

        assertEq(MemeverseUniswapHookV2(address(initialized)).version(), 2, "version");
        assertEq(vm.load(address(initialized), ownableSlot), snapshotOwner, "owner survived");
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_TREASURY)),
            snapshotTreasury,
            "treasury survived"
        );
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_LAUNCHER)),
            snapshotLauncher,
            "launcher survived"
        );
        assertEq(
            vm.load(address(initialized), bytes32(uint256(HOOK_SLOT) + OFF_POOL_INITIALIZER)),
            snapshotPoolInitializer,
            "poolInitializer survived"
        );
    }

    function testProxyAdminCanUpgradeToImplementationWithDifferentPoolManager() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(this));
        MockPoolManagerForHookLiquidity differentManager = new MockPoolManagerForHookLiquidity();
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(differentManager)));
        address proxyAdmin = address(uint160(uint256(vm.load(address(initialized), ERC1967Utils.ADMIN_SLOT))));

        // The implementation no longer carries a poolManager upgrade guard; operators must enforce that off-chain.
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(payable(address(initialized))), address(newImplementation), bytes("")
            );

        assertEq(MemeverseUniswapHookV2(address(initialized)).version(), 2, "version");
    }

    function testConstructorRevertsWhenPoolManagerIsZero() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        new MemeverseUniswapHook(IPoolManager(address(0)));
    }

    function testProxyInitializeRevertsOnSecondCall() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(0xFEE));
        IMemeverseDynamicFeeEngine engine = IMemeverseDynamicFeeEngine(address(initialized.dynamicFeeEngine()));
        UniswapLP lpTokenImplementation = new UniswapLP();
        MemeversePreorderSettlementExecutor preorderSettlementExecutor =
            new MemeversePreorderSettlementExecutor(address(initialized));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        initialized.initialize(
            address(0xABCD), address(0xBEEF), engine, address(lpTokenImplementation), preorderSettlementExecutor
        );
    }

    function testUpgradeDynamicFeeEngineRevertsForInvalidEngine() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.upgradeDynamicFeeEngine(IMemeverseDynamicFeeEngine(address(0)));

        MockPoolManagerForHookLiquidity differentManager = new MockPoolManagerForHookLiquidity();
        MemeverseDynamicFeeEngine differentEngine =
            _deployEngineProxyForManager(IPoolManager(address(differentManager)), address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                DYNAMIC_FEE_ENGINE_POOL_MANAGER_MISMATCH_SELECTOR, address(mockManager), address(differentManager)
            )
        );
        hook.upgradeDynamicFeeEngine(differentEngine);
    }

    function testUpgradeDynamicFeeEngineRevertsForNonOwner() external {
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this));

        vm.prank(address(0xB0B));
        vm.expectRevert(
            abi.encodeWithSelector(OutrunOwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xB0B))
        );
        hook.upgradeDynamicFeeEngine(newEngine);
    }

    function testUpgradeDynamicFeeEngineUpdatesPointerAndEmitsEvent() external {
        address oldEngine = address(hook.dynamicFeeEngine());
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(hook), address(hook));

        vm.expectEmit(false, false, false, true);
        emit DynamicFeeEngineUpdated(oldEngine, address(newEngine));
        hook.upgradeDynamicFeeEngine(newEngine);

        assertEq(address(hook.dynamicFeeEngine()), address(newEngine), "engine pointer");
    }

    /// @notice Verifies a ProxyAdmin upgrade to the V2 facade preserves the V1 dynamic-fee-engine pointer slot.
    /// @dev Same facade-no-getters constraint as `testOwnerCanUpgradeAndPreserveStorage`: the engine pointer
    ///      (`dynamicFeeEngine`, struct offset 11 in the hook ERC7201 namespace) is read via `vm.load` after the
    ///      upgrade because the facade shell lacks the V1 `dynamicFeeEngine()` view.
    function testHookUpgradePreservesDynamicFeeEnginePointer() external {
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(hook), address(hook));
        hook.upgradeDynamicFeeEngine(newEngine);

        bytes32 snapshotEnginePointer = vm.load(address(hook), bytes32(uint256(HOOK_SLOT) + OFF_DYNAMIC_FEE_ENGINE));

        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));
        address proxyAdmin = address(uint160(uint256(vm.load(address(hook), ERC1967Utils.ADMIN_SLOT))));
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(payable(address(hook))), address(newImplementation), bytes(""));

        assertEq(MemeverseUniswapHookV2(address(hook)).version(), 2, "version");
        assertEq(
            vm.load(address(hook), bytes32(uint256(HOOK_SLOT) + OFF_DYNAMIC_FEE_ENGINE)),
            snapshotEnginePointer,
            "engine pointer survived"
        );
    }

    /// @notice Regression: upgrading to an engine that hasn't authorized this hook must revert.
    /// @dev Without this guard, all subsequent swaps and settlements revert with UnauthorizedCaller.
    function testUpgradeDynamicFeeEngineRevertsForUnauthorizedEngine() external {
        // Deploy engine that authorizes a different address (not this hook).
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this));

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.EngineNotAuthorizedCaller.selector, address(newEngine))
        );
        hook.upgradeDynamicFeeEngine(newEngine);
    }

    function testUpgradeDynamicFeeEngineRejectsBareImplementationAddress() external {
        MemeverseDynamicFeeEngine bareImplementation = new MemeverseDynamicFeeEngine(IPoolManager(address(mockManager)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.EngineNotAuthorizedCaller.selector, address(bareImplementation)
            )
        );
        hook.upgradeDynamicFeeEngine(bareImplementation);
    }

    function testUpgradeDynamicFeeEngineRevertsWhenEngineOwnerIsNotHook() external {
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                DYNAMIC_FEE_ENGINE_OWNER_MISMATCH_SELECTOR, address(newEngine), address(hook), address(this)
            )
        );
        hook.upgradeDynamicFeeEngine(newEngine);
    }

    function testTransferredHookOwnerControlsCurrentEngineImplementationUpgradeThroughHookOnly() external {
        address oldOwner = address(this);
        address newOwner = address(0xA11CE);
        MemeverseDynamicFeeEngine currentEngine = MemeverseDynamicFeeEngine(address(hook.dynamicFeeEngine()));
        TestableMemeverseDynamicFeeEngineV2 newImplementation =
            new TestableMemeverseDynamicFeeEngineV2(IPoolManager(address(mockManager)));

        hook.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(OutrunOwnableUpgradeable.OwnableUnauthorizedAccount.selector, oldOwner));
        currentEngine.upgradeToAndCall(address(newImplementation), bytes(""));

        (bool oldOwnerHookUpgradeSucceeded, bytes memory oldOwnerHookUpgradeData) = address(hook)
            .call(
                abi.encodeWithSignature(
                    "upgradeDynamicFeeEngineImplementation(address,bytes)", address(newImplementation), bytes("")
                )
            );
        assertFalse(oldOwnerHookUpgradeSucceeded, string(oldOwnerHookUpgradeData));

        vm.prank(newOwner);
        (bool newOwnerHookUpgradeSucceeded, bytes memory newOwnerHookUpgradeData) = address(hook)
            .call(
                abi.encodeWithSignature(
                    "upgradeDynamicFeeEngineImplementation(address,bytes)", address(newImplementation), bytes("")
                )
            );
        assertTrue(newOwnerHookUpgradeSucceeded, string(newOwnerHookUpgradeData));
        assertEq(TestableMemeverseDynamicFeeEngineV2(address(currentEngine)).version(), 2, "engine version");
    }

    /// @notice Regression: the facade's delegatecall migration runs in the proxy storage context and can overwrite
    ///         the ERC7201 `authorizedHook` slot.
    /// @dev This isolates the migration-write mechanism only. It bypasses the hook's post-upgrade re-binding check by
    ///      calling `upgradeToAndCall` directly as the engine owner (the hook), so the V1 `_authorizeUpgrade` cast-check
    ///      passes (facade poolManager matches) and the delegatecall `migrateAuthorizedHook` overwrites the slot; a
    ///      follow-up `vm.load` observes the corrupted value. The hook-level safety guard that catches such corruption
    ///      when the upgrade goes through the hook path is covered by
    ///      `testUpgradeDynamicFeeEngineImplementationRevertsWhenMigrationBreaksAuthorizedHook`; the engine's own
    ///      swap-rejection of a mismatched authorizedHook is V1 hot-path logic, covered by
    ///      `test_UpgradeEngine_UnauthorizedHook_SwapReverts`.
    function testEngineUpgradeMigrationDataWritesAuthorizedHookSlot() external {
        MemeverseDynamicFeeEngine currentEngine = MemeverseDynamicFeeEngine(address(hook.dynamicFeeEngine()));
        TestableMemeverseDynamicFeeEngineV2 newImplementation =
            new TestableMemeverseDynamicFeeEngineV2(IPoolManager(address(mockManager)));
        address badAuthorizedHook = address(0xB0B);
        bytes memory migrationData =
            abi.encodeCall(TestableMemeverseDynamicFeeEngineV2.migrateAuthorizedHook, (badAuthorizedHook));

        // Snapshot the V1-set authorizedHook slot before the migration overwrites it.
        bytes32 authorizedHookSlot = bytes32(uint256(FEE_ENGINE_STORAGE_LOCATION) + 2);
        assertEq(
            address(uint160(uint256(vm.load(address(currentEngine), authorizedHookSlot)))),
            address(hook),
            "pre-migration authorized hook"
        );

        // Engine owner is the hook — upgrade directly so the migration write is observable (not rolled back by
        // the hook's own post-upgrade re-binding check).
        vm.prank(address(hook));
        currentEngine.upgradeToAndCall(address(newImplementation), migrationData);

        // The delegatecall migration wrote the bad hook into the ERC7201 slot. This proves (a) the V1 cast-based
        // poolManager match check admitted the facade and (b) the facade migration code ran in proxy storage context.
        assertEq(
            address(uint160(uint256(vm.load(address(currentEngine), authorizedHookSlot)))),
            badAuthorizedHook,
            "post-migration authorized hook corrupted"
        );
    }

    /// @notice Regression: when an engine upgrade through the hook path carries a migration payload that corrupts the
    ///         engine's `authorizedHook` slot, the hook's post-upgrade re-binding check reverts with EngineNotAuthorizedCaller.
    /// @dev This is the safety-guard counterpart to `testEngineUpgradeMigrationDataWritesAuthorizedHookSlot`. It goes
    ///      through `hook.upgradeDynamicFeeEngineImplementation` (the real owner-controlled path; the test contract is
    ///      the hook owner). V1 `_authorizeUpgrade` only-owner + poolManager check passes (facade exposes matching
    ///      `poolManager`); the delegatecall `migrateAuthorizedHook(0xB0B)` then overwrites the ERC7201 `authorizedHook`
    ///      slot in the proxy context; finally `_requireEngineBoundToHook` reads `engine.authorizedHook() == 0xB0B != hook`
    ///      and reverts before the corrupted binding can take effect. If the guard stops firing this test fails instead
    ///      of silently passing.
    function testUpgradeDynamicFeeEngineImplementationRevertsWhenMigrationBreaksAuthorizedHook() external {
        MemeverseDynamicFeeEngine currentEngine = MemeverseDynamicFeeEngine(address(hook.dynamicFeeEngine()));
        TestableMemeverseDynamicFeeEngineV2 newImplementation =
            new TestableMemeverseDynamicFeeEngineV2(IPoolManager(address(mockManager)));
        // Delegatecall target that corrupts the ERC7201 authorizedHook slot in the proxy storage context.
        bytes memory badMigration =
            abi.encodeCall(TestableMemeverseDynamicFeeEngineV2.migrateAuthorizedHook, (address(0xB0B)));

        // Engine upgrade goes through the hook (its owner is `address(this)`), then the hook re-checks the binding.
        // The corrupted authorizedHook (0xB0B) no longer matches the hook, so the post-upgrade guard reverts.
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.EngineNotAuthorizedCaller.selector, address(currentEngine))
        );
        hook.upgradeDynamicFeeEngineImplementation(address(newImplementation), badMigration);
    }

    // ── Upgrade regression: real engine swap after upgrade ──────────

    /// @notice Regression: upgrading the bound engine to the V2 facade preserves V1 fee-state storage.
    /// @dev The facade shell exposes no swap callback logic, so post-upgrade swap execution is not exercised here
    ///      — swap execution is V1 logic covered by the non-upgrade swap regressions below, and a facade upgrade
    ///      introduces no new storage layout. Instead this test verifies the upgrade does not perturb the V1
    ///      ERC7201 fee-state slots: it accumulates real fee state on V1, snapshots the DynamicFeeState and
    ///      authorizedHook slots via `vm.load`, upgrades the engine proxy to the facade (owner = hook), and
    ///      asserts the slots are byte-identical afterwards.
    function test_UpgradeEngineFacade_PreservesFeeStateStorage() external {
        MemeverseDynamicFeeEngine currentEngine = MemeverseDynamicFeeEngine(address(hook.dynamicFeeEngine()));

        // Accumulate non-trivial fee state on V1 through the bound hook.
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        // Empirically confirm the slot math matches the V1 getter decoding, then snapshot the slots. weightedVolume0
        // is the first DynamicFeeState field; ewVWAPX18 is the third; authorizedHook is the namespace base + 2.
        bytes32 stateBase = _dynamicFeeStateSlot(address(hook), poolId);
        IMemeverseDynamicFeeEngine.DynamicFeeState memory v1State =
            currentEngine.getDynamicFeeState(address(hook), poolId);
        assertEq(vm.load(address(currentEngine), stateBase), bytes32(v1State.weightedVolume0), "slot math: wv0");
        assertEq(
            vm.load(address(currentEngine), bytes32(uint256(stateBase) + 2)),
            bytes32(v1State.ewVWAPX18),
            "slot math: ewVWAP"
        );
        // shortImpactPpm shares base+4 (packed as the low 24 bits with shortLastTs in the high 40 bits,
        // since shortImpactPpm is declared before shortLastTs in DynamicFeeState). Cross-check the offset
        // against the getter-decoded value before snapshotting — a wrong offset reads an empty slot and the
        // survival assertion silently degenerates to 0 == 0.
        assertEq(
            uint24(uint256(vm.load(address(currentEngine), bytes32(uint256(stateBase) + 4)))),
            v1State.shortImpactPpm,
            "slot math: shortImpactPpm"
        );

        bytes32 snapshotWv0 = vm.load(address(currentEngine), stateBase);
        bytes32 snapshotWeightedPriceVolume0 = vm.load(address(currentEngine), bytes32(uint256(stateBase) + 1));
        bytes32 snapshotEwVWAP = vm.load(address(currentEngine), bytes32(uint256(stateBase) + 2));
        // base+3 packed vol slot (volAnchor:160|volLastMoveTs:40|volDeviation:24|volCarry:24). Whole-slot
        // snapshot+survive — no field unpacking needed to assert the packed slot survives intact.
        bytes32 snapshotPackedVol = vm.load(address(currentEngine), bytes32(uint256(stateBase) + 3));
        bytes32 snapshotShortImpact = vm.load(address(currentEngine), bytes32(uint256(stateBase) + 4));
        bytes32 authorizedHookSlot = bytes32(uint256(FEE_ENGINE_STORAGE_LOCATION) + 2);
        bytes32 snapshotAuthorizedHook = vm.load(address(currentEngine), authorizedHookSlot);

        // Upgrade the engine proxy to the facade shell. Owner is the hook; the V1 `_authorizeUpgrade` cast-check
        // passes because the facade exposes a matching `poolManager()`.
        TestableMemeverseDynamicFeeEngineV2 newImplementation =
            new TestableMemeverseDynamicFeeEngineV2(IPoolManager(address(mockManager)));
        vm.prank(address(hook));
        currentEngine.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(TestableMemeverseDynamicFeeEngineV2(address(currentEngine)).version(), 2, "version after upgrade");
        assertEq(vm.load(address(currentEngine), stateBase), snapshotWv0, "weightedVolume0 survived");
        assertEq(
            vm.load(address(currentEngine), bytes32(uint256(stateBase) + 1)),
            snapshotWeightedPriceVolume0,
            "weightedPriceVolume0 survived"
        );
        assertEq(vm.load(address(currentEngine), bytes32(uint256(stateBase) + 2)), snapshotEwVWAP, "ewVWAP survived");
        assertEq(
            vm.load(address(currentEngine), bytes32(uint256(stateBase) + 3)),
            snapshotPackedVol,
            "packed vol slot survived"
        );
        assertEq(
            vm.load(address(currentEngine), bytes32(uint256(stateBase) + 4)),
            snapshotShortImpact,
            "shortImpactPpm survived"
        );
        assertEq(vm.load(address(currentEngine), authorizedHookSlot), snapshotAuthorizedHook, "authorizedHook survived");
    }

    function test_UpgradeEngine_ThenSwap_SucceedsWithRealFeeMath() external {
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(hook), address(hook));
        hook.upgradeDynamicFeeEngine(newEngine);

        assertEq(address(hook.dynamicFeeEngine()), address(newEngine), "engine pointer");

        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        BalanceDelta delta = mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );

        assertTrue(delta.amount0() < 0, "consumed input");
        assertTrue(delta.amount1() > 0, "produced output");

        // Real engine must have written EWVWAP state — proves full fee math path executed.
        IMemeverseDynamicFeeEngine.DynamicFeeState memory state = newEngine.getDynamicFeeState(address(hook), poolId);
        assertTrue(state.weightedVolume0 > 0, "EWVWAP state accumulated");
    }

    function test_UpgradeEngine_MultipleSwaps_StateAccumulates() external {
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(hook), address(hook));
        hook.upgradeDynamicFeeEngine(newEngine);

        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        // First swap — engine state starts accumulating
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        IMemeverseDynamicFeeEngine.DynamicFeeState memory state1 = newEngine.getDynamicFeeState(address(hook), poolId);
        assertTrue(state1.weightedVolume0 > 0, "first swap wrote EWVWAP state");

        // Second swap — engine still active, state remains non-zero
        vm.warp(block.timestamp + 1);
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
        IMemeverseDynamicFeeEngine.DynamicFeeState memory state2 = newEngine.getDynamicFeeState(address(hook), poolId);
        assertTrue(state2.weightedVolume0 > 0, "second swap preserved EWVWAP state");
        assertTrue(state2.shortLastTs > state1.shortLastTs, "short impact timestamp advanced");
    }

    /// @notice Deploy engine with a different authorized hook — engine rejects the hot-path call.
    function test_UpgradeEngine_UnauthorizedHook_SwapReverts() external {
        // Deploy engine authorized to a different address, not this hook.
        // Use vm.store to bypass upgradeDynamicFeeEngine's authorization check.
        MemeverseDynamicFeeEngine newEngine =
            _deployEngineProxyForManager(IPoolManager(address(mockManager)), address(this));
        bytes32 baseSlot = HOOK_SLOT;
        vm.store(address(hook), bytes32(uint256(baseSlot) + 11), bytes32(uint256(uint160(address(newEngine)))));

        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);
        vm.warp(block.timestamp + 900);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseDynamicFeeEngine.UnauthorizedCaller.selector, address(hook)));
        mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0}), bytes("")
        );
    }

    struct RollbackSnapshot {
        uint256 payer0;
        uint256 payer1;
        uint256 treasury0;
        uint256 treasury1;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
        uint256 wv0;
        uint256 ewVWAP;
        uint160 volAnchor;
        uint24 volDev;
        uint24 shortImpact;
    }

    function _snapshotRollback() internal view returns (RollbackSnapshot memory s) {
        s.payer0 = token0.balanceOf(address(this));
        s.payer1 = token1.balanceOf(address(this));
        s.treasury0 = token0.balanceOf(hook.treasury());
        s.treasury1 = token1.balanceOf(hook.treasury());
        (, s.fee0PerShare, s.fee1PerShare) = hook.poolInfo(poolId);
        (s.wv0,, s.ewVWAP, s.volAnchor,, s.volDev,, s.shortImpact,) =
            lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
    }

    function _assertRollbackUnchanged(RollbackSnapshot memory s) internal view {
        assertEq(token0.balanceOf(address(this)), s.payer0, "payer token0 unchanged");
        assertEq(token1.balanceOf(address(this)), s.payer1, "payer token1 unchanged");
        assertEq(token0.balanceOf(hook.treasury()), s.treasury0, "treasury token0 unchanged");
        assertEq(token1.balanceOf(hook.treasury()), s.treasury1, "treasury token1 unchanged");
        (, uint256 fee0, uint256 fee1) = hook.poolInfo(poolId);
        assertEq(fee0, s.fee0PerShare, "fee0 per share unchanged");
        assertEq(fee1, s.fee1PerShare, "fee1 per share unchanged");
        (uint256 wv0,, uint256 ewvwap, uint160 volAnchor,, uint24 volDev,, uint24 shortImpact,) =
            lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
        assertEq(wv0, s.wv0, "ewvwap weightedVolume0 unchanged");
        assertEq(ewvwap, s.ewVWAP, "ewvwap unchanged");
        assertEq(volAnchor, s.volAnchor, "vol anchor unchanged");
        assertEq(volDev, s.volDev, "volatility unchanged");
        assertEq(shortImpact, s.shortImpact, "short impact unchanged");
    }

    /// @notice Adds liquidity via the hook core to seed tests.
    /// @dev Wraps `addLiquidityCore` to centralize the single-step liquidity setup.
    function _addLiquidity() internal returns (uint128 liquidity) {
        (liquidity,) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }

    /// @dev Computes the base storage slot of DynamicFeeState for (hook, poolId) inside the engine's ERC7201
    ///      namespace. `dynamicFeeStates` is the first namespace field (base + 0); Solidity derives the
    ///      mapping-value slot as keccak(abi.encode(poolId, keccak(abi.encode(hook, base)))). PoolId is a
    ///      bytes32 wrapper and encodes identically to bytes32.
    function _dynamicFeeStateSlot(address hook_, PoolId poolId_) internal pure returns (bytes32) {
        bytes32 outer = keccak256(abi.encode(hook_, FEE_ENGINE_STORAGE_LOCATION));
        return keccak256(abi.encode(poolId_, outer));
    }

    /// @notice Constructs the normalized pool key used throughout the tests.
    /// @dev Mirrors the hook's expected pair ordering and hook wiring.
    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
    }
}
