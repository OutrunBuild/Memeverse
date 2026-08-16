// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {RealisticSwapManagerHarness} from "../swap/helpers/RealisticSwapManagerHarness.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {POLendUpgradeable} from "../../src/polend/POLendUpgradeable.sol";
import {POLSplitterUpgradeable} from "../../src/polend/POLSplitterUpgradeable.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MockOFTDispatcher} from "../mocks/verse/LauncherLifecycleMocks.sol";
import {
    MockIntegrationLiquidProof,
    MockIntegrationMemecoin,
    MockLauncherIntegrationLzEndpointRegistry
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";
import {MockLauncherSwapIntegrationProxyDeployer} from "../mocks/verse/LauncherSwapIntegrationMocks.sol";
import {UniversalAssetForPOLendSettlementInvariant} from "../mocks/verse/LauncherSettlementMocks.sol";

/// @notice Drives the real-stack POLendUpgradeable global settlement path end-to-end.
/// @dev Unlike the preset-mock A-2/A-3 tests, this contract wires the real Uniswap v4 swap stack
///      (PoolManager + MemeverseUniswapHookUpgradeable + MemeverseSwapRouter) together with the real POLendUpgradeable
///      and POLSplitterUpgradeable, then drives changeStage Genesis -> Locked -> Unlocked so that
///      POLendUpgradeable.executeGlobalSettlement removes real auxiliary liquidity and repays debt on the
///      UniversalAsset. This is a class-A integration test: every contract in the settlement
///      call chain is a production artifact, only the periphery (registrar/registry/dispatcher/
///      proxyDeployer/uAsset) is mocked.
contract MemeverseLauncherPOLendSettlementIntegrationTest is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    using PoolIdLibrary for Currency;

    uint256 internal constant VERSE_ID = 1;
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant LEVERAGED_USER = address(0x1E4);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant ALICE = address(0xA11CE);

    // ── Real Uniswap v4 swap stack ──
    RealisticSwapManagerHarness internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseSwapRouter internal router;

    // ── Real Launcher proxy + production POLendUpgradeable/POLSplitterUpgradeable ──
    MemeverseLauncherUpgradeable internal launcher;
    address internal launcherProxy;
    POLendUpgradeable internal polend;
    POLSplitterUpgradeable internal splitter;

    // ── Mocked periphery only ──
    MockLauncherSwapIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    MockOFTDispatcher internal dispatcher;
    UniversalAssetForPOLendSettlementInvariant internal uAsset;

    function setUp() external {
        // 1. Real PoolManager.
        manager = new RealisticSwapManagerHarness();

        // 2. Periphery mocks.
        proxyDeployer = new MockLauncherSwapIntegrationProxyDeployer(address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        dispatcher = new MockOFTDispatcher();
        uAsset = new UniversalAssetForPOLendSettlementInvariant();

        // 3. Launcher proxy. POLendUpgradeable/Splitter slots are filled with placeholders here; real contracts
        //    are injected afterwards via setPolendForTest/setPolSplitterForTest so initialize() can run
        //    with non-zero addresses while the real POLendUpgradeable/Splitter can still be deployed with the
        //    correct launcher reference.
        address placeholderPolend = address(0x10);
        address placeholderSplitter = address(0x11);
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        address(this),
                        address(0x1111),
                        REGISTRAR,
                        address(0x3333),
                        address(0x4444),
                        address(registry),
                        placeholderPolend,
                        placeholderSplitter,
                        25,
                        115_000,
                        135_000,
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = MemeverseLauncherUpgradeable(launcherProxy);

        // 4. Real MemeverseUniswapHookUpgradeable + MemeverseSwapRouter. The hook is deployed behind a
        //    CREATE2-mined flag-address proxy via the shared helper (replaces the former Testable
        //    subclass that bypassed `_validateProxyHookAddress`). hookOwner = address(this),
        //    treasury = TREASURY.
        address hookProxy =
            deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), TREASURY, address(launcher));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0))
        );

        // 5. Real POLSplitterUpgradeable then real POLendUpgradeable. POLendUpgradeable's launcher reference is the Launcher proxy so
        //    registerLendMarket / finalizeLeveragedGenesis / executeGlobalSettlement pass onlyLauncher.
        POLSplitterUpgradeable splitterImpl = new POLSplitterUpgradeable();
        splitter = POLSplitterUpgradeable(
            address(
                new ERC1967Proxy(
                    address(splitterImpl),
                    abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), launcherProxy))
                )
            )
        );
        POLendUpgradeable polendImpl = new POLendUpgradeable();
        // interestRate = 0.1e18 (1e17), leveragedDebtFactor = 10e18: 1 ether interest -> 10 ether debt,
        // debtCap = debtFactor * max(normalFunds, minTotalFund) / 1e18 = 10 * 1 ether = 10 ether (exact).
        polend = POLendUpgradeable(
            address(
                new ERC1967Proxy(
                    address(polendImpl),
                    abi.encodeCall(
                        POLendUpgradeable.initialize,
                        (address(this), 0.1 ether, 10 ether, TREASURY, launcherProxy, address(splitter), address(this))
                    )
                )
            )
        );

        // 6. Inject real POLendUpgradeable/Splitter into Launcher proxy storage, then configure and seed settlement
        //    dust coverage so pure-leverage settlement can spend rounding dust without finalize refill.
        setPolendForTest(launcherProxy, address(polend));
        setPolSplitterForTest(launcherProxy, address(splitter));
        polend.setMaxSettlementDustReserve(address(uAsset), type(uint128).max);
        uAsset.mint(address(this), 1e6);
        uAsset.approve(address(polend), 1e6);
        polend.fundSettlementDustReserve(address(uAsset), 1e6);

        // 7. Hook wiring: the launcher is bound to the hook at deploy (initialize), so
        //    hook.launcher()==launcherProxy already holds. setMemeverseUniswapHook re-validates it
        //    while router is still zero (boundLauncher path); setMemeverseSwapRouter then re-validates
        //    router.hook()==hook && hook.launcher()==launcher && hook.poolInitializer()==router.
        hook.setPoolInitializer(address(router));

        // 8. Launcher wiring.
        launcher.setMemeverseUniswapHook(address(hook));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setYieldDispatcher(address(dispatcher));
        // minTotalFund = 1 ether so 1 ether of leveraged interest alone triggers flashGenesis Locked;
        // fundBasedAmount = 1 ether keeps main-pool memecoin provisioning 1:1 with uAsset.
        launcher.setFundMetaData(address(uAsset), 1 ether, 1);

        // 9. Register the verse with real memecoin/pol deployment via proxyDeployer and a real
        //    POLendUpgradeable.registerLendMarket call from the launcher.
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = uint32(block.chainid);
        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            VERSE_ID,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            omnichainIds,
            address(uAsset),
            true
        );

        // 10. Mark the freshly-deployed memecoin/pol/uAsset as fee currencies on the hook.
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.pol), true);
    }

    /// @dev Locks the verse by supplying 1 ether of leveraged interest through the real POLendUpgradeable, then
    ///      advancing the stage. finalizeLeveragedGenesis mints 10 ether of debt to the launcher and
    ///      _deployLiquidity creates the four real Uniswap v4 pools via the real router/hook.
    function _lockWithLeveragedLiquidity() internal {
        uAsset.mint(LEVERAGED_USER, 2 ether);
        vm.startPrank(LEVERAGED_USER);
        uAsset.approve(address(polend), 1 ether);
        polend.leveragedGenesis(VERSE_ID, 1 ether);
        vm.stopPrank();

        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "locked stage");
    }

    /// @notice Real-stack mintPOLToken conserves uAsset and memecoin across user/launcher/manager.
    /// @dev Unlike AssetFlowInvariant (line 636) which uses MockSwapRouter preset outputs (circular),
    ///      this drives mintPOLToken through the real MemeverseSwapRouter + Hook + PoolManager stack.
    ///      addLiquidity is swap-free so no protocol fee leaks; assets move user -> launcherProxy ->
    ///      PoolManager only. The conservation window covers exactly those three holders, captured
    ///      before and after mintPOLToken. POL is freshly minted and is not part of the conserved set.
    function test_A1_RealPathMintPOLTokenConservesUAssetAndMemecoin() external {
        _lockWithLeveragedLiquidity();

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);

        // Fund the minter with both legs. uAsset is the test UniversalAsset (mint); memecoin is the
        // real MockIntegrationMemecoin deployed by the launcher's proxyDeployer whose mint is
        // launcher-gated, so it is minted via the launcher proxy (the privileged minter).
        uAsset.mint(ALICE, 100 ether);
        vm.prank(launcherProxy);
        MockIntegrationMemecoin(verse.memecoin).mint(ALICE, 100 ether);

        uint128 desiredLiquidity = 1 ether;
        (uint256 uAssetBudget, uint256 memecoinBudget) =
            router.quoteExactAmountsForLiquidity(verse.uAsset, verse.memecoin, desiredLiquidity);

        // Conservation baseline across the three real mintPOLToken asset holders: payer, launcher proxy,
        // and the PoolManager. Real-stack addLiquidity parks assets in the manager, not in the router.
        uint256 uAssetBefore =
            uAsset.balanceOf(ALICE) + uAsset.balanceOf(launcherProxy) + uAsset.balanceOf(address(manager));
        uint256 memecoinBefore = IERC20(verse.memecoin).balanceOf(ALICE)
            + IERC20(verse.memecoin).balanceOf(launcherProxy) + IERC20(verse.memecoin).balanceOf(address(manager));
        uint256 polBefore = MockIntegrationLiquidProof(verse.pol).balanceOf(ALICE);

        vm.startPrank(ALICE);
        uAsset.approve(address(launcher), uAssetBudget);
        IERC20(verse.memecoin).approve(address(launcher), memecoinBudget);
        (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) =
            launcher.mintPOLToken(VERSE_ID, uAssetBudget, memecoinBudget, 0, 0, desiredLiquidity, block.timestamp);
        vm.stopPrank();

        // Exact-liquidity path mints the requested POL; the real router may round 1 wei of input
        // down (refunded to the minter), so the spent amounts are bounded by the quote, not equal.
        assertEq(amountOut, desiredLiquidity, "desired POL minted");
        assertLe(amountInUAsset, uAssetBudget, "uAsset spend bounded by quote");
        assertLe(amountInMemecoin, memecoinBudget, "memecoin spend bounded by quote");

        uint256 uAssetAfter =
            uAsset.balanceOf(ALICE) + uAsset.balanceOf(launcherProxy) + uAsset.balanceOf(address(manager));
        uint256 memecoinAfter = IERC20(verse.memecoin).balanceOf(ALICE)
            + IERC20(verse.memecoin).balanceOf(launcherProxy) + IERC20(verse.memecoin).balanceOf(address(manager));

        assertEq(uAssetAfter, uAssetBefore, "uAsset conserved across user/launcher/manager");
        assertEq(memecoinAfter, memecoinBefore, "memecoin conserved across user/launcher/manager");
        assertEq(
            MockIntegrationLiquidProof(verse.pol).balanceOf(ALICE), polBefore + desiredLiquidity, "POL minted to minter"
        );
    }

    /// @dev Warps past unlockTime and advances the stage. The Locked -> Unlocked transition triggers
    ///      POLSplitterUpgradeable.settle and, because leveraged debt is non-zero, POLendUpgradeable.executeGlobalSettlement,
    ///      which removes the auxiliary LPs and repays debt via UniversalAsset.repay.
    function _unlockAndSettle() internal {
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(uint256(verse.unlockTime) + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked stage");
    }

    /// @notice Real-stack POLendUpgradeable settlement burns leveraged debt and clears the per-uAsset global accounting.
    /// @dev Reproduce the A-2/A-3 attack path with no preset mocks: every settlement-relevant contract
    ///      (Launcher, POLendUpgradeable, POLSplitterUpgradeable, Hook, Router, PoolManager, UniversalAsset) is a production
    ///      artifact, so this test would fail if executeGlobalSettlement, settleLeveragedAuxiliaryLiquidity
    ///      or UniversalAsset.repay were ever short-circuited by a mock.
    function test_A3_RealPathSettlementRepaysDebtAndClearsGlobalAccounting() external {
        _lockWithLeveragedLiquidity();

        uint256 verseDebtBefore = polend.getTotalLeveragedDebt(VERSE_ID);
        assertGt(verseDebtBefore, 0, "leveraged debt minted");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), verseDebtBefore, "global debt tracked");

        uint256 repaidBefore = uAsset.repaidAmount();

        _unlockAndSettle();

        // Market transitions Genesis -> Locked -> Settled through the real executeGlobalSettlement path.
        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Settled), "market settled");

        // Global per-uAsset debt must be fully cleared: executeGlobalSettlement subtracts `debt` from
        // globalDebtByUAsset and repays the same amount on the UniversalAsset.
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");

        // The UniversalAsset must have recorded exactly the outstanding debt as repaid (burned).
        assertEq(uAsset.repaidAmount() - repaidBefore, verseDebtBefore, "debt repaid via UniversalAsset.repay");
    }

    /// @notice Each auxiliary LP consumed by settlement tracks the leveraged funding share
    ///         `FullMath.mulDiv(lp, totalLeveragedDebt, totalFunds)`, so a pure-leverage verse
    ///         (totalFunds == debt) consumes every auxiliary LP share.
    /// @dev Locking mints the three auxiliary LPs (pol/uAsset, pt/uAsset, pt/pol); the settle path
    ///      removes the leveraged share of each LP from real Uniswap v4 pools. Asserting the post-settle
    ///      residual against `mulDiv(lp0, debt, totalFunds)` ties the launcher's settle math to the real
    ///      remove-liquidity output.
    function test_A2_RealPathSettlementTokenDeltaMapping() external {
        _lockWithLeveragedLiquidity();

        (uint256 polUAssetLp0, uint256 ptUAssetLp0, uint256 ptPolLp0) = launcher.auxiliaryLiquidities(VERSE_ID);
        assertGt(polUAssetLp0, 0, "polUAsset LP minted");
        assertGt(ptUAssetLp0, 0, "ptUAsset LP minted");
        assertGt(ptPolLp0, 0, "ptPol LP minted");

        // Pure-leverage verse: totalNormalFunds == 0, so totalFunds collapses to totalLeveragedDebt
        // (see _checkedTotalGenesisFunds). The launcher therefore consumes the full LP share of each pool.
        uint256 totalLeveragedDebt = polend.getTotalLeveragedDebt(VERSE_ID);
        uint256 totalFunds = totalLeveragedDebt;
        assertEq(FullMath.mulDiv(polUAssetLp0, totalLeveragedDebt, totalFunds), polUAssetLp0, "polUAsset full share");

        // The real removeLiquidity drives the LP burn — no preset removeLiquidityResult. The
        // post-settle auxiliaryLiquidities residual asserts the delta came from the real PoolManager.

        _unlockAndSettle();

        (uint256 polUAssetLpAfter, uint256 ptUAssetLpAfter, uint256 ptPolLpAfter) =
            launcher.auxiliaryLiquidities(VERSE_ID);
        assertEq(
            polUAssetLpAfter,
            polUAssetLp0 - FullMath.mulDiv(polUAssetLp0, totalLeveragedDebt, totalFunds),
            "polUAsset delta"
        );
        assertEq(
            ptUAssetLpAfter,
            ptUAssetLp0 - FullMath.mulDiv(ptUAssetLp0, totalLeveragedDebt, totalFunds),
            "ptUAsset delta"
        );
        assertEq(ptPolLpAfter, ptPolLp0 - FullMath.mulDiv(ptPolLp0, totalLeveragedDebt, totalFunds), "ptPol delta");
    }

    /// @notice A pure-leverage verse (no normal genesis) has totalFunds == totalLeveragedDebt, so the
    ///         leveraged share ratio is 1: every auxiliary LP share is removed and the residual is zero.
    function test_A2_RealPathPureLeveragedConsumesAllAuxiliaryLp() external {
        _lockWithLeveragedLiquidity();

        (uint256 polUAssetLp0, uint256 ptUAssetLp0, uint256 ptPolLp0) = launcher.auxiliaryLiquidities(VERSE_ID);
        assertGt(polUAssetLp0, 0, "polUAsset LP minted");
        assertGt(ptUAssetLp0, 0, "ptUAsset LP minted");
        assertGt(ptPolLp0, 0, "ptPol LP minted");

        _unlockAndSettle();

        (uint256 polUAssetLpAfter, uint256 ptUAssetLpAfter, uint256 ptPolLpAfter) =
            launcher.auxiliaryLiquidities(VERSE_ID);
        assertEq(polUAssetLpAfter, 0, "polUAsset LP fully consumed");
        assertEq(ptUAssetLpAfter, 0, "ptUAsset LP fully consumed");
        assertEq(ptPolLpAfter, 0, "ptPol LP fully consumed");
    }

    /// @notice After the Locked->Unlocked settle, the splitter's residual `settlementUAsset` must still
    ///         cover the backing of every outstanding PT. The settle() invariant guarantees this at
    ///         write-time (`settlementUAsset >= _ptToUAsset(pt.totalSupply())`); redeemPT called by
    ///         executeGlobalSettlement then burns the leveraged PT and decreases settlementUAsset in lock
    ///         step, so the post-settlement residual must still satisfy the same inequality.
    function test_A3_RealPathSettlementPTBackingAlwaysCoveredAfterRedeem() external {
        _lockWithLeveragedLiquidity();
        _unlockAndSettle();

        (,,,,,, uint256 settlementUAsset,,,,) = splitter.splitInfos(VERSE_ID);
        address pt = splitter.getPT(VERSE_ID);
        uint256 ptSupply = IERC20(pt).totalSupply();
        uint256 requiredBacking = splitter.previewPTToUAsset(VERSE_ID, ptSupply);

        assertGe(settlementUAsset, requiredBacking, "PT backing covered after redeem");
    }

    /// @notice Verifies the mock PoolManager settle/take fix: a pol->uAsset swap settles the
    ///         verse without the take() panic (0x11) that previously occurred.
    /// @dev Before the fix, RealisticSwapManagerHarness.settle() only settled msg.sender's delta,
    ///      not all deltas for the currency.  The hook's pol fee (accumulated virtually via
    ///      _accountPoolBalanceDelta during beforeSwap) was never backed by a real transfer, so
    ///      the hook's later take(pol, ...) panicked with insufficient balance.  The fix makes
    ///      settle() settle all deltas at once (real PoolManager semantics), so the caller's
    ///      payment backs the hook's fee and take() succeeds.
    ///
    ///      This test drives the real stack (Launcher + POLendUpgradeable + POLSplitterUpgradeable + Hook + Router +
    ///      PoolManager) through a pol->uAsset swap and the Locked->Unlocked settlement.
    ///
    ///      NOTE on the dust deficit path: a pol->uAsset swap does NOT trigger a dust deficit
    ///      (recoveredUAsset < debt).  Empirically it produces a SURPLUS — moving pol into the
    ///      pol/uAsset pool inflates polAmount, and that pol is burned via redeemMemecoinLiquidity
    ///      into more uAsset than the swap drained.  The memecoin->uAsset direction is blocked by
    ///      POLSplitterUpgradeable.settle()'s safety invariant (settlementUAsset >= ptBacking, with zero
    ///      margin).  The dust-deficit branch is covered by the preset-mock A-3 tests, which
    ///      control LP-removal outputs directly.  This integration test targets the mock fix.
    function test_A3_RealPathSettlementDustCoversDeficitUnderReserveCap() external {
        _lockWithLeveragedLiquidity();

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        address swapper = address(0xABCD);

        // pol->uAsset swap: the operation that previously panicked at the hook's beforeSwap
        // take(pol).  With the mock settle() fix, the swap succeeds and settlement completes.
        vm.prank(launcherProxy);
        MockIntegrationLiquidProof(verse.pol).mint(swapper, 0.5 ether);
        _swapExactInput(swapper, verse.pol, address(uAsset), 0.5 ether);

        // The swap inflates polAmount past the launcher's memecoin/uAsset LP balance (4e18),
        // which would make redeemMemecoinLiquidity revert with InsufficientLPBalance.  Mint a
        // small amount of POL to grow the launcher's LP so settlement can proceed.
        address minter = address(0xB0B);
        uAsset.mint(minter, 100 ether);
        vm.prank(launcherProxy);
        MockIntegrationMemecoin(verse.memecoin).mint(minter, 100 ether);
        vm.startPrank(minter);
        uAsset.approve(address(launcher), 100 ether);
        IERC20(verse.memecoin).approve(address(launcher), 100 ether);
        launcher.mintPOLToken(VERSE_ID, 100 ether, 100 ether, 0, 0, 1 ether, block.timestamp);
        vm.stopPrank();

        uint256 debt = polend.getTotalLeveragedDebt(VERSE_ID);
        uint256 repaidBefore = uAsset.repaidAmount();

        _unlockAndSettle();

        assertEq(
            uint256(polend.getLendMarket(VERSE_ID).state),
            uint256(IPOLend.MarketState.Settled),
            "market settled after pol->uAsset swap"
        );
        assertEq(uAsset.repaidAmount() - repaidBefore, debt, "full debt repaid after pol->uAsset swap");
    }

    /// @dev Swaps an exact input amount through the real router. Funds the trader with tokenIn via the
    ///      test (caller mints); the router pulls tokenIn from the trader, so the trader must approve.
    function _swapExactInput(address trader, address tokenIn, address tokenOut, uint256 amountIn) internal {
        PoolKey memory key = router.getHookPoolKey(tokenIn, tokenOut);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Open the session as the test contract (which has code) before pranking the trader: beginAccountSession
        // rejects bare EOAs, and `trader` here is a no-code address. The session principal is this contract,
        // independent of the pranked swap caller; the router still pulls `tokenIn` from `trader`.
        hook.beginAccountSession();
        vm.startPrank(trader);
        // UniversalAsset is a test asset with a 1:1 approve helper; ERC20 approve works for any token here.
        IERC20(tokenIn).approve(address(router), amountIn);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            trader,
            block.timestamp,
            0,
            amountIn,
            ""
        );
        vm.stopPrank();
        hook.endAccountSession();
    }
}
