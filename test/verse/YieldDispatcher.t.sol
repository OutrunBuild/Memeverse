// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {OFTComposeSettleVerify} from "../../src/common/omnichain/OFTComposeSettleVerify.sol";
import {IBurnable} from "../../src/common/interfaces/IBurnable.sol";
import {YieldDispatcher} from "../../src/verse/YieldDispatcher.sol";
import {IYieldDispatcher} from "../../src/verse/interfaces/IYieldDispatcher.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {IMemeverseOFTEnum} from "../../src/common/types/IMemeverseOFTEnum.sol";
import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {ComposerEndpointFixture} from "../mocks/infrastructure/ComposerEndpointFixture.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {OFTHarness} from "../mocks/infrastructure/OFTHarness.sol";
import {AttackComposeToken} from "../mocks/verse/AttackComposeToken.sol";
import {BindingPassingFakeVault} from "../mocks/verse/BindingPassingFakeVault.sol";
import {NoOpBurnToken} from "../mocks/verse/NoOpBurnToken.sol";
import {YieldDispatcherMockBase} from "../mocks/verse/YieldDispatcherMockBase.sol";
import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {IGovernanceCycleIncentivizer} from "../../src/governance/interfaces/IGovernanceCycleIncentivizer.sol";
import {MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";

contract MockDispatcherComposeToken is MockERC20, IBurnable {
    uint256 public lastBurnAmount;
    // Symmetric failure switch to the vault/governor mocks: lets a test inject an EOA-burn revert to pin the
    // lzCompose settle-fail rollback-retry contract on the burn branch.
    bool public burnShouldRevert;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    /// @notice Set whether burning should revert (mirrors the vault/governor mock's failure switch).
    /// @param burnShouldRevert_ See implementation.
    function setBurnShouldRevert(bool burnShouldRevert_) external {
        burnShouldRevert = burnShouldRevert_;
    }

    /// @notice Burn.
    /// @param amount See implementation.
    function burn(uint256 amount) external {
        require(!burnShouldRevert, "settle failed");
        lastBurnAmount = amount;
        _burn(msg.sender, amount);
    }
}

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
    YieldDispatcher internal immutable dispatcher;
    address internal reentryToken;
    bytes32 internal reentryGuid;
    bytes internal reentryMessage;

    constructor(address token_, address dispatcher_) {
        token = token_;
        dispatcher = YieldDispatcher(dispatcher_);
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

contract YieldDispatcherTest is ComposerEndpointFixture {
    using Clones for address;
    using OFTComposeMsgCodec for bytes;

    address internal constant OWNER = address(0xABCD);
    address internal constant LAUNCHER = address(0x2222);
    address internal constant ALICE = address(0xA11CE);

    YieldDispatcher internal dispatcher;
    MockDispatcherComposeToken internal token;
    MockDispatcherYieldVault internal yieldVault;
    MockDispatcherGovernor internal governor;
    MockMessagingComposerEndpoint internal endpoint;

    /// @notice Set up.
    function setUp() external {
        dispatcher = new YieldDispatcher(LOCAL_ENDPOINT, LAUNCHER);
        token = new MockDispatcherComposeToken("Compose Token", "CMP");
        yieldVault = new MockDispatcherYieldVault(address(token));
        governor = new MockDispatcherGovernor(address(token));
        // Etch the shared endpoint mock runtime onto the LOCAL_ENDPOINT address so the dispatcher's `localEndpoint`
        // immutable points at a controllable endpoint mock (the immutable is fixed to LOCAL_ENDPOINT at construction time).
        endpoint = _etchComposer();
    }

    /// @notice Test constructor rejects zero local endpoint.
    function testConstructorRejectsZeroLocalEndpoint() external {
        vm.expectRevert(IYieldDispatcher.ZeroAddress.selector);
        new YieldDispatcher(address(0), LAUNCHER);
    }

    /// @notice Test constructor rejects zero memeverse launcher.
    function testConstructorRejectsZeroMemeverseLauncher() external {
        vm.expectRevert(IYieldDispatcher.ZeroAddress.selector);
        new YieldDispatcher(LOCAL_ENDPOINT, address(0));
    }

    /// @notice Test lz compose rejects unauthorized caller.
    function testLzComposeRejectsUnauthorizedCaller() external {
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.lzCompose(address(token), bytes32(0), "", address(0), "");
    }

    /// @notice Test lz compose rejects the launcher now that the compose entry is endpoint-only.
    function testLzComposeRejectsLauncherCaller() external {
        bytes memory message = abi.encode(ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, 1 ether);
        vm.prank(LAUNCHER);
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.lzCompose(address(token), bytes32("launcher-guid"), message, address(0), "");
    }

    /// @notice Test same-chain path rejects any caller other than the launcher.
    function testDistributeSameChainRejectsNonLauncherCaller() external {
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.distributeSameChain(address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, 1 ether);
    }

    /// @notice Test same-chain path rejects an out-of-range token type instead of silently no-oping.
    function testDistributeSameChainRevertsOnInvalidTokenType() external {
        // Out-of-range tokenType (uint8 = 2; enum only defines UASSET=0/MEMECOIN=1). Hand-build
        // calldata to bypass the compile-time enum bounds check. Solidity's ABI decoder rejects
        // out-of-range enum values before _settle runs; _settle's `else revert InvalidTokenType()`
        // is a defense-in-depth backstop in case the decoder ever lets one through. Either way the
        // call must fail rather than silently succeed and strand funds.
        bytes memory callData = bytes.concat(
            IYieldDispatcher.distributeSameChain.selector, abi.encode(address(token), ALICE, uint8(2), uint256(1 ether))
        );

        vm.prank(LAUNCHER);
        (bool ok,) = address(dispatcher).call(callData);

        assertFalse(ok, "out-of-range tokenType must not silently succeed");
    }

    /// @notice Test same-chain path burns memecoin for eoa receiver.
    function testDistributeSameChainBurnsMemecoinForEoaReceiver() external {
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            bytes32(0), address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, ALICE, amount, true
        );
        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount);

        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
    }

    /// @notice Test same-chain path approves exactly the amount and calls receivers.
    function testDistributeSameChainApprovesExactAmountAndCallsReceivers() external {
        uint256 memeAmount = 7 ether;
        uint256 uAssetAmount = 11 ether;
        token.mint(address(dispatcher), memeAmount + uAssetAmount);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            bytes32(0), address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, address(yieldVault), memeAmount, false
        );
        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(
            address(token), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN, memeAmount
        );
        assertEq(yieldVault.lastAccumulatedAmount(), memeAmount);
        // Mock vault's accumulateYields now pulls via transferFrom (mirroring the real vault), so the tokens move
        // into the vault and the dispatcher's allowance is consumed.
        assertEq(token.balanceOf(address(yieldVault)), memeAmount);
        assertEq(token.allowance(address(dispatcher), address(yieldVault)), 0);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            bytes32(0), address(token), IMemeverseOFTEnum.TokenType.UASSET, address(governor), uAssetAmount, false
        );
        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(
            address(token), address(governor), IMemeverseOFTEnum.TokenType.UASSET, uAssetAmount
        );
        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), uAssetAmount);
        // Mock governor's receiveTreasuryIncome now pulls via transferFrom (mirroring the real governor), so the tokens
        // move into the governor and the dispatcher's allowance is fully consumed.
        assertEq(token.balanceOf(address(governor)), uAssetAmount);
        assertEq(token.allowance(address(dispatcher), address(governor)), 0);
    }

    /// @notice lzCompose marks compose settled and routes funds.
    function testLzComposeMarksComposeSettledAndRoutesFunds() external {
        bytes32 guid = bytes32("new");
        uint256 amount = 9 ether;
        token.mint(address(dispatcher), amount);

        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.UASSET, address(governor), amount, false
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), amount);
        // The governor pulled the funds via transferFrom; nothing stranded in the dispatcher and the allowance is spent.
        assertEq(token.balanceOf(address(governor)), amount);
        assertEq(token.allowance(address(dispatcher), address(governor)), 0);
    }

    /// @notice Test local endpoint path burns the memecoin when the compose payload names an EOA receiver.
    /// @dev Mirrors testSettlePendingComposeBurnsForEoaReceiver but through the lzCompose entry: an EOA receiver must
    ///      hit `_settle`'s burn branch and emit OFTProcessed with burnedAtDispatcher=true, with the mutex landing on Settled.
    function testLzComposeBurnsMemecoinForEoaReceiver() external {
        bytes32 guid = bytes32("compose-eoa-burn");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // ALICE is an EOA (no code), so settlement must burn the tokens instead of pulling into a contract.
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, ALICE, amount, true
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Burned rather than stranded: the dispatcher balance drops to zero, the burn is recorded, and the mutex
        // resolved to Settled so a replay is blocked.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice lzCompose rejects a second lzCompose for the same guid (single-resolution mutex).
    function testLzComposeRejectsAlreadyResolvedCompose() external {
        bytes32 guid = bytes32("done");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);

        // First lzCompose resolves the guid to Settled.
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // A replayed lzCompose for the same guid must revert (single-resolution mutex).
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");
    }

    /// @notice lzCompose consumes a malformed compose message: the (token, guid) slot resolves to Settled with NO
    ///         settlement and the endpoint state machine can converge, instead of reverting and pinning the queue
    ///         for executor retries on a permanently-failing decode.
    /// @dev The 48-byte frame is shorter than the composeMsg region (offset 76) plus the 64-byte tuple, so
    ///      `_parseCompose`'s length guard (`message.length < 140`) returns unparseable before any `composeMsg`
    ///      slice can run — and the endpoint hash-binds the message to the guid, so it can never settle either.
    ///      Consuming the slot blocks no legitimate settlement; the endpoint's RECEIVED sentinel + ComposeDelivered
    ///      finish the state machine. The frame is 48 bytes >= 44, so `amountLD` is readable and the event carries
    ///      the real amount.
    function testLzComposeConsumesMalformedComposeMessage() external {
        bytes32 guid = bytes32("malformed");
        token.mint(address(dispatcher), 1 ether);

        // ComposeMsg contains only a 4-byte prefix and no (address, TokenType) tuple for abi.decode; the 48-byte
        // frame is below the 140-byte threshold, so `_parseCompose`'s length guard short-circuits (unparseable)
        // before any `composeMsg` slice can run.
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, hex"deadbeef");

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), 1 ether);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled) and the funds never moved.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), 1 ether);

        // The slot is terminal: even a valid payload for the same guid is rejected (AlreadyResolved), so a replay
        // cannot turn a consumed slot into a settlement.
        bytes memory validMessage = _dispatcherMessage(1 ether, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.lzCompose(address(token), guid, validMessage, address(0), "");
    }

    /// @notice lzCompose consumes an out-of-range tokenType payload instead of settling with a forged enum value: the
    ///         slot resolves to Settled with NO settlement and no funds moved.
    /// @dev The ABI decoder would reject the out-of-range enum (uint8(2) hand-encoded, since TokenType(2) itself
    ///      reverts during construction) before `_settle` runs; `_parseCompose` mirrors that rejection and consumes
    ///      the slot, since the endpoint hash-binds the message to the guid and it can never settle. The 140-byte
    ///      frame keeps `amountLD` readable, so the event carries the real amount.
    function testLzComposeConsumesInvalidTokenType() external {
        bytes32 guid = bytes32("invalid-type");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + hand-encoded (ALICE, uint8(2)) — uint8(2) is out of range for the two-value enum.
        bytes memory composeMessage = abi.encodePacked(bytes32(uint256(uint160(ALICE))), abi.encode(ALICE, uint8(2)));
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled) and the funds never moved. No valid retry can
        // exist for this guid: the endpoint hash-binds the delivered message, so a replayed lzCompose for the same
        // guid is unreachable (and would revert AlreadyResolved on the terminal slot).
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice lzCompose consumes a compose payload whose receiver slot carries dirty high bits instead of settling
    ///         with a forged address: the slot resolves to Settled with NO settlement and no funds moved.
    /// @dev The strict ABI decoder rejects an address word with non-zero high bits, so abi.decode would revert on
    ///      this payload — it can never settle; `_parseCompose` mirrors that rejection and consumes the slot. The
    ///      receiver slot is the first word of the encoded tuple (message[76:108]); `abi.encode` would mask the
    ///      dirty bits, so the tuple is hand-encoded word by word with bit 160 set (the lowest bit of the high 96
    ///      bits) in the receiver slot. The 140-byte frame keeps `amountLD` readable, so the event carries the real
    ///      amount.
    function testLzComposeConsumesDirtyHighBitsReceiver() external {
        bytes32 guid = bytes32("dirty-receiver");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + hand-encoded (ALICE-with-dirty-high-bits, MEMECOIN) — abi.encode would zero out the
        // dirty bits, so the tuple is packed word by word. Bit 160 makes receiverRaw >> 160 != 0.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            bytes32(uint256(uint160(ALICE)) | (1 << 160)), // receiver slot: dirty high bits
            bytes32(uint256(IMemeverseOFTEnum.TokenType.MEMECOIN)) // tokenType word
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled), the funds never moved, and nothing was
        // burned — the settle path (and its OFTProcessed) never ran.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.lastBurnAmount(), 0);
    }

    /// @notice lzCompose consumes a compose payload whose tokenType word carries dirty high bits above a valid low
    ///         value instead of settling with a forged enum: the slot resolves to Settled with NO settlement and no
    ///         funds moved.
    /// @dev The strict ABI decoder validates an enum word as exactly 0 or 1, so a word with dirty high bits above a
    ///      valid low value still reverts in abi.decode — the payload can never settle; `_parseCompose` mirrors that
    ///      rejection and consumes the slot. The tokenType slot is the second tuple word (message[108:140]);
    ///      `abi.encode` would mask the dirty bits, so the tuple is hand-encoded word by word with bit 200 set
    ///      above the valid low value 1. The 140-byte frame keeps `amountLD` readable, so the event carries the real
    ///      amount.
    function testLzComposeConsumesDirtyHighBitsTokenType() external {
        bytes32 guid = bytes32("dirty-type");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + hand-encoded (ALICE, MEMECOIN-with-dirty-high-bits) — abi.encode would mask the
        // dirty bits, so the tuple is packed word by word. Bit 200 makes the enum word != 0 and != 1.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            bytes32(uint256(uint160(ALICE))), // receiver word
            bytes32(uint256(IMemeverseOFTEnum.TokenType.MEMECOIN) | (1 << 200)) // tokenType word: dirty high bits
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled), the funds never moved, and nothing was
        // burned — the settle path (and its OFTProcessed) never ran.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.lastBurnAmount(), 0);
    }

    /// @notice lzCompose consumes an exactly 139-byte compose payload (the inner tuple is 1 byte short of 64): the
    ///         slot resolves to Settled with NO settlement, pinning the frame-length boundary against the 140-byte
    ///         valid frames the other tests settle.
    /// @dev A short tuple can never decode, so the payload can never settle; the `< COMPOSE_FROM_OFFSET + 64`
    ///      length guard rejects it before any word read. The 139-byte frame is still >= 44 bytes, so `amountLD`
    ///      is readable and the event carries the real amount.
    function testLzComposeRejects139ByteFrame() external {
        bytes32 guid = bytes32("short-frame");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + receiver word + a tokenType word truncated to 31 bytes: the tuple is 63 bytes, so
        // the full frame is 44 + 95 = 139 bytes and the length guard (< 76 + 64) rejects it before any decode.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            bytes32(uint256(uint160(ALICE))), // receiver word
            hex"00000000000000000000000000000000000000000000000000000000000001" // tokenType word truncated to 31 bytes
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
        assertEq(message.length, 139);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled) and the funds never moved.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.lastBurnAmount(), 0);
    }

    /// @notice lzCompose settles an overlong compose payload (inner tuple > 64 bytes, frame > 140) by its first two
    ///         words, ignoring the tail — identical semantics to a 64-byte inner.
    /// @dev Overlong inners are reachable only via a permissionless OFT direct send (the protocol send-side always
    ///      encodes a 64-byte inner), so the EOA burn below is the forward-consistent settlement for this self-harm
    ///      frame. The frame is 172 bytes (76-byte header + 96-byte inner) and the tail word is an out-of-range
    ///      TokenType raw (2) that would reject any code path that read it — proving `_parseCompose` settles purely
    ///      on the first two words (message[76:108] / [108:140]) and ignores the tail.
    function testLzComposeSettlesOverlongPayloadIgnoringTail() external {
        bytes32 guid = bytes32("overlong-lz");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + 64-byte (ALICE, MEMECOIN) tuple + a 32-byte dirty-enum tail that must be ignored.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            abi.encode(ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN), // the (address, TokenType) tuple
            bytes32(uint256(2)) // tail word: an out-of-range TokenType raw that must NOT be read
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
        assertEq(message.length, 172);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, ALICE, amount, true
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Settled exactly like the 64-byte frame: first-two-words settlement (EOA burn), tail ignored, mutex Settled.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice lzCompose with a valid frame naming address(0) as receiver settles through the normal path: address(0)
    ///         has no code, so `_settle`'s EOA branch burns the tokens (OFTProcessed burnedAtDispatcher=true) — it is NOT
    ///         absorbed by the malformed-payload consume path.
    /// @dev address(0) is a parseable receiver (a clean zero word) with an in-range tokenType, so the frame decodes
    ///      and must take the settle path — same as any other EOA receiver; this pins that a zero receiver keeps
    ///      the burn behavior instead of being consumed.
    function testLzComposeBurnsZeroReceiver() external {
        bytes32 guid = bytes32("zero-receiver");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + hand-encoded (address(0), MEMECOIN) — address(0) is a clean zero word, so the frame
        // is parseable and settles (EOA burn) rather than being consumed. `abi.encode(address(0), MEMECOIN)` produces
        // the same two words, so the helper expresses this frame byte-for-byte.
        bytes memory message = _dispatcherMessage(amount, ALICE, address(0), IMemeverseOFTEnum.TokenType.MEMECOIN);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, address(0), amount, true
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Burned rather than consumed or stranded: the dispatcher balance drops to zero and the burn is recorded.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice lzCompose consumes a clean, parseable payload that names the dispatcher itself as receiver instead of
    ///         reverting: the (token, guid) slot resolves to Settled with NO settlement and a ComposeRejected signal.
    /// @dev Self-reference guard. `_settleToContract` would call `accumulateYields`/`receiveTreasuryIncome` on the
    ///      dispatcher, which implements neither and has no fallback, so settlement always reverts. Without the guard
    ///      the revert would roll the Settled write back to None and pin the endpoint queue forever (no recovery
    ///      entrypoint). Mirroring the `!parseable` / `testLzComposeBurnsZeroReceiver` consume path, the slot stays
    ///      Settled and ComposeRejected lets the endpoint state machine converge. The funds strand in the dispatcher
    ///      by the sender's own construction (only a permissionless OFT direct send can encode receiver=dispatcher;
    ///      the protocol send-side always encodes governor/vault), so this is the documented self-harm boundary — the
    ///      guard removes the queue pin, not the strand. Covers both token types: MEMECOIN (vault callback) and
    ///      UASSET (governor callback).
    function testLzComposeConsumesSelfReferenceReceiver() external {
        // MEMECOIN branch: _settleToContract would call accumulateYields on the dispatcher.
        bytes32 guidMeme = bytes32("self-ref-meme");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        bytes memory messageMeme =
            _dispatcherMessage(amount, ALICE, address(dispatcher), IMemeverseOFTEnum.TokenType.MEMECOIN);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guidMeme, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guidMeme, messageMeme, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled), the callback never ran (no approval consumed),
        // and the funds strand in the dispatcher by the sender's own construction.
        assertEq(
            uint256(dispatcher.composeStates(address(token), guidMeme)), uint256(IComposeState.ComposeState.Settled)
        );
        assertEq(token.allowance(address(dispatcher), address(dispatcher)), 0);
        assertEq(token.balanceOf(address(dispatcher)), amount);

        // UASSET branch: _settleToContract would call receiveTreasuryIncome on the dispatcher.
        bytes32 guidUAsset = bytes32("self-ref-uasset");
        bytes memory messageUAsset =
            _dispatcherMessage(amount, ALICE, address(dispatcher), IMemeverseOFTEnum.TokenType.UASSET);

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guidUAsset, address(token), amount);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guidUAsset, messageUAsset, address(0), "");

        assertEq(
            uint256(dispatcher.composeStates(address(token), guidUAsset)), uint256(IComposeState.ComposeState.Settled)
        );
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose reverts on a self-reference payload (receiver == dispatcher) instead of converging:
    ///         the release path has no ComposeRejected equivalent, so — like its other content-invalid frames — it
    ///         reverts and rolls the Released write back to None, leaving the funds strand and the guid still `None`.
    /// @dev Settle-side boundary. The lzCompose guard (testLzComposeConsumesSelfReferenceReceiver) converges
    ///      the endpoint for the forward path; the settle path (permissionless, anyone may call) only re-triggers the
    ///      same failing settlement, so it reverts and changes nothing. This mirrors how the settle path treats its
    ///      other content-invalid frames (dirty-high-bits receiver, malformed composeMsg): revert, not consume. The
    ///      strand itself is the accepted self-harm outcome; a third party calling settle just wastes their own gas.
    function testSettlePendingComposeRevertsOnSelfReferenceReceiver() external {
        bytes32 guid = bytes32("self-ref-settle");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(dispatcher, MEMECOIN) — a clean, parseable payload naming the dispatcher.
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(dispatcher), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // Delivered but not yet executed: the endpoint queue slot holds the message hash settlePendingCompose proves
        // against.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // _settleToContract reverts at the binding's asset() probe (the dispatcher implements neither asset() nor
        // a fallback, so the MEMECOIN branch's `receiver.asset() == token` check cannot even execute), so the
        // Released write rolls back.
        vm.expectRevert();
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Nothing was consumed: the guid is still None, no approval was spent, and the funds stay stranded.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.allowance(address(dispatcher), address(dispatcher)), 0);
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice A failed settle rolls back the Settled write, leaving the guid retryable; success pins it and blocks replay.
    /// @dev Mirrors OmnichainMemecoinStaker.testLzComposeAllowsRetryAfterFailedDepositAndBlocksReplayAfterSuccess:
    ///      a settle-fail revert (vault accumulates revert) must roll the whole lzCompose back so composeStates returns to
    ///      None and the endpoint can retry, then a successful retry pins the guid and a further replay reverts.
    function testLzComposeAllowsRetryAfterFailedSettleAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("retry-settle");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // First attempt fails: the vault's accumulateYields reverts, and the whole lzCompose rolls back.
        yieldVault.setComposeProbe(address(dispatcher), guid);
        yieldVault.setShouldRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("settle failed");
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // The failed call reverted, rolling back the Settled write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(yieldVault.lastAccumulatedAmount(), 0);
        // The failed settle pulled nothing (the whole call reverted, approval rollback included).
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.balanceOf(address(yieldVault)), 0);

        // Retry succeeds after the failure is cleared: the guid resolves to Settled and the funds move to the vault.
        yieldVault.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, address(yieldVault), amount, false
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(yieldVault.lastAccumulatedAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));

        // A replay after success is blocked by the single-resolution mutex.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");
    }

    /// @notice A UASSET->governor settle-fail rolls back the Settled write, leaving the guid retryable; a successful
    ///         retry pins Settled and a further replay is blocked.
    /// @dev Mirror of the vault variant: when the governor's receiveTreasuryIncome reverts, the whole lzCompose rolls
    ///      back so composeStates returns to None and the endpoint can retry; a successful retry pins the guid and a
    ///      third call reverts with AlreadyResolved.
    function testLzComposeAllowsRetryAfterFailedGovernorSettleAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("retry-gov");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);

        // First attempt fails: the governor's receiveTreasuryIncome reverts, and the whole lzCompose rolls back.
        governor.setComposeProbe(address(dispatcher), guid);
        governor.setShouldRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("settle failed");
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // The failed call reverted, rolling back the Settled write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(governor.lastAmount(), 0);
        // The failed settle pulled nothing (the whole call reverted, approval rollback included).
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.balanceOf(address(governor)), 0);

        // Retry succeeds after the failure is cleared: the guid resolves to Settled and the funds move to the governor.
        governor.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.UASSET, address(governor), amount, false
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(governor)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));

        // A replay after success is blocked by the single-resolution mutex.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");
    }

    /// @notice A failed EOA-burn settle rolls back the Settled write, leaving the guid retryable; success pins it and blocks replay.
    /// @dev Mirror of the vault/governor variants through the EOA-burn branch: when `IBurnable.burn` reverts, the whole
    ///      lzCompose rolls back so composeStates returns to None and the endpoint can retry, then a successful retry pins
    ///      the guid and a further replay reverts. This closes the lzCompose failure-rollback gap for the push-based burn
    ///      branch (the vault/governor callbacks were already covered; the EOA burn is the third settle terminal action).
    function testLzComposeAllowsRetryAfterFailedBurnAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("retry-burn");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);

        // First attempt fails: the EOA-receiver burn reverts, and the whole lzCompose rolls back.
        token.setBurnShouldRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("settle failed");
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // The failed call reverted, rolling back the Settled write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.lastBurnAmount(), 0);
        // The failed settle pulled nothing (the whole call reverted).
        assertEq(token.balanceOf(address(dispatcher)), amount);

        // Retry succeeds after the failure is cleared: the guid resolves to Settled and the tokens are burned.
        token.setBurnShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, ALICE, amount, true
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));

        // A replay after success is blocked by the single-resolution mutex.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");
    }

    /// @notice A failed settlePendingCompose rolls back the Released write, leaving the guid retryable; a successful
    ///         retry pins Released and a further replay is blocked.
    /// @dev Mirror of testLzComposeAllowsRetryAfterFailedSettleAndBlocksReplayAfterSuccess through the settle entry:
    ///      when the vault's accumulateYields reverts, the whole settlePendingCompose rolls back so composeStates
    ///      returns to None and the endpoint queue slot keeps the keccak256(message) delivery proof (retry
    ///      precondition intact); the armed Released probe pins that the Released write precedes the settle external
    ///      call (CEI write order) when the retry succeeds.
    function testSettlePendingComposeAllowsRetryAfterFailedSettleAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("settle-retry");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(vault, MEMECOIN) — same layout the OFT's _lzReceive composes.
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // Delivered but not yet executed: the endpoint queue slot holds the message hash settlePendingCompose proves against.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // First attempt fails: the vault's accumulateYields reverts, and the whole settlePendingCompose rolls back.
        yieldVault.setComposeProbeReleased(address(dispatcher), guid);
        yieldVault.setShouldRevert(true);
        vm.expectRevert("settle failed");
        dispatcher.settlePendingCompose(address(token), guid, message);

        // The failed call reverted, rolling back the Released write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(yieldVault.lastAccumulatedAmount(), 0);
        // The failed settle pulled nothing (the whole call reverted, approval rollback included).
        assertEq(token.allowance(address(dispatcher), address(yieldVault)), 0);
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.balanceOf(address(yieldVault)), 0);
        // The endpoint slot still holds the message hash: the retry precondition (delivery proof) is intact.
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // Retry succeeds after the failure is cleared: the guid resolves to Released and the funds move to the vault.
        // The probe stays armed, so the retry callback also asserts the Released write is visible mid-call.
        yieldVault.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(yieldVault.lastAccumulatedAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));

        // A replay after success is blocked by the single-resolution mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice A failed UASSET->governor settlePendingCompose rolls back the Released write, leaving the guid
    ///         retryable; a successful retry pins Released and a further replay is blocked.
    /// @dev Mirror of testLzComposeAllowsRetryAfterFailedGovernorSettleAndBlocksReplayAfterSuccess through the settle
    ///      entry: when the governor's receiveTreasuryIncome reverts, the whole settlePendingCompose rolls back so
    ///      composeStates returns to None and the endpoint queue slot keeps the delivery proof; the armed Released
    ///      probe pins the CEI write order (Released before the settle external call) when the retry succeeds.
    function testSettlePendingComposeAllowsRetryAfterFailedGovernorSettleAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("settle-retry-gov");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // First attempt fails: the governor's receiveTreasuryIncome reverts, and the whole settlePendingCompose rolls back.
        governor.setComposeProbeReleased(address(dispatcher), guid);
        governor.setShouldRevert(true);
        vm.expectRevert("settle failed");
        dispatcher.settlePendingCompose(address(token), guid, message);

        // The failed call reverted, rolling back the Released write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(governor.lastAmount(), 0);
        // The failed settle pulled nothing: no allowance consumed, funds still in the dispatcher.
        assertEq(token.allowance(address(dispatcher), address(governor)), 0);
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.balanceOf(address(governor)), 0);
        // The endpoint slot still holds the message hash: the retry precondition (delivery proof) is intact.
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // Retry succeeds after the failure is cleared: the guid resolves to Released and the funds move to the governor.
        governor.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(governor), IMemeverseOFTEnum.TokenType.UASSET, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(governor)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));

        // A replay after success is blocked by the single-resolution mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose on MEMECOIN->vault approves and calls accumulateYields (pull + accounting), mirroring _settle.
    function testSettlePendingComposeMemecoinToVaultAccumulatesYield() external {
        bytes32 guid = bytes32("compose-meme");
        uint256 amount = 3 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(vault, MEMECOIN) — same layout the OFT's _lzReceive composes.
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // endpoint.composeQueue(token, dispatcher, guid, 0) = keccak256(message) => delivered, lzCompose not run yet.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // accumulateYields pulled the tokens into the vault and recorded the amount (no stranded balance).
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(yieldVault.lastAccumulatedAmount(), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice An empty-vault MEMECOIN settle burns the pulled yield inside the REAL vault (no shares exist to
    ///         credit), while the dispatcher still reports burnedAtDispatcher=false — the flag is an EOA/contract
    ///         discriminator, not an actual-burn indicator.
    /// @dev Pins the behavior where MemecoinYieldVault._accumulateYield burns when totalSupply()==0, so the token
    ///      emits a burn Transfer (to address(0)) and totalAssets stays 0, but the dispatcher's `_settle` only sets
    ///      burnedAtDispatcher on the EOA push-burn branch and reports false for the approve+pull contract path. The file's
    ///      MockDispatcherYieldVault always absorbs (it cannot express the empty-vault branch), so the real vault is
    ///      deployed behind a clone, mirroring the yield suite's deployment. The expectEmit sequence also pins that
    ///      the burn branch emits no AccumulateYields: a future change that absorbs instead of burns, flips burnedAtDispatcher,
    ///      or adds a spurious event on this path fails below.
    function testSettlePendingComposeToEmptyVaultBurnsYieldButEmitsIsBurnedFalse() external {
        // Real vault, no shares: settle hits the empty-vault burn branch. _yieldDispatcher is unused by the settle
        // path; the dispatcher address is passed for realism.
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        MemecoinYieldVault emptyVault = MemecoinYieldVault(Clones.clone(address(implementation)));
        emptyVault.initialize("Staked Memecoin", "sMEME", address(dispatcher), address(token), 1, 100 ether);
        assertEq(emptyVault.totalSupply(), 0, "vault must start empty");

        bytes32 guid = bytes32("compose-empty-vault");
        uint256 amount = 3 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(vault, MEMECOIN) — same layout the OFT's _lzReceive composes.
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(emptyVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // Delivered but not yet executed: the endpoint queue slot holds the message hash settlePendingCompose proves against.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // Event sequence: approve, pull Transfer (dispatcher -> vault), burn Transfer (vault -> address(0)), then
        // ComposeSettled with burnedAtDispatcher=false (the EOA/contract discriminator, NOT the actual burn).
        vm.expectEmit(true, true, true, true);
        emit ERC20.Approval(address(dispatcher), address(emptyVault), amount);
        vm.expectEmit(true, true, true, true);
        emit ERC20.Transfer(address(dispatcher), address(emptyVault), amount);
        vm.expectEmit(true, true, true, true);
        emit ERC20.Transfer(address(emptyVault), address(0), amount);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(emptyVault), IMemeverseOFTEnum.TokenType.MEMECOIN, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // The yield was burned, not absorbed: no value entered vault accounting and nothing is left in the vault.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(emptyVault.totalAssets(), 0, "burned yield must not enter totalAssets");
        assertEq(emptyVault.totalSupply(), 0, "burn path mints no shares");
        assertEq(token.balanceOf(address(emptyVault)), 0, "vault holds no burned yield");
        assertEq(token.balanceOf(address(dispatcher)), 0, "dispatcher drained");
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice settlePendingCompose on UASSET->governor pulls funds and records treasury income.
    function testSettlePendingComposeUAssetToGovernorPullsAndRecords() external {
        bytes32 guid = bytes32("compose-gov");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(governor), IMemeverseOFTEnum.TokenType.UASSET, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), amount);
        // The pull actually moved the funds: the governor holds the amount and the dispatcher's allowance is consumed.
        assertEq(token.balanceOf(address(governor)), amount);
        assertEq(token.allowance(address(dispatcher), address(governor)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice settlePendingCompose with an EOA receiver burns the tokens (mirrors `_settle`'s EOA burn branch).
    function testSettlePendingComposeBurnsForEoaReceiver() external {
        bytes32 guid = bytes32("compose-eoa");
        uint256 amount = 3 ether;
        token.mint(address(dispatcher), amount);

        // ALICE is an EOA (no code), so settlement must burn the tokens instead of pulling into a contract.
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount, true
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Burned rather than stranded: the dispatcher balance drops to zero and the burn is recorded.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice A failed EOA-burn settle rolls back the Released write, leaving the guid retryable; a successful retry
    ///         pins Released and a further replay is blocked.
    /// @dev Mirror of the vault/governor settle-rollback variants through the EOA-burn branch (the third `_settle`
    ///      terminal action): when `IBurnable.burn` reverts, the whole settlePendingCompose rolls back so composeStates
    ///      returns to None and the endpoint queue slot keeps the keccak256(message) delivery proof (retry
    ///      precondition intact), then a successful retry pins Released and a further replay reverts. Closes the
    ///      settle-rollback symmetry gap: lzCompose had all three terminal branches covered (L567 burn, L470 vault,
    ///      L518 governor), settle had only vault (L614) and governor (L669); the EOA-burn branch had success-only
    ///      coverage (testSettlePendingComposeBurnsForEoaReceiver). The receiver is an EOA, so (unlike the
    ///      vault/governor variants) there is no contract callback to run a Released probe — the CEI write order is
    ///      pinned via the pre/post composeStates assertions instead, matching the lzCompose EOA-burn rollback test.
    function testSettlePendingComposeAllowsRetryAfterFailedBurnAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("settle-retry-burn");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(ALICE, MEMECOIN) — ALICE is an EOA, so settlement hits `_settle`'s burn branch.
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);

        // Delivered but not yet executed: the endpoint queue slot holds the message hash settlePendingCompose proves against.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // First attempt fails: the EOA-receiver burn reverts, and the whole settlePendingCompose rolls back.
        token.setBurnShouldRevert(true);
        vm.expectRevert("settle failed");
        dispatcher.settlePendingCompose(address(token), guid, message);

        // The failed call reverted, rolling back the Released write, so the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.lastBurnAmount(), 0);
        // The failed settle burned nothing (the whole call reverted).
        assertEq(token.balanceOf(address(dispatcher)), amount);
        // The endpoint slot still holds the message hash: the retry precondition (delivery proof) is intact.
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // Retry succeeds after the failure is cleared: the guid resolves to Released and the tokens are burned.
        token.setBurnShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount, true
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));

        // A replay after success is blocked by the single-resolution mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose rejects an out-of-range tokenType instead of silently no-oping and stranding funds.
    function testSettlePendingComposeRevertsOnInvalidTokenType() external {
        bytes32 guid = bytes32("compose-invalid-type");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // TokenType 2 is out of range for the two-value enum; `TokenType(2)` itself reverts (Panic 0x21) during
        // construction, so the composeMessage is hand-encoded with uint8(2) (the enum's ABI layout is a padded uint8).
        // The ABI decoder rejects the out-of-range enum before `_settle` runs (empty-data revert), so the call fails
        // rather than silently succeeding and stranding the funds; `_settle`'s InvalidTokenType revert is the
        // defense-in-depth backstop for that same case.
        bytes memory composeMessage = abi.encodePacked(bytes32(uint256(uint160(ALICE))), abi.encode(ALICE, uint8(2)));
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectRevert();
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Nothing was consumed: the guid is still releasable and the funds are still in the dispatcher.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose rejects a malformed composeMsg (length < 64) with a named `MalformedComposeMsg`
    ///         error instead of an opaque `abi.decode` revert, mirroring `OmnichainMemecoinStaker.settlePendingCompose`.
    ///         Overlong frames (inner composeMsg > 64 bytes) are NOT rejected — the schema guard is >= 64 — and their
    ///         settle-side settlement is covered by testSettlePendingComposeSettlesOverlongPayloadIgnoringTail.
    /// @dev The inner composeMsg is a single 32-byte address (not the 64-byte (address, TokenType) tuple), so the
    ///      length guard reverts before `abi.decode` runs. A short tuple is one of the shapes the forward `lzCompose` path
    ///      also rejects — here it strands funds (no owner-recovery entrypoint for a self-built malformed payload,
    ///      hash-bound to the guid), so the named error makes the self-harm boundary readable. The slot is not consumed
    ///      (the revert rolls back before the Released write), so the guid stays `None` and the funds stay put.
    function testSettlePendingComposeRevertsOnMalformedComposeMsgLength() external {
        bytes32 guid = bytes32("compose-short-tuple");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + a single 32-byte address — the inner composeMsg is 32 bytes, not the 64-byte tuple.
        bytes memory composeMessage = abi.encodePacked(bytes32(uint256(uint160(ALICE))), abi.encode(ALICE));
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectRevert(abi.encodeWithSelector(IComposeState.MalformedComposeMsg.selector));
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Nothing was consumed: the guid is still releasable and the funds are still in the dispatcher.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose settles the same overlong frame lzCompose settles: verifySettle passes (frame
    ///         >= 76), the >= 64 schema guard passes, abi.decode takes the first two words, and the settlement is
    ///         identical to the forward path (same amount, receiver, burn result) — the §3.13 fallback = re-run of
    ///         the forward-consistent settlement.
    /// @dev The 172-byte frame's inner composeMsg is 96 bytes; the static (address, TokenType) `abi.decode` reads the
    ///      first 64 bytes and ignores the 32-byte tail. The tail word is an out-of-range TokenType raw (2) that
    ///      would revert any code path that read it, proving the tail is ignored; the settlement is then the EOA burn
    ///      of the same amount to the same receiver as testLzComposeSettlesOverlongPayloadIgnoringTail.
    function testSettlePendingComposeSettlesOverlongPayloadIgnoringTail() external {
        bytes32 guid = bytes32("overlong-settle");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // Same frame as the lzCompose overlong test: composeFrom(ALICE) + (ALICE, MEMECOIN) + dirty tail word.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            abi.encode(ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN), // the (address, TokenType) tuple
            bytes32(uint256(2)) // tail word: an out-of-range TokenType raw that must NOT be read
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
        assertEq(message.length, 172);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount, true
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Identical settlement to the forward path: same amount burned to the same EOA receiver, mutex Released.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice settlePendingCompose settles a 141-byte frame whose inner composeMsg is 65 bytes — the clean 64-byte
    ///         (receiver, TokenType) tuple plus a single non-word-aligned garbage tail byte. The >= 64 schema guard
    ///         passes and `abi.decode` reads only the first two words, ignoring the unaligned tail, so the settlement
    ///         is identical to the forward path (same amount, receiver, burn result).
    /// @dev The 1-byte unaligned tail is the sharpest boundary: any tail parsing beyond word boundaries would misread
    ///      it, proving the static decode consumes exactly the 64-byte tuple. This is the minimum overlong frame
    ///      (76-byte header + 65-byte inner), pinning the upper edge of the >= 64 guard in the settle fallback.
    function testSettlePendingComposeSettlesOverlongOneByteTail() external {
        bytes32 guid = bytes32("overlong-1byte-tail");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + (ALICE, MEMECOIN) tuple + 1 unaligned garbage byte: inner 65 bytes, frame 141.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            abi.encode(ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN), // the (address, TokenType) tuple
            hex"aa" // non-word-aligned tail byte that must be ignored
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
        assertEq(message.length, 141);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount, true
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Identical settlement to the forward path: same amount burned to the same EOA receiver, mutex Released.
        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice settlePendingCompose still rejects an inner tuple 1 byte short of 64 (139-byte frame) with the named
    ///         `MalformedComposeMsg`, pinning the lower bound of the >= 64 schema guard.
    /// @dev Same frame shape as testLzComposeRejects139ByteFrame: the inner composeMsg is 63 bytes, so the >= 64
    ///      guard reverts with the named error before `abi.decode`; the slot stays `None` and the funds stay put.
    function testSettlePendingComposeRevertsOn139ByteFrame() external {
        bytes32 guid = bytes32("settle-139-frame");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + receiver word + a tokenType word truncated to 31 bytes: inner 63 bytes, frame 139.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            bytes32(uint256(uint160(ALICE))), // receiver word
            hex"00000000000000000000000000000000000000000000000000000000000001" // tokenType word truncated to 31 bytes
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);
        assertEq(message.length, 139);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectRevert(abi.encodeWithSelector(IComposeState.MalformedComposeMsg.selector));
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Nothing was consumed: the guid is still releasable and the funds are still in the dispatcher.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose's schema guard is length-only: a 64-byte frame whose receiver word
    ///         carries dirty high bits passes the shape check and reverts with the UNNAMED empty-data `abi.decode`
    ///         revert, since the strict ABI decoder rejects a non-160-bit-clean address word. The slot is NOT consumed
    ///         (the revert rolls back before the Released write), so the guid stays `None` and the funds stay put —
    ///         the dispatcher's documented self-harm boundary, distinct from `lzCompose`'s consume-on-invalid path.
    /// @dev Mirrors the staker's settle-side dirty-high-bits test (which rejects with the named `MalformedComposeMsg`
    ///      because the staker reads the receiver word manually); the dispatcher's settle decodes the whole tuple
    ///      with `abi.decode`, so the dirty word surfaces as the decoder's empty-data revert.
    function testSettlePendingComposeRevertsOnDirtyHighBitsReceiver() external {
        bytes32 guid = bytes32("dirty-high-settle");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + hand-encoded (ALICE-with-dirty-high-bits, MEMECOIN) — a full 64-byte tuple, so the
        // length guard passes; the strict ABI decoder then rejects the dirty receiver word with an empty-data revert.
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), // compose-from word (the parse skips it)
            bytes32(uint256(uint160(ALICE)) | (1 << 160)), // receiver slot: dirty high bits
            bytes32(uint256(IMemeverseOFTEnum.TokenType.MEMECOIN)) // tokenType word
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // Bare expectRevert: the strict decoder's revert carries no data, so no selector is asserted.
        vm.expectRevert();
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Nothing was consumed: the guid is still releasable and the funds are still in the dispatcher.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose reverts with a named `MalformedComposeMsg` on a frame shorter than the 76-byte header,
    ///         before the codec slice in `verifySettle` could revert opaquely. Symmetric with the `lzCompose`-side
    ///         short-frame guard in `OmnichainMemecoinStaker`.
    /// @dev A 48-byte frame passes the queue hash proof (hash-bound to the guid) but has no `composeFrom` word, so
    ///      `composeMsg` ([76:]) would slice out of bounds; verifySettle's pre-guard fires `MalformedComposeMsg` first.
    function testSettlePendingComposeRevertsOnShortFrameBeforeHeaderComplete() external {
        bytes32 guid = bytes32("short-frame-settle");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // 48-byte frame (< 76, header incomplete): verifySettle's pre-guard fires before the codec slice.
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, hex"deadbeef");
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectRevert(abi.encodeWithSelector(IComposeState.MalformedComposeMsg.selector));
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Funds stay stranded; the guid stays `None`.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice settlePendingCompose reverts when compose was never delivered.
    function testSettlePendingComposeRevertsWhenNotDelivered() external {
        bytes32 guid = bytes32("never");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("x"));
        // composeQueue default is bytes32(0).
        vm.expectRevert(IComposeState.NotDelivered.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose reverts on a zero-amount payload instead of pinning the guid to Released.
    function testSettlePendingComposeRevertsOnZeroAmount() external {
        bytes32 guid = bytes32("zero");
        bytes memory message = _dispatcherMessage(0, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));
        vm.expectRevert(IYieldDispatcher.ZeroInput.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose reverts when lzCompose already executed (endpoint marked RECEIVED).
    function testSettlePendingComposeRevertsWhenAlreadyExecuted() external {
        bytes32 guid = bytes32("executed");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("x"));
        endpoint.markReceived(address(token), address(dispatcher), guid, 0);
        vm.expectRevert(IComposeState.AlreadyExecuted.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose reverts when message hash does not match the queue.
    function testSettlePendingComposeRevertsWhenHashMismatch() external {
        bytes32 guid = bytes32("mismatch");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("real"));
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(bytes("fake")));
        vm.expectRevert(IComposeState.InvalidProof.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice settlePendingCompose reverts when called twice for the same guid (mutex).
    function testSettlePendingComposeRevertsWhenAlreadyResolved() external {
        bytes32 guid = bytes32("twice");
        uint256 amount = 2 ether;
        token.mint(address(dispatcher), amount * 2);
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        dispatcher.settlePendingCompose(address(token), guid, message);
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice A forged settle with an attacker-owned token cannot burn the real (token, guid) compose mutex.
    /// @dev The forged MEMECOIN settle is intercepted by the token↔vault binding (AttackComposeToken.asset() == 0
    ///      != the forged token) and reverts TokenVaultMismatch before any approve or callback — it no longer even
    ///      consumes the attacker's own slot: the revert rolls the Released write back, so (attackToken, guid) stays
    ///      None and the real (token, guid) pair resolves normally afterwards. Mutex protection is therefore
    ///      stronger than the keying argument alone: the binding blocks the forged frame outright, and the real
    ///      (token, guid) keying blocks any binding-passing forgery from touching the genuine pair.
    function testSettlePendingComposeForgedTokenCannotBurnRealGuidMutex() external {
        bytes32 guid = bytes32("real-guid");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // Real delivery: the OFT writes composeQueue[token][dispatcher][guid][0].
        bytes memory realMessage =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        vm.prank(address(token));
        endpoint.sendCompose(address(dispatcher), guid, 0, realMessage);

        // Attacker: non-zero fake payload whose receiver is the attacker's own contract. The 1 wei amount is enough
        // to reach the binding: AttackComposeToken's asset() (0) never equals the forged token, so the forged settle
        // reverts TokenVaultMismatch before any approve or callback runs.
        AttackComposeToken attackToken = new AttackComposeToken();
        bytes memory fakeComposeMsg = abi.encodePacked(
            bytes32(uint256(uint160(address(this)))),
            abi.encode(address(attackToken), IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        bytes memory fakeMessage = OFTComposeMsgCodec.encode(2, 101, 1 wei, fakeComposeMsg);

        // Attacker writes its own queue slot and settles with its own token: the MEMECOIN token↔vault binding fires
        // first (receiver.asset() != delivered token) and the whole settle reverts, rolling the Released write back
        // — the attacker's (attackToken, guid) slot stays None and the real (token, guid) mutex is untouched.
        vm.prank(address(attackToken));
        endpoint.sendCompose(address(dispatcher), guid, 0, fakeMessage);
        vm.expectRevert(IYieldDispatcher.TokenVaultMismatch.selector);
        dispatcher.settlePendingCompose(address(attackToken), guid, fakeMessage);
        assertEq(
            uint256(dispatcher.composeStates(address(attackToken), guid)), uint256(IComposeState.ComposeState.None)
        );
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));

        // The real compose still resolves: lzCompose succeeds and the funds move to the vault.
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, realMessage, address(0), "");
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice Closure (b) on the dispatcher side: a forged settle whose token↔vault binding PASSES (the attacker's
    ///         vault reports the forged token as its `asset()`) succeeds and finalizes only the attacker's own
    ///         (fakeToken, guid) slot — the real (token, guid) mutex stays untouched, so the genuine compose still
    ///         settles. Keying (not the binding) is what isolates binding-passing forgeries from the real pair.
    /// @dev Dispatcher-side mirror of StakerTokenVaultBinding.t.sol's closure (b)
    ///      (testForgedComposeEvilVaultPullsOnlyFakeToken): unlike the mutex test above, whose AttackComposeToken
    ///      fails the binding (`asset() == 0`), the self-consistent fake vault passes it — the forged settle goes
    ///      through: the exact approval lands on the FAKE token only (the real token's allowance to the forged
    ///      vault stays 0) and the attacker's (fakeToken, guid) slot resolves to Released. The fake vault's settle
    ///      callbacks are no-ops, so nothing is pulled: the isolation proof is the real token's untouched custody
    ///      balance and zero allowances, not a fake-token balance transfer.
    function testSettlePendingComposeBindingPassingForgerySettlesOnlyAttackersSlot() external {
        bytes32 guid = bytes32("binding-pass-guid");
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        // Real delivery: the OFT writes composeQueue[token][dispatcher][guid][0].
        bytes memory realMessage =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        vm.prank(address(token));
        endpoint.sendCompose(address(dispatcher), guid, 0, realMessage);

        // Attacker's self-consistent pair: a forged token plus a vault reporting it as `asset()` — the binding
        // passes (fakeVault.asset() == fakeToken), so the forged settle succeeds instead of reverting.
        MockDispatcherComposeToken fakeToken = new MockDispatcherComposeToken("Fake Token", "FAKE");
        BindingPassingFakeVault fakeVault = new BindingPassingFakeVault(address(fakeToken));
        bytes memory fakeComposeMsg = abi.encodePacked(
            bytes32(uint256(uint160(address(this)))),
            abi.encode(address(fakeVault), IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        bytes memory fakeMessage = OFTComposeMsgCodec.encode(2, 101, 1 wei, fakeComposeMsg);

        // Attacker writes its own queue slot and settles: the binding passes, so the forged settle succeeds and
        // finalizes ONLY the attacker's (fakeToken, guid) slot; the real (token, guid) mutex stays None.
        vm.prank(address(fakeToken));
        endpoint.sendCompose(address(dispatcher), guid, 0, fakeMessage);
        dispatcher.settlePendingCompose(address(fakeToken), guid, fakeMessage);

        assertEq(
            uint256(dispatcher.composeStates(address(fakeToken), guid)),
            uint256(IComposeState.ComposeState.Released),
            "forged settle resolves only the attacker's own slot"
        );
        assertEq(
            uint256(dispatcher.composeStates(address(token), guid)),
            uint256(IComposeState.ComposeState.None),
            "real (token, guid) mutex untouched by the binding-passing forgery"
        );

        // Only the FAKE token was approved to the forged vault — exact approval, unspent (no-op callback) ...
        assertEq(
            fakeToken.allowance(address(dispatcher), address(fakeVault)),
            1 wei,
            "exact approval lands on the fake token only"
        );
        // ... the REAL token is never approved to the forged vault, and its custody balance is untouched.
        assertEq(
            token.allowance(address(dispatcher), address(fakeVault)), 0, "real token never approved to the forged vault"
        );
        assertEq(token.allowance(address(dispatcher), address(yieldVault)), 0, "real vault allowance unchanged");
        assertEq(token.balanceOf(address(dispatcher)), amount, "real custody balance unchanged by the forged settle");

        // The real compose still settles normally: funds move to the real vault, mutex Settled.
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, realMessage, address(0), "");
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice Regression: a forged compose (fake token from, fresh guid, REAL vault, MEMECOIN) driven through the
    ///         permissionless composer must revert with TokenVaultMismatch at the dispatcher's token↔vault binding —
    ///         before any approval or pull — leaving balances, vault state, and composeStates slots untouched.
    /// @dev Dispatcher-side mirror of StakerTokenVaultBinding.t.sol's testForgedTokenComposeRevertsTokenVaultMismatch
    ///      isolation: a standing max allowance on the REAL memecoin is restored before the forged attempt, so the
    ///      real vault COULD pull real funds if the binding were missing (the forged frame's amountLD is
    ///      attacker-chosen, and the vault's accumulateYields pulls its own stored asset — the real token). The
    ///      binding alone must still revert, proving the defense no longer depends on the exact-approval or
    ///      no-standing-allowance layers. No-stranding: a genuine compose afterwards still settles.
    function testForgedTokenComposeRevertsTokenVaultMismatch() external {
        uint256 custody = 100 ether; // real token in the dispatcher's custody (in-flight bridged credit)
        token.mint(address(dispatcher), custody);

        // ---- Isolation setup: restore the pre-fix standing max allowance on the REAL memecoin ----
        // Neutralizes the exact-approval layer: if the token↔vault binding were missing, the real vault's
        // accumulateYields pull could consume this allowance and drain the dispatcher's custody balance. The forged
        // pairing must revert at the require anyway, proving the binding alone closes the hole.
        vm.prank(address(dispatcher));
        token.approve(address(yieldVault), type(uint256).max);

        // ---- Step 1: forged token writes its own queue slot (permissionless, keyed by msg.sender) ----
        // amountLD = the full custody: a missing binding would let one forged frame drain everything via the
        // standing max allowance.
        bytes memory forgedComposeMsg = abi.encodePacked(
            OFTComposeMsgCodec.addressToBytes32(address(this)),
            abi.encode(address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        bytes memory forgedMessage = OFTComposeMsgCodec.encode(2, 101, custody, forgedComposeMsg);
        AttackComposeToken fake = new AttackComposeToken();
        vm.prank(address(fake));
        endpoint.sendCompose(address(dispatcher), bytes32("forged-guid"), 0, forgedMessage);

        // ---- Step 2: attacker drives the endpoint directly — the forged compose must revert ----
        // The endpoint's inner call reaches dispatcher.lzCompose with msg.sender == localEndpoint (the etched
        // mock), the MEMECOIN branch's binding fires first: yieldVault.asset() (the REAL token) != the forged
        // token, so the require reverts TokenVaultMismatch before the approve or pull; the whole endpoint call —
        // including the RECEIVED-sentinel write — rolls back.
        vm.expectRevert(IYieldDispatcher.TokenVaultMismatch.selector);
        endpoint.lzCompose(address(fake), address(dispatcher), bytes32("forged-guid"), 0, forgedMessage, "");

        // ---- Core assertions: the forged pairing moved nothing and consumed nothing ----
        assertEq(token.balanceOf(address(dispatcher)), custody, "dispatcher custody balance unchanged");
        assertEq(token.balanceOf(address(yieldVault)), 0, "vault pulled no real tokens");
        assertEq(token.balanceOf(address(this)), 0, "attacker drained no real tokens");
        assertFalse(yieldVault.accumulateYieldsCalled(), "vault callback never entered");
        assertEq(yieldVault.lastAccumulatedAmount(), 0, "no amount recorded");
        // The binding fires before `_safeApprove`, so the standing max allowance survives untouched.
        assertEq(
            token.allowance(address(dispatcher), address(yieldVault)),
            type(uint256).max,
            "binding reverted before the approval step"
        );
        // The forged compose slot was never RECEIVED-ized: the sentinel write rolled back with the revert, so the
        // queue still holds the queued hash (pending) and the dispatcher's single-resolution guard is clear.
        assertEq(
            endpoint.composeQueue(address(fake), address(dispatcher), bytes32("forged-guid"), 0),
            keccak256(forgedMessage),
            "forged compose slot still queued, not RECEIVED"
        );
        assertEq(
            uint256(dispatcher.composeStates(address(fake), bytes32("forged-guid"))),
            uint256(IComposeState.ComposeState.None),
            "reverted forged compose consumes nothing"
        );
        assertEq(
            uint256(dispatcher.composeStates(address(token), bytes32("forged-guid"))),
            uint256(IComposeState.ComposeState.None),
            "real token slot untouched"
        );

        // ---- No-stranding control: a genuine compose after the forged attempts still settles ----
        uint256 genuineAmount = 50 ether;
        token.mint(address(dispatcher), genuineAmount);
        bytes32 realGuid = bytes32("real-guid-after-forgery");
        bytes memory realMessage =
            _dispatcherMessage(genuineAmount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        vm.prank(address(token));
        endpoint.sendCompose(address(dispatcher), realGuid, 0, realMessage);
        endpoint.lzCompose(address(token), address(dispatcher), realGuid, 0, realMessage, "");

        assertEq(token.balanceOf(address(yieldVault)), genuineAmount, "genuine settle executed after forged attempts");
        assertEq(token.balanceOf(address(dispatcher)), custody, "dispatcher funds intact: only the genuine amount left");
        assertEq(
            uint256(dispatcher.composeStates(address(token), realGuid)),
            uint256(IComposeState.ComposeState.Settled),
            "genuine compose settled"
        );
    }

    /// @notice Race: settlePendingCompose resolves first, then a late endpoint lzCompose is absorbed as a no-op so the
    ///         endpoint's composeQueue slot converges to the RECEIVED sentinel instead of staying pending forever.
    function testLzComposeAbsorbedAfterSettlePendingCompose() external {
        bytes32 guid = bytes32("race-settle-first");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // settlePendingCompose wins first (funds settle to the message-encoded receiver).
        dispatcher.settlePendingCompose(address(token), guid, message);
        uint256 settledToGovernor = token.balanceOf(address(governor));

        // A late endpoint lzCompose is absorbed as a no-op: it must not revert, and the endpoint state machine
        // completes (queue slot -> RECEIVED sentinel) so the compose reaches ComposeDelivered.
        // Record logs around this absorbed call so we can prove the spec contract below: the Released branch of
        // lzCompose must NOT emit ANY event (events.md §4: the absorb branch is a no-op and emits nothing). The
        // only log in this window is the endpoint's own `ComposeDelivered` (emitted post-forward, mirroring the
        // real MessagingComposer), so the exact-set assertion below catches any composer-side emit — positive,
        // settle, reject, or a future event type — without a hand-written topic0 hash that could drift. Without
        // this closed-world assertion, a future spurious emit on the absorbed path would silently pass and cause
        // downstream consumers to double-account the settlement.
        vm.recordLogs();
        endpoint.lzCompose(address(token), address(dispatcher), guid, 0, message, bytes(""));
        Vm.Log[] memory absorbedLogs = vm.getRecordedLogs();
        assertEq(absorbedLogs.length, 1, "absorbed lzCompose must emit nothing besides the endpoint's ComposeDelivered");
        assertEq(absorbedLogs[0].emitter, address(endpoint), "the sole absorbed log is the endpoint's ComposeDelivered");

        // Endpoint slot converged to RECEIVED (bytes32(uint256(1))) and the composer mutex stayed Released —
        // no double settlement.
        assertEq(
            endpoint.composeQueue(address(token), address(dispatcher), guid, 0),
            OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH
        );
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
        // No double settlement: the receiver's balance is unchanged by the late lzCompose no-op.
        assertEq(token.balanceOf(address(governor)), settledToGovernor);
    }

    /// @notice Race: lzCompose resolves first, then settlePendingCompose reverts (mutex holds the other direction).
    function testSettlePendingComposeRevertsAfterLzCompose() external {
        bytes32 guid = bytes32("race-compose-first");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice E2E: a real OFT `_lzReceive` → `endpoint.sendCompose` write produces exactly the `composeQueue`
    ///         key `settlePendingCompose` reads, so a bridged compose settles without any hand-planted queue entry.
    /// @dev Drives the full production chain: the OFT's endpoint is the same LOCAL_ENDPOINT the dispatcher's
    ///      `localEndpoint` immutable points at, so `_lzReceive`'s `endpoint.sendCompose(toAddress, guid, 0, composeMsg)`
    ///      writes `composeQueue[oft][dispatcher][guid][0] = keccak256(composeMsg)`, and `settlePendingCompose` proves delivery
    ///      against that same key. This pins the "lzReceive writes what settlePendingCompose reads" invariant that the
    ///      hand-planted `setQueue` tests cannot.
    function testE2E_OFTLzReceiveWritesComposeQueueReadBySettlePendingCompose() external {
        OFTHarness oft = _deployOft();
        MockDispatcherYieldVault oftVault = new MockDispatcherYieldVault(address(oft));

        uint256 amount = 3 ether;
        bytes32 guid = bytes32("e2e-guid");
        // SendParam.composeMsg equivalent (matches MemeverseLauncherLib: `abi.encode(receiver, tokenType)`); the
        // source-side `OFTMsgCodec.encode` embeds `msg.sender` (compose-from) at send time, and the receive-side
        // `_lzReceive` only re-wraps it via `OFTComposeMsgCodec.encode`, so no extra prefix belongs here.
        bytes memory composeMessage = abi.encode(address(oftVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        bytes32 composeFrom = bytes32(uint256(uint160(address(this))));
        bytes memory message = _encodeOftLzReceiveMessage(
            bytes32(uint256(uint160(address(dispatcher)))), // sendTo
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );
        assertTrue(message.length > 40); // composed

        // Inbound nonce = 2 anchors the wire property that `_lzReceive` encodes the real `_origin.nonce` into the
        // compose payload: the queue-slot hash is rebuilt below with the same nonce 2, so a hardcoded nonce (e.g.
        // a literal 1) would make keccak256(settleMessage) diverge from the slot and fail the next assertion.
        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 2});
        vm.prank(LOCAL_ENDPOINT);
        oft.lzReceive(origin, guid, message, address(0), "");

        // The OFT minted the bridged amount to the payload's sendTo address (the dispatcher).
        assertEq(oft.balanceOf(address(dispatcher)), amount);

        // Rebuild the exact payload `_lzReceive` passed to endpoint.sendCompose:
        // OFTComposeMsgCodec.encode(nonce, srcEid, amountReceivedLD, _message.composeMsg());
        // _message.composeMsg() == message[40:] == composeFrom || composeMessage (amountReceivedLD == amount here).
        bytes memory settleMessage =
            OFTComposeMsgCodec.encode(2, 101, amount, abi.encodePacked(composeFrom, composeMessage));

        // The lzReceive → sendCompose write landed on exactly the key settlePendingCompose reads: from = the OFT, to = the dispatcher.
        assertEq(endpoint.composeQueue(address(oft), address(dispatcher), guid, 0), keccak256(settleMessage));

        dispatcher.settlePendingCompose(address(oft), guid, settleMessage);

        assertEq(oftVault.lastAccumulatedAmount(), amount);
        assertEq(oft.balanceOf(address(dispatcher)), 0);
        assertEq(oft.balanceOf(address(oftVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(oft), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice E2E: the `ComposeSent` log emitted by `sendCompose` during a real OFT `_lzReceive` carries the exact
    ///         payload `settlePendingCompose` must be given — decoding the log and copying its `message` field VERBATIM
    ///         (no re-encoding, no OFTComposeMsgCodec.encode) settles the compose, anchoring the ops runbook's
    ///         "原样拷贝 message 字段" step (operations.md §3.13).
    /// @dev Chains the runbook recovery: `lzReceive` → `sendCompose` writes the queue and emits `ComposeSent`
    ///      (from = the OFT, to = the dispatcher, message = the OFTComposeMsgCodec payload), and `settlePendingCompose`
    ///      proves delivery against keccak256(that payload). Re-encoding the payload from parts instead of copying the
    ///      log's `message` field verbatim would only prove codec self-consistency — the verbatim copy is what the
    ///      runbook directs and what an operator actually has on hand.
    function testE2E_ComposeSentMessageVerbatimCopiedSettles() external {
        OFTHarness oft = _deployOft();
        MockDispatcherYieldVault oftVault = new MockDispatcherYieldVault(address(oft));

        uint256 amount = 3 ether;
        bytes32 guid = bytes32("e2e-verbatim-guid");
        bytes memory composeMessage = abi.encode(address(oftVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        bytes32 composeFrom = bytes32(uint256(uint160(address(this))));
        bytes memory message = _encodeOftLzReceiveMessage(
            bytes32(uint256(uint160(address(dispatcher)))), // sendTo
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );

        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 1});
        bytes32 composeSentTopic0 = keccak256("ComposeSent(address,address,bytes32,uint16,bytes)");
        vm.recordLogs();
        vm.prank(LOCAL_ENDPOINT);
        oft.lzReceive(origin, guid, message, address(0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The OFT minted the bridged amount to the payload's sendTo address (the dispatcher).
        assertEq(oft.balanceOf(address(dispatcher)), amount);

        // Locate the endpoint's ComposeSent log and take its `message` field VERBATIM — the payload the runbook
        // copies, and the payload whose hash the queue slot holds (the exact key verifySettle reads).
        bytes memory settleMessage;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != composeSentTopic0) continue;
            found = true;
            (address from, address to, bytes32 logGuid, uint16 index, bytes memory payload) =
                abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
            assertEq(from, address(oft), "ComposeSent from is the composing OFT");
            assertEq(to, address(dispatcher), "ComposeSent to is the dispatcher");
            assertEq(logGuid, guid, "ComposeSent guid");
            assertEq(uint256(index), 0, "ComposeSent index");
            settleMessage = payload;
        }
        assertTrue(found, "lzReceive -> sendCompose emitted ComposeSent");
        assertEq(endpoint.composeQueue(address(oft), address(dispatcher), guid, 0), keccak256(settleMessage));

        // Settle with the verbatim-copied payload, exactly as the runbook directs — no re-encoding anywhere.
        dispatcher.settlePendingCompose(address(oft), guid, settleMessage);

        assertEq(oftVault.lastAccumulatedAmount(), amount);
        assertEq(oft.balanceOf(address(dispatcher)), 0);
        assertEq(oft.balanceOf(address(oftVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(oft), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice E2E negative: when the OFT payload's sendTo is not this dispatcher, the lzReceive → sendCompose
    ///         write lands under a different to-address, so `composeQueue[oft][dispatcher][guid][0]` stays zero and
    ///         settlePendingCompose reverts with NotDelivered (pins the to = dispatcher key invariant end to end).
    function testE2E_SettlePendingComposeRevertsNotDeliveredWhenSendToIsNotComposer() external {
        OFTHarness oft = _deployOft();

        uint256 amount = 3 ether;
        bytes32 guid = bytes32("e2e-guid-not-composer");
        // SendParam.composeMsg equivalent; receiver content is irrelevant here: settlePendingCompose reverts at
        // NotDelivered before decoding the payload.
        bytes memory composeMessage = abi.encode(address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // sendTo is a third-party address, NOT the dispatcher: the OFT mints there and the composer key is written
        // under [oft][0x1234][guid][0], never under the dispatcher's key.
        bytes32 composeFrom = bytes32(uint256(uint160(address(this))));
        bytes memory message = _encodeOftLzReceiveMessage(
            bytes32(uint256(uint160(address(0x1234)))), // sendTo
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );

        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 2});
        vm.prank(LOCAL_ENDPOINT);
        oft.lzReceive(origin, guid, message, address(0), "");

        bytes memory settleMessage =
            OFTComposeMsgCodec.encode(2, 101, amount, abi.encodePacked(composeFrom, composeMessage));
        // Pin the write side independently: the key landed under the 0x1234 to-address, so the dispatcher slot is
        // genuinely empty rather than silently unwritten.
        assertTrue(endpoint.composeQueue(address(oft), address(0x1234), guid, 0) != bytes32(0));
        // composeQueue[oft][dispatcher][guid][0] is still bytes32(0): the compose was delivered elsewhere.
        vm.expectRevert(IComposeState.NotDelivered.selector);
        dispatcher.settlePendingCompose(address(oft), guid, settleMessage);
    }

    /// @notice E2E: `lzReceive` → real composer `lzCompose` settles the compose through the dispatcher and the
    ///         resolved guid blocks `settlePendingCompose` (mutex).
    /// @dev Chains the full production flow: `lzReceive`'s `endpoint.sendCompose` writes
    ///      `composeQueue[oft][dispatcher][guid][0] = keccak256(composePayload)`, then the mock's `lzCompose` (mirroring
    ///      MessagingComposer.sol) validates the hash, stores the RECEIVED sentinel, and forwards to `dispatcher.lzCompose`,
    ///      which settles the vault. A later `settlePendingCompose` reverts on the AlreadyResolved mutex — the RECEIVED sentinel is
    ///      written by `lzCompose`, not `markReceived`, so the whole queue read/write surface is exercised end to end.
    function testE2E_OFTLzReceiveComposerLzComposeSettlesAndBlocksSettlePendingCompose() external {
        OFTHarness oft = _deployOft();
        MockDispatcherYieldVault oftVault = new MockDispatcherYieldVault(address(oft));

        uint256 amount = 3 ether;
        bytes32 guid = bytes32("e2e-compose-settle");
        bytes memory composeMessage = abi.encode(address(oftVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        bytes32 composeFrom = bytes32(uint256(uint160(address(this))));
        bytes memory message = _encodeOftLzReceiveMessage(
            bytes32(uint256(uint160(address(dispatcher)))), // sendTo
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );

        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 2});
        vm.prank(LOCAL_ENDPOINT);
        oft.lzReceive(origin, guid, message, address(0), "");

        // The OFT minted the bridged amount to the dispatcher (the payload's sendTo).
        assertEq(oft.balanceOf(address(dispatcher)), amount);

        // Rebuild the exact payload `_lzReceive` passed to endpoint.sendCompose:
        // OFTComposeMsgCodec.encode(nonce, srcEid, amountReceivedLD, _message.composeMsg()).
        bytes memory composePayload =
            OFTComposeMsgCodec.encode(2, 101, amount, abi.encodePacked(composeFrom, composeMessage));

        // Drive the real composer execute path: the mock validates the queue hash, stores the RECEIVED sentinel, and
        // forwards to dispatcher.lzCompose (the dispatcher's `localEndpoint` immutable is this etched mock).
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(oft), IMemeverseOFTEnum.TokenType.MEMECOIN, address(oftVault), amount, false
        );
        endpoint.lzCompose(address(oft), address(dispatcher), guid, 0, composePayload, bytes(""));

        // The endpoint recorded RECEIVED (bytes32(uint256(1))) via lzCompose, not the hand-planted markReceived.
        assertEq(
            endpoint.composeQueue(address(oft), address(dispatcher), guid, 0),
            OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH
        );
        // The dispatcher settled the compose through its normal lzCompose entry.
        assertEq(uint256(dispatcher.composeStates(address(oft), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(oftVault.lastAccumulatedAmount(), amount);
        assertEq(oft.balanceOf(address(dispatcher)), 0);
        assertEq(oft.balanceOf(address(oftVault)), amount);

        // The guid already resolved via the real compose path; settlePendingCompose is blocked by the mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(oft), guid, composePayload);

        // Pins the mock's replay-rejection face: the slot now holds the RECEIVED sentinel (bytes32(1)), so a replayed
        // lzCompose with the same payload fails the hash check (keccak256(payload) != RECEIVED) with ComposeNotFound,
        // mirroring the real composer's one-shot execute guard.
        vm.expectRevert(MockMessagingComposerEndpoint.ComposeNotFound.selector);
        endpoint.lzCompose(address(oft), address(dispatcher), guid, 0, composePayload, bytes(""));
    }

    /// @notice E2E negative: the mock composer's `lzCompose` rejects a payload whose hash does not match the queue slot
    ///         written by `lzReceive` → `sendCompose` (pins the mock's ComposeNotFound guard, mirroring the real
    ///         composer's LZ_ComposeNotFound rejection of a payload that was never delivered for that key).
    function testE2E_LzComposeRejectsMismatchedHash() external {
        OFTHarness oft = _deployOft();
        MockDispatcherYieldVault oftVault = new MockDispatcherYieldVault(address(oft));

        uint256 amount = 3 ether;
        bytes32 guid = bytes32("e2e-compose-mismatch");
        bytes memory composeMessage = abi.encode(address(oftVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        bytes32 composeFrom = bytes32(uint256(uint160(address(this))));
        bytes memory message = _encodeOftLzReceiveMessage(
            bytes32(uint256(uint160(address(dispatcher)))), // sendTo
            oft.toSharedDecimals(amount), // amountSD
            composeFrom, // compose-from (source-chain sender)
            composeMessage
        );

        Origin memory origin = Origin({srcEid: 101, sender: bytes32(uint256(uint160(0xBEEF))), nonce: 1});
        vm.prank(LOCAL_ENDPOINT);
        oft.lzReceive(origin, guid, message, address(0), "");

        // Rebuild the payload `_lzReceive` passed to endpoint.sendCompose, but with a different composeMessage section:
        // the queue slot holds keccak256(composeFrom || composeMessage), so this payload's hash cannot match.
        bytes memory wrongPayload =
            OFTComposeMsgCodec.encode(1, 101, amount, abi.encodePacked(composeFrom, hex"deadbeef"));
        vm.expectRevert(MockMessagingComposerEndpoint.ComposeNotFound.selector);
        endpoint.lzCompose(address(oft), address(dispatcher), guid, 0, wrongPayload, bytes(""));
    }

    /// @notice E2E: a malformed compose driven through the endpoint's `lzCompose` is consumed (ComposeRejected), so
    ///         the queue slot converges to the RECEIVED sentinel instead of staying pending and pinning the queue
    ///         for executor retries on a permanently-failing decode.
    /// @dev Mirrors the real endpoint flow: the mock validates the planted delivery hash, stores the RECEIVED
    ///      sentinel, then forwards to `dispatcher.lzCompose`, which consumes the malformed payload (no settlement,
    ///      no funds moved) and returns success — so the endpoint call completes and the slot lands on RECEIVED, the
    ///      exact convergence the consume-on-invalid fix exists to produce. The sub-44-byte frame also covers the
    ///      `amountLD` unreadable branch (amount 0 in the event).
    function testE2E_MalformedComposeConsumedThroughEndpointConverges() external {
        bytes32 guid = bytes32("e2e-malformed");
        uint256 amount = 1 ether;
        token.mint(address(dispatcher), amount);

        // Sub-44-byte frame: amountLD at [12:44] is not fully present, so the event reports amount 0 (the frame is
        // hand-planted — a real sendCompose always codec-encodes to >= 44 bytes, so this only exercises the
        // defense-in-depth guard).
        bytes memory message = hex"00112233445566778899aabb";
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(token), 0);
        endpoint.lzCompose(address(token), address(dispatcher), guid, 0, message, bytes(""));

        // The endpoint state machine converged: RECEIVED sentinel, not a pending hash.
        assertEq(
            endpoint.composeQueue(address(token), address(dispatcher), guid, 0),
            OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH
        );
        // The dispatcher consumed the slot with NO settlement: mutex Settled, funds untouched.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice E2E: a failed forward through the real endpoint composer (endpoint.lzCompose) rolls the queue back to
    ///         the delivery hash, so the same (token,guid) settlePendingCompose later releases successfully — closing
    ///         the gap, where the existing failure-rollback test calls dispatcher.lzCompose directly (bypassing
    ///         the endpoint composer) and the settle test plants the queue via setQueue, so the two halves were never
    ///         chained through the real composer path.
    /// @dev The mock lzCompose validates the delivery hash, writes the RECEIVED sentinel, then forwards to the receiver
    ///      (CEI mirroring production MessagingComposer.sol). A receiver revert rolls the whole call back, including the
    ///      RECEIVED write, so the slot returns to keccak256(message) — exactly the state verifySettle accepts
    ///      (non-zero, non-RECEIVED, hash matches). This test pins that invariant: after an endpoint-forward failure the
    ///      slot must keep the delivery hash and the mutex stays None, so the same-guid settle succeeds and lands Released.
    function testE2E_EndpointLzComposeFailureRollsBackQueueAndSameGuidSettleSucceeds() external {
        bytes32 guid = bytes32("e2e-fail-recover");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);

        // Real composer delivery mirroring OFT _lzReceive -> sendCompose: the token (msg.sender) plants the dispatcher's
        // compose key, which is the slot verifySettle later reads.
        vm.prank(address(token));
        endpoint.sendCompose(address(dispatcher), guid, 0, message);
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // Inject a receiver failure, then drive the real composer forward: the mock writes RECEIVED then forwards, and
        // the vault revert rolls the whole call back, including the RECEIVED sentinel write.
        yieldVault.setShouldRevert(true);
        vm.expectRevert("settle failed");
        endpoint.lzCompose(address(token), address(dispatcher), guid, 0, message, "");

        // Invariant: the reverted endpoint forward left the slot on the delivery hash, not RECEIVED/0 — the state
        // verifySettle accepts.
        assertEq(
            endpoint.composeQueue(address(token), address(dispatcher), guid, 0),
            keccak256(message),
            "reverted lzCompose rolled back the RECEIVED sentinel write"
        );
        // Mutex not advanced and funds untouched by the failed forward.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(yieldVault.lastAccumulatedAmount(), 0);

        // Same (token,guid) recovers: clear the injected failure, expect the settlement event, and settle successfully.
        yieldVault.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        // Settlement moved funds into the vault and advanced the mutex to Released.
        assertEq(yieldVault.lastAccumulatedAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));

        // Replay blocked on the now-Released mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    /// @notice A zero-amount lzCompose to an EOA receiver converges: the mock token's `burn(0)` is a no-op, the CEI
    ///         Settled write sticks, and no funds move.
    /// @dev Pins the dispatcher's zero-amount EOA branch: _settle short-circuits on amount==0 (returns
    ///      burnedAtDispatcher=false) before reaching burn, so no downstream call occurs regardless of whether the mock or real
    ///      Memecoin (which reverts ZeroInput) is used — resolving the mock-vs-production divergence. The CEI
    ///      Settled write sticks and the endpoint state machine converges.
    function testLzComposeZeroAmountEoaReceiverConvergesToSettled() external {
        bytes32 guid = bytes32("zero-eoa");
        // ALICE is an EOA (no code), so settlement hits the burn branch; amount 0 makes the mock burn a no-op.
        bytes memory message = _dispatcherMessage(0, ALICE, ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN);
        // Fund the dispatcher so the balance assertion is non-vacuous: the short-circuit must leave other custody
        // funds untouched (no burn, no transfer).
        token.mint(address(dispatcher), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, ALICE, 0, false);
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Short-circuit skipped burn entirely (lastBurnAmount stays its initial 0); dispatcher's pre-funded custody is
        // untouched, mutex is terminal.
        assertEq(token.lastBurnAmount(), 0);
        assertEq(token.balanceOf(address(dispatcher)), 1 ether);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A zero-amount lzCompose to a MEMECOIN contract receiver (yield vault) converges: `accumulateYields(0)`
    ///         pulls nothing, the CEI Settled write sticks, and no funds move.
    /// @dev Pins the dispatcher's MEMECOIN→vault branch under amount 0: _settle short-circuits on amount==0
    ///         before reaching _settleToContract, so accumulateYields is not called. Convergence is now uniform across all
    ///         branches (matches the real MemecoinYieldVault._accumulateYield's if (yield == 0) return early-exit in
    ///         outcome — no accounting change).
    ///         Note: the called-flag pins the dispatcher's "no callback on zero amount" design contract — production
    ///         MemecoinYieldVault also converges on 0 (early return), so there is no production revert to mirror; if the
    ///         contract is ever relaxed to route zero amounts into the vault callback, this test must be updated.
    function testLzComposeZeroAmountMemecoinVaultConvergesToSettled() external {
        bytes32 guid = bytes32("zero-vault");
        bytes memory message =
            _dispatcherMessage(0, address(yieldVault), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        // Fund the dispatcher so the balance assertions are non-vacuous: the short-circuit must leave the funds in
        // place (no approve, no transfer).
        token.mint(address(dispatcher), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.MEMECOIN, address(yieldVault), 0, false
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Short-circuit skipped accumulateYields entirely — accumulateYieldsCalled pins "not called" (lastAccumulatedAmount
        // cannot distinguish called-with-0 from never-called). No funds moved, mutex is terminal.
        assertFalse(yieldVault.accumulateYieldsCalled());
        assertEq(yieldVault.lastAccumulatedAmount(), 0);
        assertEq(token.balanceOf(address(yieldVault)), 0);
        assertEq(token.balanceOf(address(dispatcher)), 1 ether);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A zero-amount lzCompose to a UASSET contract receiver (governor) converges: `receiveTreasuryIncome(0)`
    ///         pulls nothing, the CEI Settled write sticks, and no funds move.
    /// @dev Pins the dispatcher's UASSET→governor branch under amount 0: _settle short-circuits on amount==0
    ///      before reaching _settleToContract, so receiveTreasuryIncome is not called — resolving the
    ///      mock-vs-production divergence (the real recordTreasuryIncome reverts ZeroInput). The CEI Settled write sticks
    ///      and the endpoint state machine converges.
    function testLzComposeZeroAmountUassetGovernorConvergesToSettled() external {
        bytes32 guid = bytes32("zero-governor");
        bytes memory message =
            _dispatcherMessage(0, address(governor), address(governor), IMemeverseOFTEnum.TokenType.UASSET);
        // Fund the dispatcher so the balance assertions are non-vacuous.
        token.mint(address(dispatcher), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(token), IMemeverseOFTEnum.TokenType.UASSET, address(governor), 0, false
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        // Short-circuit skipped receiveTreasuryIncome entirely; no funds moved, mutex is terminal.
        assertEq(governor.lastAmount(), 0);
        assertEq(token.balanceOf(address(governor)), 0);
        assertEq(token.balanceOf(address(dispatcher)), 1 ether);
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice settlePendingCompose's approve+callback path has NO `nonReentrant` (the dispatcher's `_settleToContract`
    ///         uses `_safeApprove` + external callback, never `_transferOut`). Its reentrancy defense is the
    ///         `composeStates` mutex (CEI: Released written before `_settle` at YieldDispatcher.sol:119). This test pins
    ///         that mutex as the regression guard: a malicious vault that reenters `settlePendingCompose` (same guid)
    ///         during its `accumulateYields` callback reverts `AlreadyResolved` — NOT `ReentrancyGuardReentrantCall`,
    ///         which the dispatcher's settle path cannot emit (no `nonReentrant` on it).
    /// @dev The `ReentrancyGuardReentrantCall` assertion that holds for the staker's `_transferOut` path does NOT hold
    ///      here: the dispatcher's reentrant settle reverts at the mutex check, never reaching any reentrancy lock.
    function testSettlePendingComposeRevertsOnReentrantCallbackDuringSettle() external {
        bytes32 guid = bytes32("dispatcher-reentrancy");
        uint256 amount = 3 ether;
        token.mint(address(dispatcher), amount);

        // composeFrom(ALICE) + abi.encode(reentrantVault, MEMECOIN) — settle routes to the MEMECOIN/vault branch.
        ReentrantDispatcherVault reentrantVault = new ReentrantDispatcherVault(address(token), address(dispatcher));
        bytes memory message =
            _dispatcherMessage(amount, ALICE, address(reentrantVault), IMemeverseOFTEnum.TokenType.MEMECOIN);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // Arm the vault to reenter settlePendingCompose (same guid) from inside its accumulateYields callback.
        reentrantVault.armReentry(address(token), guid, message);

        // The outer settle writes Released (CEI), then `_settle` -> `_settleToContract` -> approve + accumulateYields;
        // the malicious callback reenters settlePendingCompose with the same guid, which reads Released and reverts
        // `AlreadyResolved` (the mutex defense — no `nonReentrant` is involved on this path).
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);

        // The whole outer call reverted, so the Released write rolled back: the guid is still resolvable.
        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice Builds the raw OFT `_lzReceive` payload used by the E2E tests.
    /// @dev Wire format mirrors OFTMsgCodec.encode: sendTo(32) || amountSD(8) || composeFrom(32) || composeMessage.
    ///      The compose-from is the source-chain sender; pin it to the test contract for determinism. The amount
    ///      must be an exact multiple of the OFT's decimalConversionRate() (1e12): the reconstructed compose
    ///      payload only matches what `_lzReceive` wrote when amountReceivedLD (== _toLD(amountSD)) round-trips
    ///      exactly. The raw layout is deliberate: the inbound message must not go through OFTMsgCodec.encode, or
    ///      the E2E would only prove codec self-consistency instead of pinning the wire format end to end.
    function _encodeOftLzReceiveMessage(
        bytes32 sendTo,
        uint64 amountSD,
        bytes32 composeFrom,
        bytes memory composeMessage
    ) internal pure returns (bytes memory message) {
        message = abi.encodePacked(sendTo, amountSD, composeFrom, composeMessage);
    }

    /// @dev Deploys an initialized OFT clone whose endpoint is LOCAL_ENDPOINT and sets the trusted peer for srcEid 101.
    function _deployOft() internal returns (OFTHarness oft) {
        // Direct deployment is locked by Initializable's constructor; use a clone like OutrunOFTInit.t.sol.
        OFTHarness implementation = new OFTHarness(LOCAL_ENDPOINT);
        oft = OFTHarness(address(implementation).clone());
        oft.initialize(OWNER, "E2E Meme", "E2EM", address(0xCAFE));
        vm.prank(OWNER);
        oft.setPeer(101, bytes32(uint256(uint160(0xBEEF))));
    }
}

/// @title YieldDispatcherRealGovernorIntegrationTest
/// @notice Real dispatcher + real governor (behind ERC1967 proxy) + real incentivizer UASSET settle integration:
///         pins the operations.md §3.13 recovery promise ("non-zero amount but token unregistered →
///         NonTreasuryToken → register via governance → retry, recoverable") on the real pull-then-validate stack.
///         The unit-level MockDispatcherGovernor has no `_treasuryTokens` registry, so the NonTreasuryToken failure
///         mode and the register-then-retry round trip were previously inexpressible on the dispatcher path.
contract YieldDispatcherRealGovernorIntegrationTest is ComposerEndpointFixture {
    address internal constant ALICE = address(0xA11CE);
    address internal constant LAUNCHER = address(0x2222);

    YieldDispatcher internal dispatcher;
    MockDispatcherComposeToken internal token;
    MockMessagingComposerEndpoint internal endpoint;
    MemecoinDaoGovernorUpgradeable internal governor;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockGovernorVotesToken internal votesToken;

    /// @notice Deploy the real governor/incentivizer proxy pair (mutual wiring, mirroring
    ///         GovernanceIncentivizerPairIntegration.t.sol) plus the real dispatcher over the mock endpoint.
    function setUp() external {
        votesToken = new MockGovernorVotesToken();
        votesToken.setVotes(ALICE, 100 ether);

        // The incentivizer proxy is deployed uninitialized first (its initialize needs the governor address).
        incentivizer = GovernanceCycleIncentivizerUpgradeable(
            address(new UnsafeUninitializedProxy(address(new GovernanceCycleIncentivizerUpgradeable()), bytes("")))
        );

        // votingDelay=0 / votingPeriod=5 here are test accelerators only. Production deploys with
        // votingDelay=1 days + votingPeriod=1 weeks (src/verse/deployment/MemeverseProxyDeployer.sol:188-189,
        // no timelock extension), so a real register-then-retry sits in an ~8-day governance window where
        // settle retries keep reverting NonTreasuryToken until the registration proposal executes. See
        // operations.md §3.13 UASSET recovery entry.
        governor = MemecoinDaoGovernorUpgradeable(
            payable(address(
                    new ERC1967Proxy(
                        address(new MemecoinDaoGovernorUpgradeable()),
                        abi.encodeCall(
                            MemecoinDaoGovernorUpgradeable.initialize,
                            (
                                "Memecoin DAO",
                                IVotes(address(votesToken)),
                                0,
                                5,
                                1 ether,
                                10,
                                address(incentivizer),
                                0,
                                0,
                                1000,
                                6000
                            )
                        )
                    )
                ))
        );

        // Complete the mutual wiring: the incentivizer learns its governor.
        address[] memory initTokens = new address[](0);
        incentivizer.initialize(address(governor), initTokens);

        endpoint = new MockMessagingComposerEndpoint();
        dispatcher = new YieldDispatcher(address(endpoint), LAUNCHER);
        token = new MockDispatcherComposeToken("Compose Token", "CMP");
    }

    /// @notice Real-stack UASSET settle: an unregistered token reverts NonTreasuryToken with atomic rollback
    ///         (composeStates stays None, funds unmoved, queue slot intact); after governance registration the
    ///         documented retry succeeds, the real incentivizer ledger is credited, and replay is blocked.
    function testSettlePendingComposeUassetRealGovernorRecoverableAfterRegistration() external {
        bytes32 guid = bytes32("real-gov-settle");
        uint256 amount = 4 ether;
        token.mint(address(dispatcher), amount);

        bytes memory message = _dispatcherMessage(amount, ALICE, address(governor), IMemeverseOFTEnum.TokenType.UASSET);
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // First attempt: the token is not yet a treasury token. The real governor pulls the approved tokens
        // (safeTransferFrom), then recordTreasuryIncome reverts NonTreasuryToken — the whole call rolls back
        // atomically: the pull is undone, the Released write is rolled back, and the guid stays resolvable.
        vm.expectRevert(IGovernanceCycleIncentivizer.NonTreasuryToken.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
        assertEq(token.balanceOf(address(governor)), 0);
        assertEq(token.allowance(address(dispatcher), address(governor)), 0);
        // The endpoint slot still holds the delivery proof: the retry precondition is intact.
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // The documented recovery step: register the token through the real incentivizer via governance.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCallPayload(
            address(incentivizer),
            abi.encodeCall(GovernanceCycleIncentivizerUpgradeable.registerTreasuryToken, (address(token)))
        );
        _proposePassAndExecute(targets, values, calldatas, "register-token");

        // Retry succeeds: the §3.13 "register then retry, recoverable" promise holds on the real stack.
        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid, address(token), address(governor), IMemeverseOFTEnum.TokenType.UASSET, amount, false
        );
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.Released));
        assertEq(token.balanceOf(address(dispatcher)), 0);
        assertEq(token.balanceOf(address(governor)), amount);
        // The real incentivizer treasury ledger is credited through the dispatcher path (cycle 1).
        assertEq(incentivizer.getTreasuryBalance(1, address(token)), amount);

        // A replay after success is blocked by the single-resolution mutex.
        vm.expectRevert(IYieldDispatcher.AlreadyResolved.selector);
        dispatcher.settlePendingCompose(address(token), guid, message);
    }

    function _proposePassAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        // Compresses the propose→vote→execute cycle into a few blocks via vm.roll. The governor has no
        // timelock, so there is no queue step to wait through; this helper does not model the production
        // votingDelay(1 days)+votingPeriod(1 weeks) latency — see setUp comment and operations.md §3.13.
        vm.prank(ALICE);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _singleCallPayload(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        calldatas[0] = data;
    }
}

/// @title UnsafeUninitializedProxy
/// @notice Test-only ERC1967Proxy that may be deployed without an initializer call. The real Governor and
///         Incentivizer initializers each reference the other's proxy address, so one proxy must be deployed
///         uninitialized first and initialized after the pair is wired. Mirror of the helper declared in
///         GovernanceIncentivizerPairIntegration.t.sol (kept local per test-file convention).
contract UnsafeUninitializedProxy is ERC1967Proxy {
    /// @param implementation Initial implementation address.
    /// @param data Initializer calldata; may be empty for deferred initialization.
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}

    /// @notice Permit an uninitialized deployment so the paired contract can be wired in a later call.
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

/// @title YieldDispatcherUAssetEoaBranchTest
/// @notice Anchors the UASSET×EOA-receiver terminal classes of the dispatcher's EOA burn branch:
///         the revert-pin class (a uAsset whose `burn` reverts → the whole settle call
///         reverts, queue pinned, no convergence signal) and the silent false-report class (a uAsset whose `burn`
///         is an empty no-op → settle "succeeds" with burnedAtDispatcher=true while nothing moves). Both classes are
///         documented in operations.md §3.13 (结算失败类 (b) / fallback 吸收类) but previously had zero test
///         anchoring: every existing EOA-burn test drives MEMECOIN frames, so the UASSET branch of
///         `_settle`'s `receiver.code.length == 0` path was untested for both terminal classes.
contract YieldDispatcherUAssetEoaBranchTest is ComposerEndpointFixture {
    address internal constant LAUNCHER = address(0x2222);
    address internal constant ALICE = address(0xA11CE);

    YieldDispatcher internal dispatcher;
    MockDispatcherComposeToken internal token;
    MockMessagingComposerEndpoint internal endpoint;

    /// @notice Set up.
    function setUp() external {
        dispatcher = new YieldDispatcher(LOCAL_ENDPOINT, LAUNCHER);
        token = new MockDispatcherComposeToken("Compose Token", "CMP");
        // Etch the shared endpoint mock runtime onto the LOCAL_ENDPOINT address so the dispatcher's `localEndpoint`
        // immutable points at a controllable endpoint mock (the immutable is fixed to LOCAL_ENDPOINT at construction time).
        endpoint = _etchComposer();
    }

    /// @notice A UASSET frame naming an EOA receiver whose token's `burn` reverts pins the queue on BOTH entries:
    ///         the whole lzCompose reverts (the CEI Settled write rolls back) and the whole settlePendingCompose
    ///         reverts (the Released write rolls back), so the guid stays `None`, the funds stay stranded, and the
    ///         endpoint queue keeps its delivery hash (pinned by a direct slot assert) — no convergence signal for
    ///         the endpoint state machine.
    /// @dev UASSET×EOA is the missing half of the EOA-burn revert-pin coverage: the existing burn-revert tests
    ///      (testLzComposeAllowsRetryAfterFailedBurnAndBlocksReplayAfterSuccess and its settle mirror) drive
    ///      MEMECOIN frames, and the UASSET EOA branch reaches the same `IBurnable(token).burn(amount)` call only
    ///      because the tokenType does not select the contract path. This is the operations.md §3.13 结算失败类 (b)
    ///      class: the uAsset's burn reverts (owner-only/absent burn), the settle-fail rollback-retry contract
    ///      applies, and the guid must stay resolvable for the documented retry.
    function testUAssetEoaReceiverBurnRevertPinsQueueOnBothEntries() external {
        bytes32 guid = bytes32("uasset-burn-revert");
        uint256 amount = 5 ether;
        token.setBurnShouldRevert(true);
        token.mint(address(dispatcher), amount);

        // ALICE is an EOA (no code), so `_settle` takes the burn branch; the token's burn reverts "settle failed".
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.UASSET);

        // The compose was delivered before execution: the endpoint queue holds the delivery hash (as the real
        // composer writes it on delivery), so the failed run must leave it intact — no RECEIVED convergence.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));

        // lzCompose entry: the whole call reverts, rolling back the CEI Settled write — the guid stays None.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("settle failed");
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        // Funds stranded: no burn happened and no convergence signal was emitted.
        assertEq(token.balanceOf(address(dispatcher)), amount);
        // Endpoint queue keeps its delivery hash: no RECEIVED convergence signal for the state machine.
        assertEq(endpoint.composeQueue(address(token), address(dispatcher), guid, 0), keccak256(message));

        // settlePendingCompose entry: delivered-but-pending, same revert, Released write rolled back.
        endpoint.setQueue(address(token), address(dispatcher), guid, 0, keccak256(message));
        vm.expectRevert("settle failed");
        dispatcher.settlePendingCompose(address(token), guid, message);

        assertEq(uint256(dispatcher.composeStates(address(token), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(token.balanceOf(address(dispatcher)), amount);
    }

    /// @notice A UASSET frame naming an EOA receiver whose token's `burn` is an empty no-op silently "succeeds":
    ///         the dispatcher emits burnedAtDispatcher=true (a false report — nothing was destroyed) and resolves the slot,
    ///         while the token balance never moves.
    /// @dev UASSET×EOA is the missing half of the silent false-report coverage: the existing EOA-burn success tests
    ///      all drive MEMECOIN frames against MockDispatcherComposeToken's real `_burn`. This is the operations.md
    ///      §3.13 fallback 吸收类 class: a token whose burn absorbs the call (空实现 burn) makes the dispatcher's
    ///      burnedAtDispatcher flag a false report — the funds are neither destroyed nor credited to the receiver, and the
    ///      mutex write converges the endpoint as if settlement succeeded. A mint anchors the zero-movement
    ///      assertion: the dispatcher holds the full minted balance, and the no-op burn still succeeds regardless
    ///      of balance — so the false-report terminal class is proven by unchanged balance and totalSupply rather
    ///      than by the absence of funds.
    function testUAssetEoaReceiverNoOpBurnSilentlySucceedsWithIsBurnedTrue() external {
        NoOpBurnToken noOpToken = new NoOpBurnToken("No Op Token", "NOP");

        // lzCompose entry: silent success with burnedAtDispatcher=true, zero balance movement.
        bytes32 guid = bytes32("uasset-noop");
        uint256 amount = 5 ether;
        // Anchor the zero-movement claim: the dispatcher holds the full minted balance, so the no-op burn must
        // leave both the balance and the total supply untouched to be detected.
        noOpToken.mint(address(dispatcher), amount);
        bytes memory message = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.UASSET);

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.OFTProcessed(
            guid, address(noOpToken), IMemeverseOFTEnum.TokenType.UASSET, ALICE, amount, true
        );
        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(noOpToken), guid, message, address(0), "");

        assertEq(
            uint256(dispatcher.composeStates(address(noOpToken), guid)), uint256(IComposeState.ComposeState.Settled)
        );
        // Zero movement: the no-op burn absorbed the call — balance and total supply are unchanged.
        assertEq(noOpToken.balanceOf(address(dispatcher)), amount);
        assertEq(noOpToken.totalSupply(), amount);

        // settlePendingCompose entry with a second guid: same silent false-report terminal class.
        bytes32 guid2 = bytes32("uasset-noop-settle");
        bytes memory message2 = _dispatcherMessage(amount, ALICE, ALICE, IMemeverseOFTEnum.TokenType.UASSET);
        endpoint.setQueue(address(noOpToken), address(dispatcher), guid2, 0, keccak256(message2));

        vm.expectEmit(true, true, true, true);
        emit IYieldDispatcher.ComposeSettled(
            guid2, address(noOpToken), ALICE, IMemeverseOFTEnum.TokenType.UASSET, amount, true
        );
        dispatcher.settlePendingCompose(address(noOpToken), guid2, message2);

        assertEq(
            uint256(dispatcher.composeStates(address(noOpToken), guid2)), uint256(IComposeState.ComposeState.Released)
        );
        // Same zero-movement pin on the settle entry: balance and total supply unchanged.
        assertEq(noOpToken.balanceOf(address(dispatcher)), amount);
        assertEq(noOpToken.totalSupply(), amount);
    }
}

/// @notice Builds the dispatcher compose message: the OFT envelope (srcEid 101) wrapping the 64-byte
///         `(receiver, tokenType)` payload, with the compose-from word. Every clean-payload call site across this
///         file's test contracts shares this schema, so a payload change touches only this helper; the E2E
///         wire-format rebuild and the malformed-frame tests hand-build their payloads on purpose.
function _dispatcherMessage(
    uint256 amount,
    address composeFrom,
    address receiver,
    IMemeverseOFTEnum.TokenType tokenType
) pure returns (bytes memory) {
    return OFTComposeMsgCodec.encode(
        1,
        101,
        amount,
        abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(composeFrom), abi.encode(receiver, tokenType))
    );
}
