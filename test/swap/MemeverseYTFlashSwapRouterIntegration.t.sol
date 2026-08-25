// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseYTFlashSwapRouter} from "../../src/swap/MemeverseYTFlashSwapRouter.sol";
import {IMemeverseYTFlashSwapRouter} from "../../src/swap/interfaces/IMemeverseYTFlashSwapRouter.sol";
import {MemeversePoolKeyLib} from "../../src/swap/libraries/MemeversePoolKeyLib.sol";
import {POLSplitterUpgradeable} from "../../src/polend/POLSplitterUpgradeable.sol";
import {IPOLSplitter} from "../../src/polend/interfaces/IPOLSplitter.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {AtomicSessionAccount} from "../mocks/swap/AccountSessionMocks.sol";

/// @title MemeverseYTFlashSwapRouterIntegrationTest
/// @notice Real v4 PoolManager + real Memeverse hook + real POLSplitterUpgradeable integration coverage for the YT Flash Swap
///         Router (Plan Task 6). Proves the flash settlement leg is equivalent to an ordinary PT/POL swap on the same
///         pool, that referrer rebates accrue only to the packed referrer, that the read-only Lens quote matches the
///         realized settlement, and that price bounds, Splitter Unlocked/settled state atomically roll back.
/// @dev The fixture deploys the genuine v4-core PoolManager bytecode, a flag-address hook diamond proxy, and an
///      ERC1967 POLSplitterUpgradeable proxy bound to a minimal in-file `FakeLauncher`. The fake launcher is mutable so the
///      Unlocked/settled rollback cases can flip the verse stage without a production launcher. The test contract never
///      inherits an upgradeable production contract: it talks to the proxy addresses via interfaces and `HookStorageHelper`.
contract MemeverseYTFlashSwapRouterIntegrationTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // =====================================================================================
    // Constants
    // =====================================================================================

    uint256 internal constant VERSE_ID = 42;
    uint256 internal constant MAX_OPPOSITE_ORDER_VERSE_CANDIDATES = 128;
    /// @dev Exact-YT amount used across the equivalence and matrix cases. Kept small so a single swap barely moves the
    ///      deep full-range pool, keeping both legs in the `0 < R < y` / `0 < Q < y` regime deterministically.
    uint256 internal constant YT_AMOUNT = 1 ether;
    /// @dev Splitter POL backing pre-seeded via a direct split so flash SELLS (which merge PT+YT back to POL) always
    ///      find collateral. Also mints the PT used to seed pool liquidity.
    uint256 internal constant SEED_SPLIT_AMOUNT = 5_000 ether;
    /// @dev Referral rebate rate (bps of the protocol fee) used for packed-referrer accrual assertions.
    uint256 internal constant REFERRER_REBATE_BPS = 1_000;
    /// @dev Initial pool tick chosen so PT trades materially below POL (1 PT ~= 0.5 POL), guaranteeing a non-trivial
    ///      `cost = y - R > 0` on buy and `out = y - Q > 0` on sell. Sign depends on the PT/POL sort order.
    int24 internal constant PT_CHEAP_TICK_MAGNITUDE = 6932;

    // =====================================================================================
    // Fixture state
    // =====================================================================================

    IPoolManager internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    FakeLauncher internal fakeLauncher;
    POLSplitterUpgradeable internal splitter;
    MemeverseYTFlashSwapRouter internal router;
    MemeverseUniswapHookLens internal lens;
    OrdinarySwapSettler internal settler;

    MockERC20 internal pol;
    MockERC20 internal memecoin;
    MockERC20 internal uAsset;
    address internal pt;
    address internal yt;

    PoolKey internal key;
    PoolId internal poolId;
    bool internal ptIsCurrency0;

    struct VersePool {
        uint256 verseId;
        address pt;
        address yt;
        PoolKey key;
        PoolId poolId;
        bool ptIsCurrency0;
    }

    VersePool internal primaryVersePool;
    VersePool internal oppositeOrderVersePool;

    // Payer account that drives the begin -> Router/settler -> end session frames.
    AtomicSessionAccount internal account;
    // Second account for the wrong-lens-trader attribution case.
    AtomicSessionAccount internal accountB;
    address internal recipient = makeAddr("recipient");
    address internal referrer = makeAddr("referrer");

    /// @dev Baseline snapshot captured in setUp; several matrix tests revert to it between scenarios.
    function setUp() public {
        // ── 1. Canonical passive tokens ──
        pol = new MockERC20("POL", "POL", 18);
        memecoin = new MockERC20("MEME", "MEME", 18);
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pol.mint(address(this), 100_000 ether);

        // ── 2. Real v4 PoolManager + real flag-address hook diamond ──
        manager = deployRealPoolManager();
        vm.label(address(manager), "RealPoolManager");
        // FakeLauncher is created next (step 3) and the hook must bind it as launcher at initialize
        // (write-once). Predict its address: deployHookAtFlagAddress consumes 6 sender nonces
        // (5 CREATE: LP impl + 3 facets + hook impl, + 1 nonce increment from the CREATE2'd ERC1967Proxy —
        // both CREATE and CREATE2 increment the sender nonce per EIP-1014), so FakeLauncher is the 7th
        // contract, created at nonce N+6.
        address predictedFakeLauncher = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 6);
        address hookProxy = deployHookAtFlagAddress(manager, address(this), address(this), predictedFakeLauncher);
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        vm.label(hookProxy, "HookProxy");

        // ── 3. Fake launcher bound to the hook proxy (splitter wired after it is deployed) ──
        fakeLauncher = new FakeLauncher(hookProxy, address(this), uAsset, pol);

        // ── 4. Real POLSplitterUpgradeable behind an ERC1967 proxy, launcher = fakeLauncher ──
        POLSplitterUpgradeable splitterImpl = new POLSplitterUpgradeable();
        splitter = POLSplitterUpgradeable(
            address(
                new ERC1967Proxy(
                    address(splitterImpl),
                    abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), address(fakeLauncher)))
                )
            )
        );
        fakeLauncher.setSplitter(address(splitter));

        // ── 5. Initialize primary and opposite-order PT/POL pools before fee maturation ──
        pol.approve(address(splitter), type(uint256).max);
        hook.setPoolInitializer(address(this));
        primaryVersePool = _initializeVerseAndPool(VERSE_ID);
        (uint256 oppositeVerseId, address predictedOppositePT) =
            _findOppositeOrderVerseId(primaryVersePool.ptIsCurrency0);
        oppositeOrderVersePool = _initializeVerseAndPool(oppositeVerseId);
        assertEq(oppositeOrderVersePool.pt, predictedOppositePT, "predicted opposite PT must be realized");
        assertTrue(
            oppositeOrderVersePool.ptIsCurrency0 != primaryVersePool.ptIsCurrency0,
            "opposite PT/POL sort order required"
        );

        // Preserve the primary globals used by the unrelated integration scenarios below.
        pt = primaryVersePool.pt;
        yt = primaryVersePool.yt;
        key = primaryVersePool.key;
        poolId = primaryVersePool.poolId;
        ptIsCurrency0 = primaryVersePool.ptIsCurrency0;

        // Mature both pools past the launch-fee decay window so dynamic fees settle to their floor.
        vm.warp(block.timestamp + 900);

        // ── 6. Rebate rate + real Router + Lens + ordinary settler (launcher already bound at deploy) ──
        hook.setReferrerRebateBps(REFERRER_REBATE_BPS);
        router =
            new MemeverseYTFlashSwapRouter(manager, IMemeverseUniswapHook(hookProxy), IPOLSplitter(address(splitter)));
        lens = new MemeverseUniswapHookLens(manager);
        settler = new OrdinarySwapSettler(manager);

        // ── 7. Payer accounts funded and approved for both the ordinary settler and the flash Router ──
        account = new AtomicSessionAccount();
        accountB = new AtomicSessionAccount();
        _fundAndApprove(address(account));
        _fundAndApproveVersePool(address(account), oppositeOrderVersePool);
        _fundAndApprove(address(accountB));

        vm.label(address(account), "Account");
        vm.label(address(accountB), "AccountB");
        vm.label(referrer, "Referrer");
    }

    // =====================================================================================
    // Step 1: ordinary-leg equivalence (the core invariant)
    // =====================================================================================

    /// @notice Primary-order buy with an input-side fee matches the ordinary exact-input PT/POL leg exactly.
    function test_RealV4_BuyFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, true);
    }

    /// @notice Primary-order sell with an input-side fee matches the ordinary exact-output POL/PT leg exactly.
    function test_RealV4_SellFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Sell, true);
    }

    /// @notice Primary-order buy with an output-side fee matches the ordinary PT/POL leg exactly.
    function test_RealV4_PrimaryOrderBuyOutputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, false);
    }

    /// @notice Primary-order sell with an output-side fee matches the ordinary POL/PT leg exactly.
    function test_RealV4_PrimaryOrderSellOutputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Sell, false);
    }

    /// @notice Opposite-order buy with an input-side fee matches the ordinary PT/POL leg exactly.
    function test_RealV4_OppositeOrderBuyInputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(oppositeOrderVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, true);
    }

    /// @notice Opposite-order sell with an input-side fee matches the ordinary POL/PT leg exactly.
    function test_RealV4_OppositeOrderSellInputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(oppositeOrderVersePool, MemeverseYTFlashSwapRouter.FlashAction.Sell, true);
    }

    /// @notice Opposite-order buy with an output-side fee matches the ordinary PT/POL leg exactly.
    function test_RealV4_OppositeOrderBuyOutputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(oppositeOrderVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, false);
    }

    /// @notice Opposite-order sell with an output-side fee matches the ordinary POL/PT leg exactly.
    function test_RealV4_OppositeOrderSellOutputFeeFlashLegEqualsOrdinaryLeg() external {
        _runDifferentialMatrixCase(oppositeOrderVersePool, MemeverseYTFlashSwapRouter.FlashAction.Sell, false);
    }

    /// @dev Configures one fee-side/order/action row, then compares ordinary and flash settlement from the same state.
    function _runDifferentialMatrixCase(
        VersePool memory versePool,
        MemeverseYTFlashSwapRouter.FlashAction action,
        bool protocolFeeOnInput
    ) internal {
        _configureProtocolFeeSide(versePool, action, protocolFeeOnInput);
        _compareOrdinaryLeg(versePool, action, YT_AMOUNT, referrer);
    }

    /// @dev Snapshot -> run ONE ordinary PT/POL swap via the settler -> revert -> run the flash leg via the Router.
    ///      Both legs therefore start from byte-identical EVM state, so every post-condition must match exactly. The
    ///      flash swap delta is recovered from the observable Router return (`polInUsed` / `polOut`), never from a
    ///      private internal field.
    function _compareOrdinaryLeg(
        VersePool memory versePool,
        MemeverseYTFlashSwapRouter.FlashAction action,
        uint256 y,
        address ref
    ) internal {
        uint256 id = vm.snapshotState();
        LegTrace memory ord = _runOrdinaryLeg(versePool, action, y, ref);
        vm.revertToState(id);
        LegTrace memory fl = _runFlashLeg(versePool, action, y, ref);

        (int128 flPtDelta, int128 flPolDelta) = _deriveFlashSwapDelta(action, y, fl.result);
        assertEq(int256(flPtDelta), int256(ord.ptDelta), "pt delta mismatch");
        assertEq(int256(flPolDelta), int256(ord.polDelta), "pol delta mismatch");
        assertEq(fl.slot0, ord.slot0, "post slot0 mismatch");
        assertEq(fl.ewVwapX18, ord.ewVwapX18, "dynamic fee ewVWAP mismatch");
        assertEq(fl.weightedVolume0, ord.weightedVolume0, "dynamic fee weightedVolume mismatch");
        assertEq(fl.batchAccumPpm, ord.batchAccumPpm, "address batch accum mismatch");
        assertEq(fl.batchStartTs, ord.batchStartTs, "address batch ts mismatch");
        assertEq(fl.rebatePt, ord.rebatePt, "referrer rebate (PT) mismatch");
        assertEq(fl.rebatePol, ord.rebatePol, "referrer rebate (POL) mismatch");
        assertEq(fl.fee0PerShare, ord.fee0PerShare, "fee0PerShare mismatch");
        assertEq(fl.fee1PerShare, ord.fee1PerShare, "fee1PerShare mismatch");
    }

    /// @dev Runs one ordinary PT/POL swap through the real hook callback path from `account`'s session, settling input
    ///      from and sending output to `account`. Captures the swap delta and the post-state the flash leg must match.
    function _runOrdinaryLeg(
        VersePool memory versePool,
        MemeverseYTFlashSwapRouter.FlashAction action,
        uint256 y,
        address ref
    ) internal returns (LegTrace memory trace) {
        SwapParams memory params = _underlyingSwapParams(versePool, action, y);
        bytes memory hookData = ref == address(0) ? bytes("") : abi.encodePacked(ref);
        bytes memory cd = abi.encodeCall(OrdinarySwapSettler.swap, (versePool.key, params, address(account), hookData));

        vm.prank(address(account));
        BalanceDelta delta = abi.decode(account.executeSession(hook, address(settler), cd), (BalanceDelta));

        (trace.ptDelta, trace.polDelta) = _mapDeltaToPTAndPOL(delta, versePool);
        _capturePostState(versePool, ref, trace);
    }

    /// @dev Runs the flash Router (buy or sell) from `account`'s session with a generous price bound so settlement
    ///      always completes, then captures the same post-state fields plus the Router's returned `polInUsed`/`polOut`.
    function _runFlashLeg(
        VersePool memory versePool,
        MemeverseYTFlashSwapRouter.FlashAction action,
        uint256 y,
        address ref
    ) internal returns (LegTrace memory trace) {
        bool buy = action == MemeverseYTFlashSwapRouter.FlashAction.Buy;
        bool zeroForOne = buy ? versePool.ptIsCurrency0 : !versePool.ptIsCurrency0;
        bytes memory cd = buy
            ? abi.encodeCall(
                router.swapPOLForExactYT,
                (versePool.verseId, y, y, _priceLimitFor(zeroForOne), recipient, block.timestamp + 600, ref)
            )
            : abi.encodeCall(
                router.swapExactYTForPOL,
                (versePool.verseId, y, 0, _priceLimitFor(zeroForOne), recipient, block.timestamp + 600, ref)
            );

        vm.prank(address(account));
        trace.result = abi.decode(account.executeSession(hook, address(router), cd), (uint256));

        _capturePostState(versePool, ref, trace);
    }

    // =====================================================================================
    // Step 2: deterministic integration matrix
    // =====================================================================================

    /// @notice A non-zero packed referrer receives the rebate carved out of the protocol fee on both buy and sell, and
    ///         no other address accrues anything. Proves the real hook keys rebate solely on the packed hookData bytes.
    function test_RealV4_PackedReferrerAccruesOnlyToReferrer() external {
        // Buy with referrer.
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    referrer
                )
            )
        );
        uint256 refRebate = hook.pendingRebateOf(referrer, Currency.wrap(pt))
            + hook.pendingRebateOf(referrer, Currency.wrap(address(pol)));
        assertGt(refRebate, 0, "referrer must accrue rebate on buy");

        // A fresh account with no swap attribution must have zero rebate.
        assertEq(hook.pendingRebateOf(address(accountB), Currency.wrap(pt)), 0, "no rebate to non-referrer (pt)");
        assertEq(
            hook.pendingRebateOf(address(accountB), Currency.wrap(address(pol))), 0, "no rebate to non-referrer (pol)"
        );

        // Sell with referrer accrues again, still only to the same referrer.
        uint256 before = hook.pendingRebateOf(referrer, Currency.wrap(address(pol)));
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, YT_AMOUNT, 0, _priceLimitFor(!ptIsCurrency0), recipient, block.timestamp + 600, referrer)
            )
        );
        uint256 afterPol = hook.pendingRebateOf(referrer, Currency.wrap(address(pol)));
        uint256 afterPt = hook.pendingRebateOf(referrer, Currency.wrap(pt));
        assertGt(afterPol + afterPt, before, "referrer must accrue again on sell");
    }

    /// @notice A zero referrer forwards empty hookData. The real swap still settles and no rebate accrues anywhere.
    /// @dev The unit-level `lastHookData == bytes("")` equality is proven in MemeverseYTFlashSwapRouter.t.sol; this test
    ///      proves the integration path runs end-to-end and leaves rebate state untouched.
    function test_RealV4_ZeroReferrerUsesEmptyData() external {
        uint256 polBefore = pol.balanceOf(address(account));
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        assertLt(pol.balanceOf(address(account)), polBefore, "payer POL must decrease");
        assertEq(IERC20(yt).balanceOf(recipient), YT_AMOUNT, "recipient YT received");
        assertEq(hook.pendingRebateOf(referrer, Currency.wrap(pt)), 0, "no rebate with empty hookData");
        assertEq(hook.pendingRebateOf(referrer, Currency.wrap(address(pol))), 0, "no rebate with empty hookData");
    }

    /// @notice Quoting the pool for accountB but EXECUTING the flash for accountA attributes state to accountA only:
    ///         the accountB quote never enters the Router's session. Proves the Lens trader is a read-only parameter.
    function test_RealV4_WrongLensTraderDoesNotEnterRouter() external {
        SwapParams memory params = SwapParams({
            zeroForOne: ptIsCurrency0,
            amountSpecified: -int256(YT_AMOUNT),
            sqrtPriceLimitX96: _priceLimitFor(ptIsCurrency0)
        });
        // Quote with the WRONG trader (accountB) — this is a STATICCALL and must not mutate state.
        lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(accountB));
        // accountB has not yet transacted.
        assertEq(
            uint256(hook.addressBatchStateOf(address(accountB), poolId).batchStartTs), 0, "quote must not write B state"
        );

        // Execute the flash for accountA.
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );

        assertGt(
            uint256(hook.addressBatchStateOf(address(account), poolId).batchStartTs),
            0,
            "state attributed to executing account A"
        );
        assertEq(
            uint256(hook.addressBatchStateOf(address(accountB), poolId).batchStartTs),
            0,
            "quote-only trader B never enters the Router"
        );
    }

    /// @notice The read-only Lens quote for the underlying swap matches the realized Router settlement exactly: for a
    ///         buy, `polInUsed == y - R_quote`; for a sell, `polOut == y - Q_quote`.
    function test_RealV4_UnchangedStateLensQuoteMatchesSettlement() external {
        // Each leg keeps several memory variables and two external-call return values live at once, which under
        // `forge coverage --ir-minimum` (viaIR with minimum optimization) overflows the EVM stack. Extracting each
        // leg into its own function call forces the compiler to release one leg's locals before analysing the next.
        _assertBuyLensQuoteMatchesSettlement();
        _assertSellLensQuoteMatchesSettlement();
    }

    /// @dev BUY leg of `test_RealV4_UnchangedStateLensQuoteMatchesSettlement`: underlying exact-input PT swap.
    ///      Lens returns R as the POL output; Router cost is y - R.
    function _assertBuyLensQuoteMatchesSettlement() internal {
        SwapParams memory buyParams = SwapParams({
            zeroForOne: ptIsCurrency0,
            amountSpecified: -int256(YT_AMOUNT),
            sqrtPriceLimitX96: _priceLimitFor(ptIsCurrency0)
        });
        IMemeverseUniswapHook.SwapQuote memory buyQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, buyParams, address(account));
        vm.prank(address(account));
        uint256 polInUsed = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapPOLForExactYT,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        YT_AMOUNT,
                        _priceLimitFor(ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        // Lens is a read-only re-execution of the same fee/curve math (hook beforeSwap strips fees into a custom
        // delta and returns lpFeeBps=0, so v4's internal SwapMath runs on identical inputs to the Lens curve call).
        // On this unchanged state the quote and the realized settlement are therefore bit-identical — assertEq.
        assertEq(polInUsed, YT_AMOUNT - buyQuote.estimatedUserOutputAmount, "buy: polInUsed == y - R_quote");
    }

    /// @dev SELL leg of `test_RealV4_UnchangedStateLensQuoteMatchesSettlement`: underlying exact-output PT swap.
    ///      Lens returns Q as the POL input; Router output is y - Q.
    function _assertSellLensQuoteMatchesSettlement() internal {
        SwapParams memory sellParams = SwapParams({
            zeroForOne: !ptIsCurrency0,
            amountSpecified: int256(YT_AMOUNT),
            sqrtPriceLimitX96: _priceLimitFor(!ptIsCurrency0)
        });
        IMemeverseUniswapHook.SwapQuote memory sellQuote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, sellParams, address(account));
        vm.prank(address(account));
        uint256 polOut = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapExactYTForPOL,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        0,
                        _priceLimitFor(!ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        assertEq(polOut, YT_AMOUNT - sellQuote.estimatedUserInputAmount, "sell: polOut == y - Q_quote");
    }

    /// @notice A generous `maxPOLIn` bound is never fully pulled: the Router only pulls the actual cost, which is
    ///         strictly less than the bound when the realized price is at-or-better than the user's reference.
    function test_RealV4_PriceImprovementPullsLessPOL() external {
        uint256 generousMax = YT_AMOUNT; // cost is always < y because R > 0
        vm.prank(address(account));
        uint256 polInUsed = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapPOLForExactYT,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        generousMax,
                        _priceLimitFor(ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        assertLt(polInUsed, generousMax, "actual cost must be strictly below the generous maxPOLIn");
        assertEq(IERC20(yt).balanceOf(recipient), YT_AMOUNT, "recipient YT received");
    }

    /// @notice A buy whose realized cost exceeds `maxPOLIn` reverts with `MaxPOLInExceeded` before any take, payer pull,
    ///         split, or settle. The whole unlock rolls back, so the payer's POL balance is unchanged.
    function test_RevertWhen_RealV4PriceWorseningExceedsMax() external {
        // First learn the actual cost from a successful buy (state then rolled back).
        uint256 id = vm.snapshotState();
        vm.prank(address(account));
        uint256 actualCost = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapPOLForExactYT,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        YT_AMOUNT,
                        _priceLimitFor(ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        vm.revertToState(id);

        uint256 tooLowMax = actualCost - 1;
        uint256 polBefore = pol.balanceOf(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MaxPOLInExceeded.selector, actualCost, tooLowMax)
        );
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    tooLowMax,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        // Atomic rollback: the payer lost no POL despite the swap having started inside the unlock.
        assertEq(pol.balanceOf(address(account)), polBefore, "failed buy must roll back payer POL");
    }

    /// @notice A generous `minPOLOut` floor is always exceeded on a normal sell: the Router delivers the actual net
    ///         output, which is strictly greater than a zero floor whenever `Q < y`.
    function test_RealV4_SellPriceImprovementPaysMorePOL() external {
        uint256 polBefore = pol.balanceOf(recipient);
        vm.prank(address(account));
        uint256 polOut = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapExactYTForPOL,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        1,
                        _priceLimitFor(!ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        assertGt(polOut, 1, "actual net POL out must exceed the min floor");
        assertEq(pol.balanceOf(recipient) - polBefore, polOut, "recipient received net POL");
    }

    /// @notice A sell whose realized net output is below `minPOLOut` reverts with `MinPOLOutNotMet` before any take,
    ///         payer YT pull, merge, or settle. The whole unlock rolls back.
    function test_RevertWhen_RealV4SellPriceWorseningBelowMinBeforeFunds() external {
        // Learn the actual net output from a successful sell, then roll back.
        uint256 id = vm.snapshotState();
        vm.prank(address(account));
        uint256 actualOut = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapExactYTForPOL,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        0,
                        _priceLimitFor(!ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        vm.revertToState(id);

        uint256 tooHighMin = actualOut + 1;
        uint256 ytBefore = IERC20(yt).balanceOf(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MinPOLOutNotMet.selector, actualOut, tooHighMin)
        );
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    tooHighMin,
                    _priceLimitFor(!ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        assertEq(IERC20(yt).balanceOf(address(account)), ytBefore, "failed sell must roll back payer YT");
    }

    // -------------------------------------------------------------------------------------
    // Step 2b: post-quote state drift. The four tests below insert a REAL
    // intervening PT/POL swap between the Lens quote and the Router execution so the pool
    // price has genuinely moved at execution time. The intervening swap direction is chosen
    // by re-quoting after it (never hard-coded): if the candidate direction does not move
    // the state the way the scenario expects, the opposite direction is used instead.
    // -------------------------------------------------------------------------------------

    /// @notice BUY + state IMPROVEMENT. After the quote the pool moves so PT is worth more POL, so the same `y` input
    ///         yields a larger `R` and a smaller realized `cost`. The user bounds `maxPOLIn` from the quote
    ///         (`baselineCost`), not generously, and the Router still pulls strictly less than that bound.
    function test_RealV4_PostQuoteBuyImprovementPullsLessPOL() external {
        // Baseline quote taken on the un-mutated pool: R and derived cost at execution-time quote.
        (uint256 baselineR,) = _lensQuoteBuyR();
        uint256 baselineCost = YT_AMOUNT - baselineR;

        // Intervening swap must move the state so a fresh buy quote returns a larger R (smaller cost). Drive it through
        // accountB so it lands as its own committed swap (independent of account's session).
        _moveBuyRHigher(baselineR);

        // Verify the drift actually happened (self-validating direction): a fresh quote must show strict improvement.
        (uint256 postR,) = _lensQuoteBuyR();
        assertGt(postR, baselineR, "intervening swap must raise R (improve buy)");

        // Execute with the quote-derived (non-generous) bound. The realized cost must be strictly below it.
        uint256 polBefore = pol.balanceOf(address(account));
        vm.prank(address(account));
        uint256 polInUsed = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapPOLForExactYT,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        baselineCost, // user committed to at-most this cost before the state moved
                        _priceLimitFor(ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        assertLt(polInUsed, baselineCost, "improved buy must pull strictly less than the quoted maxPOLIn");
        assertEq(IERC20(yt).balanceOf(recipient), YT_AMOUNT, "recipient YT received");
        assertEq(polBefore - pol.balanceOf(address(account)), polInUsed, "payer paid exactly the realized cost");
    }

    /// @notice BUY + state WORSENING. After the quote the pool moves so PT is worth less POL (smaller `R`, larger `cost`).
    ///         The user bounds `maxPOLIn` from the baseline quote; execution now needs strictly more, so `MaxPOLInExceeded`
    ///         reverts before any take/pull/split, and the payer's POL is untouched (atomic rollback).
    function test_RevertWhen_PostQuoteBuyWorseningExceedsMax() external {
        (uint256 baselineR,) = _lensQuoteBuyR();
        uint256 baselineCost = YT_AMOUNT - baselineR;

        // Intervening swap must move the state so a fresh buy quote returns a smaller R (larger cost).
        _moveBuyRLower(baselineR);

        (uint256 postR,) = _lensQuoteBuyR();
        assertLt(postR, baselineR, "intervening swap must lower R (worsen buy)");

        // On unchanged state the Lens quote equals the realized settlement (test_RealV4_UnchangedStateLensQuoteMatchesSettlement),
        // so the post-drift quote gives the exact `actual` cost the guard will emit.
        uint256 expectedActualCost = YT_AMOUNT - postR;

        uint256 polBefore = pol.balanceOf(address(account));
        // Assert the full payload: actual = drifted cost (strictly above the baseline bound), maximum = the user's
        // pre-drift commitment.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseYTFlashSwapRouter.MaxPOLInExceeded.selector, expectedActualCost, baselineCost
            )
        );
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    baselineCost, // committed before the state worsened
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        // Atomic rollback: the payer lost no POL despite the swap having entered the unlock.
        assertEq(pol.balanceOf(address(account)), polBefore, "worsened buy must roll back payer POL");
    }

    /// @notice SELL + state IMPROVEMENT. After the quote the pool moves so the same `y` exact-output PT leg needs less
    ///         POL input (`Q` shrinks, `out = y - Q` grows). The user bounds `minPOLOut` from the baseline quote, and
    ///         the Router delivers strictly more than that floor.
    function test_RealV4_PostQuoteSellImprovementPaysMorePOL() external {
        (, uint256 baselineQ) = _lensQuoteSellQ();
        uint256 baselineOut = YT_AMOUNT - baselineQ;

        // Intervening swap must move the state so a fresh sell quote needs less POL input (larger output).
        _moveSellQLower(baselineQ);

        (, uint256 postQ) = _lensQuoteSellQ();
        assertLt(postQ, baselineQ, "intervening swap must shrink Q (improve sell)");

        uint256 polBefore = pol.balanceOf(recipient);
        vm.prank(address(account));
        uint256 polOut = abi.decode(
            account.executeSession(
                hook,
                address(router),
                abi.encodeCall(
                    router.swapExactYTForPOL,
                    (
                        VERSE_ID,
                        YT_AMOUNT,
                        baselineOut, // user committed to at-least this output before the state moved
                        _priceLimitFor(!ptIsCurrency0),
                        recipient,
                        block.timestamp + 600,
                        address(0)
                    )
                )
            ),
            (uint256)
        );
        assertGt(polOut, baselineOut, "improved sell must pay strictly more than the quoted minPOLOut");
        assertEq(pol.balanceOf(recipient) - polBefore, polOut, "recipient received net POL");
    }

    /// @notice SELL + state WORSENING. After the quote the pool moves so the same `y` exact-output PT leg needs more POL
    ///         input (`Q` grows, `out` shrinks). The user bounds `minPOLOut` from the baseline quote; execution now
    ///         delivers strictly less, so `MinPOLOutNotMet` reverts before any take/pull/merge, and the payer's YT is
    ///         untouched (atomic rollback).
    function test_RevertWhen_PostQuoteSellWorseningBelowMin() external {
        (, uint256 baselineQ) = _lensQuoteSellQ();
        uint256 baselineOut = YT_AMOUNT - baselineQ;

        // Intervening swap must move the state so a fresh sell quote needs more POL input (smaller output).
        _moveSellQHigher(baselineQ);

        (, uint256 postQ) = _lensQuoteSellQ();
        assertGt(postQ, baselineQ, "intervening swap must grow Q (worsen sell)");

        // On unchanged state the Lens quote equals the realized settlement (test_RealV4_UnchangedStateLensQuoteMatchesSettlement),
        // so the post-drift quote gives the exact `actual` out the guard will emit.
        uint256 expectedActualOut = YT_AMOUNT - postQ;

        uint256 ytBefore = IERC20(yt).balanceOf(address(account));
        // Assert the full payload: actual = drifted out (strictly below the baseline floor), minimum = the user's
        // pre-drift commitment.
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseYTFlashSwapRouter.MinPOLOutNotMet.selector, expectedActualOut, baselineOut)
        );
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    baselineOut, // committed before the state worsened
                    _priceLimitFor(!ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        // Atomic rollback: the payer's YT is untouched despite the swap having entered the unlock.
        assertEq(IERC20(yt).balanceOf(address(account)), ytBefore, "worsened sell must roll back payer YT");
    }

    /// @notice A buy whose `sqrtPriceLimitX96` would only partially fill the exact-input `y` PT leg is rejected before
    ///         any fund movement: the hook's `beforeSwap` pre-check (`OrdinarySwapMath.revertIfFinalTargetIsNotExecutable`)
    ///         reverts `FinalTargetNotExecutable` because the full-range capacity up to that limit is below the `y`
    ///         target. v4 wraps that into a `WrappedError` and the whole unlock rolls back, so the payer's POL is
    ///         unchanged.
    /// @dev This replaces a previously skipped test whose `vm.skip` note made a factually wrong claim: it asserted
    ///      "exact-y legs either fill fully or revert at the v4 layer". The real protection is upstream of the Router:
    ///      the Memeverse hook computes the full-fill capacity up to the supplied `sqrtPriceLimitX96` in `beforeSwap`
    ///      and reverts before v4's `Pool.swap` can return a partial delta. The Router's `FlashDeltaMismatch` guard
    ///      therefore never observes a partial-delta buy through a real price limit; this regression pins the actual
    ///      protective layer and the atomic rollback it guarantees.
    function test_RevertWhen_RealV4BuyPartialFillViaPriceLimit() external {
        // Probe: run a successful full buy to learn the post-fill target tick, then roll back to construct a limit that
        // strictly under-fills `y`.
        uint256 id = vm.snapshotState();
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        (, int24 targetTick,,) = manager.getSlot0(poolId);
        vm.revertToState(id);

        uint256 polBefore = pol.balanceOf(address(account));

        // Pick a limit tick strictly between the current tick and the full-fill target tick. Buy is zeroForOne ==
        // ptIsCurrency0 (price moves toward making PT cheaper: tick falls if ptIsCurrency0, rises otherwise), so the
        // mid tick stops the curve before `y` is fully consumed and capacity < target by construction.
        (, int24 currentTick,,) = manager.getSlot0(poolId);
        int24 midTick = currentTick + (targetTick - currentTick) / 2;
        if (ptIsCurrency0) {
            if (midTick >= currentTick) midTick = currentTick - 1;
        } else {
            if (midTick <= currentTick) midTick = currentTick + 1;
        }
        uint160 partialLimit = TickMath.getSqrtPriceAtTick(midTick);

        // The hook reverts `FinalTargetNotExecutable` from inside `beforeSwap`; v4's `Hooks.callHook` wraps it as
        // `WrappedError(hook, beforeSwap.selector, FinalTargetNotExecutable(), HookCallFailed())` (ERC-7751). The exact
        // byte payload is reconstructed below rather than asserted by selector, because `WrappedError` carries data
        // after its selector and forge matches `expectRevert` strictly. Every field is a deterministic constant for
        // this path: hook address, the beforeSwap selector, the capacity-revert reason, and HookCallFailed.
        bytes memory expectedRevert = abi.encodeWithSelector(
            _WRAPPED_ERROR_SELECTOR,
            address(hook),
            _BEFORE_SWAP_SELECTOR,
            abi.encodePacked(_FINAL_TARGET_NOT_EXECUTABLE_SELECTOR),
            abi.encodePacked(_HOOK_CALL_FAILED_SELECTOR)
        );

        vm.expectRevert(expectedRevert);
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapPOLForExactYT,
                (VERSE_ID, YT_AMOUNT, YT_AMOUNT, partialLimit, recipient, block.timestamp + 600, address(0))
            )
        );

        // Atomic rollback: the payer's POL is untouched despite the swap having entered the unlock.
        assertEq(pol.balanceOf(address(account)), polBefore, "partial-fill buy must roll back payer POL");
    }

    /// @notice A sell whose `sqrtPriceLimitX96` would only partially fill the exact-output `y` PT leg is rejected by
    ///         the hook's `beforeSwap` capacity pre-check (`FinalTargetNotExecutable`) before any take/pull/merge.
    ///         v4 wraps it into a `WrappedError` and the whole unlock rolls back, so the payer's YT is unchanged.
    function test_RevertWhen_RealV4SellPartialFillViaPriceLimit() external {
        // Probe: run a successful full sell to learn the post-fill target tick, then roll back.
        uint256 id = vm.snapshotState();
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, YT_AMOUNT, 0, _priceLimitFor(!ptIsCurrency0), recipient, block.timestamp + 600, address(0))
            )
        );
        (, int24 targetTick,,) = manager.getSlot0(poolId);
        vm.revertToState(id);

        uint256 ytBefore = IERC20(yt).balanceOf(address(account));

        // Pick a limit tick strictly between the current tick and the full-fill target tick. Sell is zeroForOne ==
        // !ptIsCurrency0 (price moves opposite to the buy: tick rises if ptIsCurrency0, falls otherwise), so the mid
        // tick again under-fills `y` PT and capacity < target by construction.
        (, int24 currentTick,,) = manager.getSlot0(poolId);
        int24 midTick = currentTick + (targetTick - currentTick) / 2;
        if (ptIsCurrency0) {
            if (midTick <= currentTick) midTick = currentTick + 1;
        } else {
            if (midTick >= currentTick) midTick = currentTick - 1;
        }
        uint160 partialLimit = TickMath.getSqrtPriceAtTick(midTick);

        // Same wrapped `FinalTargetNotExecutable` path as the buy; see that test for the byte-for-byte rationale.
        bytes memory expectedRevert = abi.encodeWithSelector(
            _WRAPPED_ERROR_SELECTOR,
            address(hook),
            _BEFORE_SWAP_SELECTOR,
            abi.encodePacked(_FINAL_TARGET_NOT_EXECUTABLE_SELECTOR),
            abi.encodePacked(_HOOK_CALL_FAILED_SELECTOR)
        );

        vm.expectRevert(expectedRevert);
        vm.prank(address(account));
        account.executeSession(
            hook,
            address(router),
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, YT_AMOUNT, 0, partialLimit, recipient, block.timestamp + 600, address(0))
            )
        );

        // Atomic rollback: the payer's YT is untouched despite the swap having entered the unlock.
        assertEq(IERC20(yt).balanceOf(address(account)), ytBefore, "partial-fill sell must roll back payer YT");
    }

    /// @dev Selectors of the v4/hook error frames observed when a partial-fill price limit is rejected by the hook's
    ///      `beforeSwap` capacity pre-check. Verified against the live v4-core trace (the `vm.skip` note it replaces
    ///      wrongly claimed exact-y legs always fill fully). `WrappedError` is ERC-7751
    ///      `(address,bytes4,bytes,bytes)`; the inner reason is `FinalTargetNotExecutable` and the detail is v4's
    ///      `HookCallFailed` set in `Hooks.callHook`. Kept as named constants so the asserted revert stays readable.
    bytes4 internal constant _WRAPPED_ERROR_SELECTOR = bytes4(0x90bfb865);
    bytes4 internal constant _BEFORE_SWAP_SELECTOR = bytes4(0x575e24b4);
    bytes4 internal constant _FINAL_TARGET_NOT_EXECUTABLE_SELECTOR = bytes4(0x5698f557);
    bytes4 internal constant _HOOK_CALL_FAILED_SELECTOR = bytes4(0xa9e35b2f);

    /// @notice When the launcher reports `Stage.Unlocked`, both buy and sell revert with POLSplitterUpgradeable.AlreadyUnlocked
    ///         and the whole flash rolls back atomically.
    function test_RevertWhen_RealSplitterUnlockedStageRollsBackBuyAndSell() external {
        fakeLauncher.setUnlocked();
        uint256 polBefore = pol.balanceOf(address(account));

        vm.expectRevert(IPOLSplitter.AlreadyUnlocked.selector);
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );
        assertEq(pol.balanceOf(address(account)), polBefore, "Unlocked buy must roll back payer POL");

        vm.expectRevert(IPOLSplitter.AlreadyUnlocked.selector);
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, YT_AMOUNT, 0, _priceLimitFor(!ptIsCurrency0), recipient, block.timestamp + 600, address(0))
            )
        );
        assertEq(IERC20(yt).balanceOf(address(account)), YT_FUND_AMOUNT, "Unlocked sell must roll back payer YT");
    }

    /// @notice Once the Splitter is genuinely settled, restoring `Stage.Locked` does NOT reopen split/merge: the
    ///         `info.settled` guard still reverts AlreadyUnlocked. This isolates the settled guard from the stage guard.
    /// @dev The fixture completes a REAL `POLSplitterUpgradeable.settle` first (FakeLauncher.redeemMemecoinLiquidity mints 1:1
    ///      uAsset so the settlement accounting balances), then flips the stage back to Locked. Production lifecycle
    ///      never returns from Unlocked to Locked; this test fakes it ONLY to isolate the settled guard.
    function test_RevertWhen_RealSplitterSettledRollsBackBuyAndSell() external {
        // Stage must be Unlocked for settle to be accepted.
        fakeLauncher.setUnlocked();
        vm.prank(address(fakeLauncher));
        splitter.settle(VERSE_ID);
        assertTrue(_isSettled(VERSE_ID), "fixture must reach settled=true");

        // Restore Locked so any revert below is attributable solely to the settled guard, not the stage guard.
        fakeLauncher.setLocked();

        vm.expectRevert(IPOLSplitter.AlreadyUnlocked.selector);
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );

        vm.expectRevert(IPOLSplitter.AlreadyUnlocked.selector);
        _runFlashFromAccount(
            abi.encodeCall(
                router.swapExactYTForPOL,
                (VERSE_ID, YT_AMOUNT, 0, _priceLimitFor(!ptIsCurrency0), recipient, block.timestamp + 600, address(0))
            )
        );
    }

    /// @notice One successful flash swap advances the per-trader, per-pool dynamic state exactly once: batchStartTs goes
    ///         from zero to the block timestamp, and the volatility/batch accumulators become non-zero.
    function test_RealV4_DynamicStateAdvancesOnce() external {
        assertEq(
            uint256(hook.addressBatchStateOf(address(account), poolId).batchStartTs), 0, "no batch before first swap"
        );
        assertEq(hook.dynamicFeeStateOf(poolId).ewVWAPX18, 0, "no ewVWAP before first swap");

        _runFlashFromAccount(
            abi.encodeCall(
                router.swapPOLForExactYT,
                (
                    VERSE_ID,
                    YT_AMOUNT,
                    YT_AMOUNT,
                    _priceLimitFor(ptIsCurrency0),
                    recipient,
                    block.timestamp + 600,
                    address(0)
                )
            )
        );

        assertGt(uint256(hook.addressBatchStateOf(address(account), poolId).batchStartTs), 0, "batch advanced once");
        assertGt(
            uint256(hook.addressBatchStateOf(address(account), poolId).batchAccumPpm), 0, "batch accum advanced once"
        );
        assertGt(hook.dynamicFeeStateOf(poolId).ewVWAPX18, 0, "dynamic fee state advanced once");
    }

    // =====================================================================================
    // Internal helpers
    // =====================================================================================

    /// @dev Initializes one independent splitter verse and its deep full-range PT/POL pool.
    function _initializeVerseAndPool(uint256 verseId) internal returns (VersePool memory versePool) {
        vm.prank(address(fakeLauncher));
        (versePool.pt, versePool.yt) =
            splitter.initializeVerse(verseId, address(pol), address(memecoin), address(uAsset), "PT", "YT");
        vm.prank(address(fakeLauncher));
        splitter.recordPTBackingRatio(verseId, 1 ether, 1 ether);

        // Directly splitting gives this fixture both pool PT liquidity and splitter POL collateral.
        splitter.split(verseId, SEED_SPLIT_AMOUNT);
        versePool.verseId = verseId;
        versePool.ptIsCurrency0 = versePool.pt < address(pol);
        versePool.key = MemeversePoolKeyLib.hookPoolKey(versePool.pt, address(pol), address(hook));
        versePool.poolId = versePool.key.toId();

        IERC20(versePool.pt).approve(address(hook), type(uint256).max);
        pol.approve(address(hook), type(uint256).max);
        uint160 initSqrt =
            TickMath.getSqrtPriceAtTick(versePool.ptIsCurrency0 ? -PT_CHEAP_TICK_MAGNITUDE : PT_CHEAP_TICK_MAGNITUDE);
        hook.authorizePoolInitialization(versePool.key, initSqrt);
        manager.initialize(versePool.key, initSqrt);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: versePool.key.currency0,
                currency1: versePool.key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }

    /// @dev Finds an unused verse id whose deterministic PT clone sorts opposite the primary PT.
    function _findOppositeOrderVerseId(bool primaryPtIsCurrency0)
        internal
        view
        returns (uint256 verseId, address predictedPT)
    {
        // CREATE2 prediction lets the fixture choose the opposite sort order before deploying the second verse.
        for (uint256 offset = 1; offset <= MAX_OPPOSITE_ORDER_VERSE_CANDIDATES; ++offset) {
            verseId = VERSE_ID + offset;
            predictedPT = Clones.predictDeterministicAddress(
                splitter.principalTokenImplementation(), bytes32(verseId), address(splitter)
            );
            if ((predictedPT < address(pol)) != primaryPtIsCurrency0) return (verseId, predictedPT);
        }
        revert("opposite PT/POL order not found");
    }

    /// @dev Builds the ordinary PT/POL leg underlying the requested flash action.
    function _underlyingSwapParams(VersePool memory versePool, MemeverseYTFlashSwapRouter.FlashAction action, uint256 y)
        internal
        pure
        returns (SwapParams memory params)
    {
        bool buy = action == MemeverseYTFlashSwapRouter.FlashAction.Buy;
        bool zeroForOne = buy ? versePool.ptIsCurrency0 : !versePool.ptIsCurrency0;
        params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: buy ? -int256(y) : int256(y),
            sqrtPriceLimitX96: _priceLimitFor(zeroForOne)
        });
    }

    /// @dev Resets the target pool's PT and shared POL flags, then enables only the requested route leg.
    function _configureProtocolFeeSide(
        VersePool memory versePool,
        MemeverseYTFlashSwapRouter.FlashAction action,
        bool protocolFeeOnInput
    ) internal {
        Currency ptCurrency = Currency.wrap(versePool.pt);
        Currency polCurrency = Currency.wrap(address(pol));
        hook.setProtocolFeeCurrency(ptCurrency, false);
        hook.setProtocolFeeCurrency(polCurrency, false);

        bool buy = action == MemeverseYTFlashSwapRouter.FlashAction.Buy;
        Currency inputCurrency = buy ? ptCurrency : polCurrency;
        Currency outputCurrency = buy ? polCurrency : ptCurrency;
        Currency feeCurrency = protocolFeeOnInput ? inputCurrency : outputCurrency;
        hook.setProtocolFeeCurrency(feeCurrency, true);

        bool ptSupported = Currency.unwrap(feeCurrency) == versePool.pt;
        bool polSupported = Currency.unwrap(feeCurrency) == address(pol);
        assertEq(hook.supportedProtocolFeeCurrencies(versePool.pt), ptSupported, "PT fee flag mismatch");
        assertEq(hook.supportedProtocolFeeCurrencies(address(pol)), polSupported, "POL fee flag mismatch");

        IMemeverseUniswapHook.SwapQuote memory quote = lens.quoteSwap(
            IMemeverseUniswapHook(address(hook)),
            versePool.key,
            _underlyingSwapParams(versePool, action, YT_AMOUNT),
            address(account)
        );
        assertEq(quote.protocolFeeOnInput, protocolFeeOnInput, "Lens fee side mismatch");
    }

    /// @dev POL funding granted to each payer account.
    uint256 internal constant POL_FUND_AMOUNT = 10_000 ether;
    /// @dev PT/YT funding granted to each payer account.
    uint256 internal constant YT_FUND_AMOUNT = 500 ether;

    function _fundAndApprove(address holder) internal {
        pol.mint(holder, POL_FUND_AMOUNT);
        require(IERC20(pt).transfer(holder, YT_FUND_AMOUNT));
        require(IERC20(yt).transfer(holder, YT_FUND_AMOUNT));
        // Ordinary settler pulls PT and POL input from msg.sender (the account).
        vm.prank(holder);
        IERC20(pt).approve(address(settler), type(uint256).max);
        vm.prank(holder);
        pol.approve(address(settler), type(uint256).max);
        // Flash Router pulls POL (buy cost) and YT (sell input) from msg.sender (the account).
        vm.prank(holder);
        pol.approve(address(router), type(uint256).max);
        vm.prank(holder);
        IERC20(yt).approve(address(router), type(uint256).max);
        // The account helper itself must approve nothing; it only forwards calls.
    }

    /// @dev Funds and approves the second verse without giving accountB access to its PT or YT.
    function _fundAndApproveVersePool(address holder, VersePool memory versePool) internal {
        require(IERC20(versePool.pt).transfer(holder, YT_FUND_AMOUNT));
        require(IERC20(versePool.yt).transfer(holder, YT_FUND_AMOUNT));
        vm.prank(holder);
        IERC20(versePool.pt).approve(address(settler), type(uint256).max);
        vm.prank(holder);
        IERC20(versePool.yt).approve(address(router), type(uint256).max);
    }

    /// @dev Drives one Router call through `account`'s atomic session frame.
    function _runFlashFromAccount(bytes memory cd) internal {
        vm.prank(address(account));
        account.executeSession(hook, address(router), cd);
    }

    /// @dev Valid full-range price limit for the given swap direction.
    function _priceLimitFor(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // -------------------------------------------------------------------------------------
    // Helpers for the post-quote state-drift scenarios. The intervening swap
    // direction is chosen by re-quoting rather than hard-coded, so a wrong PT/POL sort order
    // assumption can never silently invert a scenario. All intervening swaps go through
    // `accountB`'s session so they commit as independent trades distinct from `account`.
    // -------------------------------------------------------------------------------------

    /// @dev Size of the intervening swap. Kept below `YT_AMOUNT` so the price moves enough to flip R/Q but neither leg
    ///      leaves the `0 < R < y` / `0 < Q < y` regime the Router guards depend on.
    uint256 internal constant DRIFT_SWAP_AMOUNT = YT_AMOUNT / 2;

    /// @dev Quotes the buy leg (`zeroForOne = ptIsCurrency0`, exact-input `-y` PT -> POL) on the current pool. Returns
    ///      `R` (the POL output of the swap = `buyQuote.estimatedUserOutputAmount`) and the derived `cost = y - R`.
    function _lensQuoteBuyR() internal view returns (uint256 r, uint256 cost) {
        SwapParams memory params = SwapParams({
            zeroForOne: ptIsCurrency0,
            amountSpecified: -int256(YT_AMOUNT),
            sqrtPriceLimitX96: _priceLimitFor(ptIsCurrency0)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(account));
        r = quote.estimatedUserOutputAmount; // buy: POL output of the PT->POL swap
        cost = YT_AMOUNT - r;
    }

    /// @dev Quotes the sell leg (`zeroForOne = !ptIsCurrency0`, exact-output `+y` PT <- POL) on the current pool. Returns
    ///      the derived `out = y - Q` and `Q` (the POL input of the swap = `sellQuote.estimatedUserInputAmount`).
    function _lensQuoteSellQ() internal view returns (uint256 out, uint256 q) {
        SwapParams memory params = SwapParams({
            zeroForOne: !ptIsCurrency0,
            amountSpecified: int256(YT_AMOUNT),
            sqrtPriceLimitX96: _priceLimitFor(!ptIsCurrency0)
        });
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(account));
        q = quote.estimatedUserInputAmount; // sell: POL input of the POL->PT swap
        out = YT_AMOUNT - q;
    }

    /// @dev Runs one ordinary PT/POL swap of size `DRIFT_SWAP_AMOUNT` in the given direction through `accountB`'s session.
    ///      Used by the drift helpers to move the pool between the Lens quote and the Router execution.
    function _runInterveningSwap(bool zeroForOne, int256 amountSpecified) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: _priceLimitFor(zeroForOne)
        });
        bytes memory cd = abi.encodeCall(OrdinarySwapSettler.swap, (key, params, address(accountB), bytes("")));
        vm.prank(address(accountB));
        accountB.executeSession(hook, address(settler), cd);
    }

    /// @dev Moves the pool so the next buy quote returns a strictly larger `R` than `baselineR`. Tries the buy-style
    ///      direction first; if re-quoting shows it did not raise `R`, the candidate swap is discarded via a snapshot and
    ///      the opposite direction is applied instead. The caller re-quotes to confirm.
    function _moveBuyRHigher(uint256 baselineR) internal {
        uint256 id = vm.snapshotState();
        _runInterveningSwap(ptIsCurrency0, -int256(DRIFT_SWAP_AMOUNT));
        (uint256 rAfter,) = _lensQuoteBuyR();
        if (rAfter > baselineR) return; // candidate direction raised R as intended; keep the state
        vm.revertToState(id); // wrong way: discard and apply the opposite direction
        _runInterveningSwap(!ptIsCurrency0, int256(DRIFT_SWAP_AMOUNT));
    }

    /// @dev Moves the pool so the next buy quote returns a strictly smaller `R` than `baselineR`.
    function _moveBuyRLower(uint256 baselineR) internal {
        uint256 id = vm.snapshotState();
        _runInterveningSwap(!ptIsCurrency0, int256(DRIFT_SWAP_AMOUNT));
        (uint256 rAfter,) = _lensQuoteBuyR();
        if (rAfter < baselineR) return;
        vm.revertToState(id);
        _runInterveningSwap(ptIsCurrency0, -int256(DRIFT_SWAP_AMOUNT));
    }

    /// @dev Moves the pool so the next sell quote returns a strictly smaller `Q` than `baselineQ` (larger output).
    function _moveSellQLower(uint256 baselineQ) internal {
        uint256 id = vm.snapshotState();
        _runInterveningSwap(ptIsCurrency0, -int256(DRIFT_SWAP_AMOUNT));
        (, uint256 qAfter) = _lensQuoteSellQ();
        if (qAfter < baselineQ) return;
        vm.revertToState(id);
        _runInterveningSwap(!ptIsCurrency0, int256(DRIFT_SWAP_AMOUNT));
    }

    /// @dev Moves the pool so the next sell quote returns a strictly larger `Q` than `baselineQ` (smaller output).
    function _moveSellQHigher(uint256 baselineQ) internal {
        uint256 id = vm.snapshotState();
        _runInterveningSwap(!ptIsCurrency0, int256(DRIFT_SWAP_AMOUNT));
        (, uint256 qAfter) = _lensQuoteSellQ();
        if (qAfter > baselineQ) return;
        vm.revertToState(id);
        _runInterveningSwap(ptIsCurrency0, -int256(DRIFT_SWAP_AMOUNT));
    }

    /// @dev Maps a raw currency0/currency1 delta to (PT delta, POL delta) using the selected PT/POL sort order.
    function _mapDeltaToPTAndPOL(BalanceDelta delta, VersePool memory versePool)
        internal
        pure
        returns (int128 ptDelta, int128 polDelta)
    {
        if (versePool.ptIsCurrency0) {
            (ptDelta, polDelta) = (delta.amount0(), delta.amount1());
        } else {
            (ptDelta, polDelta) = (delta.amount1(), delta.amount0());
        }
    }

    /// @dev Recovers the flash swap delta from the observable Router return: buy returns `cost = y - R` so `R = y - cost`
    ///      and the swap delta is (-y PT, +R POL); sell returns `out = y - Q` so `Q = y - out` and the delta is
    ///      (+y PT, -Q POL).
    function _deriveFlashSwapDelta(MemeverseYTFlashSwapRouter.FlashAction action, uint256 y, uint256 result)
        internal
        pure
        returns (int128 ptDelta, int128 polDelta)
    {
        if (action == MemeverseYTFlashSwapRouter.FlashAction.Buy) {
            ptDelta = -int128(int256(y));
            polDelta = int128(int256(y - result)); // R = y - cost, guaranteed > 0 by InvalidBuyCost guard
        } else {
            ptDelta = int128(int256(y));
            polDelta = -int128(int256(y - result)); // Q = y - out, guaranteed > 0 by InvalidSellDebt guard
        }
    }

    /// @dev Captures the post-leg state the equivalence assertion compares. All fields are absolute post-state values;
    ///      because the ordinary and flash legs each start from the same snapshot baseline, absolute equality is exact.
    function _capturePostState(VersePool memory versePool, address ref, LegTrace memory trace) internal {
        (trace.slot0,,,) = manager.getSlot0(versePool.poolId);
        IDynamicFeeFacet.DynamicFeeState memory dfs = hook.dynamicFeeStateOf(versePool.poolId);
        trace.ewVwapX18 = dfs.ewVWAPX18;
        trace.weightedVolume0 = dfs.weightedVolume0;
        IDynamicFeeFacet.AddressBatchState memory abs = hook.addressBatchStateOf(address(account), versePool.poolId);
        trace.batchAccumPpm = abs.batchAccumPpm;
        trace.batchStartTs = abs.batchStartTs;
        trace.rebatePt = hook.pendingRebateOf(ref, Currency.wrap(versePool.pt));
        trace.rebatePol = hook.pendingRebateOf(ref, Currency.wrap(address(pol)));
        (, trace.fee0PerShare, trace.fee1PerShare) = hook.poolInfo(versePool.poolId);
    }

    /// @dev Reads only the `settled` flag from the Splitter's 11-field splitInfos getter.
    function _isSettled(uint256 verseId) internal view returns (bool settled) {
        (,,,,,,,,,, settled) = splitter.splitInfos(verseId);
    }

    /// @dev Post-leg observable state captured for ordinary-vs-flash equivalence comparison.
    struct LegTrace {
        int128 ptDelta;
        int128 polDelta;
        uint256 result; // Router return (polInUsed for buy, polOut for sell); unused for the ordinary leg
        uint160 slot0;
        uint256 ewVwapX18;
        uint256 weightedVolume0;
        uint192 batchAccumPpm;
        uint64 batchStartTs;
        uint256 rebatePt;
        uint256 rebatePol;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
    }
}

// =====================================================================================
// In-file helpers (FakeLauncher + OrdinarySwapSettler) — kept self-contained per the task contract.
// =====================================================================================

/// @title FakeLauncher
/// @notice Minimal `IMemeverseLauncher` subset used by the YT Flash Swap integration fixture: it advertises the
///         canonical hook+splitter pair, reports a mutable verse stage, and backs `POLSplitterUpgradeable.settle` with 1:1 uAsset.
/// @dev Production launcher methods not exercised here are intentionally absent. `redeemMemecoinLiquidity` mints uAsset
///      1:1 against the POL collateral so `POLSplitterUpgradeable.settle` accounting balances; it does NOT model real memecoin LP.
contract FakeLauncher {
    IMemeverseLauncher.Stage internal _stage = IMemeverseLauncher.Stage.Locked;
    address public immutable hookProxy;
    address public immutable polendAddr;
    MockERC20 public immutable uAsset;
    MockERC20 public immutable polToken;
    address public splitter;

    constructor(address hookProxy_, address polend_, MockERC20 uAsset_, MockERC20 polToken_) {
        hookProxy = hookProxy_;
        polendAddr = polend_;
        uAsset = uAsset_;
        polToken = polToken_;
    }

    function setSplitter(address splitter_) external {
        splitter = splitter_;
    }

    /// @notice Flips the reported stage to `Unlocked` so POLSplitterUpgradeable split/merge revert and settle becomes callable.
    function setUnlocked() external {
        _stage = IMemeverseLauncher.Stage.Unlocked;
    }

    /// @notice Restores the reported stage to `Locked` (used to isolate the settled guard from the stage guard).
    function setLocked() external {
        _stage = IMemeverseLauncher.Stage.Locked;
    }

    function getStageByVerseId(uint256) external view returns (IMemeverseLauncher.Stage) {
        return _stage;
    }

    function polend() external view returns (address) {
        return polendAddr;
    }

    function getLauncherContracts() external view returns (IMemeverseLauncher.LauncherContracts memory contracts) {
        contracts.memeverseUniswapHook = hookProxy;
        contracts.polSplitter = splitter;
    }

    /// @notice Minimal settle backing: pull the POL collateral the Splitter approved and mint 1:1 uAsset back so the
    ///         `settlementUAsset >= ptTotalSupply` invariant in `POLSplitterUpgradeable.settle` holds at a 1:1 backing ratio.
    function redeemMemecoinLiquidity(
        uint256,
        /* verseId */
        uint256 amountInPOL,
        bool,
        /* unwrap */
        uint256,
        uint256,
        uint256
    )
        external
        returns (uint256)
    {
        if (amountInPOL > 0) {
            require(polToken.transferFrom(msg.sender, address(this), amountInPOL));
            uAsset.mint(msg.sender, amountInPOL);
        }
        return 0;
    }
}

/// @title OrdinarySwapSettler
/// @notice No-trader single-account integrator that settles ONE ordinary PT/POL swap against the REAL v4 PoolManager.
/// @dev Mirrors `SessionSwapIntegrator` from MemeverseAccountSession.t.sol. It takes no trader parameter and implements
///      no `IMsgSender`: the hook attributes the swap solely to the active session principal. The payer is `msg.sender`
///      of `swap`; output is sent to `recipient`.
contract OrdinarySwapSettler is IUnlockCallback {
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

    /// @notice Swaps `params` on `key`, pulling input from `msg.sender` and sending output to `recipient`.
    /// @return delta The settled swap delta.
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

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        // Settle negative deltas (input owed): sync -> transferFrom -> settle credits the PoolManager.
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
