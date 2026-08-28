// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

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
import {LzEndpointRegistryMock} from "../mocks/common/LzEndpointRegistryMock.sol";
import {MockLauncherSwapIntegrationProxyDeployer} from "../mocks/verse/LauncherSwapIntegrationMocks.sol";
import {UniversalAssetForPOLendSettlementInvariant} from "../mocks/verse/LauncherSettlementMocks.sol";
import {BurnableMockERC20} from "../mocks/polend/POLendMocks.sol";
import {MockGenesisCreditFactory} from "../mocks/credit/MockGenesisCreditFactory.sol";

/// @notice Probes the "triple-absent" verse: NO normal genesis funds, NO preorder, and leveraged
///         genesis funded ENTIRELY via GenesisCredit. Drives the REAL swap stack (PoolManager + Hook +
///         Router) + real POLendUpgradeable/POLSplitterUpgradeable all the way Genesis -> Locked -> Unlocked so that
///         POLSplitterUpgradeable.settle() and POLendUpgradeable.executeGlobalSettlement() run against genuine LP removal /
///         PT redemption, exposing any dust-gap revert that preset-mock tests cannot reach.
///
/// @dev This isolates reserve underfunding after removing interest auto-refill. With credit-only
///      leverage and no normal funds, finalize contributes no real-uAsset interest to the reserve;
///      the only automatic reserve seed is the bootstrap deployment residual. That residual under-covers
///      the settlement-side LP-removal/PT-redeem rounding deficit by ~1 wei, so `executeGlobalSettlement`
///      reverts `SettlementDustInsufficient`. `POLSplitterUpgradeable.settle()` is expected to pass; the failure is
///      POLendUpgradeable reserve coverage. (Exact wei magnitudes are v4 rounding artifacts — see the selector-only
///      expectPartialRevert in the test body, which deliberately avoids pinning them.)
contract MemeverseLauncherTripleAbsentSettlementTest is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    using PoolIdLibrary for Currency;

    uint256 internal constant VERSE_ID = 1;
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant LEVERAGED_USER = address(0x1E4);
    address internal constant TREASURY = address(0x7EA5);

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
    LzEndpointRegistryMock internal registry;
    MockOFTDispatcher internal dispatcher;
    UniversalAssetForPOLendSettlementInvariant internal uAsset;

    // ── Credit path (the only leveraged entry in the triple-absent verse) ──
    BurnableMockERC20 internal credit;
    MockGenesisCreditFactory internal creditFactory;

    function setUp() external {
        // 1. Real PoolManager.
        manager = new RealisticSwapManagerHarness();

        // 2. Periphery mocks.
        proxyDeployer = new MockLauncherSwapIntegrationProxyDeployer(address(0xCAFE), address(0xF00D));
        registry = new LzEndpointRegistryMock();
        dispatcher = new MockOFTDispatcher();
        uAsset = new UniversalAssetForPOLendSettlementInvariant();

        // 3. Launcher proxy with placeholder POLendUpgradeable/Splitter (real ones injected afterwards).
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

        // 4. Real Hook + Router.
        address hookProxy =
            deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), TREASURY, address(launcher));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0))
        );

        // 5. Credit token + factory wired to the verse uAsset. creditOf(uAsset) resolves to `credit`.
        credit = new BurnableMockERC20("CREDIT", "CREDIT");
        creditFactory = new MockGenesisCreditFactory();
        creditFactory.setCreditOf(address(uAsset), address(credit));

        // 6. Real POLSplitterUpgradeable then real POLendUpgradeable. POLendUpgradeable's creditFactory now points at the real factory
        //    (not the address(this) placeholder used by the non-credit settlement integration test).
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
        // interestRate = 0.1e18, leveragedDebtFactor = 10e18: 1 ether credit interest -> 10 ether debt,
        // which lands exactly on the debt cap (capBase collapses to minTotalFund = 1 ether at zero normal
        // funds, cap = 10 * 1 ether). Strict `>` gate accepts the equality.
        polend = POLendUpgradeable(
            address(
                new ERC1967Proxy(
                    address(polendImpl),
                    abi.encodeCall(
                        POLendUpgradeable.initialize,
                        (
                            address(this),
                            0.1 ether,
                            10 ether,
                            TREASURY,
                            launcherProxy,
                            address(splitter),
                            address(creditFactory)
                        )
                    )
                )
            )
        );

        // 7. Inject real POLendUpgradeable/Splitter into Launcher proxy storage and allow unlimited dust reserve.
        setPolendForTest(launcherProxy, address(polend));
        setPolSplitterForTest(launcherProxy, address(splitter));
        polend.setMaxSettlementDustReserve(address(uAsset), type(uint128).max);

        // 8. Launcher is bound to the hook at deploy (initialize); wire the pool initializer here.
        hook.setPoolInitializer(address(router));
        launcher.setMemeverseUniswapHook(address(hook));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setYieldDispatcher(address(dispatcher));
        // minTotalFund = 1 ether so 1 ether of credit interest alone clears the flashGenesis launch gate;
        // fundBasedAmount = 1 keeps main-pool memecoin provisioning 1:1 with uAsset.
        launcher.setFundMetaData(address(uAsset), 1 ether, 1);

        // 9. Register the verse. preorder() is NEVER called, so preorderState.totalFunds stays 0.
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = uint32(block.chainid);
        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "TripleAbsent",
            "3NONE",
            VERSE_ID,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            omnichainIds,
            address(uAsset),
            true
        );

        // 10. Fee currencies on the hook.
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.pol), true);
    }

    /// @dev Locks the verse by supplying 1 ether of GenesisCredit through the real POLendUpgradeable, then
    ///      advancing the stage. No normal genesis() and no preorder() are ever called. finalize (run
    ///      inside the Genesis->Locked transition) mints 10 ether of uAsset debt to the launcher, burns
    ///      the escrowed credit, and — because realInterest == 0 — credits NOTHING to the dust reserve
    ///      from interest. The only reserve funding is the bootstrap deployment residual.
    function _lockWithCreditOnly() internal {
        credit.mint(LEVERAGED_USER, 1 ether);
        vm.startPrank(LEVERAGED_USER);
        credit.approve(address(polend), 1 ether);
        polend.leveragedGenesisWithCredit(VERSE_ID, 1 ether);
        vm.stopPrank();

        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Locked), "locked stage");
    }

    /// @dev Warps past unlockTime and advances the stage. The Locked -> Unlocked transition triggers
    ///      POLSplitterUpgradeable.settle and, because leveraged debt is non-zero, POLendUpgradeable.executeGlobalSettlement.
    function _unlockAndSettle() internal {
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(uint256(verse.unlockTime) + 1);
        assertEq(uint256(launcher.changeStage(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Unlocked), "unlocked stage");
    }

    /// @notice Triple-absent verse (no normal funds, no preorder, credit-only leverage) driven through
    ///         real-stack settlement. Logs the reserve / debt magnitudes after lock so the bootstrap
    ///         residual and any settlement gap are observable in the trace.
    ///
    /// @dev If POLSplitterUpgradeable.settle() reverts, the failure reason is `InvalidClaim` from the PT-backing
    ///      invariant (settlementUAsset < _ptToUAsset(pt.totalSupply())) — zero preorder surplus means
    ///      no margin against LP-removal rounding. If POLendUpgradeable.executeGlobalSettlement() reverts, the
    ///      reason is `SettlementDustInsufficient` — the bootstrap residual was too small to cover the
    ///      settlement-side rounding. If neither reverts, the triple-absent scenario is safe by
    ///      construction and the earlier concern was overcautious.
    function test_TripleAbsent_CreditOnlyRealStackSettlement() external {
        _lockWithCreditOnly();

        // ── Confirm the triple-absent invariants ──
        assertEq(launcher.totalNormalFunds(VERSE_ID), 0, "no normal funds");
        assertEq(polend.getTotalCreditInterest(VERSE_ID), 1 ether, "all interest is credit");
        assertEq(polend.getTotalLeveragedInterest(VERSE_ID), 1 ether, "aggregate interest == credit");

        uint256 debt = polend.getTotalLeveragedDebt(VERSE_ID);
        (uint128 reserveBefore, uint128 maxReserve) = polend.settlementDustStates(address(uAsset));
        console.log("debt (uAsset minted to launcher):", debt);
        console.log("dust reserve after finalize (bootstrap residual R):", uint256(reserveBefore));
        console.log("dust maxReserve:", uint256(maxReserve));

        // ── Probe result (observed empirically): the bootstrap residual alone under-covers the
        //    settlement deficit by 1 wei. realInterest == 0 (credit-only) so finalize credits no
        //    interest to the reserve; normalFunds == 0 so there is no normal-share surplus either.
        //    The settlement-side LP-removal / PT-redeem rounding is therefore uncovered, and
        //    executeGlobalSettlement reverts SettlementDustInsufficient. POLSplitterUpgradeable.settle() passes;
        //    the only revert is in POLendUpgradeable.executeGlobalSettlement.
        // Inline the unlock so vm.expectPartialRevert sits immediately before the changeStage external call
        // (placing it before _unlockAndSettle() would consume the view getter getMemeverseByVerseId).
        // Selector-only match via expectPartialRevert: the invariant under test is "settlement reverts
        // when reserve < deficit". The exact (deficit, reserve) wei values are v4 LP-removal rounding
        // artifacts and would brittle-pin the test to specific compiler/v4 versions; matching only the
        // error selector keeps the test robust to 1-wei rounding drift while still proving the
        // reserve-underfunding revert.
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        vm.warp(uint256(verse.unlockTime) + 1);
        vm.expectPartialRevert(IPOLend.SettlementDustInsufficient.selector);
        launcher.changeStage(VERSE_ID);
    }

    /// @notice Same triple-absent verse but with a manual dust top-up before settlement, confirming the
    ///         operational remedy (fundSettlementDustReserve) unblocks settlement.
    /// @dev Runs unconditionally alongside the bare-revert test so both the failure and its remedy are
    ///      observed in the same suite.
    function test_TripleAbsent_WithManualDustTopUp_Settles() external {
        _lockWithCreditOnly();

        // Manually fund a modest dust buffer before settlement (1e6 uAsset, well within maxReserve).
        uAsset.mint(address(this), 1e6);
        uAsset.approve(address(polend), 1e6);
        polend.fundSettlementDustReserve(address(uAsset), 1e6);

        (uint128 reserveBefore,) = polend.settlementDustStates(address(uAsset));
        console.log("reserve after manual top-up:", uint256(reserveBefore));

        _unlockAndSettle();

        assertEq(uint256(polend.getLendMarket(VERSE_ID).state), uint256(IPOLend.MarketState.Settled), "settled");
        assertEq(polend.getTotalDebtByUAsset(address(uAsset)), 0, "global debt cleared");
    }
}
