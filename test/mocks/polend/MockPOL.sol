// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

/// @notice Shared POL token mock exposing its paired memecoin address.
/// @dev Single canonical definition shared by the POLendUpgradeable and POLSplitterUpgradeable test suites.
contract MockPOL is MockERC20 {
    address public memecoin;

    constructor(address memecoin_) MockERC20("POL", "POL", 18) {
        memecoin = memecoin_;
    }
}
