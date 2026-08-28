// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BurnableMockERC20Base} from "../common/BurnableMockERC20Base.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {OmnichainMemecoinStakerUpgradeable} from "../../../src/interoperation/OmnichainMemecoinStakerUpgradeable.sol";
import {IComposeState} from "../../../src/common/types/IComposeState.sol";

/// @dev Mirrors the real memecoin's transfer-to-zero-address guard (`OutrunERC20Init._transfer` reverts OZ's
///      `ERC20InvalidReceiver(address(0))`). Declared here with the same signature so the selector and revert data
///      are identical; solmate's bare ERC20 has no zero-address check of its own.
error ERC20InvalidReceiver(address receiver);

/// @dev Attacker-controlled token for the forged-token mutex regression test. The forged settle releases 1 wei via
///      `_transferOut` (push), so `OutrunSafeERC20.safeTransfer` (bubble=true) must see a working `transfer` on this
///      mock for the release to succeed.
contract AttackStakerToken {
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Mock memecoin used by the omnichain staker tests.
/// @dev Implements `IBurnable` so production code that calls the burn path can exercise it without a full
///      LayerZero deployment. Replay protection now lives in the staker's `composeStates` mutex, so this mock
///      no longer tracks a token-side executed-status flag. The transfer failure switch and the mid-call Released
///      probe pin the settlePendingCompose rollback-retry contract and its CEI write order (Released written
///      before the outward transfer).
contract MockStakerComposeToken is BurnableMockERC20Base {
    bool public transferRevert;
    address public composeProbeStaker;
    bytes32 public composeProbeGuid;

    constructor() BurnableMockERC20Base("Memecoin", "MEME", 18, BurnMode.Plain) {}

    /// @notice Set whether transfers should revert.
    function setTransferRevert(bool transferRevert_) external {
        transferRevert = transferRevert_;
    }

    /// @notice Arm the mid-call Released-state probe: the next transfer asserts the (token, guid) mutex is already
    ///         Released mid-call, pinning the settlePendingCompose CEI write order (Released written before the
    ///         settle external call).
    /// @param staker_ The OmnichainMemecoinStakerUpgradeable whose composeStates to read.
    /// @param guid_ The compose guid to probe.
    function setComposeProbeReleased(address staker_, bytes32 guid_) external {
        composeProbeStaker = staker_;
        composeProbeGuid = guid_;
    }

    /// @notice Transfer.
    /// @param to See implementation.
    /// @param amount See implementation.
    /// @return See implementation.
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!transferRevert, "transfer failed");
        // Mirror the real memecoin's zero-address guard: the staker's receiver==0 fallback boundary depends on
        // the token reverting so the CEI Settled write rolls back and the slot stays pinned.
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        // Probe pins that settlePendingCompose wrote Released before the outward transfer (CEI write order).
        if (composeProbeStaker != address(0)) {
            require(
                OmnichainMemecoinStakerUpgradeable(composeProbeStaker).composeStates(address(this), composeProbeGuid)
                    == IComposeState.ComposeState.Released,
                "released write not visible mid-call"
            );
        }
        return super.transfer(to, amount);
    }
}

/// @notice Mock yield vault recording the last deposit for assertions.
contract MockStakerYieldVault {
    address public token;
    uint256 public lastDepositAmount;
    address public lastDepositReceiver;
    bool public shouldRevert;
    bool public returnZeroSharesForNonZero;
    // Mid-call compose-state probe for the deposit branch. Mirrors YieldDispatcherMockBase._checkComposeProbes: the
    // next deposit callback asserts the (token, guid) mutex is already Settled mid-call, pinning the lzCompose CEI
    // write order (Settled written before the deposit external call). Unlike MockStakerComposeToken's probe — which
    // sits on the overridden public `transfer` and is bypassed by solmate's `transferFrom` (the deposit pull path) —
    // this probe fires inside `deposit` itself, so it is reached on every deposit regardless of the pull mechanism.
    address public composeProbeStaker;
    bytes32 public composeProbeGuid;

    constructor(address token_) {
        token = token_;
    }

    /// @notice Underlying asset of the mock vault.
    /// @dev Mirrors the real vault's `asset()` (its immutable underlying token), which the staker's deposit branch
    ///      now reads to bind the delivered token to the vault (`TokenVaultMismatch` check).
    /// @return tokenAddress Underlying asset token address.
    function asset() external view returns (address tokenAddress) {
        return token;
    }

    /// @notice Set whether deposits should revert.
    /// @param shouldRevert_ See implementation.
    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    /// @notice Set whether non-zero deposits should return 0 shares without reverting (drift simulation).
    /// @param returnZeroSharesForNonZero_ See implementation.
    function setReturnZeroSharesForNonZero(bool returnZeroSharesForNonZero_) external {
        returnZeroSharesForNonZero = returnZeroSharesForNonZero_;
    }

    /// @notice Arm the mid-call compose-state probe: the next deposit callback asserts the (token, guid) mutex is
    ///         already Settled mid-call, pinning the lzCompose deposit-branch CEI write order (Settled written before
    ///         the deposit external call). Symmetric to YieldDispatcherMockBase.setComposeProbe on the dispatcher side.
    /// @param staker_ The OmnichainMemecoinStakerUpgradeable whose composeStates to read.
    /// @param guid_ The compose guid to probe.
    function setComposeProbe(address staker_, bytes32 guid_) external {
        composeProbeStaker = staker_;
        composeProbeGuid = guid_;
    }

    /// @notice Deposit.
    /// @param amount See implementation.
    /// @param receiver See implementation.
    /// @return shares See implementation.
    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        require(!shouldRevert, "deposit failed");
        // Mid-call probe: asserts the staker already wrote Settled before this deposit external call (CEI). The
        // deposit branch has no `_transferOut`/`nonReentrant`, so CEI write order is the sole reentrancy defense;
        // this probe is the regression guard that catches a reorder moving Settled after the deposit.
        if (composeProbeStaker != address(0)) {
            require(
                OmnichainMemecoinStakerUpgradeable(composeProbeStaker).composeStates(token, composeProbeGuid)
                    == IComposeState.ComposeState.Settled,
                "settled write not visible mid-call"
            );
        }
        // Mirror MemecoinYieldVault.deposit: a zero-asset deposit early-returns before any receiver check
        // (production early-return at MemecoinYieldVault.sol:168), so amount==0 x receiver==0 converges.
        if (amount == 0) {
            lastDepositAmount = amount;
            lastDepositReceiver = receiver;
            return 0;
        }
        // Mirror the production `_mint` zero-account guard (OutrunERC20Init._mint -> ERC20InvalidReceiver):
        // without it a receiver==0 deposit silently succeeds on the mock while production reverts, and the
        // deployed-vault x receiver==0 boundary test would pass with the wrong terminal state.
        if (receiver == address(0)) revert ERC20InvalidReceiver(receiver);
        // Drift simulation: a vault variant that absorbs the assets but mints nothing and returns 0 without
        // reverting (the real vault reverts ZeroSharesDeposit instead). Exercises the staker's amount-gated
        // deposit return-value guard.
        if (returnZeroSharesForNonZero) {
            MockERC20(token).transferFrom(msg.sender, address(this), amount);
            lastDepositAmount = amount;
            lastDepositReceiver = receiver;
            return 0;
        }
        // Mirror MemecoinYieldVault.deposit: pull via transferFrom from msg.sender (the staker), then record.
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        lastDepositAmount = amount;
        lastDepositReceiver = receiver;
        shares = amount;
    }
}

/// @notice A malicious yield vault that reenters `settlePendingCompose` from inside its `deposit` callback with the
///         same guid.
/// @dev The deposit branch has no `_transferOut`/`nonReentrant`, so the only reentrancy defense is the `composeStates`
///      mutex: the outer `lzCompose` writes `Settled` (CEI) before the `deposit` external call, so a reentry into
///      `settlePendingCompose` with the same (memecoin, guid) must read `Settled` and revert `AlreadyResolved` (the
///      `composeStates == None` check is the very first guard in settle, ahead of `verifySettle` and beneficiary).
///      This pins the CEI write order as a regression guard: if `Settled` were ever moved after the deposit call, the
///      reentry would read `None`, pass that first guard, and proceed — this test would catch the reorder. Symmetric to
///      ReentrantDispatcherVault (test/mocks/verse/DispatcherTestMocks.sol) on the dispatcher settle path.
contract ReentrantStakerVault {
    OmnichainMemecoinStakerUpgradeable internal immutable staker;
    address internal memecoin;
    bytes32 internal reentryGuid;
    bytes internal reentryMessage;

    constructor(OmnichainMemecoinStakerUpgradeable staker_) {
        staker = staker_;
    }

    /// @notice Arm the reentry attempt with the same (memecoin, guid, message) the outer lzCompose is settling.
    function armReentry(address memecoin_, bytes32 guid_, bytes memory message_) external {
        memecoin = memecoin_;
        reentryGuid = guid_;
        reentryMessage = message_;
    }

    /// @notice `asset()` so the staker's `TokenVaultMismatch` binding check accepts this vault as the memecoin's vault.
    function asset() external view returns (address) {
        return memecoin;
    }

    /// @notice `deposit` that triggers the same-guid reentry mid-call. `settlePendingCompose` is permissionless at the
    ///         first guard (`composeStates == None`), so the vault reenters it directly; the reentry must revert
    ///         `AlreadyResolved` because the outer lzCompose already wrote `Settled` (CEI). Pulls nothing.
    function deposit(uint256, address) external returns (uint256) {
        staker.settlePendingCompose(memecoin, reentryGuid, reentryMessage);
        return 0;
    }
}

/// @notice Mock launcher exposing the memecoin -> verse lookup used by interoperation tests.
contract MockInteroperationLauncher {
    IMemeverseLauncher.Memeverse internal verse;
    address internal registeredMemecoin;

    /// @notice Set memeverse.
    /// @param memecoin See implementation.
    /// @param verse_ See implementation.
    function setMemeverse(address memecoin, IMemeverseLauncher.Memeverse memory verse_) external {
        registeredMemecoin = memecoin;
        verse = verse_;
    }

    /// @notice Get memeverse by memecoin.
    /// @param memecoin See implementation.
    /// @return See implementation.
    function getMemeverseByMemecoin(address memecoin) external view returns (IMemeverseLauncher.Memeverse memory) {
        if (memecoin != registeredMemecoin) {
            revert IMemeverseLauncher.InvalidVerseId();
        }
        return verse;
    }
}

/// @notice Mock yield vault recording the last deposit for interoperation assertions.
contract MockInteroperationYieldVault {
    uint256 public lastDepositAmount;
    address public lastDepositReceiver;

    /// @notice Deposit.
    /// @param amount See implementation.
    /// @param receiver See implementation.
    /// @return shares See implementation.
    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        lastDepositAmount = amount;
        lastDepositReceiver = receiver;
        shares = amount;
    }
}

/// @notice Mock OFT that records send inputs and enforces the quoted fee.
/// @dev Asserts `fee` and `msg.value` match the last `quoteFee` so callers cannot reuse a stale quote.
contract MockInteroperationOFT is MockERC20, IOFT {
    using OptionsBuilder for bytes;

    error InvalidQuotedSendFee(
        uint256 expectedNativeFee,
        uint256 expectedLzTokenFee,
        uint256 providedNativeFee,
        uint256 providedLzTokenFee,
        uint256 msgValue
    );

    MessagingFee internal quoteFee;
    uint32 public lastSendDstEid;
    bytes32 public lastSendTo;
    bytes public lastSendComposeMsg;
    uint256 public lastSendNativeFee;
    address public lastRefundAddress;
    uint256 public lastSendValue;
    bytes32 public nextGuid = bytes32("stake-guid");

    constructor() MockERC20("Memecoin", "MEME", 18) {}

    /// @notice Set quote fee.
    /// @param nativeFee See implementation.
    function setQuoteFee(uint256 nativeFee) external {
        quoteFee = MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    /// @notice Oft version.
    /// @return interfaceId See implementation.
    /// @return version See implementation.
    function oftVersion() external pure returns (bytes4 interfaceId, uint64 version) {
        return (type(IOFT).interfaceId, 1);
    }

    /// @notice Token.
    /// @return See implementation.
    function token() external view returns (address) {
        return address(this);
    }

    /// @notice Approval required.
    /// @return See implementation.
    function approvalRequired() external pure returns (bool) {
        return false;
    }

    /// @notice Shared decimals.
    /// @return See implementation.
    function sharedDecimals() external pure returns (uint8) {
        return 6;
    }

    /// @notice Quote oft — mirrors `OutrunOFTCoreInit._debitView`/`_removeDust` truncation.
    /// @dev The production memecoin OFT truncates the local-decimal amount to
    ///      `(amountLD / decimalConversionRate) * decimalConversionRate` before encoding the shared-decimal amount on
    ///      the wire, so a sub-`decimalConversionRate` `amountLD` collapses to `amountSentLD = amountReceivedLD = 0`.
    ///      Implementing the same truncation here lets the interoperation router's `amountReceivedLD != 0` pre-check
    ///      behave against the mock exactly as it does against a real 18-decimal memecoin (rate = 1e12).
    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory)
    {
        uint256 rate = 10 ** (this.decimals() - this.sharedDecimals());
        // Intentional LayerZero `_removeDust` truncation — see the `_debit` mirror below.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 amountSentLD = (sendParam.amountLD / rate) * rate;
        return (OFTLimit(0, type(uint64).max), new OFTFeeDetail[](0), OFTReceipt(amountSentLD, amountSentLD));
    }

    /// @notice Quote send.
    /// @param sendParam See implementation.
    /// @param payInLzToken See implementation.
    /// @return fee See implementation.
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory fee)
    {
        sendParam;
        payInLzToken;
        fee = quoteFee;
    }

    /// @notice Send.
    /// @param sendParam See implementation.
    /// @param fee See implementation.
    /// @param refundAddress See implementation.
    /// @return receipt See implementation.
    /// @return oftReceipt See implementation.
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        if (
            fee.nativeFee != quoteFee.nativeFee || fee.lzTokenFee != quoteFee.lzTokenFee
                || msg.value != quoteFee.nativeFee
        ) {
            revert InvalidQuotedSendFee(
                quoteFee.nativeFee, quoteFee.lzTokenFee, fee.nativeFee, fee.lzTokenFee, msg.value
            );
        }

        lastSendDstEid = sendParam.dstEid;
        lastSendTo = sendParam.to;
        lastSendComposeMsg = sendParam.composeMsg;
        lastSendNativeFee = fee.nativeFee;
        lastRefundAddress = refundAddress;
        lastSendValue = msg.value;
        // Mirror the real OFT `_debit`: burn only the truncated `amountSentLD` (what `_removeDust` keeps), so a
        // sub-multiple `amountLD` leaves the remainder in the caller's balance via the router's refund path. Burning
        // the raw `amountLD` here (as an earlier version did) would mask the refund behavior under test.
        uint256 rate = 10 ** (this.decimals() - this.sharedDecimals());
        // Intentional LayerZero `_removeDust` truncation — mirrors the real OFT `_debit` burn.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 amountSentLD = (sendParam.amountLD / rate) * rate;
        _burn(msg.sender, amountSentLD);

        receipt = MessagingReceipt({guid: nextGuid, nonce: 1, fee: fee});
        oftReceipt = OFTReceipt({amountSentLD: amountSentLD, amountReceivedLD: amountSentLD});
    }
}

/// @notice A forged vault whose `asset()` actively reverts with its own reason: the staker's binding guard
///         (`require(IMemecoinYieldVault(yieldVault).asset() == memecoin, TokenVaultMismatch())`) only emits its
///         named error when the message-named callee implements `asset()` AND returns a readable word; a
///         reverting `asset()` propagates the callee's own error instead — the same opaque-failure class as an
///         asset-less vault ("asset() unreadable" boundary, revert sub-class).
/// @dev Attacker-style mock: a self-harm frame may name ANY code-bearing contract as the vault word, so a
///      contract whose `asset()` reverts is a legitimate member of the forged-vault family.
contract RevertingAssetVault {
    /// @notice Reverts with a reason string instead of returning the underlying asset.
    function asset() external pure returns (address) {
        revert("vault asset exploded");
    }
}
