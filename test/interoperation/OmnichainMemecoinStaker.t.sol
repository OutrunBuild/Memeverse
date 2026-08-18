// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {OFTComposeSettleVerify} from "../../src/common/omnichain/OFTComposeSettleVerify.sol";
import {IOmnichainMemecoinStaker} from "../../src/interoperation/interfaces/IOmnichainMemecoinStaker.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {IMemecoinYieldVault} from "../../src/yield/interfaces/IMemecoinYieldVault.sol";
import {OmnichainMemecoinStakerUpgradeable} from "../../src/interoperation/OmnichainMemecoinStakerUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OutrunOwnable} from "../../src/common/access/OutrunOwnable.sol";
import {OmnichainMemecoinStakerUpgradeableV2} from "../mocks/upgrade/OmnichainMemecoinStakerUpgradeableV2.sol";
import {
    AttackStakerToken,
    ERC20InvalidReceiver,
    MockInteroperationYieldVault,
    MockStakerComposeToken,
    MockStakerYieldVault,
    ReentrantStakerVault,
    RevertingAssetVault
} from "../mocks/interoperation/InteroperationMocks.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {ComposerEndpointFixture} from "../mocks/infrastructure/ComposerEndpointFixture.sol";

/// @notice A malicious memecoin that reenters `settlePendingCompose` from inside `_transferOut`'s token transfer.
/// @dev `_transferOut` (TokenHelper.sol) calls `IERC20(token).safeTransfer`, which invokes this token's `transfer`.
///      Because `_transferOut` carries the `nonReentrant` modifier, a reentry into another `_transferOut` (via
///      `settlePendingCompose`) must revert `ReentrancyGuardReentrantCall`. This pins the defense-in-depth lock as a
///      regression guard: if the `composeStates` mutex or CEI order were ever removed, this test catches it.
contract ReentrantMemecoin {
    OmnichainMemecoinStakerUpgradeable internal immutable staker;
    // The reentry target: a different guid (pre-seeded in the queue) so the reentrant call passes the mutex/proof
    // checks and reaches `_transferOut`, where the `nonReentrant` lock (held by the outer `_transferOut`) fires.
    bytes32 internal reentryGuid;
    bytes internal reentryMessage;

    constructor(OmnichainMemecoinStakerUpgradeable staker_) {
        staker = staker_;
    }

    /// @notice Arm the reentry attempt. The guid/message must be a valid, deliverable settle target.
    function armReentry(bytes32 guid_, bytes memory message_) external {
        reentryGuid = guid_;
        reentryMessage = message_;
    }

    /// @notice The `_transferOut` external call. Triggers the reentrant `settlePendingCompose` mid-transfer.
    function transfer(address, uint256) external returns (bool) {
        // Reenter via the settle entry with the armed (different) guid. The outer `_transferOut` still holds the
        // `nonReentrant` lock, so the reentrant call reverts `ReentrancyGuardReentrantCall` at the second `_transferOut`.
        staker.settlePendingCompose(address(this), reentryGuid, reentryMessage);
        return true;
    }
}

contract OmnichainMemecoinStakerTest is ComposerEndpointFixture {
    address internal constant RECEIVER = address(0xBEEF);

    OmnichainMemecoinStakerUpgradeable internal staker;
    MockStakerComposeToken internal memecoin;
    MockStakerYieldVault internal yieldVault;
    MockMessagingComposerEndpoint internal endpoint;

    /// @notice Set up.
    /// @dev The staker is deployed through the shared fixture helper (production UUPS shape, mirroring the
    ///      script's `_deployOmnichainMemecoinStaker`); owner = this test contract, endpoint = the fixed
    ///      LOCAL_ENDPOINT.
    function setUp() external {
        staker = _deployStaker(address(this), LOCAL_ENDPOINT);
        memecoin = new MockStakerComposeToken();
        yieldVault = new MockStakerYieldVault(address(memecoin));

        // Etch the MessagingComposer surface onto the fixed LOCAL_ENDPOINT so production calls against
        // `localEndpoint` (lzCompose's msg.sender check and settlePendingCompose's composeQueue read) resolve to the mock.
        endpoint = _etchComposer();
    }

    /// @notice Test initialize rejects zero local endpoint.
    /// @dev initialize runs inside the ERC1967Proxy constructor, so the reverting initializer fails the
    ///      proxy deploy itself. This deploy deliberately bypasses `_deployStaker`: the expectRevert must
    ///      wrap the proxy CREATE directly — the helper's impl `new` would run first and match the
    ///      expectation against a creation that cannot revert.
    function testInitializeRejectsZeroLocalEndpoint() external {
        OmnichainMemecoinStakerUpgradeable implementation = new OmnichainMemecoinStakerUpgradeable();

        vm.expectRevert(IOmnichainMemecoinStaker.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(OmnichainMemecoinStakerUpgradeable.initialize, (address(this), address(0)))
        );
    }

    /// @notice Test initialize cannot run twice on the proxy (OZ initializer guard).
    function testInitializeCannotBeReRunOnTheProxy() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        staker.initialize(address(this), LOCAL_ENDPOINT);
    }

    /// @notice Test owner-upgraded V2 shell keeps the composeStates mutex and localEndpoint storage intact.
    /// @dev The V2 shell (test/mocks/upgrade) has no getters, so post-upgrade state is proven by raw
    ///      `vm.load` reads on the erc7201("outrun.storage.OmnichainMemecoinStaker") namespace. The
    ///      pre-upgrade `vm.load` assertions double as a self-check of the slot math: a wrong base slot or
    ///      nested-mapping formula would fail them before the upgrade ever runs.
    function testUpgradeToV2ShellPreservesComposeStateStorage() external {
        // Known state: a settled compose mutex entry plus the initializer's localEndpoint pointer.
        bytes32 guid = bytes32("upgrade-preserve");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);
        // Vault word names an undeployed address so the fallback branch settles without a vault fixture.
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(0x1234));
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));

        // ERC-7201 base slot: keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(uint256(0xff)).
        // localEndpoint is field 0; composeStates is the nested mapping at field 1, so the (memecoin, guid)
        // entry sits at keccak256(abi.encode(guid, keccak256(abi.encode(memecoin, base + 1)))).
        bytes32 baseSlot = _stakerStorageBaseSlot();
        assertEq(vm.load(address(staker), baseSlot), bytes32(uint256(uint160(LOCAL_ENDPOINT))));
        bytes32 composeSlot =
            keccak256(abi.encode(guid, keccak256(abi.encode(address(memecoin), bytes32(uint256(baseSlot) + 1)))));
        assertEq(vm.load(address(staker), composeSlot), bytes32(uint256(IComposeState.ComposeState.Settled)));

        // Capture the observed words: the post-upgrade assertions compare against these captures, so the
        // endpoint/state derivations stay maintained exactly once, in the pre-upgrade block above.
        bytes32 localEndpointSlotValue = vm.load(address(staker), baseSlot);
        bytes32 composeStateSlotValue = vm.load(address(staker), composeSlot);

        // Owner (= this test contract) upgrades to the bare shell; V1's plain onlyOwner guard runs.
        OmnichainMemecoinStakerUpgradeableV2 shell = new OmnichainMemecoinStakerUpgradeableV2();
        staker.upgradeToAndCall(address(shell), "");

        assertEq(OmnichainMemecoinStakerUpgradeableV2(address(staker)).upgradeVersion(), 2);
        // Storage preserved: post-upgrade slots equal the captured pre-upgrade words.
        assertEq(vm.load(address(staker), baseSlot), localEndpointSlotValue);
        assertEq(vm.load(address(staker), composeSlot), composeStateSlotValue);
    }

    /// @notice Test upgradeToAndCall reverts for a non-owner.
    function testUpgradeToAndCallRevertsForNonOwner() external {
        OmnichainMemecoinStakerUpgradeableV2 shell = new OmnichainMemecoinStakerUpgradeableV2();
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, attacker));
        staker.upgradeToAndCall(address(shell), "");
    }

    /// @notice ERC-7201 base slot of the staker's namespaced storage.
    function _stakerStorageBaseSlot() internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256("outrun.storage.OmnichainMemecoinStaker")) - 1))
            & ~bytes32(uint256(0xff));
    }

    /// @notice Test lz compose rejects unauthorized caller and replayed guid.
    function testLzComposeRejectsUnauthorizedCallerAndAlreadyResolvedGuid() external {
        vm.expectRevert(IOmnichainMemecoinStaker.PermissionDenied.selector);
        staker.lzCompose(address(memecoin), bytes32(0), "", LOCAL_ENDPOINT, "");

        bytes32 guid = bytes32("done");
        memecoin.mint(address(staker), 1 ether);
        bytes memory message = _stakeMessage(1 ether, RECEIVER, RECEIVER, address(yieldVault));

        // First lzCompose resolves the guid to Settled.
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // A replayed lzCompose for the same guid must revert (single-resolution mutex).
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");
    }

    /// @notice Test lz compose deposits into yield vault when vault exists.
    function testLzComposeDepositsIntoYieldVaultWhenVaultExists() external {
        bytes32 guid = bytes32("stake");
        memecoin.mint(address(staker), 3 ether);
        bytes memory message = _stakeMessage(3 ether, RECEIVER, RECEIVER, address(yieldVault));

        // Contract vault targets should receive the full compose amount and the guid becomes Settled.
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), RECEIVER, 3 ether
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        assertEq(yieldVault.lastDepositAmount(), 3 ether);
        assertEq(yieldVault.lastDepositReceiver(), RECEIVER);
        // The vault's deposit pulled the tokens from the staker: funds moved, nothing stranded.
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(memecoin.balanceOf(address(yieldVault)), 3 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
        // Exact approval invariant: the per-deposit allowance was consumed by the single pull, no residual.
        // Guards against vault pull drift (rounded-down / partial pull) leaving a residual allowance that
        // a later forged compose frame could amplify. Parallels YieldDispatcher.t.sol's allowance==0 check.
        assertEq(memecoin.allowance(address(staker), address(yieldVault)), 0);
    }

    /// @notice Test lz compose settles receiver when vault is eoa.
    function testLzComposeSettlesReceiverWhenVaultIsEoa() external {
        bytes32 guid = bytes32("compose");
        memecoin.mint(address(staker), 2 ether);
        bytes memory message = _stakeMessage(2 ether, RECEIVER, RECEIVER, address(0x1234));

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0x1234), RECEIVER, 2 ether
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        assertEq(memecoin.balanceOf(RECEIVER), 2 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice Test lz compose ignores executor and native value when settling the receiver.
    function testLzComposeIgnoresExecutorAndNativeValueWhenSettlingReceiver() external {
        bytes32 guid = bytes32("value");
        memecoin.mint(address(staker), 5 ether);
        bytes memory message = _stakeMessage(2 ether, RECEIVER, RECEIVER, address(0x1234));

        vm.deal(LOCAL_ENDPOINT, 1 wei);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0x1234), RECEIVER, 2 ether
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose{value: 1 wei}(address(memecoin), guid, message, address(0xCAFE), hex"1234");

        assertEq(memecoin.balanceOf(RECEIVER), 2 ether);
        assertEq(memecoin.balanceOf(address(staker)), 3 ether);
        assertEq(address(staker).balance, 1 wei);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice Test failed deposits do not consume the guid and replays are blocked after success.
    function testLzComposeAllowsRetryAfterFailedDepositAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("retry");
        memecoin.mint(address(staker), 4 ether);
        bytes memory message = _stakeMessage(4 ether, RECEIVER, RECEIVER, address(yieldVault));

        yieldVault.setShouldRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("deposit failed");
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");

        // The failed call reverted, rolling back the Settled write, so the guid is still resolvable.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(yieldVault.lastDepositAmount(), 0);
        // The failed deposit pulled nothing (the whole call reverted, approval rollback included).
        assertEq(memecoin.balanceOf(address(staker)), 4 ether);
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);

        yieldVault.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), RECEIVER, 4 ether
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");

        assertEq(yieldVault.lastDepositAmount(), 4 ether);
        assertEq(yieldVault.lastDepositReceiver(), RECEIVER);
        // The successful deposit pulled the tokens from the staker into the vault.
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(memecoin.balanceOf(address(yieldVault)), 4 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");
    }

    /// @notice A non-zero deposit whose vault returns 0 shares WITHOUT reverting (a drift variant of the real
    ///         vault, which reverts ZeroSharesDeposit instead) must revert the whole lzCompose: the staker's
    ///         amount-gated deposit return-value guard fires so the CEI Settled write rolls back, the guid stays
    ///         None, and the beneficiary can still recover via settlePendingCompose — a silent settle would leave
    ///         the slot Settled with no shares minted and no recovery exit.
    /// @dev The mock's drift switch pulls the assets then returns 0 shares for a non-zero amount without
    ///      reverting, exercising the guard itself (the real vault reverts before the guard is reached). The
    ///      guard is amount-gated (`amount == 0 || shares != 0`), so the zero-amount convergence tests stay
    ///      unaffected. The settle recovery plants the delivery proof via setQueue because this suite drives the
    ///      staker directly (no composer write on the direct-call path).
    function testLzComposeDepositReturningZeroSharesForNonZeroRevertsAndStaysSettlable() external {
        bytes32 guid = bytes32("zero-shares-drift");
        memecoin.mint(address(staker), 4 ether);
        bytes memory message = _stakeMessage(4 ether, RECEIVER, RECEIVER, address(yieldVault));

        yieldVault.setReturnZeroSharesForNonZero(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IMemecoinYieldVault.ZeroSharesDeposit.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");

        // The atomic revert rolled back the CEI Settled write and the drift pull: the guid stays None, the
        // staker still holds the full amount, and the vault holds nothing.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), 4 ether);
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);
        assertEq(
            memecoin.allowance(address(staker), address(yieldVault)), 0, "approve rolled back with the guard revert"
        );

        // The beneficiary still recovers the stuck funds once the drift is cleared: settle pushes the amount
        // via `_transferOut` and never touches the vault.
        yieldVault.setReturnZeroSharesForNonZero(false);
        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));
        vm.prank(RECEIVER);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
        assertEq(memecoin.balanceOf(RECEIVER), 4 ether);
        assertEq(memecoin.balanceOf(address(staker)), 0);
    }

    /// @notice lz compose reverts with a named `MalformedComposeMsg` error when the composeMsg is not exactly 64 bytes,
    ///         instead of letting `abi.decode` revert opaquely. The 4-byte inner composeMsg here is shorter than one
    ///         32-byte word, so it is unrecoverable on BOTH entrypoints: lzCompose's `== 64` guard and settle's
    ///         `>= 32` guard both reject it. The CEI `Settled` write rolls back, so the guid stays `None` and the funds
    ///         stay stranded in staker custody (self-harm boundary). The symmetric settle test
    ///         below (`testSettlePendingComposeRevertsOnMalformedComposeMessageBeforeAuth`) uses the same 4-byte frame
    ///         and asserts settle also reverts — pinning the unrecoverable boundary. (Frames with inner composeMsg in
    ///         the [32,64)-byte band ARE settle-recoverable; see
    ///         `testSettlePendingComposeReleasesMalformedNon64PayloadToBeneficiary`.)
    function testLzComposeRevertsOnMalformedComposeMessage() external {
        bytes32 guid = bytes32("malformed");
        memecoin.mint(address(staker), 1 ether);

        // The OFT compose message carries a 32-byte `composeFrom` prefix before the inner composeMsg; a real
        // delivery always has the full 76-byte header so `composeMsg()` (slices `[76:]`) never goes out of bounds.
        // The inner composeMsg here is 4 bytes, not the 64-byte `(address, address)` schema, so the bounds check
        // fires `MalformedComposeMsg`.
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 101, 1 ether, abi.encodePacked(bytes32(uint256(uint160(RECEIVER))), hex"deadbeef")
        );

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The atomic revert rolled back the CEI `Settled` write, so the guid stays `None`. The same 4-byte frame also
        // reverts on `settlePendingCompose` (`>= 32` guard, see the symmetric test below), so the funds are permanently
        // stranded — a documented self-harm boundary, not a recoverable state.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice lzCompose reverts with a named `MalformedComposeMsg` when the frame is shorter than the 76-byte compose
    ///         header, instead of letting the `composeMsg` codec slice (`[76:]`) revert with an opaque bare revert.
    ///         The CEI `Settled` write rolls back, so the guid stays `None`.
    /// @dev A 48-byte frame has the 44-byte amountLD region readable but no `composeFrom` word: `amountLD` ([12:44])
    ///      succeeds, then `composeMsg` ([76:]) is out of bounds. The pre-guard fires `MalformedComposeMsg` first.
    function testLzComposeRevertsOnShortFrameBeforeHeaderComplete() external {
        bytes32 guid = bytes32("short-frame");
        memecoin.mint(address(staker), 1 ether);

        // encode = nonce(8) + srcEid(4) + amountLD(32) + "deadbeef"(4) = 48 bytes total (< 76, header incomplete).
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, hex"deadbeef");

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The atomic revert rolled back the CEI `Settled` write, so the guid is still `None`.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice lzCompose reverts with a named `MalformedComposeMsg` when the frame is shorter than the 76-byte compose
    ///         header: the `>= 76` header-integrity guard fires before any codec slice can run. This variant's frame
    ///         is shorter than even the 44-byte amountLD region (extreme short edge); the [44, 76) band is covered by
    ///         `testLzComposeRevertsOnShortFrameBeforeHeaderComplete`. The CEI `Settled` write rolls back, so the guid
    ///         stays `None`.
    /// @dev `OFTComposeMsgCodec.encode` cannot produce a frame shorter than 44 bytes (its header alone is 44), so the
    ///      frame is hand-built. The guard checks length only, so the byte content is irrelevant.
    function testLzComposeRevertsOnFrameShorterThanAmountLDOffset() external {
        bytes32 guid = bytes32("sub-amountLD");
        // Hand-built 20-byte frame: shorter than the 76-byte header, so the `>= 76` header-integrity guard fires the
        // named error first; it is also shorter than the 44-byte amountLD end offset, so `amountLD` ([12:44]) would
        // slice out of bounds only if that guard were removed. Any 20-byte content exercises the length-only guard.
        bytes memory shortMessage = new bytes(20);
        for (uint256 i = 0; i < 20; i++) {
            shortMessage[i] = bytes1("x");
        }

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.lzCompose(address(memecoin), guid, shortMessage, address(0), "");

        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice lzCompose consumes a 64-byte compose payload whose receiver word carries dirty high bits instead of
    ///         releasing to a forged address: the slot resolves to Settled with NO settlement and no funds moved.
    /// @dev The strict ABI decoder rejects an address word with non-zero high bits, so decoding as (address, address)
    ///      would revert with an EMPTY unreadable revert and pin the endpoint queue forever; the uint256 decode skips
    ///      that validator and the explicit `receiverRaw >> 160` check consumes the slot with `ComposeRejected`
    ///      instead. The receiver slot is the first word of the encoded tuple (message[76:108]); `abi.encode` would
    ///      mask the dirty bits, so the tuple is hand-encoded word by word with bit 160 set (the lowest bit of the
    ///      high 96
    ///      bits) in the receiver slot. Mirrors the dispatcher's `testLzComposeConsumesDirtyHighBitsReceiver`.
    function testLzComposeConsumesDirtyHighBitsReceiver() external {
        bytes32 guid = bytes32("dirty-receiver");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // composeFrom(RECEIVER) + hand-encoded (RECEIVER-with-dirty-high-bits, yieldVault) — bit 160 makes
        // receiverRaw >> 160 != 0, so the payload can never be released (settle rejects the same word).
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))), // compose-from word (skipped by the decode)
                bytes32(uint256(uint160(RECEIVER)) | (1 << 160)), // receiver word: dirty high bits
                bytes32(uint256(uint160(address(yieldVault)))) // vault word: clean
            )
        );

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(memecoin), amount);
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled) and the funds never moved.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(RECEIVER), 0);
    }

    /// @notice A 64-byte compose payload whose vault word carries dirty high bits has no readable vault target, so
    ///         lzCompose treats it as vault-absent and releases the bridged memecoin directly to the receiver via the
    ///         fallback branch (yieldVault reported as address(0) in the event).
    /// @dev The strict ABI decoder would reject the dirty vault word with an empty revert and pin the endpoint queue;
    ///      the uint256 decode skips that validator and `vaultRaw >> 160 != 0` reads as vault-absent, so the existing
    ///      fallback branch releases to the receiver instead of trapping the funds. The tuple is hand-encoded word by
    ///      word (`abi.encode` would mask the dirty bits) with bit 200 set above the clean vault address.
    function testLzComposeReleasesToReceiverWhenVaultWordDirty() external {
        bytes32 guid = bytes32("dirty-vault");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);

        // composeFrom(RECEIVER) + hand-encoded (RECEIVER, yieldVault-with-dirty-high-bits) — bit 200 makes
        // vaultRaw >> 160 != 0, so the vault is treated as absent.
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))), // compose-from word (skipped by the decode)
                bytes32(uint256(uint160(RECEIVER))), // receiver word: clean
                bytes32(uint256(uint160(address(yieldVault))) | (1 << 200)) // vault word: dirty high bits
            )
        );

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0), RECEIVER, amount
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // Released to the receiver via the vault-absent fallback: funds moved to the receiver, nothing stranded.
        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A 64-byte compose payload whose receiver AND vault words both carry dirty high bits is consumed by the
    ///         receiver-dirty branch: the receiver check (`receiverRaw >> 160 != 0`) precedes the vault derivation, so
    ///         the frame is rejected with `ComposeRejected` regardless of the vault word — no settlement, no funds
    ///         moved, slot Settled.
    /// @dev Pins the branch ORDER: if a refactor ever swapped the checks (vault-absent fallback before the receiver
    ///      rejection), this payload would silently release to the receiver instead of being consumed as rejected.
    function testLzComposeConsumesDirtyHighBitsReceiverAndVault() external {
        bytes32 guid = bytes32("dirty-both");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // composeFrom(RECEIVER) + hand-encoded (RECEIVER-with-dirty-high-bits, yieldVault-with-dirty-high-bits) —
        // bit 160 fires the receiver rejection before the dirty vault word (bit 200) is ever read.
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))), // compose-from word (skipped by the decode)
                bytes32(uint256(uint160(RECEIVER)) | (1 << 160)), // receiver word: dirty high bits
                bytes32(uint256(uint160(address(yieldVault))) | (1 << 200)) // vault word: dirty high bits
            )
        );

        vm.expectEmit(true, true, true, true);
        emit IComposeState.ComposeRejected(guid, address(memecoin), amount);
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // Consumed with NO settlement: the mutex is terminal (Settled) and the funds never moved.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(RECEIVER), 0);
    }

    /// @notice A 64-byte compose payload with a clean zero receiver word and a dirty vault word maps to a vault-absent
    ///         fallback targeting address(0): the memecoin's zero-address guard reverts, rolling back the CEI Settled
    ///         write, so the slot stays pinned at None (receiver==0 self-harm boundary).
    /// @dev The zero receiver word passes `receiverRaw >> 160 == 0` and the dirty vault word reads as vault-absent, so
    ///      `_transferOut(memecoin, address(0), amount)` hits the token's zero-address guard. The mock mirrors the
    ///      real memecoin's `ERC20InvalidReceiver(address(0))` guard (OutrunERC20Init._transfer); solmate's bare
    ///      ERC20 has no such check, so this boundary is fixture-enforced.
    function testLzComposeZeroReceiverDirtyVaultKeepsPinnedBoundary() external {
        bytes32 guid = bytes32("zero-receiver-dirty-vault");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // composeFrom(RECEIVER) + hand-encoded (address(0), yieldVault-with-dirty-high-bits) — the zero receiver word
        // is clean (passes the high-bits check) and the dirty vault word (bit 200) maps to vault-absent.
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))), // compose-from word (skipped by the decode)
                bytes32(0), // receiver word: clean zero
                bytes32(uint256(uint160(address(yieldVault))) | (1 << 200)) // vault word: dirty high bits
            )
        );

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The atomic revert rolled back the CEI Settled write: the guid stays None (pinned) and the funds never left
        // staker custody.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(address(0)), 0);
    }

    /// @notice A non-zero-amount lzCompose whose receiver is address(0) and whose predicted vault IS deployed reverts
    ///         in the deposit branch: the vault's `_mint` zero-account guard (`ERC20InvalidReceiver`) rolls back the
    ///         CEI `Settled` write, pinning the guid to `None` (receiver==0 boundary, amount>0
    ///         sub-class). Complements `testLzComposeZeroReceiverDirtyVaultKeepsPinnedBoundary` (fallback branch).
    /// @dev Requires the mock vault's receiver guard (mirrors the real `_mint` guard): without it the mock silently
    ///      succeeds with the opposite terminal state.
    function testLzComposeZeroReceiverDeployedVaultKeepsPinnedBoundary() external {
        bytes32 guid = bytes32("zero-receiver-deployed-vault");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // composeFrom(RECEIVER) + hand-encoded (address(0), yieldVault) — clean zero receiver word (passes the
        // high-bits check) and a clean vault word, so lzCompose takes the deposit branch.
        bytes memory message = _stakeMessage(amount, RECEIVER, address(0), address(yieldVault));

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The atomic revert rolled back the CEI Settled write: the guid stays None (pinned) and the funds never left
        // staker custody (the mock's receiver guard fires before the pull).
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);
    }

    /// @notice settlePendingCompose pushes the bridged memecoin to the receiver when lzCompose never ran.
    function testSettlePendingComposePushesToReceiver() external {
        bytes32 guid = bytes32("compose-stake");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // Only the beneficiary (the receiver decoded from the message) may settle the stuck compose.
        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice settlePendingCompose reverts when the caller is not the beneficiary decoded from `message` (front-run guard).
    function testSettlePendingComposeRevertsWhenNotBeneficiary() external {
        bytes32 guid = bytes32("compose-other");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        vm.prank(address(0xDEAD));
        vm.expectRevert(IOmnichainMemecoinStaker.NotBeneficiary.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // The failed settle consumed nothing: the guid stays releasable by the genuine beneficiary.
        assertEq(memecoin.balanceOf(address(0xDEAD)), 0);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice settlePendingCompose can never release a guid whose encoded receiver is address(0): the
    ///         `msg.sender == receiver` auth (NotBeneficiary) is unsatisfiable because an EVM caller can never be
    ///         address(0). This pins the documented self-harm boundary — a sender who forges receiver=0 strands their
    ///         own funds with no exit, distinct from the dispatcher's receiver=0 burn path.
    /// @dev The protocol sender (`MemeverseOmnichainInteroperation.memecoinStaking`) guards `receiver != address(0)`,
    ///      so this is only reachable via a permissionless direct OFT `send` with a hand-crafted composeMsg (self-harm).
    ///      Every non-zero caller fails the auth identically; no caller can ever be address(0) to satisfy it.
    function testSettlePendingComposeReceiverZeroPermanentlyUnreachable() external {
        bytes32 guid = bytes32("zero-receiver");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Encode receiver = address(0); the compose-from word carries the non-zero source sender (positionally
        // required by the codec) but is never read by the staker's settle decode — the helper's explicit
        // compose-from parameter expresses this frame (composeFrom != receiver) cleanly.
        bytes memory message = _stakeMessage(amount, RECEIVER, address(0), address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // A non-beneficiary caller fails the auth check — same as any non-receiver caller.
        vm.prank(address(0xDEAD));
        vm.expectRevert(IOmnichainMemecoinStaker.NotBeneficiary.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // Even address(0xCAFE) (any non-zero caller) fails: msg.sender can never equal address(0), so the auth is
        // permanently unsatisfiable for a zero-receiver guid.
        vm.prank(address(0xCAFE));
        vm.expectRevert(IOmnichainMemecoinStaker.NotBeneficiary.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // The guid stays unreleasable: no state change, funds still in staker custody, zero exits.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
    }

    /// @notice A forged settle with an attacker-controlled memecoin advances only the attacker's own slot; the real
    ///         (memecoin, guid) mutex stays untouched, so the genuine staking compose remains settleable.
    function testSettlePendingComposeForgedTokenCannotBurnRealGuidMutex() external {
        bytes32 guid = bytes32("real-guid");
        uint256 amount = 3 ether;
        memecoin.mint(address(staker), amount);

        // Real delivery: the OFT writes composeQueue[memecoin][staker][guid][0].
        bytes memory realMessage = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));
        vm.prank(address(memecoin));
        endpoint.sendCompose(address(staker), guid, 0, realMessage);

        // Attacker: 1 wei fake payload whose receiver is the attacker's own contract.
        AttackStakerToken attackToken = new AttackStakerToken();
        bytes memory fakeComposeMsg = abi.encodePacked(
            bytes32(uint256(uint160(address(this)))), abi.encode(address(attackToken), address(attackToken))
        );
        bytes memory fakeMessage = OFTComposeMsgCodec.encode(2, 101, 1 wei, fakeComposeMsg);

        // Attacker writes its own queue slot and settles with its own token (msg.sender == receiver self-satisfies
        // NotBeneficiary): the 1 wei forged settle succeeds for real (the mock's transfer no-ops), resolving the
        // attacker's own slot to Released while leaving the real (memecoin, guid) mutex untouched.
        vm.prank(address(attackToken));
        endpoint.sendCompose(address(staker), guid, 0, fakeMessage);
        vm.prank(address(attackToken));
        staker.settlePendingCompose(address(attackToken), guid, fakeMessage);
        assertEq(
            uint256(staker.composeStates(address(attackToken), guid)), uint256(IComposeState.ComposeState.Released)
        );
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));

        // The real compose still resolves: lzCompose stakes into the vault for the receiver.
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, realMessage, address(0), "");
        assertEq(memecoin.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice settlePendingCompose reverts when the compose guid was never delivered.
    function testSettlePendingComposeRevertsWhenNotDelivered() external {
        bytes32 guid = bytes32("never");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("x"));

        vm.expectRevert(IComposeState.NotDelivered.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice settlePendingCompose reverts on a zero-amount payload instead of pinning the guid to Released.
    function testSettlePendingComposeRevertsOnZeroAmount() external {
        bytes32 guid = bytes32("zero");
        bytes memory message = _stakeMessage(0, RECEIVER, RECEIVER, address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        vm.expectRevert(IOmnichainMemecoinStaker.ZeroInput.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice settlePendingCompose reverts with a named `MalformedComposeMsg` when the inner composeMsg is shorter
    ///         than one 32-byte word (the receiver word is unreadable). The release path accepts >=32 bytes and reads
    ///         only the first word, so anything shorter is unrecoverable. The check runs before the auth check, so even
    ///         the beneficiary cannot release such a payload.
    function testSettlePendingComposeRevertsOnMalformedComposeMessageBeforeAuth() external {
        bytes32 guid = bytes32("malformed-settle");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // 4-byte inner composeMsg (< 32, no readable receiver word); the 32-byte `composeFrom` prefix keeps the
        // message header well-formed so `composeMsg()` slicing stays in bounds, and amount != 0 reaches the guard.
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 101, amount, abi.encodePacked(bytes32(uint256(uint160(RECEIVER))), hex"deadbeef")
        );

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // The beneficiary themselves calls — the >=32-byte shape check fires before the `msg.sender == receiver` auth,
        // so even the rightful caller cannot release a shorter-than-one-word payload.
        vm.prank(RECEIVER);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // Funds stay stranded in the staker; the guid stays `None` (no state change on revert).
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice Release path recovers a self-stranded non-64 payload to the beneficiary: an inner composeMsg of exactly
    ///         one 32-byte word (receiver only, no yieldVault) is accepted because settle only needs the beneficiary.
    ///         Pins the release-shape choice: the release shape guard is `>= 32` (first word = receiver), not `== 64`.
    function testSettlePendingComposeReleasesMalformedNon64PayloadToBeneficiary() external {
        bytes32 guid = bytes32("malformed-recover");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Inner _composeMsg = composeFrom(32) + a single receiver word (32). The codec strips the composeFrom prefix
        // (header region [44:76]), so the inner user composeMsg (message[76:]) is exactly 32 bytes — receiver only,
        // no yieldVault. This is malformed for the entry path (which needs 64 bytes) but recoverable on the release path.
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 101, amount, abi.encodePacked(bytes32(uint256(uint160(RECEIVER))), bytes32(uint256(uint160(RECEIVER))))
        );

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice Release path recovers an oversized (>64 byte) payload: the extra trailing bytes are discarded and only
    ///         the first 32-byte receiver word is used. Pins that the release guard accepts >=32 (not exactly 64).
    function testSettlePendingComposeReleasesOversizedPayloadToBeneficiary() external {
        bytes32 guid = bytes32("oversized-recover");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Inner user composeMsg = receiver(32) + yieldVault(32) + 32 bytes garbage = 96 bytes (>64). The release path
        // reads only the first word as receiver and drops the trailing 64 bytes (yieldVault + garbage).
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))),
                abi.encode(RECEIVER, address(yieldVault)),
                bytes32(uint256(0xBADBEEF))
            )
        );

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice Release path rejects a receiver word whose high 96 bits are non-zero (dirty-high), instead of letting
    ///         `uint160` silently truncate it into a forged address. The payload otherwise satisfies the >=32 guard and
    ///         the `msg.sender == receiver` auth, so only the dirty-high check blocks release.
    /// @dev The first 32-byte word is `0x01 << 160 | RECEIVER`: high 96 bits non-zero, low 160 bits = RECEIVER. A caller
    ///      == RECEIVER exercises the auth, isolating the revert to the dirty-high check.
    function testSettlePendingComposeRevertsOnDirtyHighBitsReceiverWord() external {
        bytes32 guid = bytes32("dirty-high");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Dirty receiver word: high 96 bits set, low 160 bits = RECEIVER. A `uint160` truncation would drop the high
        // bits and forge RECEIVER — the `>> 160 == 0` check rejects it before that.
        bytes32 dirtyReceiverWord = bytes32((uint256(0x01) << 160) | uint256(uint160(RECEIVER)));
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 101, amount, abi.encodePacked(bytes32(uint256(uint160(RECEIVER))), dirtyReceiverWord)
        );

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // The beneficiary themselves calls — the dirty-high check fires before the auth could ever match.
        vm.prank(RECEIVER);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // No state change, funds stay in staker custody.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
    }

    /// @notice settlePendingCompose reverts with a named `MalformedComposeMsg` on a frame shorter than the 76-byte header,
    ///         before the codec slice in `verifySettle` could revert opaquely. Symmetric with the `lzCompose` short-frame guard.
    function testSettlePendingComposeRevertsOnShortFrameBeforeHeaderComplete() external {
        bytes32 guid = bytes32("short-settle");
        uint256 amount = 1 ether;
        memecoin.mint(address(staker), amount);

        // 48-byte frame (< 76, header incomplete) queued via the endpoint so verifySettle's hash proof passes.
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, hex"deadbeef");
        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // The frame-length guard in verifySettle fires `MalformedComposeMsg` before the codec slice runs.
        vm.prank(RECEIVER);
        vm.expectRevert(IComposeState.MalformedComposeMsg.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // Funds stay stranded; the guid stays `None`.
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
    }

    /// @notice settlePendingCompose reverts when the compose guid was already executed via lzCompose (queue holds RECEIVED).
    function testSettlePendingComposeRevertsWhenAlreadyExecuted() external {
        bytes32 guid = bytes32("exec");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("x"));

        endpoint.markReceived(address(memecoin), address(staker), guid, 0);

        vm.expectRevert(IComposeState.AlreadyExecuted.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice settlePendingCompose reverts when the supplied message does not hash to the queued message.
    function testSettlePendingComposeRevertsWhenHashMismatch() external {
        bytes32 guid = bytes32("mismatch");
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, bytes("real"));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(bytes("fake")));

        vm.expectRevert(IComposeState.InvalidProof.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice settlePendingCompose reverts when the guid has already been released once.
    function testSettlePendingComposeRevertsWhenAlreadyResolved() external {
        bytes32 guid = bytes32("twice");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount * 2);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        vm.prank(RECEIVER);
        staker.settlePendingCompose(address(memecoin), guid, message);

        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice After lzCompose's vault-undeployed fallback (_transferOut to receiver) succeeds, settlePendingCompose reverts.
    function testSettlePendingComposeRevertsAfterLzComposeFallbackSucceeded() external {
        bytes32 guid = bytes32("fallback-then-settle");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Vault address is a non-contract, so lzCompose takes the _transferOut(receiver) fallback branch.
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(0x1234));

        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // lzCompose already settled the guid, so a settle must revert as already resolved.
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice A failed settlePendingCompose transfer rolls back the Released write, leaving the guid retryable; a
    ///         successful retry pins Released and a further replay is blocked.
    /// @dev Mirror of testLzComposeAllowsRetryAfterFailedDepositAndBlocksReplayAfterSuccess through the settle entry:
    ///      when the memecoin's transfer reverts, the whole settlePendingCompose rolls back so composeStates returns
    ///      to None and the endpoint queue slot keeps the keccak256(message) delivery proof (retry precondition
    ///      intact); the armed Released probe pins that the Released write precedes the settle external call (CEI
    ///      write order) when the retry succeeds.
    function testSettlePendingComposeAllowsRetryAfterFailedTransferAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("settle-transfer-retry");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // First attempt fails: the memecoin's transfer reverts, and the whole settlePendingCompose rolls back.
        memecoin.setComposeProbeReleased(address(staker), guid);
        memecoin.setTransferRevert(true);
        vm.prank(RECEIVER);
        vm.expectRevert("transfer failed");
        staker.settlePendingCompose(address(memecoin), guid, message);

        // The failed call reverted, rolling back the Released write, so the guid is still resolvable.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(RECEIVER), 0);
        // The failed settle pulled nothing (the whole call reverted, transfer rollback included).
        assertEq(memecoin.balanceOf(address(staker)), amount);
        // The endpoint slot still holds the message hash: the retry precondition (delivery proof) is intact.
        assertEq(endpoint.composeQueue(address(memecoin), address(staker), guid, 0), keccak256(message));

        // Retry succeeds after the failure is cleared: the guid resolves to Released and the funds move to the
        // receiver. The probe stays armed, so the retry callback also asserts the Released write is visible mid-call.
        memecoin.setTransferRevert(false);
        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));

        // A replay after success is blocked by the single-resolution mutex.
        vm.prank(RECEIVER);
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);
    }

    /// @notice Race: settlePendingCompose resolves first, then a late endpoint lzCompose is absorbed as a no-op so the
    ///         endpoint's composeQueue slot converges to the RECEIVED sentinel instead of staying pending forever.
    function testLzComposeAbsorbedAfterSettlePendingCompose() external {
        bytes32 guid = bytes32("race-settle-first");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(0x1234));
        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // settlePendingCompose wins first (only the beneficiary may settle).
        vm.prank(RECEIVER);
        staker.settlePendingCompose(address(memecoin), guid, message);
        uint256 settledToReceiver = memecoin.balanceOf(RECEIVER);

        // A late endpoint lzCompose is absorbed as a no-op: no revert, endpoint slot converges to RECEIVED.
        // Record logs around this absorbed call so we can prove the spec contract below: the Released branch of
        // lzCompose must NOT emit ANY event (the absorb branch is a no-op and emits nothing). The
        // only log in this window is the endpoint's own `ComposeDelivered` (emitted post-forward, mirroring the
        // real MessagingComposer), so the exact-set assertion below catches any composer-side emit — positive,
        // settle, reject, or a future event type — without a hand-written topic0 hash that could drift. Without
        // this closed-world assertion, a future spurious emit on the absorbed path would silently pass and cause
        // downstream consumers to double-account the settlement.
        vm.recordLogs();
        endpoint.lzCompose(address(memecoin), address(staker), guid, 0, message, bytes(""));
        Vm.Log[] memory absorbedLogs = vm.getRecordedLogs();
        assertEq(absorbedLogs.length, 1, "absorbed lzCompose must emit nothing besides the endpoint's ComposeDelivered");
        assertEq(absorbedLogs[0].emitter, address(endpoint), "the sole absorbed log is the endpoint's ComposeDelivered");

        assertEq(
            endpoint.composeQueue(address(memecoin), address(staker), guid, 0),
            OFTComposeSettleVerify.RECEIVED_MESSAGE_HASH
        );
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
        // No double settlement: the beneficiary's balance is unchanged by the late lzCompose no-op.
        assertEq(memecoin.balanceOf(RECEIVER), settledToReceiver);
    }

    /// @notice A failed lzCompose fallback transfer rolls back the Settled write, leaving the guid retryable; a
    ///         successful retry pins Settled and a further replay is blocked.
    /// @dev Mirror of testSettlePendingComposeAllowsRetryAfterFailedTransferAndBlocksReplayAfterSuccess through the
    ///      lzCompose entry: when the predicted vault is undeployed, lzCompose takes the `_transferOut(receiver)`
    ///      fallback branch (not the deposit branch). If that transfer reverts (receiver rejects / balance shortage),
    ///      the whole lzCompose rolls back so composeStates returns to None and the endpoint can retry, then a successful
    ///      retry pins the guid and a further replay reverts. This closes the lzCompose failure-rollback gap for the
    ///      vault-undeployed fallback branch (the deposit branch was already covered by testLzComposeAllowsRetryAfterFailedDeposit...).
    function testLzComposeAllowsRetryAfterFailedFallbackTransferAndBlocksReplayAfterSuccess() external {
        bytes32 guid = bytes32("retry-fallback");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        // Vault address is a non-contract, so lzCompose takes the _transferOut(receiver) fallback branch.
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(0x1234));

        // First attempt fails: the memecoin's transfer reverts, and the whole lzCompose rolls back.
        memecoin.setTransferRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("transfer failed");
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The failed call reverted, rolling back the CEI Settled write, so the guid is still resolvable.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        // The failed transfer moved nothing (the whole call reverted).
        assertEq(memecoin.balanceOf(RECEIVER), 0);
        assertEq(memecoin.balanceOf(address(staker)), amount);

        // Retry succeeds after the failure is cleared: the guid resolves to Settled and the funds reach the receiver.
        memecoin.setTransferRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0x1234), RECEIVER, amount
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));

        // A replay after success is blocked by the single-resolution mutex.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");
    }

    /// @notice A zero-amount lzCompose whose predicted vault is undeployed converges: `_transferOut` early-returns on
    ///         amount 0 (TokenHelper), the CEI Settled write sticks, and no funds move.
    /// @dev Pins the staker's half of the zero-amount convergence contract: unlike the dispatcher, the staker's
    ///      downstream calls never reject amount 0, so a dusted-to-zero delivery resolves cleanly instead of reverting.
    function testLzComposeZeroAmountUndeployedVaultConvergesToSettled() external {
        bytes32 guid = bytes32("zero-undeployed");
        // amountLD = 0; vault is a non-contract so lzCompose takes the _transferOut(receiver) fallback branch.
        bytes memory message = _stakeMessage(0, RECEIVER, RECEIVER, address(0x1234));
        // Fund the staker so the balance assertion is non-vacuous: the zero-amount short-circuit must leave
        // other custody funds (e.g. another user's stranded compose funds) untouched.
        memecoin.mint(address(staker), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0x1234), RECEIVER, 0
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // Settled sticks (CEI write before the no-op transfer); receiver got nothing, staker's pre-funded custody is untouched.
        assertEq(memecoin.balanceOf(RECEIVER), 0);
        assertEq(memecoin.balanceOf(address(staker)), 1 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A zero-amount lzCompose whose predicted vault is deployed converges via the deposit branch: the vault's
    ///         `deposit(0)` records a zero deposit and the CEI Settled write sticks.
    /// @dev Second half of the staker's zero-amount convergence contract. The mock vault mirrors the real
    ///      MemecoinYieldVault's `deposit(0)` early-return only in outcome (no funds move, no shares minted); the real
    ///      vault early-returns at MemecoinYieldVault.sol:168, the mock records amount 0. Both converge, which is
    ///      the contract under test.
    function testLzComposeZeroAmountDeployedVaultConvergesToSettled() external {
        bytes32 guid = bytes32("zero-deployed");
        bytes memory message = _stakeMessage(0, RECEIVER, RECEIVER, address(yieldVault));
        // Fund the staker so the balance assertion is non-vacuous: the zero-amount short-circuit must leave
        // other custody funds untouched.
        memecoin.mint(address(staker), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), RECEIVER, 0
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The vault recorded a zero deposit (convergence), no funds moved, staker's pre-funded custody is untouched,
        // and the guid is terminal.
        assertEq(yieldVault.lastDepositAmount(), 0);
        assertEq(yieldVault.lastDepositReceiver(), RECEIVER);
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);
        assertEq(memecoin.balanceOf(address(staker)), 1 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A zero-amount lzCompose with receiver=address(0) and an undeployed predicted vault CONVERGES: the
    ///         fallback `_transferOut(memecoin, address(0), 0)` early-returns before the token's zero-address guard
    ///         (TokenHelper._transferOut), the CEI Settled write sticks, and no funds move.
    /// @dev Pins the zero-amount x receiver==0 sub-class of the receiver==0 boundary: the unconditional
    ///      "receiver==0 always reverts, never converges" assertion holds only for non-zero amounts.
    function testLzComposeZeroAmountZeroReceiverUndeployedVaultConvergesToSettled() external {
        bytes32 guid = bytes32("zero-amount-zero-recv-undeployed");
        bytes memory message = _stakeMessage(0, RECEIVER, address(0), address(0x1234));
        // Fund the staker so the balance assertion is non-vacuous: the zero-amount short-circuit must leave
        // other custody funds untouched.
        memecoin.mint(address(staker), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(0x1234), address(0), 0
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // Settled sticks (CEI write before the no-op transfer); the zero receiver got nothing, staker's pre-funded
        // custody is untouched.
        assertEq(memecoin.balanceOf(address(0)), 0);
        assertEq(memecoin.balanceOf(address(staker)), 1 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A zero-amount lzCompose with receiver=address(0) and a deployed predicted vault CONVERGES via the
    ///         deposit branch: `deposit(0, address(0))` early-returns before any receiver check (the mock mirrors
    ///         the real vault's `assets == 0` early-return at MemecoinYieldVault.sol:168), the CEI Settled write
    ///         sticks, and no funds move.
    /// @dev Second half of the zero-amount x receiver==0 convergence contract (undeployed half above).
    function testLzComposeZeroAmountZeroReceiverDeployedVaultConvergesToSettled() external {
        bytes32 guid = bytes32("zero-amount-zero-recv-deployed");
        bytes memory message = _stakeMessage(0, RECEIVER, address(0), address(yieldVault));
        // Fund the staker so the balance assertion is non-vacuous: the zero-amount short-circuit must leave
        // other custody funds untouched.
        memecoin.mint(address(staker), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), address(0), 0
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The vault recorded the zero deposit (convergence), no funds moved, staker's pre-funded custody is untouched,
        // and the guid is terminal.
        assertEq(yieldVault.lastDepositAmount(), 0);
        assertEq(yieldVault.lastDepositReceiver(), address(0));
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);
        assertEq(memecoin.balanceOf(address(staker)), 1 ether);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A code-bearing message-named vault that does not implement `asset()` makes the deposit branch's
    ///         binding guard revert with EMPTY data instead of the named `TokenVaultMismatch`: the guard's error
    ///         contract assumes ABI compliance of an arbitrary forged address. The whole lzCompose reverts (CEI
    ///         `Settled` write rolled back, guid back to `None`, endpoint queue pinned), but the beneficiary can
    ///         still recover via `settlePendingCompose` — settle never reads the vault word and always
    ///         `_transferOut` pushes. Pins the "vault has code but asset() is missing" boundary.
    /// @dev The mock is `MockInteroperationYieldVault` (test/mocks): a vault-shaped contract with code and a
    ///      `deposit` entry but no `asset()` selector and no fallback, so the high-level STATICCALL falls to
    ///      solc's empty-data revert path. `vm.expectRevert(bytes(""))` pins the empty revert data — a named
    ///      error (`TokenVaultMismatch` or the callee's own) would fail this expectation, anchoring the
    ///      obscure-failure class the doc row classifies.
    function testLzComposeAssetlessVaultRevertsOpaquelyAndRemainsSettlable() external {
        MockInteroperationYieldVault assetlessVault = new MockInteroperationYieldVault();
        bytes32 guid = bytes32("assetless-vault");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(assetlessVault));

        // The binding guard's asset() call reverts with empty data (no matching selector, no fallback) — the
        // require's `TokenVaultMismatch` error never fires; the whole lzCompose reverts.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(bytes(""));
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // CEI rollback: the Settled write is undone, the guid is back to None, and no funds moved.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(address(assetlessVault)), 0);

        // The beneficiary still recovers the stuck funds: settle ignores the vault word entirely.
        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));
        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice A message-named vault whose `asset()` actively reverts propagates the callee's own error instead of
    ///         `TokenVaultMismatch`: same opaque-failure class as the asset-less vault ("asset() unreadable"
    ///         boundary, revert sub-class) — lzCompose reverts, CEI rollback leaves the guid
    ///         `None`, and the beneficiary recovers via `settlePendingCompose` (which never reads the vault word).
    function testLzComposeRevertingAssetVaultRevertsAndRemainsSettlable() external {
        RevertingAssetVault revertingVault = new RevertingAssetVault();
        bytes32 guid = bytes32("reverting-asset-vault");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(revertingVault));

        // The callee's own revert reason propagates through the binding guard — not TokenVaultMismatch.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("vault asset exploded");
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // CEI rollback: guid back to None, funds still in staker custody.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);

        // Recovery unaffected: the beneficiary settles and receives the funds.
        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));
        vm.prank(RECEIVER);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.StakingComposeSettled(guid, address(memecoin), RECEIVER, amount);
        staker.settlePendingCompose(address(memecoin), guid, message);

        assertEq(memecoin.balanceOf(RECEIVER), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Released));
    }

    /// @notice A zero-amount frame naming a vault whose `asset()` does not match the delivered memecoin reverts
    ///         `TokenVaultMismatch` BEFORE the zero-amount early-return can converge: the binding guard is
    ///         amount-independent and precedes `_safeApprove`/`deposit`, so the CEI `Settled` write rolls back, the
    ///         guid stays `None`, and the endpoint queue does NOT converge. Pins the zero-amount x mismatch
    ///         intersection (the zero-amount convergence rule holds only for `asset() == memecoin` vaults).
    /// @dev Uses a second `MockStakerYieldVault` deployed with a foreign asset address: its `asset()` returns the
    ///      foreign token, so the guard fires the named mismatch error even though the amount is zero.
    function testLzComposeZeroAmountMismatchedVaultRevertsTokenVaultMismatch() external {
        MockStakerYieldVault mismatchedVault = new MockStakerYieldVault(address(0xDEAD));
        bytes32 guid = bytes32("zero-amount-mismatched-vault");
        bytes memory message = _stakeMessage(0, RECEIVER, RECEIVER, address(mismatchedVault));

        // Zero amount does not bypass the binding guard: the mismatch reverts the whole lzCompose.
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IOmnichainMemecoinStaker.TokenVaultMismatch.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // No convergence: the CEI Settled write rolled back and the guid stays None; nothing moved.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(memecoin.balanceOf(address(mismatchedVault)), 0);
    }

    /// @notice settlePendingCompose's `_transferOut` is reentrancy-locked: a malicious memecoin that tries to reenter
    ///         another `settlePendingCompose` mid-transfer must revert `ReentrancyGuardReentrantCall`.
    /// @dev The composeStates mutex alone would NOT catch a reentry with a *different* guid (that slot is still None and
    ///      would pass the mutex). The `nonReentrant` lock on `_transferOut` is the layer that blocks it, and this test
    ///      pins that layer so removing the lock (or the mutex) surfaces as a regression.
    function testSettlePendingComposeRevertsOnReentrantTransferDuringSettle() external {
        // Attacker token: its `transfer` reenters the staker during `_transferOut`.
        ReentrantMemecoin attackerToken = new ReentrantMemecoin(staker);

        // The real (outer) settle: an amount that reaches `_transferOut`. The attacker is its own beneficiary.
        bytes32 outerGuid = bytes32("reentrancy-outer");
        uint256 outerAmount = 1 ether;
        bytes memory outerMessage =
            _stakeMessage(outerAmount, address(attackerToken), address(attackerToken), address(0x1234));
        endpoint.setQueue(address(attackerToken), address(staker), outerGuid, 0, keccak256(outerMessage));

        // The reentry target: a *different* guid (still None), pre-seeded so the reentrant settle passes the mutex and
        // proof checks and actually reaches `_transferOut` (where the lock fires). Same beneficiary self-satisfies auth.
        bytes32 innerGuid = bytes32("reentrancy-inner");
        bytes memory innerMessage =
            _stakeMessage(outerAmount, address(attackerToken), address(attackerToken), address(0x5678));
        endpoint.setQueue(address(attackerToken), address(staker), innerGuid, 0, keccak256(innerMessage));

        attackerToken.armReentry(innerGuid, innerMessage);

        // The outer settle enters `_transferOut` (lock acquired), the malicious token reenters `settlePendingCompose`,
        // which reaches its own `_transferOut` while the lock is still held -> ReentrancyGuardReentrantCall.
        vm.prank(address(attackerToken));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        staker.settlePendingCompose(address(attackerToken), outerGuid, outerMessage);

        // Neither guid was resolved (the whole outer call reverted, rolling back the Released write).
        assertEq(
            uint256(staker.composeStates(address(attackerToken), outerGuid)), uint256(IComposeState.ComposeState.None)
        );
        assertEq(
            uint256(staker.composeStates(address(attackerToken), innerGuid)), uint256(IComposeState.ComposeState.None)
        );
    }

    /// @notice settlePendingCompose can never release a guid whose encoded receiver is the staker itself: the
    ///         `msg.sender == receiver` auth (NotBeneficiary) is unsatisfiable because the staker never self-calls
    ///         settlePendingCompose — like receiver=0, an unsatisfiable beneficiary restriction (an EVM caller can
    ///         never be address(0), and the staker never calls its own settle entrypoint).
    /// @dev The protocol sender guards only `receiver != address(0)`, so a receiver=staker frame is expressible via
    ///      the protocol `memecoinStaking` entry (user-passed param) or a direct OFT `send`. Every caller fails the
    ///      auth identically: no external caller's `msg.sender` equals the staker address.
    function testSettlePendingComposeReceiverStakerPermanentlyUnreachable() external {
        bytes32 guid = bytes32("receiver-staker");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, address(staker), address(staker), address(yieldVault));

        endpoint.setQueue(address(memecoin), address(staker), guid, 0, keccak256(message));

        // A non-beneficiary caller fails the auth check — the staker is the encoded receiver but never calls settle.
        vm.prank(address(0xDEAD));
        vm.expectRevert(IOmnichainMemecoinStaker.NotBeneficiary.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // Any non-staker caller fails identically: msg.sender can never equal the staker, so the auth is permanently
        // unsatisfiable for a receiver==staker guid.
        vm.prank(RECEIVER);
        vm.expectRevert(IOmnichainMemecoinStaker.NotBeneficiary.selector);
        staker.settlePendingCompose(address(memecoin), guid, message);

        // The guid stays unreleasable: no state change, funds still in staker custody, zero exits.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
    }

    /// @notice lzCompose settles a receiver==staker frame through the normal branches instead of consuming it as a
    ///         self-reference: with an undeployed vault word the fallback's self-transfer is a net no-op (funds stay
    ///         in staker custody), and with a deployed vault the deposit stakes into the vault for the staker. Pins
    ///         the post-guard-removal contract so a refactor that re-introduces receiver==staker consumption (or a
    ///         spurious ComposeRejected) surfaces as a regression.
    /// @dev The lzCompose self-reference guard was removed by design (the receiver is sender-chosen; self-harm is
    ///      self-inflicted), so receiver==staker frames must behave exactly like any other frame. Branch 1 uses a
    ///      zero vault word: `_transferOut(memecoin, staker, amount)` is a self-transfer, which the solmate-style
    ///      ERC20 nets to zero (no revert, no balance change). Branch 2 pins the deposit: the mock vault returns
    ///      `shares = amount` for the receiver (mirroring the real vault minting shares to the receiver) but exposes
    ///      no `balanceOf`, so the staker's share credit is pinned via `lastDepositReceiver` and the vault holding
    ///      the pulled amount.
    function testLzComposeReceiverStakerSettlesLikeNormalFrame() external {
        // Branch 1 — vault-absent: zero vault word takes the fallback branch; the self-transfer nets to zero.
        bytes32 fallbackGuid = bytes32("receiver-staker-fallback");
        uint256 fallbackAmount = 2 ether;
        memecoin.mint(address(staker), fallbackAmount);
        bytes memory fallbackMessage = _stakeMessage(fallbackAmount, address(staker), address(staker), address(0));

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            fallbackGuid, address(memecoin), address(0), address(staker), fallbackAmount
        );
        vm.recordLogs();
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), fallbackGuid, fallbackMessage, address(0), "");

        // The frame was processed, not consumed: no ComposeRejected in the emitted logs.
        bytes32 composeRejectedTopic0 = keccak256("ComposeRejected(bytes32,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != composeRejectedTopic0, "receiver==staker frame emitted ComposeRejected");
        }

        // The self-transfer moved nothing: the minted amount stays in staker custody and the slot is terminal.
        assertEq(memecoin.balanceOf(address(staker)), fallbackAmount);
        assertEq(
            uint256(staker.composeStates(address(memecoin), fallbackGuid)), uint256(IComposeState.ComposeState.Settled)
        );

        // Branch 2 — deployed vault: the deposit branch stakes into the real vault for the staker.
        bytes32 vaultGuid = bytes32("receiver-staker-vault");
        uint256 vaultAmount = 3 ether;
        memecoin.mint(address(staker), vaultAmount);
        bytes memory vaultMessage = _stakeMessage(vaultAmount, address(staker), address(staker), address(yieldVault));

        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            vaultGuid, address(memecoin), address(yieldVault), address(staker), vaultAmount
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), vaultGuid, vaultMessage, address(0), "");

        // The vault pulled exactly `vaultAmount` from the staker (balance drops from fallback+vault amounts to the
        // fallback amount) and credited the deposit to the staker (shares == amount in the mock, minted to the
        // receiver by the real vault).
        assertEq(yieldVault.lastDepositAmount(), vaultAmount);
        assertEq(yieldVault.lastDepositReceiver(), address(staker));
        assertEq(memecoin.balanceOf(address(yieldVault)), vaultAmount);
        assertEq(memecoin.balanceOf(address(staker)), fallbackAmount);
        assertEq(
            uint256(staker.composeStates(address(memecoin), vaultGuid)), uint256(IComposeState.ComposeState.Settled)
        );
    }

    /// @notice A receiver==staker frame whose vault deposit reverts rolls back the CEI Settled write, leaving the guid
    ///         retryable; the retry deposits into the vault for the staker and pins Settled.
    /// @dev Mirror of testLzComposeAllowsRetryAfterFailedDepositAndBlocksReplayAfterSuccess for the receiver==staker
    ///      frame (the post-guard-removal contract in testLzComposeReceiverStakerSettlesLikeNormalFrame): the revert
    ///      boundary must behave identically to a normal receiver — the whole lzCompose reverts, the composeStates
    ///      slot stays None, no funds leave staker custody (approval rollback included), and the endpoint retry
    ///      resolves the guid.
    function testLzComposeReceiverStakerDepositRevertRollsBackToNone() external {
        bytes32 guid = bytes32("receiver-staker-deposit-revert");
        uint256 amount = 2 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, address(staker), address(staker), address(yieldVault));

        // First attempt fails: the vault's deposit reverts, and the whole lzCompose rolls back.
        yieldVault.setShouldRevert(true);
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert("deposit failed");
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        // The failed call reverted, rolling back the CEI Settled write, so the guid is still resolvable.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        // The failed deposit pulled nothing (the whole call reverted, approval rollback included).
        assertEq(yieldVault.lastDepositAmount(), 0);
        assertEq(memecoin.balanceOf(address(staker)), amount);
        assertEq(memecoin.balanceOf(address(yieldVault)), 0);

        // Retry succeeds after the failure is cleared: the guid resolves to Settled and the vault pulls the amount
        // from the staker, crediting the deposit to the staker as receiver.
        yieldVault.setShouldRevert(false);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), address(staker), amount
        );
        vm.prank(LOCAL_ENDPOINT);
        staker.lzCompose(address(memecoin), guid, message, address(0), "");

        assertEq(yieldVault.lastDepositAmount(), amount);
        assertEq(yieldVault.lastDepositReceiver(), address(staker));
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(memecoin.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice Builds the staking compose message: the OFT envelope (srcEid 101) wrapping the 64-byte
    ///         `(receiver, vault)` payload, with an explicit compose-from word (the source-chain sender in the real
    ///         wire format, positionally required by the codec but not read by the staker's decode). Every
    ///         clean-payload call site — lzCompose and settlePendingCompose alike — shares this schema, so a payload
    ///         change touches only this helper. The malformed-frame and raw-layout boundary tests stay hand-built.
    function _stakeMessage(uint256 amount, address composeFrom, address receiver, address vault)
        internal
        pure
        returns (bytes memory)
    {
        return OFTComposeMsgCodec.encode(
            1,
            101,
            amount,
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(composeFrom), abi.encode(receiver, vault))
        );
    }

    /// @notice The deposit branch's mid-call Settled probe: `MockStakerYieldVault.deposit` asserts the (token, guid)
    ///         mutex is already `Settled` before its `transferFrom` pull, pinning the lzCompose CEI write order
    ///         (Settled written before the deposit external call). This is the deposit-branch counterpart to the
    ///         dispatcher's `_checkComposeProbes` (YieldDispatcherMockBase.sol): unlike `MockStakerComposeToken`'s
    ///         `setComposeProbeReleased`, which sits on the overridden public `transfer` and is bypassed by solmate's
    ///         `transferFrom`, this probe fires inside `deposit` itself and is reached on every pull path.
    function testLzComposeDepositProbeAssertsSettledVisibleMidCall() external {
        bytes32 guid = bytes32("deposit-probe");
        uint256 amount = 3 ether;
        memecoin.mint(address(staker), amount);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(yieldVault));

        // Arm the probe: the next deposit callback must observe Settled mid-call.
        yieldVault.setComposeProbe(address(staker), guid);

        vm.prank(LOCAL_ENDPOINT);
        vm.expectEmit(true, true, true, true);
        emit IOmnichainMemecoinStaker.OmnichainMemecoinStakingProcessed(
            guid, address(memecoin), address(yieldVault), RECEIVER, amount
        );
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");

        assertEq(yieldVault.lastDepositAmount(), amount);
        assertEq(memecoin.balanceOf(address(staker)), 0);
        assertEq(memecoin.balanceOf(address(yieldVault)), amount);
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
    }

    /// @notice A malicious vault that reenters `settlePendingCompose` with the same guid from inside the deposit
    ///         callback must revert `AlreadyResolved`: the outer `lzCompose` writes `Settled` (CEI) before the deposit
    ///         external call, so the reentrant settle reads `Settled` at its very first guard and reverts. This pins
    ///         the deposit-branch CEI write order as a regression guard — symmetric to
    ///         `testSettlePendingComposeRevertsOnReentrantCallbackDuringSettle` on the dispatcher settle path.
    /// @dev The deposit branch has no `_transferOut`/`nonReentrant`, so the `composeStates` mutex is the sole defense.
    ///      If `Settled` were ever moved after the deposit call, the reentry would read `None`, pass the first guard,
    ///      and reach the hash proof / beneficiary checks — this test would fail, catching the CEI regression.
    function testLzComposeDepositRevertsOnReentrantSettleDuringDeposit() external {
        bytes32 guid = bytes32("deposit-reentrancy");
        uint256 amount = 3 ether;
        memecoin.mint(address(staker), amount);

        // Deploy a malicious vault that reports `asset() == memecoin` (so the binding check passes) and reenters
        // `settlePendingCompose` with the same (memecoin, guid) from inside `deposit`.
        ReentrantStakerVault reentrantVault = new ReentrantStakerVault(staker);
        bytes memory message = _stakeMessage(amount, RECEIVER, RECEIVER, address(reentrantVault));
        reentrantVault.armReentry(address(memecoin), guid, message);

        // The outer lzCompose writes Settled (CEI), then `_safeApprove` + `deposit`; the malicious vault reenters
        // `settlePendingCompose` with the same guid, which reads Settled and reverts `AlreadyResolved` (the mutex
        // defense — no `nonReentrant` is involved on this path).
        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IOmnichainMemecoinStaker.AlreadyResolved.selector);
        staker.lzCompose(address(memecoin), guid, message, address(0xCAFE), "");

        // The whole outer call reverted, so the Settled write rolled back: the guid is still resolvable.
        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.None));
        assertEq(memecoin.balanceOf(address(staker)), amount);
    }
}
