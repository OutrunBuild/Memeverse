// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {POLSplitterUpgradeable} from "../../../src/polend/POLSplitterUpgradeable.sol";
import {PrincipalToken} from "../../../src/polend/tokens/PrincipalToken.sol";
import {YieldToken} from "../../../src/polend/tokens/YieldToken.sol";
import {POLSplitterStorageHelper} from "./POLSplitterStorageHelper.sol";

/// @dev Minimal launcher stand-in so POLSplitterUpgradeable.initialize + initializeVerse succeed without the real launcher.
contract POLSplitterStorageHelperFakeLauncher {
    address private _polend;

    function setPolend(address p) external {
        _polend = p;
    }

    function polend() external view returns (address) {
        return _polend;
    }
}

contract POLSplitterStorageHelperSanityTest is Test, POLSplitterStorageHelper {
    function test_slotRoundTrip_mockSettledAndMints() external {
        POLSplitterStorageHelperFakeLauncher fakeLauncher = new POLSplitterStorageHelperFakeLauncher();
        POLSplitterUpgradeable impl = new POLSplitterUpgradeable();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(POLSplitterUpgradeable.initialize, (address(this), address(fakeLauncher)))
            )
        );

        vm.prank(address(fakeLauncher));
        POLSplitterUpgradeable(proxy).initializeVerse(7, address(0xA1), address(0xA2), address(0xA3), "Verse", "VRS");

        mockSettledForTest(proxy, 7, 900 ether, 400 ether);
        (,,,,,, uint256 settlementUAsset, uint256 settlementMemecoin,,, bool settled) =
            POLSplitterUpgradeable(proxy).splitInfos(7);
        assertEq(settlementUAsset, 900 ether, "settlement uAsset round-trip");
        assertEq(settlementMemecoin, 400 ether, "settlement memecoin round-trip");
        assertTrue(settled, "settled round-trip");

        address to = address(0xBEEF);
        mintPTForTest(proxy, 7, to, 12 ether);
        mintYTForTest(proxy, 7, to, 34 ether);
        (address pt, address yt) = POLSplitterUpgradeable(proxy).getPTAndYT(7);
        assertEq(PrincipalToken(pt).balanceOf(to), 12 ether, "pt minted");
        assertEq(YieldToken(yt).balanceOf(to), 34 ether, "yt minted");
    }
}
