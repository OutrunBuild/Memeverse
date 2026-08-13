// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MemeverseLauncherUpgradeable} from "../../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLauncherTestHelper} from "./MemeverseLauncherTestHelper.sol";

contract MemeverseLauncherTestHelperSanityTest is Test, MemeverseLauncherTestHelper {
    function test_slotRoundTrip_preorderState() external {
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        address proxy = address(
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

        setPreorderStateForTest(proxy, 1, 1000 ether, 500 ether, uint40(block.timestamp));
        (uint256 totalFunds, uint256 settledMemecoin, uint40 ts) = getPreorderStateForTest(proxy, 1);
        assertEq(totalFunds, 1000 ether, "totalFunds");
        assertEq(settledMemecoin, 500 ether, "settledMemecoin");
        assertEq(ts, uint40(block.timestamp), "timestamp");
    }
}
