// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLiquidityImpl} from "../../src/verse/MemeverseLiquidityImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {POLSplitterInvariantStub} from "../mocks/verse/LauncherInvariantStubs.sol";
import {ConfigurableDebtPOLendStub} from "../mocks/verse/FundraisingBoundaryMocks.sol";
import {MemeverseUniswapHookUpgradeable} from "../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {
    MockLauncherIntegrationLzEndpointRegistry,
    MockLauncherIntegrationProxyDeployer
} from "../mocks/verse/LauncherPreorderIntegrationMocks.sol";
import {MockPoolManagerForRouterTest} from "../mocks/swap/SwapRouterMocks.sol";

/// @title MemeverseLauncherFundraisingBoundaryTest
/// @notice Genesis-cap and preorder-capacity boundary properties.
/// @dev Wiring mirrors MemeverseLauncherPreorderInvariant.t.sol's proven setUp
///      (full launcher stack + registered verse in Stage.Genesis); the only delta is
///      the POLend stub, whose leveraged debt is runtime-configurable so the combined
///      cap normalFunds + debt can be driven to exactly 2^128 - 1.
contract MemeverseLauncherFundraisingBoundaryTest is Test, MemeverseLauncherTestHelper, HookStorageHelper {
    address internal constant REGISTRAR = address(0xBEEF);
    uint32 internal constant REMOTE_GOV_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;
    uint256 internal constant VERSE_ID = 1;
    address internal constant ALICE = address(0xA11CE);
    uint256 internal constant GENESIS_CAP = type(uint128).max; // MAX_SUPPORTED_TOTAL_GENESIS_FUNDS

    MockPoolManagerForRouterTest internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseSwapRouter internal router;
    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockLauncherIntegrationProxyDeployer internal proxyDeployer;
    MockLauncherIntegrationLzEndpointRegistry internal registry;
    ConfigurableDebtPOLendStub internal polend;
    POLSplitterInvariantStub internal splitter;
    MockERC20 internal uAsset;
    MockERC20 internal pt;
    MockERC20 internal yt;

    function setUp() external {
        manager = new MockPoolManagerForRouterTest();
        proxyDeployer = new MockLauncherIntegrationProxyDeployer(address(0xD00D), address(0xCAFE), address(0xF00D));
        registry = new MockLauncherIntegrationLzEndpointRegistry();
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        pt = new MockERC20("PT", "PT", 18);
        yt = new MockERC20("YT", "YT", 18);
        polend = new ConfigurableDebtPOLendStub();
        splitter = new POLSplitterInvariantStub(address(pt), address(yt));
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
                        address(polend),
                        address(splitter),
                        25,
                        115_000,
                        135_000,
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = IMemeverseLauncher(launcherProxy);
        address hookProxy =
            deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), address(this), address(launcher));
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)),
            IMemeverseUniswapHook(address(hook)),
            new MemeverseUniswapHookLens(IPoolManager(address(manager))),
            IPermit2(address(0xBEEF))
        );
        hook.setPoolInitializer(address(router));

        launcher.setMemeverseUniswapHook(address(router.hook()));
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        launcher.setFeePreviewReader(address(new MemeverseFeePreviewReader(address(launcher))));
        launcher.setLiquidityImpl(address(new MemeverseLiquidityImpl()));
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setFundMetaData(address(uAsset), 10 ether, 4);
        polend.setLendMarket(address(pt), address(yt));

        registry.setEndpoint(REMOTE_GOV_CHAIN_ID, REMOTE_EID);
        _registerVerse();

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(VERSE_ID);
        hook.setProtocolFeeCurrency(Currency.wrap(address(uAsset)), true);
        hook.setProtocolFeeCurrency(Currency.wrap(verse.memecoin), true);

        // Cap-and-preorder-scale funding: genesis can consume a full cap, and the
        // full-capacity preorder adds up to 0.7 * (base + debt) on top.
        uAsset.mint(ALICE, 2 * GENESIS_CAP);
        vm.prank(ALICE);
        uAsset.approve(address(launcher), type(uint256).max);
    }

    /// @notice D1: the combined genesis cap is exact and atomic. For any debt
    ///         level, deposits filling the remaining headroom land the combined total
    ///         at exactly 2^128 - 1; one wei more reverts TotalGenesisFundsTooHigh
    ///         leaving state unchanged; remainingGenesisCapacity agrees throughout.
    function testFuzz_GenesisCapBoundary(uint256 debtSeed, uint256 firstSeed) external {
        assertEq(uint8(launcher.getStageByVerseId(VERSE_ID)), uint8(IMemeverseLauncher.Stage.Genesis), "stage");

        uint256 debt = bound(debtSeed, 0, GENESIS_CAP - 1);
        polend.setTotalLeveragedDebt(debt);
        uint256 remaining = GENESIS_CAP - debt;

        // Optional first deposit (0 explores the single-shot fill variant).
        uint256 first = bound(firstSeed, 0, remaining);
        if (first != 0) {
            vm.prank(ALICE);
            launcher.genesis(VERSE_ID, first, ALICE);
        }
        assertEq(launcher.totalNormalFunds(VERSE_ID), first, "first leg booked wrong");
        assertEq(launcher.remainingGenesisCapacity(VERSE_ID), remaining - first, "capacity view mismatch");

        // Fill the remaining headroom: combined lands exactly at the cap.
        if (remaining - first != 0) {
            vm.prank(ALICE);
            launcher.genesis(VERSE_ID, remaining - first, ALICE);
        }
        assertEq(launcher.totalNormalFunds(VERSE_ID) + debt, GENESIS_CAP, "combined must land exactly at cap");
        assertEq(launcher.remainingGenesisCapacity(VERSE_ID), 0, "capacity must be exhausted");

        // One wei more must revert atomically (state unchanged).
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseLauncher.TotalGenesisFundsTooHigh.selector, uint256(GENESIS_CAP) + 1, GENESIS_CAP
            )
        );
        launcher.genesis(VERSE_ID, 1, ALICE);
        assertEq(launcher.totalNormalFunds(VERSE_ID), remaining, "revert must not change state");
    }

    /// @notice D2: a single user's cumulative GenesisData.genesisFund (uint128)
    ///         accumulates without truncation up to the cap. The aggregate cap bounds
    ///         every user's cumulative total below 2^128, so two-part deposits must
    ///         sum exactly (equality, not <=).
    function testFuzz_GenesisUserFundUint128NoTruncation(uint256 debtSeed, uint256 splitSeed) external {
        uint256 debt = bound(debtSeed, 0, GENESIS_CAP / 2);
        polend.setTotalLeveragedDebt(debt);
        uint256 target = GENESIS_CAP - debt; // >= 2^127 (debt <= floor(cap/2) = 2^127 - 1)
        uint256 first = bound(splitSeed, 1, target - 1); // force two accumulating deposits

        vm.prank(ALICE);
        launcher.genesis(VERSE_ID, first, ALICE);
        vm.prank(ALICE);
        launcher.genesis(VERSE_ID, target - first, ALICE);

        (uint256 genesisFund,,) = MemeverseLauncherUpgradeable(launcherProxy).userGenesisData(VERSE_ID, ALICE);
        assertEq(genesisFund, target, "D2: uint128 accumulation truncated");
        assertEq(launcher.totalNormalFunds(VERSE_ID), target, "D2: aggregate mismatch");
    }

    /// @notice D3: the facade capacity view equals the lib oracle for any base and
    ///         any validated ratio, stays within 70% of the base, and the enforcement
    ///         path agrees exactly: preordering the full capacity succeeds and drains
    ///         the view to 0, one wei more reverts InvalidLength.
    function testFuzz_PreorderCapacityOracle(uint256 baseSeed, uint16 ratioSeed, uint256 debtSeed) external {
        uint256 ratio = bound(ratioSeed, 1, 10_000);
        launcher.setPreorderConfig(ratio, 7 days);
        uint256 debt = bound(debtSeed, 0, GENESIS_CAP / 2);
        polend.setTotalLeveragedDebt(debt);
        uint256 base = bound(baseSeed, 0, GENESIS_CAP - debt);
        if (base != 0) {
            vm.prank(ALICE);
            launcher.genesis(VERSE_ID, base, ALICE);
        }

        // Oracle: MemeverseLauncherLib.preorderMaxCapacity formula, computed here
        // independently (FullMath) from the same inputs the facade reads.
        uint256 expected = FullMath.mulDiv(base + debt, 7 * ratio, 10 * 10_000);
        assertEq(launcher.previewPreorderCapacity(VERSE_ID), expected, "D3: facade view != oracle");
        assertLe(expected * 10, (base + debt) * 7, "D3: capacity above 70% of base");
        if (ratio == 10_000) {
            // At the max ratio the capacity is exactly floor(0.7 * base): the cross-
            // multiplied gap is the floor remainder, strictly below 10.
            assertLt((base + debt) * 7 - expected * 10, 10, "D3: ratio=10^4 must sit at floor(0.7*base)");
        }

        // Enforcement agreement: full-capacity preorder succeeds, view drains to 0,
        // and one wei more reverts InvalidLength (state unchanged).
        if (expected != 0) {
            vm.prank(ALICE);
            launcher.preorder(VERSE_ID, expected, ALICE);
            assertEq(launcher.previewPreorderCapacity(VERSE_ID), 0, "D3: view must drain to 0");
            (uint256 preorderFunds,,) = getPreorderStateForTest(launcherProxy, VERSE_ID);
            assertEq(preorderFunds, expected, "D3: preorder funds mismatch");

            vm.prank(ALICE);
            vm.expectRevert(IMemeverseLauncher.InvalidLength.selector);
            launcher.preorder(VERSE_ID, 1, ALICE);
            (preorderFunds,,) = getPreorderStateForTest(launcherProxy, VERSE_ID);
            assertEq(preorderFunds, expected, "D3: revert must not change state");
        }
    }

    function _registerVerse() internal {
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = REMOTE_GOV_CHAIN_ID;

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            VERSE_ID,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 30 days),
            omnichainIds,
            address(uAsset),
            false
        );
    }
}
