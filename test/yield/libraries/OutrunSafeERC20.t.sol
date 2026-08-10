// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutrunSafeERC20} from "../../../src/common/token/OutrunSafeERC20.sol";

contract OutrunSafeERC20Harness {
    using OutrunSafeERC20 for IERC20;

    /// @notice Calls `OutrunSafeERC20.safeTransfer` on the provided token.
    /// @dev Test harness for exercising library behavior through an external call.
    /// @param token The token contract to call.
    /// @param to The transfer recipient.
    /// @param value The transfer amount.
    function safeTransfer(IERC20 token, address to, uint256 value) external {
        token.safeTransfer(to, value);
    }

    /// @notice Calls `OutrunSafeERC20.safeTransferFrom` on the provided token.
    /// @dev Test harness for exercising library behavior through an external call.
    /// @param token The token contract to call.
    /// @param from The transfer sender.
    /// @param to The transfer recipient.
    /// @param value The transfer amount.
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) external {
        token.safeTransferFrom(from, to, value);
    }
}

contract OutrunSafeERC20Test is Test {
    OutrunSafeERC20Harness internal harness;

    /// @notice Deploys a fresh harness for each test case.
    /// @dev Keeps each revert assertion isolated from prior calls.
    function setUp() external {
        harness = new OutrunSafeERC20Harness();
    }

    /// @notice Verifies no-code token targets revert with `SafeERC20FailedOperation` on `safeTransfer`.
    /// @dev Locks the OZ v5.5 failure semantics for invalid token addresses.
    function testSafeTransferRevertsWithSafeERC20FailedOperationForAddressWithoutCode() external {
        address token = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, token));
        harness.safeTransfer(IERC20(token), address(this), 1);
    }

    /// @notice Verifies no-code token targets revert with `SafeERC20FailedOperation` on `safeTransferFrom`.
    /// @dev Locks the OZ v5.5 failure semantics for invalid token addresses.
    function testSafeTransferFromRevertsWithSafeERC20FailedOperationForAddressWithoutCode() external {
        address token = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, token));
        harness.safeTransferFrom(IERC20(token), address(this), address(0xCAFE), 1);
    }
}
