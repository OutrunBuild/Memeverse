// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeversePoolKeyLib} from "../../src/swap/libraries/MemeversePoolKeyLib.sol";
import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";

import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {PreorderSettlementReenterer} from "../mocks/swap/PreorderSettlementReenterer.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

import {MemeverseUniswapHookV2} from "../mocks/upgrade/MemeverseUniswapHookV2.sol";

/// @dev Test boundary:
/// - These cases lock hook-side handling under the local hook-liquidity manager mock.
/// - They do not establish real market execution, partial-fill economics, rollback guarantees,
///   or fee-side correctness beyond this deterministic harness.
contract MemeverseUniswapHookLiquidityTest is Test, HookStorageHelper {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q128 = uint256(1) << 128;
    bytes4 internal constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    bytes4 internal constant UNAUTHORIZED_POOL_INITIALIZER_SELECTOR =
        bytes4(keccak256("UnauthorizedPoolInitializer()"));

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
        // Deploy the real MemeverseUniswapHook, its three facets, and the LP token implementation behind a
        // CREATE2-mined flag-address UUPS proxy so production address validation is exercised.
        address hookProxy = deployHookAtFlagAddress(manager_, owner_, treasury_);
        return MemeverseUniswapHook(hookProxy);
    }

    function _deployHookProxy(address owner_, address treasury_) internal returns (MemeverseUniswapHook deployed) {
        deployed = _deployHookProxyForManager(IPoolManager(address(mockManager)), owner_, treasury_);
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

    function testUnlockCallback_RevertsForUnsupportedKind() external {
        uint256 unsupportedKind = 2;

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseUniswapHook.InvalidUnlockCallbackKind.selector, unsupportedKind)
        );
        vm.prank(address(mockManager));
        hook.unlockCallback(abi.encode(unsupportedKind));
    }

    /// @dev Regression: discriminator is read via `rawData[:32]` calldata slice (not abi.decode).
    ///      A payload shorter than 32 bytes must revert on the SOLC slice bounds check as an
    ///      empty-data `revert(0,0)`. The first byte is non-zero (0x01) so that a hypothetical
    ///      regression dropping the length check (e.g. an assembly `calldataload` rewrite that
    ///      zero-extends short calldata) would read a large rawKind (2^248 for byte 0 = 0x01),
    ///      miss both supported kinds, and fall into `revert InvalidUnlockCallbackKind(...)` —
    ///      which carries revert data and therefore fails `expectRevert(bytes(""))`. This makes
    ///      the test discriminate the slice-bounds revert from a fallthrough revert.
    function testUnlockCallback_RevertsWhenPayloadShorterThanOneWord() external {
        // 31 bytes: shorter than one ABI word. First byte non-zero so a dropped length check would
        // read a large rawKind and hit InvalidUnlockCallbackKind (with data), not an empty revert.
        bytes memory tooShort = new bytes(31);
        tooShort[0] = bytes1(uint8(uint256(IMemeverseUniswapHook.UnlockCallbackKind.Settlement)));

        // Slice bounds check emits bare revert(0,0) = empty data. expectRevert(bytes("")) matches
        // only empty-data reverts, so a fallthrough to InvalidUnlockCallbackKind (with data) fails.
        vm.expectRevert(bytes(""));
        vm.prank(address(mockManager));
        hook.unlockCallback(tooShort);
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

    function testPublicSwapResumeTime_RevertsForNativeCurrencyInEitherPosition() external {
        hook.setLauncher(address(this));

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.setPublicSwapResumeTime(address(0), address(token1), 1);

        vm.expectRevert(IMemeverseUniswapHook.NativeCurrencyUnsupported.selector);
        hook.setPublicSwapResumeTime(address(token0), address(0), 1);
    }

    function testFuzz_PublicSwapResumeTime_UsesCanonicalPoolIdForEitherTokenOrder(
        address tokenA,
        address tokenB,
        uint40 resumeTime
    ) external {
        tokenA = address(uint160(bound(uint160(tokenA), 1, type(uint160).max)));
        tokenB = address(uint160(bound(uint160(tokenB), 1, type(uint160).max)));
        hook.setLauncher(address(this));

        PoolId expectedPoolId = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, address(hook)).toId();
        hook.setPublicSwapResumeTime(tokenA, tokenB, resumeTime);
        assertEq(hook.publicSwapResumeTime(expectedPoolId), resumeTime, "canonical pool resume time");

        uint40 reversedResumeTime = resumeTime == type(uint40).max ? 0 : resumeTime + 1;
        hook.setPublicSwapResumeTime(tokenB, tokenA, reversedResumeTime);
        assertEq(hook.publicSwapResumeTime(expectedPoolId), reversedResumeTime, "reversed pair updates same pool");
    }

    /// @notice Verifies hook-local protection state is keyed only by `PoolId`.
    /// @dev The unlock gate uses canonical PoolId state without token-pair guessing or launcher verdict helpers.
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

    /// @notice Verifies `updateUserSnapshot` is a no-op when the user's offsets already match current fee growth.
    /// @dev Covers the zero-growth early-return path: after a first snapshot syncs the user's offsets to the
    ///      post-swap fee-per-share growth, a second snapshot with no intervening swap must neither read the LP
    ///      token's external `balanceOf` nor mutate any user fee state. The first snapshot accrues `pendingFee0`
    ///      (fee0 growth > 0 offset), advancing both offsets to current growth; the second then hits the early
    ///      return because `fee0PerShare == fee0Offset` and `fee1PerShare == fee1Offset`. State equivalence
    ///      before/after the second call is asserted, and `balanceOf` is armed to revert so a regression that
    ///      falls through to the external read fails loudly instead of silently performing a redundant SSTORE.
    function testUpdateUserSnapshot_ZeroGrowthEarlyReturnIsNoOp() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);

        // Drive fee0 growth past the user's zero offsets (zeroForOne=true accrues fee0).
        vm.prank(address(mockManager));
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            bytes("")
        );

        // First snapshot: fee0 growth > offset, so pendingFee0 crystallizes and offsets advance to current growth.
        hook.updateUserSnapshot(poolId, address(this));
        (uint256 fee0OffsetA, uint256 fee1OffsetA, uint256 pendingFee0A, uint256 pendingFee1A) =
            hook.userFeeState(poolId, address(this));

        // Sanity: the first snapshot did real work, so the second's no-op equivalence is meaningful rather than
        // vacuous. Without this guard a permanently-no-op `_updateUserSnapshot` would pass the equality check below.
        (, uint256 fee0PerShare, uint256 fee1PerShare) = hook.poolInfo(poolId);
        assertEq(fee0OffsetA, fee0PerShare, "first snapshot synced fee0 offset");
        assertEq(fee1OffsetA, fee1PerShare, "first snapshot synced fee1 offset");
        assertGt(pendingFee0A, 0, "first snapshot crystallized fee0");

        // Arm balanceOf to revert so a regression skipping the early return fails loudly. The second snapshot
        // would otherwise silently perform a redundant balanceOf + mulDiv(0) + same-value SSTORE.
        (address lpToken,,) = hook.poolInfo(poolId);
        bytes4 balanceOfSelector = bytes4(keccak256("balanceOf(address)"));
        vm.mockCallRevert(
            lpToken,
            abi.encodeWithSelector(balanceOfSelector, address(this)),
            bytes("unexpected balanceOf on zero-growth early return")
        );

        // Second snapshot: offsets already equal current growth and no swap advanced growth in between, so the
        // zero-growth early return must fire and skip balanceOf + mulDiv + SSTORE entirely.
        hook.updateUserSnapshot(poolId, address(this));

        (uint256 fee0OffsetB, uint256 fee1OffsetB, uint256 pendingFee0B, uint256 pendingFee1B) =
            hook.userFeeState(poolId, address(this));
        assertEq(fee0OffsetB, fee0OffsetA, "fee0 offset unchanged on early return");
        assertEq(fee1OffsetB, fee1OffsetA, "fee1 offset unchanged on early return");
        assertEq(pendingFee0B, pendingFee0A, "pending fee0 unchanged on early return");
        assertEq(pendingFee1B, pendingFee1A, "pending fee1 unchanged on early return");
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
    /// @notice Verifies beforeSwap's LP-fee hot path reads the hook's cached LP supply, not an external
    ///         `totalSupply` call.
    /// @dev This is a white-box unit test that drives `beforeSwap` directly. The per-poolId swap-lifecycle lock
    ///      is acquired in `beforeSwapLogic` and released in `afterSwapLogic` (v4 always pairs them for a real
    ///      swap), so a direct `beforeSwap` leaves the lock held for the rest of this test's tx. Splitting the
    ///      beforeSwap and settlement assertions into separate test functions keeps each in its own tx, where the
    ///      transient lock auto-clears before the next test.
    function testLpFeeHotPaths_BeforeSwapUsesCachedSupply() external {
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
    }

    /// @notice Verifies the settlement LP-fee hot path reads the hook's cached LP supply, not an external
    ///         `totalSupply` call.
    function testLpFeeHotPaths_SettlementUsesCachedSupply() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, true);

        (address lpToken,,) = hook.poolInfo(poolId);
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
    /// @dev The owner-direct claim surface redirects fees without a signature relay.
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

    /// @notice Verifies quoting succeeds when neither side is registered for protocol fees.
    /// @dev `setUp` registers no protocol-fee currency, so neither `currencyIn` nor `currencyOut` is
    ///      supported. The protocol fee falls on the input leg (ordinary-pool resolution) and the quote
    ///      must return sensibly instead of reverting.
    function testQuoteSwap_OrdinaryPoolWithoutProtocolFeeCurrencyRegistration_Succeeds() external {
        _addLiquidity();
        // Explicit: neither side is a registered protocol-fee currency.
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, false);

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );

        // Ordinary-pool resolution: protocol fee is charged on the input leg. `protocolFeeOnInput==true`
        // is the assertion that pins the leg — a wrong (output-leg) resolution would set it false. Note
        // `estimatedProtocolFeeAmount>0` alone does NOT distinguish the leg: on the output leg it is derived
        // from gross output and is also >0, so it only confirms a fee is quoted.
        assertTrue(quote.protocolFeeOnInput, "protocol fee on input leg");
        assertGt(quote.estimatedProtocolFeeAmount, 0, "ordinary-pool protocol fee charged on input");
    }

    /// @notice Pins protocol-fee leg selection against explicit `setProtocolFeeCurrency` state.
    /// @dev Resolution is `inputSupported || !outputSupported`, inlined at each call site.
    ///      Registered currencies control HOW the fee is collected, not whether: the fee always accrues.
    ///      Quotes use exact-input (`amountSpecified < 0`) on `zeroForOne=true`, so `currencyIn=currency0`
    ///      and `currencyOut=currency1`. The three registered cases here contrast with the ordinary-pool
    ///      case in `testQuoteSwap_OrdinaryPoolWithoutProtocolFeeCurrencyRegistration_Succeeds`, jointly
    ///      pinning the full four-row leg-resolution truth table.
    function testQuoteSwap_ProtocolFeeLegResolutionFollowsRegisteredCurrencies() external {
        _addLiquidity();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});

        // Row 1: input registered only (currency0). `||` short-circuits → input leg.
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setProtocolFeeCurrency(key.currency1, false);
        assertTrue(
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this)).protocolFeeOnInput,
            "input registered only -> fee on input leg"
        );

        // Row 2: output registered only (currency1). Input not registered, so `!outputSupported=false`
        // propagates → output leg (protocolFeeOnInput=false). This is the assertion that pins the design:
        // a wrong (input-leg) resolution would set it true.
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);
        assertFalse(
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this)).protocolFeeOnInput,
            "output registered only -> fee on output leg"
        );

        // Row 3: both registered. `||` short-circuits on the input leg → input leg preferred.
        hook.setProtocolFeeCurrency(key.currency0, true);
        hook.setProtocolFeeCurrency(key.currency1, true);
        assertTrue(
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this)).protocolFeeOnInput,
            "both registered -> fee on input leg (input preferred)"
        );
    }

    /// @notice Pins the exact-output ordinary-pool quote path: `amountSpecified > 0`, neither registered.
    /// @dev Mirrors `testQuoteSwap_OrdinaryPoolWithoutProtocolFeeCurrencyRegistration_Succeeds` for the
    ///      exact-output branch of `MemeverseUniswapHookLens.quoteSwap`. The lens routes the ordinary
    ///      pool through the input-leg fee (`protocolFeeOnInput=true`), so the quote must report a
    ///      positive `estimatedProtocolFeeAmount` derived from the grossed-up input.
    function testQuoteSwap_OrdinaryPool_ExactOutput_ChargesInputProtocolFee() external {
        _addLiquidity();
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, false);

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            key,
            SwapParams({zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: 0}),
            address(this)
        );

        assertTrue(quote.protocolFeeOnInput, "exact-output ordinary pool: fee on input leg");
        assertGt(quote.estimatedProtocolFeeAmount, 0, "exact-output ordinary pool: positive protocol fee");
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

    /// @notice Verifies launch fee floor dominates immediately after pool initialization and decays to the minimum fee.
    /// @dev Covers how the launch fee scheduler composes with the dynamic fee calculation.
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
    /// @dev When only the output leg is a registered protocol-fee token (input unregistered), the
    ///      settlement callback takes the fee on the output leg before delivering the remainder.
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

    /// @notice Verifies production SettlementFacet reverts when unlock returns a mismatched protocol fee report.
    /// @dev Arms the mock PoolManager to run the real settlement unlock callback, then inflate only
    ///      `SettlementResult.protocolFeeOutputAmount` by 1 wei before returning. Does NOT replace
    ///      SettlementFacet via setFacet — that would swap out the production check under test.
    function testExecutePreorderSettlement_RevertsOnFeeMismatch() external {
        _addLiquidity();
        // Output-side protocol fee so expected fee is non-zero and the mismatch branch is live.
        hook.setProtocolFeeCurrency(key.currency1, true);
        hook.setLauncher(address(this));
        token0.approve(address(hook), type(uint256).max);
        token1.mint(address(mockManager), 1_000_000 ether);

        mockManager.setInflateSettlementProtocolFeeByOne();

        vm.expectRevert(IMemeverseUniswapHook.PreorderSettlementFeeMismatch.selector);
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );
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
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 5000, minFeeBps: 100, decayDurationSeconds: 0})
        );

        vm.expectRevert(IMemeverseUniswapHook.InvalidLaunchFeeConfig.selector);
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 99, minFeeBps: 100, decayDurationSeconds: 900})
        );

        vm.expectRevert(IMemeverseUniswapHook.InvalidLaunchFeeConfig.selector);
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 10_001, minFeeBps: 100, decayDurationSeconds: 900})
        );

        vm.expectRevert(IMemeverseUniswapHook.InvalidLaunchFeeConfig.selector);
        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 5_000, minFeeBps: 10_001, decayDurationSeconds: 900})
        );

        hook.setDefaultLaunchFeeConfig(
            IDynamicFeeFacet.LaunchFeeConfig({startFeeBps: 4000, minFeeBps: 100, decayDurationSeconds: 900})
        );

        (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds) = hook.defaultLaunchFeeConfig();
        assertEq(startFeeBps, 4000, "start fee");
        assertEq(minFeeBps, 100, "min fee");
        assertEq(decayDurationSeconds, 900, "duration");
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

    /// @notice A malicious ERC20 reentry must use the public callback path, not the hook self-call path.
    /// @dev The hook's own settlement swap is a PoolManager self-call, so v4 skips its swap callbacks. The token
    ///      callback reenters with `msg.sender == token`, so v4 executes the normal public callback path and the
    ///      configured public-swap block rejects it. The reenterer swallows that revert so settlement can finish.
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
        // Fund the output currency so the settlement callback can pay token1 out.
        token1.mint(address(mockManager), 1_000_000 ether);

        // Arm the evil token to reenter exactly one swap from inside the hook's settle window.
        evil.arm(
            mockManager,
            evilKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: 0})
        );

        // The settlement completes because its own swap is a hook self-call and v4 skips both swap callbacks.
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: evilKey,
                params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: 0}),
                recipient: address(this)
            })
        );

        // The reentrant swap fired from inside settle and was rejected (it hit the public-swap block),
        // proving the token caller used the public callback path rather than the hook self-call path.
        assertTrue(evil.reentryFired(), "reentrant swap fired during hook settle");
        assertTrue(evil.reentryBlocked(), "token reentry rejected by public-swap callbacks");
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

    function testNonOwnerCannotUpgrade() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(this));
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(mockManager)));

        // UUPS `_authorizeUpgrade` runs under onlyOwner inside the proxy delegatecall context, so a non-owner
        // caller is rejected with OwnableUnauthorizedAccount before the implementation slot is touched.
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        MemeverseUniswapHook(address(initialized)).upgradeToAndCall(address(newImplementation), "");
    }

    /// @notice Verifies an owner-driven UUPS upgrade to the V2 shell preserves V1 hook storage (owner, treasury,
    ///         launcher, poolInitializer).
    /// @dev The V2 shell cannot inherit V1 (Solidity Error 8894 blocks inheriting a `layout at` contract), so it
    ///      exposes no V1 getters and post-upgrade storage is read via `vm.load` against the V1 storage slots
    ///      (OutrunOwnableUpgradeable owner slot + the hook ERC7201 namespace struct field offsets). UUPS upgrade
    ///      authorization lives on the implementation (`_authorizeUpgrade`, onlyOwner), so the owner can drive the
    ///      upgrade directly through the proxy without a ProxyAdmin.
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

        // Owner drives the upgrade directly through the proxy via UUPS upgradeToAndCall (no ProxyAdmin).
        MemeverseUniswapHook(address(initialized)).upgradeToAndCall(address(newImplementation), "");

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

    function testOwnerCannotUpgradeToImplementationWithDifferentPoolManager() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(this));
        MockPoolManagerForHookLiquidity differentManager = new MockPoolManagerForHookLiquidity();
        MemeverseUniswapHookV2 newImplementation = new MemeverseUniswapHookV2(IPoolManager(address(differentManager)));

        // The hook enforces poolManager drift checks on-chain; a mismatched implementation must revert.
        // Encode the full error (selector + args) because this Foundry version matches `bytes4` exactly,
        // not as a prefix — see the `abi.encodeWithSelector` pattern used elsewhere in this file.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.UpgradePoolManagerMismatch.selector,
                address(mockManager),
                address(differentManager)
            )
        );
        MemeverseUniswapHook(address(initialized)).upgradeToAndCall(address(newImplementation), "");
    }

    function testOwnerCannotUpgradeToCodelessImplementation() external {
        MemeverseUniswapHook initialized = _deployHookProxy(address(this), address(this));

        // An EOA upgrade target has no code, so the drift-check pre-check must reject it with a
        // named error before the ImmutableState external call would produce an opaque decode revert.
        address eoaTarget = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.UpgradeTargetCodeNotReady.selector, eoaTarget));
        MemeverseUniswapHook(address(initialized)).upgradeToAndCall(eoaTarget, "");
    }

    function testConstructorRevertsWhenPoolManagerIsZero() external {
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        new MemeverseUniswapHook(IPoolManager(address(0)));
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

    function _snapshotRollback() internal returns (RollbackSnapshot memory s) {
        s.payer0 = token0.balanceOf(address(this));
        s.payer1 = token1.balanceOf(address(this));
        s.treasury0 = token0.balanceOf(hook.treasury());
        s.treasury1 = token1.balanceOf(hook.treasury());
        (, s.fee0PerShare, s.fee1PerShare) = hook.poolInfo(poolId);
        (s.wv0,, s.ewVWAP, s.volAnchor,, s.volDev,, s.shortImpact,) =
            lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
    }

    function _assertRollbackUnchanged(RollbackSnapshot memory s) internal {
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

    /// @notice Constructs the normalized pool key used throughout the tests.
    /// @dev Mirrors the hook's expected pair ordering and hook wiring.
    function _dynamicPoolKey(Currency currency0, Currency currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
    }
}
