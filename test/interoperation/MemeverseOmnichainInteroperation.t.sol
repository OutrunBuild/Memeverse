// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {ICrossChainSendErrors} from "../../src/common/types/ICrossChainSendErrors.sol";
import {
    IMemeverseOmnichainInteroperation
} from "../../src/interoperation/interfaces/IMemeverseOmnichainInteroperation.sol";
import {MemeverseOmnichainInteroperation} from "../../src/interoperation/MemeverseOmnichainInteroperation.sol";
import {
    MockInteroperationLauncher,
    MockInteroperationRegistry,
    MockInteroperationYieldVault,
    MockInteroperationOFT
} from "../mocks/interoperation/InteroperationMocks.sol";

contract MemeverseOmnichainInteroperationTest is Test {
    using OptionsBuilder for bytes;

    address internal constant OWNER = address(0xABCD);
    address internal constant RECEIVER = address(0xBEEF);
    address internal constant OMNICHAIN_STAKER = address(0xCAFE);
    uint32 internal constant REMOTE_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;

    MockInteroperationLauncher internal launcher;
    MockInteroperationRegistry internal registry;
    MockInteroperationYieldVault internal yieldVault;
    MockInteroperationOFT internal memecoin;
    MemeverseOmnichainInteroperation internal interoperation;

    /// @notice Set up.
    function setUp() external {
        launcher = new MockInteroperationLauncher();
        registry = new MockInteroperationRegistry();
        yieldVault = new MockInteroperationYieldVault();
        memecoin = new MockInteroperationOFT();
        interoperation = new MemeverseOmnichainInteroperation(
            OWNER, address(registry), address(launcher), OMNICHAIN_STAKER, 115_000, 135_000
        );
    }

    /// @notice Test constructor rejects zero omnichain memecoin staker.
    function testConstructorRejectsZeroOmnichainMemecoinStaker() external {
        vm.expectRevert(IMemeverseOmnichainInteroperation.ZeroAddress.selector);
        new MemeverseOmnichainInteroperation(OWNER, address(registry), address(launcher), address(0), 115_000, 135_000);
    }

    /// @notice Test quote memecoin staking rejects zero input.
    function testQuoteMemecoinStakingRejectsZeroInput() external {
        vm.expectRevert(IMemeverseOmnichainInteroperation.ZeroInput.selector);
        interoperation.quoteMemecoinStaking(address(0), RECEIVER, 1 ether);
    }

    /// @notice Test quote memecoin staking rejects unregistered memecoin.
    function testQuoteMemecoinStakingRejectsUnregisteredMemecoin() external {
        _setLocalVerse(address(yieldVault));

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        interoperation.quoteMemecoinStaking(address(0x9999), RECEIVER, 1 ether);
    }

    /// @notice Test quote memecoin staking returns zero for local governance chain.
    function testQuoteMemecoinStakingReturnsZeroForLocalGovernanceChain() external {
        _setLocalVerse(address(yieldVault));

        uint256 fee = interoperation.quoteMemecoinStaking(address(memecoin), RECEIVER, 1 ether);
        assertEq(fee, 0);
    }

    /// @notice Test the endpoint registry dependency getter uses its concrete name.
    function testEndpointRegistryGetterReturnsRegistry() external {
        assertEq(interoperation.LZ_ENDPOINT_REGISTRY(), address(registry));
    }

    /// @notice Test quote memecoin staking builds remote send param.
    function testQuoteMemecoinStakingBuildsRemoteSendParam() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.25 ether);

        bytes memory expectedOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(115_000, 0)
            .addExecutorLzComposeOption(0, 135_000, 0);

        vm.expectCall(
            address(memecoin),
            abi.encodeWithSelector(
                IOFT.quoteSend.selector,
                SendParam({
                    dstEid: REMOTE_EID,
                    to: bytes32(uint256(uint160(OMNICHAIN_STAKER))),
                    amountLD: 2 ether,
                    minAmountLD: 0,
                    extraOptions: expectedOptions,
                    composeMsg: abi.encode(RECEIVER, address(yieldVault)),
                    oftCmd: abi.encode()
                }),
                false
            )
        );

        uint256 fee = interoperation.quoteMemecoinStaking(address(memecoin), RECEIVER, 2 ether);
        assertEq(fee, 0.25 ether);
    }

    /// @notice Test memecoin staking local path rejects empty vault and deposits to yield vault.
    function testMemecoinStakingLocalPathRejectsEmptyVaultAndDepositsToYieldVault() external {
        _setLocalVerse(address(0));
        memecoin.mint(address(this), 3 ether);
        memecoin.approve(address(interoperation), type(uint256).max);

        vm.expectRevert(IMemeverseOmnichainInteroperation.EmptyYieldVault.selector);
        interoperation.memecoinStaking(address(memecoin), RECEIVER, 3 ether);

        _setLocalVerse(address(yieldVault));
        interoperation.memecoinStaking(address(memecoin), RECEIVER, 3 ether);

        assertEq(yieldVault.lastDepositAmount(), 3 ether);
        assertEq(yieldVault.lastDepositReceiver(), RECEIVER);
    }

    /// @notice Test memecoin staking remote path checks fee and sends oft.
    function testMemecoinStakingRemotePathChecksFeeAndSendsOFT() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        memecoin.mint(address(this), 5 ether);
        memecoin.approve(address(interoperation), type(uint256).max);
        uint256 quotedFee = interoperation.quoteMemecoinStaking(address(memecoin), RECEIVER, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseOmnichainInteroperation.InvalidLzFee.selector, quotedFee, 0));
        interoperation.memecoinStaking(address(memecoin), RECEIVER, 5 ether);

        interoperation.memecoinStaking{value: quotedFee}(address(memecoin), RECEIVER, 5 ether);

        assertEq(memecoin.lastRefundAddress(), address(this));
        assertEq(memecoin.lastSendValue(), quotedFee);
        assertEq(memecoin.lastSendNativeFee(), quotedFee);
        assertEq(memecoin.lastSendDstEid(), REMOTE_EID);
        assertEq(memecoin.lastSendTo(), bytes32(uint256(uint160(OMNICHAIN_STAKER))));
        assertEq(memecoin.lastSendComposeMsg(), abi.encode(RECEIVER, address(yieldVault)));
    }

    /// @notice Verifies the OFT mock rejects stale quoted fees and mismatched msg.value.
    function testMockInteroperationOFTSendRejectsStaleQuotedFee() external {
        memecoin.mint(address(this), 1 ether);

        SendParam memory sendParam = SendParam({
            dstEid: REMOTE_EID,
            to: bytes32(uint256(uint160(OMNICHAIN_STAKER))),
            amountLD: 1 ether,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: abi.encode(RECEIVER, address(yieldVault)),
            oftCmd: abi.encode()
        });
        memecoin.setQuoteFee(0.2 ether);
        MessagingFee memory staleFee = memecoin.quoteSend(sendParam, false);
        memecoin.setQuoteFee(0.3 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockInteroperationOFT.InvalidQuotedSendFee.selector, 0.3 ether, 0, 0.2 ether, 0, 0.2 ether
            )
        );
        memecoin.send{value: staleFee.nativeFee}(sendParam, staleFee, RECEIVER);
    }

    /// @notice Verifies remote staking rejects overpayment instead of trapping extra ETH in the interoperation contract.
    /// @dev Requires callers to provide the exact quoted LayerZero fee.
    function testMemecoinStakingRemotePathRevertsWhenLzFeeIsNotExact() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        memecoin.mint(address(this), 5 ether);
        memecoin.approve(address(interoperation), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseOmnichainInteroperation.InvalidLzFee.selector, 0.4 ether, 0.41 ether)
        );
        interoperation.memecoinStaking{value: 0.41 ether}(address(memecoin), RECEIVER, 5 ether);
    }

    /// @notice Verifies local staking rejects accidental native value.
    /// @dev Prevents same-chain staking calls from trapping ETH in the interoperation contract.
    function testMemecoinStakingLocalPathRevertsWhenMsgValueProvided() external {
        _setLocalVerse(address(yieldVault));
        memecoin.mint(address(this), 3 ether);
        memecoin.approve(address(interoperation), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IMemeverseOmnichainInteroperation.InvalidLzFee.selector, 0, 1));
        interoperation.memecoinStaking{value: 1}(address(memecoin), RECEIVER, 3 ether);
    }

    /// @notice Test memecoin staking rejects unregistered memecoin.
    function testMemecoinStakingRejectsUnregisteredMemecoin() external {
        _setLocalVerse(address(yieldVault));

        vm.expectRevert(IMemeverseLauncher.InvalidVerseId.selector);
        interoperation.memecoinStaking(address(0x9999), RECEIVER, 1 ether);
    }

    /// @notice Test set gas limits only owner and rejects zero.
    function testSetGasLimitsOnlyOwnerAndRejectsZero() external {
        vm.prank(address(0x1234));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x1234)));
        interoperation.setGasLimits(1, 1);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseOmnichainInteroperation.ZeroInput.selector);
        interoperation.setGasLimits(0, 1);

        vm.expectEmit(false, false, false, true);
        emit IMemeverseOmnichainInteroperation.SetGasLimits(1, 2);
        vm.prank(OWNER);
        interoperation.setGasLimits(1, 2);
        assertEq(interoperation.oftReceiveGasLimit(), 1);
        assertEq(interoperation.omnichainStakingGasLimit(), 2);
    }

    /// @notice Fuzzes that every valid gas-limit update persists both configured values.
    function testFuzz_SetGasLimitsStoresPositiveValues(uint128 oftReceiveGasLimit, uint128 stakingGasLimit) external {
        oftReceiveGasLimit = uint128(bound(oftReceiveGasLimit, 1, type(uint128).max));
        stakingGasLimit = uint128(bound(stakingGasLimit, 1, type(uint128).max));

        vm.prank(OWNER);
        interoperation.setGasLimits(oftReceiveGasLimit, stakingGasLimit);

        assertEq(interoperation.oftReceiveGasLimit(), oftReceiveGasLimit);
        assertEq(interoperation.omnichainStakingGasLimit(), stakingGasLimit);
    }

    /// @notice Regression guard for the sub-`decimalConversionRate` truncation (MR-45).
    /// @dev `_removeDust` truncates `amountLD / rate * rate`; for an 18-decimal memecoin (rate = 1e12) any
    ///      `0 < amount < 1e12` collapses to `amountReceivedLD = 0`. Before the fix this would silently pull the
    ///      dust into the router, send a zero-amount compose (zero position, full LZ fee), and strand the dust.
    ///      The router now rejects it with `DustAmount` BEFORE `_transferIn`, so the caller's balance is untouched.
    function testMemecoinStakingRemotePathRejectsSubConversionRateAmount() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        uint256 subRate = 1e12 - 1; // strictly below decimalConversionRate -> truncates to 0
        memecoin.mint(address(this), subRate);
        memecoin.approve(address(interoperation), type(uint256).max);

        vm.expectRevert(ICrossChainSendErrors.DustAmount.selector);
        interoperation.memecoinStaking{value: 0.4 ether}(address(memecoin), RECEIVER, subRate);

        // Guard fires BEFORE _transferIn: the caller still holds the full dust (no stranding).
        assertEq(memecoin.balanceOf(address(this)), subRate);
        assertEq(memecoin.balanceOf(address(interoperation)), 0);
    }

    /// @notice Quote path mirrors the send guard: a sub-rate amount reverts at quote time too.
    function testQuoteMemecoinStakingRejectsSubConversionRateAmount() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.25 ether);

        vm.expectRevert(ICrossChainSendErrors.DustAmount.selector);
        interoperation.quoteMemecoinStaking(address(memecoin), RECEIVER, 1e12 - 1);
    }

    /// @notice Boundary counterpart: an amount that is an exact multiple of `decimalConversionRate` passes the guard.
    /// @dev `amount == rate` (`1e12`) is an exact multiple (`_removeDust(1e12) == 1e12`, `amountSentLD == amountLD`),
    ///      so the guard accepts it. Pins the upper edge so a guard that wrongly rejected rate-sized amounts is caught.
    function testMemecoinStakingRemotePathAcceptsConversionRateAmount() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        uint256 rate = 1e12; // exactly the conversion rate -> an exact multiple, no truncation
        memecoin.mint(address(this), rate);
        memecoin.approve(address(interoperation), type(uint256).max);

        interoperation.memecoinStaking{value: 0.4 ether}(address(memecoin), RECEIVER, rate);

        // The full rate-sized amount was pulled and burned by the OFT send (no stranding).
        assertEq(memecoin.balanceOf(address(this)), 0);
        assertEq(memecoin.balanceOf(address(interoperation)), 0);
        assertEq(memecoin.lastSendDstEid(), REMOTE_EID);
    }

    /// @notice A non-exact-multiple amount above the rate does NOT revert — the un-burnt remainder is refunded to the
    ///         caller on the source chain, so nothing strands. Pins the refund behavior (vs the alternative of
    ///         reverting, which would force the caller to round to an exact multiple).
    /// @dev `amount = rate + 1` truncates to `amountSentLD = rate` (1 wei remainder). The send proceeds, then
    ///      `memecoinStaking` refunds the 1-wei remainder to `msg.sender`. The caller ends with 1 wei back; the
    ///      contract holds nothing.
    function testMemecoinStakingRemotePathRefundsNonExactMultipleRemainder() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        uint256 nonMultiple = 1e12 + 1; // above rate, not an exact multiple -> truncates to 1e12, 1 wei remainder
        memecoin.mint(address(this), nonMultiple);
        memecoin.approve(address(interoperation), type(uint256).max);

        // The mock reuses `nextGuid` (never incremented) as the send guid, so its current value is the emitted guid.
        vm.expectEmit(true, true, true, true);
        emit IMemeverseOmnichainInteroperation.OmnichainMemecoinStaking(
            memecoin.nextGuid(), address(this), RECEIVER, address(memecoin), nonMultiple, 1e12, 1
        );
        interoperation.memecoinStaking{value: 0.4 ether}(address(memecoin), RECEIVER, nonMultiple);

        // The 1-wei remainder was refunded to the caller; the contract holds nothing (no stranding).
        assertEq(memecoin.balanceOf(address(this)), 1, "remainder refunded");
        assertEq(memecoin.balanceOf(address(interoperation)), 0, "contract holds no dust");
        assertEq(memecoin.lastSendDstEid(), REMOTE_EID);
    }

    /// @notice A large whole-ether amount (an exact 1e12-multiple) sends the full amount with zero remainder — no
    ///         refund, nothing strands. Guards against a regression where the refund path or guard would wrongly
    ///         affect normal staking.
    /// @dev `1.5 ether == 1.5e18 == 1.5e6 * 1e12`, an exact multiple, so `_removeDust` leaves it unchanged and the
    ///      remainder is 0 (no refund transfer).
    function testMemecoinStakingRemotePathAcceptsWholeEtherAmount() external {
        _setRemoteVerse(address(yieldVault));
        memecoin.setQuoteFee(0.4 ether);
        uint256 wholeEther = 1.5 ether; // 1.5e18 = 1.5e6 * 1e12, an exact multiple
        memecoin.mint(address(this), wholeEther);
        memecoin.approve(address(interoperation), type(uint256).max);

        interoperation.memecoinStaking{value: 0.4 ether}(address(memecoin), RECEIVER, wholeEther);

        assertEq(memecoin.balanceOf(address(this)), 0);
        assertEq(memecoin.balanceOf(address(interoperation)), 0);
    }

    function _setLocalVerse(address yieldVaultAddress) internal {
        launcher.setMemeverse(address(memecoin), _verse(uint32(block.chainid), yieldVaultAddress));
    }

    function _setRemoteVerse(address yieldVaultAddress) internal {
        registry.setEndpoint(REMOTE_CHAIN_ID, REMOTE_EID);
        launcher.setMemeverse(address(memecoin), _verse(REMOTE_CHAIN_ID, yieldVaultAddress));
    }

    function _verse(uint32 govChainId, address yieldVaultAddress)
        internal
        pure
        returns (IMemeverseLauncher.Memeverse memory verse)
    {
        verse.yieldVault = yieldVaultAddress;
        verse.omnichainIds = new uint32[](1);
        verse.omnichainIds[0] = govChainId;
    }
}
