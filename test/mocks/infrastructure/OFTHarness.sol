// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {OutrunOFTInit} from "../../../src/common/omnichain/oft/OutrunOFTInit.sol";

contract OFTHarness is OutrunOFTInit {
    constructor(address endpoint_) OutrunOFTInit(endpoint_) {}

    /// @notice Initialize.
    /// @param owner_ See implementation.
    /// @param name_ See implementation.
    /// @param symbol_ See implementation.
    /// @param delegate_ See implementation.
    function initialize(address owner_, string memory name_, string memory symbol_, address delegate_)
        external
        initializer
    {
        __OutrunOFT_init(name_, symbol_, delegate_);
        __OutrunOwnable_init(owner_);
    }

    /// @notice Mint test.
    /// @param to See implementation.
    /// @param amount See implementation.
    function mintTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Converts an LD amount to shared decimals via the OFT's conversion rate, mirroring OFT `_toSD`.
    ///         Single shared site for the LD→SD conversion across the test suites (OutrunOFTInit.t.sol and
    ///         YieldDispatcher.t.sol previously each defined their own copy).
    /// @param amountLD Local-decimals amount.
    /// @return amountSD Shared-decimals amount.
    function toSharedDecimals(uint256 amountLD) external view returns (uint64) {
        return uint64(amountLD / decimalConversionRate);
    }
}
