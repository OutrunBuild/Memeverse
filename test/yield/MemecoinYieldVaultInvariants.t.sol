// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MemecoinYieldVault} from "src/yield/MemecoinYieldVault.sol";
import {MockComposeAsset} from "test/mocks/yield/YieldMocks.sol";

/// @title YieldVaultHandler
/// @notice Ghost-accounted operations for the vault invariant suite.
/// @dev Ghost ledger:
///      - ghostAssetsIn[a]      assets pulled from a (deposit + mint cost)
///      - ghostPayoutsOut[a]    assets paid back to a (redeem + withdraw)
///      - ghostYieldCredit[a]   damped yield share credited while holding:
///                              y * balance(a) / (totalSupply + V) per credited yield
///      - ghostValueGift[a]     exact measured share-value growth while holding,
///                              accrued on foreign deposit/mint/requestRedeem ops
///                              (floor-dust gifts can reach ~rate weis, so they are
///                              measured, not bounded per op)
///      - ghostQueuePushedLocked / ghostQueuePaid track the queue: the contract's
///        Σ entry.lockedAssets equals pushed - paid exactly (lockstep decrements,
///        entries only pop at locked == 0)
///      The sentinel observer is bound at construction (an `address` parameter would
///      let the fuzzer substitute arbitrary observers and break value-monotonicity tracking).
///      Some properties are asserted inside op bodies (pre/post snapshots) because the
///      state they observe only exists transiently.
contract YieldVaultHandler is Test {
    MemecoinYieldVault public vault;
    MockComposeAsset public asset;
    address public immutable sentinel;

    address[3] public actors;
    address public yieldActor; // dedicated: only calls accumulateYields
    address public donor; // dedicated: only does direct ERC20 transfers

    mapping(address => uint256) public ghostAssetsIn;
    mapping(address => uint256) public ghostPayoutsOut;
    mapping(address => uint256) public ghostYieldCredit;
    mapping(address => uint256) public ghostValueGift;
    uint256 public ghostQueuePushedLocked;
    uint256 public ghostQueuePaid;
    uint256 public ghostRateUnitBeforeLastDonation;
    uint256 public ghostRateUnitAfterLastDonation;

    uint256 internal constant ACTORS = 3;
    uint256 internal constant UINT208_MAX = type(uint208).max;
    uint256 internal constant REDEEM_DELAY = 1 days;

    constructor(MemecoinYieldVault _vault, MockComposeAsset _asset, address _sentinel) {
        vault = _vault;
        asset = _asset;
        sentinel = _sentinel;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("vaultActor", vm.toString(i)));
        }
        yieldActor = makeAddr("yieldActor");
        donor = makeAddr("donor");
    }

    // ---- shared helpers -----------------------------------------------------------

    /// @dev a fixed holder's share value never decreases across any handler op.
    ///      The pre-op value is captured at entry and asserted at exit — asserting at
    ///      entry against the previous exit's snapshot would compare a value to itself,
    ///      because only handler ops can change the value between checks.
    function _sentinelPreValue() internal view returns (uint256) {
        return _shareValue(sentinel);
    }

    function _assertSentinelNotDecreased(uint256 preValue) internal {
        assertGe(_shareValue(sentinel), preValue, "sentinel share value decreased");
    }

    function _shareValue(address who) internal view returns (uint256) {
        uint256 b = vault.balanceOf(who);
        if (b == 0) return 0;
        return Math.mulDiv(b, vault.totalAssets() + vault.virtualAssets(), vault.totalSupply() + vault.virtualAssets());
    }

    /// @dev Foreign-op value-growth accounting: a deposit/mint/requestRedeem
    ///      by `who` can raise other holders' per-share value by floor-dust — up to
    ///      ~rate weis for a dominant holder (Delta(b*r) < b*r/(S+s+V)), so the slack
    ///      must be measured exactly, not bounded by a per-op constant.
    function _chargeForeignGrowth(address who, uint256[3] memory valuesBefore) internal {
        for (uint256 i; i < ACTORS; ++i) {
            address a = actors[i];
            if (a == who) continue;
            uint256 valueNow = _shareValue(a);
            if (valueNow > valuesBefore[i]) ghostValueGift[a] += valueNow - valuesBefore[i];
        }
    }

    function _captureValues() internal view returns (uint256[3] memory values) {
        for (uint256 i; i < ACTORS; ++i) {
            values[i] = _shareValue(actors[i]);
        }
    }

    function _fund(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    // ---- actor operations ----------------------------------------------------------

    /// deposit side (floor rounding).
    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 sentinelPre = _sentinelPreValue();
        uint256 headroom = UINT208_MAX - vault.totalAssets();
        if (headroom == 0) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 amount = bound(amountSeed, 1, headroom);
        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        uint256[3] memory valuesBefore = _captureValues();
        _fund(who, amount);
        vm.startPrank(who);
        try vault.deposit(amount, who) returns (uint256 shares) {
            ghostAssetsIn[who] += amount;
            // a truly empty vault (S == 0 AND T == 0) mints exactly 1:1. A
            // residual state (S == 0, T > 0 after full exits) legitimately
            // mints fewer, richer shares — only the zero-share lockout is asserted there.
            if (supplyBefore == 0 && assetsBefore == 0) {
                assertEq(shares, amount, "empty-vault deposit not 1:1");
            } else {
                assertGt(shares, 0, "zero-share deposit");
            }
        } catch {}
        vm.stopPrank();
        _chargeForeignGrowth(who, valuesBefore);
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// mint side (ceil rounding); actor funded with the previewed cost.
    function mint(uint256 actorSeed, uint256 sharesSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 sentinelPre = _sentinelPreValue();
        uint256 headroom = UINT208_MAX - vault.totalAssets();
        if (headroom <= 1) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 shares = bound(sharesSeed, 1, headroom - 1); // ceil cost >= shares; keep 1 wei slack
        uint256 cost = vault.previewMint(shares);
        if (cost > headroom) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256[3] memory valuesBefore = _captureValues();
        _fund(who, cost);
        vm.startPrank(who);
        try vault.mint(shares, who) returns (uint256 assets) {
            ghostAssetsIn[who] += assets;
        } catch {}
        vm.stopPrank();
        _chargeForeignGrowth(who, valuesBefore);
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// burn shares into the redemption queue (floor lock pricing).
    function requestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 sentinelPre = _sentinelPreValue();
        uint256 balance = vault.balanceOf(who);
        if (balance == 0) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 shares = bound(sharesSeed, 1, balance);
        uint256[3] memory valuesBefore = _captureValues();
        vm.startPrank(who);
        try vault.requestRedeem(shares, who, who) returns (uint256 locked) {
            // Premise recorded at push time: rate >= 1 keeps locked >= shares,
            // which keeps per-entry floor payouts non-zero (lockstep decrements preserve it).
            assertGe(locked, shares, "locked below shares at push");
            ghostQueuePushedLocked += locked;
        } catch {}
        vm.stopPrank();
        _chargeForeignGrowth(who, valuesBefore);
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// Advance time past REDEEM_DELAY with jitter on both sides of the boundary.
    function warp(uint256 extra) external {
        vm.warp(block.timestamp + REDEEM_DELAY + bound(extra, 0, 3 days));
    }

    /// shares-first claim of matured entries.
    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 sentinelPre = _sentinelPreValue();
        uint256 claimable = vault.claimableRedeemRequest(who);
        if (claimable == 0) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 shares = bound(sharesSeed, 1, claimable);
        vm.startPrank(who);
        try vault.redeem(shares, who, who) returns (uint256 payout) {
            ghostPayoutsOut[who] += payout;
            ghostQueuePaid += payout;
        } catch {}
        vm.stopPrank();
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// assets-first claim; InsufficientClaimableRedeem is an expected floor
    /// granularity outcome and is swallowed, not a failure.
    function withdraw(uint256 actorSeed, uint256 assetsSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 sentinelPre = _sentinelPreValue();
        uint256 maxOut = vault.maxWithdraw(who);
        if (maxOut == 0) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 amount = bound(assetsSeed, 1, maxOut);
        vm.startPrank(who);
        try vault.withdraw(amount, who, who) returns (uint256) {
            ghostPayoutsOut[who] += amount;
            ghostQueuePaid += amount;
        } catch {}
        vm.stopPrank();
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// yield push — burned while the vault is empty, credited otherwise.
    function accumulateYields(uint256 yieldSeed) external {
        uint256 sentinelPre = _sentinelPreValue();
        uint256 headroom = UINT208_MAX - vault.totalAssets();
        if (headroom == 0) {
            _assertSentinelNotDecreased(sentinelPre);
            return;
        }
        uint256 amount = bound(yieldSeed, 1, Math.min(headroom, 1e30));
        uint256[3] memory valuesBefore = _captureValues();
        _fund(yieldActor, amount);
        vm.startPrank(yieldActor);
        try vault.accumulateYields(amount) {
            // exact per-holder value growth from the credited yield. An empty
            // vault burns the yield instead, so no growth is measured there.
            for (uint256 i; i < ACTORS; ++i) {
                address a = actors[i];
                uint256 valueNow = _shareValue(a);
                if (valueNow > valuesBefore[i]) ghostYieldCredit[a] += valueNow - valuesBefore[i];
            }
        } catch {}
        vm.stopPrank();
        _assertSentinelNotDecreased(sentinelPre);
    }

    /// a direct ERC20 donation must not move accounting-based pricing. Both
    /// snapshots are frozen in ghosts and compared by the invariant function (other ops
    /// may legitimately change the rate between donation and check).
    function directTransferDonation(uint256 amountSeed) external {
        uint256 sentinelPre = _sentinelPreValue();
        uint256 amount = bound(amountSeed, 1, 1e30);
        ghostRateUnitBeforeLastDonation = vault.convertToShares(1e18);
        asset.mint(donor, amount);
        vm.prank(donor);
        asset.transfer(address(vault), amount);
        ghostRateUnitAfterLastDonation = vault.convertToShares(1e18);
        _assertSentinelNotDecreased(sentinelPre);
    }
}

/// @title MemecoinYieldVaultInvariants
/// @notice Stateful and single-sequence properties for MemecoinYieldVault.
/// @dev Not duplicated from the existing suite: previewDeposit floor fuzz
///      (testFuzz_PreviewDepositUsesFloor) and the uint208/uint192 domain-guard revert
///      tests already cover those angles.
contract MemecoinYieldVaultInvariants is StdInvariant, Test {
    MemecoinYieldVault internal vault;
    MockComposeAsset internal asset;
    YieldVaultHandler internal handler;

    // Fixed holder that never transacts — observes value monotonicity.
    address internal sentinel;

    uint256 internal constant VIRTUAL_ASSETS = 1e24; // production-scale buffer keeps the value-growth property meaningful

    function setUp() external {
        asset = new MockComposeAsset();
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(implementation)));
        vault.initialize("Test Vault", "TVLT", address(asset), 1, VIRTUAL_ASSETS);

        sentinel = makeAddr("sentinel");
        asset.mint(sentinel, 1e24);
        vm.startPrank(sentinel);
        asset.approve(address(vault), 1e24);
        vault.deposit(1e24, sentinel);
        vm.stopPrank();

        handler = new YieldVaultHandler(vault, asset, sentinel);
        targetContract(address(handler));
    }

    /// totalSupply() <= totalAssets() in every reachable state (rate >= 1 is
    /// the premise for the lockstep bound and redeem's non-zero payout guard).
    function invariant_supplyNeverExceedsAssets() external view {
        assertLe(vault.totalSupply(), vault.totalAssets(), "supply must not exceed assets");
    }

    /// the frozen before/after snapshots around a direct ERC20 donation are
    /// identical (donations bypass totalAssets, so pricing cannot see them).
    function invariant_directDonationDoesNotChangeRate() external view {
        assertEq(
            handler.ghostRateUnitBeforeLastDonation(),
            handler.ghostRateUnitAfterLastDonation(),
            "donation moved the rate"
        );
    }

    /// no actor receives more than paid in plus their exactly-measured
    /// share-value growth while holding — from credited yield events and from foreign
    /// deposit/mint/requestRedeem floor dust. (The V-damped tight bound lives in
    /// testFuzz_PostDepositDonationProfitBounded; this is the sequential form.)
    function invariant_noActorRedeemsMoreThanPaidPlusObservedGrowth() external view {
        for (uint256 i; i < 3; ++i) {
            address a = handler.actors(i);
            assertLe(
                handler.ghostPayoutsOut(a),
                handler.ghostAssetsIn(a) + handler.ghostYieldCredit(a) + handler.ghostValueGift(a),
                "payout above damped bound"
            );
        }
    }

    /// solvency — holdings cover accounting plus every queued lock. The
    /// contract's queue total equals ghostPushed - ghostPaid exactly (lockstep
    /// decrements; entries pop only at locked == 0).
    function invariant_holdingsCoverAccountingPlusQueue() external view {
        uint256 queueLive = handler.ghostQueuePushedLocked() - handler.ghostQueuePaid();
        assertGe(
            asset.balanceOf(address(vault)), vault.totalAssets() + queueLive, "holdings below accounting plus queue"
        );
    }

    // ---- standalone single-sequence fuzz properties ----

    /// yield pushed to an empty vault is burned, never credited — the
    /// pre-deposit donation attack stays inert. (Stateful-suite note: the sentinel's
    /// permanent deposit keeps totalSupply() > 0 there, so this property lives here;
    /// example-level coverage also exists in MemecoinYieldVault.t.sol.)
    function testFuzz_EmptyVaultYieldBurnedNotCredited(uint96 y) external {
        y = uint96(bound(y, 1, type(uint96).max));
        MemecoinYieldVault v = _freshVault();
        asset.mint(address(this), y);
        vm.startPrank(address(this));
        asset.approve(address(v), y);
        v.accumulateYields(y);
        vm.stopPrank();
        assertEq(v.totalAssets(), 0, "empty vault credited yield");
        assertEq(v.totalSupply(), 0);
        assertEq(asset.balanceOf(address(v)), 0, "yield not burned");
    }

    /// on a fresh vault, deposit is exactly 1:1 and chained mints stay exactly
    /// 1:1 while S == T (rate pinned at 1 by the symmetric +V buffer).
    function testFuzz_EmptyVaultDepositMintExact(uint96 amount, uint96 mintShares) external {
        amount = uint96(bound(amount, 1, type(uint96).max));
        mintShares = uint96(bound(mintShares, 1, type(uint96).max));
        MemecoinYieldVault v = _freshVault();
        asset.mint(address(this), uint256(amount) + mintShares);
        vm.startPrank(address(this));
        asset.approve(address(v), type(uint256).max);
        assertEq(v.deposit(amount, address(this)), amount, "first deposit not 1:1");
        assertEq(v.mint(mintShares, address(this)), mintShares, "chained mint not 1:1 while S==T");
        assertEq(v.totalSupply(), uint256(amount) + mintShares);
        assertEq(v.totalAssets(), uint256(amount) + mintShares);
        vm.stopPrank();
    }

    /// single-attacker donation profit bound. After deposit(d) -> yield(y),
    /// the full-exit lock is floor(d*(d+y+V)/(d+V)) so profit = lock - d <= d*y/(d+V).
    function testFuzz_PostDepositDonationProfitBounded(uint96 d, uint96 y) external {
        d = uint96(bound(d, 1, type(uint96).max));
        y = uint96(bound(y, 1, type(uint96).max));
        MemecoinYieldVault v = _freshVault();
        uint256 vv = v.virtualAssets();
        asset.mint(address(this), uint256(d) + y);
        vm.startPrank(address(this));
        asset.approve(address(v), type(uint256).max);
        v.deposit(d, address(this)); // S = T = d
        v.accumulateYields(y); // T = d + y
        uint256 locked = v.requestRedeem(d, address(this), address(this));
        assertGe(locked, d, "rate < 1 would underflow the profit bound");
        assertLe(locked - d, Math.mulDiv(y, d, d + vv), "donation profit exceeds V-damped bound");
        vm.stopPrank();
    }

    /// Rounding directions (incremental half — previewDeposit floor already covered elsewhere):
    /// the mint cost is the exact ceil and the requestRedeem lock the exact floor of
    /// the same rate, asserted by bracketing inequalities rather than re-derivation.
    function testFuzz_MintCeilAndRedeemLockRounding(
        uint96 depositAmount,
        uint96 mintShares,
        uint96 redeemShares,
        uint96 yieldAmount
    ) external {
        depositAmount = uint96(bound(depositAmount, 1, type(uint96).max));
        mintShares = uint96(bound(mintShares, 1, type(uint96).max));
        yieldAmount = uint96(bound(yieldAmount, 1, type(uint96).max));
        MemecoinYieldVault v = _freshVault();
        asset.mint(address(this), uint256(depositAmount) + yieldAmount);
        vm.startPrank(address(this));
        asset.approve(address(v), type(uint256).max);
        v.deposit(depositAmount, address(this));
        // Push the rate above 1: at rate exactly 1 floor and ceil coincide, and the
        // bracketing assertions below would degenerate to identities.
        v.accumulateYields(yieldAmount);
        // The ceil cost can exceed mintShares by ~rate; fund it exactly via preview.
        asset.mint(address(this), v.previewMint(mintShares));
        uint256 supplyBeforeMint = v.totalSupply();
        uint256 assetsBeforeMint = v.totalAssets();
        uint256 cost = v.mint(mintShares, address(this));
        // ceil: cost * (S+V) >= s * (T+V), priced against the pre-mint state.
        assertGe(
            Math.mulDiv(cost, supplyBeforeMint + v.virtualAssets(), 1),
            Math.mulDiv(mintShares, assetsBeforeMint + v.virtualAssets(), 1),
            "mint cost below exact pro-rata (ceil violated)"
        );
        redeemShares = uint96(bound(redeemShares, 1, v.balanceOf(address(this))));
        // Capture the rate state BEFORE requestRedeem: it burns the shares and deducts
        // totalAssets at call time, so the lock is priced against this pre-call state.
        uint256 sPlusV = v.totalSupply() + v.virtualAssets();
        uint256 tPlusV = v.totalAssets() + v.virtualAssets();
        uint256 lock = v.requestRedeem(redeemShares, address(this), address(this));
        // floor bracket: lock*(S+V) <= s*(T+V) < (lock+1)*(S+V)
        assertLe(Math.mulDiv(lock, sPlusV, 1), Math.mulDiv(redeemShares, tPlusV, 1), "lock above floor");
        assertLt(
            Math.mulDiv(redeemShares, tPlusV, 1), Math.mulDiv(lock + 1, sPlusV, 1), "lock below floor (one-wei under)"
        );
        vm.stopPrank();
    }

    // ---- fixture ----

    function _freshVault() internal returns (MemecoinYieldVault v) {
        MemecoinYieldVault implementation = new MemecoinYieldVault();
        v = MemecoinYieldVault(Clones.clone(address(implementation)));
        v.initialize("Fresh", "FRSH", address(asset), 1, VIRTUAL_ASSETS);
    }
}
