// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

/// @title AtomicSessionAccount
/// @notice Minimal smart-account implementation used by the account-session regression tests.
/// @dev Models the supported, atomic, uncapturable account frame: a single external call into
///      `executeSession` opens the hook session, runs exactly one target call, and closes the session.
///      ANY revert from the target (or from the hook's begin/end/callback path) bubbles verbatim and reverts
///      the whole frame — there is no try/catch around the inner calls, so a begin-without-end can never
///      leak the session into the caller. This is the same all-success-or-all-revert guarantee the design
///      requires of a compliant account implementation. The contract deliberately carries no allowlist and
///      performs no implementation-authentication: it is a stand-in for any deployed contract account
///      (ERC-4337 smart account, Safe, or EIP-7702-delegated EOA) whose address is what the hook records.
contract AtomicSessionAccount {
    /// @notice Opens a hook session, runs one target call, then closes the session.
    /// @dev Begin → target.call → bubble original revert on failure → end. No try/catch: any failure
    ///      reverts the whole external frame so the session can never be left open after `executeSession`.
    ///      `endAccountSession` is reached only when the target call returned without reverting; if the
    ///      target itself calls `endAccountSession` (it should not) the outer `end` would observe an empty
    ///      session and revert with `AccountSessionNotActive`, which is the correct failure mode.
    /// @param hook The Memeverse hook whose session lifecycle is being driven.
    /// @param target The contract to call inside the session.
    /// @param targetCalldata Calldata forwarded to `target`.
    /// @return returndata The target call's raw return data.
    function executeSession(IMemeverseUniswapHook hook, address target, bytes calldata targetCalldata)
        external
        returns (bytes memory returndata)
    {
        hook.beginAccountSession();
        // Forward the call and bubble the original revert (selector + data) instead of a generic string.
        // Forward via a memory copy for readability; the calldata-offset path (`bytes calldata.offset`)
        // was already correct in solc 0.8.35 — for a `bytes[]` element it resolves to the absolute calldata
        // offset of the element's data region via head/tail offset chasing. The memory copy is a stylistic
        // refactor, not a bug fix, and keeps the forwarding path easy to follow.
        returndata = _copyToMemory(targetCalldata);
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(returndata, 0x20), mload(returndata), 0, 0)
        }
        // Capture the target's return data (or revert reason) into `returndata` for the caller / bubble path.
        assembly ("memory-safe") {
            let rdSize := returndatasize()
            returndata := mload(0x40)
            mstore(returndata, rdSize)
            returndatacopy(add(returndata, 0x20), 0, rdSize)
            mstore(0x40, add(add(returndata, 0x20), and(add(rdSize, 0x1f), not(0x1f))))
        }
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        hook.endAccountSession();
    }

    /// @dev Copies `data` into a freshly allocated `bytes memory` (length-prefixed) so the call forwarding
    ///      path relays the exact selector+args from a stable memory region. This is a readability refactor;
    ///      forwarding straight from `bytes calldata.offset` was already correct in solc 0.8.35 (it resolves
    ///      to the element's absolute data-region offset for a nested `bytes[]`).
    function _copyToMemory(bytes calldata data) internal pure returns (bytes memory out) {
        out = new bytes(data.length);
        assembly ("memory-safe") {
            calldatacopy(add(add(out, 0x20), 0), data.offset, data.length)
        }
    }

    /// @notice Convenience wrapper used by tests that need an ERC20 approval issued from this account.
    /// @dev The approval runs OUTSIDE the session frame; it is only a test helper, not part of the
    ///      identity flow.
    function approveToken(address token, address spender, uint256 amount) external {
        require(IERC20(token).approve(spender, amount), "approve failed");
    }
}

/// @title HandleOpsLikeEntryPoint
/// @notice Stand-in for an ERC-4337 Bundler / EntryPoint that sequentially executes account frames.
/// @dev Drives several `AtomicSessionAccount`s in one outer transaction to exercise cross-account session
///      isolation. `handleOps` is sequential, length-validated, and does NOT catch reverts: if any account
///      frame reverts, the whole `handleOps` reverts (matching the real all-or-nothing bundler semantics in
///      a single-storage-context simulation). `executeFrameCatching` is the single catching entry: it wraps
///      the ENTIRE external `account.executeSession(...)` call in try/catch so a negative test can assert a
///      frame reverted WITHOUT aborting the outer test transaction.
contract HandleOpsLikeEntryPoint {
    /// @notice Sequentially runs one session frame per account/target pair.
    /// @dev Length of `accounts`, `targets`, and `targetCalldatas` MUST match; reverts otherwise. The whole
    ///      call reverts if any inner frame reverts — this is the bundler semantics under test, NOT a bug.
    function handleOps(
        IMemeverseUniswapHook hook,
        AtomicSessionAccount[] calldata accounts,
        address[] calldata targets,
        bytes[] calldata targetCalldatas
    ) external {
        uint256 len = accounts.length;
        require(len == targets.length && len == targetCalldatas.length, "length mismatch");
        for (uint256 i = 0; i < len; i++) {
            accounts[i].executeSession(hook, targets[i], targetCalldatas[i]);
        }
    }

    /// @notice Runs ONE account session frame and catches the whole external call's revert.
    /// @dev Used only by negative tests that assert a specific revert on the frame WITHOUT aborting the
    ///      test. The try/catch surrounds the entire external `executeSession` call, so a begin-without-end
    ///      or a begin-that-reverts is fully isolated from the caller's transaction.
    function executeFrameCatching(
        AtomicSessionAccount account,
        IMemeverseUniswapHook hook,
        address target,
        bytes calldata targetCalldata
    ) external returns (bool ok, bytes memory returndata) {
        try account.executeSession(hook, target, targetCalldata) returns (bytes memory rd) {
            return (true, rd);
        } catch (bytes memory reason) {
            return (false, reason);
        }
    }
}

/// @title TargetCallSpy
/// @notice Minimal spy contract used as the in-session target call in account-session tests.
/// @dev Records whether `record` was reached inside a session frame. Callers place this as the
///      `target`/`targetCalldata` of `executeSession` to prove the frame reached the target only when the
///      full begin → target → end chain succeeded.
contract TargetCallSpy {
    bool public wasCalled;

    /// @notice Marks the spy as called. Intended as the in-session target payload.
    function record() external {
        wasCalled = true;
    }
}

/// @title NonCompliantSessionHelper
/// @notice Negative-path helpers for the unsupported begin-without-end flow.
/// @dev The design explicitly does NOT guarantee isolation when a caller skips begin or catches a begin
///      failure and then calls the Router anyway. These helpers expose exactly that unsupported flow so
///      tests can document the revert at `beginAccountSession` (or the absence of isolation) without
///      pretending it is a supported path.
contract NonCompliantSessionHelper {
    /// @notice Calls `beginAccountSession` and returns WITHOUT calling `end`. Used to drive
    ///         `endAccountSession` / next-frame-begin reverts.
    function beginWithoutEnd(IMemeverseUniswapHook hook) external {
        hook.beginAccountSession();
    }

    /// @notice Calls `beginAccountSession`, catches the revert, and then calls `target` regardless.
    /// @dev Documents the unsupported captured-failure-then-Router path. Returns the begin revert reason
    ///      so the caller can assert it, and the target returndata so the caller can inspect what happened.
    function catchBeginFailureThenCallTarget(IMemeverseUniswapHook hook, address target, bytes calldata targetCalldata)
        external
        returns (bool beginOk, bytes memory beginReason, bool targetOk, bytes memory targetReturndata)
    {
        try hook.beginAccountSession() {
            beginOk = true;
        } catch (bytes memory reason) {
            beginOk = false;
            beginReason = reason;
        }
        // Continue to the target deliberately — this is the unsupported path the design warns about.
        (targetOk, targetReturndata) = target.call(targetCalldata);
    }
}

/// @title BatchExecutor
/// @notice Plain external executor that calls the Hook+Router on a user's behalf.
/// @dev Models the UNSUPPORTED external-executor path: an unrelated contract `executor`
///      receives `A`'s intent and itself calls `hook.beginAccountSession()` / `hook.endAccountSession()`.
///      The Hook captures `msg.sender == address(executor)`, never `A`, so the resulting session is owned by
///      the executor — proving `A` cannot obtain `[A][poolId]` attribution through an external executor.
contract BatchExecutor {
    /// @notice Opens a hook session as THIS executor (the direct caller), runs one target call, then ends it.
    /// @dev Used by `test_externalBatchExecutorIsNotA` to demonstrate the executor becomes the principal,
    ///      NOT the user `A` whose funds/tokens were involved. The hook never sees `A` in this path.
    function executeAsSelf(IMemeverseUniswapHook hook, address target, bytes calldata targetCalldata)
        external
        returns (bool ok, bytes memory returndata)
    {
        hook.beginAccountSession();
        (ok, returndata) = target.call(targetCalldata);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        hook.endAccountSession();
    }
}
