// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IImmutableState} from "@uniswap/v4-periphery/src/interfaces/IImmutableState.sol";
import {IDynamicFeeFacet} from "./IDynamicFeeFacet.sol";

/**
 * @title IMemeverseUniswapHook
 * @notice Interface for the Memeverse Uniswap v4 Hook.
 * @dev Defines shared types, events, and external entrypoints used by the hook implementation.
 *      The storage structs `PoolInfo` / `UserFeeState` / `PoolInitializationAuth` and the
 *      hook ERC-7201 storage struct live in `IMemeverseHookStorage`; the hook implementation
 *      imports both, and the structs are referenced unqualified via interface inheritance.
 *      Inherits {IImmutableState} so consumers (e.g. the MemeverseYTFlashSwapRouter constructor) can read
 *      `poolManager()` through this interface, aligning the static type with the runtime selector the hook already
 *      exposes via ImmutableState.
 */
interface IMemeverseUniswapHook is IImmutableState {
    /// @notice Identifies the typed payload carried through `PoolManager.unlock`.
    enum UnlockCallbackKind {
        ModifyLiquidity,
        Settlement
    }

    // ==========================
    // External Call Structures
    // ==========================
    struct AddLiquidityCoreParams {
        Currency currency0;
        Currency currency1;
        uint256 amount0Desired;
        uint256 amount1Desired;
        address to;
    }

    struct RemoveLiquidityCoreParams {
        Currency currency0;
        Currency currency1;
        uint128 liquidity;
        address recipient;
    }

    struct ClaimFeesCoreParams {
        PoolKey key;
        address recipient;
    }

    struct PreorderSettlementParams {
        PoolKey key;
        SwapParams params;
        address recipient;
    }

    struct SwapQuote {
        uint256 feeBps;
        uint256 estimatedUserInputAmount;
        uint256 estimatedUserOutputAmount;
        uint256 estimatedProtocolFeeAmount;
        uint256 estimatedLpFeeAmount;
        bool protocolFeeOnInput;
    }

    /// @notice Returns the current hook owner.
    /// @return owner_ Address authorized for hook-owned configuration.
    function owner() external view returns (address owner_);

    /// @notice Exposes the LP token implementation cloned for newly initialized pools.
    /// @return Implementation contract used as the source for pool LP clones.
    function lpTokenImplementation() external view returns (address);

    /// @notice Exposes the launcher consulted for post-unlock public-swap protection.
    /// @dev Returns the explicit launcher binding used by hook implementations for launch-state checks.
    /// @return Explicit launcher binding used for public-swap protection checks.
    function launcher() external view returns (address);

    /// @notice Exposes the public-swap resume time for a hook-managed pool.
    /// @dev `0` means no active post-unlock public-swap protection is recorded for the pool.
    /// @param poolId Pool being queried.
    /// @return Stored public-swap resume timestamp for the pool.
    function publicSwapResumeTime(PoolId poolId) external view returns (uint40);

    /// @notice Exposes when a hook-managed pool was initialized.
    /// @dev The launch timestamp anchors the launch-fee decay schedule.
    ///      UPGRADE INVARIANT: `quoteSwapFeeWithContext()` reads this getter for MemeverseUniswapHookLens.quoteSwap().
    ///      Hook proxy implementation upgrades MUST preserve this function signature; a selector break silently disables off-chain quoting.
    /// @param poolId Pool being queried.
    /// @return Recorded launch timestamp.
    function poolLaunchTimestamp(PoolId poolId) external view returns (uint40);

    /// @notice Exposes the default launch-fee decay schedule.
    /// @dev New pools use this configuration unless a future implementation introduces pool-specific overrides.
    ///      UPGRADE INVARIANT: `quoteSwapFeeWithContext()` reads this getter for MemeverseUniswapHookLens.quoteSwap().
    ///      Hook proxy implementation upgrades MUST preserve this function signature; a selector break silently disables off-chain quoting.
    /// @return startFeeBps Launch fee applied immediately after pool initialization.
    /// @return minFeeBps Floor fee reached after decay completes.
    /// @return decayDurationSeconds Time required for the launch fee to decay to its floor.
    function defaultLaunchFeeConfig()
        external
        view
        returns (uint24 startFeeBps, uint24 minFeeBps, uint32 decayDurationSeconds);

    /// @notice Quotes only the dynamic-fee portion of a public swap.
    /// @dev Lens callers use `STATICCALL` on this bridge so the hook remains the authorized facet caller
    ///      while EIP-214 read-only enforcement propagates through the storage-sharing `delegatecall`.
    ///      UPGRADE INVARIANT: keep the signature `quoteSwapFeeWithContext(...)`; it remains non-view while
    ///      the implementation needs `delegatecall` because solc 0.8.35 rejects `view` + `delegatecall`
    ///      (Error 8961). A direct ordinary CALL is read-only only while the delegated facet implementation
    ///      is read-only; `eth_call` alone does not establish EVM static-call enforcement.
    /// @param poolId Pool being quoted.
    /// @param params Swap parameters used for the quote.
    /// @param trader Trader address used by the dynamic-fee context.
    /// @param preSqrtPriceX96 Pool price before the quoted swap.
    /// @param liquidity Current pool liquidity.
    /// @param protocolFeeOnInput Whether the protocol fee is charged from the input currency.
    /// @return quote Prepared fee data returned by the DynamicFeeFacet.
    function quoteSwapFeeWithContext(
        PoolId poolId,
        SwapParams calldata params,
        address trader,
        uint160 preSqrtPriceX96,
        uint128 liquidity,
        bool protocolFeeOnInput
    ) external returns (IDynamicFeeFacet.PreparedSwapFee memory quote);

    /// @notice Reads the per-pool dynamic fee state held in this hook's storage namespace.
    /// @dev UPGRADE INVARIANT: hook proxy implementation upgrades MUST preserve this selector. The hook reads
    ///      its own ERC7201 storage directly without a facet `delegatecall`, matching
    ///      `addressBatchStateOf` and `pendingRebateOf`.
    /// @param poolId Pool being queried.
    /// @return state Current dynamic fee state.
    function dynamicFeeStateOf(PoolId poolId) external view returns (IDynamicFeeFacet.DynamicFeeState memory state);

    /// @notice Claims the caller's accrued referral rebate in `currency` and sends it to `recipient`.
    /// @dev Rebate assets and pending balances are held by this hook Router until the caller claims them.
    /// @param currency Rebate currency to claim.
    /// @param recipient Recipient of the claimed rebate.
    /// @return amount Claimed rebate amount sent to `recipient`.
    function claimRebate(Currency currency, address recipient) external returns (uint256 amount);

    /// @notice Updates the referral rebate rate (share of the total swap fee, in bps) on referral swaps.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    ///      `bps` is the referrer's share of the *total* swap fee in bps (`rebate = totalFee * bps / 10_000`,
    ///      equivalently `protocolFee * bps / FeeMath.PROTOCOL_FEE_SHARE_BPS` since the protocol share is 35%).
    ///      Rebate is capped at `FeeMath.PROTOCOL_FEE_SHARE_BPS` (3500); larger values revert.
    /// @param bps New rebate rate in basis points.
    function setReferrerRebateBps(uint256 bps) external;

    /// @notice Updates the treasury address.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    ///      Zero address is rejected because protocol fees require a concrete recipient.
    /// @param treasury_ The new treasury address.
    function setTreasury(address treasury_) external;

    /// @notice Replaces a diamond facet pointer.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    ///      The new facet must share this hook's PoolManager.
    /// @param role One of `SWAP_FACET_ROLE` / `DYNAMIC_FEE_FACET_ROLE` / `SETTLEMENT_FACET_ROLE`.
    /// @param facet New facet address.
    function setFacet(bytes32 role, address facet) external;

    /// @notice Reads the per-trader, per-pool address batch state held in this hook's storage namespace.
    /// @dev The hook reads its own shared ERC7201 storage directly without a facet delegatecall, matching
    ///      `pendingRebateOf` and `dynamicFeeStateOf`.
    /// @param trader Trader address whose batch state is read.
    /// @param poolId Pool being queried.
    /// @return state Current address batch state.
    function addressBatchStateOf(address trader, PoolId poolId)
        external
        view
        returns (IDynamicFeeFacet.AddressBatchState memory state);

    /// @notice Returns the accrued (unclaimed) rebate for a referrer in a currency.
    /// @param referrer Referrer address.
    /// @param currency Rebate currency.
    /// @return Accrued rebate amount held by the hook on behalf of `referrer`.
    function pendingRebateOf(address referrer, Currency currency) external view returns (uint256);

    /// @notice Returns the current referral rebate rate in basis points.
    /// @dev Reads the current rate directly from hook Router storage.
    /// @return Rebate share of the total fee in bps.
    function referrerRebateBps() external view returns (uint256);

    /// @notice Exposes the router authorized to initialize hook-managed pools.
    /// @return Router address allowed to authorize and trigger pool initialization.
    function poolInitializer() external view returns (address);

    /// @notice Returns the SwapFacet address bound to this hook.
    function swapFacet() external view returns (address);

    /// @notice Returns the DynamicFeeFacet address bound to this hook.
    function dynamicFeeFacet() external view returns (address);

    /// @notice Returns the SettlementFacet address bound to this hook.
    function settlementFacet() external view returns (address);

    /// @notice Updates the router authorized to initialize hook-managed pools.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    /// @param initializer New authorized initializer router.
    function setPoolInitializer(address initializer) external;

    /// @notice Authorizes exactly one pool initialization at a specific start price.
    /// @dev Callable only by `poolInitializer`; consumed by `beforeInitialize`.
    /// @param key Pool key being initialized.
    /// @param startPriceX96 Expected initial pool price.
    function authorizePoolInitialization(PoolKey calldata key, uint160 startPriceX96) external;

    /// @notice Updates the public-swap resume time for a hook-managed pool identified by token pair.
    /// @dev Intended for the configured launcher to snapshot post-unlock protection windows without depending on
    /// router-derived pool-key helpers.
    /// @param tokenA One token in the pair.
    /// @param tokenB The other token in the pair.
    /// @param resumeTime New public-swap resume timestamp for the pool.
    function setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime) external;

    /// @notice Updates the default launch-fee decay configuration.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    /// @param config New default launch-fee schedule.
    function setDefaultLaunchFeeConfig(IDynamicFeeFacet.LaunchFeeConfig calldata config) external;

    /// @notice Registers or removes a protocol-fee token, which controls HOW the protocol fee is collected — not whether.
    /// @dev Implementations are expected to restrict this to an admin or owner role. A registered currency is collected
    /// in when it is a pool leg (input side preferred when both legs are registered); otherwise the fee is taken from
    /// the input leg. Registering or removing never disables the fee.
    /// @param currency The currency whose protocol-fee-token flag is being updated.
    /// @param supported Whether `currency` should be collected in as the protocol fee when present in a pool leg.
    function setProtocolFeeCurrency(Currency currency, bool supported) external;

    /**
     * @notice Returns stored pool information for a hook-managed pool.
     * @dev Exposes the LP token address and fee-per-share accumulators.
     * @param poolId The pool id to query.
     * @return liquidityToken The LP token contract for the pool.
     * @return fee0PerShare The accumulated fee-per-share for currency0.
     * @return fee1PerShare The accumulated fee-per-share for currency1.
     */
    function poolInfo(PoolId poolId)
        external
        view
        returns (address liquidityToken, uint256 fee0PerShare, uint256 fee1PerShare);

    /// @notice Returns the LP token contract for a hook-managed pool.
    /// @dev Cheaper than poolInfo when only the LP token address is needed: reads one storage slot
    ///      instead of three and returns no fee-per-share accumulators.
    /// @param poolId The pool id to query.
    /// @return liquidityToken The LP token contract for the pool.
    function liquidityTokenOf(PoolId poolId) external view returns (address liquidityToken);

    /// @notice Returns the cached LP supply used by swap fee accounting.
    /// @param poolId Pool being queried.
    /// @return supply Cached total LP share supply.
    function cachedLpTotalSupply(PoolId poolId) external view returns (uint256 supply);

    /// @notice Returns one owner's fee accounting snapshot for a pool.
    /// @param poolId Pool being queried.
    /// @param user Owner whose accounting state is queried.
    /// @return fee0Offset Last currency0 fee-per-share snapshot.
    /// @return fee1Offset Last currency1 fee-per-share snapshot.
    /// @return pendingFee0 Pending currency0 fees.
    /// @return pendingFee1 Pending currency1 fees.
    function userFeeState(PoolId poolId, address user)
        external
        view
        returns (uint256 fee0Offset, uint256 fee1Offset, uint256 pendingFee0, uint256 pendingFee1);

    /// @notice Returns the treasury receiving protocol fees.
    /// @return treasury_ Current treasury address.
    function treasury() external view returns (address treasury_);

    /// @notice Returns whether a currency is registered as a protocol-fee token.
    /// @dev The flag selects which leg the fee is collected on; it does NOT gate whether the fee accrues.
    ///      See `setProtocolFeeCurrency` for the leg-resolution semantics.
    /// @param currency Currency address being queried.
    /// @return supported True if `currency` is registered as a protocol-fee token.
    function supportedProtocolFeeCurrencies(address currency) external view returns (bool supported);

    /// @notice Low-level liquidity execution API.
    /// @dev Adds full-range liquidity using the caller as payer and mints LP shares to `params.to`.
    /// Intended for routers and advanced integrators and does not implement end-user deadline or
    /// min-amount protections. The pool fee is not caller-configurable here: this Hook Core only operates on its
    /// dynamic-fee pool type.
    /// @param params The core liquidity-add parameters.
    /// @return liquidity The LP liquidity minted for this operation.
    /// @return delta The balance delta settled against the caller.
    function addLiquidityCore(AddLiquidityCoreParams calldata params)
        external
        returns (uint128 liquidity, BalanceDelta delta);

    /// @notice Low-level liquidity exit API.
    /// @dev Removes full-range liquidity owned by the caller and sends the underlying tokens to `params.recipient`.
    /// Intended for routers and advanced integrators and does not implement end-user deadline or
    /// min-amount protections. The pool fee is not caller-configurable here: this Hook Core only operates on its
    /// dynamic-fee pool type.
    /// @param params The core liquidity-remove parameters.
    /// @return delta The balance delta returned by the liquidity removal.
    function removeLiquidityCore(RemoveLiquidityCoreParams calldata params) external returns (BalanceDelta delta);

    /**
     * @notice Low-level fee-claim API.
     * @dev Claims pending LP fees for `msg.sender` and forwards them to `params.recipient`.
     * @param params The core fee-claim parameters.
     * @return fee0Amount The claimed amount of currency0 fees.
     * @return fee1Amount The claimed amount of currency1 fees.
     */
    function claimFeesCore(ClaimFeesCoreParams calldata params)
        external
        returns (uint256 fee0Amount, uint256 fee1Amount);

    /**
     * @notice Execute the preorder settlement swap through the hook's dedicated settlement path.
     * @dev Callable only by the configured launcher.
     * @param params Preorder settlement payload.
     * @return delta Balance delta describing the net token movement after applying fixed 1% settlement economics.
     */
    function executePreorderSettlement(PreorderSettlementParams calldata params) external returns (BalanceDelta delta);

    /**
     * @notice Internal accounting helper for LP fee snapshots.
     * @dev Integrators normally should not call this directly unless they intentionally want to synchronize fee
     * accounting outside the standard LP token transfer / claim flow.
     * @param id The pool id.
     * @param user The user address.
     */
    function updateUserSnapshot(PoolId id, address user) external;

    // ==========================
    // Events
    // ==========================

    event TreasuryUpdated(address oldTreasury, address newTreasury);

    event ProtocolFeeCurrencySupportUpdated(Currency indexed currency, bool supported);

    event LauncherUpdated(address oldLauncher, address newLauncher);

    event PoolInitializerUpdated(address oldInitializer, address newInitializer);

    event PoolInitializationAuthorized(PoolId indexed poolId, uint160 startPriceX96);

    event DefaultLaunchFeeConfigUpdated(
        uint24 oldStartFeeBps,
        uint24 oldMinFeeBps,
        uint32 oldDecayDurationSeconds,
        uint24 newStartFeeBps,
        uint24 newMinFeeBps,
        uint32 newDecayDurationSeconds
    );

    event PublicSwapResumeTimeUpdated(PoolId indexed poolId, uint40 oldResumeTime, uint40 newResumeTime);

    event ReferrerRebateBpsUpdated(uint256 oldBps, uint256 newBps);

    event ReferralRebateAccrued(address indexed referrer, Currency indexed currency, uint256 amount);

    event ReferralRebateClaimed(
        address indexed referrer, address indexed recipient, Currency indexed currency, uint256 amount
    );

    event FacetUpdated(bytes32 indexed role, address oldFacet, address newFacet);

    event PoolInitialized(
        PoolId indexed poolId, address indexed liquidityToken, Currency indexed currency0, Currency currency1
    );

    /// @dev `amount` is the portion received by `treasury`. When a swap carries a referrer, the rebate
    ///      carved out of the protocol fee is emitted separately as `ReferralRebateAccrued` on the hook
    ///      (via `SwapFacet._collectProtocolFee`),
    ///      so `ProtocolFeeCollected.amount + rebate == totalProtocolFee`. Indexers summing protocol
    ///      revenue must read both events on referral swaps.
    event ProtocolFeeCollected(
        PoolId indexed poolId, Currency indexed currency, address indexed treasury, uint256 amount, uint256 blockNumber
    );

    event LPFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 feePerShare, uint256 blockNumber
    );

    event LiquidityAdded(
        PoolId indexed poolId,
        address indexed provider,
        address indexed to,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event LiquidityRemoved(
        PoolId indexed poolId, address indexed provider, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    event FeesClaimed(
        PoolId indexed poolId,
        address indexed user,
        Currency indexed currency0,
        Currency currency1,
        uint256 fee0Amount,
        uint256 fee1Amount
    );

    error PoolNotInitialized();

    error TickSpacingNotDefault();

    error FeeMustBeDynamic();

    error HookAddressMismatch();

    /// @notice Reverts when pool liquidity exists but no tracked LP shares can earn fees.
    error NoActiveLiquidityShares();

    error SenderMustBeHook();

    error ExpiredPastDeadline();

    /// @notice Reverts when actual amounts are worse than user-provided minimums.
    error TooMuchSlippage();

    /// @notice Reverts when an exact-input swap underdelivers the expected pool-side input.
    error ExactInputPartialFill();

    /// @notice Reverts when an exact-output swap underdelivers the expected pool-side output.
    error ExactOutputPartialFill();

    /// @notice Reverts when a preorder settlement's self-computed protocol fee disagrees with the settlement result.
    error PreorderSettlementFeeMismatch();

    error InvalidUnlockCallbackKind(uint256 rawKind);

    error ZeroAddress();

    error NativeCurrencyUnsupported();

    /// @notice Reverts when a launch fee configuration value is zero, or when a preorder
    ///         settlement swap specifies a non-negative amount or nets zero input after fees.
    error ZeroValue();

    /// @notice Reverts when a launch fee config field exceeds BPS_BASE or when minFee > startFee.
    error InvalidLaunchFeeConfig();

    error Unauthorized();

    error UnauthorizedPoolInitializer();

    error UnauthorizedPoolInitialization();

    error PoolInitializationAlreadyAuthorized();

    /// @notice Reverts when pool initialization uses a different price than authorized.
    error InvalidInitialPrice();

    /// @notice Reverts when a public swap is attempted during the post-unlock protection window.
    error PublicSwapDisabled();

    /// @notice Reverts when a same-poolId swap reenters a swap lifecycle still in progress — either a public
    ///         swap's `beforeSwapLogic` while its `beforeSwap → _swap → afterSwap` window is open, or a
    ///         settlement's `executeSettlementLogic` while its Phase 1 transferFrom → Phase 3 `_updateAfterSwap`
    ///         window is open (covers transferFrom pre-unlock + swap + settle/take).
    /// @dev Blocks callback-token (ERC-777/1363) same-pool reentry that would advance `dynamicFeeState` while
    ///      the outer swap settles with a stale quote/snapshot. Per-pool (per poolId), so cross-pool nested
    ///      swaps are unaffected. Public swaps acquire the lock in `beforeSwapLogic` and release it in
    ///      `afterSwapLogic`; settlement swaps are hook self-calls that skip v4 swap callbacks, so
    ///      `SettlementFacet.executeSettlementLogic` acquires/releases the lock itself across its full body
    ///      (Phase 1 transferFrom → Phase 3 `_updateAfterSwap`) — it is NOT exempt, it owns its own lock lifecycle.
    error SwapLifecycleReentrant();

    /// @notice Reverts when an ERC20 transfer returns false.
    error ERC20TransferFailed();

    error LPTokenImplementationCodeNotReady(address implementation);

    error RebateExceedsProtocolShare();

    error FacetCodeNotReady(address facet);
    error FacetPoolManagerMismatch(address facet, address hookPoolManager, address facetPoolManager);
    /// @notice Reverts when a facet's immutable PoolManager getter cannot be read.
    /// @dev The facet has code but the `ImmutableState.poolManager()` probe reverts or the getter is
    ///      missing — folded into this named error instead of a bare revert, the same greppable
    ///      honest-failure class as `FacetCodeNotReady`. A successful call with non-decodable return data is
    ///      outside Solidity try/catch semantics and bubbles up as the raw decode revert; the facet swap is
    ///      rejected (fail-closed) either way.
    error FacetPoolManagerUnreadable(address facet);

    /// @dev Operational guardrail, not a security boundary — see `_authorizeUpgrade` dev comment.
    error UpgradePoolManagerMismatch(address expected, address actual);
    /// @notice Reverts when a UUPS upgrade target's immutable PoolManager getter cannot be read.
    /// @dev The target has code but the `ImmutableState.poolManager()` probe reverts or the getter is
    ///      missing — folded into this named error instead of a bare revert, mirroring the registration
    ///      center's `UpgradeEndpointUnreadable`. A successful call with non-decodable return data is
    ///      outside Solidity try/catch semantics and bubbles up as the raw decode revert; the upgrade is
    ///      rejected (fail-closed) either way.
    error UpgradePoolManagerUnreadable(address newImplementation);
    /// @dev Mirrors the `code.length` pre-check used by `_requireFacetPoolManager` so a no-code
    ///      target fails with a named, locatable error instead of an opaque ABI-decode revert.
    error UpgradeTargetCodeNotReady(address target);
    /// @notice Reverts when `setFacet` receives a role discriminator other than the three known roles.
    error UnknownFacetRole(bytes32 role);

    error UnsupportedSelector(bytes4 selector);

    // -----------------------------------------------------------------
    // Smart-EOA transient account-session errors
    // -----------------------------------------------------------------
    // Execution identity comes ONLY from the hook-captured `activePrincipal` (set by `beginAccountSession`
    // reading `msg.sender`); there is no principal parameter anywhere, and `tx.origin` is never read in the
    // execution path. `activePrincipal != address(0)` is the sole session-active marker; a non-zero
    // `SwapContext.principal` is the sole swap-context presence marker.

    /// @notice Reverts when `beginAccountSession` is called by an address with no account code.
    /// @dev This is a presence gate, NOT auth or an allowlist: it only separates conventional no-code EOAs
    ///      (which cannot atomically run begin → Router → end) from any address that carries account code
    ///      (deployed contract account, Safe, or an EIP-7702-delegated EOA whose EXTCODESIZE is 23). It does
    ///      NOT authenticate the account implementation.
    error AccountSessionCallerMustHaveCode(address caller);

    /// @notice Reverts when `beginAccountSession` is called while a session is already active.
    /// @dev The original `activePrincipal` is NOT overwritten; nested or repeated begin always reverts.
    error AccountSessionAlreadyActive(address activePrincipal);

    /// @notice Reverts when `endAccountSession` (or a swap callback) runs with no active session.
    error AccountSessionNotActive();

    /// @notice Reverts when `endAccountSession` is called by an address other than `activePrincipal`.
    error AccountSessionUnauthorized(address caller, address activePrincipal);

    /// @notice Reverts when `endAccountSession` (or `beginAccountSession`) runs with unconsumed swap context.
    /// @dev A pending context means a `beforeSwap` push has no matching `afterSwap` consume; ending the
    ///      session then would orphan that context's fee/principal state.
    error AccountSessionHasPendingContext(uint256 depth);

    /// @notice Reverts when `afterSwap` consumes a context with no principal (no matching beforeSwap push).
    error AccountSessionContextMissing();

    /// @notice Reverts when an `afterSwap` context principal differs from the current `activePrincipal`.
    /// @dev A mismatch means the session principal changed between beforeSwap and afterSwap — impossible
    ///      inside a single atomic account frame, so this is a hard integrity failure.
    error AccountSessionPrincipalMismatch(address contextPrincipal, address activePrincipal);

    /// @notice Opens a smart-EOA transient account session, recording `msg.sender` as `activePrincipal`.
    /// @dev Identity root: there is NO principal parameter. The hook captures the direct caller's address;
    ///      supported callers are deployed contract accounts (ERC-4337 smart account, Safe, or an
    ///      EIP-7702-delegated EOA). The `code.length` gate only rejects conventional no-code EOAs — it is a
    ///      presence check, NOT an auth/allowlist, and does NOT authenticate the account implementation.
    ///      Reverts with `AccountSessionCallerMustHaveCode` if the caller has no code,
    ///      `AccountSessionAlreadyActive` if a session is already active, or
    ///      `AccountSessionHasPendingContext` if any swap context is still pending. Runs directly against
    ///      the hook's own transient store (not via the Router/`onlyViaRouter` facet path).
    function beginAccountSession() external;

    /// @notice Closes the active smart-EOA transient account session.
    /// @dev Callable only by the current `activePrincipal` (`msg.sender == activePrincipal`). Reverts with
    ///      `AccountSessionNotActive` if no session is active, `AccountSessionUnauthorized` if the caller is
    ///      not the principal, or `AccountSessionHasPendingContext` if any swap context is still pending.
    ///      Clears `activePrincipal` (the sole session-active marker) on success.
    function endAccountSession() external;

    /// @notice Returns the active smart-EOA account-session principal, or address(0) when no session is active.
    /// @dev Read-only view over the hook's transient `activePrincipal` slot; does not alter session lifecycle.
    ///      Used by the YT Flash Swap Router to bind the payer to msg.sender before any fund action.
    /// @return principal Active session principal captured by `beginAccountSession`, or address(0).
    function activeAccountSessionPrincipal() external view returns (address principal);

    /// @notice Updates the clone template used to deploy LP tokens for new pools.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    ///      Existing LP clones are unaffected — they are independent contracts.
    /// @param implementation_ The new LP token clone implementation.
    function setLpTokenImplementation(address implementation_) external;

    /// @notice Emitted when the LP token implementation pointer is initialized or updated.
    event LPTokenImplementationUpdated(address oldImplementation, address newImplementation);
}
