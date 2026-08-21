// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {POLendInvariantStub} from "./LauncherInvariantStubs.sol";

/// @notice POLend stub with a runtime-configurable total leveraged debt.
/// @dev The shared POLendInvariantStub returns a fixed internal value with no setter;
///      the fundraising-boundary tests vary `getTotalLeveragedDebt` to explore the
///      combined genesis cap (normalFunds + debt <= 2^128 - 1) across debt levels.
contract ConfigurableDebtPOLendStub is POLendInvariantStub {
    function setTotalLeveragedDebt(uint256 debt) external {
        totalLeveragedDebt_ = debt;
    }
}
