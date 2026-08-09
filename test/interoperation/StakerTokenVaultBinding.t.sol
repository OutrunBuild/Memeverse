// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {OmnichainMemecoinStaker} from "../../src/interoperation/OmnichainMemecoinStaker.sol";
import {IOmnichainMemecoinStaker} from "../../src/interoperation/interfaces/IOmnichainMemecoinStaker.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {Memecoin} from "../../src/token/Memecoin.sol";
import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";
import {IMemecoinYieldVault} from "../../src/yield/interfaces/IMemecoinYieldVault.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {ForgedComposeToken} from "../mocks/interoperation/ForgedComposeToken.sol";

/// @dev Attacker-controlled vault whose `asset()` is attacker-chosen, used to exercise the token-vault binding
///      from the vault side. Mirrors the real vault's deposit pull (`IERC20(asset).transferFrom(msg.sender, ...)`):
///      it pulls only the delivered fake token, so it can never reach the staker's real memecoin — post-fix the
///      exact approval lands on the fake token, and the real token is never approved to it.
contract EvilVault {
    ForgedComposeToken public immutable token;
    address public immutable reportedAsset;

    constructor(ForgedComposeToken _token, address _reportedAsset) {
        token = _token;
        reportedAsset = _reportedAsset;
    }

    /// @notice Underlying asset reported to the staker's binding check (`TokenVaultMismatch`).
    /// @return address Attacker-chosen asset address.
    function asset() external view returns (address) {
        return reportedAsset;
    }

    /// @notice Pulls the delivered (fake) token from the caller (the staker), mirroring the real vault's pull.
    /// @param amount Amount of fake tokens pulled from the caller.
    /// @param receiver Mock share recipient (accepted for interface parity; no shares are minted).
    /// @return shares The deposited amount, mirrored 1:1.
    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        receiver;
        token.transferFrom(msg.sender, address(this), amount);
        shares = amount;
    }
}

/// @dev Attacker-controlled vault variant that pulls LESS than the approved amount (1 wei) while returning a
///      non-zero share count — the drift that would leave a residual exact-approval over the staker's custody
///      balance if the deposit branch did not zero it after settlement. `asset()` reports the real memecoin so the
///      token-vault binding passes and the deposit branch completes.
contract PartialPullVault {
    Memecoin public immutable token;

    constructor(Memecoin _token) {
        token = _token;
    }

    /// @notice Underlying asset reported to the staker's binding check (`TokenVaultMismatch`): the real memecoin.
    /// @return address The real memecoin address.
    function asset() external view returns (address) {
        return address(token);
    }

    /// @notice Pulls only 1 wei of the approved amount from the caller (the staker) and returns a non-zero share
    ///         count, leaving a residual allowance behind unless the staker zeroes it.
    /// @param amount Approved amount (accepted for interface parity; only 1 wei is pulled).
    /// @param receiver Mock share recipient (accepted for interface parity; no shares are minted).
    /// @return shares Non-zero share count mirroring a "successful" deposit.
    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        amount;
        receiver;
        token.transferFrom(msg.sender, address(this), 1);
        shares = 1;
    }

    /// @notice Attack entry: tries to drain `amount` from `from` via the residual allowance over the staker's
    ///         custody balance. Reverts when the allowance was zeroed.
    /// @param from Account to pull tokens from (the staker).
    /// @param to Recipient of the drained tokens.
    /// @param amount Amount to drain.
    function attack(address from, address to, uint256 amount) external {
        token.transferFrom(from, to, amount);
    }
}

/// @dev Regression test (post-fix): the deposit branch of `lzCompose` binds the delivered token to the
///      vault's underlying asset (`require(IMemecoinYieldVault(yieldVault).asset() == memecoin,
///      TokenVaultMismatch())`) before any approval or deposit. A forged (fake token, real vault) compose — queued
///      under the attacker's own token via the permissionless composer `sendCompose` and driven through
///      `lzCompose` — reverts at the binding with no fund movement, even when a standing max allowance (the
///      pre-fix state) would otherwise let the real vault pull the staker's real memecoin and mint shares to the
///      attacker. Genuine (real memecoin, real vault) composes still deposit and mint shares.
///      Uses the REAL Memecoin, the REAL MemecoinYieldVault (minimal-proxy clones, matching production deployment),
///      the REAL OmnichainMemecoinStaker, and the repo's MessagingComposer endpoint mock — a byte-level behavioral
///      mirror of the real LayerZero composer (sendCompose keyed by msg.sender; lzCompose hash-check + RECEIVED
///      sentinel + forward with msg.sender=endpoint), which the canonical EndpointV2 inherits without override.
contract StakerTokenVaultBindingTest is Test {
    MockMessagingComposerEndpoint internal endpoint;
    Memecoin internal memecoin;
    MemecoinYieldVault internal vault;
    OmnichainMemecoinStaker internal staker;
    ForgedComposeToken internal fake;

    address internal constant RECEIVER = address(0xBEEF); // genuine staking beneficiary
    address internal attacker;

    function setUp() external {
        attacker = address(this);

        // Endpoint surface (mirrors canonical EndpointV2's MessagingComposer compose surface).
        endpoint = new MockMessagingComposerEndpoint();

        // Real memecoin OFT, deployed as a minimal-proxy clone like production.
        Memecoin memecoinImpl = new Memecoin(address(endpoint));
        memecoin = Memecoin(Clones.clone(address(memecoinImpl)));
        memecoin.initialize("Memecoin", "MEME", address(this), address(this));

        // Real yield vault, minimal-proxy clone like production. V = 1e18 virtual buffer (spec §4 requires V > 0).
        MemecoinYieldVault vaultImpl = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(vaultImpl)));
        vault.initialize("Verse 1 Vault", "vMEME", address(0xA11CE), address(memecoin), 1, 1e18);

        // The victim contract under attack; localEndpoint wired like the deploy script (canonical endpoint).
        staker = new OmnichainMemecoinStaker(address(endpoint));

        fake = new ForgedComposeToken(address(endpoint));
    }

    /// @notice Positive control: a genuine compose (real memecoin from, real vault) still settles through the
    ///         deposit branch — the vault pulls exactly the bridged amount from the staker and mints shares to the
    ///         receiver. The token-vault binding does not regress the happy path.
    function testGenuineComposeStillSucceeds() external {
        uint256 stake = 100 ether;
        memecoin.mint(address(staker), stake);

        bytes memory composeMsg =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(RECEIVER), abi.encode(RECEIVER, address(vault)));
        bytes memory message = OFTComposeMsgCodec.encode(1, 40106, stake, composeMsg);
        vm.prank(address(memecoin)); // the OFT writes its own queue slot inside _lzReceive
        endpoint.sendCompose(address(staker), bytes32("real-guid"), 0, message);
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("real-guid"), 0, message, "");

        // Deposit executed: vault holds the bridged memecoin, shares minted 1:1 (symmetric virtual buffer), the
        // staker's balance consumed and the compose settled.
        assertEq(memecoin.balanceOf(address(vault)), stake, "vault pulled the bridged stake");
        assertEq(memecoin.balanceOf(address(staker)), 0, "staker balance consumed by the genuine deposit");
        assertEq(vault.balanceOf(RECEIVER), stake, "shares minted to the receiver at the 1:1 genesis rate");
        assertEq(
            uint256(staker.composeStates(address(memecoin), bytes32("real-guid"))),
            uint256(IComposeState.ComposeState.Settled),
            "genuine compose settled"
        );
    }

    /// @notice End-to-end ZeroShares round trip through the REAL vault: a dust deposit that rounds down to 0
    ///         shares reverts `ZeroSharesDeposit` inside the vault (the staker's deposit return-value guard
    ///         reverts the same error for vault variants that do not), the endpoint's RECEIVED-sentinel write
    ///         rolls back with the whole call, the guid stays None, and the beneficiary recovers the dust via
    ///         settlePendingCompose; a late endpoint lzCompose then converges the queue slot to the RECEIVED
    ///         sentinel (operations.md §3.13.1 step 4).
    /// @dev The warm-up pushes the exchange rate above 1 (deposit 10 ether, donate 5 ether yield) so
    ///      `deposit(1)` rounds down to 0 shares at the real vault's `_convertToShares`; with the 1e18 virtual
    ///      buffer the rate stays comfortably above 1. The dust compose is delivered through the real memecoin
    ///      OFT + endpoint mock like `testGenuineComposeStillSucceeds`; the reverted lzCompose leaves the queue
    ///      slot at keccak256(message), so the settle delivery proof still passes.
    function testZeroSharesDepositRoundTripRevertThenSettleRecovery() external {
        // Warm up the exchange rate above 1:1. RECEIVER funds both the deposit and the yield donation (the
        // vault pulls both via transferFrom, so the approval is needed for both calls).
        memecoin.mint(RECEIVER, 10 ether);
        vm.startPrank(RECEIVER);
        memecoin.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, RECEIVER);
        vm.stopPrank();
        memecoin.mint(RECEIVER, 5 ether);
        vm.prank(RECEIVER);
        vault.accumulateYields(5 ether);
        assertEq(vault.totalAssets(), 15 ether, "fixture: rate > 1");

        // Dust deposit: 1 wei at the 1.5 rate rounds down to 0 shares at the real vault.
        uint256 dust = 1;
        memecoin.mint(address(staker), dust);
        bytes memory composeMsg =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(RECEIVER), abi.encode(RECEIVER, address(vault)));
        bytes memory message = OFTComposeMsgCodec.encode(1, 40106, dust, composeMsg);
        vm.prank(address(memecoin));
        endpoint.sendCompose(address(staker), bytes32("zero-shares-guid"), 0, message);

        // The real vault itself reverts ZeroSharesDeposit; the whole endpoint call (RECEIVED-sentinel write
        // included) rolls back.
        vm.expectRevert(IMemecoinYieldVault.ZeroSharesDeposit.selector);
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("zero-shares-guid"), 0, message, "");

        // Nothing moved, nothing settled: the dust never left the staker, the vault holds only the warm-up
        // deposit, the guid stays None, and the queue slot still holds the delivery proof.
        assertEq(memecoin.balanceOf(address(staker)), dust, "dust never left the staker");
        assertEq(memecoin.balanceOf(address(vault)), 15 ether, "vault holds the warm-up deposit and donated yield");
        assertEq(vault.totalAssets(), 15 ether, "warm-up assets unchanged");
        assertEq(
            uint256(staker.composeStates(address(memecoin), bytes32("zero-shares-guid"))),
            uint256(IComposeState.ComposeState.None),
            "reverted deposit consumes nothing"
        );
        assertEq(
            endpoint.composeQueue(address(memecoin), address(staker), bytes32("zero-shares-guid"), 0),
            keccak256(message),
            "RECEIVED-sentinel write rolled back with the revert"
        );

        // The beneficiary recovers the dust via settlePendingCompose (delivery proof intact).
        vm.prank(RECEIVER);
        staker.settlePendingCompose(address(memecoin), bytes32("zero-shares-guid"), message);
        assertEq(
            uint256(staker.composeStates(address(memecoin), bytes32("zero-shares-guid"))),
            uint256(IComposeState.ComposeState.Released),
            "settle recovery resolved the guid"
        );
        assertEq(memecoin.balanceOf(RECEIVER), dust, "dust recovered by the beneficiary");
        assertEq(memecoin.balanceOf(address(staker)), 0, "staker custody drained by the recovery");

        // §3.13.1 step 4: a late endpoint lzCompose absorbs the Released pair as a no-op and converges the
        // queue slot to the RECEIVED sentinel (bytes32(uint256(1))).
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("zero-shares-guid"), 0, message, "");
        assertEq(
            endpoint.composeQueue(address(memecoin), address(staker), bytes32("zero-shares-guid"), 0),
            bytes32(uint256(1)),
            "queue slot converged to the RECEIVED sentinel"
        );
    }

    /// @notice Regression: a forged compose (fake token from, fresh guid, REAL vault, attacker receiver) driven
    ///         through the permissionless composer must revert with TokenVaultMismatch at the token-vault binding —
    ///         before any approval or deposit — leaving the staker's balance, the vault's balance/shares, and the
    ///         composeStates slot untouched. Isolation: a standing max allowance (the pre-fix state) is restored on
    ///         the REAL memecoin before the forged attempt, so the vault COULD pull real funds if the binding were
    ///         missing; the binding alone must still revert. No-stranding: a genuine compose afterwards still
    ///         deposits and mints shares.
    function testForgedTokenComposeRevertsTokenVaultMismatch() external {
        uint256 custody = 100 ether; // real memecoin in the staker's custody (in-flight bridged credit)
        memecoin.mint(address(staker), custody);

        // ---- Isolation setup: restore the pre-fix standing max allowance on the REAL memecoin ----
        // The exact-approve is deliberately neutralized: if the token-vault binding were missing, the real
        // vault's deposit pull could consume this allowance and drain the staker's custody balance. The forged
        // pairing must revert at the require anyway, proving the binding alone closes the hole.
        vm.prank(address(staker));
        memecoin.approve(address(vault), type(uint256).max);

        // ---- Step 1: forged token writes its own queue slot (permissionless, keyed by msg.sender) ----
        bytes memory forgedMsg = _forgeComposeMsg(attacker, custody, address(vault));
        vm.prank(address(fake));
        fake.queueCompose(address(staker), bytes32("forged-guid"), forgedMsg);

        // ---- Step 2: attacker drives the endpoint directly — the forged compose must revert ----
        // lzCompose: hash matches the queue slot, then
        // ILayerZeroComposer(staker).lzCompose(from=fake, guid, forgedMsg, executor=endpoint) — the staker's
        // `msg.sender == localEndpoint` check passes because the ENDPOINT makes the inner call. The deposit
        // branch's binding fires first: vault.asset() (REAL memecoin) != fake token, so the require reverts with
        // TokenVaultMismatch before the approval or deposit; the whole endpoint call — including the
        // RECEIVED-sentinel write — rolls back.
        vm.expectRevert(IOmnichainMemecoinStaker.TokenVaultMismatch.selector);
        endpoint.lzCompose(address(fake), address(staker), bytes32("forged-guid"), 0, forgedMsg, "");

        // ---- Core assertions: the forged pairing moved nothing and consumed nothing ----
        assertEq(memecoin.balanceOf(address(staker)), custody, "staker custody balance unchanged");
        assertEq(memecoin.balanceOf(address(vault)), 0, "vault pulled no real memecoin");
        assertEq(memecoin.balanceOf(attacker), 0, "attacker drained no real memecoin");
        assertEq(vault.balanceOf(attacker), 0, "no vault shares minted to the attacker");
        assertEq(vault.totalSupply(), 0, "vault share supply unchanged");
        assertEq(vault.totalAssets(), 0, "vault totalAssets unchanged");
        // Secondary check only: the binding fires before `_safeApprove`, so the standing max allowance survives
        // untouched. NOT the primary proof — the deposit branch approves the FROM (fake) token, and a max
        // real-token allowance would survive even a hypothetical drain since `transferFrom` with a max allowance
        // never decrements. The primary proof is the balance/share/totalAssets assertions above and below: nothing
        // moved and no shares or assets were created.
        assertEq(
            memecoin.allowance(address(staker), address(vault)),
            type(uint256).max,
            "binding reverted before the approval step"
        );

        // The forged compose slot was never RECEIVED-ized: the sentinel write rolled back with the revert, so the
        // queue still holds the queued hash (pending) and the staker's single-resolution guard is clear.
        assertEq(
            endpoint.composeQueue(address(fake), address(staker), bytes32("forged-guid"), 0),
            keccak256(forgedMsg),
            "forged compose slot still queued, not RECEIVED"
        );
        assertEq(
            uint256(staker.composeStates(address(fake), bytes32("forged-guid"))),
            uint256(IComposeState.ComposeState.None),
            "reverted forged compose consumes nothing"
        );

        // ---- No-stranding control: a genuine compose after the forged attempts still settles ----
        uint256 genuineStake = 50 ether;
        memecoin.mint(address(staker), genuineStake);
        bytes memory realComposeMsg =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(RECEIVER), abi.encode(RECEIVER, address(vault)));
        bytes memory realMessage = OFTComposeMsgCodec.encode(2, 40106, genuineStake, realComposeMsg);
        vm.prank(address(memecoin));
        endpoint.sendCompose(address(staker), bytes32("real-guid"), 0, realMessage);
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("real-guid"), 0, realMessage, "");

        assertEq(memecoin.balanceOf(address(vault)), genuineStake, "genuine deposit executed after forged attempts");
        assertEq(memecoin.balanceOf(address(staker)), custody, "staker funds intact: only the genuine stake left");
        assertEq(vault.balanceOf(RECEIVER), genuineStake, "genuine shares minted to the receiver");
    }

    /// @notice Closure case (b): an attacker vault that PASSES the token-vault binding (asset() == fake token).
    ///         Post-fix the deposit branch approves only the DELIVERED (fake) token to it and the vault's pull
    ///         operates entirely in fake-token space: the REAL memecoin is never approved (allowance stays 0) and
    ///         the staker's real balance is untouched, even though the forged deposit completes and settles.
    function testForgedComposeEvilVaultPullsOnlyFakeToken() external {
        uint256 custody = 100 ether;
        memecoin.mint(address(staker), custody);
        EvilVault evilVault = new EvilVault(fake, address(fake));

        // Fund the staker with fake tokens so the vault's pull of the delivered token can actually succeed.
        fake.mint(address(staker), custody);

        bytes memory forgedMsg = _forgeComposeMsg(attacker, custody, address(evilVault));
        vm.prank(address(fake));
        fake.queueCompose(address(staker), bytes32("evil-guid"), forgedMsg);

        // No revert: the binding passes (evilVault.asset() == fake), the exact approval lands on the FAKE token,
        // and the vault pulls only fake tokens from the staker.
        endpoint.lzCompose(address(fake), address(staker), bytes32("evil-guid"), 0, forgedMsg, "");

        // Only the FAKE token was approved to the forged vault ...
        assertEq(
            memecoin.allowance(address(staker), address(evilVault)),
            0,
            "the REAL memecoin is never approved to the forged vault"
        );
        // ... and only the fake token was pulled. The fake allowance is fully consumed (0), not max: an exact
        // approval was issued and the vault's transferFrom spent it completely — a standing max allowance would
        // have survived the pull without decrementing.
        assertEq(fake.allowance(address(staker), address(evilVault)), 0, "exact fake-token approval fully consumed");
        // ... and only the fake token was pulled: the staker's real custody balance is untouched.
        assertEq(memecoin.balanceOf(address(staker)), custody, "staker real balance untouched");
        assertEq(memecoin.balanceOf(address(evilVault)), 0, "evil vault holds no real memecoin");
        assertEq(memecoin.balanceOf(attacker), 0, "attacker drained no real memecoin");
        assertEq(fake.balanceOf(address(staker)), 0, "staker's fake balance consumed by the forged deposit");
        assertEq(fake.balanceOf(address(evilVault)), custody, "evil vault holds only the fake tokens");
        assertEq(
            uint256(staker.composeStates(address(fake), bytes32("evil-guid"))),
            uint256(IComposeState.ComposeState.Settled),
            "forged compose settles in fake-token space"
        );
    }

    /// @notice Closure case (c): an attacker vault that FAILS the token-vault binding (asset() == real memecoin)
    ///         while the delivered token is the fake. The vault pretending to be the real vault changes nothing:
    ///         the binding compares the vault's reported asset against the delivered token, so the pairing reverts
    ///         with TokenVaultMismatch before any approval or pull.
    function testForgedComposeEvilVaultClaimingRealAssetReverts() external {
        uint256 custody = 100 ether;
        memecoin.mint(address(staker), custody);
        EvilVault evilVault = new EvilVault(fake, address(memecoin));

        bytes memory forgedMsg = _forgeComposeMsg(attacker, custody, address(evilVault));
        vm.prank(address(fake));
        fake.queueCompose(address(staker), bytes32("evil-real-guid"), forgedMsg);

        vm.expectRevert(IOmnichainMemecoinStaker.TokenVaultMismatch.selector);
        endpoint.lzCompose(address(fake), address(staker), bytes32("evil-real-guid"), 0, forgedMsg, "");

        assertEq(memecoin.balanceOf(address(staker)), custody, "staker real balance untouched");
        assertEq(memecoin.allowance(address(staker), address(evilVault)), 0, "real memecoin never approved");
    }

    /// @notice Explicit negative control (d): the endpoint keys the composeQueue slot by msg.sender, so an
    ///         attacker can never write a slot keyed by the REAL memecoin (only the real OFT itself can). Driving
    ///         lzCompose with from = real memecoin and no delivered slot reverts at the composer's not-found guard
    ///         before the staker is even reached — the staker is unreachable via the real token unless the real
    ///         OFT actually delivered a compose.
    function testAttackerCannotWriteRealMemecoinComposeSlot() external {
        bytes memory forgedMsg = _forgeComposeMsg(attacker, 1 ether, address(vault));

        // Direct negative control on the slot-keying property: the attacker calls the endpoint's permissionless
        // sendCompose targeting the REAL memecoin's queue key — but sendCompose keys the slot by msg.sender, so the
        // write lands under the attacker's own address and the real memecoin's slot stays empty. Only the real OFT
        // (the memecoin contract itself) can write composeQueue[memecoin][...].
        vm.prank(attacker);
        endpoint.sendCompose(address(staker), bytes32("never-delivered-guid"), 0, forgedMsg);
        assertEq(
            endpoint.composeQueue(attacker, address(staker), bytes32("never-delivered-guid"), 0),
            keccak256(forgedMsg),
            "the write lands under the attacker's own key, not the real memecoin's"
        );
        assertEq(
            endpoint.composeQueue(address(memecoin), address(staker), bytes32("never-delivered-guid"), 0),
            bytes32(0),
            "attacker cannot write the real memecoin's compose slot"
        );

        // Driving lzCompose with from = real memecoin and no delivered slot reverts at the composer's not-found
        // guard before the staker is even reached — the staker is unreachable via the real token unless the real
        // OFT actually delivered a compose.
        vm.expectRevert(MockMessagingComposerEndpoint.ComposeNotFound.selector);
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("never-delivered-guid"), 0, forgedMsg, "");

        // The staker never saw the message: nothing moved, nothing settled, no state written.
        assertEq(memecoin.balanceOf(address(staker)), 0, "no real balance moved");
        assertEq(
            uint256(staker.composeStates(address(memecoin), bytes32("never-delivered-guid"))),
            uint256(IComposeState.ComposeState.None),
            "no queue slot, no staker state change"
        );
    }

    /// @notice Regression: after a successful deposit the staker zeroes the exact approval, so a vault that pulled
    ///         LESS than the approved amount (1 wei) while returning non-zero shares cannot later drain the
    ///         residual allowance over the staker's custody balance (which includes other users' stranded funds).
    ///         The partial-pull compose settles (slot Settled, only 1 wei moved), the residual allowance is zeroed,
    ///         and the vault's own `attack` transferFrom reverts with the staker's balance intact.
    function testPartialPullVaultCannotDrainAfterSettlement() external {
        uint256 custody = 10 ether;
        memecoin.mint(address(staker), custody);
        PartialPullVault partialPullVault = new PartialPullVault(memecoin);

        // Deliver a genuine compose through the real memecoin OFT: vault = PartialPullVault, receiver = attacker.
        bytes memory composeMsg = abi.encodePacked(
            OFTComposeMsgCodec.addressToBytes32(attacker), abi.encode(attacker, address(partialPullVault))
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 40106, custody, composeMsg);
        vm.prank(address(memecoin)); // the OFT writes its own queue slot inside _lzReceive
        endpoint.sendCompose(address(staker), bytes32("partial-pull-guid"), 0, message);
        endpoint.lzCompose(address(memecoin), address(staker), bytes32("partial-pull-guid"), 0, message, "");

        // The compose settled, the vault pulled only 1 wei, and the residual exact-approval was zeroed.
        assertEq(
            memecoin.allowance(address(staker), address(partialPullVault)),
            0,
            "residual allowance zeroed after settlement"
        );
        assertEq(memecoin.balanceOf(address(staker)), custody - 1, "only 1 wei pulled by the partial-pull vault");
        assertEq(memecoin.balanceOf(address(partialPullVault)), 1, "partial-pull vault holds the 1 wei it pulled");
        assertEq(
            uint256(staker.composeStates(address(memecoin), bytes32("partial-pull-guid"))),
            uint256(IComposeState.ComposeState.Settled),
            "partial-pull compose settled"
        );

        // The vault's own attack cannot spend the zeroed allowance: transferFrom reverts
        // ERC20InsufficientAllowance and the staker's custody balance stays untouched.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(partialPullVault), 0, custody
            )
        );
        partialPullVault.attack(address(staker), attacker, custody);
        assertEq(memecoin.balanceOf(address(staker)), custody - 1, "attack drained nothing");
        assertEq(memecoin.balanceOf(attacker), 0, "attacker gained nothing");
    }

    /// @dev Forges the attacker's compose payload: nonce/srcEid are arbitrary (999/999) and never validated;
    ///      composeFrom (bytes 44..76) is attacker-chosen and never validated — the only binding is the queue
    ///      slot's from-key, which sendCompose keys by msg.sender. Genuine-path encodings stay inline because
    ///      their nonce/srcEid differ deliberately.
    /// @param composeFrom_ Attacker-chosen composeFrom (the token the message claims to come from).
    /// @param amount_ amountLD: the bridged amount the forged deposit would move.
    /// @param vault_ Attacker-chosen vault the forged deposit targets.
    /// @return The forged composed message.
    function _forgeComposeMsg(address composeFrom_, uint256 amount_, address vault_)
        internal
        pure
        returns (bytes memory)
    {
        return OFTComposeMsgCodec.encode(
            999,
            999,
            amount_,
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(composeFrom_), abi.encode(composeFrom_, vault_))
        );
    }
}
