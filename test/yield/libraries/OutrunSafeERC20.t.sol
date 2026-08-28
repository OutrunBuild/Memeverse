// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {OutrunSafeERC20} from "../../../src/common/token/OutrunSafeERC20.sol";
import {FalseApproveToken} from "../../mocks/common/CommonMocks.sol";
import {SilentApproveToken} from "../../mocks/infrastructure/SilentApproveToken.sol";
import {RevertingApproveToken} from "../../mocks/infrastructure/RevertingApproveToken.sol";

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

    /// @notice Calls `OutrunSafeERC20.safeApprove` on the provided token.
    /// @dev Test harness for exercising library behavior through an external call.
    /// @param token The token contract to call.
    /// @param spender The approved spender.
    /// @param value The approved amount.
    function safeApprove(IERC20 token, address spender, uint256 value) external {
        token.safeApprove(spender, value);
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

    /// @notice Verifies `safeApprove` passes for a standard token whose `approve` returns true.
    function test_SafeApprovePassesWhenApproveReturnsTrue() external {
        MockERC20 token = new MockERC20("Std", "STD", 18);

        harness.safeApprove(IERC20(address(token)), address(0xCAFE), 123);

        assertEq(token.allowance(address(harness), address(0xCAFE)), 123, "allowance recorded");
    }

    /// @notice Verifies `safeApprove` reverts `SafeERC20FailedOperation` when the token's `approve`
    ///         executes successfully but returns false.
    function test_RevertWhen_SafeApproveApproveReturnsFalse() external {
        FalseApproveToken token = new FalseApproveToken();

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, address(token)));
        harness.safeApprove(IERC20(address(token)), address(0xCAFE), 123);
    }

    /// @notice Verifies `safeApprove` reverts `SafeERC20FailedOperation` for a code-less token address:
    ///         the CALL succeeds with empty returndata, and only the extcodesize guard rejects it.
    function test_RevertWhen_SafeApproveTokenHasNoCodeAndReturnsEmptyData() external {
        address token = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, token));
        harness.safeApprove(IERC20(token), address(0xCAFE), 123);
    }

    /// @notice Verifies `safeApprove` reverts `SafeERC20FailedOperation` when the token has code but its
    ///         `approve` fails with empty revert data: a failed CALL must not be mistaken for the
    ///         empty-returndata-is-trusted case (that trust is reserved for calls that actually succeeded).
    function test_RevertWhen_SafeApproveApproveRevertsWithoutData() external {
        RevertingApproveToken token = new RevertingApproveToken();

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, address(token)));
        harness.safeApprove(IERC20(address(token)), address(0xCAFE), 123);
    }

    /// @notice Verifies `safeApprove` passes for a token with code whose `approve` returns no data —
    ///         empty returndata from a code-bearing token is trusted as success.
    function test_SafeApprovePassesWhenTokenWithCodeReturnsNoData() external {
        SilentApproveToken token = new SilentApproveToken();

        harness.safeApprove(IERC20(address(token)), address(0xCAFE), 456);

        assertEq(token.lastApproveSpender(), address(0xCAFE), "approve call landed on the token");
        assertEq(token.lastApproveValue(), 456, "approve value forwarded");
    }
}
