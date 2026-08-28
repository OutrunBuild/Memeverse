// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

/// @title Invariant Test Stubs
/// @notice Shared no-op stub contracts for invariant testing.
///         Unlike LauncherPOLendIntegrationMocks / POLendMocks (which are functional mocks for safety tests),
///         these stubs only provide interface skeletons without business logic.

abstract contract POLendInvariantStub {
    uint256 internal totalLeveragedDebt_;
    address internal pt_;
    address internal yt_;

    function setLendMarket(address pt, address yt) external {
        pt_ = pt;
        yt_ = yt;
    }

    function registerLendMarket(uint256) external {}

    function getTotalLeveragedDebt(uint256) external view returns (uint256) {
        return totalLeveragedDebt_;
    }

    function getTotalLeveragedInterest(uint256) external pure returns (uint256) {
        return 0;
    }

    function getLendMarket(uint256) external view returns (IPOLend.LendMarket memory market) {
        market.yt = yt_;
    }

    function finalizeLeveragedGenesis(uint256) external {}
    function recordLeveragedYT(uint256, address, uint256) external {}
    function markRefundable(uint256) external {}
    function executeGlobalSettlement(uint256) external {}

    function settlementDustStates(address) external pure returns (uint128, uint128) {
        return (0, 0);
    }

    function fundSettlementDustReserve(address, uint256) external {}
}

/// @notice Shared no-op splitter stub with deterministic pt/yt addresses.
contract POLSplitterInvariantStub {
    address internal immutable pt;
    address internal immutable yt;

    constructor(address pt_, address yt_) {
        pt = pt_;
        yt = yt_;
    }

    function initializeVerse(uint256, address, address, address, string calldata, string calldata)
        external
        view
        returns (address, address)
    {
        return (pt, yt);
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, address(0), address(0), address(0), 0, 0, 0, 0, 0, false);
    }

    function getPT(uint256) external view returns (address) {
        return pt;
    }

    function getYT(uint256) external view returns (address) {
        return yt;
    }

    function getMemecoin(uint256) external pure returns (address) {
        return address(0);
    }

    function getPTAndYT(uint256) external view returns (address, address) {
        return (pt, yt);
    }

    function getPTSettlementState(uint256) external view returns (address, bool) {
        return (pt, false);
    }

    function split(uint256, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount) {
        MockERC20(pt).mint(msg.sender, polAmount);
        MockERC20(yt).mint(msg.sender, polAmount);
        return (polAmount, polAmount);
    }

    function settle(uint256) external pure returns (uint256 settlementUAsset, uint256 settlementMemecoin) {
        return (0, 0);
    }

    function merge(uint256, uint256) external pure returns (uint256) {
        revert("unused");
    }

    function preRedeemPTFee(uint256, uint256) external pure returns (uint256 uAssetBacking) {
        return 0;
    }

    function redeemPT(uint256, uint256, address) external pure returns (uint256) {
        revert("unused");
    }

    function redeemYT(uint256, uint256, address) external pure returns (uint256, uint256) {
        revert("unused");
    }

    function previewRedeemYTUAsset(uint256, uint256) external pure returns (uint256 uAssetAmount) {
        return 0;
    }

    function recordPTBackingRatio(uint256, uint256, uint256) external {}
}
