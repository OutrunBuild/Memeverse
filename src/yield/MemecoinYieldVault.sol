// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {OutrunNoncesInit} from "../common/token/OutrunNoncesInit.sol";
import {IMemecoinYieldVault} from "./interfaces/IMemecoinYieldVault.sol";
import {ISettleCompose} from "../common/omnichain/ISettleCompose.sol";
import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OutrunERC20PermitInit} from "../common/token/OutrunERC20PermitInit.sol";
import {OutrunERC20Init, OutrunERC20VotesInit} from "../common/token/extensions/governance/OutrunERC20VotesInit.sol";

/**
 * @dev Single-source planner for the vault's assets-first claim scan. `withdraw` (state-changing) and
 *      `isWithdrawReachable` (view-only) both run `plan`, so the reachability verdict and the actual
 *      claim can never drift apart. Lives outside the contract because the planner mutates only the
 *      passed memory arrays and needs no vault storage.
 */
library WithdrawPlanner {
    /// @dev Upper bound on redeem-queue entries a plan can cover; mirrors the vault's public
    ///      `MAX_REDEEM_REQUESTS` (enforced at enqueue time in `_requestWithdraw`). Both must stay
    ///      equal: the compiler only accepts file-local literal constants as fixed-array lengths, so
    ///      the two declarations cannot reference each other.
    uint256 public constant MAX_REDEEM_REQUESTS = 5;

    /// @dev Maturity delay a redeem request must age before its locked assets become claimable; the
    ///      vault re-exports the same value as its public `REDEEM_DELAY` constant.
    uint256 public constant REDEEM_DELAY = 1 days;

    /// @dev Single source of the redeem-maturity predicate: a queued entry's locked assets become
    ///      claimable exactly when `REDEEM_DELAY` has fully elapsed since its request time (endpoint
    ///      inclusive). Every maturity consumer — this planner's scan, the vault's claim loop, and the
    ///      vault's maturity views — routes through this predicate so the boundary cannot drift
    ///      between the view family and the claim path.
    function _matured(uint64 requestTime) internal view returns (bool) {
        return block.timestamp >= uint256(requestTime) + REDEEM_DELAY;
    }

    /// @dev Plans the assets-first FIFO claim scan. Mutates the passed memory arrays in place:
    ///      matured entries are consumed in queue (FIFO) order — the scan index only moves forward
    ///      and swap-pop moves the tail entry into the current slot — with each entry contributing
    ///      the largest share count whose floor payout stays within the remaining target;
    ///      fully-consumed entries are compacted swap-pop style, so the arrays end in the exact
    ///      post-`withdraw` queue state (first `newLength` slots survive; slots at or past
    ///      `newLength` are stale). `queueLength` is the number of filled leading slots. Returns
    ///      whether `assets` was covered exactly, the shares the claim would burn, the unpaid
    ///      remainder, and the surviving queue length.
    function plan(
        uint256[MAX_REDEEM_REQUESTS] memory shares,
        uint192[MAX_REDEEM_REQUESTS] memory lockedAssets,
        uint64[MAX_REDEEM_REQUESTS] memory requestTimes,
        uint256 queueLength,
        uint256 assets
    ) internal view returns (bool ok, uint256 totalShares, uint256 remainingAssets, uint256 newLength) {
        uint256 len = queueLength;
        remainingAssets = assets;
        uint256 j = 0;
        while (j < len && remainingAssets > 0) {
            if (!_matured(requestTimes[j])) {
                unchecked {
                    ++j;
                }
                continue;
            }
            uint256 takeAssets = remainingAssets < lockedAssets[j] ? remainingAssets : uint256(lockedAssets[j]);
            // Largest share count whose floor payout stays <= takeAssets (assets-first inverse of the lock rate).
            // Computed as ceil((T+1)·S/L) − 1 = floor(((T+1)·S − 1)/L): the exact largest s with floor(s·L/S) <= T.
            // The naive floor(T·S/L) under-counts by one at rounding edges and spuriously reverts reachable targets.
            // The −1 is load-bearing: without it, ceil over-counts when (T+1)·S is an exact multiple of L, which
            // would make the payout exceed takeAssets and strand the scan (underflow on the remainder decrement).
            uint256 takeShares =
                Math.mulDiv(takeAssets + 1, shares[j], uint256(lockedAssets[j]), Math.Rounding.Ceil) - 1;
            if (takeShares == 0) {
                // Rounding leaves too few shares to cover 1 unit of payout here; try the next matured entry.
                unchecked {
                    ++j;
                }
                continue;
            }
            uint256 payout = Math.mulDiv(takeShares, uint256(lockedAssets[j]), shares[j]);
            shares[j] -= takeShares;
            lockedAssets[j] -= uint192(payout);
            remainingAssets -= payout;
            totalShares += takeShares;
            if (shares[j] == 0) {
                if (j != len - 1) {
                    lockedAssets[j] = lockedAssets[len - 1];
                    shares[j] = shares[len - 1];
                    requestTimes[j] = requestTimes[len - 1];
                }
                --len;
            } else {
                unchecked {
                    ++j;
                }
            }
        }
        return (remainingAssets == 0, totalShares, remainingAssets, len);
    }
}

/**
 * @dev Memecoin Yield Vault
 */
contract MemecoinYieldVault is IMemecoinYieldVault, OutrunERC20PermitInit, OutrunERC20VotesInit {
    using OutrunSafeERC20 for IERC20;

    // Queue bound and maturity delay mirror the planner library: REDEEM_DELAY re-exports the
    // library's value (single numeric source), while MAX_REDEEM_REQUESTS must stay a literal here —
    // the compiler rejects cross-contract constants as fixed-array lengths (see WithdrawPlanner).
    uint256 public constant MAX_REDEEM_REQUESTS = 5;
    uint256 public constant REDEEM_DELAY = WithdrawPlanner.REDEEM_DELAY; // Preventing flash attacks

    address public asset;
    /// @dev Total managed assets. Implicit upper bound type(uint208).max: the governance asset checkpoint stores
    ///      uint208 (OutrunVotesInit), so the TotalAssetsOverflowed require in _accumulateYield/_deposit keeps it
    ///      representable — practically unreachable given the launcher-gated memecoin supply. Residual boundary: a
    ///      single increment of 2^256 − totalAssets or more panics at the checked addition before the require runs
    ///      (Panic(0x11)), so TotalAssetsOverflowed covers overshoots below that threshold only; the gap is ~48
    ///      orders of magnitude beyond the 2^208 bound and unreachable, documented so error-name monitoring knows
    ///      the boundary.
    uint256 public totalAssets;
    /// @dev Permanent virtual buffer used by the share/asset conversion helpers. Set once at
    ///      initialization; sized by the launcher at 1% of the minimum main-pool memecoin provision
    ///      (equivalently 0.7% of the minimum fund-based memecoin amount `minTotalFund * fundBasedAmount`;
    ///      the main pool receives 70% of genesis funds).
    uint256 public virtualAssets;

    mapping(address account => RedeemRequestEntry[]) public redeemRequestQueues;

    /// @inheritdoc IMemecoinYieldVault
    /// @dev Reverts `ZeroVirtualAssets` when the buffer is zero — the `+virtualAssets` conversion guards
    ///      can never divide by zero and actually dampen the rate — and `ZeroAddress` for a zero asset.
    function initialize(string calldata _name, string calldata _symbol, address _asset, uint256 _virtualAssets)
        external
        override
        initializer
    {
        require(_virtualAssets > 0, ZeroVirtualAssets());
        require(_asset != address(0), ZeroAddress());

        __OutrunERC20_init(_name, _symbol);
        __OutrunERC20Permit_init(_name);

        asset = _asset;
        virtualAssets = _virtualAssets;
    }

    /// @notice Exposes the timepoint source used by the votes extension.
    /// @dev Matches the votes-base default (timestamp clock); kept as an explicit pin so a future base-class
    ///      clock-domain change surfaces at the vault instead of silently shifting its checkpoint domain.
    /// @return Current timestamp cast into the ERC-6372 clock domain.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    /// @notice Exposes the ERC-6372 clock mode string.
    /// @dev Deliberately bypasses the base's clock-consistency guard (pure, no live `clock()` comparison)
    ///      while pinning the advertised mode to the vault's fixed timestamp domain.
    /// @return Clock mode descriptor.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, totalAssets);
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewRedeem(uint256) external pure override returns (uint256) {
        revert PreviewRedeemNotSupported();
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev `previewDeposit` is the only current-rate preview; `previewRedeem` always reverts because
    ///      claims use per-entry locked rates a single current rate cannot represent.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, totalAssets);
    }

    /// @inheritdoc IMemecoinYieldVault
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, totalAssets);
    }

    /// @inheritdoc IMemecoinYieldVault
    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IMemecoinYieldVault
    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IMemecoinYieldVault
    function maxWithdraw(address owner) external view override returns (uint256) {
        RedeemRequestEntry[] storage queue = redeemRequestQueues[owner];
        uint256 total;
        // Read-only scan: queue is not mutated here, so caching length once saves the per-iteration storage read.
        uint256 queueLength = queue.length;
        for (uint256 i = 0; i < queueLength; ++i) {
            // Only entries past REDEEM_DELAY are claimable; immature ones remain pending.
            if (WithdrawPlanner._matured(queue[i].requestTime)) {
                total += queue[i].lockedAssets;
            }
        }
        return total;
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev Delegates to `WithdrawPlanner.plan`, the single-source simulation of `withdraw`'s FIFO scan
    ///      with swap-pop compaction, so the reachability result matches the state-changing call exactly.
    function isWithdrawReachable(address owner, uint256 assets) external view override returns (bool ok) {
        if (assets == 0) return false;
        RedeemRequestEntry[] storage queue = redeemRequestQueues[owner];
        if (queue.length == 0) return false;
        // Copy to memory to simulate swap-pop without mutating storage; the scratch arrays are
        // length-bound to the enqueue-time queue cap (see _loadQueue).
        (
            uint256[MAX_REDEEM_REQUESTS] memory shares,
            uint192[MAX_REDEEM_REQUESTS] memory lockedAssets,
            uint64[MAX_REDEEM_REQUESTS] memory requestTimes,
            uint256 queueLength
        ) = _loadQueue(queue);
        (ok,,,) = WithdrawPlanner.plan(shares, lockedAssets, requestTimes, queueLength, assets);
    }

    /// @inheritdoc IMemecoinYieldVault
    function maxRedeem(address owner) external view override returns (uint256) {
        return _claimableShares(owner);
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssetsCeil(shares, totalAssets);
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewWithdraw(uint256) external pure override returns (uint256) {
        revert PreviewWithdrawNotSupported();
    }

    /// @notice Pulls new yield into the vault and updates share pricing.
    /// @dev Burns the supplied yield if no shares exist yet, preventing the first depositor from capturing it.
    /// @param yield Amount of underlying asset contributed as yield.
    function accumulateYields(uint256 yield) external override {
        address msgSender = msg.sender;
        IERC20(asset).safeTransferFrom(msgSender, address(this), yield);
        _accumulateYield(msgSender, yield);
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev `settlePendingCompose` settles by approving this vault and calling `accumulateYields` (pull +
    ///      totalAssets accounting) in one step, re-deriving delivery against
    ///      `composeQueue(token, dispatcher, guid, 0)`. A no-code `dispatcher` (EOA/empty contract) is not
    ///      pre-checked: the high-level call succeeds with empty returdata, so the strict `abi.decode` of the
    ///      uint256 return reverts with EMPTY revert data — no named error, and error-name monitoring must not
    ///      expect `ComposeSettlementFailed` for this class (verify the address was sourced from the
    ///      endpoint's `ComposeSent` event `to` field).
    function reAccumulateYields(address dispatcher, bytes32 guid, bytes calldata message) external override {
        // The compose's beneficiary is fixed by the message (hash-bound to the guid by the endpoint queue), so only
        // a message whose inner receiver is this vault can settle yield into this vault. The receiver word sits at
        // [76:108] — OFTComposeMsgCodec's COMPOSE_FROM_OFFSET plus the first word of the (address, TokenType) tuple
        // (the offsets YieldDispatcherUpgradeable parses in _parseCompose). A message shorter than 108 bytes cannot carry the
        // word and can never settle (verifySettle needs the full header and the tuple needs 64 more bytes), so it
        // fails here with a named error before reaching the dispatcher.
        require(message.length >= 108, ComposeMessageTooShort());
        // Note: the uint160 downcast truncates a dirty-high-bit receiver word, so a self-forged word whose low 160 bits
        // are this vault passes this gate and then reverts inside the dispatcher (frames >= 140 bytes at its strict
        // abi.decode with an opaque empty-data revert; the 108-139-byte band at its named MalformedComposeMsg guard).
        // Either way there is no settlement, the slot stays None, and error-name monitoring must not expect
        // NotComposeBeneficiary for this class.
        require(address(uint160(uint256(bytes32(message[76:108])))) == address(this), NotComposeBeneficiary());

        // No separate local accounting step — settlePendingCompose handles pull + totalAssets in one call. The
        // declared return is asserted non-zero: a genuine settle always releases the payload's non-zero amount
        // (the dispatcher rejects zero-amount payloads with ZeroInput), so a zero return means the dispatcher
        // claimed success without settling anything.
        uint256 amount = ISettleCompose(dispatcher).settlePendingCompose(asset, guid, message);
        require(amount != 0, ComposeSettlementFailed());
    }

    function _accumulateYield(address yieldSource, uint256 yield) internal {
        // Zero-yield call carries no value; return early so totalAssets and checkpoints stay unchanged
        // (historical queries keep returning the prior value via upperLookupRecent).
        if (yield == 0) return;
        // Empty-vault yield would otherwise create unowned value for the next depositor, so the asset is burned instead.
        if (totalSupply() == 0) {
            IMemecoin(asset).burn(yield);
        } else {
            totalAssets += yield;

            // The governance asset checkpoint stores uint208; revert with a named error instead of SafeCast's
            // SafeCastOverflowedUintDowncast revert if the bound is ever crossed (defense-in-depth, see totalAssets NatSpec).
            require(totalAssets <= type(uint208).max, TotalAssetsOverflowed(totalAssets));

            _writeTotalAssetCheckpoint(totalAssets);

            emit AccumulateYields(yieldSource, yield, _convertToAssets(1e18, totalAssets));
        }
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev Share minting uses the current `totalAssets` exchange rate before the new deposit is added.
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        // Zero-asset deposit carries no value; returning early avoids redundant transfers, mint, and
        // checkpoint writes. Preserves the ERC-4626 round-trip: previewDeposit(0) == deposit(0) == 0.
        if (assets == 0) return 0;
        uint256 shares = _convertToShares(assets, totalAssets);
        // A non-zero deposit that rounds down to 0 shares would silently absorb the caller's assets
        // (transfer in, zero shares minted, no redemption path). Revert so the caller can top up;
        // mirrors Solmate ERC4626's ZERO_SHARES guard.
        if (shares == 0) revert ZeroSharesDeposit();
        _deposit(msg.sender, receiver, assets, shares);
        _writeTotalAssetCheckpoint(totalAssets);

        return shares;
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev Reuses `_deposit` (pull + mint + uint208 guard + Deposit event) and writes the `totalAssets`
    ///      checkpoint so the paired governance invariant holds.
    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        // Zero-share mint carries no value; returning early avoids redundant transfers, mint, and
        // checkpoint writes. Preserves the ERC-4626 round-trip: previewMint(0) == mint(0) == 0.
        if (shares == 0) return 0;
        // Ceil the asset pull so the vault is never short-changed: the caller pays one wei more rather
        // than one wei less. virtualAssets is non-zero from initialize, so assets > 0 whenever shares > 0.
        assets = _convertToAssetsCeil(shares, totalAssets);
        _deposit(msg.sender, receiver, assets, shares);
        _writeTotalAssetCheckpoint(totalAssets);

        return assets;
    }

    /// @inheritdoc IMemecoinYieldVault
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        override
        returns (uint256 lockedAssets)
    {
        // controller == owner == msg.sender: no operator path, no filling another account's queue.
        require(controller == msg.sender && owner == msg.sender, NotSelfRedemption());
        // shares > 0 implies lockedAssets > 0 via the rate>=1 invariant (totalAssets >= totalSupply, maintained
        // by deposit/mint/yield), so the historical zero-asset guard stays unreachable here. Re-audit if that
        // invariant is ever relaxed.
        require(shares > 0, ZeroRedeemRequest());

        // Lock the asset value at request time; this amount is frozen and no longer earns yield.
        lockedAssets = _convertToAssets(shares, totalAssets);
        require(lockedAssets <= type(uint192).max, RedeemAmountOverflowed(lockedAssets));

        _requestWithdraw(owner, lockedAssets, shares);

        emit RedeemRequest(controller, owner, msg.sender, shares, lockedAssets);

        return lockedAssets;
    }

    /// @inheritdoc IMemecoinYieldVault
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        require(owner == msg.sender, NotSelfRedemption());
        require(shares > 0, ZeroRedeemRequest());

        RedeemRequestEntry[] storage requestQueue = redeemRequestQueues[msg.sender];
        uint256 remaining = shares;
        uint256 totalPayout;

        uint256 i = 0;
        // Length is re-read each pass on purpose: the swap-pop compaction below pops requestQueue and
        // shrinks it, so caching length once would let i overrun the array after a pop.
        // solhint-disable-next-line gas-length-in-loops
        while (i < requestQueue.length && remaining > 0) {
            RedeemRequestEntry storage entry = requestQueue[i];
            // Skip entries still inside the REDEEM_DELAY maturity window.
            if (!WithdrawPlanner._matured(entry.requestTime)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 take = remaining < entry.shares ? remaining : entry.shares;
            // Floor payout at this entry's own locked rate so a partial claim never over-pays.
            uint256 payout = Math.mulDiv(take, entry.lockedAssets, entry.shares);
            if (payout == 0) {
                // take > 0 but the floor payout rounds to 0. Under the maintained totalAssets >=
                // totalSupply invariant (per-entry lockedAssets >= shares, see requestRedeem) this path
                // is currently unreachable: payout = floor(take * lockedAssets / shares) >= take >= 1.
                // Retained as a forward guard — re-audit if the rate>=1 invariant is ever relaxed. It
                // does NOT mirror withdraw's takeShares==0 guard: withdraw is assets-first, so a tiny
                // asset target against a high per-share locked rate can legitimately round to 0 shares,
                // whereas this shares-first path cannot while lockedAssets >= shares. Skip without
                // consuming this entry's shares so a later claim can still recover the locked assets.
                unchecked {
                    ++i;
                }
                continue;
            }
            // Decrement shares and lockedAssets in lockstep so later claims stay rate-correct.
            entry.shares -= take;
            entry.lockedAssets -= uint192(payout);
            remaining -= take;
            totalPayout += payout;

            if (entry.shares == 0) {
                // Fully consumed: swap-pop compaction. Do not advance i — re-examine the swapped-in tail.
                if (i != requestQueue.length - 1) {
                    requestQueue[i] = requestQueue[requestQueue.length - 1];
                }
                requestQueue.pop();
            } else {
                unchecked {
                    ++i;
                }
            }
        }

        require(remaining == 0, InsufficientClaimableRedeem(shares - remaining));

        IERC20(asset).safeTransfer(receiver, totalPayout);

        emit Withdraw(msg.sender, receiver, owner, totalPayout, shares);

        return totalPayout;
    }

    /// @inheritdoc IMemecoinYieldVault
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        require(owner == msg.sender, NotSelfRedemption());
        require(assets > 0, ZeroRedeemRequest());

        RedeemRequestEntry[] storage requestQueue = redeemRequestQueues[msg.sender];
        // Copy the bounded queue to memory (see _loadQueue), plan the take sequence off-storage, then
        // write the planned end state back in one pass — same scan math as `isWithdrawReachable`
        // because both share `WithdrawPlanner.plan`.
        (
            uint256[MAX_REDEEM_REQUESTS] memory shares,
            uint192[MAX_REDEEM_REQUESTS] memory lockedAssets,
            uint64[MAX_REDEEM_REQUESTS] memory requestTimes,
            uint256 queueLength
        ) = _loadQueue(requestQueue);
        (bool ok, uint256 totalShares, uint256 remainingAssets, uint256 newLength) =
            WithdrawPlanner.plan(shares, lockedAssets, requestTimes, queueLength, assets);

        // Floor loss can leave a sub-unit remainder that no entry can satisfy exactly; revert, do not under-pay.
        require(ok, InsufficientClaimableRedeem(assets - remainingAssets));

        for (uint256 i = 0; i < newLength; ++i) {
            requestQueue[i] =
                RedeemRequestEntry({lockedAssets: lockedAssets[i], requestTime: requestTimes[i], shares: shares[i]});
        }
        // Fully-consumed tail entries are gone from the plan; shrink the storage queue to match.
        while (queueLength > newLength) {
            requestQueue.pop();
            --queueLength;
        }

        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, totalShares);

        return totalShares;
    }

    /// @inheritdoc IMemecoinYieldVault
    function pendingRedeemRequest(address controller) external view override returns (uint256 shares) {
        RedeemRequestEntry[] storage queue = redeemRequestQueues[controller];
        // Read-only scan: queue is not mutated here, so caching length once saves the per-iteration storage read.
        uint256 queueLength = queue.length;
        for (uint256 i = 0; i < queueLength; ++i) {
            if (!WithdrawPlanner._matured(queue[i].requestTime)) {
                shares += queue[i].shares;
            }
        }
    }

    /// @inheritdoc IMemecoinYieldVault
    function claimableRedeemRequest(address controller) external view override returns (uint256 shares) {
        return _claimableShares(controller);
    }

    /// @dev Copies the bounded redeem queue into the fixed-size memory scratch arrays the shared
    ///      planner runs on. The array lengths are the `MAX_REDEEM_REQUESTS` literal — the enqueue-time
    ///      queue bound — because the compiler only accepts file-local literals as fixed-array lengths:
    ///      if the bound ever changes, these lengths and the planner's must change with it. Slots at
    ///      or past `queueLength` are left zeroed and never read by the plan.
    function _loadQueue(RedeemRequestEntry[] storage queue)
        internal
        view
        returns (
            uint256[MAX_REDEEM_REQUESTS] memory shares,
            uint192[MAX_REDEEM_REQUESTS] memory lockedAssets,
            uint64[MAX_REDEEM_REQUESTS] memory requestTimes,
            uint256 queueLength
        )
    {
        queueLength = queue.length;
        for (uint256 i = 0; i < queueLength; ++i) {
            RedeemRequestEntry storage entry = queue[i];
            shares[i] = entry.shares;
            lockedAssets[i] = entry.lockedAssets;
            requestTimes[i] = entry.requestTime;
        }
    }

    /// @dev Shared matured-share sum used by `claimableRedeemRequest` and `maxRedeem`. Sums shares of
    ///      entries whose `requestTime + REDEEM_DELAY` has elapsed.
    function _claimableShares(address controller) internal view returns (uint256 total) {
        RedeemRequestEntry[] storage queue = redeemRequestQueues[controller];
        // Read-only scan: queue is not mutated here, so caching length once saves the per-iteration storage read.
        uint256 queueLength = queue.length;
        for (uint256 i = 0; i < queueLength; ++i) {
            if (WithdrawPlanner._matured(queue[i].requestTime)) {
                total += queue[i].shares;
            }
        }
    }

    /// @dev Burns `shares`, deducts `lockedAssets` from totalAssets (so the queued amount stops earning
    ///      yield immediately), writes the asset checkpoint, and enqueues the packed entry. Caller-side
    ///      checks (self-redemption, non-zero shares, uint192 cap) live in `requestRedeem`; the cap is
    ///      re-checked here as defense-in-depth.
    function _requestWithdraw(address owner, uint256 lockedAssets, uint256 shares) internal {
        uint256 requestCount = redeemRequestQueues[owner].length;
        require(requestCount < MAX_REDEEM_REQUESTS, MaxRedeemRequestsReached());
        require(lockedAssets <= type(uint192).max, RedeemAmountOverflowed(lockedAssets));

        _burn(owner, shares);
        // The queued asset amount stops participating in future yield immediately, so share price only reflects still-staked assets.
        totalAssets -= lockedAssets;
        _writeTotalAssetCheckpoint(totalAssets);
        redeemRequestQueues[owner].push(
            RedeemRequestEntry({
                lockedAssets: uint192(lockedAssets), requestTime: uint64(block.timestamp), shares: shares
            })
        );
    }

    function _convertToShares(uint256 assets, uint256 latestTotalAssets) internal view returns (uint256) {
        // A permanent virtual buffer (`virtualAssets` = `virtualSupply`) is added symmetrically to the
        // share and asset sides. It dampens exchange-rate inflation from donations/yield because an
        // attacker must outlay ~V in unbacked assets to move the rate by 1 unit of share.
        return Math.mulDiv(assets, totalSupply() + virtualAssets, latestTotalAssets + virtualAssets);
    }

    function _convertToAssets(uint256 shares, uint256 latestTotalAssets) internal view returns (uint256) {
        // Mirror `_convertToShares` so previews and queued redemptions use the same V-seeded rate.
        return Math.mulDiv(shares, latestTotalAssets + virtualAssets, totalSupply() + virtualAssets);
    }

    function _convertToAssetsCeil(uint256 shares, uint256 latestTotalAssets) internal view returns (uint256) {
        // Ceil counterpart of `_convertToAssets`, used by previewMint/mint so the vault never under-prices
        // a shares→assets conversion (EIP-4626 "no fewer than" for mint).
        return Math.mulDiv(shares, latestTotalAssets + virtualAssets, totalSupply() + virtualAssets, Math.Rounding.Ceil);
    }

    /// @dev Shared pull-and-mint core for `deposit` and `mint`. Safety assumption: `asset` is a
    ///      hook-free ERC-20. The `safeTransferFrom` interaction runs BEFORE the `totalAssets`/`_mint`
    ///      effects (interaction-before-effects), so reentrancy safety relies on the asset having no
    ///      transfer hook that could reenter while this vault state is stale. The bound memecoin
    ///      (OutrunOFTInit) has no transfer hook, so this is not exploitable today; binding any
    ///      hook-bearing token here requires a fresh reentrancy review (and likely a reentrancy guard).
    function _deposit(address sender, address receiver, uint256 assets, uint256 shares) internal {
        IERC20(asset).safeTransferFrom(sender, address(this), assets);
        totalAssets += assets;
        // Same uint208 checkpoint bound as _accumulateYield; revert before minting (see totalAssets NatSpec).
        require(totalAssets <= type(uint208).max, TotalAssetsOverflowed(totalAssets));
        _mint(receiver, shares);

        emit Deposit(sender, receiver, assets, shares);
    }

    /// @dev Converts raw votes to memecoin asset-denominated votes using the current exchange rate.
    ///      Uses the same `+V` convention as `_convertToShares` so votes track the real asset value of shares.
    function _convertVotes(uint256 rawVotes, uint256 rawTotalSupply) internal view override returns (uint256) {
        if (rawTotalSupply == 0) return 0;
        return Math.mulDiv(rawVotes, totalAssets + virtualAssets, rawTotalSupply + virtualAssets);
    }

    /// @dev Converts raw past votes to asset-denominated using historical totalAssets checkpoint and the
    ///      permanent virtual buffer.
    function _convertPastVotes(uint256 rawPastVotes, uint256 rawPastTotalSupply, uint256 pastTotalAssets)
        internal
        view
        override
        returns (uint256)
    {
        if (rawPastTotalSupply == 0) return 0;
        return Math.mulDiv(rawPastVotes, pastTotalAssets + virtualAssets, rawPastTotalSupply + virtualAssets);
    }

    /// @dev Converts raw past total supply to asset-denominated using historical totalAssets checkpoint and
    ///      the permanent virtual buffer.
    function _convertPastTotalSupply(uint256 rawPastTotalSupply, uint256 pastTotalAssets)
        internal
        view
        override
        returns (uint256)
    {
        if (rawPastTotalSupply == 0) return 0;
        return Math.mulDiv(rawPastTotalSupply, pastTotalAssets + virtualAssets, rawPastTotalSupply + virtualAssets);
    }

    function _update(address from, address to, uint256 value) internal override(OutrunERC20Init, OutrunERC20VotesInit) {
        super._update(from, to, value);
    }

    /// @notice Exposes the permit nonce for `owner`.
    /// @dev Exposes the shared nonce source used by ERC20 Permit and voting signatures.
    /// @param owner Account whose nonce is being queried.
    /// @return Current nonce value.
    function nonces(address owner) public view override(OutrunERC20PermitInit, OutrunNoncesInit) returns (uint256) {
        return super.nonces(owner);
    }
}
