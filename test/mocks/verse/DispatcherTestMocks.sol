// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {YieldDispatcherUpgradeable} from "../../../src/verse/YieldDispatcherUpgradeable.sol";
import {IYieldDispatcher} from "../../../src/verse/interfaces/IYieldDispatcher.sol";

import {YieldDispatcherMockBase} from "./YieldDispatcherMockBase.sol";

/// @notice Vault, governor, and reentrancy mocks for the YieldDispatcherUpgradeable settle path.
///         The vault and governor mocks inherit the shared failure-switch / compose-probe base so
///         the settle-fail rollback and CEI write-order contracts stay pinned in one mechanism.
contract MockDispatcherYieldVault is YieldDispatcherMockBase {
    uint256 public lastAccumulatedAmount;
    bool public accumulateYieldsCalled;

    constructor(address token_) YieldDispatcherMockBase(token_) {}

    /// @notice Accumulate yields — mirrors the real vault: pull the approved tokens from the caller, then record.
    /// @param amount See implementation.
    function accumulateYields(uint256 amount) external {
        require(!shouldRevert, "settle failed");
        _checkComposeProbes(token);
        // Pin "callback entered" separately from the recorded amount: lastAccumulatedAmount cannot distinguish
        // called-with-0 from never-called, and the real vault early-returns on 0 before recording anything.
        accumulateYieldsCalled = true;
        // Mirror MemecoinYieldVault.accumulateYields: pull via transferFrom from msg.sender (the dispatcher).
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        lastAccumulatedAmount = amount;
    }
}

contract MockDispatcherGovernor is YieldDispatcherMockBase {
    address public lastToken;
    uint256 public lastAmount;

    constructor(address token_) YieldDispatcherMockBase(token_) {}

    /// @notice Receive treasury income — mirrors the real governor: pull the approved tokens from the caller, then record.
    /// @param token_ See implementation.
    /// @param amount See implementation.
    function receiveTreasuryIncome(address token_, uint256 amount) external {
        require(!shouldRevert, "settle failed");
        _checkComposeProbes(token_);
        // Mirror GovernanceCycleIncentivizerUpgradeable.recordTreasuryIncome's ZeroInput guard: production reverts
        // ZeroInput on amount == 0 unconditionally, so the mock does too — deleting the _settle zero-amount
        // short-circuit makes this test fail exactly as production would.
        if (amount == 0) revert IYieldDispatcher.ZeroInput();
        // Mirror MemecoinDaoGovernorUpgradeable.receiveTreasuryIncome: pull via transferFrom from msg.sender (the dispatcher).
        MockERC20(token_).transferFrom(msg.sender, address(this), amount);
        lastToken = token_;
        lastAmount = amount;
    }
}

/// @notice Malicious vault that reenters the dispatcher's `settlePendingCompose` from inside its `accumulateYields`
///         callback. Used to pin the dispatcher's reentrancy defense on the approve+callback path: unlike the staker's
///         `_transferOut` path, the dispatcher's `_settleToContract` has no `nonReentrant`, so the defense is the
///         `composeStates` mutex — a same-guid reentry reverts `AlreadyResolved`, not `ReentrancyGuardReentrantCall`.
contract ReentrantDispatcherVault {
    address public token;
    YieldDispatcherUpgradeable internal immutable dispatcher;
    address internal reentryToken;
    bytes32 internal reentryGuid;
    bytes internal reentryMessage;

    constructor(address token_, address dispatcher_) {
        token = token_;
        dispatcher = YieldDispatcherUpgradeable(dispatcher_);
    }

    /// @notice Arm the reentry attempt with the same (token, guid, message) the outer settle is processing.
    function armReentry(address token_, bytes32 guid_, bytes memory message_) external {
        reentryToken = token_;
        reentryGuid = guid_;
        reentryMessage = message_;
    }

    /// @notice The `_settleToContract` callback. Reenters `settlePendingCompose` with the same guid mid-call.
    function accumulateYields(uint256) external {
        dispatcher.settlePendingCompose(reentryToken, reentryGuid, reentryMessage);
    }

    /// @notice Mirrors a MEMECOIN vault's `asset()` so this mock is structurally interchangeable with the vault type.
    function asset() external view returns (address) {
        return token;
    }
}
