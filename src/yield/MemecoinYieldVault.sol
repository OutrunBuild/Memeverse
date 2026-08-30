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
 * @dev Memecoin Yield Vault
 */
contract MemecoinYieldVault is IMemecoinYieldVault, OutrunERC20PermitInit, OutrunERC20VotesInit {
    using OutrunSafeERC20 for IERC20;

    uint256 public constant MAX_REDEEM_REQUESTS = 5;
    uint256 public constant REDEEM_DELAY = 1 days; // Preventing flash attacks

    address public asset;
    /// @dev Total managed assets. Implicit upper bound type(uint208).max: the governance asset checkpoint stores
    ///      uint208 (OutrunVotesInit), so the TotalAssetsOverflowed require in _accumulateYield/_deposit keeps it
    ///      representable — practically unreachable given the launcher-gated memecoin supply. Residual boundary: a
    ///      single increment of 2^256 − totalAssets or more panics at the checked addition before the require runs
    ///      (Panic(0x11)), so TotalAssetsOverflowed covers overshoots below that threshold only; the gap is ~48
    ///      orders of magnitude beyond the 2^208 bound and unreachable, documented so error-name monitoring knows
    ///      the boundary.
    uint256 public totalAssets;
    uint256 public verseId;
    /// @dev Permanent virtual buffer used by the share/asset conversion helpers. Set once at
    ///      initialization; sized by the launcher at 0.7% of the minimum main-pool memecoin provision.
    uint256 public virtualAssets;

    mapping(address account => RedeemRequestEntry[]) public redeemRequestQueues;

    /// @notice Initializes the yield vault proxy.
    /// @dev Sets ERC20 share metadata, binds the vault to one verse and one underlying memecoin, and locks
    ///      the permanent virtual buffer used to dampen exchange-rate inflation.
    /// @param _name Share token name.
    /// @param _symbol Share token symbol.
    /// @param _asset Underlying memecoin address. Reverts `ZeroAddress` if set to the zero address.
    /// @param _verseId Verse id associated with this vault.
    /// @param _virtualAssets Permanent virtual buffer. Must be non-zero so the `+virtualAssets` conversion guards can
    ///        never divide by zero and actually dampen the rate; sized by the launcher.
    function initialize(
        string calldata _name,
        string calldata _symbol,
        address _asset,
        uint256 _verseId,
        uint256 _virtualAssets
    ) external override initializer {
        require(_virtualAssets > 0, ZeroVirtualAssets());
        require(_asset != address(0), ZeroAddress());

        __OutrunERC20_init(_name, _symbol);
        __OutrunERC20Permit_init(_name);

        asset = _asset;
        verseId = _verseId;
        virtualAssets = _virtualAssets;
    }

    /// @notice Exposes the timepoint source used by the votes extension.
    /// @dev The vault uses block timestamps rather than block numbers.
    /// @return Current timestamp cast into the ERC-6372 clock domain.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    /// @notice Exposes the ERC-6372 clock mode string.
    /// @dev Advertises timestamp-based governance checkpoints.
    /// @return Clock mode descriptor.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, totalAssets);
    }

    /// @notice Preview how many underlying assets redeeming `shares` would release.
    /// @dev NOT supported. Claim payouts use each request's per-entry locked rate (fixed at requestRedeem
    ///      time), which a single current-rate preview cannot represent, so this always reverts.
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
            if (block.timestamp >= uint256(queue[i].requestTime) + REDEEM_DELAY) {
                total += queue[i].lockedAssets;
            }
        }
        return total;
    }

    /// @inheritdoc IMemecoinYieldVault
    /// @dev The simulation mirrors `withdraw`'s FIFO scan with swap-pop compaction in memory, so the
    ///      reachability result matches the state-changing call exactly.
    function isWithdrawReachable(address owner, uint256 assets) external view override returns (bool ok) {
        if (assets == 0) return false;
        RedeemRequestEntry[] storage queue = redeemRequestQueues[owner];
        uint256 len = queue.length;
        if (len == 0) return false;
        // Copy to memory to simulate swap-pop without mutating storage.
        uint192[] memory lockedAssets = new uint192[](len);
        uint256[] memory shares = new uint256[](len);
        uint64[] memory requestTimes = new uint64[](len);
        for (uint256 i = 0; i < len; ++i) {
            RedeemRequestEntry storage e = queue[i];
            lockedAssets[i] = e.lockedAssets;
            shares[i] = e.shares;
            requestTimes[i] = e.requestTime;
        }
        uint256 remaining = assets;
        uint256 j = 0;
        while (j < len && remaining > 0) {
            if (block.timestamp < uint256(requestTimes[j]) + REDEEM_DELAY) {
                unchecked {
                    ++j;
                }
                continue;
            }
            uint256 takeAssets = remaining < lockedAssets[j] ? remaining : uint256(lockedAssets[j]);
            uint256 takeShares =
                Math.mulDiv(takeAssets + 1, shares[j], uint256(lockedAssets[j]), Math.Rounding.Ceil) - 1;
            if (takeShares == 0) {
                unchecked {
                    ++j;
                }
                continue;
            }
            uint256 payout = Math.mulDiv(takeShares, uint256(lockedAssets[j]), shares[j]);
            shares[j] -= takeShares;
            lockedAssets[j] -= uint192(payout);
            remaining -= payout;
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
        return remaining == 0;
    }

    /// @notice Maximum shares `owner` could redeem right now.
    /// @dev Claim-mode semantics: sums shares across `owner`'s matured (claimable) queue entries. Shares
    ///      are burned at requestRedeem time, so this does NOT reflect `balanceOf`.
    /// @param owner Account whose claimable shares are queried.
    /// @return maxShares Total claimable shares for `owner`.
    function maxRedeem(address owner) external view override returns (uint256) {
        return _claimableShares(owner);
    }

    /// @inheritdoc IMemecoinYieldVault
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssetsCeil(shares, totalAssets);
    }

    /// @notice Previews the shares that must be burned to release exactly `assets`.
    /// @dev NOT supported for the same per-entry locked-rate reason as `previewRedeem`; always reverts.
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

    /// @notice Retries yield accumulation after a LayerZero compose call to `accumulateYields` failed.
    /// @dev Delegates to the `dispatcher`'s `settlePendingCompose`, which proves the compose was delivered-but-unrun
    ///      via the endpoint's composeQueue and then settles by approving this vault and calling `accumulateYields`
    ///      (pull + totalAssets accounting) in one step. The vault stores no dispatcher at all: the launcher's
    ///      `setYieldDispatcher` can rotate the canonical dispatcher after this vault was created, so a stuck compose may
    ///      sit in a different dispatcher's composeQueue than the current canonical one. The caller must supply the
    ///      dispatcher the compose was actually delivered to (the `to` field of the endpoint's `ComposeSent` event,
    ///      sourced alongside `message`), plus the original compose `message`, reconstructable from the same
    ///      `ComposeSent` log. `settlePendingCompose`
    ///      re-derives delivery against `composeQueue(token, dispatcher, guid, 0)`. This entry also verifies that the
    ///      message's inner receiver is this vault (revert `NotComposeBeneficiary`) and that the settlement released
    ///      a non-zero amount (revert `ComposeSettlementFailed`). A no-code `dispatcher` (EOA/empty contract) is not
    ///      pre-checked: the high-level call succeeds with empty returndata, so the strict `abi.decode` of the
    ///      uint256 return reverts with EMPTY revert data — no named error, and error-name monitoring must not
    ///      expect `ComposeSettlementFailed` for this class (verify the address was sourced
    ///      from the endpoint's `ComposeSent` event `to` field).
    /// @param dispatcher YieldDispatcherUpgradeable that the stuck compose was delivered to (ComposeSent `to`).
    /// @param guid LayerZero guid.
    /// @param message The original compose payload.
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

    /// @notice Deposits underlying asset and mints vault shares to `receiver`.
    /// @dev Share minting uses the current `totalAssets` exchange rate before the new deposit is added.
    ///      A non-zero deposit that would round down to 0 shares reverts instead of silently absorbing assets.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Recipient of the minted shares.
    /// @return shares Shares minted for the deposit.
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

    /// @notice Mints exactly `shares` to `receiver` by pulling the needed assets from the caller.
    /// @dev Shares-first deposit. `assets` is rounded up (ceil) to protect the vault so existing
    ///      shareholders are never diluted by an under-paying mint. Reuses `_deposit` (pull + mint +
    ///      uint208 guard + Deposit event) and writes the `totalAssets` checkpoint so the paired
    ///      governance invariant holds. The caller (`msg.sender`) pays the assets, mirroring `deposit`;
    ///      there is no operator-allowance path.
    /// @param shares Amount of vault shares to mint.
    /// @param receiver Recipient of the minted shares.
    /// @return assets Underlying assets pulled from the caller.
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
    /// @dev Entries remain until fully claimed (swap-pop on `entry.shares == 0`), so matured entries
    ///      still occupy `MAX_REDEEM_REQUESTS` slots until `redeem`/`withdraw` frees them. Governance:
    ///      shares are burned at request time via `_requestWithdraw` (`_burn` → `totalAssets -=
    ///      lockedAssets` → `_writeTotalAssetCheckpoint`), so the owner's `getVotes`/`getPastVotes`
    ///      (asset-denominated via `_convertVotes` / `_convertPastVotes` over
    ///      `OutrunVotesInit.sol::_totalAssetsCheckpoint`) drop to the post-burn checkpoint immediately
    ///      and remain zero for that position throughout `REDEEM_DELAY`; a proposal snapshot taken in
    ///      that window records zero voting power and a later `redeem`/`withdraw` does not restore it —
    ///      requesting is exiting governance one day early (see `_requestWithdraw` /
    ///      `OutrunVotesInit.sol::getPastVotes`).
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
            if (block.timestamp < uint256(entry.requestTime) + REDEEM_DELAY) {
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
        uint256 remainingAssets = assets;
        uint256 totalShares;

        uint256 i = 0;
        // Length is re-read each pass on purpose: the swap-pop compaction below pops requestQueue and
        // shrinks it, so caching length once would let i overrun the array after a pop.
        // solhint-disable-next-line gas-length-in-loops
        while (i < requestQueue.length && remainingAssets > 0) {
            RedeemRequestEntry storage entry = requestQueue[i];
            if (block.timestamp < uint256(entry.requestTime) + REDEEM_DELAY) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 takeAssets = remainingAssets < entry.lockedAssets ? remainingAssets : entry.lockedAssets;
            // Largest share count whose floor payout stays <= takeAssets (assets-first inverse of the lock rate).
            // Computed as ceil((T+1)·S/L) − 1 = floor(((T+1)·S − 1)/L): the exact largest s with floor(s·L/S) <= T.
            // The naive floor(T·S/L) under-counts by one at rounding edges and spuriously reverts reachable targets.
            // The −1 is load-bearing: without it, ceil over-counts when (T+1)·S is an exact multiple of L, which
            // would make `remainingAssets -= payout` underflow (Panic 0x11).
            uint256 takeShares = Math.mulDiv(takeAssets + 1, entry.shares, entry.lockedAssets, Math.Rounding.Ceil) - 1;
            if (takeShares == 0) {
                // Rounding leaves too few shares to cover 1 unit of payout here; try the next matured entry.
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 payout = Math.mulDiv(takeShares, entry.lockedAssets, entry.shares);
            entry.shares -= takeShares;
            entry.lockedAssets -= uint192(payout);
            remainingAssets -= payout;
            totalShares += takeShares;

            if (entry.shares == 0) {
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

        // Floor loss can leave a sub-unit remainder that no entry can satisfy exactly; revert, do not under-pay.
        require(remainingAssets == 0, InsufficientClaimableRedeem(assets - remainingAssets));

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
            if (block.timestamp < uint256(queue[i].requestTime) + REDEEM_DELAY) {
                shares += queue[i].shares;
            }
        }
    }

    /// @inheritdoc IMemecoinYieldVault
    function claimableRedeemRequest(address controller) external view override returns (uint256 shares) {
        return _claimableShares(controller);
    }

    /// @dev Shared matured-share sum used by `claimableRedeemRequest` and `maxRedeem`. Sums shares of
    ///      entries whose `requestTime + REDEEM_DELAY` has elapsed.
    function _claimableShares(address controller) internal view returns (uint256 total) {
        RedeemRequestEntry[] storage queue = redeemRequestQueues[controller];
        // Read-only scan: queue is not mutated here, so caching length once saves the per-iteration storage read.
        uint256 queueLength = queue.length;
        for (uint256 i = 0; i < queueLength; ++i) {
            if (block.timestamp >= uint256(queue[i].requestTime) + REDEEM_DELAY) {
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
