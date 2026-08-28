// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";

/// @dev Test boundary:
/// - These cases lock the read-only `isWithdrawReachable` simulation against the state-changing
///   `withdraw` scan: both share the same FIFO maturity skip, ceil-then-decrement share math
///   (`ceil((T+1)*S/L) - 1`), and swap-pop compaction.
/// - Rates are kept 1:1 (totalAssets == totalSupply) except the dust and non-unit-rate cases, which
///   engineer a locked-per-share rate above 1 to reach the takeShares == 0 branch and pin the ceil
///   inverse of the lock rate respectively.
contract MemeverseYieldVaultWithdrawReachabilityTest is Test {
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);
    address internal constant YIELD_SOURCE = address(0xFEED);
    /// @dev Same virtual buffer as the main vault suite (V = 100 ether) so cross-suite rates stay comparable.
    uint256 internal constant VIRTUAL_ASSETS = 100 ether;

    MockERC20 internal asset;
    MemecoinYieldVault internal vault;

    /// @notice Deploys a fresh vault clone and seeds the attacker balance.
    /// @dev Reuses the production initializer path so tests exercise clone semantics.
    function setUp() external {
        asset = new MockERC20("Memecoin", "MEME", 18);
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(implementation)));
        vault.initialize("Staked Memecoin", "sMEME", address(asset), 1, VIRTUAL_ASSETS);

        asset.mint(ATTACKER, 1_001 ether);
        vm.prank(ATTACKER);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @notice Zero assets are never reachable, even with a fully matured queue.
    function test_IsWithdrawReachableReturnsFalseForZeroAssets() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.requestRedeem(shares, ATTACKER, ATTACKER);
        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        assertFalse(vault.isWithdrawReachable(ATTACKER, 0), "zero assets must be unreachable");
    }

    /// @notice An empty request queue can never satisfy a non-zero target.
    function test_IsWithdrawReachableReturnsFalseWhenQueueIsEmpty() external {
        assertFalse(vault.isWithdrawReachable(VICTIM, 1 ether), "empty queue must be unreachable");
    }

    /// @notice Entries still inside REDEEM_DELAY are skipped, so a target equal to their locked assets
    ///         is unreachable one second before maturity.
    function test_IsWithdrawReachableSkipsImmatureEntryBeforeDelayElapses() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(shares, ATTACKER, ATTACKER);

        vm.warp(block.timestamp + vault.REDEEM_DELAY() - 1);

        assertFalse(vault.isWithdrawReachable(ATTACKER, lockedAssets), "immature entry must not cover the target");
    }

    /// @notice A single matured entry covers a target up to its locked assets: exactly at the locked
    ///         amount (maturity boundary `>= requestTime + REDEEM_DELAY`) and partially below it.
    function test_IsWithdrawReachableCoversTargetFromSingleMaturedEntry() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(shares, ATTACKER, ATTACKER);

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        assertTrue(vault.isWithdrawReachable(ATTACKER, lockedAssets), "exact locked amount is reachable");
        assertTrue(vault.isWithdrawReachable(ATTACKER, 4 ether), "partial target below locked is reachable");
    }

    /// @notice A target above the single entry's locked assets exhausts the queue with a remainder and
    ///         is unreachable (the simulation reports it instead of under-paying).
    function test_IsWithdrawReachableReturnsFalseWhenQueueCannotCoverTarget() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(shares, ATTACKER, ATTACKER);
        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        assertFalse(
            vault.isWithdrawReachable(ATTACKER, lockedAssets + 2 ether),
            "target above locked assets must be unreachable"
        );
    }

    /// @notice The dust rounding branch: when the target is so small that the largest share count whose
    ///         payout stays within it rounds to zero (`ceil((T+1)*S/L) - 1 == 0`), the entry is skipped
    ///         and the target is unreachable — even though `maxWithdraw` reports the full locked amount.
    /// @dev Hand-calculated with V = 100 ether: deposit of 1 wei mints 1 share; a 1_000 ether yield
    ///      lifts totalAssets to 1_000 ether + 1 wei, so `requestRedeem(1)` locks
    ///      floor((1_000e18 + 1 + 100e18) / (1 + 100e18)) = 10 wei for 1 share. For T = 1:
    ///      ceil(2 * 1 / 10) - 1 = 0, so the entry is skipped.
    function test_IsWithdrawReachableSkipsEntryWhenShareRoundingLeavesNothing() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(1, ATTACKER);
        assertEq(shares, 1, "fixture: 1 wei deposit mints exactly 1 share");

        asset.mint(YIELD_SOURCE, 1_000 ether);
        vm.startPrank(YIELD_SOURCE);
        asset.approve(address(vault), 1_000 ether);
        vault.accumulateYields(1_000 ether);
        vm.stopPrank();

        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(shares, ATTACKER, ATTACKER);
        assertEq(lockedAssets, 10, "fixture: lock rate is 10 assets per share");

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        assertEq(vault.maxWithdraw(ATTACKER), 10, "maxWithdraw ignores share rounding");
        assertFalse(vault.isWithdrawReachable(ATTACKER, 1), "1 wei target rounds to zero shares");
    }

    /// @notice A partial target at a non-1:1 lock rate is covered exactly only through the ceil inverse
    ///         (`ceil((T+1)*S/L) - 1`); the naive `floor(T*S/L)` under-counts shares at rounding edges and
    ///         would report this reachable target as unreachable.
    /// @dev Hand-calculated with V = 100 ether: a 7 wei deposit mints 7 shares (empty vault — the V buffer
    ///      cancels on both sides), a 50 ether yield lifts totalAssets to 50 ether + 7 wei, and the 7-share
    ///      request locks floor(7 * (50e18 + 7 + 100e18) / (7 + 100e18)) = 10 wei, a 10/7 locked-per-share
    ///      rate. For T = 4: ceil(5 * 7 / 10) - 1 = 3 shares pay floor(3 * 10 / 7) = 4 — covered exactly.
    ///      The naive floor(4 * 7 / 10) = 2 shares pay only floor(2 * 10 / 7) = 2 and strand a 2 wei
    ///      remainder the queue can never satisfy, flipping the result to unreachable.
    function test_IsWithdrawReachableCoversPartialTargetAtNonUnitLockRate() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(7, ATTACKER);
        assertEq(shares, 7, "fixture: 7 wei deposit mints exactly 7 shares");

        asset.mint(YIELD_SOURCE, 50 ether);
        vm.startPrank(YIELD_SOURCE);
        asset.approve(address(vault), 50 ether);
        vault.accumulateYields(50 ether);
        vm.stopPrank();

        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(shares, ATTACKER, ATTACKER);
        assertEq(lockedAssets, 10, "fixture: lock rate is 10 assets per 7 shares");

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        assertTrue(vault.isWithdrawReachable(ATTACKER, 4), "4 wei target needs the ceil inverse to be covered");
    }

    /// @notice Swap-pop compaction inside the simulation must carry the swapped-in entry's own maturity:
    ///         after a matured head entry is consumed, the immature tail entry swapped into its slot stays
    ///         unclaimable and cannot cover the leftover target.
    /// @dev The second entry is requested at the current block timestamp, so it sits a full REDEEM_DELAY
    ///      away from maturity when the head entry is consumed. If the memory copy of `requestTimes` were
    ///      dropped during the swap-pop, the swapped-in entry would inherit the head's matured timestamp
    ///      and wrongly cover the +1 wei remainder (a 1:1 entry pays a 1 wei remainder exactly).
    function test_IsWithdrawReachableSwapPopCarriesSwappedInEntryMaturity() external {
        vm.prank(ATTACKER);
        vault.deposit(20 ether, ATTACKER);

        vm.prank(ATTACKER);
        uint256 firstLocked = vault.requestRedeem(10 ether, ATTACKER, ATTACKER);
        assertEq(firstLocked, 10 ether, "fixture: first entry locks 10 ether");

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        vm.prank(ATTACKER);
        uint256 secondLocked = vault.requestRedeem(10 ether, ATTACKER, ATTACKER);
        assertEq(secondLocked, 10 ether, "fixture: second entry locks 10 ether");

        (, uint64 secondRequestTime,) = vault.redeemRequestQueues(ATTACKER, 1);
        assertEq(secondRequestTime, uint64(block.timestamp), "fixture: second entry still inside the delay");

        assertTrue(vault.isWithdrawReachable(ATTACKER, firstLocked), "head entry alone covers its locked amount");
        assertFalse(
            vault.isWithdrawReachable(ATTACKER, firstLocked + 1),
            "swapped-in immature entry must not cover the remainder"
        );
    }

    /// @notice With two matured entries, the first entry is fully consumed (swap-pop compaction) and the
    ///         second covers the remainder; both combined-cover and over-target boundaries are pinned.
    /// @dev Both entries lock 10 ether for 10 ether shares at a 1:1 rate. For a 15 ether target: the
    ///      first entry pays 10 ether and is popped, the second pays 5 ether — reachable. For exactly
    ///      20 ether both entries are consumed (including the no-copy pop when i == len - 1); 21 ether
    ///      leaves a remainder.
    function test_IsWithdrawReachableExhaustsFirstEntryAndCoversRemainderFromSecond() external {
        (uint256 firstLocked, uint256 secondLocked) = _queueTwoMaturedRequests();
        assertEq(firstLocked, 10 ether, "fixture: first entry locks 10 ether");
        assertEq(secondLocked, 10 ether, "fixture: second entry locks 10 ether");

        assertTrue(vault.isWithdrawReachable(ATTACKER, 15 ether), "second entry must cover the remainder");
        assertTrue(vault.isWithdrawReachable(ATTACKER, 20 ether), "both entries fully consumed is reachable");
        assertFalse(vault.isWithdrawReachable(ATTACKER, 21 ether), "target above both entries is unreachable");
    }

    /// @notice Cross-validates the view against the state-changing call: the same target that reads
    ///         reachable succeeds in `withdraw`, and after the withdraw the consumed state reads
    ///         unreachable while the residual entry still covers its own locked remainder.
    function test_IsWithdrawReachableMatchesActualWithdrawOutcome() external {
        _queueTwoMaturedRequests();

        assertTrue(vault.isWithdrawReachable(ATTACKER, 15 ether), "15 ether reachable before withdraw");

        uint256 balanceBefore = asset.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 burnedShares = vault.withdraw(15 ether, ATTACKER, ATTACKER);

        assertEq(burnedShares, 15 ether, "shares consumed at the 1:1 lock rate");
        assertEq(asset.balanceOf(ATTACKER) - balanceBefore, 15 ether, "payout transferred");

        assertFalse(vault.isWithdrawReachable(ATTACKER, 15 ether), "consumed queue no longer covers 15 ether");
        assertTrue(vault.isWithdrawReachable(ATTACKER, 5 ether), "residual entry still covers its remainder");

        // The first entry was popped, so the queue shrank to a single residual entry.
        (uint192 remainingLocked,, uint256 remainingShares) = vault.redeemRequestQueues(ATTACKER, 0);
        assertEq(uint256(remainingLocked), 5 ether, "residual locked assets");
        assertEq(remainingShares, 5 ether, "residual shares");
        vm.expectRevert();
        vault.redeemRequestQueues(ATTACKER, 1);
    }

    /// @notice Queues two fully matured requests of 10 ether each: deposit 20 ether (1:1 rate), request
    ///         half, warp a full delay, request the other half, warp again so both are matured.
    function _queueTwoMaturedRequests() internal returns (uint256 firstLocked, uint256 secondLocked) {
        vm.prank(ATTACKER);
        vault.deposit(20 ether, ATTACKER);

        vm.prank(ATTACKER);
        firstLocked = vault.requestRedeem(10 ether, ATTACKER, ATTACKER);
        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        vm.prank(ATTACKER);
        secondLocked = vault.requestRedeem(10 ether, ATTACKER, ATTACKER);
        vm.warp(block.timestamp + vault.REDEEM_DELAY());
    }
}
