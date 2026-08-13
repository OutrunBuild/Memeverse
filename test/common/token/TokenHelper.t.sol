// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {TokenHelper} from "../../../src/common/token/TokenHelper.sol";
import {FalseApproveToken, RejectETHReceiver} from "../../mocks/common/CommonMocks.sol";
import {TokenHelperHarness} from "../../mocks/infrastructure/TokenHelperHarness.sol";

contract TokenHelperTest is Test {
    TokenHelperHarness internal harness;

    /// @dev Mirror of TokenHelper.NATIVE / LOWER_BOUND_APPROVAL (both are internal).
    address internal constant NATIVE = address(0);
    uint256 internal constant LOWER_BOUND_APPROVAL = type(uint96).max / 2;

    MockERC20 internal token;

    function setUp() external {
        harness = new TokenHelperHarness();
        token = new MockERC20("Test Token", "TST", 18);
    }

    function testTransferInNativeRevertsWithNativeValueMismatch() external {
        vm.expectRevert(abi.encodeWithSelector(TokenHelper.NativeValueMismatch.selector, 1 ether, 0.5 ether));
        harness.transferInNative{value: 0.5 ether}(1 ether);
    }

    function testTransferInNativeSucceeds() external {
        // Positive path: msg.value == amount passes the require, native value is received by the harness.
        uint256 amount = 1 ether;
        uint256 startBalance = address(harness).balance;

        harness.transferInNative{value: amount}(amount);

        assertEq(address(harness).balance, startBalance + amount);
    }

    function testTransferInERC20MovesFunds() external {
        uint256 amount = 1 ether;
        token.mint(address(this), amount);
        token.approve(address(harness), amount);

        harness.transferInERC20(address(token), address(this), amount);

        assertEq(token.balanceOf(address(harness)), amount);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testTransferInERC20ZeroAmountSkipsTransfer() external {
        // amount == 0 is an early skip, so no approval is required and balances stay put.
        uint256 harnessBalance = token.balanceOf(address(harness));
        uint256 callerBalance = token.balanceOf(address(this));

        harness.transferInERC20(address(token), address(this), 0);

        assertEq(token.balanceOf(address(harness)), harnessBalance);
        assertEq(token.balanceOf(address(this)), callerBalance);
    }

    function testTransferOutNativeRevertsWithNativeTransferFailed() external {
        RejectETHReceiver receiver = new RejectETHReceiver();
        vm.deal(address(harness), 1 ether);

        vm.expectRevert(TokenHelper.NativeTransferFailed.selector);
        harness.transferOutNative(address(receiver), 1 ether);
    }

    function testTransferOutNativeSucceeds() external {
        address receiver = makeAddr("receiver");
        uint256 amount = 1 ether;
        vm.deal(address(harness), amount);

        harness.transferOutNative(receiver, amount);

        assertEq(receiver.balance, amount);
    }

    function testTransferOutERC20MovesFunds() external {
        address recipient = makeAddr("recipient");
        uint256 amount = 1 ether;
        token.mint(address(harness), amount);

        harness.transferOutERC20(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    function testTransferOutERC20ZeroAmountEarlyReturns() external {
        address recipient = makeAddr("recipient");
        token.mint(address(harness), 1 ether);
        uint256 harnessBalance = token.balanceOf(address(harness));

        harness.transferOutERC20(address(token), recipient, 0);

        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(harness)), harnessBalance);
    }

    function testSafeApproveRevertsWithSafeApproveFailed() external {
        FalseApproveToken falseApprove = new FalseApproveToken();

        vm.expectRevert(
            abi.encodeWithSelector(TokenHelper.SafeApproveFailed.selector, address(falseApprove), address(this), 123)
        );
        harness.safeApproveToken(address(falseApprove), address(this), 123);
    }

    function testSafeApproveSetsAllowance() external {
        address spender = makeAddr("spender");
        uint256 value = 42 ether;

        harness.safeApproveToken(address(token), spender, value);

        assertEq(token.allowance(address(harness), spender), value);
    }

    function testSafeApproveInfBelowLowerBoundApprovesMax() external {
        // Initial allowance is 0 (< LOWER_BOUND_APPROVAL), so _safeApproveInf resets to max.
        address spender = makeAddr("spender");
        assertEq(token.allowance(address(harness), spender), 0);

        harness.safeApproveInf(address(token), spender);

        assertEq(token.allowance(address(harness), spender), type(uint256).max);
    }

    function testSafeApproveInfZeroAllowanceOmitsRedundantApproveZero() external {
        // The optimization itself: when current allowance is 0, _safeApproveInf must issue only
        // approve(spender, max) and NOT the redundant same-value approve(spender, 0). This fails if
        // the optimization is reverted, because the old code would emit an extra Approval(spender, 0).
        address spender = makeAddr("spender");
        assertEq(token.allowance(address(harness), spender), 0);

        vm.recordLogs();
        harness.safeApproveInf(address(token), spender);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 approvalTopic = keccak256("Approval(address,address,uint256)");
        bytes32 spenderTopic = bytes32(uint256(uint160(spender)));
        uint256 zeroApprovals;
        uint256 maxApprovals;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != approvalTopic || logs[i].topics[2] != spenderTopic) continue;
            uint256 value = abi.decode(logs[i].data, (uint256));
            if (value == 0) {
                ++zeroApprovals;
            } else if (value == type(uint256).max) {
                ++maxApprovals;
            }
        }
        assertEq(zeroApprovals, 0, "zero-allowance path must not emit a redundant Approval(spender, 0)");
        assertEq(maxApprovals, 1, "zero-allowance path must emit exactly one Approval(spender, max)");
    }

    function testSafeApproveInfNonZeroBelowLowerBoundResetsToMax() external {
        // A non-zero allowance below the lower bound must still reset to 0 before re-setting max.
        // The fix only skips the reset when the current allowance is already 0 (a same-value no-op);
        // USDT-style tokens require this reset on non-zero -> non-zero transitions.
        address spender = makeAddr("spender");
        uint256 smallAllowance = 1 ether; // non-zero, well below LOWER_BOUND_APPROVAL
        harness.safeApproveToken(address(token), spender, smallAllowance);
        assertEq(token.allowance(address(harness), spender), smallAllowance);

        // The intermediate reset-to-0 call must still fire for a non-zero current allowance.
        vm.expectCall(address(token), abi.encodeWithSignature("approve(address,uint256)", spender, 0));

        harness.safeApproveInf(address(token), spender);

        assertEq(token.allowance(address(harness), spender), type(uint256).max);
    }

    function testSafeApproveInfAtLowerBoundIsSuppressed() external {
        // Pre-set allowance to exactly LOWER_BOUND_APPROVAL. The guard is strict `<`, so this
        // branch must be skipped: allowance is NOT reset to max.
        address spender = makeAddr("spender");
        harness.safeApproveToken(address(token), spender, LOWER_BOUND_APPROVAL);

        harness.safeApproveInf(address(token), spender);

        assertEq(token.allowance(address(harness), spender), LOWER_BOUND_APPROVAL);
    }

    function testSafeApproveInfNativeIsNoop() external {
        // NATIVE short-circuits before reading allowance; only requirement is no revert.
        address spender = makeAddr("spender");
        harness.safeApproveInf(NATIVE, spender);
    }

    function testTransferFromMovesFunds() external {
        address from = makeAddr("from");
        address to = makeAddr("to");
        uint256 amount = 1 ether;
        token.mint(from, amount);
        vm.prank(from);
        token.approve(address(harness), amount);

        harness.transferFrom(address(token), from, to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(from), 0);
    }

    function testTransferFromZeroAmountSkipsTransfer() external {
        // amount == 0 skips the internal safeTransferFrom; no approval needed, balances unchanged.
        address from = makeAddr("from");
        address to = makeAddr("to");
        uint256 fromBalance = token.balanceOf(from);
        uint256 toBalance = token.balanceOf(to);

        harness.transferFrom(address(token), from, to, 0);

        assertEq(token.balanceOf(from), fromBalance);
        assertEq(token.balanceOf(to), toBalance);
    }
}
