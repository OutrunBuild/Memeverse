// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// Referral-rebate custody must close the hook's v4 delta within the swap unlock session. The hook performs
// the rebate take, so PoolManager charges the same address that receives the return-delta credit, while
// `accrueRebate` records claimable accounting only. A non-zero per-caller delta would make v4 revert with
// CurrencyNotSettled. The mock PoolManager cannot prove this because its settle() zeroes every address's delta.
//
// This suite uses the REAL
// lib/v4-core PoolManager bytecode (compiled with solc 0.8.26, via_ir, cancun) deployed via `create`,
// because the project solc 0.8.35 cannot import PoolManager.sol (exact pragma 0.8.26). All delta
// accounting (unlock/take/settle/NonzeroDeltaCount) is the genuine v4-core logic.

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @notice Swap integrator that settles/takes against a real IPoolManager (not the mock).
///         Mirrors UnlockSwapIntegrator but targets IPoolManager so it works with the real
///         v4 PoolManager delta accounting (sync -> transferFrom -> settle; take).
contract RealV4SwapIntegrator is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager internal immutable manager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, address recipient, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Settle negative deltas (input owed): sync snapshots reserves, transferFrom pays, settle credits.
        if (delta.amount0() < 0) {
            manager.sync(data.key.currency0);
            IERC20(Currency.unwrap(data.key.currency0))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount0())));
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(data.key.currency1);
            IERC20(Currency.unwrap(data.key.currency1))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount1())));
            manager.settle();
        }
        // Take positive deltas (output owed to recipient).
        if (delta.amount0() > 0) {
            manager.take(data.key.currency0, data.recipient, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(data.key.currency1, data.recipient, uint256(int256(delta.amount1())));
        }

        return abi.encode(delta);
    }
}

/// @notice Minimal non-RPC coverage for referral-rebate settlement on the REAL v4-core PoolManager.
contract MemeverseReferralRebateRealV4PoC is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address internal constant REFERRER = address(0xCAFE);

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    /// @dev Interface alias for the hook Router's rebate custody and views.
    IMemeverseUniswapHook internal engine;
    RealV4SwapIntegrator internal integrator;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    PoolKey internal key;

    function setUp() public {
        // 1. Deploy the REAL v4-core PoolManager (v4-core pins solc 0.8.26, so it can't be imported).
        manager = deployRealPoolManager();
        vm.label(address(manager), "RealPoolManager");

        treasury = makeAddr("treasury");

        // 2. Deploy tokens (token0 < token1 so currency0 < currency1).
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        // 3. Deploy the real hook/LP stack at a flag-address proxy.
        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        // Rebate assertions use the hook's Router interface.
        engine = hook;
        vm.label(hookProxy, "HookProxy");

        // 4. Integrator settles/takes against the real PoolManager.
        integrator = new RealV4SwapIntegrator(manager);

        // 5. Approvals: hook pulls LP+fee tokens via transferFrom; integrator pulls swap input.
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(integrator), type(uint256).max);
        token1.approve(address(integrator), type(uint256).max);

        // 6. Pool key (dynamic fee, tickSpacing 200, hook = proxy).
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000, // LPFeeLibrary.DYNAMIC_FEE_FLAG
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        // 7. Initialize pool on the real PoolManager (hook.beforeInitialize deploys LP token).
        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);

        // 8. Add full-range liquidity (100 ether of each). Hook unlockCallback settles to real PM.
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );

        // 9. Enable input-side protocol fee on currency0 so _beforeSwap charges it and routes
        //    through _collectProtocolFee -> accrueRebate.
        hook.setProtocolFeeCurrency(key.currency0, true);

        // 10. Push past the launch-fee decay window so the fee is the stable base fee.
        vm.warp(block.timestamp + 900);
    }

    // ---------------------------------------------------------------------
    // Minimal regression: referrer + rebate > 0 succeeds on real v4 PoolManager
    // ---------------------------------------------------------------------

    /// @notice This is the mandatory non-RPC guard for the delta-accounting bug. Fork tests cover
    ///         broader mainnet scenarios, but they skip when ETH_MAINNET_RPC is absent. This local
    ///         real-v4 test keeps the critical CurrencyNotSettled regression covered everywhere.
    function test_SwapWithReferrer_Succeeds_OnRealV4() public {
        // Sanity: default rebate is 1000 bps (10% of total fee) -> rebate > 0 on any fee.
        assertEq(engine.referrerRebateBps(), 1000, "default rebate bps");

        // WRITE-SIDE namespace round-trip: `afterSwap` -> `SwapFacet.afterSwapLogic` ->
        // `DynamicFeeFacet.updateAfterSwap` writes the per-trader batch state via facet delegatecall
        // into the shared hook namespace; the Router getter `addressBatchStateOf` reads the same
        // namespace. Task 2 made the hook-captured session principal the batch key (no tx.origin fallback),
        // so the trader here is this contract (the principal set by `beginAccountSession`), not tx.origin.
        // This closes the read/write loop the read-side `vm.store` test in MemeverseAddressBatchStateOf.t.sol
        // cannot express: a facet namespace drift (state written to a facet-local slot) would leave
        // batchStartTs == 0 here.
        address trader = address(this);
        PoolId poolId = key.toId();
        assertEq(uint256(hook.addressBatchStateOf(trader, poolId).batchStartTs), 0, "pre-swap: fresh batch");

        // The public swap callback requires an active session; open one so the integrator's swap runs.
        hook.beginAccountSession();
        BalanceDelta delta =
            integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();

        // zeroForOne exact-input: paid token0 (amount0 < 0), received token1 (amount1 > 0).
        assertLt(delta.amount0(), 0, "paid token0");
        assertGt(delta.amount1(), 0, "received token1");
        // Rebate accrued to the referrer in the input-side protocol-fee currency.
        assertGt(engine.pendingRebateOf(REFERRER, key.currency0), 0, "rebate accrued");
        // First swap takes the else-branch (DynamicFeeFacet.sol:93-95), writing block.timestamp != 0.
        assertGt(
            uint256(hook.addressBatchStateOf(trader, poolId).batchStartTs),
            0,
            "write-side: facet write visible to getter"
        );
    }

    /// @notice With a referrer but rebateBps set to zero, the swap still settles on real v4 and
    ///         records no rebate. This keeps the disabled-rebate branch covered without the broader
    ///         duplicate no-referrer case that the fork/mock rebate suites already exercise.
    function test_SwapWithReferrerZeroRebate_Succeeds_OnRealV4() public {
        hook.setReferrerRebateBps(0);
        assertEq(engine.referrerRebateBps(), 0, "rebate disabled");

        // The public swap callback requires an active session; open one so the integrator's swap runs.
        hook.beginAccountSession();
        BalanceDelta delta =
            integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();

        assertLt(delta.amount0(), 0, "paid token0");
        assertGt(delta.amount1(), 0, "received token1");
        assertEq(engine.pendingRebateOf(REFERRER, key.currency0), 0, "no rebate when bps=0");
    }

    /// @notice Non-skippable real-v4 settlement delta-closure guard. The fork preorder tests depend on
    ///         RPC and skip when it is absent; this inlines the genuine v4 bytecode so CI runs it every
    ///         build. A clean return from `executePreorderSettlement` IS the proof that the real
    ///         PoolManager's unlock exited with NonzeroDeltaCount == 0 (delta closure): a missing
    ///         settle/take inside the settlement callback would leave an open delta and revert with
    ///         CurrencyNotSettled here. This variant keeps the setUp input-side protocol fee (currency0),
    ///         so the callback only settles input + takes output to the recipient and never enters the
    ///         output-fee take branch.
    function test_PreorderSettlement_InputFee_Succeeds_OnRealV4() public {
        // Foundry re-runs setUp() before every test function, so the fee switch below does not
        // leak into the shared swap tests. This contract is the launcher (bound at deploy), so
        // settlement is authorized.

        uint256 recipientToken1Before = token1.balanceOf(address(this));

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key, params: _exactInputZeroForOne(10 ether), recipient: address(this)
            })
        );

        // zeroForOne exact-input: pay token0 (amount0 < 0), receive token1 (amount1 > 0).
        assertLt(delta.amount0(), 0, "paid token0");
        assertGt(delta.amount1(), 0, "received token1");
        // Recipient received the output token1 via the settlement-callback take.
        assertGt(token1.balanceOf(address(this)) - recipientToken1Before, 0, "recipient received output");
    }

    /// @notice Same real-v4 delta-closure guard as the input-fee variant, but moves the protocol fee to
    ///         the output currency (token1). This forces the settlement callback to additionally execute
    ///         `poolManager.take(outputCurrency, treasury, fee)`. On the real PoolManager, a SettlementFacet
    ///         arithmetic error in that fee take would leave an unsettled positive delta and revert with
    ///         CurrencyNotSettled at unlock exit — exactly the path the mock PoolManager does not catch,
    ///         which is the core incremental value of this guard.
    function test_PreorderSettlement_OutputFee_Succeeds_OnRealV4() public {
        // Foundry re-runs setUp() before every test function, so the fee switch below does not
        // leak into the shared swap tests. This contract is the launcher (bound at deploy), so
        // settlement is authorized.

        // Route the protocol fee to the output currency (token1) so the callback hits the output-fee
        // take branch (SettlementFacet: poolManager.take(outputCurrency, treasury, fee)).
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);

        uint256 recipientToken1Before = token1.balanceOf(address(this));
        uint256 treasuryToken1Before = token1.balanceOf(treasury);

        BalanceDelta delta = hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key, params: _exactInputZeroForOne(10 ether), recipient: address(this)
            })
        );

        assertLt(delta.amount0(), 0, "paid token0");
        assertGt(delta.amount1(), 0, "received token1");
        // Treasury received the output-side fee via the settlement-callback take. This is the
        // real-v4-only assertion: the mock would not revert even if this take's arithmetic were wrong.
        assertGt(token1.balanceOf(treasury) - treasuryToken1Before, 0, "treasury received output-side fee");
        // Recipient still received some output (strictly less than total output, since part was taken
        // to treasury); only assert > 0, the exact split is fee-config dependent.
        assertGt(token1.balanceOf(address(this)) - recipientToken1Before, 0, "recipient received output");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Exact-input swap of `amount` token0 -> token1 (zeroForOne). Input-side protocol
    ///      fee (currency0) is enabled in setUp, so the buggy accrueRebate path is exercised.
    function _exactInputZeroForOne(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    /// @dev Packs the referrer as the first 20 bytes of hookData, matching _decodeReferrer.
    function _packReferrer(address referrer) internal pure returns (bytes memory) {
        return abi.encodePacked(referrer);
    }
}
