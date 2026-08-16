// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BurnableMockERC20} from "../polend/POLendMocks.sol";

/// @notice `BurnableMockERC20` variant whose transfer surface can be paused, standing in for the
///         real `GenesisCredit` (OZ `ERC20Pausable`) in POLend integration tests. `pause`/`unpause`
///         are owner-only, mirroring GenesisCredit's OZ `Ownable` emergency switch, and a paused
///         token reverts `transfer`/`transferFrom` with the same OZ `EnforcedPause` error, so
///         revert-selector assertions against POLend's credit paths hold against real behavior.
/// @dev    Only the two pull/push entry points POLend actually calls on the credit token are gated.
///         Like OZ `ERC20Pausable` (which gates `_update` but not `approve`), approvals stay live
///         while paused, so tests can arm allowances before pausing. `mint`/`burn` are left open:
///         no POLend-side pause scenario mints or burns credit while paused (pause-blocked
///         self-burn is already pinned against the real token in GenesisCredit.t.sol).
contract PausableBurnableMockERC20 is BurnableMockERC20, Ownable, Pausable {
    /// @param name_ Human-readable token name.
    /// @param symbol_ Token ticker.
    /// @param owner_ Account empowered to pause/unpause (the credit-token admin in tests).
    constructor(string memory name_, string memory symbol_, address owner_)
        BurnableMockERC20(name_, symbol_)
        Ownable(owner_)
    {}

    /// @notice Owner-only emergency stop: `transfer`/`transferFrom` revert `EnforcedPause`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Owner-only: lifts the pause. Reverts OZ `ExpectedPause` when not paused.
    function unpause() external onlyOwner {
        _unpause();
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (paused()) revert EnforcedPause();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (paused()) revert EnforcedPause();
        return super.transferFrom(from, to, amount);
    }
}
