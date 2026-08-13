// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "../../common/token/OutrunERC20Init.sol";

interface IMemecoinYieldVault is IERC20 {
    /// @dev Packed redemption-queue entry. `lockedAssets` is the asset amount fixed at request time
    ///      (uint192 single-request cap, enforced in `requestRedeem`); `requestTime` is the enqueue
    ///      timestamp; `shares` is the share amount burned for this request. Slot 0 packs
    ///      `lockedAssets` + `requestTime` (192 + 64 = 256 bits); slot 1 holds `shares`.
    struct RedeemRequestEntry {
        uint192 lockedAssets; // Asset amount locked when the request was enqueued
        uint64 requestTime; // Timestamp the request was enqueued
        uint256 shares; // Shares burned for this request
    }

    /// @notice Exposes the underlying memecoin managed by the vault.
    /// @dev This is the asset deposited by users and accumulated as yield.
    /// @return assetTokenAddress Underlying asset token address.
    function asset() external view returns (address assetTokenAddress);

    /// @notice Exposes the total amount of managed underlying assets.
    /// @dev Includes deposited principal plus any accumulated yield that has not been redeemed yet.
    /// @return totalManagedAssets Total managed asset amount.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Preview how many vault shares a deposit would mint at the current rate.
    /// @dev Uses the vault's current share pricing without mutating state. Does not revert on amounts
    ///      that would round down to zero shares: previewDeposit returns 0 while deposit reverts
    ///      ZeroSharesDeposit for the same amount.
    /// @param assets Amount of underlying asset to deposit.
    /// @return shares Shares that would be minted.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview how many underlying assets redeeming `shares` would unlock.
    /// @dev NOT supported. Claims pay out at each request's per-entry locked rate (fixed at requestRedeem
    ///      time), which a single current-rate preview cannot represent; always reverts
    ///      `PreviewRedeemNotSupported`. Use `claimableRedeemRequest`/`maxRedeem` for the claimable shares
    ///      and `maxWithdraw` for the claimable asset total.
    /// @param shares Amount of vault shares to redeem.
    /// @return assets Underlying asset amount that would be redeemed (never returned; always reverts).
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Converts an asset amount to vault shares at the current rate.
    /// @dev Reuses the internal floor conversion with the `virtualAssets` buffer, sharing the same
    ///      baseline as `previewDeposit`.
    /// @param assets Amount of underlying asset to convert.
    /// @return shares Shares equivalent at the current rate.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts a vault share amount to underlying assets at the current rate.
    /// @dev Reuses the internal floor conversion with the `virtualAssets` buffer.
    /// @param shares Amount of vault shares to convert.
    /// @return assets Asset equivalent at the current rate.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Maximum assets a single deposit could accept for `receiver`.
    /// @return maxAssets Unbounded upper bound; the vault imposes no deposit cap.
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Maximum shares a single mint could accept for `receiver`.
    /// @return maxShares Unbounded upper bound; the vault imposes no mint cap.
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Maximum assets `owner` could withdraw right now.
    /// @dev Claim-mode semantics: returns the sum of `lockedAssets` across `owner`'s matured
    ///      (claimable) redemption-queue entries. Shares are burned at requestRedeem time, so this does
    ///      NOT reflect `balanceOf`; an owner with un-requested shares reports 0 here.
    /// @return maxAssets Total claimable locked assets for `owner`.
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Maximum shares `owner` could redeem right now.
    /// @dev Claim-mode semantics: returns the sum of `shares` across `owner`'s matured (claimable)
    ///      redemption-queue entries. Shares are burned at requestRedeem time, so this does NOT reflect
    ///      `balanceOf`; an owner with un-requested shares reports 0 here.
    /// @return maxShares Total claimable shares for `owner`.
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Previews the asset cost of minting exactly `shares`.
    /// @dev Rounds up (ceil) — EIP-4626 requires the deposit to cost no fewer than this amount.
    /// @param shares Amount of vault shares to mint.
    /// @return assets Underlying asset amount needed.
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Previews the shares that must be burned to release exactly `assets`.
    /// @dev NOT supported for the same per-entry locked-rate reason as `previewRedeem`; always reverts
    ///      `PreviewWithdrawNotSupported`. Use `maxWithdraw` for the claimable asset total.
    /// @param assets Underlying asset amount to release.
    /// @return shares Vault shares that would be burned (never returned; always reverts).
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Initializes the yield vault proxy.
    /// @dev Wires ERC20 share metadata, the yield dispatcher, the verse-specific underlying asset, and the
    ///      permanent virtual buffer used to dampen exchange-rate inflation.
    /// @param name Share token name.
    /// @param symbol Share token symbol.
    /// @param yieldDispatcher Address treated as the canonical remote-yield source.
    /// @param asset Underlying memecoin address.
    /// @param verseId Verse id associated with this vault.
    /// @param virtualAssets Permanent virtual buffer added symmetrically to the share/asset sides of every
    ///        conversion; sized by the launcher at 0.7% of the minimum main-pool memecoin provision.
    function initialize(
        string calldata name,
        string calldata symbol,
        address yieldDispatcher,
        address asset,
        uint256 verseId,
        uint256 virtualAssets
    ) external;

    /// @notice Adds freshly supplied yield into the vault.
    /// @dev Implementations may restrict who is allowed to call this entrypoint.
    /// @param amount Amount of underlying asset being contributed as yield.
    function accumulateYields(uint256 amount) external;

    /// @notice Retries a failed cross-chain yield accumulation by settling the stuck compose from the dispatcher.
    /// @dev The caller must supply the `dispatcher` the compose was actually delivered to (the endpoint's ComposeSent
    ///      `to`, since the launcher's `setYieldDispatcher` can rotate the canonical dispatcher after this vault was
    ///      created) and the original compose `message` (reconstructable from the same ComposeSent log); the
    ///      dispatcher's `settlePendingCompose` verifies both against the endpoint's composeQueue. The entry also
    ///      verifies the message's inner receiver is this vault (revert `NotComposeBeneficiary`) and that the
    ///      settlement returned a non-zero amount (revert `ComposeSettlementFailed`).
    /// @param dispatcher YieldDispatcher the stuck compose was delivered to.
    /// @param guid LayerZero compose guid for the failed yield transfer.
    /// @param message The original compose payload.
    function reAccumulateYields(address dispatcher, bytes32 guid, bytes calldata message) external;

    /// @notice Deposits underlying asset and mints vault shares.
    /// @dev Implementations may add validation around who may receive shares. A non-zero deposit that
    ///      rounds down to zero shares reverts ZeroSharesDeposit; a zero-asset deposit returns 0.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Recipient of the minted vault shares.
    /// @return shares Shares minted for the deposit.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Mints exactly `shares` to `receiver` by pulling the needed assets from the caller.
    /// @dev Shares-first deposit: `assets` is rounded up (ceil) to protect the vault so existing
    ///      shareholders are never diluted by an under-paying mint. The caller (`msg.sender`) pays the
    ///      assets, mirroring `deposit`; there is no operator-allowance path. A zero-share mint returns 0.
    /// @param shares Amount of vault shares to mint.
    /// @param receiver Recipient of the minted shares.
    /// @return assets Underlying assets pulled from the caller.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Queues a redemption request, burning `shares` and locking their asset value immediately.
    /// @dev ERC-7540-style request phase (without operator/supportsInterface). Self-redemption only:
    ///      `controller` and `owner` must both equal `msg.sender`, so no one can fill another account's
    ///      queue (griefing defense). The locked asset amount is computed once at request time via the
    ///      floor conversion and stops participating in future yield; it is paid out later by
    ///      `redeem`/`withdraw` once `REDEEM_DELAY` has elapsed. Each controller owns a single FIFO
    ///      self-claim queue, so the vault uses one shared time-delay model instead of per-request ids.
    ///      Reverts `ZeroRedeemRequest` for a zero share amount, `RedeemAmountOverflowed` when the locked
    ///      assets exceed the uint192 single-request cap, and `MaxRedeemRequestsReached` when the queue
    ///      already holds `MAX_REDEEM_REQUESTS` entries.
    /// @param shares Amount of vault shares to burn into the redemption queue.
    /// @param controller Account that will later claim (must be `msg.sender`).
    /// @param owner Account whose queue is debited (must be `msg.sender`).
    /// @return lockedAssets Asset amount locked for the request (no longer earns yield).
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 lockedAssets);

    /// @notice Claims `shares` worth of matured redemption requests, paying out their locked assets.
    /// @dev ERC-4626-shaped claim phase. FIFO over `owner`'s queue: each matured entry contributes
    ///      `min(remaining, entry.shares)` shares at a floor payout of `take * entry.lockedAssets /
    ///      entry.shares`, decrementing the entry's shares and lockedAssets in lockstep so a later claim
    ///      never over-pays. The whole bounded queue (MAX_REDEEM_REQUESTS) is scanned rather than breaking
    ///      at the first immature entry, because partial-claim swap-pop compaction can reorder entries.
    ///      `owner` must equal `msg.sender`: shares were already burned at requestRedeem time, so there is
    ///      no allowance path and a third-party `owner` would steal assets. Reverts `ZeroRedeemRequest` for
    ///      zero shares, `NotSelfRedemption` for a third-party owner, and `InsufficientClaimableRedeem` if
    ///      the matured queue cannot cover the requested shares.
    /// @param shares Amount of previously burned shares to claim payouts for.
    /// @param receiver Recipient of the unlocked assets.
    /// @param owner Account whose matured requests are claimed (must be `msg.sender`).
    /// @return assets Total locked assets paid out.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Claims exactly `assets` from matured redemption requests.
    /// @dev Assets-first FIFO claim. For each matured entry it takes `min(remainingAssets,
    ///      entry.lockedAssets)` assets and solves the matching share count `takeShares =
    ///      ceil((takeAssets + 1) * entry.shares / entry.lockedAssets) - 1` so the floor payout
    ///      `floor(takeShares * entry.lockedAssets / entry.shares)` never exceeds `takeAssets`. Because each
    ///      payout floors down, an exact `assets` target is frequently unreachable from a partial queue;
    ///      the call then reverts `InsufficientClaimableRedeem` (EIP-4626's "MUST revert if all assets
    ///      cannot be withdrawn"). Same self-claim owner guard and FIFO scan as `redeem`.
    /// @param assets Exact amount of locked assets to pay out.
    /// @param receiver Recipient of the unlocked assets.
    /// @param owner Account whose matured requests are claimed (must be `msg.sender`).
    /// @return shares Total burned shares consumed by the claim.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Total shares in `controller`'s queue still pending the `REDEEM_DELAY` maturity.
    /// @dev ERC-7540-shaped pending query over `controller`'s single FIFO self-claim queue. Sums the
    ///      `shares` of every queue entry whose `requestTime + REDEEM_DELAY` is still in the future.
    /// @param controller Account whose pending shares are queried.
    /// @return shares Sum of immature (pending) shares.
    function pendingRedeemRequest(address controller) external view returns (uint256 shares);

    /// @notice Total shares in `controller`'s queue that have matured and are claimable now.
    /// @dev ERC-7540-shaped claimable query over `controller`'s single FIFO self-claim queue. Sums the
    ///      `shares` of every queue entry whose `requestTime + REDEEM_DELAY` has elapsed; equals
    ///      `maxRedeem(controller)`.
    /// @param controller Account whose claimable shares are queried.
    /// @return shares Sum of matured (claimable) shares.
    function claimableRedeemRequest(address controller) external view returns (uint256 shares);

    event AccumulateYields(address indexed yieldSource, uint256 yield, uint256 exchangeRate);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @dev ERC-4626 standard withdrawal event; emitted by `redeem` and `withdraw` at payout time.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @dev ERC-7540-style redeem-request event; emitted by `requestRedeem` at enqueue time (request phase).
    /// @param lockedAssets Asset value locked for the request at the requestRedeem-time exchange rate
    ///      (`_convertToAssets`); emitted so indexers can observe it directly without re-deriving.
    event RedeemRequest(
        address indexed controller, address indexed owner, address sender, uint256 shares, uint256 lockedAssets
    );

    error ZeroVirtualAssets();

    error ZeroRedeemRequest();

    error ZeroSharesDeposit();

    error MaxRedeemRequestsReached();

    error RedeemAmountOverflowed(uint256 assets);

    /// @dev totalAssets must stay representable in the governance asset checkpoint's uint208 storage.
    error TotalAssetsOverflowed(uint256 totalAssets);

    error NotSelfRedemption();

    /// @dev The compose payload is shorter than 108 bytes, so it cannot carry the inner
    ///      (address, TokenType) beneficiary word at [76:108] and can never settle.
    error ComposeMessageTooShort();

    /// @dev The compose's inner receiver is not this vault; settling it would never yield into this vault.
    error NotComposeBeneficiary();

    /// @dev The dispatcher returned without releasing any amount; nothing was settled.
    error ComposeSettlementFailed();

    /// @dev The matured queue cannot cover the requested claim. `available` is the claimable amount in the
    ///      same unit as the request (shares for `redeem`, assets for `withdraw`) matched before the revert.
    error InsufficientClaimableRedeem(uint256 available);

    /// @dev Single-rate preview cannot represent per-entry locked rates; `previewRedeem` always reverts.
    error PreviewRedeemNotSupported();

    /// @dev Single-rate preview cannot represent per-entry locked rates; `previewWithdraw` always reverts.
    error PreviewWithdrawNotSupported();
}
