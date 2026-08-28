// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {FeeMath} from "../../src/swap/libraries/FeeMath.sol";
import {OutrunOwnable} from "../../src/common/access/OutrunOwnable.sol";

import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";

/// @notice End-to-end coverage for the referral-rebate feature: rebate storage/setter/views, hook decode +
///         rebate routing, claim flow, 65/25/10 fee conservation, self-referral, and rebate solvency.
/// @dev Rebate custody and the `pendingRebateOf`/`claimRebate` views live on the hook Router. `engine` is an
///      interface alias for the hook proxy, so rebate-rate reads, pending reads, and claims all target the
///      Router. The realistic swap harness accrues rebate through a real swap unlock session, where the facet
///      `take`s rebate into the hook proxy under delegatecall.
contract MemeverseReferralRebateTest is RealisticSwapIntegrationBase {
    /// @dev Interface alias for the hook Router that owns rebate custody and the claim/pending views.
    IMemeverseUniswapHook internal engine;

    /// @dev Canonical referrer address used across accrual/integration tests.
    address internal constant REFERRER = address(0xCAFE);

    function setUp() public {
        // Base owns no `setUp`; integration fixtures are wired through `_setUpIntegration`.
        _setUpIntegration(IPermit2(address(0)));
        engine = IMemeverseUniswapHook(address(hook));
        // Charge the protocol fee on the input currency (currency0 for zeroForOne swaps) so a
        // single exact-input swap accrues rebate in token0.
        hook.setProtocolFeeCurrency(key.currency0, true);
        // Push the pool past the launch-fee decay window so the quoted fee is the stable base fee,
        // keeping the 65/25/10 amounts deterministic across runs.
        _matureLaunchWindow();
    }

    // -------------------------------------------------------------------------
    // Setter / default / view coverage (engine storage via hook wrapper)
    // -------------------------------------------------------------------------

    /// @notice Default rebate rate initialized to 1000 bps (10% of the total fee).
    function testRebateBps_DefaultIs1000() external view {
        assertEq(engine.referrerRebateBps(), 1000, "default rebate bps");
    }

    /// @notice Owner may raise the rate up to the protocol share boundary inclusive.
    function testSetReferrerRebateBps_OwnerSucceedsUpToProtocolShare() external {
        uint256 oldBps = engine.referrerRebateBps();
        vm.expectEmit(false, false, false, true, address(hook));
        emit IMemeverseUniswapHook.ReferrerRebateBpsUpdated(oldBps, FeeMath.PROTOCOL_FEE_SHARE_BPS);
        hook.setReferrerRebateBps(FeeMath.PROTOCOL_FEE_SHARE_BPS);
        assertEq(engine.referrerRebateBps(), FeeMath.PROTOCOL_FEE_SHARE_BPS, "set to protocol share");
    }

    /// @notice Rates above the protocol share would leave the treasury share negative.
    function testSetReferrerRebateBps_RevertsWhenExceedsProtocolShare() external {
        vm.expectRevert(IMemeverseUniswapHook.RebateExceedsProtocolShare.selector);
        hook.setReferrerRebateBps(FeeMath.PROTOCOL_FEE_SHARE_BPS + 1);
    }

    /// @notice Non-owner cannot change the rate.
    function testSetReferrerRebateBps_RevertsWhenNotOwner() external {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setReferrerRebateBps(500);
    }

    // -------------------------------------------------------------------------
    // Hook integration: referrer decode + rebate accrual during a swap
    // -------------------------------------------------------------------------

    /// @notice A swap carrying a referrer in hookData accrues rebate to that referrer and still
    ///         delivers the (reduced) treasury share. Referrer is the first 20 bytes of hookData.
    function testSwap_WithReferrer_AccruesRebateInEngine() external {
        uint256 treasuryBefore = _balanceOf(key.currency0, treasury);

        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();

        assertGt(engine.pendingRebateOf(REFERRER, key.currency0), 0, "rebate accrued");
        assertGt(_balanceOf(key.currency0, treasury), treasuryBefore, "treasury still funded");
    }

    /// @notice Without a referrer the full protocol fee lands in the treasury and no rebate is
    ///         recorded for any address.
    function testSwap_NoReferrer_FullProtocolFeeToTreasury() external {
        uint256 treasuryBefore = _balanceOf(key.currency0, treasury);

        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), bytes(""));
        hook.endAccountSession();

        assertEq(engine.pendingRebateOf(REFERRER, key.currency0), 0, "no rebate without referrer");
        assertGt(_balanceOf(key.currency0, treasury), treasuryBefore, "treasury funded");
    }

    /// @notice Self-referral (trader is the referrer) is permitted; no anti-self-deallocation rule.
    function testSwap_SelfReferral_IsAllowed() external {
        address self = address(this);

        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(self));
        hook.endAccountSession();

        assertGt(engine.pendingRebateOf(self, key.currency0), 0, "self-referral accrued");
    }

    // -------------------------------------------------------------------------
    // claimRebate: transfer + zero-out + edge cases
    // -------------------------------------------------------------------------

    /// @notice After a rebate accrues, the referrer can claim it: recipient balance rises by the
    ///         pending amount and the ledger is zeroed.
    function testClaimRebate_TransfersAndZeroesBalance() external {
        address recipient = makeAddr("rebateRecipient");
        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();
        uint256 pending = engine.pendingRebateOf(REFERRER, key.currency0);

        uint256 recipientBefore = _balanceOf(key.currency0, recipient);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IMemeverseUniswapHook.ReferralRebateClaimed(REFERRER, recipient, key.currency0, pending);
        vm.prank(REFERRER);
        uint256 paid = engine.claimRebate(key.currency0, recipient);

        assertEq(paid, pending, "paid == pending");
        assertEq(_balanceOf(key.currency0, recipient), recipientBefore + pending, "recipient credited");
        assertEq(engine.pendingRebateOf(REFERRER, key.currency0), 0, "ledger zeroed");
    }

    /// @notice Claiming with no accrued balance is a no-op returning 0 (not a revert).
    function testClaimRebate_ZeroBalance_ReturnsZero() external {
        address recipient = makeAddr("emptyRecipient");
        vm.prank(REFERRER);
        uint256 paid = engine.claimRebate(key.currency0, recipient);
        assertEq(paid, 0, "zero balance yields zero payout");
    }

    /// @notice Zero-address recipient is rejected to avoid burning rebates silently.
    function testClaimRebate_RevertsWhenRecipientZero() external {
        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();
        vm.prank(REFERRER);
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        engine.claimRebate(key.currency0, address(0));
    }

    // -------------------------------------------------------------------------
    // End-to-end 65/25/10 fee conservation
    // -------------------------------------------------------------------------

    /// @notice Verifies the locked spec split: LP 65% / treasury 25% / referrer 10% of the total fee.
    ///         Tolerance absorbs FullMath.mulDiv rounding across the two-level fee split.
    function testE2E_FeeSplitMatches65_25_10() external {
        uint256 amount = 1 ether;
        SwapParams memory params = _exactInputZeroForOne(amount);

        // Quote the stable post-launch fee (lens returns the total fee bps and the protocol portion
        // amount in the input currency).
        IMemeverseUniswapHook.SwapQuote memory quote =
            lens.quoteSwap(IMemeverseUniswapHook(address(hook)), key, params, address(this));
        uint256 protocolFeeAmount = quote.estimatedProtocolFeeAmount;

        // rebate = protocolFee × rebateBps / PROTOCOL_FEE_SHARE_BPS = protocolFee × 1000/3500
        // treasury = protocolFee − rebate
        uint256 expectedRebate = FullMath.mulDiv(protocolFeeAmount, 1000, FeeMath.PROTOCOL_FEE_SHARE_BPS);
        uint256 expectedTreasuryDelta = protocolFeeAmount - expectedRebate;

        uint256 treasuryBefore = _balanceOf(key.currency0, treasury);
        hook.beginAccountSession();
        integrator.swap(key, params, address(this), _packReferrer(REFERRER));
        hook.endAccountSession();

        assertApproxEqAbs(engine.pendingRebateOf(REFERRER, key.currency0), expectedRebate, 2, "rebate ~= 10%");
        assertApproxEqAbs(
            _balanceOf(key.currency0, treasury) - treasuryBefore, expectedTreasuryDelta, 2, "treasury ~= 25%"
        );
    }

    // -------------------------------------------------------------------------
    // Rebate solvency postcondition
    // -------------------------------------------------------------------------

    /// @notice After each successful swap, the hook's balance in the rebate currency covers total pending rebates.
    /// @dev This checks committed post-swap state only; it does not assert an in-call balance relationship.
    function testInvariant_EngineHoldsAtLeastAllPendingRebates() external {
        address r2 = address(0xBEEF);

        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();

        uint256 firstPending = engine.pendingRebateOf(REFERRER, key.currency0);
        assertGe(_balanceOf(key.currency0, address(engine)), firstPending, "first swap rebate solvency violated");

        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(r2));
        hook.endAccountSession();

        uint256 pending = engine.pendingRebateOf(REFERRER, key.currency0) + engine.pendingRebateOf(r2, key.currency0);
        assertGe(_balanceOf(key.currency0, address(engine)), pending, "second swap rebate solvency violated");
    }

    // -------------------------------------------------------------------------
    // Preorder settlement (negative regression): must NOT accrue referral rebate
    // -------------------------------------------------------------------------

    /// @notice Explicit preorder settlement routes fees through the preorder fee path
    ///         (`_collectPreorderSettlementInputFees`), never through `_collectProtocolFee`, so no
    ///         referrer rebate can accrue. This keeps preorder fee collection separate from the
    ///         public-swap fee path.
    /// @dev Mirrors the setup of `testExecutePreorderSettlement_UsesFixedOnePercentFee` in the
    ///      router suite: protocol fee currency is currency0, the test owns the launcher role, and
    ///      token0 is max-approved to the hook so settlement pulls the fixed 1% from this contract.
    ///      The price limit is the tight preorder bound (1% below SQRT_PRICE_1_1) used elsewhere.
    function testPreorderSettlement_DoesNotAccrueRebate() external {
        uint160 priceLimit = uint160((uint256(SQRT_PRICE_1_1) * 99) / 100);
        token0.approve(address(hook), type(uint256).max);

        // Sanity: a normal public swap with this referrer WOULD accrue rebate (the path this test guards).
        hook.beginAccountSession();
        integrator.swap(key, _exactInputZeroForOne(1 ether), address(this), _packReferrer(REFERRER));
        hook.endAccountSession();
        uint256 accruedFromPublicSwap = engine.pendingRebateOf(REFERRER, key.currency0);
        assertGt(accruedFromPublicSwap, 0, "public swap accrues rebate");

        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: key,
                params: SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: priceLimit}),
                recipient: address(this)
            })
        );

        // Preorder settlement must not add anything to the referrer's ledger.
        assertEq(
            engine.pendingRebateOf(REFERRER, key.currency0),
            accruedFromPublicSwap,
            "preorder settlement accrues no rebate"
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Exact-input swap of `amount` token0 → token1 (zeroForOne). Input-side protocol fee
    ///      (currency0) is enabled in `setUp`, so rebate accrues in token0. The price limit is the
    ///      tight bound used by the integration suite — 0 is rejected by PoolManager validation.
    function _exactInputZeroForOne(uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _balanceOf(Currency currency, address account) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    /// @dev Packs the referrer as the first 20 bytes of hookData, matching the hook's
    ///      `_decodeReferrer` (`address(bytes20(hookData[:20]))`). `abi.encode` would left-pad
    ///      the address and place it in bytes 12..31, decoding to address(0).
    function _packReferrer(address referrer) internal pure returns (bytes memory) {
        return abi.encodePacked(referrer);
    }
}
