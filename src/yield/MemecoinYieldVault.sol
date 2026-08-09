// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {OutrunNoncesInit} from "../common/token/OutrunNoncesInit.sol";
import {IMemecoinYieldVault} from "./interfaces/IMemecoinYieldVault.sol";
import {ISettleCompose} from "../common/omnichain/ISettleCompose.sol";
import {OutrunSafeERC20, IERC20} from "./libraries/OutrunSafeERC20.sol";
import {OutrunERC20PermitInit} from "../common/token/OutrunERC20PermitInit.sol";
import {OutrunERC20Init, OutrunERC20VotesInit} from "../common/token/extensions/governance/OutrunERC20VotesInit.sol";

/**
 * @dev Memecoin Yield Vault
 */
contract MemecoinYieldVault is IMemecoinYieldVault, OutrunERC20PermitInit, OutrunERC20VotesInit {
    using OutrunSafeERC20 for IERC20;

    uint256 public constant MAX_REDEEM_REQUESTS = 5;
    uint256 public constant REDEEM_DELAY = 1 days; // Preventing flash attacks

    /// @dev Bound once in `initialize`. `reAccumulateYields` takes the dispatcher as a parameter
    ///      instead of reading this slot (the launcher can rotate its canonical dispatcher after this vault is
    ///      created). Retained only to preserve the clone + initializer storage layout.
    ///      DO NOT use this slot for compose recovery: it is not read by any runtime path. After a launcher
    ///      `setYieldDispatcher` rotation it holds a stale pointer that can diverge from the dispatcher a stuck compose
    ///      was actually delivered to; passing it to `reAccumulateYields` reverts `NotDelivered` (wrong dispatcher's
    ///      empty composeQueue slot). Recovery callers MUST source `dispatcher` from the endpoint's `ComposeSent` event
    ///      `to` field, never here.
    address public yieldDispatcher;
    address public asset;
    uint256 public totalAssets;
    uint256 public verseId;
    /// @dev Permanent virtual buffer V used by the share/asset conversion helpers. Set once at
    ///      initialization; sized by the launcher at 0.7% of the minimum main-pool memecoin provision.
    uint256 public virtualAssets;

    mapping(address account => RedeemRequest[]) public redeemRequestQueues;

    /// @notice Initializes the yield vault proxy.
    /// @dev Sets ERC20 share metadata, binds the vault to one verse and one underlying memecoin, and locks
    ///      the permanent virtual buffer used to dampen exchange-rate inflation.
    /// @param _name Share token name.
    /// @param _symbol Share token symbol.
    /// @param _yieldDispatcher Address treated as the canonical remote-yield source.
    /// @param _asset Underlying memecoin address.
    /// @param _verseId Verse id associated with this vault.
    /// @param _virtualAssets Permanent virtual buffer V. Must be non-zero so the `+V` conversion guards can
    ///        never divide by zero and actually dampen the rate; sized by the launcher (spec §4).
    function initialize(
        string calldata _name,
        string calldata _symbol,
        address _yieldDispatcher,
        address _asset,
        uint256 _verseId,
        uint256 _virtualAssets
    ) external override initializer {
        require(_virtualAssets > 0, ZeroVirtualAssets());

        __OutrunERC20_init(_name, _symbol);
        __OutrunERC20Permit_init(_name);

        yieldDispatcher = _yieldDispatcher;
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

    /// @notice Preview how many vault shares a deposit would mint at the current rate.
    /// @dev Does not transfer assets or mutate share supply.
    /// @param assets Amount of underlying asset to deposit.
    /// @return Shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, totalAssets);
    }

    /// @notice Preview how many underlying assets redeeming `shares` would release at today's rate.
    /// @dev Uses the current exchange rate without mutating any redemption queue state.
    /// @param shares Amount of vault shares to redeem.
    /// @return Underlying asset amount represented by `shares`.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, totalAssets);
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
    ///      (pull + totalAssets accounting) in one step. The `dispatcher` is taken as a parameter rather than read from
    ///      this vault's `initialize`-time `yieldDispatcher` storage: the launcher's `setYieldDispatcher` can rotate the
    ///      canonical dispatcher after this vault was created, so a stuck compose may sit in a different dispatcher's
    ///      composeQueue than the one captured at initialization. The caller must supply the dispatcher the compose was
    ///      actually delivered to (the `to` field of the endpoint's `ComposeSent` event, sourced alongside `message`),
    ///      plus the original compose `message`, reconstructable from the same `ComposeSent` log. `settlePendingCompose`
    ///      re-derives delivery against `composeQueue(token, dispatcher, guid, 0)`. This entry also verifies that the
    ///      message's inner receiver is this vault (revert `NotComposeBeneficiary`) and that the settlement released
    ///      a non-zero amount (revert `ComposeSettlementFailed`).
    /// @param dispatcher YieldDispatcher that the stuck compose was delivered to (ComposeSent `to`).
    /// @param guid LayerZero guid.
    /// @param message The original compose payload.
    function reAccumulateYields(address dispatcher, bytes32 guid, bytes calldata message) external override {
        // The compose's beneficiary is fixed by the message (hash-bound to the guid by the endpoint queue), so only
        // a message whose inner receiver is this vault can settle yield into this vault. The receiver word sits at
        // [76:108] — OFTComposeMsgCodec's COMPOSE_FROM_OFFSET plus the first word of the (address, TokenType) tuple
        // (the offsets YieldDispatcher parses in _parseCompose). A message shorter than 108 bytes cannot carry the
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

    /// @notice Burns shares and queues a delayed redemption for `receiver`.
    /// @dev Self-redemption only: `receiver` must equal `msg.sender` so no one can fill another
    ///      account's queue. The queued asset amount is fixed at request time and later unlocked by `executeRedeem`.
    /// @param shares Amount of shares to burn into the redemption queue.
    /// @param receiver Account that will later receive the underlying asset.
    /// @return assets Underlying asset amount locked into the redemption request.
    function requestRedeem(uint256 shares, address receiver) external override returns (uint256) {
        require(receiver == msg.sender, NotSelfRedemption());

        uint256 assets = _convertToAssets(shares, totalAssets);
        require(assets > 0, ZeroRedeemRequest());

        _requestWithdraw(msg.sender, receiver, assets, shares);

        return assets;
    }

    /// @notice Redeems every matured request owned by the caller.
    /// @dev Requests that have not yet passed `REDEEM_DELAY` remain queued for future calls.
    /// @return redeemedAmount Total underlying asset amount transferred to the caller.
    function executeRedeem() external override returns (uint256 redeemedAmount) {
        RedeemRequest[] storage requestQueue = redeemRequestQueues[msg.sender];

        // asset is written once in initialize and never mutated; caching avoids repeated SLOADs across loop iterations.
        address asset_ = asset;

        for (uint256 i = requestQueue.length; i > 0;) {
            unchecked {
                --i;
            }
            if (block.timestamp >= requestQueue[i].requestTime + REDEEM_DELAY) {
                uint256 amount = requestQueue[i].amount;
                redeemedAmount += amount;

                // Iterate backwards so pop-based removals can swap in the tail element without skipping unchecked requests.
                if (i != requestQueue.length - 1) {
                    requestQueue[i] = requestQueue[requestQueue.length - 1];
                }
                requestQueue.pop();

                IERC20(asset_).safeTransfer(msg.sender, amount);

                emit RedeemExecuted(msg.sender, amount);
            }
        }
    }

    function _requestWithdraw(address sender, address receiver, uint256 assets, uint256 shares) internal {
        uint256 requestCount = redeemRequestQueues[receiver].length;
        require(requestCount < MAX_REDEEM_REQUESTS, MaxRedeemRequestsReached());
        require(assets <= type(uint192).max, RedeemAmountOverflowed(assets));

        _burn(sender, shares);
        // The queued asset amount stops participating in future yield immediately, so share price only reflects still-staked assets.
        totalAssets -= assets;
        _writeTotalAssetCheckpoint(totalAssets);
        redeemRequestQueues[receiver].push(
            RedeemRequest({amount: uint192(assets), requestTime: uint64(block.timestamp)})
        );

        emit RedeemRequested(sender, receiver, assets, shares, block.timestamp);
    }

    function _convertToShares(uint256 assets, uint256 latestTotalAssets) internal view returns (uint256) {
        // A permanent virtual buffer V (= virtualAssets = virtualSupply) is added symmetrically to the
        // share and asset sides. It dampens exchange-rate inflation from donations/yield because an
        // attacker must outlay ~V in unbacked assets to move the rate by 1 unit of share. See spec §4.
        return Math.mulDiv(assets, totalSupply() + virtualAssets, latestTotalAssets + virtualAssets);
    }

    function _convertToAssets(uint256 shares, uint256 latestTotalAssets) internal view returns (uint256) {
        // Mirror `_convertToShares` so previews and queued redemptions use the same V-seeded rate.
        return Math.mulDiv(shares, latestTotalAssets + virtualAssets, totalSupply() + virtualAssets);
    }

    function _deposit(address sender, address receiver, uint256 assets, uint256 shares) internal {
        IERC20(asset).safeTransferFrom(sender, address(this), assets);
        totalAssets += assets;
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
    ///      permanent virtual buffer V (spec §4).
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
    ///      the permanent virtual buffer V (spec §4).
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
