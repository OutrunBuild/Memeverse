// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IGovernanceCycleIncentivizer} from "../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {MockIncentivizerGovernor} from "../mocks/governance/GovernanceMocks.sol";
import {ReentrantRewardToken} from "../mocks/governance/ReentrantRewardToken.sol";
import {ReentrantBalanceOfToken} from "../mocks/governance/ReentrantBalanceOfToken.sol";
import {GovernanceCycleIncentivizerUpgradeableV2} from "../mocks/upgrade/GovernanceCycleIncentivizerUpgradeableV2.sol";

contract GovernanceCycleIncentivizerUpgradeableTest is Test {
    address internal constant OTHER = address(0xBEEF);

    GovernanceCycleIncentivizerUpgradeable internal implementation;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockIncentivizerGovernor internal governor;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    /// @notice Set up.
    function setUp() external {
        implementation = new GovernanceCycleIncentivizerUpgradeable();
        governor = new MockIncentivizerGovernor();
        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        incentivizer = _deployIncentivizer(address(governor), address(tokenA));
        governor.setIncentivizer(address(incentivizer));
    }

    function testUpgradeToAndCallRequiresGovernorAndUpgradesProxy() external {
        GovernanceCycleIncentivizerUpgradeable governedIncentivizer = _deployIncentivizer(OTHER, address(tokenA));
        GovernanceCycleIncentivizerUpgradeableV2 newImplementation = new GovernanceCycleIncentivizerUpgradeableV2();

        vm.expectRevert(IGovernanceCycleIncentivizer.PermissionDenied.selector);
        governedIncentivizer.upgradeToAndCall(address(newImplementation), bytes(""));

        // V2 shell does not inherit the incentivizer, so currentCycleId is read directly from its erc7201
        // storage slot. _currentCycleId is the high 128 bits of the first slot of
        // GovernanceCycleIncentivizerStorage (packed with _rewardRatio in the low 128 bits).
        bytes32 cycleSlot = bytes32(uint256(0x99c67075de64491849821c50466dd705dae8bfdda77a190b7f78ed5af150e100));
        bytes32 cycleBefore = vm.load(address(governedIncentivizer), cycleSlot);
        // _rewardRatio is the low 128 bits of the packed slot (_currentCycleId occupies the high 128 bits);
        // the initializer seeds it to 2500.
        uint128 expectedRewardRatio = uint128(uint256(cycleBefore));

        vm.prank(OTHER);
        governedIncentivizer.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(GovernanceCycleIncentivizerUpgradeableV2(address(governedIncentivizer)).upgradeVersion(), 2);
        // Storage must survive the upgrade: same slot, same value.
        assertEq(vm.load(address(governedIncentivizer), cycleSlot), cycleBefore);
        // _rewardRatio (low 128 bits) survives the upgrade.
        assertEq(uint128(uint256(vm.load(address(governedIncentivizer), cycleSlot))), expectedRewardRatio);
        // _currentCycleId is the high 128 bits of the packed slot (_rewardRatio occupies the low 128 bits);
        // the initializer seeds it to 1.
        assertEq(uint256(cycleBefore >> 128), 1);
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

    /// @notice Test initialize seeds cycle and treasury metadata.
    function testInitializeSeedsCycleAndTreasuryMetadata() external view {
        (
            uint128 currentCycleId,
            uint128 rewardRatio,
            address governorAddress,
            address[] memory treasuryTokenList,
            address[] memory rewardTokenList
        ) = incentivizer.metaData();

        assertEq(currentCycleId, 1);
        assertEq(rewardRatio, 2500);
        assertEq(governorAddress, address(governor));
        assertEq(treasuryTokenList.length, 1);
        assertEq(treasuryTokenList[0], address(tokenA));
        assertEq(rewardTokenList.length, 0);
    }

    /// @notice Test view helpers return false or zero when cycle has no matching data.
    function testViewHelpersReturnFalseOrZeroWhenCycleHasNoMatchingData() external view {
        assertFalse(incentivizer.isTreasuryToken(1, address(tokenB)));
        assertFalse(incentivizer.isRewardToken(1, address(tokenB)));
        assertEq(incentivizer.getClaimableReward(address(0x1), address(tokenA)), 0);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 0);

        (address[] memory rewardTokens, uint256[] memory rewards) = incentivizer.getClaimableReward(address(0x1));
        assertEq(rewardTokens.length, 0);
        assertEq(rewards.length, 0);

        (address[] memory remainingTokens, uint256[] memory remainingRewards) =
            incentivizer.getRemainingClaimableRewards();
        assertEq(remainingTokens.length, 0);
        assertEq(remainingRewards.length, 0);
    }

    /// @notice Test historical view helpers read frozen lists after finalize.
    function testHistoricalViewHelpersReadFrozenListsAfterFinalize() external {
        tokenA.mint(address(governor), 100 ether);
        tokenB.mint(address(governor), 40 ether);
        vm.startPrank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));
        incentivizer.registerRewardToken(address(tokenA));
        // Registration seeded tokenB's ledger from the governor-held 40 ether; custody must grow by the
        // same amount before the income is booked so the fixture ledger matches custody (G = T).
        tokenB.mint(address(governor), 40 ether);
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.recordTreasuryIncome(address(tokenB), 40 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        assertTrue(incentivizer.isTreasuryToken(1, address(tokenA)));
        assertTrue(incentivizer.isTreasuryToken(1, address(tokenB)));
        assertTrue(incentivizer.isRewardToken(1, address(tokenA)));
        assertFalse(incentivizer.isRewardToken(1, address(tokenB)));

        (address[] memory tokens, uint256[] memory balances) = incentivizer.getTreasuryBalances(1);
        assertEq(tokens.length, 2);
        assertEq(balances.length, 2);

        (address[] memory rewardTokens, uint256[] memory rewards) = incentivizer.getClaimableReward(address(this));
        assertEq(rewardTokens.length, 1);
        assertEq(rewards.length, 1);
        assertEq(rewardTokens[0], address(tokenA));
        assertEq(rewards[0], 25 ether);

        (address[] memory remainingTokens, uint256[] memory remainingRewards) =
            incentivizer.getRemainingClaimableRewards();
        assertEq(remainingTokens.length, 1);
        assertEq(remainingRewards.length, 1);
        assertEq(remainingTokens[0], address(tokenA));
        assertEq(remainingRewards[0], 25 ether);
    }

    /// @notice Test governance registration guards and token lists.
    function testGovernanceRegistrationGuardsAndTokenLists() external {
        vm.prank(OTHER);
        vm.expectRevert(IGovernanceCycleIncentivizer.PermissionDenied.selector);
        incentivizer.registerTreasuryToken(address(tokenB));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        incentivizer.registerTreasuryToken(address(0));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.RegisteredToken.selector);
        incentivizer.registerTreasuryToken(address(tokenA));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        incentivizer.registerRewardToken(address(tokenB));

        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));
        assertTrue(incentivizer.isTreasuryToken(1, address(tokenB)));

        vm.prank(address(governor));
        incentivizer.registerRewardToken(address(tokenB));
        assertTrue(incentivizer.isRewardToken(1, address(tokenB)));

        vm.prank(address(governor));
        incentivizer.unregisterRewardToken(address(tokenB));
        assertFalse(incentivizer.isRewardToken(1, address(tokenB)));

        vm.prank(address(governor));
        incentivizer.unregisterTreasuryToken(address(tokenB));
        assertFalse(incentivizer.isTreasuryToken(1, address(tokenB)));
    }

    /// @notice Test register treasury token respects max list size.
    function testRegisterTreasuryTokenRespectsMaxListSize() external {
        for (uint256 i = 0; i < incentivizer.MAX_TOKENS_LIMIT() - 1; i++) {
            MockERC20 extra = new MockERC20("Extra", "EXT", 18);
            vm.prank(address(governor));
            incentivizer.registerTreasuryToken(address(extra));
        }

        MockERC20 overflowToken = new MockERC20("Overflow", "OVR", 18);
        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.OutOfMaxTokensLimit.selector);
        incentivizer.registerTreasuryToken(address(overflowToken));
    }

    /// @notice Test treasury registration seeds the ledger from governor custody, not incentivizer-held tokens.
    function testRegisterTreasuryTokenExcludesIncentivizerHeldBalanceFromLedger() external {
        tokenB.mint(address(incentivizer), 100 ether);

        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));

        assertEq(incentivizer.getTreasuryBalance(1, address(tokenB)), 0);
    }

    /// @notice Test treasury registration seeds the ledger with the governor-held balance when no reward reserve exists.
    function testRegisterTreasuryTokenSeedsLedgerWithGovernorBalanceWhenNoRewardReserve() external {
        tokenB.mint(address(governor), 100 ether);

        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));

        assertEq(incentivizer.getTreasuryBalance(1, address(tokenB)), 100 ether);
    }

    /// @notice Test re-registering a treasury token seeds the ledger minus the previous cycle reward reserve.
    function testReRegisterTreasuryTokenSeedsLedgerMinusPreviousCycleRewardReserve() external {
        tokenB.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));
        incentivizer.registerRewardToken(address(tokenB));
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        // Finalizing splits the 100 ether seeded ledger 75/25: 25 ether reward reserve (R) is parked in
        // cycle 1 while the governor still holds the full 100 ether (G).
        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        vm.prank(address(governor));
        incentivizer.unregisterTreasuryToken(address(tokenB));
        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));

        assertEq(incentivizer.getTreasuryBalance(2, address(tokenB)), 75 ether);
    }

    /// @notice Test register reward token rejects zero input and duplicate token.
    function testRegisterRewardTokenRejectsZeroInputAndDuplicateToken() external {
        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        incentivizer.registerRewardToken(address(0));

        vm.prank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.RegisteredToken.selector);
        incentivizer.registerRewardToken(address(tokenA));
    }

    /// @notice Test unregister functions reject non registered tokens.
    function testUnregisterFunctionsRejectNonRegisteredTokens() external {
        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.NonRegisteredToken.selector);
        incentivizer.unregisterRewardToken(address(tokenB));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.NonRegisteredToken.selector);
        incentivizer.unregisterTreasuryToken(address(tokenB));
    }

    /// @notice Test unregister treasury token also removes reward registration.
    function testUnregisterTreasuryTokenAlsoRemovesRewardRegistration() external {
        vm.startPrank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));
        incentivizer.registerRewardToken(address(tokenB));
        vm.stopPrank();

        vm.prank(address(governor));
        incentivizer.unregisterTreasuryToken(address(tokenB));

        assertFalse(incentivizer.isTreasuryToken(1, address(tokenB)));
        assertFalse(incentivizer.isRewardToken(1, address(tokenB)));
    }

    /// @notice Test unregister treasury token without reward registration keeps other reward list untouched.
    function testUnregisterTreasuryTokenWithoutRewardRegistrationKeepsOtherRewardListUntouched() external {
        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(tokenB));

        vm.prank(address(governor));
        incentivizer.unregisterTreasuryToken(address(tokenB));

        assertFalse(incentivizer.isTreasuryToken(1, address(tokenB)));
        assertFalse(incentivizer.isRewardToken(1, address(tokenB)));
    }

    /// @notice Test receive and send treasury assets track balances.
    function testRecordTreasuryIncomeAndSpendTrackBalances() external {
        tokenA.mint(address(governor), 100 ether);

        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        vm.prank(address(governor));
        incentivizer.recordTreasuryIncome(address(0), 1 ether);

        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        vm.prank(address(governor));
        incentivizer.recordTreasuryIncome(address(tokenB), 1 ether);

        vm.prank(address(governor));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        assertEq(incentivizer.getTreasuryBalance(1, address(tokenA)), 100 ether);

        vm.prank(OTHER);
        vm.expectRevert(IGovernanceCycleIncentivizer.PermissionDenied.selector);
        incentivizer.recordTreasuryAssetSpend(address(tokenA), OTHER, 1 ether);

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.InsufficientTreasuryBalance.selector);
        incentivizer.recordTreasuryAssetSpend(address(tokenA), OTHER, 101 ether);

        vm.prank(address(governor));
        incentivizer.recordTreasuryAssetSpend(address(tokenA), OTHER, 40 ether);
        assertEq(incentivizer.getTreasuryBalance(1, address(tokenA)), 60 ether);
    }

    /// @notice Test record treasury asset spend rejects zero input and non treasury token.
    function testRecordTreasuryAssetSpendRejectsZeroInputAndNonTreasuryToken() external {
        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        incentivizer.recordTreasuryAssetSpend(address(0), OTHER, 1 ether);

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        incentivizer.recordTreasuryAssetSpend(address(tokenB), OTHER, 1 ether);
    }

    /// @notice Test record treasury asset spend reverts when recorded balance exceeds actual holdings.
    function testRecordTreasuryAssetSpendRevertsWhenRecordedBalanceExceedsActualHoldings() external {
        vm.prank(address(governor));
        incentivizer.recordTreasuryIncome(address(tokenA), 10 ether);

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.InsufficientTreasuryBalance.selector);
        incentivizer.recordTreasuryAssetSpend(address(tokenA), OTHER, 1 ether);
    }

    // testSyncTreasuryBalanceRequiresGovernance removed: syncTreasuryBalance is now permissionless
    // (see test/governance/SyncTreasuryBalancePermissionless.t.sol for permissionless coverage).

    /// @notice Test sync treasury balance rejects zero input and unregistered tokens.
    function testSyncTreasuryBalanceRejectsZeroInputAndUnregisteredToken() external {
        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.ZeroInput.selector);
        incentivizer.syncTreasuryBalance(address(0));

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        incentivizer.syncTreasuryBalance(address(tokenB));
    }

    /// @notice Test sync credits a direct governor donation into the current cycle ledger.
    function testSyncTreasuryBalanceCreditsDirectGovernorDonation() external {
        tokenA.mint(address(governor), 100 ether);

        vm.prank(address(governor));
        incentivizer.syncTreasuryBalance(address(tokenA));

        assertEq(incentivizer.getTreasuryBalance(1, address(tokenA)), 100 ether);
    }

    /// @notice Test sync subtracts the previous cycle unclaimed reward reserve from the synced ledger.
    function testSyncTreasuryBalanceSubtractsPreviousCycleRewardReserve() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        // A direct donation to the governor after finalization bypasses the ledger; sync books it
        // net of the 25 ether cycle-1 reward reserve: 130 - 25 = 105.
        tokenA.mint(address(governor), 30 ether);

        vm.prank(address(governor));
        incentivizer.syncTreasuryBalance(address(tokenA));

        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 105 ether);
    }

    /// @notice Test sync saturates the ledger to zero when the reward reserve exceeds governor custody.
    function testSyncTreasuryBalanceSaturatesToZeroWhenReserveExceedsGovernorBalance() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        // The governor spends custody down to 20 ether, below the 25 ether unclaimed reward reserve.
        vm.prank(address(governor));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(OTHER, 80 ether);

        vm.prank(address(governor));
        incentivizer.syncTreasuryBalance(address(tokenA));

        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 0);
    }

    /// @notice Test sync emits the treasury balance synced event with the cycle, token, and synced balance.
    function testSyncTreasuryBalanceEmitsEvent() external {
        tokenA.mint(address(governor), 100 ether);

        // Full-field expectation: cycle, token, and synced balance must all match the ledger write.
        vm.expectEmit();
        emit IGovernanceCycleIncentivizer.TreasuryBalanceSynced(1, address(tokenA), 100 ether);
        vm.prank(address(governor));
        incentivizer.syncTreasuryBalance(address(tokenA));

        assertEq(incentivizer.getTreasuryBalance(1, address(tokenA)), 100 ether);
    }

    /// @notice Test a balanceOf that mutates state cannot reenter during sync.
    /// @dev The governor custody read goes through the view-qualified IERC20.balanceOf, which compiles to
    /// STATICCALL. The mock's balanceOf attempts an SSTORE (clearing its reenter switch) before any finalize
    /// callback, so the whole sync must revert: the view declaration itself makes reentrant state mutation
    /// impossible. Do not remove the view qualifier to "support" this scenario.
    function testSyncTreasuryBalanceRevertsWhenTokenBalanceReadMutatesState() external {
        ReentrantBalanceOfToken reentrantToken = new ReentrantBalanceOfToken();
        reentrantToken.mint(address(governor), 100 ether);
        reentrantToken.setIncentivizer(address(incentivizer));

        // Register with the switch off so the registration seed read succeeds.
        vm.prank(address(governor));
        incentivizer.registerTreasuryToken(address(reentrantToken));

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION() + 1);
        reentrantToken.setReenter(true);

        vm.expectRevert();
        vm.prank(address(governor));
        incentivizer.syncTreasuryBalance(address(reentrantToken));

        // The reentrant finalize never ran: the cycle is untouched and the ledger still holds the
        // 100 ether seed booked at registration.
        assertEq(incentivizer.currentCycleId(), 1);
        assertEq(incentivizer.getTreasuryBalance(1, address(reentrantToken)), 100 ether);
        assertFalse(reentrantToken.callbackAttempted());
    }

    /// @notice Test finalize current cycle distributes rewards and starts next cycle.
    function testFinalizeCurrentCycleDistributesRewardsAndStartsNextCycle() external {
        tokenA.mint(address(governor), 100 ether);

        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(0x1), 40);
        incentivizer.accumCycleVotes(address(0x2), 60);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        assertEq(incentivizer.currentCycleId(), 2);
        assertEq(incentivizer.getClaimableReward(address(0x1), address(tokenA)), 10 ether);
        assertEq(incentivizer.getClaimableReward(address(0x2), address(tokenA)), 15 ether);
        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 75 ether);
    }

    /// @notice Test finalize current cycle reverts before end and carries undistributed rewards forward.
    function testFinalizeCurrentCycleRevertsBeforeEndAndCarriesUndistributedRewardsForward() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        vm.stopPrank();

        vm.expectRevert(IGovernanceCycleIncentivizer.CycleNotEnded.selector);
        incentivizer.finalizeCurrentCycle();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        assertEq(incentivizer.currentCycleId(), 2);
        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 100 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 0);
    }

    /// @notice Test finalize next cycle carries forward unclaimed rewards into treasury.
    function testFinalizeNextCycleCarriesForwardUnclaimedRewardsIntoTreasury() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        // Do not claim cycle 1 rewards, then finalize cycle 2 to force carry-over of prev reward balance.
        vm.warp(block.timestamp + 90 days + 1);
        incentivizer.finalizeCurrentCycle();

        assertEq(incentivizer.currentCycleId(), 3);
        assertEq(incentivizer.getTreasuryBalance(3, address(tokenA)), 100 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 0);
    }

    /// @notice Test finalize with reward token but no votes keeps treasury balance undistributed.
    function testFinalizeWithRewardTokenButNoVotesKeepsTreasuryBalanceUndistributed() external {
        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        assertEq(incentivizer.currentCycleId(), 2);
        assertEq(incentivizer.getTreasuryBalance(2, address(tokenA)), 100 ether);
        assertEq(incentivizer.getClaimableReward(address(this), address(tokenA)), 0);
    }

    /// @notice Test claim reward distributes every registered reward token pro rata.
    function testClaimRewardDistributesMultipleTokensProRata() external {
        tokenA.mint(address(governor), 100 ether);
        tokenB.mint(address(governor), 200 ether);

        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        // Registration seeds tokenB's ledger from the governor-held 200 ether, so income on top
        // yields a 400 ether cycle treasury (seed 200 + recorded income 200).
        incentivizer.registerTreasuryToken(address(tokenB));
        incentivizer.registerRewardToken(address(tokenB));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        // Matching custody growth for the booked income: seed 200 + income 200 with the governor
        // holding 400 ether keeps the ledger consistent (G = T).
        tokenB.mint(address(governor), 200 ether);
        incentivizer.recordTreasuryIncome(address(tokenB), 200 ether);
        incentivizer.accumCycleVotes(address(this), 40);
        incentivizer.accumCycleVotes(OTHER, 60);
        vm.stopPrank();

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        (address[] memory tokens, uint256[] memory rewards) = incentivizer.getClaimableReward(address(this));
        assertEq(tokens.length, 2);
        assertEq(rewards.length, 2);
        assertEq(rewards[0], 10 ether);
        assertEq(rewards[1], 40 ether);

        uint256 tokenABefore = tokenA.balanceOf(address(this));
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        incentivizer.claimReward();

        assertEq(tokenA.balanceOf(address(this)) - tokenABefore, 10 ether);
        assertEq(tokenB.balanceOf(address(this)) - tokenBBefore, 40 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 15 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenB)), 60 ether);
    }

    /// @notice Test claim reward clears state before a reward token callback can reenter.
    function testClaimRewardHandlesReentrantRewardTokenCallback() external {
        ReentrantRewardToken reentrantToken = new ReentrantRewardToken();
        reentrantToken.mint(address(governor), 100 ether);

        vm.startPrank(address(governor));
        // Registration seeds the ledger from the governor-held 100 ether, so income on top yields a
        // 200 ether cycle treasury (seed 100 + recorded income 100) and a 50 ether reward pool.
        incentivizer.registerTreasuryToken(address(reentrantToken));
        incentivizer.registerRewardToken(address(reentrantToken));
        // Matching custody growth for the booked income: seed 100 + income 100 leaves the governor
        // holding 200 ether, so the 50 ether payout after finalize leaves 150 ether in custody.
        reentrantToken.mint(address(governor), 100 ether);
        incentivizer.recordTreasuryIncome(address(reentrantToken), 100 ether);
        incentivizer.accumCycleVotes(address(reentrantToken), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        reentrantToken.setClaimTarget(address(incentivizer));
        reentrantToken.setReenter(true);
        vm.prank(address(reentrantToken));
        incentivizer.claimReward();

        assertTrue(reentrantToken.callbackAttempted());
        assertFalse(reentrantToken.callbackSucceeded());
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 50 ether);
        assertEq(reentrantToken.balanceOf(address(governor)), 150 ether);
        assertEq(incentivizer.getUserVotesCount(address(reentrantToken), 1), 0);
        assertEq(incentivizer.getRemainingClaimableRewards(address(reentrantToken)), 0);
    }

    /// @notice Fuzzes the single-token claimable reward formula after cycle finalization.
    function testFuzz_ClaimableRewardMatchesProRata(uint96 income, uint96 userVotes, uint96 otherVotes) external {
        income = uint96(bound(income, 1 ether, 1_000 ether));
        userVotes = uint96(bound(userVotes, 1, 1_000 ether));
        otherVotes = uint96(bound(otherVotes, 1, 1_000 ether));

        tokenA.mint(address(governor), income);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), income);
        incentivizer.accumCycleVotes(address(this), userVotes);
        incentivizer.accumCycleVotes(OTHER, otherVotes);
        vm.stopPrank();

        vm.warp(block.timestamp + incentivizer.CYCLE_DURATION());
        incentivizer.finalizeCurrentCycle();

        uint256 rewardPool = income * 2500 / incentivizer.RATIO();
        assertEq(
            incentivizer.getClaimableReward(address(this), address(tokenA)),
            rewardPool * userVotes / (userVotes + otherVotes)
        );
    }

    /// @notice Test claim reward transfers previous cycle rewards.
    function testClaimRewardTransfersPreviousCycleRewards() external {
        tokenA.mint(address(governor), 100 ether);

        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        uint256 beforeBalance = tokenA.balanceOf(address(this));
        incentivizer.claimReward();
        uint256 afterBalance = tokenA.balanceOf(address(this));

        assertEq(afterBalance - beforeBalance, 25 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 0);
        assertEq(governor.lastRewardToken(), address(tokenA));
        assertEq(governor.lastRewardTo(), address(this));
        assertEq(governor.lastRewardAmount(), 25 ether);
    }

    /// @notice Test claim reward reverts without votes and supports partial rewards across users.
    function testClaimRewardRevertsWithoutVotesAndSupportsPartialRewardsAcrossUsers() external {
        vm.prank(OTHER);
        vm.expectRevert(IGovernanceCycleIncentivizer.NoRewardsToClaim.selector);
        incentivizer.claimReward();

        vm.expectRevert(IGovernanceCycleIncentivizer.NoRewardsToClaim.selector);
        incentivizer.claimReward();

        tokenA.mint(address(governor), 100 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 100 ether);
        incentivizer.accumCycleVotes(address(this), 40);
        incentivizer.accumCycleVotes(OTHER, 60);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        uint256 before = tokenA.balanceOf(address(this));
        incentivizer.claimReward();
        uint256 claimed = tokenA.balanceOf(address(this)) - before;

        assertEq(claimed, 10 ether);
        assertEq(incentivizer.getRemainingClaimableRewards(address(tokenA)), 15 ether);
    }

    /// @notice Test claim reward clears votes even when rounded reward is zero.
    function testClaimRewardClearsVotesEvenWhenRoundedRewardIsZero() external {
        tokenA.mint(address(governor), 1 ether);
        vm.startPrank(address(governor));
        incentivizer.registerRewardToken(address(tokenA));
        incentivizer.recordTreasuryIncome(address(tokenA), 1 ether);
        incentivizer.accumCycleVotes(address(this), 1);
        incentivizer.accumCycleVotes(OTHER, 10_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        incentivizer.finalizeCurrentCycle();

        incentivizer.claimReward();

        assertEq(incentivizer.getClaimableReward(address(this), address(tokenA)), 0);
    }

    /// @notice Test accum cycle votes requires governance.
    function testAccumCycleVotesRequiresGovernance() external {
        vm.prank(OTHER);
        vm.expectRevert(IGovernanceCycleIncentivizer.PermissionDenied.selector);
        incentivizer.accumCycleVotes(OTHER, 1 ether);
    }

    /// @notice Test update reward ratio checks bounds.
    function testUpdateRewardRatioChecksBounds() external {
        vm.prank(OTHER);
        vm.expectRevert(IGovernanceCycleIncentivizer.PermissionDenied.selector);
        incentivizer.updateRewardRatio(1);

        vm.prank(address(governor));
        vm.expectRevert(IGovernanceCycleIncentivizer.InvalidRewardRatio.selector);
        incentivizer.updateRewardRatio(10001);

        vm.prank(address(governor));
        incentivizer.updateRewardRatio(3000);
        (, uint128 rewardRatio,,,) = incentivizer.metaData();
        assertEq(rewardRatio, 3000);
    }
}
