// SPDX-License-Identifier: GPL-3.0
// OpenZeppelin Contracts (last updated v5.2.0) (governance/utils/Votes.sol)
//
// Divergence from upstream (preserve when syncing): this vendored port deliberately defaults the governance
// clock to timestamps (`Time.timestamp()`); upstream Votes defaults to the block number. Once deployed, the
// checkpoint keys are timestamp-domain values, so regressing the clock to block numbers makes every new key
// smaller than the last recorded one and `Checkpoints` reverts `CheckpointUnorderedInsertion` — bricking
// each mint/burn/delegate/transfer that writes a checkpoint until the block number outgrows the recorded
// timestamps (practically never within uint48 range).
pragma solidity ^0.8.35;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {ERC6372Utils} from "@openzeppelin/contracts/utils/ERC6372Utils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {OutrunNoncesInit} from "../../OutrunNoncesInit.sol";
import {OutrunEIP712Init} from "../../../cryptography/OutrunEIP712Init.sol";

/**
 * @dev This is a base abstract contract that tracks voting units, which are a measure of voting power that can be
 * transferred, and provides a system of vote delegation, where an account can delegate its voting units to a sort of
 * "representative" that will pool delegated voting units from different accounts and can then use it to vote in
 * decisions. In fact, voting units _must_ be delegated in order to count as actual votes, and an account has to
 * delegate those votes to itself if it wishes to participate in decisions and does not have a trusted representative.
 *
 * This contract is often combined with a token contract such that voting units correspond to token units. For an
 * example, see {ERC721Votes}.
 *
 * The full history of delegate votes is tracked on-chain so that governance protocols can consider votes as distributed
 * at a particular timepoint to protect against flash loans and double voting. The opt-in delegate system makes the
 * cost of this history tracking optional.
 *
 * When using this module the derived contract must implement {_getVotingUnits} (for example, make it return
 * {ERC721-balanceOf}), and can use {_transferVotingUnits} to track a change in the distribution of those units (in the
 * previous example, it would be included in {ERC721-_update}).
 *
 * @dev ---- Asset-denomination extension (yield-bearing share tokens) ----
 * The upstream Votes module records voting power in the token's own units (shares). For a yield-bearing share token
 * (e.g. an ERC-4626 vault) the share count alone is misleading: as yield accrues each share is worth more underlying
 * asset, so raw share votes would under-represent holders and drift whenever the exchange rate moves. To make votes
 * reflect the underlying asset value of holdings, this contract lets a subclass denominate votes in assets via three
 * conversion hooks plus an asset-side checkpoint:
 *
 *   - {_convertVotes}            converts `getVotes`          (latest  snapshot of shares).
 *   - {_convertPastVotes}        converts `getPastVotes`      (past   snapshot of shares + past totalAssets).
 *   - {_convertPastTotalSupply}  converts `getPastTotalSupply`(past   snapshot of shares + past totalAssets).
 *   - {_writeTotalAssetCheckpoint} records the managed `totalAssets` at the same clock timepoint as the share
 *     checkpoints, so past conversions can be replayed against the asset value that was in effect back then.
 *
 * Pairing-consistency invariant (load-bearing): every *past* conversion reads `_totalCheckpoints`,
 * `_delegateCheckpoints[account]`, and `_totalAssetsCheckpoint` at the SAME validated past timepoint (see
 * {getPastVotes} / {getPastTotalSupply}). A subclass that writes share checkpoints MUST also call
 * {_writeTotalAssetCheckpoint} on the same mutation (deposit, redeem, yield accrual, burn) so the three traces never
 * diverge in time. {getVotes} is the only view that intentionally uses the CURRENT exchange rate and therefore takes no
 * checkpoint argument; this is by design because a current vote must reflect the current share price.
 *
 * The default implementations here are identity (return the raw value unchanged), so a plain non-yield subclass is
 * unaffected. Asset denomination is only active when a subclass (currently `MemecoinYieldVault`) overrides the
 * conversion hooks and feeds totalAssets into the checkpoint.
 */
abstract contract OutrunVotesInit is Context, OutrunEIP712Init, OutrunNoncesInit, IERC5805 {
    using Checkpoints for Checkpoints.Trace208;

    bytes32 private constant DELEGATION_TYPEHASH =
    // solhint-disable-next-line gas-small-strings
    keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    struct VotesStorage {
        mapping(address account => address) _delegatee;

        mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;

        Checkpoints.Trace208 _totalCheckpoints;

        /// @notice Historical total-assets checkpoints for asset-denominated governance votes.
        /// @dev Subcontracts call `_writeTotalAssetCheckpoint` to record managed assets at each mutation.
        ///      When empty, IVotes views return raw voting units (backward compatible).
        Checkpoints.Trace208 _totalAssetsCheckpoint;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.Votes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VOTES_STORAGE_LOCATION =
        0x208f5ae36e3aa0934f277adce61242847ae71fe37b1a71ca90478a975291f400;

    function _getVotesStorage() private pure returns (VotesStorage storage $) {
        assembly {
            $.slot := VOTES_STORAGE_LOCATION
        }
    }

    /**
     * @dev Lookup to future votes is not available.
     */
    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

    function __OutrunVotes_init() internal onlyInitializing {}

    /// @notice Exposes the governance clock used for vote checkpoints.
    /// @dev Uses timestamps as defined by ERC-6372. Timestamp is the safe default: on chains where BLOCKNUMBER
    ///      returns the L1 (Ethereum) block number (Arbitrum Nitro/Orbit chains), a block-number clock does not
    ///      advance within the same L1 height and can regress on an L1 reorg, breaking ERC5805 checkpoint
    ///      monotonicity; a timestamp clock never decreases. It is not strictly increasing either — consecutive
    ///      fast blocks can share the same second-granularity timestamp — so checkpoint keys are non-decreasing
    ///      rather than strictly increasing: a write at an already-recorded timepoint merges into the last
    ///      checkpoint in place (equal-key update) instead of appending.
    /// @return currentTimepoint Current timestamp timepoint.
    function clock() public view virtual returns (uint48) {
        return Time.timestamp();
    }

    /**
     * @dev Machine-readable description of the clock as specified in ERC-6372.
     */
    // solhint-disable-next-line func-name-mixedcase
    /// @notice Exposes the ERC-6372 clock mode string for this votes module.
    /// @dev Reverts if a child contract changed `clock()` semantics.
    /// @return mode ERC-6372 clock mode descriptor string.
    function CLOCK_MODE() public view virtual returns (string memory) {
        return ERC6372Utils.timestampClockMode(clock());
    }

    /**
     * @dev Validate that a timepoint is in the past, and return it as a uint48.
     */
    function _validateTimepoint(uint256 timepoint) internal view returns (uint48) {
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) revert ERC5805FutureLookup(timepoint, currentTimepoint);
        return SafeCast.toUint48(timepoint);
    }

    /// @notice Reads the voting power currently delegated to `account`.
    /// @dev Reads latest value from delegate checkpoints, then applies `_convertVotes`.
    /// @param account Account whose current votes are requested.
    /// @return votes Current voting power of `account`.
    function getVotes(address account) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        return _convertVotes($._delegateCheckpoints[account].latest(), $._totalCheckpoints.latest());
    }

    /// @notice Reads the voting power delegated to `account` at a past timepoint.
    /// @dev Reverts when querying the current/future timepoint.
    /// @param account Account whose historical votes are requested.
    /// @param timepoint Past timestamp timepoint to query.
    /// @return votes Voting power recorded at `timepoint`.
    function getPastVotes(address account, uint256 timepoint) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        uint48 validatedTimepoint = _validateTimepoint(timepoint);
        return _convertPastVotes(
            $._delegateCheckpoints[account].upperLookupRecent(validatedTimepoint),
            $._totalCheckpoints.upperLookupRecent(validatedTimepoint),
            $._totalAssetsCheckpoint.upperLookupRecent(validatedTimepoint)
        );
    }

    /// @notice Reads total tracked voting units at a past timepoint.
    /// @dev Reverts when querying the current/future timepoint.
    /// @param timepoint Past timestamp timepoint to query.
    /// @return totalSupply Voting-unit supply recorded at `timepoint`.
    function getPastTotalSupply(uint256 timepoint) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        uint48 validatedTimepoint = _validateTimepoint(timepoint);
        return _convertPastTotalSupply(
            $._totalCheckpoints.upperLookupRecent(validatedTimepoint),
            $._totalAssetsCheckpoint.upperLookupRecent(validatedTimepoint)
        );
    }

    /// @notice Reads the delegate currently chosen by `account`.
    /// @dev Returns zero address when no delegate has been set.
    /// @param account Account to query.
    /// @return delegatee Delegate currently receiving votes from `account`.
    function delegates(address account) public view virtual returns (address) {
        VotesStorage storage $ = _getVotesStorage();
        return $._delegatee[account];
    }

    /// @notice Delegates caller voting units to `delegatee`.
    /// @dev Updates vote checkpoints and emits delegation events.
    /// @param delegatee Address that will receive caller voting power.
    function delegate(address delegatee) public virtual {
        address account = _msgSender();
        _delegate(account, delegatee);
    }

    /// @notice Delegates voting units using an EIP-712 signature.
    /// @dev Reverts on expired signature or nonce mismatch.
    /// @param delegatee Address that will receive voting power.
    /// @param nonce Expected signer nonce.
    /// @param expiry Signature expiration timestamp.
    /// @param v Signature recovery parameter.
    /// @param r Signature field `r`.
    /// @param s Signature field `s`.
    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        public
        virtual
    {
        if (block.timestamp > expiry) {
            revert VotesExpiredSignature(expiry);
        }
        address signer = ECDSA.recover(
            _hashTypedDataV4(keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s
        );
        _useCheckedNonce(signer, nonce);
        _delegate(signer, delegatee);
    }

    /**
     * @dev Delegate all of `account`'s voting units to `delegatee`.
     *
     * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
     */
    function _delegate(address account, address delegatee) internal virtual {
        VotesStorage storage $ = _getVotesStorage();
        address oldDelegate = delegates(account);
        $._delegatee[account] = delegatee;

        emit DelegateChanged(account, oldDelegate, delegatee);
        _moveDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
    }

    /**
     * @dev Transfers, mints, or burns voting units. To register a mint, `from` should be zero. To register a burn, `to`
     * should be zero. Total supply of voting units will be adjusted with mints and burns.
     */
    function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
        VotesStorage storage $ = _getVotesStorage();
        if (from == address(0)) {
            _push($._totalCheckpoints, _add, SafeCast.toUint208(amount));
        }
        if (to == address(0)) {
            _push($._totalCheckpoints, _subtract, SafeCast.toUint208(amount));
        }
        _moveDelegateVotes(
            from == address(0) ? address(0) : delegates(from), to == address(0) ? address(0) : delegates(to), amount
        );
    }

    /**
     * @dev Moves delegated votes from one delegate to another.
     */
    function _moveDelegateVotes(address from, address to, uint256 amount) internal virtual {
        VotesStorage storage $ = _getVotesStorage();
        if (from != to && amount > 0) {
            if (from != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _push($._delegateCheckpoints[from], _subtract, SafeCast.toUint208(amount));
                emit DelegateVotesChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                (uint256 oldValue, uint256 newValue) =
                    _push($._delegateCheckpoints[to], _add, SafeCast.toUint208(amount));
                emit DelegateVotesChanged(to, oldValue, newValue);
            }
        }
    }

    /**
     * @dev Get number of checkpoints for `account`.
     */
    function _numCheckpoints(address account) internal view virtual returns (uint32) {
        VotesStorage storage $ = _getVotesStorage();
        return SafeCast.toUint32($._delegateCheckpoints[account].length());
    }

    /**
     * @dev Get the `pos`-th checkpoint for `account`.
     */
    function _checkpoints(address account, uint32 pos)
        internal
        view
        virtual
        returns (Checkpoints.Checkpoint208 memory)
    {
        VotesStorage storage $ = _getVotesStorage();
        return $._delegateCheckpoints[account].at(pos);
    }

    function _push(
        Checkpoints.Trace208 storage store,
        function(uint208, uint208) view returns (uint208) op,
        uint208 delta
    ) private returns (uint208 oldValue, uint208 newValue) {
        return store.push(clock(), op(store.latest(), delta));
    }

    function _add(uint208 a, uint208 b) private pure returns (uint208) {
        return a + b;
    }

    function _subtract(uint208 a, uint208 b) private pure returns (uint208) {
        return a - b;
    }

    /// @notice Returns the number of stored total-assets checkpoints.
    /// @return len Number of checkpoints recorded.
    function getTotalAssetsCheckpointLen() external view virtual returns (uint256 len) {
        VotesStorage storage $ = _getVotesStorage();
        return $._totalAssetsCheckpoint.length();
    }

    /// @dev Converts raw voting power for `getVotes`. Default returns raw value unchanged.
    ///      Override in subcontracts to apply asset-denomination.
    /// @param rawVotes Raw delegated shares.
    /// @param rawTotalSupply Raw total share supply.
    /// @return votes Converted voting power.
    function _convertVotes(uint256 rawVotes, uint256 rawTotalSupply) internal view virtual returns (uint256) {
        rawTotalSupply; // suppress unused parameter warning
        return rawVotes;
    }

    /// @dev Converts raw voting power for `getPastVotes`. Default returns raw value unchanged.
    ///      Override in subcontracts to apply asset-denomination.
    /// @param rawPastVotes Raw delegated shares at past timepoint.
    /// @param rawPastTotalSupply Raw total share supply at past timepoint.
    /// @param pastTotalAssets Total assets checkpoint at past timepoint (0 if no checkpoint).
    /// @return votes Converted voting power.
    function _convertPastVotes(uint256 rawPastVotes, uint256 rawPastTotalSupply, uint256 pastTotalAssets)
        internal
        view
        virtual
        returns (uint256)
    {
        pastTotalAssets; // suppress unused parameter warning
        rawPastTotalSupply; // suppress unused parameter warning
        return rawPastVotes;
    }

    /// @dev Converts raw total supply for `getPastTotalSupply`. Default returns raw value unchanged.
    ///      Override in subcontracts to apply asset-denomination.
    /// @param rawPastTotalSupply Raw total share supply at past timepoint.
    /// @param pastTotalAssets Total assets checkpoint at past timepoint (0 if no checkpoint).
    /// @return totalSupply Converted total supply.
    function _convertPastTotalSupply(uint256 rawPastTotalSupply, uint256 pastTotalAssets)
        internal
        view
        virtual
        returns (uint256)
    {
        pastTotalAssets; // suppress unused parameter warning
        return rawPastTotalSupply;
    }

    /// @notice Records the current managed assets into the governance checkpoint.
    /// @dev Call this from subcontracts whenever managed totalAssets changes (deposit, yield, redeem).
    /// @param totalAssets Current managed total assets.
    function _writeTotalAssetCheckpoint(uint256 totalAssets) internal {
        VotesStorage storage $ = _getVotesStorage();
        $._totalAssetsCheckpoint.push(clock(), SafeCast.toUint208(totalAssets));
    }

    /**
     * @dev Must return the voting units held by an account.
     */
    function _getVotingUnits(address) internal view virtual returns (uint256);
}
