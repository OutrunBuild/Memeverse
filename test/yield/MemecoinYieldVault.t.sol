// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";
import {IMemecoinYieldVault} from "../../src/yield/interfaces/IMemecoinYieldVault.sol";
import {YieldDispatcher} from "../../src/verse/YieldDispatcher.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {IYieldDispatcher} from "../../src/verse/interfaces/IYieldDispatcher.sol";
import {IMemeverseOFTEnum} from "../../src/common/types/IMemeverseOFTEnum.sol";
import {MockComposeAsset} from "../mocks/yield/YieldMocks.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {OFTHarness} from "../mocks/infrastructure/OFTHarness.sol";

contract MemecoinYieldVaultTest is Test {
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant YIELD_SOURCE = address(0xFEED);
    /// @dev Virtual buffer V passed to every test vault. Chosen large enough to visibly dampen rate
    ///      inflation while keeping assertions readable; production sizing is spec §4 (0.7% of the
    ///      minimum main-pool memecoin provision) and is covered by dedicated tests below.
    uint256 internal constant VIRTUAL_ASSETS = 100 ether;

    MockERC20 internal asset;
    MemecoinYieldVault internal vault;

    /// @notice Deploys a fresh vault clone and seeds attacker/victim balances.
    /// @dev Reuses the production initializer path so tests exercise clone semantics.
    function setUp() external {
        asset = new MockERC20("Memecoin", "MEME", 18);
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(implementation)));
        vault.initialize("Staked Memecoin", "sMEME", address(0xD15A7), address(asset), 1, VIRTUAL_ASSETS);

        asset.mint(ATTACKER, 1_001 ether);
        asset.mint(VICTIM, 2_000 ether);

        vm.prank(ATTACKER);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(VICTIM);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @notice A first depositor who front-runs public yield captures only a V-damped fraction.
    /// @dev Yield is injected by a third party (modeling legitimate swap-fee arrival via the
    ///      yieldDispatcher path), NOT by the attacker. This makes the assertion V-sensitive:
    ///      with VIRTUAL_ASSETS=100 ether the attacker redeems ~11 ether; if V regressed to +1
    ///      the attacker would redeem ~500 ether, failing the bound below.
    function testVirtualBufferDampsFirstDepositorCaptureOfPublicYield() external {
        // Attacker front-runs: deposits dust before public yield arrives.
        vm.prank(ATTACKER);
        uint256 attackerShares = vault.deposit(1, ATTACKER);

        // Legitimate public yield arrives from a third party, not the attacker.
        asset.mint(YIELD_SOURCE, 1_000 ether);
        vm.startPrank(YIELD_SOURCE);
        asset.approve(address(vault), 1_000 ether);
        vault.accumulateYields(1_000 ether);
        vm.stopPrank();

        // Victim deposits at the pushed-up rate.
        vm.prank(VICTIM);
        vault.deposit(2_000 ether, VICTIM);

        // Attacker redeems after the delay.
        vm.prank(ATTACKER);
        vault.requestRedeem(attackerShares, ATTACKER);
        vm.warp(block.timestamp + 1 days);
        vm.prank(ATTACKER);
        uint256 attackerRedeemed = vault.executeRedeem();

        // The attacker captured some yield (sanity), but only a V-damped fraction: ~11 ether with
        // V=100, versus ~500 ether if V regressed to +1. The 50 ether bound catches such a regression.
        assertGt(attackerRedeemed, 0, "attacker should capture some public yield");
        assertLt(attackerRedeemed, 50 ether, "attacker capture must be damped by V (V=100 ~11e, V=1 ~500e)");
    }

    /// @notice Verifies raw ERC20 transfers into the vault do not affect share pricing.
    /// @dev Confirms pricing relies on managed assets rather than `balanceOf(address(this))`.
    function testDirectAssetDonationDoesNotChangeSharePricing() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        // Direct ERC20 donations should not move the preview path because pricing tracks managed assets only.
        uint256 previewBefore = vault.previewDeposit(20 ether);

        vm.prank(ATTACKER);
        assertTrue(asset.transfer(address(vault), 500 ether));

        uint256 previewAfter = vault.previewDeposit(20 ether);

        vm.prank(VICTIM);
        uint256 actualShares = vault.deposit(20 ether, VICTIM);

        assertEq(previewAfter, previewBefore, "preview changed by raw donation");
        assertEq(actualShares, previewBefore, "deposit changed by raw donation");
    }

    /// @notice V damping holds across multiple downstream victim deposits.
    /// @dev Same third-party yield injection as the single-victim case; the attacker stakes 1 ether
    ///      (small but not dust) and still captures only a damped fraction (~7.4 ether at V=100,
    ///      ~667 ether if V regressed to +1).
    function testVirtualBufferDampsFirstDepositorCaptureAcrossMultipleVictims() external {
        address victimTwo = address(0xB0B2);
        asset.mint(victimTwo, 2_000 ether);
        vm.prank(victimTwo);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(ATTACKER);
        uint256 attackerShares = vault.deposit(1 ether, ATTACKER);

        // Legitimate public yield from a third party.
        asset.mint(YIELD_SOURCE, 1_000 ether);
        vm.startPrank(YIELD_SOURCE);
        asset.approve(address(vault), 1_000 ether);
        vault.accumulateYields(1_000 ether);
        vm.stopPrank();

        vm.prank(VICTIM);
        vault.deposit(1_000 ether, VICTIM);
        vm.prank(victimTwo);
        vault.deposit(1_000 ether, victimTwo);

        vm.prank(ATTACKER);
        vault.requestRedeem(attackerShares, ATTACKER);
        vm.warp(block.timestamp + 1 days);
        vm.prank(ATTACKER);
        uint256 attackerRedeemed = vault.executeRedeem();

        assertGt(attackerRedeemed, 1 ether, "attacker should capture some public yield");
        assertLt(attackerRedeemed, 50 ether, "attacker capture must be damped by V across multiple victims");
    }

    /// @notice A third-party caller cannot queue a redemption into someone else's queue.
    /// @dev Guards the self-redemption-only rule: the queue of the nominated receiver must stay untouched.
    function testRequestRedeemRevertsForThirdPartyReceiver() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vm.expectRevert(IMemecoinYieldVault.NotSelfRedemption.selector);
        vault.requestRedeem(shares / 2, RECEIVER);

        vm.expectRevert();
        vault.redeemRequestQueues(RECEIVER, 0);
    }

    /// @notice The griefing queue-fill attack (5 wei deposit, 5 requests into the victim's queue) is blocked.
    /// @dev Reproduces the reported DoS: each request into VICTIM's queue must revert, the victim's queue
    ///      must stay empty, and the victim must still be able to queue their own request.
    function testGriefingQueueFillAttackIsBlocked() external {
        vm.prank(ATTACKER);
        vault.deposit(5, ATTACKER);

        for (uint256 i = 0; i < vault.MAX_REDEEM_REQUESTS(); i++) {
            vm.prank(ATTACKER);
            vm.expectRevert(IMemecoinYieldVault.NotSelfRedemption.selector);
            vault.requestRedeem(1, VICTIM);
        }

        vm.expectRevert();
        vault.redeemRequestQueues(VICTIM, 0);

        // The victim can still queue their own redemption without hitting the request cap.
        vm.prank(VICTIM);
        uint256 victimShares = vault.deposit(10 ether, VICTIM);
        vm.prank(VICTIM);
        vault.requestRedeem(victimShares / 2, VICTIM);

        (uint192 queuedAmount,) = vault.redeemRequestQueues(VICTIM, 0);
        assertGt(uint256(queuedAmount), 0, "victim's own request stays queued");
    }

    /// @notice Verifies previewed shares match actual shares after yield accumulation.
    /// @dev Guards the pricing path shared by `previewDeposit` and `deposit`.
    function testPreviewDepositMatchesActualDepositAfterYieldAccumulation() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        uint256 previewedShares = vault.previewDeposit(20 ether);

        vm.prank(VICTIM);
        uint256 actualShares = vault.deposit(20 ether, VICTIM);

        assertEq(actualShares, previewedShares, "preview deposit");
    }

    /// @notice Verifies requestRedeem locks the asset amount at request time regardless of later deposits.
    /// @dev Yield accumulation or new deposits after requestRedeem must not change the queued redemption amount.
    function testRequestRedeem_LocksAssetAmountAgainstSubsequentDeposits() external {
        // A deposits 10 ether, gets 10 shares (1:1 at initial state)
        vm.prank(ATTACKER);
        uint256 sharesA = vault.deposit(10 ether, ATTACKER);
        assertEq(sharesA, 10 ether, "initial shares");

        // Yield accumulates: totalAssets goes from 10 to 15, share price = 1.5
        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(sharesA, ATTACKER);
        assertGt(lockedAssets, 10 ether, "locked reflects yield");

        vm.prank(VICTIM);
        vault.deposit(30 ether, VICTIM);

        vm.warp(block.timestamp + 1 days);

        uint256 attackerBalanceBefore = asset.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 redeemed = vault.executeRedeem();

        assertEq(redeemed, lockedAssets, "redeemed amount matches locked");
        assertEq(asset.balanceOf(ATTACKER), attackerBalanceBefore + lockedAssets, "attacker received locked amount");
    }

    /// @notice Verifies `reAccumulateYields` claims the stuck compose from the dispatcher and credits totalAssets.
    /// @dev Models the retry path used when a LayerZero compose call to `accumulateYields` previously failed:
    ///      the vault calls YieldDispatcher.settlePendingCompose, which proves delivery via endpoint composeQueue, then
    ///      approves this vault and calls accumulateYields (pull + totalAssets accounting).
    function testReAccumulateYieldsClaimsFromDispatcherAndAccumulates() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        // Seed an existing deposit so _accumulateYield credits totalAssets (non-empty vault path).
        composeAsset.mint(ATTACKER, 10 ether);
        vm.prank(ATTACKER);
        composeAsset.approve(address(composeVault), type(uint256).max);
        vm.prank(ATTACKER);
        composeVault.deposit(10 ether, ATTACKER);

        bytes32 guid = keccak256("compose-guid");
        uint256 yieldAmount = 5 ether;
        composeAsset.mint(dispatcherAddr, yieldAmount);
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), yieldAmount);
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, guid, 0, keccak256(message));

        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        assertEq(composeVault.totalAssets(), 15 ether, "total assets after re-accumulate");
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.Released),
            "dispatcher marked released"
        );
    }

    /// @notice Empty-vault `reAccumulateYields` burns the claimed yield instead of absorbing it.
    /// @dev Complements the non-empty retry test above by covering the empty-vault branch of the retry
    ///      chain (reAccumulateYields -> settlePendingCompose -> _settleToContract -> accumulateYields ->
    ///      _accumulateYield burn). With no shares outstanding the yield is burned, so totalAssets stays
    ///      zero and no unowned value is left for a future first depositor.
    function testReAccumulateYieldsBurnsYieldOnEmptyVault() external {
        MockComposeAsset burnableAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(burnableAsset));

        assertEq(composeVault.totalAssets(), 0, "vault starts empty");
        assertEq(composeVault.totalSupply(), 0, "no shares outstanding");
        assertEq(burnableAsset.balanceOf(address(composeVault)), 0, "vault holds no asset before yield");

        bytes32 guid = keccak256("compose-guid");
        uint256 yieldAmount = 5 ether;
        burnableAsset.mint(dispatcherAddr, yieldAmount);
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), yieldAmount);
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(burnableAsset), dispatcherAddr, guid, 0, keccak256(message));

        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Empty vault: the pulled yield is burned, not absorbed, so no unowned value is created.
        assertEq(composeVault.totalAssets(), 0, "totalAssets unchanged after burn-on-empty");
        assertEq(burnableAsset.balanceOf(address(composeVault)), 0, "vault holds no burned yield");
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(burnableAsset), guid)),
            uint256(IComposeState.ComposeState.Released),
            "dispatcher marked released"
        );
        assertEq(burnableAsset.balanceOf(dispatcherAddr), 0, "dispatcher drained");
    }

    /// @notice `reAccumulateYields` reverts `NotDelivered` when the guid was never delivered to the endpoint.
    /// @dev Covers the first guard of the retry chain: with no endpoint `composeQueue` entry (mock default zero),
    ///      YieldDispatcher.settlePendingCompose cannot prove delivery and reverts before any fund movement. No queue
    ///      is planted and no tokens are minted — the revert must happen before state or balance changes.
    function testReAccumulateYieldsRevertsWhenNotDelivered() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr,) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), 5 ether);

        // No setQueue: the endpoint composeQueue slot stays zero, so the delivery proof fails with NotDelivered.
        vm.expectRevert(IComposeState.NotDelivered.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Revert is atomic: the (token, guid) mutex slot is untouched, so a funded retry can still resolve it.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice `reAccumulateYields` reverts `ZeroInput` for zero-amount payloads and `AlreadyResolved` on replay.
    /// @dev Covers the remaining guards of the retry chain: a delivered zero-amount message passes the delivery
    ///      proof but is rejected before settlement (keeping the (token, guid) slot resolvable), and a guid settled
    ///      once is pinned to Released so a second attempt reverts before the delivery check runs again.
    function testReAccumulateYieldsRevertsOnZeroInputAndAlreadyResolved() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        // ZeroInput: delivered message carries amount 0, so the delivery proof passes but settlement is refused.
        bytes32 zeroGuid = keccak256("zero-input-guid");
        bytes memory zeroMessage = _buildMemecoinComposeMessage(address(composeVault), 0);
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, zeroGuid, 0, keccak256(zeroMessage));

        vm.expectRevert(IYieldDispatcher.ZeroInput.selector);
        composeVault.reAccumulateYields(dispatcherAddr, zeroGuid, zeroMessage);

        // Revert is atomic: the zero-input rejection left the slot unpinned (composeStates stays None).
        // The hash-bound zero payload can never be settled with funds via settlePendingCompose; only the
        // endpoint's lzCompose callback can consume this guid.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), zeroGuid)),
            uint256(IComposeState.ComposeState.None),
            "zero-input revert left guid slot unresolved"
        );

        // AlreadyResolved: a guid settled once is pinned to Released, so the second attempt reverts.
        bytes32 guid = keccak256("compose-guid");
        uint256 yieldAmount = 5 ether;
        composeAsset.mint(dispatcherAddr, yieldAmount);
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), yieldAmount);
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, guid, 0, keccak256(message));

        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // The replay revert is atomic too: the first settle pinned the guid to Released and the retry left it there.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.Released),
            "replay revert kept guid pinned released"
        );
    }

    /// @notice `reAccumulateYields` succeeds when the caller passes the dispatcher the compose was actually
    ///         delivered to, even if it differs from the vault's initialize-time pointer (launcher rotation).
    /// @dev Covers the rotation fix: after `setYieldDispatcher` rotates the canonical dispatcher, a stuck compose for a
    ///      pre-rotation vault lands in the NEW dispatcher's composeQueue. The vault's `reAccumulateYields` must
    ///      accept the new dispatcher as a parameter and settle from ITS queue. Passing the stale initialize-time
    ///      dispatcher reads an empty queue slot and reverts NotDelivered — the bug this fix resolves for the success path.
    function testReAccumulateYieldsSettlesViaRotatedDispatcher() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherA, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        // dispatcherA (0xD15A7) is the vault's initialize-time storage pointer. Simulate a post-creation rotation
        // by deploying a second YieldDispatcher whose localEndpoint points at the same mock endpoint (0x9999) the
        // settle path reads. The stuck compose is delivered into dispatcherB's queue, not dispatcherA's.
        // Native deploy (no etch): composeStates and the composeQueue `to` key both derive from dispatcherB's own
        // address, and constructor immutables are set correctly, so a fresh deploy is sufficient and avoids the
        // etch-only-copies-code storage caveat that the dispatcherA setup must work around.
        YieldDispatcher dispatcherB = new YieldDispatcher(endpointAddr, address(this));

        // Seed an existing deposit so settlement credits totalAssets (non-empty vault path).
        composeAsset.mint(ATTACKER, 10 ether);
        vm.prank(ATTACKER);
        composeAsset.approve(address(composeVault), type(uint256).max);
        vm.prank(ATTACKER);
        composeVault.deposit(10 ether, ATTACKER);

        // ── Positive: settle via the rotated dispatcher (dispatcherB), not the initialize-time pointer (dispatcherA).
        bytes32 guid = keccak256("rotated-guid");
        uint256 yieldAmount = 5 ether;
        composeAsset.mint(address(dispatcherB), yieldAmount);
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), yieldAmount);
        // Queue key is composeQueue[token][to=dispatcherB][guid][0]; verifySettle reads address(this) under
        // dispatcherB's context, so the planted key must be keyed on dispatcherB, not the vault or dispatcherA.
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), address(dispatcherB), guid, 0, keccak256(message));

        composeVault.reAccumulateYields(address(dispatcherB), guid, message);

        // Settlement pulled 5 ether from dispatcherB into the vault: totalAssets 10 -> 15.
        assertEq(composeVault.totalAssets(), 15 ether, "total assets after re-accumulate via rotated dispatcher");
        assertEq(
            uint256(dispatcherB.composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.Released),
            "rotated dispatcher marked released"
        );

        // ── Negative: a second compose also delivered to dispatcherB fails when the caller passes the stale
        //    initialize-time pointer (dispatcherA). verifySettle keys composeQueue on address(this) = the
        //    dispatcher it runs under, so dispatcherA reads its own (empty) queue slot and reverts NotDelivered
        //    before any state or fund movement.
        bytes32 guid2 = keccak256("rotated-guid-2");
        bytes memory message2 = _buildMemecoinComposeMessage(address(composeVault), 3 ether);
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), address(dispatcherB), guid2, 0, keccak256(message2));

        vm.expectRevert(IComposeState.NotDelivered.selector);
        composeVault.reAccumulateYields(dispatcherA, guid2, message2);

        // Revert is atomic: guid2 was never processed, so dispatcherB's (token, guid2) mutex slot stays None.
        assertEq(
            uint256(dispatcherB.composeStates(address(composeAsset), guid2)),
            uint256(IComposeState.ComposeState.None),
            "stale-dispatcher revert left guid2 unresolved on dispatcherB"
        );
    }

    /// @notice `reAccumulateYields` reverts `NotComposeBeneficiary` when the message's inner receiver is not this vault.
    /// @dev Covers the beneficiary gate: the compose's receiver word ([76:108] of the payload) must be this
    ///      vault, because the endpoint hash-binds the message to the guid, so a message whose receiver is another
    ///      address can never settle yield into this vault. The gate runs before any dispatcher interaction, so no
    ///      queue is planted and the (token, guid) mutex slot stays untouched.
    function testReAccumulateYieldsRevertsWhenMessageReceiverIsNotThisVault() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr,) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        // Receiver is a third party, not the vault: the beneficiary gate must revert before the dispatcher is called.
        bytes memory message = _buildMemecoinComposeMessage(address(0xBeef), 5 ether);

        vm.expectRevert(IMemecoinYieldVault.NotComposeBeneficiary.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Revert is atomic: the (token, guid) mutex slot is untouched, so a legitimately-delivered compose can still resolve it.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice `reAccumulateYields` reverts `ComposeSettlementFailed` when the dispatcher returns without settling.
    /// @dev Covers the return-value gate: a dispatcher that claims success but releases no amount must not let
    ///      the retry pass silently. `vm.mockCall` stubs the dispatcher to return 0 (exact selector+args match, so
    ///      the stub fires for this precise call) while the message receiver is this vault, so the beneficiary gate
    ///      passes and the zero return is caught.
    function testReAccumulateYieldsRevertsWhenDispatcherSettlesNothing() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr,) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), 5 ether);

        // Stub settlePendingCompose to return 0 without executing the dispatcher's code.
        vm.mockCall(
            dispatcherAddr,
            abi.encodeWithSelector(
                IYieldDispatcher.settlePendingCompose.selector, address(composeAsset), guid, message
            ),
            abi.encode(uint256(0))
        );

        vm.expectRevert(IMemecoinYieldVault.ComposeSettlementFailed.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // The stubbed dispatcher never ran, so its (token, guid) mutex slot stays None.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "zero-settle revert left guid slot unresolved"
        );
    }

    /// @notice `reAccumulateYields` reverts `ComposeMessageTooShort` for payloads shorter than 108 bytes.
    /// @dev Covers the length gate: a message truncated below the beneficiary word ([76:108]) cannot carry the
    ///      inner receiver and can never settle (the dispatcher needs the full header plus the 64-byte tuple), so it
    ///      must fail with the named error before any dispatcher interaction.
    function testReAccumulateYieldsRevertsOnShortMessage() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr,) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        bytes memory message = _buildMemecoinComposeMessage(address(composeVault), 5 ether);
        assertGt(message.length, 108, "fixture: valid message is longer than the gate boundary");
        bytes memory truncated = new bytes(107);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = message[i];
        }

        vm.expectRevert(IMemecoinYieldVault.ComposeMessageTooShort.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, truncated);

        // Revert is atomic: the (token, guid) mutex slot is untouched.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice An exactly-108-byte message (receiver word present) passes the vault length gate.
    /// @dev Pins the `>= 108` boundary: a frame whose tail is only the 32-byte receiver word at [76:108] clears
    ///      the vault's entry gate (a `> 108` gate would instead revert `ComposeMessageTooShort` here). With no
    ///      queue planted, the retry proceeds into the dispatcher's delivery proof and reverts `NotDelivered`,
    ///      proving 108 is NOT rejected by the vault gate and that the next boundary lives dispatcher-side.
    function testReAccumulateYieldsAllowsExactly108ByteMessage() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr,) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        // 8 nonce + 4 srcEid + 32 amountLD + 32 composeFrom + 32 receiver word = 108 bytes exactly.
        bytes memory message =
            _buildRawComposeFrame(5 ether, abi.encodePacked(bytes32(uint256(uint160(address(composeVault))))));
        assertEq(message.length, 108, "fixture: exactly 108 bytes");

        // No setQueue: the vault gates pass (108 >= 108, receiver word == vault) and the dispatcher's delivery
        // proof reverts NotDelivered — proving 108 is not rejected by the vault entry gate.
        vm.expectRevert(IComposeState.NotDelivered.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Revert is atomic: the (token, guid) mutex slot is untouched.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice A 120-byte frame (108-139 band) clears the vault gates and is rejected by the dispatcher's
    ///         inner-tuple guard with the NAMED `MalformedComposeMsg`.
    /// @dev Pins the dispatcher-side boundary: the vault only checks the 32-byte receiver word (present at
    ///      [76:108]), while `settlePendingCompose` additionally requires the inner (address, TokenType) tuple
    ///      to be >= 64 bytes. A 44-byte tuple tail (120-byte frame) passes the vault gate and the delivery proof
    ///      but fails the dispatcher's `composeMsg.length >= TUPLE_LENGTH` guard — the same named error the
    ///      forward `lzCompose` path uses for unparseable payloads — with no settlement and the slot left None.
    function testReAccumulateYieldsRevertsAtDispatcherForShortTupleBand() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        // 76-byte header + 32-byte receiver word + 12 bytes of the tuple = 120 bytes.
        bytes memory message = _buildRawComposeFrame(
            5 ether, abi.encodePacked(bytes32(uint256(uint160(address(composeVault)))), bytes12(0))
        );
        assertEq(message.length, 120, "fixture: 120-byte short-tuple frame");
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, guid, 0, keccak256(message));

        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Revert is atomic: no settlement ran, so the (token, guid) mutex slot stays None.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice A length-legal frame with a dirty-high-bit receiver word reverts OPAQUELY at the dispatcher.
    /// @dev Pins the documented class claim (operations.md §3.13 / reAccumulateYields comment): the vault's
    ///      uint160 downcast truncates the forged receiver word so its low 160 bits equal this vault and the
    ///      gate passes, but the dispatcher's strict `abi.decode` rejects the dirty word with EMPTY revert data
    ///      — not NotComposeBeneficiary, not any named error. vm.expectRevert(bytes("")) is exact for empty
    ///      revert data in this Foundry version (a named error fails the expectation), so the form is load-bearing.
    function testReAccumulateYieldsDirtyHighBitsRevertOpaqueAtDispatcher() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        // Full 64-byte tuple whose receiver word is (non-zero high 96 bits | vault low 160 bits): 140 bytes.
        bytes32 dirtyReceiverWord = bytes32((uint256(1) << 160) | uint256(uint160(address(composeVault))));
        bytes memory message = _buildRawComposeFrame(5 ether, abi.encodePacked(dirtyReceiverWord, bytes32(uint256(1))));
        assertEq(message.length, 140, "fixture: full 140-byte frame");
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, guid, 0, keccak256(message));

        // The vault gate passes via uint160 truncation; the dispatcher's strict abi.decode reverts with EMPTY
        // revert data — pinning that this class does NOT revert NotComposeBeneficiary (or any named error).
        vm.expectRevert(bytes(""));
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);

        // Revert is atomic: no settlement ran, so the (token, guid) mutex slot stays None.
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(composeAsset), guid)),
            uint256(IComposeState.ComposeState.None),
            "revert left guid slot unresolved"
        );
    }

    /// @notice A zero-amount 120-byte frame reverts `ZeroInput` before the tuple-shape guard runs.
    /// @dev Pins the guard order in `settlePendingCompose`: `require(amount != 0, ZeroInput())` precedes the
    ///      `composeMsg.length >= 64` guard, so a short-tuple frame with amountLD = 0 fails `ZeroInput` — NOT
    ///      `MalformedComposeMsg` — documenting the precedence the dispatcher's comments rely on.
    function testReAccumulateYieldsZeroAmountShortTupleRevertsZeroInput() external {
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr) =
            _deployComposeVaultWithDispatcher(address(composeAsset));

        bytes32 guid = keccak256("compose-guid");
        bytes memory message =
            _buildRawComposeFrame(0, abi.encodePacked(bytes32(uint256(uint160(address(composeVault)))), bytes12(0)));
        MockMessagingComposerEndpoint(endpointAddr)
            .setQueue(address(composeAsset), dispatcherAddr, guid, 0, keccak256(message));

        vm.expectRevert(IYieldDispatcher.ZeroInput.selector);
        composeVault.reAccumulateYields(dispatcherAddr, guid, message);
    }

    /// @notice Verifies the vault reports timestamp-based clock metadata.
    /// @dev Confirms governance snapshotting semantics stay timestamp-based.
    function testClockMetadataUsesTimestampMode() external view {
        assertEq(vault.clock(), uint48(block.timestamp), "clock");
        assertEq(vault.CLOCK_MODE(), "mode=timestamp", "clock mode");
    }

    /// @notice Verifies redeem requests reject third-party receivers and zero-asset burns.
    /// @dev Both revert branches are guarded: a third-party or zero receiver reverts NotSelfRedemption,
    ///      and a zero share burn reverts ZeroRedeemRequest.
    function testRequestRedeemRevertsOnThirdPartyReceiverAndZeroRedeemRequest() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vm.expectRevert(IMemecoinYieldVault.NotSelfRedemption.selector);
        vault.requestRedeem(1 ether, address(0));

        vm.prank(ATTACKER);
        vm.expectRevert(IMemecoinYieldVault.ZeroRedeemRequest.selector);
        vault.requestRedeem(0, ATTACKER);
    }

    /// @notice Verifies redeem execution before the delay elapses returns zero and leaves the queue intact.
    /// @dev Covers the branch where no queued request is yet claimable.
    function testExecuteRedeemReturnsZeroBeforeDelay() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.requestRedeem(shares / 2, ATTACKER);

        vm.prank(ATTACKER);
        uint256 redeemedAmount = vault.executeRedeem();

        assertEq(redeemedAmount, 0, "redeemed amount");
        (uint192 queuedAmount,) = vault.redeemRequestQueues(ATTACKER, 0);
        assertGt(uint256(queuedAmount), 0, "queue retained");
    }

    /// @notice Verifies redeem execution removes matured entries even when they are not at the queue tail.
    /// @dev Covers the swap-pop branch in `executeRedeem`.
    function testExecuteRedeemRemovesMiddleEntryViaSwapPop() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(20 ether, ATTACKER);

        vm.prank(ATTACKER);
        uint256 firstAssets = vault.requestRedeem(shares / 2, ATTACKER);
        vm.warp(block.timestamp + 1 days);

        uint64 secondRequestTime = uint64(block.timestamp);
        vm.prank(ATTACKER);
        uint256 secondAssets = vault.requestRedeem(shares / 4, ATTACKER);

        uint256 balanceBefore = asset.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 redeemedAmount = vault.executeRedeem();

        assertEq(redeemedAmount, firstAssets, "only the mature request is redeemed");
        assertEq(asset.balanceOf(ATTACKER) - balanceBefore, firstAssets, "redeemed asset amount");
        (uint192 remainingAmount, uint64 remainingRequestTime) = vault.redeemRequestQueues(ATTACKER, 0);
        assertEq(uint256(remainingAmount), secondAssets, "immature request remains queued");
        assertEq(uint256(remainingRequestTime), uint256(secondRequestTime), "remaining request time");
        vm.expectRevert();
        vault.redeemRequestQueues(ATTACKER, 1);
    }

    /// @notice Verifies executeRedeem sums every request that is mature at the same time.
    function testExecuteRedeemAggregatesAllMaturedRequests() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(40 ether, ATTACKER);

        vm.prank(ATTACKER);
        uint256 firstAssets = vault.requestRedeem(shares / 4, ATTACKER);

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        vm.prank(ATTACKER);
        uint256 secondAssets = vault.requestRedeem(shares / 4, ATTACKER);

        vm.warp(block.timestamp + vault.REDEEM_DELAY());

        uint256 balanceBefore = asset.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 redeemedAmount = vault.executeRedeem();

        uint256 expectedRedeemed = firstAssets + secondAssets;
        assertEq(redeemedAmount, expectedRedeemed, "all mature requests are aggregated");
        assertEq(asset.balanceOf(ATTACKER) - balanceBefore, expectedRedeemed, "aggregated transfer amount");

        vm.expectRevert();
        vault.redeemRequestQueues(ATTACKER, 0);
    }

    /// @notice Verifies the queue caps outstanding redeem requests.
    /// @dev Covers the `MaxRedeemRequestsReached` branch.
    function testRequestRedeemRevertsWhenQueueIsFull() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);

        for (uint256 i = 0; i < vault.MAX_REDEEM_REQUESTS(); i++) {
            vm.prank(ATTACKER);
            vault.requestRedeem(shares / 10, ATTACKER);
        }

        vm.prank(ATTACKER);
        vm.expectRevert(IMemecoinYieldVault.MaxRedeemRequestsReached.selector);
        vault.requestRedeem(1, ATTACKER);
    }

    /// @notice Verifies redeem requests reject asset amounts that cannot fit in the packed uint192 queue entry.
    /// @dev Seeds a large exchange rate via vm.store (direct storage writes) so the request path
    ///      reaches the narrowing conversion without relying on a test-harness subclass.
    function testRequestRedeemRevertsWhenQueuedAssetsOverflowUint192() external {
        // Deploy a standard production vault (no test-harness subclass).
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        MemecoinYieldVault overflowVault = MemecoinYieldVault(Clones.clone(address(implementation)));
        overflowVault.initialize("Overflow Vault", "ovMEME", address(0xD15A7), address(asset), 99, VIRTUAL_ASSETS);

        // Give the attacker 1 wei of shares via a real deposit so _burn has a valid balance to debit.
        vm.startPrank(ATTACKER);
        asset.approve(address(overflowVault), type(uint256).max);
        overflowVault.deposit(1, ATTACKER);
        vm.stopPrank();

        // Inflate totalAssets to push _convertToAssets above type(uint192).max. With 1 share minted,
        // _convertToAssets(uint128.max, totalAssets) = uint128.max * (totalAssets + V) / (1 + V). The V=100
        // denominator divides by 101, so totalAssets must be large enough that even after that division the
        // asset value of uint128.max shares exceeds uint192. Using ~2^210 guarantees the quotient is far
        // above the uint192 ceiling with margin for the floor division.
        uint256 oversizedAssets = uint256(1) << 210;
        // Slot 2 = totalAssets (regular storage, after yieldDispatcher and asset).
        vm.store(address(overflowVault), bytes32(uint256(2)), bytes32(oversizedAssets));

        // Also inflate ERC20 totalSupply so _burn doesn't underflow.
        // ERC20_STORAGE_LOCATION + 2 = totalSupply (after two mapping fields).
        vm.store(
            address(overflowVault),
            bytes32(0xae36c519e2a406a79e4c05a9c40dc957f3757904fff7f6a4d18b68c3b12f9302),
            bytes32(uint256(type(uint128).max))
        );
        // Inflate the attacker's balance so requestRedeem can request a large share amount.
        // keccak256(abi.encode(ATTACKER, ERC20_STORAGE_LOCATION + 0)).
        vm.store(
            address(overflowVault),
            bytes32(0x819c7a1121989277ca5e22639b1d6fcf99589b7b3581ea632d4a29d6f73e87e4),
            bytes32(uint256(type(uint128).max))
        );

        uint256 previewAssets = overflowVault.previewRedeem(type(uint128).max);
        assertGt(previewAssets, uint256(type(uint192).max), "preview must exceed uint192");

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IMemecoinYieldVault.RedeemAmountOverflowed.selector, previewAssets));
        overflowVault.requestRedeem(type(uint128).max, ATTACKER);
    }

    /// @notice Verifies permit and delegateBySig consume the same nonce sequence on the vault.
    function testPermitAndDelegateBySigShareNonceSequence() external {
        uint256 alicePrivateKey = 0xA11CE;
        address alice = vm.addr(alicePrivateKey);
        uint256 deadline = block.timestamp + 1 days;

        asset.mint(alice, 10 ether);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10 ether, alice);

        bytes32 permitTypeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 permitStructHash =
            keccak256(abi.encode(permitTypeHash, alice, RECEIVER, 7 ether, vault.nonces(alice), deadline));
        bytes32 permitDigest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), permitStructHash));
        (uint8 permitV, bytes32 permitR, bytes32 permitS) = vm.sign(alicePrivateKey, permitDigest);

        vault.permit(alice, RECEIVER, 7 ether, deadline, permitV, permitR, permitS);

        assertEq(vault.allowance(alice, RECEIVER), 7 ether);
        assertEq(vault.nonces(alice), 1);

        bytes32 delegationTypeHash = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
        bytes32 delegationStructHash =
            keccak256(abi.encode(delegationTypeHash, RECEIVER, vault.nonces(alice), deadline));
        bytes32 delegationDigest =
            keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), delegationStructHash));
        (uint8 delegationV, bytes32 delegationR, bytes32 delegationS) = vm.sign(alicePrivateKey, delegationDigest);

        vault.delegateBySig(RECEIVER, 1, deadline, delegationV, delegationR, delegationS);

        assertEq(vault.delegates(alice), RECEIVER);
        assertEq(vault.getVotes(RECEIVER), 10 ether);
        assertEq(vault.nonces(alice), 2);
    }

    /// @notice Verifies the share conversion uses an independent floor oracle for non-divisible inputs.
    function testConvertToSharesRoundsDownForNonDivisibleRate() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        uint256 assetsToPreview = 7 ether;
        uint256 numerator = assetsToPreview * (vault.totalSupply() + VIRTUAL_ASSETS);
        uint256 denominator = vault.totalAssets() + VIRTUAL_ASSETS;
        uint256 expectedShares = numerator / denominator;

        assertGt(numerator % denominator, 0, "fixture must be non-divisible");
        assertEq(vault.previewDeposit(assetsToPreview), expectedShares, "conversion rounds down");
        assertLt(expectedShares * denominator, numerator, "floor is below exact quotient");
        assertGt((expectedShares + 1) * denominator, numerator, "next share would round above exact quotient");
    }

    /// @notice Fuzzes the share conversion against the integer floor formula after yield changes the rate.
    function testFuzz_PreviewDepositUsesFloor(uint96 initialAssets, uint96 yieldAssets, uint96 previewAssets) external {
        initialAssets = uint96(bound(initialAssets, 1 ether, 1_000 ether));
        yieldAssets = uint96(bound(yieldAssets, 1 ether, 1_000 ether));
        previewAssets = uint96(bound(previewAssets, 1, 1_000 ether));

        vm.prank(ATTACKER);
        vault.deposit(initialAssets, ATTACKER);

        asset.mint(YIELD_SOURCE, yieldAssets);
        vm.startPrank(YIELD_SOURCE);
        asset.approve(address(vault), type(uint256).max);
        vault.accumulateYields(yieldAssets);
        vm.stopPrank();

        uint256 numerator = uint256(previewAssets) * (vault.totalSupply() + VIRTUAL_ASSETS);
        uint256 denominator = vault.totalAssets() + VIRTUAL_ASSETS;
        assertEq(vault.previewDeposit(previewAssets), numerator / denominator, "fuzz floor formula");
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Asset-denominated votes tests
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice Yield accumulation makes account votes grow by asset value, not stay at raw shares.
    function testYieldAccumulationIncreasesAccountVotesByAssetValue() external {
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        assertEq(shares, 10 ether, "initial shares");

        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        uint256 votesBefore = vault.getVotes(ATTACKER);
        assertEq(votesBefore, 10 ether, "votes before yield = shares");

        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        uint256 votesAfter = vault.getVotes(ATTACKER);
        assertGt(votesAfter, votesBefore, "votes must increase after yield");
        assertEq(votesAfter, Math.mulDiv(shares, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS), "votes formula");
    }

    /// @notice Quorum reads asset-denominated total supply, not raw share supply.
    function testQuorumUsesAssetDenominatedTotalSupply() external {
        // Deposit at t=100
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        // Yield at t=200
        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        // Query at t=300 (past all events)
        vm.warp(300);
        assertEq(vault.getPastTotalSupply(100), 10 ether, "initial total supply = assets");

        uint256 pastTotalAfterYield = vault.getPastTotalSupply(200);
        assertGt(pastTotalAfterYield, 10 ether, "total supply grows with yield");
        assertEq(
            pastTotalAfterYield, Math.mulDiv(10 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS), "formula"
        );
    }

    /// @notice Asset denomination lets a sub-threshold staker cross proposalThreshold after yield.
    /// @dev Deposits 60 raw shares (below an abstract 100-ether threshold), then yields so the
    ///      asset-denominated votes clear it. Pre-fix `getVotes` returned raw shares (60),
    ///      failing the threshold assertion — the denomination lift, not the share count, crosses it.
    ///      Amounts are calibrated for V=100: votes = shares * (totalAssets + V) / (totalSupply + V).
    function testProposalThresholdAndAccountVotesUseSameUnit() external {
        vm.prank(ATTACKER);
        vault.deposit(60 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        // Raw shares 60 stay below the 100-ether threshold before yield.
        assertLe(vault.getVotes(ATTACKER), 100 ether, "sub-threshold before yield");

        // Yield 200 lifts totalAssets 60 -> 260; V=100 prices 60 shares to
        // 60 * (260 + 100) / (60 + 100) = 135 asset-votes, clearing the 100 threshold.
        vm.prank(ATTACKER);
        vault.accumulateYields(200 ether);

        uint256 accountVotes = vault.getVotes(ATTACKER);
        // Load-bearing: pre-fix getVotes == 60 (raw shares) would fail; only asset denomination clears 100.
        assertGt(accountVotes, 100 ether, "asset-denominated votes cross threshold after yield");
        assertGt(accountVotes, 60 ether, "votes exceed raw shares");
    }

    /// @notice Post-snapshot donation does not change getPastVotes or getPastTotalSupply.
    function testSnapshotImmutabilityAfterPostSnapshotDonation() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        vm.warp(300);
        assertEq(vault.getPastVotes(ATTACKER, 100), 10 ether, "votes unchanged at snapshot");
        assertEq(vault.getPastTotalSupply(100), 10 ether, "total supply unchanged at snapshot");
        assertGt(vault.getVotes(ATTACKER), 10 ether, "current votes reflect yield");
    }

    /// @notice requestRedeem immediately removes user votes and queued assets from total supply.
    function testRequestRedeemImmediatelyRemovesVotes() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        assertEq(vault.getVotes(ATTACKER), 10 ether, "votes before redeem");

        vm.prank(ATTACKER);
        vault.requestRedeem(shares / 2, ATTACKER);

        assertEq(vault.getVotes(ATTACKER), 5 ether, "votes halved after redeem request");

        vm.warp(200);
        assertEq(vault.getPastTotalSupply(100), 5 ether, "total supply reduced");
    }

    /// @notice After delegation, delegatee votes equal delegated shares converted to asset value.
    function testDelegateeVotesUseAssetDenominatedValue() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.delegate(VICTIM);

        uint256 victimVotes = vault.getVotes(VICTIM);
        assertEq(victimVotes, 10 ether, "delegatee votes = depositor shares at 1:1");

        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        uint256 victimVotesAfterYield = vault.getVotes(VICTIM);
        assertGt(victimVotesAfterYield, 10 ether, "delegatee votes grow with yield");
        assertEq(
            victimVotesAfterYield,
            Math.mulDiv(10 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "formula"
        );
    }

    /// @notice After delegate rebalancing, the moved votes stay consistent with the total.
    /// @dev Re-delegating from a shared delegatee back to self must not change the asset-denominated
    ///      vote total (within rounding). This exercises the `delegate()` path, not share `transfer()`.
    function testDelegateRebalancingKeepsVotesConsistent() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(VICTIM);
        vault.deposit(10 ether, VICTIM);

        address delegatee = address(0xBEEF);
        vm.prank(ATTACKER);
        vault.delegate(delegatee);
        vm.prank(VICTIM);
        vault.delegate(delegatee);

        assertEq(vault.getVotes(delegatee), 20 ether, "combined delegation");

        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        uint256 totalDelegatedAfterYield = vault.getVotes(delegatee);
        assertGt(totalDelegatedAfterYield, 20 ether, "combined votes grow with yield");

        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);
        uint256 sum = vault.getVotes(delegatee) + vault.getVotes(ATTACKER);
        // Allow 1 wei rounding tolerance from integer division.
        assertLe(sum, totalDelegatedAfterYield, "sum <= total");
        assertLe(totalDelegatedAfterYield - sum, 1, "sum within 1 wei");
    }

    /// @notice A real share `transfer()` conserves asset-denominated votes between sender and receiver.
    /// @dev Transferring shares moves raw units via `_update` without touching totalAssets/totalSupply,
    ///      so both holders' asset-denominated votes must sum to the pre-transfer total within 1 wei.
    function testShareTransferKeepsAssetDenominatedVotesConserved() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(VICTIM);
        vault.deposit(10 ether, VICTIM);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);
        vm.prank(VICTIM);
        vault.delegate(VICTIM);

        // Yield first so the exchange rate is not 1:1; conservation must hold post-yield too.
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        uint256 totalBefore = vault.getVotes(ATTACKER) + vault.getVotes(VICTIM);
        uint256 victimBefore = vault.getVotes(VICTIM);

        // Real ERC20 share transfer: ATTACKER sends 3 shares to VICTIM.
        vm.prank(ATTACKER);
        assertTrue(vault.transfer(VICTIM, 3 ether));

        uint256 totalAfter = vault.getVotes(ATTACKER) + vault.getVotes(VICTIM);
        uint256 victimAfter = vault.getVotes(VICTIM);

        // Transfer does not change totalAssets or totalSupply, so the asset-vote total is conserved.
        // Integer division can shift the per-holder sum by ±1 wei in either direction, so use a
        // symmetric tolerance. A one-sided uint subtraction would underflow if rounding pushed
        // totalAfter above totalBefore.
        assertApproxEqAbs(totalAfter, totalBefore, 1, "asset votes conserved within 1 wei");
        assertGt(victimAfter, victimBefore, "receiver gained votes");
    }

    /// @notice Empty vault, first depositor, and managed donation edge cases are safe.
    function testEmptyVaultAndFirstDepositorEdgeCases() external {
        assertEq(vault.getVotes(ATTACKER), 0, "empty vault votes = 0");

        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(1 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        assertEq(vault.getVotes(ATTACKER), 1 ether, "first depositor votes = deposit");

        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(100 ether);

        vm.warp(300);
        assertEq(vault.getPastVotes(ATTACKER, 100), 1 ether, "snapshot votes unaffected by later donation");
        assertGt(vault.getVotes(ATTACKER), 1 ether, "current votes reflect donation");
    }

    /// @notice Direct ERC20 transfer to vault address does not change votes or total supply.
    function testDirectERC20TransferDoesNotAffectVotes() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        uint256 votesBefore = vault.getVotes(ATTACKER);

        vm.prank(ATTACKER);
        assertTrue(asset.transfer(address(vault), 100 ether));

        assertEq(vault.getVotes(ATTACKER), votesBefore, "votes unchanged by raw transfer");

        vm.warp(200);
        assertEq(vault.getPastTotalSupply(100), 10 ether, "total supply unchanged by raw transfer");
    }

    /// @notice totalAssets checkpoints and IVotes checkpoints share the same ERC-6372 timepoint domain.
    function testTotalAssetsCheckpointsUseSameTimestampTimepoint() external {
        // Use the standard vault deployed in setUp (no test-harness subclass needed).
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        // getTotalAssetsCheckpointLen() is inherited from OutrunVotesInit — no helper needed.
        assertEq(vault.getTotalAssetsCheckpointLen(), 1, "one checkpoint after deposit");

        vm.warp(200);
        // Verify the checkpoint value indirectly: at 1:1 rate, pastTotalSupply == deposit amount.
        assertEq(vault.getPastTotalSupply(100), 10 ether, "checkpoint records totalAssets at deposit time");
        assertEq(vault.CLOCK_MODE(), "mode=timestamp", "clock mode");
    }

    /// @notice getPastTotalSupply equals real shares at historical rate, not total managed assets.
    function testSmallDepositorLargeDonation_TotalSupplyNotEqualToTotalAssets() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(1 ether, ATTACKER);

        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(1000 ether);

        vm.warp(300);
        assertEq(vault.getPastTotalSupply(100), 1 ether, "snapshot total = deposit amount");

        uint256 currentTotal = vault.getPastTotalSupply(200);
        uint256 expected = Math.mulDiv(1 ether, 1001 ether + VIRTUAL_ASSETS, 1 ether + VIRTUAL_ASSETS);
        assertEq(currentTotal, expected, "total supply = shares * rate");
        assertLt(currentTotal, 1001 ether, "total supply < totalAssets when virtual share captures value");
    }

    /// @notice Multiple yield rounds keep each historical snapshot at its own exchange rate.
    /// @dev Exercises a checkpoint chain longer than two entries through the binary lookup path.
    function testMultipleYieldRoundsProduceCorrectHistoricalVotes() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        // Round 1: +10 yield, rate moves to 2.0
        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        // Round 2: +20 yield, rate moves to 4.0
        vm.warp(300);
        vm.prank(ATTACKER);
        vault.accumulateYields(20 ether);

        // Query from a later block so every snapshot is strictly in the past.
        vm.warp(400);

        // Snapshot at t=100 (rate 1.0): 10 shares * (10+V)/(10+V) = 10 assets.
        assertEq(vault.getPastVotes(ATTACKER, 100), 10 ether, "votes@100 = raw shares");
        // Snapshot at t=200 (rate 2.0): past total assets = 20.
        assertEq(
            vault.getPastVotes(ATTACKER, 200),
            Math.mulDiv(10 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "votes@200 reflect round-1 rate"
        );
        // Snapshot at t=300 (rate 4.0): past total assets = 40.
        assertEq(
            vault.getPastVotes(ATTACKER, 300),
            Math.mulDiv(10 ether, 40 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "votes@300 reflect round-2 rate"
        );
    }

    /// @notice Same-block deposit then yield records the post-yield asset value at that timepoint.
    /// @dev The total-assets checkpoint is overwritten in-block while share supply reflects the deposit.
    function testSameBlockDepositAndYieldCheckpointAlignment() external {
        // Seed a first depositor so the later yield is not burned.
        vm.warp(100);
        vm.prank(VICTIM);
        vault.deposit(10 ether, VICTIM);

        // Same block: ATTACKER deposits 10, then 5 yield lands.
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        // Block end state: shares = 20, managed assets = 25.
        vm.warp(200);
        uint256 pastTotal = vault.getPastTotalSupply(100);
        assertEq(
            pastTotal,
            Math.mulDiv(20 ether, 25 ether + VIRTUAL_ASSETS, 20 ether + VIRTUAL_ASSETS),
            "same-block total = shares * post-yield rate"
        );
    }

    /// @notice Redeeming the entire supply to zero then re-depositing keeps votes consistent.
    /// @dev Guards checkpoint chain continuity across the empty-vault boundary.
    function testRedeemToZeroThenRedepositRestoresVotes() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(10 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);
        assertEq(vault.getVotes(ATTACKER), 10 ether, "votes before redeem");

        // Burn every share: supply and managed assets both return to zero.
        vm.prank(ATTACKER);
        vault.requestRedeem(shares, ATTACKER);
        assertEq(vault.getVotes(ATTACKER), 0, "votes zero after full redeem");

        vm.warp(block.timestamp + 1 days);
        vm.prank(ATTACKER);
        vault.executeRedeem();

        // Fresh deposit in a new block: rate resets to 1:1, votes equal assets.
        vm.warp(300);
        vm.prank(ATTACKER);
        vault.deposit(20 ether, ATTACKER);
        assertEq(vault.getVotes(ATTACKER), 20 ether, "votes restored after redeposit");
    }

    /// @notice A 1000x yield rate does not overflow and the V buffer visibly dampens the sole-holder's vote gain.
    /// @dev With virtual buffer V, sole-holder votes = shares * (totalAssets + V) / (totalSupply + V). The raw
    ///      asset value grew 1000x but the buffer caps the sole holder's vote gain far below that multiple,
    ///      documenting that extreme donation cannot inflate a staker's voting power toward totalAssets.
    function testExtremeYieldRateStaysWithinConventionSlack() external {
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(1 ether, ATTACKER);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);

        // Donate 999x the deposit to push the raw rate to 1000x.
        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(999 ether);

        vm.warp(300);
        uint256 votes = vault.getPastVotes(ATTACKER, 200);
        assertEq(
            votes, Math.mulDiv(1 ether, 1000 ether + VIRTUAL_ASSETS, 1 ether + VIRTUAL_ASSETS), "votes match +V formula"
        );
        // The buffer dampens the 1000x asset growth into a small vote multiple instead of tracking totalAssets.
        // Un-buffered votes would be 1000 ether (sole holder owns all shares); V keeps votes far below that.
        assertLt(votes, 1000 ether, "buffer caps sole-holder votes below raw totalAssets");
        assertLt(votes, 12 ether, "buffer dampens 1000x donation into a near-1x vote multiple");
        assertGt(votes, 1 ether, "yield is still reflected in votes");
    }

    /// @notice Verifies deposit(0) returns 0 without minting, transferring, or writing checkpoints.
    /// @dev Guards the round-trip-preserving early return in `deposit`.
    function testDepositZeroReturnsEarlyWithoutSideEffects() external {
        vm.prank(VICTIM);
        vault.deposit(10 ether, VICTIM);
        uint256 baselineLen = vault.getTotalAssetsCheckpointLen();
        uint256 baselineAssets = vault.totalAssets();

        vm.prank(ATTACKER);
        uint256 shares = vault.deposit(0, RECEIVER);

        assertEq(shares, 0, "deposit(0) shares");
        assertEq(vault.balanceOf(RECEIVER), 0, "no mint to receiver");
        assertEq(vault.totalAssets(), baselineAssets, "totalAssets unchanged");
        assertEq(vault.getTotalAssetsCheckpointLen(), baselineLen, "no new checkpoint");
    }

    /// @notice A non-zero deposit that rounds down to 0 shares reverts instead of absorbing the caller's assets.
    /// @dev At rate > 1 (A=15e18, S=10e18, V=100 ether), 1 wei of assets maps to 0 shares; the deposit must
    ///      revert with ZeroSharesDeposit before any transfer, leaving totalAssets and the caller's balance
    ///      untouched so the caller can top up and retry.
    function test_DepositRevertsWhenSharesRoundToZero() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);
        assertEq(vault.totalAssets(), 15 ether, "fixture: rate > 1");

        uint256 victimBalanceBefore = asset.balanceOf(VICTIM);

        vm.prank(VICTIM);
        vm.expectRevert(IMemecoinYieldVault.ZeroSharesDeposit.selector);
        vault.deposit(1, VICTIM);

        assertEq(vault.totalAssets(), 15 ether, "totalAssets unchanged after revert");
        assertEq(asset.balanceOf(VICTIM), victimBalanceBefore, "caller assets not pulled after revert");
    }

    /// @notice The zero-share guard also fires in the residual state (S=0, A>0).
    /// @dev After all shares are burned via requestRedeem, managed assets remain; a sub-threshold deposit
    ///      still maps to 0 shares and must revert rather than leaving unowned dust in the vault.
    function test_DepositRevertsWhenSharesRoundToZeroInResidualState() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        // Burn every share; requestRedeem requires receiver == msg.sender (NotSelfRedemption).
        uint256 attackerShares = vault.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        vault.requestRedeem(attackerShares, ATTACKER);
        assertEq(vault.totalSupply(), 0, "fixture: no shares outstanding");
        assertGt(vault.totalAssets(), 0, "fixture: residual assets remain");

        vm.prank(VICTIM);
        vm.expectRevert(IMemecoinYieldVault.ZeroSharesDeposit.selector);
        vault.deposit(1, VICTIM);
    }

    /// @notice The zero-share guard only rejects deposits that round down to 0 shares.
    /// @dev In the same rate > 1 fixture, depositing 2 wei maps to 1 share and must not revert,
    ///      proving the guard does not over-block deposits with a sub-1-share but non-zero value.
    function test_DepositBelowThresholdButNonZeroSharesDoesNotRevert() external {
        vm.prank(ATTACKER);
        vault.deposit(10 ether, ATTACKER);

        vm.prank(ATTACKER);
        vault.accumulateYields(5 ether);

        vm.prank(VICTIM);
        uint256 shares = vault.deposit(2, VICTIM);

        assertEq(shares, 1, "2 wei maps to 1 share at the fixture rate");
    }

    /// @notice Verifies accumulateYields(0) leaves totalAssets and checkpoints unchanged.
    /// @dev Guards the zero-yield early return in `_accumulateYield`.
    function testAccumulateZeroYieldReturnsEarlyWithoutSideEffects() external {
        vm.prank(VICTIM);
        vault.deposit(10 ether, VICTIM);
        uint256 baselineLen = vault.getTotalAssetsCheckpointLen();
        uint256 baselineAssets = vault.totalAssets();

        vm.prank(ATTACKER);
        vault.accumulateYields(0);

        assertEq(vault.totalAssets(), baselineAssets, "totalAssets unchanged");
        assertEq(vault.getTotalAssetsCheckpointLen(), baselineLen, "no new checkpoint");
    }

    /// @notice A yield landing between two snapshot timepoints is reflected only at the later
    ///         snapshot, and scales every voter by the same factor so it cannot flip a proposal's
    ///         pass/fail outcome (griefing neutral).
    /// @dev OZ Governor sets `proposalSnapshot = clock() + votingDelay`, a future timepoint, so a
    ///      permissionless `accumulateYields` during the delay window writes a checkpoint the
    ///      snapshot reads. This documents that the window is harmless: the earlier snapshot stays
    ///      immutable, and the donation preserves each voter's share of total votes.
    function testYieldDuringSnapshotWindowPreservesVoterShare() external {
        // Split supply 6:4 between two stakers.
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(6 ether, ATTACKER);
        vm.prank(VICTIM);
        vault.deposit(4 ether, VICTIM);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);
        vm.prank(VICTIM);
        vault.delegate(VICTIM);

        // Yield lands at T=200 — between the baseline snapshot (T=100) and a later one.
        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether); // totalAssets 10 -> 20, rate 2.0

        // Query from T=300 so both 100 and 200 are strictly past.
        vm.warp(300);

        // Immutability: the pre-yield snapshot keeps rate-1.0 votes.
        assertEq(vault.getPastVotes(ATTACKER, 100), 6 ether, "pre-yield snapshot immutable");
        assertEq(vault.getPastVotes(VICTIM, 100), 4 ether, "pre-yield snapshot immutable");

        // The post-yield snapshot reflects the doubled rate.
        uint256 attackerAt200 = vault.getPastVotes(ATTACKER, 200);
        uint256 victimAt200 = vault.getPastVotes(VICTIM, 200);
        assertEq(
            attackerAt200,
            Math.mulDiv(6 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "attacker votes reflect yield"
        );
        assertEq(
            victimAt200,
            Math.mulDiv(4 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "victim votes reflect yield"
        );

        // Griefing neutrality: the donation scaled both voters by the same factor, so the
        // attacker:victim ratio (3:2) is preserved within rounding. A donation moves every vote
        // and the quorum denominator by one multiplier, so it cannot change a proposal's outcome.
        assertApproxEqAbs(attackerAt200 * 2, victimAt200 * 3, 4, "voter ratio preserved (griefing neutral)");
    }

    /// @notice Yield landing exactly at the proposal snapshot timepoint is reflected in getPastVotes.
    /// @dev Governor sets `proposalSnapshot = clock() + votingDelay`. When yield arrives at that
    ///      exact timestamp, the snapshot reads post-yield values. This documents that yield during
    ///      the voting-delay window is harmless: each voter's share of total votes is preserved,
    ///      and the snapshot correctly captures the yield-inclusive exchange rate.
    function testYieldAtSnapshotTimepointReflectedInGetPastVotes() external {
        // Deposit at T=100, split 6:4.
        vm.warp(100);
        vm.prank(ATTACKER);
        vault.deposit(6 ether, ATTACKER);
        vm.prank(VICTIM);
        vault.deposit(4 ether, VICTIM);
        vm.prank(ATTACKER);
        vault.delegate(ATTACKER);
        vm.prank(VICTIM);
        vault.delegate(VICTIM);

        // Yield lands at T=200 — the exact timepoint a Governor with votingDelay=100 would snapshot.
        vm.warp(200);
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether); // totalAssets 10 -> 20, rate 2.0

        // Query from T=300 so T=200 is strictly past.
        vm.warp(300);

        // The snapshot at T=200 reflects the post-yield exchange rate.
        uint256 attackerVotes = vault.getPastVotes(ATTACKER, 200);
        uint256 victimVotes = vault.getPastVotes(VICTIM, 200);
        assertEq(
            attackerVotes,
            Math.mulDiv(6 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "attacker votes at snapshot"
        );
        assertEq(
            victimVotes,
            Math.mulDiv(4 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "victim votes at snapshot"
        );

        // Total supply at snapshot reflects post-yield rate.
        uint256 totalSupplyAtSnapshot = vault.getPastTotalSupply(200);
        assertEq(
            totalSupplyAtSnapshot,
            Math.mulDiv(10 ether, 20 ether + VIRTUAL_ASSETS, 10 ether + VIRTUAL_ASSETS),
            "total supply at snapshot"
        );

        // Voter ratio preserved: 6:4 = 3:2 scaling is uniform.
        assertApproxEqAbs(attackerVotes * 2, victimVotes * 3, 4, "voter ratio preserved at snapshot");
    }

    // ──────────────────────────────────────────────────────────────────────────────
    // Virtual buffer V tests (spec §4)
    // ──────────────────────────────────────────────────────────────────────────────

    /// @notice initialize stores the supplied virtual buffer verbatim and exposes it via the getter.
    function testInitializeStoresVirtualAssets() external view {
        assertEq(vault.virtualAssets(), VIRTUAL_ASSETS, "virtualAssets stored from initialize");
    }

    /// @notice A zero virtual buffer must be rejected so the +V guards actually dampen the rate.
    /// @dev V=0 would degenerate share/asset math to the un-buffered form and remove the donation dampener.
    function testInitializeRevertsOnZeroVirtualAssets() external {
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        MemecoinYieldVault zeroVault = MemecoinYieldVault(Clones.clone(address(implementation)));
        vm.expectRevert(IMemecoinYieldVault.ZeroVirtualAssets.selector);
        zeroVault.initialize("Zero V", "zMEME", address(0xD15A7), address(asset), 1, 0);
    }

    /// @notice A large yield injection moves the exchange rate by far less than the un-buffered case.
    /// @dev With V, the post-donation price is (D + V) / (shares + V); without V it would be ~D / shares.
    ///      Here a 1000x donation only moves the rate from 1.0 to ~1.099x instead of ~1000x.
    function testVirtualBufferDampensDonationRateInflation() external {
        vm.prank(ATTACKER);
        vault.deposit(1 ether, ATTACKER);

        // Without the buffer this donation would push the rate to 1000x; with V it stays near 1.1x.
        vm.prank(ATTACKER);
        vault.accumulateYields(1000 ether);

        // Price per share = totalAssets / shares, buffered.
        uint256 bufferedPrice = vault.previewRedeem(1 ether);
        uint256 expectedBuffered = Math.mulDiv(1 ether, 1001 ether + VIRTUAL_ASSETS, 1 ether + VIRTUAL_ASSETS);
        assertEq(bufferedPrice, expectedBuffered, "buffered price follows +V formula");
        // The buffer caps inflation well below the un-buffered 1001x ceiling.
        assertLt(bufferedPrice, 12 ether, "rate inflation dampened far below un-buffered 1000x");
        assertGt(bufferedPrice, 1 ether, "yield still reflected in price");
    }

    /// @notice Yield is absorbed pro-rata: a late depositor receives shares at the post-yield rate, and
    ///         earlier holders can redeem for more assets than they deposited.
    function testYieldAbsorbedProRataAcrossHolders() external {
        vm.prank(ATTACKER);
        uint256 attackerShares = vault.deposit(10 ether, ATTACKER);

        // Yield lands while only ATTACKER holds shares.
        vm.prank(ATTACKER);
        vault.accumulateYields(10 ether);

        // VICTIM deposits after yield: receives fewer shares because each share is now worth more.
        vm.prank(VICTIM);
        uint256 victimShares = vault.deposit(10 ether, VICTIM);
        assertLt(victimShares, attackerShares, "later depositor gets fewer shares post-yield");

        // ATTACKER redeems and recovers more than the 10 ether deposited — yield is absorbed, not trapped.
        vm.prank(ATTACKER);
        uint256 lockedAssets = vault.requestRedeem(attackerShares, ATTACKER);
        assertGt(lockedAssets, 10 ether, "attacker redeems principal + yield share");
    }

    /// @notice Empty-vault yield is still burned; while the vault is entirely empty (totalSupply == totalAssets == 0)
    ///         the +V buffer cancels out of the share/asset conversion, so burn-on-empty is rate-neutral.
    /// @dev Guards the orthogonality between burn-on-empty (§5) and the V buffer (§4). Uses a compose-style
    ///      asset mock because the burn path calls `IMemecoin.burn(uint256)` (single-arg, from msg.sender =
    ///      the vault), which solmate's `MockERC20.burn(address,uint256)` does not satisfy.
    function testEmptyVaultYieldIsBurnedRegardlessOfVirtualBuffer() external {
        // Deploy a fresh vault bound to an asset that implements IMemecoin's single-arg `burn(uint256)`.
        MockComposeAsset burnableAsset = new MockComposeAsset();
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        MemecoinYieldVault emptyVault = MemecoinYieldVault(Clones.clone(address(implementation)));
        emptyVault.initialize("Empty Vault", "eMEME", address(0xD15A7), address(burnableAsset), 3, VIRTUAL_ASSETS);

        burnableAsset.mint(ATTACKER, 50 ether);
        vm.prank(ATTACKER);
        burnableAsset.approve(address(emptyVault), type(uint256).max);

        assertEq(emptyVault.totalAssets(), 0, "vault starts empty");
        assertEq(burnableAsset.balanceOf(address(emptyVault)), 0, "vault holds no asset before yield");

        // Fund ATTACKER with yield to inject; the vault pulls it then burns it because totalSupply == 0.
        vm.prank(ATTACKER);
        emptyVault.accumulateYields(50 ether);

        assertEq(emptyVault.totalAssets(), 0, "totalAssets unchanged after burn-on-empty");
        assertEq(burnableAsset.balanceOf(address(emptyVault)), 0, "vault holds no burned yield");
    }

    /// @notice Vault-side E2E (finding part B): a REAL OFT `_lzReceive` writes the compose queue the vault's
    ///         `reAccumulateYields` recovery entry reads — the runbook chain's first hop (OFT mints the bridged
    ///         amount to the dispatcher) through the re-accumulate retry (queue proof → Released), with the settle
    ///         payload copied VERBATIM from the endpoint's ComposeSent log.
    /// @dev The OFT's endpoint immutable is the SAME etched mock (0x9999) the dispatcher's `localEndpoint` immutable
    ///      points at, so `_lzReceive`'s `endpoint.sendCompose(toAddress, guid, 0, composeMsg)` writes
    ///      `composeQueue[oft][dispatcher][guid][0] = keccak256(composeMsg)` — the exact key `verifySettle` reads when
    ///      `reAccumulateYields` retries. Mirrors the OFTHarness wiring of YieldDispatcher.t.sol's E2E tests.
    function testE2E_OFTLzReceiveWritesComposeQueueReadByReAccumulateYields() external {
        // The dispatcher's endpoint (0x9999) is fixed by _deployComposeVaultWithDispatcher; the real OFT must use the
        // same address so its sendCompose lands in the queue the retry reads.
        OFTHarness implementation = new OFTHarness(address(0x9999));
        OFTHarness oft = OFTHarness(Clones.clone(address(implementation)));

        // Etch the endpoint mock onto 0x9999 (and the dispatcher onto 0xD15A7) BEFORE initializing the OFT: the OFT
        // initializer calls endpoint.setDelegate, which needs the etched code to be in place.
        (MemecoinYieldVault composeVault, address dispatcherAddr,) = _deployComposeVaultWithDispatcher(address(oft));

        oft.initialize(address(this), "E2E Meme", "E2EM", address(0xCAFE));
        oft.setPeer(101, bytes32(uint256(uint160(0xBEEF))));

        // Seed an existing deposit so _accumulateYield credits totalAssets (non-empty vault path).
        oft.mintTest(ATTACKER, 10 ether);
        vm.prank(ATTACKER);
        oft.approve(address(composeVault), type(uint256).max);
        vm.prank(ATTACKER);
        composeVault.deposit(10 ether, ATTACKER);
        assertEq(composeVault.totalAssets(), 10 ether, "fixture: seeded deposit");

        // Raw OFT _lzReceive wire payload: sendTo(32) || amountSD(8) || composeFrom(32) || composeMessage — the same
        // layout as YieldDispatcher.t.sol's _encodeOftLzReceiveMessage (mirrors OFTMsgCodec.encode). amount must be an
        // exact multiple of decimalConversionRate (1e12) so amountReceivedLD round-trips exactly.
        uint256 amount = 5 ether;
        bytes32 guid = keccak256("e2e-oft-guid");
        bytes memory composeMessage = abi.encode(address(composeVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        bytes32 composeFrom = bytes32(uint256(uint160(ATTACKER)));
        bytes memory message = abi.encodePacked(
            bytes32(uint256(uint160(dispatcherAddr))), // sendTo = the dispatcher
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );

        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 1});
        bytes32 composeSentTopic0 = keccak256("ComposeSent(address,address,bytes32,uint16,bytes)");
        vm.recordLogs();
        vm.prank(address(0x9999));
        oft.lzReceive(origin, guid, message, address(0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Runbook chain hop 1: the OFT minted the bridged amount to the payload's sendTo (the dispatcher).
        assertEq(oft.balanceOf(dispatcherAddr), amount, "OFT minted the bridged amount to the dispatcher");

        // Take the settle payload VERBATIM from the ComposeSent log (the runbook's "原样拷贝 message 字段" step); it
        // hashes to the queue slot verifySettle reads.
        bytes memory settleMessage;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != composeSentTopic0) continue;
            found = true;
            (address from, address to, bytes32 logGuid, uint16 index, bytes memory payload) =
                abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
            assertEq(from, address(oft), "ComposeSent from is the OFT");
            assertEq(to, dispatcherAddr, "ComposeSent to is the dispatcher");
            assertEq(logGuid, guid, "ComposeSent guid");
            assertEq(uint256(index), 0, "ComposeSent index");
            settleMessage = payload;
        }
        assertTrue(found, "lzReceive -> sendCompose emitted ComposeSent");
        assertEq(
            MockMessagingComposerEndpoint(address(0x9999)).composeQueue(address(oft), dispatcherAddr, guid, 0),
            keccak256(settleMessage),
            "queue slot matches the verbatim settle payload"
        );

        // Runbook recovery entry: the vault retries the stuck compose with the verbatim payload.
        composeVault.reAccumulateYields(dispatcherAddr, guid, settleMessage);

        assertEq(composeVault.totalAssets(), 15 ether, "total assets after re-accumulate (10 deposit + 5 yield)");
        assertEq(
            uint256(YieldDispatcher(dispatcherAddr).composeStates(address(oft), guid)),
            uint256(IComposeState.ComposeState.Released),
            "dispatcher marked released"
        );
    }

    /// @dev Deploys a fresh compose-vault clone and a real YieldDispatcher, etching the dispatcher onto the
    ///      fixed `0xD15A7` address the vault references as `yieldDispatcher` and the mock composer endpoint
    ///      onto `0x9999`. Every `reAccumulateYields` retry-path test calls this so dispatcher-constructor /
    ///      etch drift has a single edit point. Returns the etched `dispatcherAddr` (state MUST be read via
    ///      `YieldDispatcher(dispatcherAddr)`, since `vm.etch` copies only code, not storage — the in-memory
    ///      `dispatcher` instance is a distinct storage context) and the mock `endpointAddr` (used to plant
    ///      the compose queue).
    function _deployComposeVaultWithDispatcher(address asset)
        internal
        returns (MemecoinYieldVault composeVault, address dispatcherAddr, address endpointAddr)
    {
        composeVault = MemecoinYieldVault(Clones.clone(address(new MemecoinYieldVault())));
        dispatcherAddr = address(0xD15A7);
        endpointAddr = address(0x9999);
        MockMessagingComposerEndpoint endpointImpl = new MockMessagingComposerEndpoint();
        vm.etch(endpointAddr, address(endpointImpl).code);
        YieldDispatcher dispatcher = new YieldDispatcher(endpointAddr, address(this));
        vm.etch(dispatcherAddr, address(dispatcher).code);
        composeVault.initialize("Compose Vault", "cvMEME", dispatcherAddr, asset, 2, VIRTUAL_ASSETS);
    }

    /// @dev Builds the OFT compose payload a launcher would have sent for a memecoin-yield retry:
    ///      `composeFrom(ATTACKER)` + `abi.encode(targetVault, MEMECOIN)`, wrapped via OFTComposeMsgCodec.
    function _buildMemecoinComposeMessage(address targetVault, uint256 amount)
        internal
        pure
        returns (bytes memory message)
    {
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ATTACKER))), abi.encode(targetVault, IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
    }

    /// @dev Builds a raw OFT compose frame with a caller-supplied tail: nonce(8) + srcEid(4) + amountLD(32) +
    ///      composeFrom(32) + tail — the same packing as OFTComposeMsgCodec.encode — so boundary tests can
    ///      exercise exact frame lengths (108/120/140) that the high-level helper cannot produce. The receiver
    ///      word sits at [76:108], i.e. the first 32 bytes of `tail`.
    function _buildRawComposeFrame(uint256 amountLD, bytes memory tail) internal pure returns (bytes memory message) {
        message = abi.encodePacked(bytes8(uint64(1)), uint32(101), amountLD, bytes32(uint256(uint160(ATTACKER))), tail);
    }

    /// @notice Anchors MR-69's window invariant: while a full-redeem queue is in-flight (shares burned but
    ///         REDEEM_DELAY not yet elapsed), incoming yield hits the `totalSupply() == 0` burn branch and is
    ///         burned, yet the queued redemption obligation is neither consumed nor diluted — the matured
    ///         `executeRedeem` still pays the full locked amount. Distinct from the existing empty-vault test,
    ///         which starts from a vault that was never deposited into; here the vault WAS deposited into, the
    ///         shares were then fully burned by `requestRedeem`, and assets physically remain in the vault as a
    ///         pending obligation during the delay window.
    /// @dev Window semantics under test: `totalSupply() == 0` AND `totalAssets() == 0` AND a non-empty
    ///      `redeemRequestQueues[ATTACKER]` (queued amount sitting in the vault balance). Yield arriving in this
    ///      window is pulled in then burned via `IMemecoin.burn(uint256)`, which destroys only the freshly-arrived
    ///      yield held by the vault, not the queued obligation. Uses `MockComposeAsset` because the burn path calls
    ///      `IMemecoin.burn(uint256)` (single-arg, from the caller = the vault), which solmate `MockERC20`'s
    ///      two-arg `burn(address,uint256)` does not satisfy. Calls `accumulateYields` directly (no dispatcher /
    ///      settle / `reAccumulateYields`): the target is the window's state invariant, not the retry path, which
    ///      is already covered by the empty-vault burn test plus this test's burn-branch coverage.
    function testAccumulateYieldsBurnsYieldDuringQueuedRedeemWindow() external {
        // Compose-style asset implements the single-arg burn the vault's empty-vault path calls.
        MockComposeAsset composeAsset = new MockComposeAsset();
        (MemecoinYieldVault composeVault,,) = _deployComposeVaultWithDispatcher(address(composeAsset));

        // Fund ATTACKER and approve the vault for both the initial deposit and the later yield pull.
        composeAsset.mint(ATTACKER, 10 ether);
        vm.prank(ATTACKER);
        composeAsset.approve(address(composeVault), type(uint256).max);

        // Deposit principal; with no prior yield the share rate is 1:1 so 10 ether deposits 10 shares.
        vm.prank(ATTACKER);
        uint256 shares = composeVault.deposit(10 ether, ATTACKER);
        assertEq(shares, 10 ether, "initial deposit mints 1:1 shares");

        // Full redemption request: burns all shares and deducts totalAssets, but assets stay in the vault
        // as a pending obligation until REDEEM_DELAY elapses.
        vm.prank(ATTACKER);
        uint256 lockedAssets = composeVault.requestRedeem(shares, ATTACKER);
        assertEq(lockedAssets, 10 ether, "locked amount equals principal at no-yield state");

        // Window-state assertions: empty on the books but the queued obligation physically sits in the vault.
        assertEq(composeVault.totalSupply(), 0, "shares fully burned by requestRedeem");
        assertEq(composeVault.totalAssets(), 0, "totalAssets deducted by requestRedeem");
        (uint192 queuedAmount,) = composeVault.redeemRequestQueues(ATTACKER, 0);
        assertEq(uint256(queuedAmount), lockedAssets, "queued obligation equals locked amount");
        assertGe(
            composeAsset.balanceOf(address(composeVault)),
            lockedAssets,
            "queued obligation assets physically held by vault during window"
        );

        // Snapshot the vault balance right before yield arrives: this is exactly the queued obligation.
        uint256 vaultBalanceBeforeYield = composeAsset.balanceOf(address(composeVault));

        // Keep the timestamp inside the REDEEM_DELAY window (do NOT warp) and inject yield directly.
        uint256 yieldAmount = 5 ether;
        composeAsset.mint(ATTACKER, yieldAmount);
        vm.prank(ATTACKER);
        composeVault.accumulateYields(yieldAmount);

        // Invariant: yield was burned (not retained). The pull temporarily raised the vault balance by
        // yieldAmount; the burn then destroyed exactly that freshly-arrived yield, leaving the vault balance
        // back at the pre-yield snapshot — i.e. the queued obligation is untouched.
        assertEq(
            composeAsset.balanceOf(address(composeVault)),
            vaultBalanceBeforeYield,
            "yield burned, vault balance restored to pre-yield (queued obligation untouched)"
        );
        assertEq(composeVault.totalAssets(), 0, "burned yield never enters totalAssets accounting");
        assertEq(composeVault.totalSupply(), 0, "burn branch keeps totalSupply at zero");

        // Mature the queue past REDEEM_DELAY and settle: the full locked obligation must still be payable.
        vm.warp(block.timestamp + 1 days);
        uint256 attackerBalanceBefore = composeAsset.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 redeemed = composeVault.executeRedeem();

        assertEq(redeemed, lockedAssets, "matured executeRedeem pays the full locked obligation");
        assertEq(
            composeAsset.balanceOf(ATTACKER),
            attackerBalanceBefore + lockedAssets,
            "attacker receives the full queued amount after window closes"
        );
    }
}
