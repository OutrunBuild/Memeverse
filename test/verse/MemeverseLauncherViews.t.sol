// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {MemeverseSettlementImpl} from "../../src/verse/MemeverseSettlementImpl.sol";
import {MemeverseFeePreviewReader} from "../../src/verse/MemeverseFeePreviewReader.sol";
import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseFeePreviewReader} from "../../src/verse/interfaces/IMemeverseFeePreviewReader.sol";
import {IPOLend} from "../../src/polend/interfaces/IPOLend.sol";

contract MockPOLendForViews {
    uint256 internal totalLeveragedDebt_;
    IPOLend.LendMarket internal market;

    function setTotalLeveragedDebt(uint256 amount) external {
        totalLeveragedDebt_ = amount;
    }

    function getTotalLeveragedDebt(uint256) external view returns (uint256) {
        return totalLeveragedDebt_;
    }

    function getLendMarket(uint256) external view returns (IPOLend.LendMarket memory) {
        return market;
    }

    function registerLendMarket(uint256) external {}
}

contract MockPOLSplitterForViews {
    address internal immutable yt;

    constructor(address yt_) {
        yt = yt_;
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (address(0), yt, address(0), address(0), address(0), 0, 0, 0, 0, 0, false);
    }

    function getPT(uint256) external pure returns (address) {
        return address(0);
    }

    function getYT(uint256) external view returns (address) {
        return yt;
    }

    function getMemecoin(uint256) external pure returns (address) {
        return address(0);
    }

    function getPTAndYT(uint256) external view returns (address, address) {
        return (address(0), yt);
    }

    function getPTSettlementState(uint256) external pure returns (address, bool) {
        return (address(0), false);
    }
}

contract MemeverseLauncherViewsTest is Test, MemeverseLauncherTestHelper {
    address internal constant REGISTRAR = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MEMECOIN = address(0x1111);
    address internal constant GOVERNOR = address(0x3333);
    address internal constant YIELD_VAULT = address(0x4444);
    address internal constant POL = address(0x5555);
    uint256 internal constant MAX_SUPPORTED_FUND_BASED_AMOUNT = (1 << 64) - 1;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    IMemeverseFeePreviewReader internal feePreviewReader;
    /// @notice Pure proxy (implementation = MemeverseLauncherUpgradeable without *ForTest helpers)
    ///         for selector/ABI surface validation independent of test-only state helpers.
    address internal pureLauncher;
    /// @notice The pure implementation behind `pureLauncher`; the runtime-selector scan reads this
    ///         contract's bytecode (a proxy's runtime has no function dispatch table to scan).
    address internal pureImplementation;
    MockERC20 internal uAssetToken;
    MockERC20 internal ytToken;
    MockPOLendForViews internal polend;
    MockPOLSplitterForViews internal splitter;

    /// @notice Set up.
    /// @dev Deploys the views-only launcher and a helper token to exercise getters.
    function setUp() external {
        uAssetToken = new MockERC20("UASSET", "UASSET", 18);
        ytToken = new MockERC20("YT", "YT", 18);
        polend = new MockPOLendForViews();
        splitter = new MockPOLSplitterForViews(address(ytToken));
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        address(this),
                        address(0x1),
                        REGISTRAR,
                        address(0x3),
                        address(0x4),
                        address(0x5),
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
        // Phase 4B: refund/claimNormalYT/claimUnlockedPreorderMemecoin delegatecall the settlement sibling,
        // so wire it for the views suite just as the proxy owner would in production.
        launcher.setSettlementImpl(address(new MemeverseSettlementImpl()));
        // Phase 3B: genesis/preorder delegatecall the launch sibling; bind it for the genesis/preorder view tests.
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        feePreviewReader = new MemeverseFeePreviewReader(launcherProxy);

        // Deploy a pure proxy (implementation = pure MemeverseLauncherUpgradeable, no *ForTest helpers)
        // for selector / ABI surface validation.
        MemeverseLauncherUpgradeable pureImpl = new MemeverseLauncherUpgradeable();
        pureImplementation = address(pureImpl);
        pureLauncher = address(
            new ERC1967Proxy(
                address(pureImpl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        address(this),
                        address(0x1),
                        REGISTRAR,
                        address(0x3),
                        address(0x4),
                        address(0x5),
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
    }

    /// @notice Builds a base verse for the requested stage.
    /// @dev Supplies consistent memecoin and uAsset addresses for view tests.
    function _baseVerse(IMemeverseLauncher.Stage stage)
        internal
        view
        returns (IMemeverseLauncher.Memeverse memory verse)
    {
        verse.memecoin = MEMECOIN;
        verse.uAsset = address(uAssetToken);
        verse.currentStage = stage;
    }

    /// @notice Write a Memeverse struct to proxy storage via the helper.
    /// @dev Destructures the struct into individual fields for setMemeverseForTest.
    function _setVerse(uint256 verseId, IMemeverseLauncher.Memeverse memory verse) internal {
        setMemeverseForTest(
            launcherProxy,
            verseId,
            verse.uAsset,
            verse.memecoin,
            verse.pol,
            verse.yieldVault,
            verse.governor,
            verse.incentivizer,
            verse.endTime,
            verse.unlockTime,
            verse.currentStage,
            verse.flashGenesis
        );
    }

    function _expectedDefaultPreorderCapacity(uint256 baseFunds) internal pure returns (uint256) {
        uint256 quotient = baseFunds / 40;
        uint256 remainder = baseFunds % 40;
        return quotient * 7 + remainder * 7 / 40;
    }

    function _expectedLauncherSelectorSignatures() internal pure returns (string[] memory signatures) {
        signatures = new string[](70);
        signatures[0] = "BPS_BASE()";
        signatures[1] = "auxiliaryLiquidities(uint256)";
        signatures[2] = "bootstrapResidualClaims(uint256)";
        signatures[3] = "changeStage(uint256)";
        signatures[4] = "claimNormalFees(uint256)";
        signatures[5] = "claimNormalYT(uint256)";
        signatures[6] = "claimUnlockedPreorderMemecoin(uint256)";
        signatures[7] = "claimablePreorderMemecoin(uint256)";
        signatures[8] = "communitiesMap(uint256,uint256)";
        signatures[9] = "fundMetaDatas(address)";
        signatures[10] = "genesis(uint256,uint256,address)";
        signatures[11] = "genesisAndPreorder(uint256,uint256,uint256,address)";
        signatures[12] = "getDebtCapBaseByVerseId(uint256)";
        signatures[13] = "getGovernorByVerseId(uint256)";
        signatures[14] = "getLauncherContracts()";
        signatures[15] = "getLauncherParameters()";
        signatures[16] = "getMemeverseByMemecoin(address)";
        signatures[17] = "getMemeverseByVerseId(uint256)";
        signatures[18] = "getStageByMemecoin(address)";
        signatures[19] = "getStageByVerseId(uint256)";
        signatures[20] = "getUAssetByVerseId(uint256)";
        signatures[21] = "getVerseIdByMemecoin(address)";
        signatures[22] = "getYieldVaultByVerseId(uint256)";
        signatures[23] =
            "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)";
        signatures[24] = "memecoinToIds(address)";
        signatures[25] = "mintPOLToken(uint256,uint256,uint256,uint256,uint256,uint256,uint256)";
        signatures[26] = "normalFeeStates(uint256)";
        signatures[27] = "normalYTClaimed(uint256,address)";
        signatures[28] = "owner()";
        signatures[29] = "pause()";
        signatures[30] = "paused()";
        signatures[31] = "pendingAuxiliaryGovFeeStates(uint256)";
        signatures[32] = "polToIds(address)";
        signatures[33] = "polend()";
        signatures[34] = "preorder(uint256,uint256,address)";
        signatures[35] = "previewPreorderCapacity(uint256)";
        signatures[36] = "proxiableUUID()";
        signatures[37] = "redeemAndDistributeFees(uint256,address)";
        signatures[38] = "redeemAuxiliaryLiquidity(uint256)";
        signatures[39] = "redeemMemecoinLiquidity(uint256,uint256,bool)";
        signatures[40] = "redeemMemecoinLiquidity(uint256,uint256,bool,uint256,uint256,uint256)";
        signatures[41] = "refund(uint256)";
        signatures[42] = "refundPreorder(uint256)";
        signatures[43] = "registerMemeverse(string,string,uint256,uint128,uint128,uint32[],address,bool)";
        signatures[44] = "remainingGenesisCapacity(uint256)";
        signatures[45] = "removeGasDust(address)";
        signatures[46] = "setLaunchImpl(address)";
        signatures[47] = "setExecutorRewardRate(uint256)";
        signatures[48] = "setExternalInfo(uint256,string,string,string[])";
        signatures[49] = "setSettlementImpl(address)";
        signatures[50] = "setFeePreviewReader(address)";
        signatures[51] = "setFundMetaData(address,uint256,uint256)";
        signatures[52] = "setGasLimits(uint128,uint128)";
        signatures[53] = "setMemeverseProxyDeployer(address)";
        signatures[54] = "setMemeverseRegistrar(address)";
        signatures[55] = "setMemeverseSwapRouter(address)";
        signatures[56] = "setMemeverseUniswapHook(address)";
        signatures[57] = "setLiquidityImpl(address)";
        signatures[58] = "setPreorderConfig(uint256,uint256)";
        signatures[59] = "setYieldDispatcher(address)";
        signatures[60] = "settleLeveragedAuxiliaryLiquidity(uint256)";
        signatures[61] = "totalNormalClaimableYT(uint256)";
        signatures[62] = "totalNormalFunds(uint256)";
        signatures[63] = "transferOwnership(address)";
        signatures[64] = "unpause()";
        signatures[65] = "UPGRADE_INTERFACE_VERSION()";
        signatures[66] = "upgradeToAndCall(address,bytes)";
        signatures[67] = "userGenesisData(uint256,address)";
        signatures[68] = "userNormalFeeClaims(uint256,address)";
        signatures[69] = "userPreorderData(uint256,address)";
    }

    function _expectSelectorMissing(string memory signature) internal view {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        (bool ok,) = pureLauncher.staticcall(abi.encodeWithSelector(selector, uint256(1)));
        assertFalse(ok, signature);
    }

    function testExpectedSelectorBaselineIncludesRuntimeSurface() external {
        string[] memory signatures = _expectedLauncherSelectorSignatures();
        assertEq(signatures.length, 70, "expected selector count");
        assertEq(signatures[0], "BPS_BASE()", "first selector");
        assertEq(signatures[69], "userPreorderData(uint256,address)", "last selector");

        // Verify every expected selector actually exists on the proxy.
        // Pad calldata with 512 zero-bytes so the abi decoder does not revert
        // with empty data before the function body is entered (512 covers the
        // 13-parameter initialize). Use a regular call
        // (not staticcall) because state-changing functions blocked by staticcall
        // produce empty revert data at the EVM level, indistinguishable from a
        // missing selector. Even when an argument-less probe does execute a side
        // effect, it can only touch the pure proxy / pure implementation used
        // solely for this selector validation; the assertion only requires a
        // non-empty response, so both success and named-error reverts count.
        bytes memory pad = new bytes(512);
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes4 selector = bytes4(keccak256(bytes(signatures[i])));
            bool ok;
            bytes memory data;
            if (selector == bytes4(keccak256("upgradeToAndCall(address,bytes)"))) {
                // The generic zero-padded probe would drive the ERC1967 upgrade machinery toward the
                // zero address and revert with empty data, indistinguishable from a missing selector.
                // Probe with a valid self-upgrade instead: new implementation = the pure
                // implementation itself, and the post-upgrade call reads owner() on it.
                (ok, data) = pureLauncher.call(abi.encodeWithSelector(selector, pureImplementation, hex"8da5cb5b"));
            } else {
                (ok, data) = pureLauncher.call(abi.encodePacked(selector, pad));
            }
            assertTrue(
                ok || data.length > 0, string(abi.encodePacked("selector missing from runtime: ", signatures[i]))
            );
        }
    }

    /// @notice Scans runtime bytecode for function selectors and verifies each one
    ///         is accounted for in the baseline list. Catches new external functions
    ///         added without updating _expectedLauncherSelectorSignatures.
    function testNoUndocumentedRuntimeSelectors() external {
        string[] memory expected = _expectedLauncherSelectorSignatures();

        // Build a lookup array of expected selectors (local mapping not allowed in Solidity).
        bytes4[] memory knownSelectors = new bytes4[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            knownSelectors[i] = bytes4(keccak256(bytes(expected[i])));
        }

        // Scan the implementation's runtime bytecode for PUSH4 (0x63) selector patterns — the proxy
        // runtime is a thin delegatecall fallback with no dispatch table, so scanning the proxy would
        // make this test vacuously pass.
        // In the function dispatch block the compiler emits:
        //   DUP1 PUSH4 <selector> EQ PUSH2 <dest> JUMPI
        // Extract every 4-byte value following a 0x63 opcode.
        bytes memory code = pureImplementation.code;
        uint256 selectorCount;
        bytes4[] memory found = new bytes4[](code.length / 4); // upper bound

        for (uint256 i = 0; i + 4 < code.length; i++) {
            if (uint8(code[i]) == 0x63) {
                // PUSH4 opcode — next 4 bytes are the selector.
                if (i + 5 > code.length) break;
                bytes4 sel = bytes4(
                    (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                        | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
                );
                // Skip selectors below the BPS_BASE() floor — compiler metadata noise.
                if (uint32(sel) < 0x10000000) continue;

                // De-duplicate.
                bool duplicate;
                for (uint256 j = 0; j < selectorCount; j++) {
                    if (found[j] == sel) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;

                // Check against baseline.
                bool inBaseline;
                for (uint256 j = 0; j < knownSelectors.length; j++) {
                    if (knownSelectors[j] == sel) {
                        inBaseline = true;
                        break;
                    }
                }

                if (!inBaseline) {
                    // Reconstruct a plausible signature string for diagnostics.
                    // Verify the selector actually dispatches to a real function before flagging it.
                    // Probe the implementation with a regular call: state-changing entries revert with
                    // empty data under STATICCALL, which is indistinguishable from a missing selector.
                    // The probe can only mutate the pure implementation's own (unused) storage.
                    // Pad with 512 zero-bytes so larger signatures (e.g. the 13-parameter
                    // initialize) still decode instead of failing opaquely with empty data.
                    bytes memory pad = new bytes(512);
                    (bool ok, bytes memory data) = pureImplementation.call(abi.encodePacked(sel, pad));
                    if (ok || data.length > 0) {
                        found[selectorCount] = sel;
                        selectorCount++;
                        // Emit selector hex so the developer can identify the missing entry.
                        emit log_named_bytes32("undocumented selector", bytes32(sel));
                    }
                }
            }
        }
        assertEq(selectorCount, 0, "runtime has selectors not in baseline");
    }

    function testNoNewInternalStateGetters() external view {
        _expectSelectorMissing("preorderStates(uint256)");
        _expectSelectorMissing("UNLOCK_PROTECTION_WINDOW()");
        _expectSelectorMissing("MAX_FUND_BASED_AMOUNT()");
        _expectSelectorMissing("MAX_SUPPORTED_TOTAL_GENESIS_FUNDS()");
        _expectSelectorMissing("exposedMemeverseLauncherStorage()");
    }

    /// @notice Test getter views revert on zero input and return stored state.
    /// @dev Exercises all public view helpers for zero-input guarding and correct state returns.
    function testGetterViewsRevertOnZeroInputAndReturnStoredState() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        verse.governor = GOVERNOR;
        verse.yieldVault = YIELD_VAULT;
        _setVerse(1, verse);
        setVerseIdByMemecoinForTest(launcherProxy, MEMECOIN, 1);
        setGenesisFundForTest(launcherProxy, 1, 120 ether);
        setUserGenesisDataForTest(launcherProxy, 1, ALICE, 24 ether, false, false);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.getVerseIdByMemecoin(address(0));
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getMemeverseByVerseId(0);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getUAssetByVerseId(0);
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.getMemeverseByMemecoin(address(0));
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getStageByVerseId(0);
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.getStageByMemecoin(address(0));
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getYieldVaultByVerseId(0);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getGovernorByVerseId(0);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        feePreviewReader.previewGenesisMakerFees(0);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        feePreviewReader.quoteDistributionLzFee(0);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getMemeverseByVerseId(999);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.getMemeverseByMemecoin(address(0x9999));
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        feePreviewReader.quoteDistributionLzFee(999);

        vm.startPrank(ALICE);
        assertEq(launcher.getVerseIdByMemecoin(MEMECOIN), 1);
        assertEq(launcher.getMemeverseByVerseId(1).memecoin, MEMECOIN);
        assertEq(launcher.getUAssetByVerseId(1), address(uAssetToken));
        assertEq(uint256(launcher.getStageByVerseId(1)), uint256(IMemeverseLauncher.Stage.Locked));
        assertEq(launcher.getYieldVaultByVerseId(1), YIELD_VAULT);
        assertEq(launcher.getGovernorByVerseId(1), GOVERNOR);
        vm.stopPrank();
    }

    function testPreviewPreorderCapacity_UsesAllNormalFundsAndLeveragedDebtBase() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        setGenesisFundForTest(launcherProxy, 1, 1000 ether);
        polend.setTotalLeveragedDebt(500 ether);
        assertEq(launcher.previewPreorderCapacity(1), 262.5 ether, "70 percent base times ratio");
    }

    function testPreviewPreorderCapacity_HandlesLargeBaseWithoutIntermediateOverflow() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        uint256 baseFunds = type(uint128).max;
        setGenesisFundForTest(launcherProxy, 1, baseFunds);

        assertEq(launcher.previewPreorderCapacity(1), _expectedDefaultPreorderCapacity(baseFunds), "capacity");
    }

    function testPreviewPreorderCapacity_RevertsWhenTotalGenesisFundsExceedSupportedMaximum() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        setGenesisFundForTest(launcherProxy, 1, type(uint128).max);
        polend.setTotalLeveragedDebt(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseLauncher.TotalGenesisFundsTooHigh.selector,
                uint256(type(uint128).max) + 1,
                uint256(type(uint128).max)
            )
        );
        launcher.previewPreorderCapacity(1);
    }

    function testPreviewPreorderCapacity_RevertsWhenVerseIdInvalid() external {
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.previewPreorderCapacity(0);

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.previewPreorderCapacity(999);
    }

    function testClaimablePreorderMemecoin_UsesFullPrecisionForLargePreorderAndVesting() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Locked));

        uint256 settledMemecoin = 1 << 240;
        uint256 userFunds = 1 << 80;
        uint256 totalFunds = 1 << 80;
        uint40 settlementTimestamp = 1_000;
        uint256 elapsed = 2 days;

        setPreorderStateForTest(launcherProxy, 1, totalFunds, settledMemecoin, settlementTimestamp);
        setUserPreorderDataForTest(launcherProxy, 1, ALICE, userFunds, 0, false);
        vm.warp(uint256(settlementTimestamp) + elapsed);

        uint256 purchasedMemecoin = FullMath.mulDiv(settledMemecoin, userFunds, totalFunds);
        uint256 expected = FullMath.mulDiv(purchasedMemecoin, elapsed, 7 days);

        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(1), expected, "claimable preorder");
    }

    function testGetDebtCapBaseByVerseId_ReturnsMinTotalFundWhenNormalFundsAreLower() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        setGenesisFundForTest(launcherProxy, 1, 5 ether);
        setFundMetaDataForTest(launcherProxy, address(uAssetToken), 10 ether, 1);

        (bool success, bytes memory data) =
            address(launcher).staticcall(abi.encodeWithSignature("getDebtCapBaseByVerseId(uint256)", 1));

        assertTrue(success, "debt cap base getter");
        assertEq(abi.decode(data, (uint256)), 10 ether, "min fund");
    }

    function testGetDebtCapBaseByVerseId_ReturnsNormalFundsWhenHigher() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        setGenesisFundForTest(launcherProxy, 1, 15 ether);
        setFundMetaDataForTest(launcherProxy, address(uAssetToken), 10 ether, 1);

        (bool success, bytes memory data) =
            address(launcher).staticcall(abi.encodeWithSignature("getDebtCapBaseByVerseId(uint256)", 1));

        assertTrue(success, "debt cap base getter");
        assertEq(abi.decode(data, (uint256)), 15 ether, "normal funds");
    }

    function testGetDebtCapBaseByVerseId_AllowsLargeMinTotalFund() external {
        uint256 verseId = 2;
        uint256 largeMinTotalFund = uint256(type(uint128).max) + 1;
        _setVerse(verseId, _baseVerse(IMemeverseLauncher.Stage.Genesis));
        setGenesisFundForTest(launcherProxy, verseId, 0);
        setFundMetaDataForTest(launcherProxy, address(uAssetToken), largeMinTotalFund, 1);

        assertEq(launcher.getDebtCapBaseByVerseId(verseId), largeMinTotalFund, "large min fund");
    }

    function testGetDebtCapBaseByVerseId_RevertsForInvalidVerseId() external view {
        (bool success, bytes memory data) =
            address(launcher).staticcall(abi.encodeWithSignature("getDebtCapBaseByVerseId(uint256)", 999));

        assertFalse(success, "invalid verse");
        assertEq(bytes4(data), IMemeverseLauncher.InvalidVerseId.selector, "selector");
    }

    function testClaimNormalYT_RevertsBeforeLocked() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Genesis);
        _setVerse(1, verse);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.NotReachedLockedStage.selector);
        launcher.claimNormalYT(1);
    }

    /// @notice Verifies launcher no longer exposes a configurable unlock-protection getter/setter surface.
    /// @dev The protection window is now a fixed product constant rather than owner-configurable state.
    function testUnlockProtectionWindow_ConfigSurfaceRemoved() external view {
        (bool getterOk,) = pureLauncher.staticcall(abi.encodeWithSignature("unlockProtectionWindow()"));
        (bool setterOk,) = pureLauncher.staticcall(abi.encodeWithSignature("setUnlockProtectionWindow(uint256)", 1));

        assertFalse(getterOk, "getter should be removed");
        assertFalse(setterOk, "setter should be removed");
    }

    /// @notice Test genesis reverts when verse missing or paused or wrong stage and accumulates funds.
    /// @dev Confirms genesis enforces id, stage, zero-input, and pause guards while still accounting for funds.
    function testGenesisRevertsWhenVerseMissingOrPausedOrWrongStageAndAccumulatesFunds() external {
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.genesis(1, 1 ether, ALICE);

        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        _setVerse(1, verse);

        vm.expectRevert(IMemeverseLauncher.NotGenesisStage.selector);
        launcher.genesis(1, 1 ether, ALICE);

        verse.currentStage = IMemeverseLauncher.Stage.Genesis;
        _setVerse(1, verse);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.genesis(1, 0, ALICE);

        MemeverseLauncherUpgradeable(launcherProxy).pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        launcher.genesis(1, 1 ether, ALICE);
        MemeverseLauncherUpgradeable(launcherProxy).unpause();

        uAssetToken.mint(address(this), 1 ether);
        uAssetToken.approve(address(launcher), type(uint256).max);
        launcher.genesis(1, 1 ether, ALICE);

        uint256 _totalNormalFunds = MemeverseLauncherUpgradeable(launcherProxy).totalNormalFunds(1);
        (uint256 genesisFund,,) = MemeverseLauncherUpgradeable(launcherProxy).userGenesisData(1, ALICE);
        assertEq(_totalNormalFunds, 1 ether);
        assertEq(genesisFund, 1 ether);
    }

    /// @notice Verifies genesis can accumulate past the old fundBasedAmount cap.
    function testGenesis_AllowsAccumulationPastFormerFundBasedAmountCap() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Genesis);
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, uint128(MAX_SUPPORTED_FUND_BASED_AMOUNT));

        uAssetToken.mint(address(this), 1 ether);
        uAssetToken.approve(address(launcher), type(uint256).max);

        launcher.genesis(1, 1 ether, ALICE);

        assertEq(
            MemeverseLauncherUpgradeable(launcherProxy).totalNormalFunds(1),
            MAX_SUPPORTED_FUND_BASED_AMOUNT + 1 ether,
            "funds increased"
        );
        (uint256 genesisFund,,) = MemeverseLauncherUpgradeable(launcherProxy).userGenesisData(1, ALICE);
        assertEq(genesisFund, 1 ether, "genesis fund tracked");
    }

    function testGenesis_RevertsWhenAggregateTotalGenesisFundsWouldExceedSupportedMaximum() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Genesis);
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, type(uint128).max);
        polend.setTotalLeveragedDebt(1);

        uAssetToken.mint(address(this), 1);
        uAssetToken.approve(address(launcher), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseLauncher.TotalGenesisFundsTooHigh.selector,
                uint256(type(uint128).max) + 2,
                uint256(type(uint128).max)
            )
        );
        launcher.genesis(1, 1, ALICE);
    }

    /// @notice Test refund success marks user and transfers native fund.
    /// @dev Checks that refunds set the flag and return ETH when the verse is in Refund stage.
    function testRefundSuccessMarksUserAndTransfersNativeFund() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Refund);
        _setVerse(1, verse);
        setUserGenesisDataForTest(launcherProxy, 1, ALICE, 1 ether, false, false);
        uAssetToken.mint(address(launcher), 1 ether);

        vm.prank(ALICE);
        uint256 refunded = launcher.refund(1);

        (uint256 genesisFund, bool isRefunded,) = MemeverseLauncherUpgradeable(launcherProxy).userGenesisData(1, ALICE);
        assertEq(refunded, 1 ether);
        assertEq(genesisFund, 1 ether);
        assertTrue(isRefunded);
        assertEq(uAssetToken.balanceOf(ALICE), 1 ether);
    }

    /// @notice Test claim normal YT pause guard while pause allows refund safety exit.
    /// @dev Ensures pause blocks non-exit claims but does not block refunds.
    function testClaimNormalYTPauseGuardAllowsRefundSafetyExit() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        verse.pol = POL;
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, 120 ether);
        setUserGenesisDataForTest(launcherProxy, 1, ALICE, 0, false, false);
        setTotalNormalClaimableYTForTest(launcherProxy, 1, 60 ether);

        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidClaim.selector);
        launcher.claimNormalYT(1);

        MemeverseLauncherUpgradeable(launcherProxy).pause();
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        launcher.claimNormalYT(1);

        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        _setVerse(1, verse);
        setUserGenesisDataForTest(launcherProxy, 1, ALICE, 1 ether, false, false);
        uAssetToken.mint(address(launcher), 1 ether);
        vm.prank(ALICE);
        assertEq(launcher.refund(1), 1 ether);
    }

    /// @notice Test preorder reverts when stage or capacity invalid.
    /// @dev Verifies preorder enforces stage, non-zero input, and cap constraints.
    function testPreorderRevertsWhenNotGenesisOrCapacityExceeded() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        _setVerse(1, verse);

        vm.expectRevert(IMemeverseLauncher.NotGenesisStage.selector);
        launcher.preorder(1, 1 ether, ALICE);

        verse.currentStage = IMemeverseLauncher.Stage.Genesis;
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, 4 ether);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.preorder(1, 0, ALICE);

        uAssetToken.mint(address(this), 2 ether);
        uAssetToken.approve(address(launcher), type(uint256).max);

        vm.expectRevert();
        launcher.preorder(1, 2 ether, ALICE);
    }

    function testPreorderCapacity_IncludesPolFundsInNormalFundBase() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Genesis);
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, 10 ether);

        uAssetToken.mint(address(this), 1 ether);
        uAssetToken.approve(address(launcher), type(uint256).max);

        launcher.preorder(1, 1 ether, ALICE);

        (uint256 preorderFunds,, bool isRefunded) =
            MemeverseLauncherUpgradeable(launcherProxy).userPreorderData(1, ALICE);
        assertEq(preorderFunds, 1 ether, "preorder accepted");
        assertFalse(isRefunded, "not refunded");
    }

    function testPreorderCapacityCheck_HandlesLargeBaseWithoutIntermediateOverflow() external {
        uint256 baseFunds = type(uint128).max;
        uint256 expectedCapacity = _expectedDefaultPreorderCapacity(baseFunds);
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Genesis);
        _setVerse(1, verse);
        setGenesisFundForTest(launcherProxy, 1, baseFunds);
        setPreorderStateForTest(launcherProxy, 1, expectedCapacity - 1, 0, 0);

        uAssetToken.mint(address(this), 1);
        uAssetToken.approve(address(launcher), type(uint256).max);

        launcher.preorder(1, 1, ALICE);

        (uint256 preorderFunds,, bool isRefunded) =
            MemeverseLauncherUpgradeable(launcherProxy).userPreorderData(1, ALICE);
        assertEq(preorderFunds, 1, "preorder accepted");
        assertFalse(isRefunded, "not refunded");
    }

    /// @notice Test claimable preorder memecoin linearly vests over seven days.
    /// @dev Checks that linear vesting unfolds over 7 days by warping time.
    function testClaimablePreorderMemecoin_LinearVestingOverSevenDays() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        _setVerse(1, verse);
        setUserPreorderDataForTest(launcherProxy, 1, ALICE, 1 ether, 10 ether, false);
        setPreorderStateForTest(launcherProxy, 1, 1 ether, 70 ether, uint40(block.timestamp));
        uAssetToken.mint(address(launcher), 70 ether);

        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(1), 0, "initial claimable");

        vm.warp(block.timestamp + 3 days + 12 hours);
        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(1), 25 ether, "midway claimable");

        vm.warp(block.timestamp + 3 days + 12 hours + 1);
        vm.prank(ALICE);
        assertEq(launcher.claimablePreorderMemecoin(1), 60 ether, "final claimable");
    }

    function testClaimablePreorderMemecoinForTest_MatchesProductionWhenPreorderMarkedRefunded() external {
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Locked));
        setUserPreorderDataForTest(launcherProxy, 1, ALICE, 1 ether, 0, true);
        setPreorderStateForTest(launcherProxy, 1, 1 ether, 70 ether, uint40(block.timestamp));
        vm.warp(block.timestamp + 7 days);

        vm.prank(ALICE);
        uint256 productionClaimable = launcher.claimablePreorderMemecoin(1);

        assertEq(claimablePreorderMemecoinForTest(launcherProxy, 1, ALICE), productionClaimable, "helper drift");
        assertEq(productionClaimable, 70 ether, "production ignores refund flag");
    }

    function testClaimablePreorderMemecoinForTest_MatchesProductionBeforeSettlementTime() external {
        uint40 settlementTimestamp = uint40(block.timestamp + 1 days);
        _setVerse(1, _baseVerse(IMemeverseLauncher.Stage.Locked));
        setUserPreorderDataForTest(launcherProxy, 1, ALICE, 1 ether, 0, false);
        setPreorderStateForTest(launcherProxy, 1, 1 ether, 70 ether, settlementTimestamp);

        vm.prank(ALICE);
        uint256 productionClaimable = launcher.claimablePreorderMemecoin(1);

        assertEq(claimablePreorderMemecoinForTest(launcherProxy, 1, ALICE), productionClaimable, "helper drift");
        assertEq(productionClaimable, 0, "future settlement has no elapsed vesting");
    }

    function testClaimablePreorderMemecoinForTest_RevertsLikeProductionForInvalidVerseId() external {
        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.claimablePreorderMemecoin(999);

        // Helper reads storage directly and returns 0 for non-existent verseId (no validation)
        assertEq(claimablePreorderMemecoinForTest(launcherProxy, 999, ALICE), 0, "helper returns 0 for invalid verse");
    }

    /// @notice Test claimable preorder memecoin remains pro-rata and bounded for multiple users under fuzzed inputs.
    /// @dev Exercises the pro-rata and total vesting bounds with bounded fuzzed inputs.
    /// @param fundsA See implementation.
    /// @param fundsB See implementation.
    /// @param settledMemecoin See implementation.
    /// @param elapsed See implementation.
    function testFuzzClaimablePreorderMemecoin_MultiUserProRataAndBounded(
        uint96 fundsA,
        uint96 fundsB,
        uint96 settledMemecoin,
        uint32 elapsed
    ) external {
        fundsA = uint96(bound(uint256(fundsA), 1, 1_000_000 ether));
        fundsB = uint96(bound(uint256(fundsB), 1, 1_000_000 ether));
        settledMemecoin = uint96(bound(uint256(settledMemecoin), 1, 1_000_000 ether));
        elapsed = uint32(bound(uint256(elapsed), 0, 7 days));

        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Locked);
        _setVerse(1, verse);
        setUserPreorderDataForTest(launcherProxy, 1, ALICE, fundsA, 0, false);
        setUserPreorderDataForTest(launcherProxy, 1, BOB, fundsB, 0, false);
        setPreorderStateForTest(
            launcherProxy, 1, uint256(fundsA) + uint256(fundsB), settledMemecoin, uint40(block.timestamp)
        );

        vm.warp(block.timestamp + elapsed);

        vm.prank(ALICE);
        uint256 claimableA = launcher.claimablePreorderMemecoin(1);

        vm.prank(BOB);
        uint256 claimableB = launcher.claimablePreorderMemecoin(1);

        uint256 entitledA = uint256(settledMemecoin) * uint256(fundsA) / (uint256(fundsA) + uint256(fundsB));
        uint256 entitledB = uint256(settledMemecoin) * uint256(fundsB) / (uint256(fundsA) + uint256(fundsB));
        uint256 vestedTotal = uint256(settledMemecoin) * elapsed / 7 days;

        assertLe(claimableA, entitledA, "alice bounded by entitlement");
        assertLe(claimableB, entitledB, "bob bounded by entitlement");
        assertLe(claimableA + claimableB, vestedTotal, "total bounded by vested");
    }

    /// @notice Verifies preorder claim previews reject non-existent non-zero verse ids.
    /// @dev Prevents unknown verse ids from falling through to stage-based errors.
    function testClaimablePreorderMemecoin_RevertsWhenVerseIdNotRegistered() external {
        vm.prank(ALICE);
        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        launcher.claimablePreorderMemecoin(999);
    }

    /// @notice Test get memeverse by memecoin and stage by memecoin return stored state.
    /// @dev Ensures the memecoin-indexed getters match the pre-seeded verse metadata.
    function testGetMemeverseByMemecoinAndStageByMemecoinReturnStoredState() external {
        IMemeverseLauncher.Memeverse memory verse = _baseVerse(IMemeverseLauncher.Stage.Unlocked);
        verse.governor = GOVERNOR;
        _setVerse(7, verse);
        setVerseIdByMemecoinForTest(launcherProxy, MEMECOIN, 7);

        IMemeverseLauncher.Memeverse memory stored = launcher.getMemeverseByMemecoin(MEMECOIN);
        assertEq(stored.memecoin, MEMECOIN);
        assertEq(stored.governor, GOVERNOR);
        assertEq(uint256(launcher.getStageByMemecoin(MEMECOIN)), uint256(IMemeverseLauncher.Stage.Unlocked));
    }
}
