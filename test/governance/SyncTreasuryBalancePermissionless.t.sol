// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IGovernanceCycleIncentivizer} from "../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {MockIncentivizerGovernor} from "../mocks/governance/GovernanceMocks.sol";

/// @title SyncTreasuryBalancePermissionlessTest
/// @notice Verifies `syncTreasuryBalance` is permissionless yet still truthfully reconciles the ledger
/// and preserves its token-validation guards.
contract SyncTreasuryBalancePermissionlessTest is Test {
    // Unprivileged caller: not the governor, the incentivizer, or any admin.
    address internal constant ATTACKER = address(0xBAD);

    GovernanceCycleIncentivizerUpgradeable internal implementation;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockIncentivizerGovernor internal governor;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function setUp() external {
        implementation = new GovernanceCycleIncentivizerUpgradeable();
        governor = new MockIncentivizerGovernor();
        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        incentivizer = _deployIncentivizer(address(governor), address(tokenA));
        governor.setIncentivizer(address(incentivizer));

        vm.label(ATTACKER, "Attacker");
    }

    function _deployIncentivizer(address governorAddress, address initialToken)
        internal
        returns (GovernanceCycleIncentivizerUpgradeable deployed)
    {
        address[] memory initTokens = new address[](1);
        initTokens[0] = initialToken;
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(GovernanceCycleIncentivizerUpgradeable.initialize, (governorAddress, initTokens))
        );
        deployed = GovernanceCycleIncentivizerUpgradeable(address(proxy));
    }

    /// @notice An unprivileged caller reconciles a registered treasury token without reverting.
    /// @dev Before the permissionless change this call reverted with `PermissionDenied`; it must now
    /// succeed and write the truthful custody balance into the current cycle ledger.
    function test_PermissionlessCallerReconcilesRegisteredToken() external {
        tokenA.mint(address(governor), 100 ether);

        vm.prank(ATTACKER);
        incentivizer.syncTreasuryBalance(address(tokenA));

        // No previous-cycle reward reserve exists, so the ledger must equal governor custody (G).
        assertEq(incentivizer.getTreasuryBalance(1, address(tokenA)), 100 ether);
    }

    /// @notice A permissionless sync books a custody drift net of the previous cycle reward reserve.
    function test_PermissionlessSyncReflectsCustodyDriftNetOfRewardReserve() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        // Finalizing splits the 100 ether ledger 75/25: 25 ether reward reserve (R) is parked in cycle 1
        // while the governor still holds the full 100 ether (G).
        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        // A direct donation to the governor bypasses the ledger (drift); a permissionless sync must rebook
        // it net of R: 180 - 25 = 155.
        tokenA.mint(address(governor), 80 ether);

        vm.prank(ATTACKER);
        incentivizer.syncTreasuryBalance(address(tokenA));

        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 155 ether);
    }

    /// @notice Permissionless sync still rejects tokens that are not registered as treasury tokens.
    function test_RevertWhen_PermissionlessSyncTargetsUnregisteredToken() external {
        // Permissionless access must not bypass token-registration validation.
        vm.prank(ATTACKER);
        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        incentivizer.syncTreasuryBalance(address(tokenB));
    }

    /// @notice Permissionless sync still rejects a zero address argument.
    function test_RevertWhen_PermissionlessSyncTargetsZeroAddress() external {
        vm.prank(ATTACKER);
        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        incentivizer.syncTreasuryBalance(address(0));
    }
}
