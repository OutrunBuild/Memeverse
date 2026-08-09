// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

// Historical trace: regression test for the unlimited-approval amplifier.

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {OmnichainMemecoinStaker} from "../../src/interoperation/OmnichainMemecoinStaker.sol";
import {IOmnichainMemecoinStaker} from "../../src/interoperation/interfaces/IOmnichainMemecoinStaker.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {MockStakerYieldVault} from "../mocks/interoperation/InteroperationMocks.sol";
import {ForgedComposeToken} from "../mocks/interoperation/ForgedComposeToken.sol";
import {ComposerEndpointFixture} from "../mocks/infrastructure/ComposerEndpointFixture.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {MockOFTEndpoint} from "../mocks/common/CommonMocks.sol";
import {OFTHarness} from "../mocks/infrastructure/OFTHarness.sol";

/// @dev Attacker-controlled "yield vault" used by this regression suite. The staker's `lzCompose` decodes the
///      vault address from a forgeable compose message, so it grants only an EXACT-amount approval
///      (`_safeApprove(token, vault, amount)`) before calling `deposit(amount, receiver)`. This vault's deposit
///      callback records the allowance it actually observes, tries to pull the staker's ENTIRE memecoin balance
///      (must revert: allowance insufficient), and then falls back to pulling only the exact granted amount.
///      It also LIES in `asset()` (reports the real memecoin) so the staker's first defense layer — the
///      token-vault binding check (`require(IMemecoinYieldVault(yieldVault).asset() == memecoin,
///      TokenVaultMismatch())`) — passes when the delivered token really is the memecoin; the second, backstop
///      defense layer is the exact-amount approval cap, which limits the vault's pull to the bridged amount.
contract SpoofedYieldVault {
    address public immutable token;
    address public immutable staker;
    address public immutable attacker;

    uint256 public lastDepositAssets;
    address public lastDepositReceiver;
    uint256 public observedAllowance;
    uint256 public attemptedDrain;
    bool public overdraftReverted;

    constructor(address token_, address staker_, address attacker_) {
        token = token_;
        staker = staker_;
        attacker = attacker_;
    }

    /// @notice Underlying asset the vault reports to the staker's token-vault binding check.
    /// @dev Lies on purpose: reports the REAL memecoin so the pairing reaches the exact-approval layer — the
    ///      staker compares this against the DELIVERED token, so the lie only passes when the delivered token is
    ///      genuinely the memecoin (exactly the case the approval cap must contain).
    /// @return tokenAddress The real memecoin OFT this mock's pulls operate on.
    function asset() external view returns (address tokenAddress) {
        return token;
    }

    /// @notice Attacker-controlled deposit: first tries to pull every memecoin the staker holds; with the
    ///         exact-amount approval that overdraft must revert, leaving only the exact granted `assets` pullable.
    /// @param assets Amount the staker asked to deposit (the exact approval cap post-fix).
    /// @param receiver Share receiver requested by the staker (recorded only).
    /// @return shares Shares minted to the receiver (the mock mints nothing; the value is unconstrained).
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        lastDepositAssets = assets;
        lastDepositReceiver = receiver;
        observedAllowance = IERC20(token).allowance(staker, address(this));
        attemptedDrain = IERC20(token).balanceOf(staker);
        // Post-fix the staker granted only `assets`; pulling the full balance must revert (ERC20InsufficientAllowance).
        try IERC20(token).transferFrom(staker, attacker, attemptedDrain) {
            revert("F02: overdraft succeeded - fix regressed");
        } catch {
            overdraftReverted = true;
            // With the overdraft capped, the vault can only pull the exact bridged amount granted to it.
            IERC20(token).transferFrom(staker, attacker, assets);
        }
        shares = assets;
    }
}

/// @notice Regression test (post-fix): exact-amount approval caps loss to the bridged amount. The staker's
///         `lzCompose` approves (exactly the bridged amount) and deposits into ANY contract address decoded from
///         the compose payload, so an attacker can still force a deposit into an attacker contract — but that
///         contract can now pull at most the amount the attacker bridged, and can no longer drain the staker's
///         entire memecoin balance, including other users' stranded/pending compose funds. The harness vault LIES
///         in `asset()` (reports the real memecoin) to pass the token-vault binding check, so the tests
///         exercise the binding + exact-approval defense layers together, as they stack on the
///         genuine-bridge attack path.
/// @dev Reproduces the full cross-chain chain with real code: attacker `send()` on the source OFT → real
///      `_lzReceive`/`_credit`/`sendCompose` on the destination OFT → permissionless composer `lzCompose` →
///      staker binding check → exact-amount `_safeApprove` + external `deposit`. Only the endpoint is mocked
///      (MockOFTEndpoint for send, MockMessagingComposerEndpoint etched at the fixed endpoint address, mirroring
///      EndpointV2's embedded MessagingComposer semantics).
contract StakerExactApprovalTest is ComposerEndpointFixture {
    using Clones for address;

    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);
    uint32 internal constant SRC_EID = 30102;
    uint32 internal constant DST_EID = 30101;

    OmnichainMemecoinStaker internal staker;
    MockMessagingComposerEndpoint internal composer; // etched at LOCAL_ENDPOINT (EndpointV2 embeds MessagingComposer)
    MockOFTEndpoint internal srcEndpoint;
    OFTHarness internal srcOft; // source-chain memecoin OFT instance (attacker/victim hold tokens there)
    OFTHarness internal memecoin; // destination-chain memecoin OFT instance (the one the staker interacts with)
    MockStakerYieldVault internal legitVault; // legit vault whose deposit reverts -> stranded funds
    SpoofedYieldVault internal evilVault;

    /// @notice Set up.
    function setUp() external {
        composer = _etchComposer();

        staker = new OmnichainMemecoinStaker(LOCAL_ENDPOINT);

        // Source-chain OFT (endpoint = MockOFTEndpoint) and destination-chain OFT (endpoint = LOCAL_ENDPOINT).
        // The repo's Initializable locks the logic contract, so deploy via minimal proxy clones like the OFT tests.
        srcEndpoint = new MockOFTEndpoint();
        srcOft = OFTHarness(address(new OFTHarness(address(srcEndpoint))).clone());
        srcOft.initialize(address(this), "Memecoin", "MEME", address(this));
        memecoin = OFTHarness(address(new OFTHarness(LOCAL_ENDPOINT)).clone());
        memecoin.initialize(address(this), "Memecoin", "MEME", address(this));

        // Wire peers: send-side receiver is enforced via `_getPeerOrRevert`; receive-side via `OnlyPeer`.
        srcOft.setPeer(DST_EID, bytes32(uint256(uint160(address(memecoin)))));
        memecoin.setPeer(SRC_EID, bytes32(uint256(uint160(address(srcOft)))));

        legitVault = new MockStakerYieldVault(address(memecoin));
        legitVault.setShouldRevert(true); // simulate a ZeroSharesDeposit-style failed deposit
        evilVault = new SpoofedYieldVault(address(memecoin), address(staker), ATTACKER);

        vm.label(address(staker), "OmnichainMemecoinStaker");
        vm.label(address(memecoin), "memecoinOFT(dst)");
        vm.label(address(srcOft), "memecoinOFT(src)");
        vm.label(address(evilVault), "attackerVault");
        vm.label(LOCAL_ENDPOINT, "endpoint+composer");
        vm.label(ATTACKER, "attacker");
        vm.label(VICTIM, "victim");
    }

    /// @notice Regression: an attacker-controlled vault named in a forged composeMsg gets only an exact-amount
    ///         approval. Its attempt to drain the staker's full balance (including another user's stranded funds)
    ///         reverts; it can pull at most the amount the attacker himself bridged. The stranded victim funds stay
    ///         in the staker and remain recoverable via `settlePendingCompose`.
    function testExactApproveCapsLossToSentAmount() external {
        uint256 victimAmount = 10 ether;
        uint256 attackAmount = 2 ether;

        // --- Phase 1: a legitimate user's staking compose arrives and strands funds in the staker. ---
        // The victim bridges from the source chain using the genuine protocol composeMsg format
        // `abi.encode(receiver, yieldVault)` (MemeverseOmnichainInteroperation.sol:148). Their vault deposit
        // reverts (ZeroSharesDeposit-style), so lzCompose fails and the funds stay parked in the staker.
        bytes memory victimComposeMsg = abi.encode(VICTIM, address(legitVault));
        bytes32 victimGuid = bytes32("victim-guid");
        srcOft.mintTest(VICTIM, victimAmount);
        bytes memory victimComposeMessage = bridgeAndQueue(victimAmount, victimComposeMsg, victimGuid, VICTIM);

        assertEq(memecoin.balanceOf(address(staker)), victimAmount, "victim funds credited to the staker");
        assertEq(
            composer.composeQueue(address(memecoin), address(staker), victimGuid, 0),
            keccak256(victimComposeMessage),
            "victim compose queued"
        );

        // Executor-driven lzCompose for the victim fails (vault deposit reverts): funds remain stranded.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("deposit failed");
        staker.lzCompose(address(memecoin), victimGuid, victimComposeMessage, address(0), "");
        assertEq(memecoin.balanceOf(address(staker)), victimAmount, "funds stranded after failed deposit");

        // --- Phase 2: the attacker bridges HIS OWN amount with a composeMsg naming the attacker's vault. ---
        // `send` has no access control; the attacker funds the attack with his own memecoin. The destination
        // credits `attackAmount` to the staker, so the staker now custodies victim + attacker funds.
        bytes memory attackComposeMsg = abi.encode(ATTACKER, address(evilVault));
        bytes32 attackGuid = bytes32("attack-guid");
        srcOft.mintTest(ATTACKER, attackAmount);
        // Second inbound message on this path uses a higher nonce than the victim's first (nonce=1). Anchors the
        // wire property that `_lzReceive` encodes the real `_origin.nonce` — a hardcoded nonce would make the
        // reconstructed hash diverge from the queue slot.
        bytes memory attackComposeMessage = bridgeAndQueue(2, attackAmount, attackComposeMsg, attackGuid, ATTACKER);
        assertEq(memecoin.balanceOf(address(staker)), victimAmount + attackAmount, "both funds parked in the staker");

        // --- Phase 3: permissionless compose execution by the attacker (EOA, no executor role). ---
        // msg.sender of staker.lzCompose is the composer at LOCAL_ENDPOINT, so the `localEndpoint` check passes.
        // The vault's `asset()` lie (reports the real memecoin) passes the binding check — the delivered
        // token IS the memecoin here — so the attack reaches the exact-approval layer, where the exact-amount approval is
        // the backstop. Post-fix this succeeds: the vault's overdraft attempt reverts, its exact-amount pull does
        // not.
        vm.prank(ATTACKER);
        composer.lzCompose(address(memecoin), address(staker), attackGuid, 0, attackComposeMessage, bytes(""));

        // --- Regression assertions: exact approval, overdraft reverts, loss capped to the sent amount. ---
        assertEq(evilVault.observedAllowance(), attackAmount, "vault observed exactly the bridged amount of allowance");
        assertEq(
            memecoin.allowance(address(staker), address(evilVault)),
            0,
            "exact allowance was granted and fully spent by the capped pull"
        );
        assertEq(evilVault.lastDepositAssets(), attackAmount, "vault called with the bridged amount");
        assertEq(evilVault.lastDepositReceiver(), ATTACKER, "receiver is attacker-chosen");
        assertEq(
            evilVault.attemptedDrain(),
            victimAmount + attackAmount,
            "vault attempted to pull the staker's entire custody balance"
        );
        assertTrue(evilVault.overdraftReverted(), "overdraft transferFrom reverted (allowance insufficient)");
        assertEq(
            memecoin.balanceOf(address(staker)),
            victimAmount,
            "only the attacker's own sent amount left the staker; victim funds untouched"
        );
        assertEq(memecoin.balanceOf(ATTACKER), attackAmount, "attacker recovered at most his own sent amount");
        assertEq(
            uint256(staker.composeStates(address(memecoin), attackGuid)),
            uint256(IComposeState.ComposeState.Settled),
            "attack compose settled"
        );

        // --- Phase 4: the victim's recovery path is NOT broken anymore. ---
        // settlePendingCompose pushes the victim's stranded funds from the staker's remaining balance; with the
        // cap in place the funds survived, so the victim recovers them through the protocol.
        vm.prank(VICTIM);
        staker.settlePendingCompose(address(memecoin), victimGuid, victimComposeMessage);
        assertEq(memecoin.balanceOf(address(staker)), 0, "staker empty after victim recovery");
        assertEq(memecoin.balanceOf(VICTIM), victimAmount, "victim recovered his stranded funds");
    }

    /// @notice Premise 1+2 evidence: the memecoin OFT has no msgInspector, `send` is permissionless, and a
    ///         zero-amount send (attacker holds zero memecoin) succeeds, delivering the attacker's composeMsg
    ///         verbatim to the destination OFT.
    function testZeroAmountSendIsPermissionlessAndComposeMsgPassesThrough() external {
        assertEq(srcOft.msgInspector(), address(0), "no msgInspector deployed anywhere in the repo");

        // Attacker holds zero memecoin on the source chain.
        assertEq(srcOft.balanceOf(ATTACKER), 0);

        bytes memory attackComposeMsg = abi.encode(ATTACKER, address(evilVault));
        SendParam memory sendParam = _sendParam(0, attackComposeMsg);
        MessagingFee memory fee = srcOft.quoteSend(sendParam, false);
        assertEq(fee.nativeFee, 0, "zero-amount send has zero LZ fee in the mock");

        vm.prank(ATTACKER);
        srcOft.send{value: 0}(sendParam, fee, ATTACKER);

        // The message produced by the real `send` is byte-for-byte `abi.encodePacked(to=staker, amountSD=0,
        // sender=ATTACKER, composeMsg)` — the exact payload the destination OFT will credit and re-queue.
        // No inspector rewrite, zero amount encoded.
        bytes memory delivered = srcEndpoint.lastMessage();
        bytes memory expectedMessage = abi.encodePacked(
            bytes32(uint256(uint160(address(staker)))), uint64(0), bytes32(uint256(uint160(ATTACKER))), attackComposeMsg
        );
        assertEq(delivered, expectedMessage, "delivered message equals the pure encoding of attacker inputs");
    }

    /// @notice Zero-amount variant (the attack's cheapest form): the attacker holds zero memecoin and bridges
    ///         amountLD=0 (zero LZ fee in this mock; a real endpoint still charges executor/DVN base fee + message
    ///         gas — see OutrunOFTInit's truncation test), yet the destination OFT still queues the forged compose
    ///         and the staker runs the
    ///         full `lzCompose` path — exact-amount approval of 0, then `deposit(0, receiver)`. A regression that skips
    ///         the approve for zero amounts would leave any stale allowance intact; the pre-seeded residue below
    ///         (simulating a pre-fix unlimited approval, or a vault that pulled less than granted) makes that
    ///         regression fail loudly. Nothing may move: zero allowance observed and left behind, custody balance
    ///         untouched, compose settled.
    function testZeroAmountComposeGrantsNoAllowance() external {
        // Strand victim funds first so the staker custodies other users' money (the attacker's real target) AND so the
        // mock vault's overdraft attempt — pulling the staker's ENTIRE balance — has a non-zero amount to revert on:
        // with an empty staker, a zero-value "drain" transfer would succeed and make the mock revert instead of
        // recording the observed allowance.
        uint256 victimAmount = 10 ether;
        srcOft.mintTest(VICTIM, victimAmount);
        bridgeAndQueue(victimAmount, abi.encode(VICTIM, address(legitVault)), bytes32("victim-guid-zero"), VICTIM);
        assertEq(memecoin.balanceOf(address(staker)), victimAmount, "victim funds stranded in the staker");

        // Pre-existing residual allowance (e.g. granted before the exact-approval fix, or left behind by a vault that
        // pulled less than it was approved). Post-fix the zero-amount compose must still run `approve(vault, 0)` and
        // wipe it before `deposit`; a "skip approve when amount == 0" regression would preserve it and fail the
        // assertions below.
        vm.prank(address(staker));
        memecoin.approve(address(evilVault), type(uint256).max);

        // Attacker bridges ZERO memecoin with the forged composeMsg; the destination OFT credits 0, queues the
        // compose, and the staker's lzCompose approves exactly 0 and calls deposit(0, attacker). The vault's
        // `asset()` lie passes the binding (the delivered token IS the memecoin), so the path reaches the
        // exact-approval layer.
        bytes memory attackComposeMsg = abi.encode(ATTACKER, address(evilVault));
        bytes32 attackGuid = bytes32("attack-guid-zero");
        bytes memory attackComposeMessage = bridgeAndQueue(0, attackComposeMsg, attackGuid, ATTACKER);

        vm.prank(ATTACKER);
        composer.lzCompose(address(memecoin), address(staker), attackGuid, 0, attackComposeMessage, bytes(""));

        // Regression assertions: exact ZERO allowance observed at deposit time, no residual allowance, no movement.
        assertEq(evilVault.observedAllowance(), 0, "zero-amount compose grants zero allowance");
        assertEq(
            memecoin.allowance(address(staker), address(evilVault)),
            0,
            "stale allowance wiped by the zero-amount approve"
        );
        assertEq(evilVault.lastDepositAssets(), 0, "vault called with zero assets");
        assertEq(evilVault.lastDepositReceiver(), ATTACKER, "receiver is attacker-chosen");
        assertEq(evilVault.attemptedDrain(), victimAmount, "vault still attempted the staker's entire custody balance");
        assertTrue(evilVault.overdraftReverted(), "overdraft transferFrom reverted (allowance insufficient)");
        assertEq(memecoin.balanceOf(address(staker)), victimAmount, "staker custody balance unchanged");
        assertEq(memecoin.balanceOf(ATTACKER), 0, "attacker pulled nothing");
        assertEq(
            uint256(staker.composeStates(address(memecoin), attackGuid)),
            uint256(IComposeState.ComposeState.Settled),
            "zero-amount compose settled"
        );
    }

    /// @notice Negative control (devil's advocate), complementary to StakerTokenVaultBinding's
    ///         `testForgedTokenComposeRevertsTokenVaultMismatch`: a compose queued under a NON-memecoin `from`
    ///         (attacker's fake token) is intercepted at the binding layer — the vault's reported `asset()`
    ///         (real memecoin) != delivered token (fake) → TokenVaultMismatch, before any approval or deposit. The
    ///         drain of the REAL memecoin requires a genuine bridge through the memecoin OFT (which the attacker
    ///         obtains at negligible cost — a small base fee on real chains, zero only in this mock — see the
    ///         zero-amount test). Where StakerTokenVaultBinding proves the intercept with
    ///         the REAL MemecoinYieldVault, this file's mock proves it with its own vault.
    function testForgedComposeCannotDrainRealMemecoin() external {
        // Strand some real funds first.
        uint256 stranded = 1 ether;
        srcOft.mintTest(VICTIM, stranded);
        bridgeAndQueue(stranded, abi.encode(VICTIM, address(legitVault)), bytes32("victim-guid-nc"), VICTIM);
        assertEq(memecoin.balanceOf(address(staker)), stranded);

        // Attacker queues a compose under its own fake token (sendCompose is keyed by msg.sender, so any contract
        // can write its own slot — but the slot's `from` is the fake token, NOT the memecoin).
        ForgedComposeToken fake = new ForgedComposeToken(address(composer));
        bytes32 fakeGuid = bytes32("fake-guid");
        bytes memory fakeMessage =
            fake.queueComposeEncoded(SRC_EID, address(staker), fakeGuid, abi.encode(ATTACKER, address(evilVault)));

        // Permissionless execution: staker.lzCompose(fakeToken, ...) passes the endpoint check, then the
        // binding fires BEFORE any approval or deposit: the evil vault's reported asset() is the REAL memecoin
        // while the delivered token is the fake, so the pairing reverts with TokenVaultMismatch — the allowance
        // path (which would land on the fake token anyway) is never even reached.
        vm.prank(ATTACKER);
        vm.expectRevert(IOmnichainMemecoinStaker.TokenVaultMismatch.selector);
        composer.lzCompose(address(fake), address(staker), fakeGuid, 0, fakeMessage, bytes(""));

        // Nothing moved: the real memecoin balance and allowance are untouched, and the fake guid is unresolved.
        assertEq(memecoin.balanceOf(address(staker)), stranded, "real funds untouched by the fake-token compose");
        assertEq(memecoin.allowance(address(staker), address(evilVault)), 0, "no allowance granted on real memecoin");
        assertEq(
            uint256(staker.composeStates(address(fake), fakeGuid)),
            uint256(IComposeState.ComposeState.None),
            "reverted compose consumes nothing"
        );
    }

    /// @dev Builds the SendParam used by every send in this harness: destination is always the staker on DST_EID,
    ///      with no minAmountLD/extraOptions/oftCmd; only the bridged amount and the forgeable composeMsg vary.
    function _sendParam(uint256 amountLD, bytes memory composeMsg) internal view returns (SendParam memory) {
        return SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(staker)))),
            amountLD: amountLD,
            minAmountLD: 0,
            extraOptions: bytes(""),
            composeMsg: composeMsg,
            oftCmd: bytes("")
        });
    }

    /// @dev Bridges `amountLD` memecoin from `sender` on the source chain to the staker on the destination chain
    ///      with `composeMsg`, driving the real OFT send/_lzReceive/sendCompose code. Returns the exact compose
    ///      payload queued in the composer (reconstructed and hash-verified against the queue). Convenience overload:
    ///      uses inbound nonce = 1 (the first message of a fresh guid path).
    function bridgeAndQueue(uint256 amountLD, bytes memory composeMsg, bytes32 guid, address sender)
        internal
        returns (bytes memory composeMessage)
    {
        return bridgeAndQueue(1, amountLD, composeMsg, guid, sender);
    }

    /// @dev Same as the 4-arg overload but takes an explicit inbound `nonce`. Production endpoints increment the
    ///      inbound nonce per message; passing a nonce != 1 here anchors that wire property — if `_lzReceive` ever
    ///      hardcoded the nonce instead of encoding `_origin.nonce`, the reconstructed hash below would diverge from
    ///      the queue slot and this assertion would fail.
    function bridgeAndQueue(uint64 nonce, uint256 amountLD, bytes memory composeMsg, bytes32 guid, address sender)
        internal
        returns (bytes memory composeMessage)
    {
        SendParam memory sendParam = _sendParam(amountLD, composeMsg);
        MessagingFee memory fee = srcOft.quoteSend(sendParam, false);
        vm.prank(sender);
        srcOft.send{value: fee.nativeFee}(sendParam, fee, sender);

        // Destination-chain delivery: the endpoint invokes the destination OFT's lzReceive with the exact message
        // the real send() produced. `_lzReceive` credits (mints) `amountLD` to the staker and calls
        // `endpoint.sendCompose(staker, guid, 0, ...)` on the composer at LOCAL_ENDPOINT.
        // Note: fetch the delivered message BEFORE pranking — an argument-evaluating staticcall would consume it.
        bytes memory deliveredMessage = srcEndpoint.lastMessage();
        Origin memory origin =
            Origin({srcEid: SRC_EID, sender: bytes32(uint256(uint160(address(srcOft)))), nonce: nonce});
        vm.prank(LOCAL_ENDPOINT);
        memecoin.lzReceive(origin, guid, deliveredMessage, address(0), "");

        // Reconstruct the exact compose payload the OFT queued: OFTComposeMsgCodec.encode(nonce, srcEid,
        // amountReceivedLD, <sender||composeMsg>). The OFT message embeds the src sender (addressToBytes32 of
        // send()'s msg.sender) in front of the payload, and `_lzReceive` forwards `_message.composeMsg()`
        // verbatim — so the queued payload is [sender][composeMsg]. amountReceivedLD == amountLD for these
        // dust-clean amounts.
        composeMessage = OFTComposeMsgCodec.encode(
            nonce, SRC_EID, amountLD, abi.encodePacked(bytes32(uint256(uint160(sender))), composeMsg)
        );
        assertEq(
            composer.composeQueue(address(memecoin), address(staker), guid, 0),
            keccak256(composeMessage),
            "queued compose hash matches reconstruction"
        );
    }
}
