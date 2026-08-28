// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    MessagingFee,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol";
import {OFTMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import {SendParam, OFTReceipt, IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MockOFTEndpoint} from "../../../mocks/common/CommonMocks.sol";
import {OFTHarness} from "../../../mocks/infrastructure/OFTHarness.sol";
import {OutrunOwnable} from "../../../../src/common/access/OutrunOwnable.sol";

error AmountSDOverflowed(uint256 amountSD);

event MsgInspectorSet(address inspector);

contract OutrunOFTInitTest is Test {
    using Clones for address;
    using OFTMsgCodec for bytes;

    address internal constant OWNER = address(0xABCD);
    address internal constant DELEGATE = address(0xCAFE);
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);
    uint32 internal constant DST_EID = 101;

    MockOFTEndpoint internal endpoint;
    OFTHarness internal implementation;
    OFTHarness internal oft;

    /// @notice Set up.
    function setUp() external {
        endpoint = new MockOFTEndpoint();
        implementation = new OFTHarness(address(endpoint));
        oft = OFTHarness(address(implementation).clone());
        oft.initialize(OWNER, "OFT Token", "OFT", DELEGATE);

        vm.prank(OWNER);
        oft.setPeer(DST_EID, bytes32(uint256(uint160(address(0xBEEF)))));
    }

    /// @notice Test initialize sets metadata and token config.
    function testInitializeSetsMetadataAndTokenConfig() external view {
        assertEq(oft.name(), "OFT Token");
        assertEq(oft.symbol(), "OFT");
        assertEq(oft.owner(), OWNER);
        assertEq(oft.token(), address(oft));
        assertFalse(oft.approvalRequired());
        assertEq(oft.sharedDecimals(), 6);
        assertEq(oft.decimalConversionRate(), 1e12);
    }

    /// @notice Test isPeer resolves exactly the configured peer per eid.
    /// @dev Exercises the real `OutrunOFTCoreInit.isPeer` -> `peers` mapping on the initialized clone:
    ///      the configured (eid, peer) pair is trusted, while a different peer value for the configured
    ///      eid and the configured peer under another eid are both untrusted.
    function testIsPeerReflectsConfiguredPeers() external view {
        bytes32 peer = bytes32(uint256(uint160(address(0xBEEF))));
        assertTrue(oft.isPeer(DST_EID, peer), "configured peer must be trusted");
        assertFalse(oft.isPeer(DST_EID, bytes32(uint256(uint160(address(0xCAFE))))), "other peer untrusted");
        assertFalse(oft.isPeer(DST_EID + 1, peer), "unconfigured eid untrusted");
    }

    /// @notice Test quote send and send use peer and burn sender balance.
    function testQuoteSendAndSendUsePeerAndBurnSenderBalance() external {
        endpoint.setQuoteNativeFee(0.2 ether);
        oft.mintTest(address(this), 5 ether);

        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: 5 ether,
            minAmountLD: 0,
            extraOptions: bytes("opts"),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        vm.expectCall(
            address(endpoint),
            abi.encodeWithSelector(
                MockOFTEndpoint.quote.selector,
                MessagingParams({
                    dstEid: DST_EID,
                    receiver: sendParam.to,
                    message: bytes(
                        hex"000000000000000000000000000000000000000000000000000000000000beef00000000004c4b40"
                    ),
                    options: bytes("opts"),
                    payInLzToken: false
                }),
                address(oft)
            )
        );
        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        assertEq(fee.nativeFee, 0.2 ether);

        oft.send{value: 0.2 ether}(sendParam, fee, address(this));
        assertEq(oft.balanceOf(address(this)), 0);
    }

    /// @notice Test quoteSend reverts when the shared-decimal amount exceeds uint64 capacity.
    function testQuoteSendRevertsWhenAmountSDOverflows() external {
        uint256 overflowAmountLD = (uint256(type(uint64).max) + 1) * oft.decimalConversionRate();

        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: overflowAmountLD,
            minAmountLD: 0,
            extraOptions: bytes("opts"),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        vm.expectRevert(abi.encodeWithSelector(AmountSDOverflowed.selector, uint256(type(uint64).max) + 1));
        oft.quoteSend(sendParam, false);
    }

    /// @notice Test lz receive credits recipient and forwards the compose payload to the endpoint.
    function testLzReceiveCreditsRecipientAndForwardsCompose() external {
        Origin memory origin = Origin({srcEid: DST_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 1});
        bytes memory message;
        bool hasCompose;
        (message, hasCompose) =
            OFTMsgCodec.encode(bytes32(uint256(uint160(address(0x1234)))), 2_000_000, abi.encode(BENEFICIARY));
        assertTrue(hasCompose);

        // `_lzReceive` emits OFTReceived once per credit; guid/srcEid/to/amount are deterministic here.
        vm.expectEmit(true, true, false, true);
        emit IOFT.OFTReceived(bytes32("compose-guid"), DST_EID, address(0x1234), 2 ether);
        vm.prank(address(endpoint));
        oft.lzReceive(origin, bytes32("compose-guid"), message, address(0), "");

        assertEq(oft.balanceOf(address(0x1234)), 2 ether);
        assertEq(endpoint.lastComposeTo(), address(0x1234));
        assertEq(endpoint.lastComposeGuid(), bytes32("compose-guid"));
        assertEq(endpoint.lastComposeIndex(), 0);
    }

    /// @notice Regression: a bridged compose payload mints exactly once and exposes no
    ///         token-side second-mint entry.
    /// @dev After the UBO/ComposeTxStatus mechanism was removed, the only way for a bridged `lzReceive`
    ///      compose to settle is the off-chain `lzCompose` path (or `settlePendingCompose` via the dispatcher). This
    ///      guards against the old attack path where a stuck compose could be re-resolved through the token's
    ///      own `withdrawIfNotExecuted` / re-`notify` flow, double-spending the bridged amount. Assertions:
    ///        - totalSupply increases by exactly `amount` (one mint).
    ///        - the `address(0)` recipient is minted to the `0xdead` sentinel with the full amount.
    ///        - no attacker balance appears.
    ///        - the token exposes no `withdrawIfNotExecuted(bytes32,address)` selector (no second entry).
    function testComposeReceiveMintsOnceAndExposesNoTokenSideReMint() external {
        uint256 amount = 3 ether;
        Origin memory origin = Origin({srcEid: DST_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 1});

        // Compose payload sent to address(0): _credit remaps the zero recipient to the 0xdead sentinel.
        (bytes memory message, bool hasCompose) =
            OFTMsgCodec.encode(bytes32(0), oft.toSharedDecimals(amount), abi.encode(BENEFICIARY));
        assertTrue(hasCompose);

        uint256 supplyBefore = oft.totalSupply();

        // OFTReceived carries the pre-remap `sendTo` (address(0)); the 0xdead remap happens inside `_credit`.
        vm.expectEmit(true, true, false, true);
        emit IOFT.OFTReceived(bytes32("common-001"), DST_EID, address(0), amount);
        vm.prank(address(endpoint));
        oft.lzReceive(origin, bytes32("common-001"), message, address(0), "");

        // Exactly one mint happened: totalSupply rose by the bridged amount, and the 0xdead sentinel holds it all.
        assertEq(oft.totalSupply() - supplyBefore, amount, "single mint");
        assertEq(oft.balanceOf(address(0xdead)), amount, "0xdead holds full amount");

        // No attacker balance can appear from this compose path.
        assertEq(oft.balanceOf(ATTACKER), 0, "no attacker mint");

        // The token exposes no `withdrawIfNotExecuted(bytes32,address)` selector: a low-level call must not
        // return data (no matching function) and must not transfer any balance.
        (bool ok, bytes memory data) = address(oft)
            .call(abi.encodeWithSignature("withdrawIfNotExecuted(bytes32,address)", bytes32("common-001"), ATTACKER));
        assertFalse(ok, "no token-side re-mint entry exists");
        assertEq(data.length, 0, "selector unimplemented");

        assertEq(oft.balanceOf(ATTACKER), 0, "still no attacker mint after attempted re-mint");
        assertEq(oft.balanceOf(address(0xdead)), amount, "0xdead balance unchanged");
    }

    /// @notice Test send reverts when min amount exceeds received.
    function testSendRevertsWhenMinAmountExceedsReceived() external {
        endpoint.setQuoteNativeFee(0.2 ether);
        oft.mintTest(address(this), 5 ether);

        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: 5 ether,
            minAmountLD: 6 ether,
            extraOptions: bytes("opts"),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        // quoteSend itself calls _debitView and would revert before send, masking which path failed.
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 5 ether, 6 ether));
        oft.send{value: 0.2 ether}(sendParam, MessagingFee({nativeFee: 0.2 ether, lzTokenFee: 0}), address(this));

        // The slippage check in _debitView runs before _burn, so the sender balance is untouched after the revert.
        assertEq(oft.balanceOf(address(this)), 5 ether);
    }

    /// @notice Test lz receive with a zero recipient remaps to the burn address and routes compose to the raw zero address.
    function testLzReceiveRemapsZeroRecipientToBurnAddress() external {
        Origin memory origin = Origin({srcEid: DST_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 2});
        bytes memory message;
        bool hasCompose;
        (message, hasCompose) = OFTMsgCodec.encode(bytes32(0), 2_000_000, abi.encode(BENEFICIARY));
        assertTrue(hasCompose);

        vm.expectEmit(true, true, false, true);
        emit IOFT.OFTReceived(bytes32("zero-guid"), DST_EID, address(0), 2 ether);
        vm.prank(address(endpoint));
        oft.lzReceive(origin, bytes32("zero-guid"), message, address(0), "");

        assertEq(oft.balanceOf(address(0xdead)), 2 ether);
        assertEq(oft.balanceOf(address(0)), 0);
        // Compose routing intentionally uses the pre-remap recipient (address(0)); this matches official OFTCore semantics.
        assertEq(endpoint.lastComposeTo(), address(0));
    }

    /// @notice SEND-path lzReceive (empty composeMsg) still credits the recipient and emits OFTReceived,
    ///         but skips the compose-routing branch because `isComposed()` returns false.
    /// @dev Regression guard for the SEND receive path: `_credit` and the OFTReceived emit sit outside the
    ///      `if (_message.isComposed())` block in `OutrunOFTCoreInit._lzReceive`, so a 40-byte message
    ///      (sendTo + amountSD, no compose tail) must still mint and emit. The only behavioral difference
    ///      vs the composed path is that `sendCompose` is never called, so the endpoint's compose-tracking
    ///      fields stay at their zeroed initial state.
    function testLzReceiveSendPathCreditsWithoutComposing() external {
        address recipient = address(0x1234);
        uint256 amountLD = 2 ether;
        Origin memory origin = Origin({srcEid: DST_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 3});

        // Empty composeMsg -> message is 40 bytes (sendTo + amountSD) -> isComposed() is false -> SEND branch.
        (bytes memory message, bool hasCompose) =
            OFTMsgCodec.encode(bytes32(uint256(uint160(recipient))), oft.toSharedDecimals(amountLD), bytes(""));
        assertFalse(hasCompose);

        // Positive: the shared `_credit` + emit still run on the SEND branch.
        vm.expectEmit(true, true, false, true);
        emit IOFT.OFTReceived(bytes32("send-guid"), DST_EID, recipient, amountLD);
        vm.prank(address(endpoint));
        oft.lzReceive(origin, bytes32("send-guid"), message, address(0), "");

        // Positive: SEND path mints the full bridged amount to the recipient.
        assertEq(oft.balanceOf(recipient), amountLD);
        // Negative: SEND path does not invoke sendCompose, so the endpoint tracker keeps its initial zero.
        assertEq(endpoint.lastComposeTo(), address(0));
    }

    /// @notice Regression guard: an amount below `decimalConversionRate` truncates to zero.
    /// @dev `_removeDust` and `_toSD` integer-divide by `decimalConversionRate` (1e12 here), so any sub-rate
    ///      `amountLD` collapses to `amountSentLD = amountReceivedLD = 0`. The send still succeeds (no zero-amount
    ///      guard), the LayerZero fee is still paid, but `_burn(_from, amountSentLD=0)` is a no-op — the sender's
    ///      dust balance is KEPT, not lost. This locks the contract: future changes to `_removeDust`/`_toSD`
    ///      semantics (e.g. rounding instead of truncation) or to `_debit` (e.g. burning the raw `_amountLD`)
    ///      would break these assertions.
    function testSendTruncatesSubConversionRateAmountToZero() external {
        uint256 rate = oft.decimalConversionRate(); // 1e12 for the 18-decimal test token
        uint256 dust = rate - 1; // strictly below the conversion rate -> truncates to 0
        assertEq(dust, 1e12 - 1);

        oft.mintTest(address(this), dust);
        assertEq(oft.balanceOf(address(this)), dust);

        endpoint.setQuoteNativeFee(0.2 ether);

        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: dust,
            minAmountLD: 0, // 0 < 0 is false, so the slippage check passes
            extraOptions: bytes("opts"),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        // The send does not revert: no zero-amount guard exists, and `_burn(address(this), 0)` is a no-op.
        // OFTSent has 2 indexed topics (guid, from); dstEid + amounts are checked via checkData.
        vm.expectEmit(true, true, false, true);
        emit IOFT.OFTSent(bytes32("guid"), DST_EID, address(this), uint256(0), uint256(0));
        (, OFTReceipt memory receipt) =
            oft.send{value: 0.2 ether}(sendParam, MessagingFee({nativeFee: 0.2 ether, lzTokenFee: 0}), address(this));

        // amountSentLD and amountReceivedLD both collapsed to zero via truncation.
        assertEq(receipt.amountSentLD, 0, "amountSentLD truncated to 0");
        assertEq(receipt.amountReceivedLD, 0, "amountReceivedLD truncated to 0");

        // The dust is RETAINED: `_burn(_from, 0)` did not touch the sender's balance.
        assertEq(oft.balanceOf(address(this)), dust, "dust kept, not lost");
        assertEq(oft.totalSupply(), dust, "total supply unchanged");
    }

    /// @notice Boundary counterpart: an amount equal to `decimalConversionRate` does NOT truncate.
    /// @dev Pins the other side of the truncation edge so a regression that shifted the boundary
    ///      (e.g. off-by-one in `_removeDust`) would be caught here.
    function testSendAtConversionRateDoesNotTruncate() external {
        uint256 rate = oft.decimalConversionRate(); // 1e12
        oft.mintTest(address(this), rate);

        endpoint.setQuoteNativeFee(0.2 ether);

        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: rate,
            minAmountLD: 0,
            extraOptions: bytes("opts"),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        (, OFTReceipt memory receipt) =
            oft.send{value: 0.2 ether}(sendParam, MessagingFee({nativeFee: 0.2 ether, lzTokenFee: 0}), address(this));

        assertEq(receipt.amountSentLD, rate, "amountSentLD at boundary is non-zero");
        assertEq(receipt.amountReceivedLD, rate, "amountReceivedLD at boundary is non-zero");
        assertEq(oft.balanceOf(address(this)), 0, "full amount burned at boundary");
    }

    /// @notice The owner can set the outbound message inspector, which is readable via the getter.
    /// @dev `MsgInspectorSet` is non-indexed, so only the data word is matched.
    function test_SetMsgInspectorStoresInspectorAndEmitsEvent() external {
        vm.expectEmit(false, false, false, true);
        emit MsgInspectorSet(ATTACKER);

        vm.prank(OWNER);
        oft.setMsgInspector(ATTACKER);

        assertEq(oft.msgInspector(), ATTACKER, "inspector stored");
    }

    /// @notice The zero address is an accepted inspector value: the setter has no zero-address guard
    ///         because address(0) is the documented "inspection disabled" state.
    /// @dev Pinning the `MsgInspectorSet(address(0))` emit proves the zero write actually executes the
    ///      full setter body (storage update plus event), not just a stale-storage coincidence.
    function test_SetMsgInspectorAcceptsZeroAddressToDisableInspection() external {
        vm.expectEmit(false, false, false, true);
        emit MsgInspectorSet(address(0));

        vm.prank(OWNER);
        oft.setMsgInspector(address(0));

        assertEq(oft.msgInspector(), address(0), "zero inspector accepted (inspection disabled)");
    }

    /// @notice A non-owner caller cannot change the inspector.
    function test_RevertWhen_SetMsgInspectorCallerIsNotOwner() external {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, ATTACKER));
        oft.setMsgInspector(BENEFICIARY);

        assertEq(oft.msgInspector(), address(0), "inspector unchanged after the rejected call");
    }
}
