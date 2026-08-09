// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IBurnable} from "../../../src/common/interfaces/IBurnable.sol";

/// @notice MockERC20-style token whose single-arg `burn(uint256)` is a NO-OP (empty body: no `_burn`, no balance
///         movement), mirroring the "fallback 吸收 / 空实现 burn" uAsset class in the dispatcher's EOA-settle branch.
/// @dev The dispatcher's `IBurnable(token).burn(amount)` call succeeds and `burnedAtDispatcher` reports true while nothing
///      moves — the silent false-report terminal class documented in operations.md §3.13, used by
///      YieldDispatcherUAssetEoaBranchTest. The inherited solmate `MockERC20.burn(address,uint256)` two-arg
///      overload genuinely burns but is not on the dispatcher's call path — only the single-arg `IBurnable` entry
///      is used (same precedent as MockDispatcherComposeToken). Distinct from MockDispatcherComposeToken, whose
///      `burnShouldRevert` switch models the revert-pin class (an owner-only/absent burn that reverts the whole
///      settle call).
contract NoOpBurnToken is MockERC20, IBurnable {
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    /// @notice Burn — deliberately a no-op: accepts the amount and moves nothing.
    /// @param amount Ignored: no balance movement occurs.
    function burn(uint256 amount) external {
        amount;
    }
}
