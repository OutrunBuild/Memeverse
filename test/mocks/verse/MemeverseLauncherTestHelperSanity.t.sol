// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherUpgradeable} from "../../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLauncherTestHelper} from "./MemeverseLauncherTestHelper.sol";

/// @notice Cross-validates MemeverseLauncherTestHelper slot writes against production getters.
/// @dev The helper seeds proxy storage via raw vm.store at hardcoded ERC-7201 offsets. If the
///      storage layout drifts, those writes silently land on wrong slots. Each test below writes
///      through the helper and reads back through MemeverseLauncherUpgradeable's own getters, so
///      an offset mismatch fails loudly here instead of only surfacing in downstream seed tests.
contract MemeverseLauncherTestHelperSanityTest is Test, MemeverseLauncherTestHelper {
    MemeverseLauncherUpgradeable internal launcher;
    address internal proxy;

    function setUp() external {
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        address(this),
                        address(0x1),
                        address(0x2),
                        address(0x3),
                        address(0x4),
                        address(0x5),
                        address(0x6),
                        address(0x7),
                        100,
                        200000,
                        200000,
                        5000,
                        7 days
                    )
                )
            )
        );
        launcher = MemeverseLauncherUpgradeable(proxy);
    }

    function test_SimpleFieldSeedsReadViaProductionGetters() external {
        address polendSeed = makeAddr("polendSeed");
        setPolendForTest(proxy, polendSeed);
        assertEq(launcher.polend(), polendSeed, "polend");

        address polSplitterSeed = makeAddr("polSplitterSeed");
        setPolSplitterForTest(proxy, polSplitterSeed);
        assertEq(launcher.getLauncherContracts().polSplitter, polSplitterSeed, "polSplitter");

        setGenesisFundForTest(proxy, 1, 750e18);
        assertEq(launcher.totalNormalFunds(1), 750e18, "totalNormalFunds");

        setTotalNormalClaimableYTForTest(proxy, 1, 42e18);
        assertEq(launcher.totalNormalClaimableYT(1), 42e18, "totalNormalClaimableYT");

        address memecoin = makeAddr("memecoin");
        setVerseIdByMemecoinForTest(proxy, memecoin, 1);
        assertEq(launcher.memecoinToIds(memecoin), 1, "memecoinToIds");
        assertEq(launcher.getVerseIdByMemecoin(memecoin), 1, "getVerseIdByMemecoin");

        address uAsset = makeAddr("uAsset");
        setFundMetaDataForTest(proxy, uAsset, 10e18, 4);
        (uint256 minTotalFund, uint256 fundBasedAmount) = launcher.fundMetaDatas(uAsset);
        assertEq(minTotalFund, 10e18, "fundMetaDatas.minTotalFund");
        assertEq(fundBasedAmount, 4, "fundMetaDatas.fundBasedAmount");
    }

    function test_StructMappingSeedsReadViaProductionGetters() external {
        address account = makeAddr("user");

        setUserGenesisDataForTest(proxy, 1, account, 3e18, true, false);
        (uint256 genesisFund, bool isRefunded, bool isRedeemed) = launcher.userGenesisData(1, account);
        assertEq(genesisFund, 3e18, "userGenesisData.genesisFund");
        assertTrue(isRefunded, "userGenesisData.isRefunded");
        assertFalse(isRedeemed, "userGenesisData.isRedeemed");

        setUserPreorderDataForTest(proxy, 1, account, 80e18, 5e18, true);
        (uint256 funds, uint256 claimedMemecoin, bool preorderRefunded) = launcher.userPreorderData(1, account);
        assertEq(funds, 80e18, "userPreorderData.funds");
        assertEq(claimedMemecoin, 5e18, "userPreorderData.claimedMemecoin");
        assertTrue(preorderRefunded, "userPreorderData.isRefunded");

        setAuxiliaryLiquiditiesForTest(proxy, 1, 1e18, 2e18, 3e18);
        (uint256 polUAsset, uint256 ptUAsset, uint256 ptPol) = launcher.auxiliaryLiquidities(1);
        assertEq(polUAsset, 1e18, "auxiliaryLiquidities.polUAsset");
        assertEq(ptUAsset, 2e18, "auxiliaryLiquidities.ptUAsset");
        assertEq(ptPol, 3e18, "auxiliaryLiquidities.ptPol");

        setBootstrapResidualClaimsForTest(proxy, 1, 11e18, 22e18, 33e18, 44e18);
        (uint256 normalPOL, uint256 normalPT, uint256 leveragedPOL, uint256 leveragedPT) =
            launcher.bootstrapResidualClaims(1);
        assertEq(normalPOL, 11e18, "bootstrapResidualClaims.normalResidualPOL");
        assertEq(normalPT, 22e18, "bootstrapResidualClaims.normalResidualPT");
        assertEq(leveragedPOL, 33e18, "bootstrapResidualClaims.leveragedResidualPOL");
        assertEq(leveragedPT, 44e18, "bootstrapResidualClaims.leveragedResidualPT");

        setNormalFeeStateForTest(proxy, 1, 7e18, 8e18);
        (uint256 accUAssetFee, uint256 accPTFee) = launcher.normalFeeStates(1);
        assertEq(accUAssetFee, 7e18, "normalFeeStates.accUAssetFee");
        assertEq(accPTFee, 8e18, "normalFeeStates.accPTFee");

        setPendingAuxiliaryGovFeeForTest(proxy, 1, 9e18, 10e18);
        (uint256 pendingUAssetFee, uint256 pendingPTFee) = launcher.pendingAuxiliaryGovFeeStates(1);
        assertEq(pendingUAssetFee, 9e18, "pendingAuxiliaryGovFeeStates.pendingUAssetFee");
        assertEq(pendingPTFee, 10e18, "pendingAuxiliaryGovFeeStates.pendingPTFee");
    }

    function test_MemeverseSeedReadViaProductionGetters() external {
        address uAsset = makeAddr("memeverse.uAsset");
        address memecoin = makeAddr("memeverse.memecoin");
        address pol = makeAddr("memeverse.pol");
        address yieldVault = makeAddr("memeverse.yieldVault");
        address governor = makeAddr("memeverse.governor");
        address incentivizer = makeAddr("memeverse.incentivizer");

        setMemeverseForTest(
            proxy,
            2,
            uAsset,
            memecoin,
            pol,
            yieldVault,
            governor,
            incentivizer,
            999_999,
            123_456_789,
            IMemeverseLauncher.Stage.Locked,
            true
        );
        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(2);
        assertEq(verse.uAsset, uAsset, "memeverse.uAsset");
        assertEq(uint8(verse.currentStage), uint8(IMemeverseLauncher.Stage.Locked), "memeverse.currentStage");
        assertTrue(verse.flashGenesis, "memeverse.flashGenesis");
        assertEq(verse.memecoin, memecoin, "memeverse.memecoin");
        assertEq(verse.pol, pol, "memeverse.pol");
        assertEq(verse.yieldVault, yieldVault, "memeverse.yieldVault");
        assertEq(verse.governor, governor, "memeverse.governor");
        assertEq(verse.incentivizer, incentivizer, "memeverse.incentivizer");
        assertEq(uint256(verse.endTime), 999_999, "memeverse.endTime");
        assertEq(uint256(verse.unlockTime), 123_456_789, "memeverse.unlockTime");

        uint32[] memory chainIds = new uint32[](3);
        chainIds[0] = 1;
        chainIds[1] = 301;
        chainIds[2] = 42_220;
        setOmnichainIdsForTest(proxy, 2, chainIds);
        verse = launcher.getMemeverseByVerseId(2);
        assertEq(verse.omnichainIds.length, 3, "memeverse.omnichainIds.length");
        assertEq(verse.omnichainIds[0], 1, "memeverse.omnichainIds[0]");
        assertEq(verse.omnichainIds[1], 301, "memeverse.omnichainIds[1]");
        assertEq(verse.omnichainIds[2], 42_220, "memeverse.omnichainIds[2]");
    }

    function test_PreorderStateSeedReadViaProductionClaimable() external {
        address uAsset = makeAddr("preorder.uAsset");
        address memecoin = makeAddr("preorder.memecoin");
        address pol = makeAddr("preorder.pol");
        address yieldVault = makeAddr("preorder.yieldVault");
        address governor = makeAddr("preorder.governor");
        address incentivizer = makeAddr("preorder.incentivizer");

        // preorderStates has no direct getter; the production claim path reads it, so seed a
        // fully vested preorder and assert the amount computed by MemeverseLauncherLib.
        setMemeverseForTest(
            proxy,
            3,
            uAsset,
            memecoin,
            pol,
            yieldVault,
            governor,
            incentivizer,
            999_999,
            123_456_789,
            IMemeverseLauncher.Stage.Locked,
            false
        );
        uint40 settledAt = uint40(block.timestamp);
        setPreorderStateForTest(proxy, 3, 1000e18, 500e18, settledAt);
        setUserPreorderDataForTest(proxy, 3, address(this), 250e18, 0, false);

        // Fully vested past initialize()'s 7-day preorderVestingDuration:
        // claimable = settledMemecoin * userFunds / totalFunds = 500e18 * 250e18 / 1000e18.
        vm.warp(settledAt + 8 days);
        assertEq(launcher.claimablePreorderMemecoin(3), 125e18, "claimablePreorderMemecoin");
    }
}
