// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {CallRecorder, MockPOLendForPOLendIntegration} from "../mocks/verse/LauncherPOLendIntegrationMocks.sol";
import {MemeverseLauncher} from "../../src/verse/MemeverseLauncher.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";

contract MemeverseLauncherGenesisThresholdRegressionTest is Test, MemeverseLauncherTestHelper {
    uint256 internal constant VERSE_ID = 1;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockERC20 internal uAsset;
    MockPOLendForPOLendIntegration internal polend;

    function setUp() external {
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        polend = new MockPOLendForPOLendIntegration(uAsset, new CallRecorder());

        MemeverseLauncher implementation = new MemeverseLauncher();
        launcherProxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    MemeverseLauncher.initialize,
                    (
                        address(this),
                        address(0x1),
                        address(0x2),
                        address(0x3),
                        address(0x4),
                        address(0x5),
                        address(polend),
                        address(0x6),
                        25,
                        uint128(115_000),
                        uint128(135_000),
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = IMemeverseLauncher(launcherProxy);
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        launcher.setFundMetaData(address(uAsset), 10 ether, 1);
    }

    function testChangeStage_RefundsWhenOnlyCombinedDebtAndNormalFundsMeetThreshold() external {
        setMemeverseForTest(
            launcherProxy,
            VERSE_ID,
            address(uAsset),
            address(0xBEEF),
            address(0xCAFE),
            address(0xD00D),
            address(0xF00D),
            address(0),
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 8 days),
            IMemeverseLauncher.Stage.Genesis,
            false
        );
        setGenesisFundForTest(launcherProxy, VERSE_ID, 6 ether);
        polend.setTotalLeveragedInterest(VERSE_ID, 4 ether);
        polend.setTotalLeveragedDebt(VERSE_ID, 40 ether);

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(
            uint256(launcher.changeStage(VERSE_ID)),
            uint256(IMemeverseLauncher.Stage.Refund),
            "combined deployable funds do not satisfy launch gate"
        );
        assertEq(
            uint256(launcher.getStageByVerseId(VERSE_ID)), uint256(IMemeverseLauncher.Stage.Refund), "stored stage"
        );
        assertEq(polend.lastRefundedVerse(), VERSE_ID, "mark refundable");
    }
}
