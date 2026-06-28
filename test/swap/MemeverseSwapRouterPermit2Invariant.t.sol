// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ISignatureTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/ISignatureTransfer.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseSwapRouter} from "../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MockPermit2ForRouterTest, MockPoolManagerForPermit2RouterTest} from "../mocks/swap/Permit2Mocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

contract Permit2AccountingHandler is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MemeverseSwapRouter internal router;
    MemeverseUniswapHook internal immutable hook;
    MockPermit2ForRouterTest internal immutable permit2;
    MockERC20 internal immutable token0;
    address internal immutable treasury;
    PoolKey internal key;

    uint256 public expectedRegularTreasuryFee;
    uint256 public expectedSettlementTreasuryFee;
    uint256 public lastExpectedPermitAmount;

    constructor(
        MemeverseUniswapHook _hook,
        MockPermit2ForRouterTest _permit2,
        MockERC20 _token0,
        address _treasury,
        PoolKey memory _key
    ) {
        hook = _hook;
        permit2 = _permit2;
        token0 = _token0;
        treasury = _treasury;
        key = _key;
        token0.approve(address(permit2), type(uint256).max);
    }

    /// @notice Test helper for setRouter.
    /// @param _router See implementation.
    function setRouter(MemeverseSwapRouter _router) external {
        require(address(router) == address(0), "router already set");
        router = _router;
    }

    /// @notice Test helper for warp.
    /// @param deltaSeed See implementation.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 40 minutes));
    }

    /// @notice Test helper for regularSwap.
    /// @param amountSeed See implementation.
    function regularSwap(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = _singlePermit(amount);
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);

        BalanceDelta delta = router.swapWithPermit2(
            permitParams, key, params, address(this), block.timestamp, 0, amount, bytes("regular")
        );

        assertLt(delta.amount0(), 0, "regular delta0");
        assertGt(delta.amount1(), 0, "regular delta1");

        expectedRegularTreasuryFee += token0.balanceOf(treasury) - treasuryBefore;
        lastExpectedPermitAmount = amount;
        _assertLastPermitPull(amount);
        assertEq(token0.balanceOf(treasury) - treasuryBefore, quote.estimatedProtocolFeeAmount, "regular fee");
    }

    /// @notice Test helper for settlementSwap.
    /// @param amountSeed See implementation.
    function settlementSwap(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = _singlePermit(amount);
        uint256 treasuryBefore = token0.balanceOf(treasury);

        BalanceDelta delta = router.swapWithPermit2(
            permitParams, key, params, address(this), block.timestamp, 0, amount, bytes("public-swap")
        );

        assertLt(delta.amount0(), 0, "settlement delta0");
        assertGt(delta.amount1(), 0, "settlement delta1");

        expectedSettlementTreasuryFee += token0.balanceOf(treasury) - treasuryBefore;
        lastExpectedPermitAmount = amount;
        _assertLastPermitPull(amount);
        assertEq(token0.balanceOf(treasury) - treasuryBefore, quote.estimatedProtocolFeeAmount, "marker fee");
    }

    function _assertLastPermitPull(uint256 amount) internal view {
        assertEq(permit2.lastOwner(), address(this), "permit owner");
        assertEq(permit2.lastRecipient(), address(router), "permit recipient");
        assertEq(permit2.lastToken(), address(token0), "permit token");
        assertEq(permit2.lastRequestedAmount(), amount, "permit amount");
    }

    function _singlePermit(uint256 amount)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2SingleParams memory permitParams)
    {
        permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: amount}),
                nonce: 0,
                deadline: block.timestamp
            }),
            transferDetails: ISignatureTransfer.SignatureTransferDetails({
                to: address(router), requestedAmount: amount
            }),
            signature: hex"01"
        });
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract Permit2SpoofHandler is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MemeverseSwapRouter internal immutable router;
    MemeverseUniswapHook internal immutable hook;
    MockPermit2ForRouterTest internal immutable permit2;
    MockERC20 internal immutable token0;
    address internal immutable treasury;
    PoolKey internal key;

    uint256 public expectedSpoofTreasuryFee;

    constructor(
        MemeverseSwapRouter _router,
        MemeverseUniswapHook _hook,
        MockPermit2ForRouterTest _permit2,
        MockERC20 _token0,
        address _treasury,
        PoolKey memory _key
    ) {
        router = _router;
        hook = _hook;
        permit2 = _permit2;
        token0 = _token0;
        treasury = _treasury;
        key = _key;
        token0.approve(address(permit2), type(uint256).max);
    }

    /// @notice Test helper for warp.
    /// @param deltaSeed See implementation.
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 0, 40 minutes));
    }

    /// @notice Test helper for spoofSettlement.
    /// @param amountSeed See implementation.
    function spoofSettlement(uint256 amountSeed) external {
        uint256 balance = token0.balanceOf(address(this));
        if (balance < 1 ether) return;

        uint256 amount = bound(amountSeed, 1 ether, _min(balance, 10_000 ether));
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        IMemeverseSwapRouter.Permit2SingleParams memory permitParams = _singlePermit(amount);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: priceLimit});
        IMemeverseUniswapHook.SwapQuote memory quote = router.quoteSwap(key, params, address(this));
        uint256 treasuryBefore = token0.balanceOf(treasury);

        try router.swapWithPermit2(
            permitParams, key, params, address(this), block.timestamp, 0, amount, bytes("public-swap")
        ) returns (
            BalanceDelta delta
        ) {
            assertLt(delta.amount0(), 0, "spoof delta0");
            assertGt(delta.amount1(), 0, "spoof delta1");
            uint256 treasuryDelta = token0.balanceOf(treasury) - treasuryBefore;
            assertEq(treasuryDelta, quote.estimatedProtocolFeeAmount, "spoof fee");
            expectedSpoofTreasuryFee += treasuryDelta;
        } catch {}
    }

    function _singlePermit(uint256 amount)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2SingleParams memory permitParams)
    {
        permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: amount}),
                nonce: 0,
                deadline: block.timestamp
            }),
            transferDetails: ISignatureTransfer.SignatureTransferDetails({
                to: address(router), requestedAmount: amount
            }),
            signature: hex"01"
        });
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract MemeverseSwapRouterPermit2InvariantTest is StdInvariant, Test, HookStorageHelper {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockPoolManagerForPermit2RouterTest internal manager;
    MemeverseUniswapHook internal hook;
    MockPermit2ForRouterTest internal permit2;
    MemeverseSwapRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    PoolKey internal key;

    Permit2AccountingHandler internal accountingHandler;
    Permit2SpoofHandler internal spoofHandler;

    function _deployHookProxy(IPoolManager manager_, address owner_, address treasury_)
        internal
        returns (MemeverseUniswapHook deployed)
    {
        // Real MemeverseUniswapHook deployed behind a CREATE2-mined flag-address proxy via the shared
        // helper (replaces the former Testable subclass that bypassed `_validateProxyHookAddress`).
        (address hookProxy,) = deployHookAtFlagAddress(manager_, owner_, treasury_);
        deployed = MemeverseUniswapHook(hookProxy);
    }

    /// @notice Test helper for setUp.
    function setUp() external {
        manager = new MockPoolManagerForPermit2RouterTest();
        treasury = makeAddr("treasury");
        hook = _deployHookProxy(IPoolManager(address(manager)), address(this), treasury);
        permit2 = new MockPermit2ForRouterTest();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(manager), 1_000_000 ether);
        token1.mint(address(manager), 1_000_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setProtocolFeeCurrency(key.currency0, true);

        accountingHandler = new Permit2AccountingHandler(hook, permit2, token0, treasury, key);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(permit2))
        );
        hook.setPoolInitializer(address(router));
        accountingHandler.setRouter(router);
        spoofHandler = new Permit2SpoofHandler(router, hook, permit2, token0, treasury, key);
        token0.mint(address(accountingHandler), 1_000_000 ether);
        token0.mint(address(spoofHandler), 1_000_000 ether);

        targetContract(address(accountingHandler));
        targetContract(address(spoofHandler));
    }

    /// @notice Test helper for invariant_permit2TreasuryAccountingMatchesRegularPlusSettlementPaths.
    function invariant_permit2TreasuryAccountingMatchesRegularPlusSettlementPaths() external view {
        assertEq(
            token0.balanceOf(treasury),
            accountingHandler.expectedRegularTreasuryFee() + accountingHandler.expectedSettlementTreasuryFee()
                + spoofHandler.expectedSpoofTreasuryFee(),
            "treasury accounting"
        );
    }

    /// @notice Test helper for invariant_permit2LastPullMatchesExpectedBudget.
    function invariant_permit2LastPullMatchesExpectedBudget() external view {
        if (accountingHandler.lastExpectedPermitAmount() == 0) return;
        if (permit2.lastOwner() == address(accountingHandler)) {
            assertEq(permit2.lastRecipient(), address(router), "last recipient");
            assertEq(permit2.lastToken(), address(token0), "last token");
            assertEq(permit2.lastRequestedAmount(), accountingHandler.lastExpectedPermitAmount(), "last amount");
        }
    }

    /// @notice Test helper for invariant_permit2RouterHoldsNoResidualInputBudget.
    function invariant_permit2RouterHoldsNoResidualInputBudget() external view {
        assertEq(token0.balanceOf(address(router)), 0, "router token0 balance");
    }
}
