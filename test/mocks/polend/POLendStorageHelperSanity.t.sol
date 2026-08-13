// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";
import {POLendUpgradeable} from "../../../src/polend/POLendUpgradeable.sol";
import {POLendStorageHelper} from "./POLendStorageHelper.sol";

contract POLendStorageHelperSanityTest is Test, POLendStorageHelper {
    function test_slotRoundTrip_leveragedInterestPaidAndResidual() external {
        POLendUpgradeable impl = new POLendUpgradeable();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    POLendUpgradeable.initialize,
                    (address(this), 1e17, 10e18, address(this), address(this), address(this), address(this))
                )
            )
        );

        seedLeveragedPositionForTest(proxy, 1, address(0xBEEF), 42 ether);
        assertEq(
            POLendUpgradeable(proxy).leveragedInterestPaid(1, address(0xBEEF)),
            42 ether,
            "leveragedInterestPaid round-trip"
        );

        seedResidualForTest(proxy, 1, 200 ether, 100 ether, 40 ether);
        (uint256 residualUAsset, uint256 residualMemecoin) = POLendUpgradeable(proxy).residualStates(1);
        assertEq(residualUAsset, 200 ether, "residual uAsset");
        assertEq(residualMemecoin, 100 ether, "residual memecoin");

        IPOLend.LendMarket memory market = POLendUpgradeable(proxy).getLendMarket(1);
        assertEq(market.totalLeveragedInterest, 40 ether, "market interest");
        assertEq(uint256(market.state), uint256(IPOLend.MarketState.Settled), "market state settled");

        seedSettlementDustStateForTest(proxy, address(0xCAFE), uint128(7 ether), uint128(99 ether));
        (uint128 reserve, uint128 maxReserve) = POLendUpgradeable(proxy).settlementDustStates(address(0xCAFE));
        assertEq(reserve, uint128(7 ether), "dust reserve");
        assertEq(maxReserve, uint128(99 ether), "dust maxReserve");
    }
}
