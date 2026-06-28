//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMemeverseDynamicFeeEngine} from "./IMemeverseDynamicFeeEngine.sol";
import {IMemeversePreorderSettlementExecutor} from "./IMemeversePreorderSettlementExecutor.sol";

/**
 * @title IMemeverseUniswapHook
 * @notice Interface for the Memeverse Uniswap v4 Hook.
 * @dev Defines shared types, events, and external entrypoints used by the hook implementation.
 */
interface IMemeverseUniswapHook {
    /// @notice Pool information tracked by the hook.
    struct PoolInfo {
        /// @notice Custom ERC20 LP token address for this pool.
        address liquidityToken;
        /// @notice Accumulated LP fees for currency0 (per share, scaled by Q128 in the implementation).
        uint256 fee0PerShare;
        /// @notice Accumulated LP fees for currency1 (per share, scaled by Q128 in the implementation).
        uint256 fee1PerShare;
    }

    /// @notice Per-user fee accounting state for a pool.
    struct UserFeeState {
        /// @notice Snapshot offset of `fee0PerShare` at the last user update, in Q128 per-share units.
        uint256 fee0Offset;
        /// @notice Snapshot offset of `fee1PerShare` at the last user update, in Q128 per-share units.
        uint256 fee1Offset;
        /// @notice Earned but unclaimed currency0 fees.
        uint256 pendingFee0;
        /// @notice Earned but unclaimed currency1 fees.
        uint256 pendingFee1;
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

    /// @notice Exposes the dynamic fee engine bound to this hook implementation.
    /// @dev The engine address is owner-upgradeable via `upgradeDynamicFeeEngine`. After replacement,
    ///      the new engine starts from zero dynamic-fee state (EWVWAP, volatility, short-impact all reset).
    ///      Hook proxy implementation upgrades do not affect the engine pointer — it lives in hook proxy storage.
    /// @return Engine used for dynamic fee quotes and realized swap state.
    function dynamicFeeEngine() external view returns (IMemeverseDynamicFeeEngine);

    /// @notice Exposes the LP token implementation cloned for newly initialized pools.
    /// @return Implementation contract used as the source for pool LP clones.
    function lpTokenImplementation() external view returns (address);

    /// @notice Exposes the stateless helper used for preorder settlement calculations.
    /// @return Executor contract currently used by the hook.
    function preorderSettlementExecutor() external view returns (IMemeversePreorderSettlementExecutor);

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

    /// @notice Quotes only the dynamic-fee engine portion of a public swap.
    /// @dev Lens callers use this bridge so the hook remains the authorized engine caller.
    /// @param poolId Pool being quoted.
    /// @param params Swap parameters used for the quote.
    /// @param trader Trader address used by the fee engine context.
    /// @param preSqrtPriceX96 Pool price before the quoted swap.
    /// @param liquidity Current pool liquidity.
    /// @param protocolFeeOnInput Whether the protocol fee is charged from the input currency.
    /// @return quote Prepared fee data returned by the dynamic fee engine.
    function quoteSwapFeeWithContext(
        PoolId poolId,
        SwapParams calldata params,
        address trader,
        uint160 preSqrtPriceX96,
        uint128 liquidity,
        bool protocolFeeOnInput
    ) external view returns (IMemeverseDynamicFeeEngine.PreparedSwapFee memory quote);

    /// @notice Exposes the router authorized to initialize hook-managed pools.
    /// @return Router address allowed to authorize and trigger pool initialization.
    function poolInitializer() external view returns (address);

    /// @notice Updates the launcher consulted for public-swap protection.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    /// @param launcher_ New launcher binding.
    function setLauncher(address launcher_) external;

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
    function setDefaultLaunchFeeConfig(IMemeverseDynamicFeeEngine.LaunchFeeConfig calldata config) external;

    /// @notice Updates whether a currency is eligible to receive protocol fees.
    /// @dev Implementations are expected to restrict this to an admin or owner role. If both pool sides are supported,
    /// the swap path prefers charging protocol fees on the input side.
    /// @param currency The currency whose support flag is being updated.
    /// @param supported Whether protocol fees may settle in `currency`.
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

    /// @notice Returns whether a currency can receive protocol fees.
    /// @param currency Currency address being queried.
    /// @return supported True when protocol fees may be collected in this currency.
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

    /// @notice Emitted when the treasury address is updated.
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /// @notice Emitted when a currency's protocol-fee support flag is updated.
    event ProtocolFeeCurrencySupportUpdated(Currency indexed currency, bool supported);

    /// @notice Emitted when the launcher binding is updated.
    event LauncherUpdated(address oldLauncher, address newLauncher);

    /// @notice Emitted when the pool initializer router is updated.
    event PoolInitializerUpdated(address oldInitializer, address newInitializer);

    /// @notice Emitted when a one-time pool initialization authorization is written.
    event PoolInitializationAuthorized(PoolId indexed poolId, uint160 startPriceX96);

    /// @notice Emitted when the default launch fee configuration is updated.
    event DefaultLaunchFeeConfigUpdated(
        uint24 oldStartFeeBps,
        uint24 oldMinFeeBps,
        uint32 oldDecayDurationSeconds,
        uint24 newStartFeeBps,
        uint24 newMinFeeBps,
        uint32 newDecayDurationSeconds
    );

    /// @notice Emitted when the public swap resume time is updated for a pool.
    event PublicSwapResumeTimeUpdated(PoolId indexed poolId, uint40 oldResumeTime, uint40 newResumeTime);

    /// @notice Emitted when a pool is initialized
    event PoolInitialized(
        PoolId indexed poolId, address indexed liquidityToken, Currency indexed currency0, Currency currency1
    );

    /// @notice Emitted when protocol fees are collected.
    /// @dev `amount` is the portion received by `treasury`. When a swap carries a referrer, the rebate
    ///      carved out of the protocol fee is emitted separately as `ReferralRebateAccrued` on the engine,
    ///      so `ProtocolFeeCollected.amount + rebate == totalProtocolFee`. Indexers summing protocol
    ///      revenue must read both events on referral swaps.
    event ProtocolFeeCollected(
        PoolId indexed poolId, Currency indexed currency, address indexed treasury, uint256 amount, uint256 blockNumber
    );

    /// @notice Emitted when LP fees are collected
    event LPFeeCollected(
        PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 feePerShare, uint256 blockNumber
    );

    /// @notice Emitted when liquidity is added to a pool
    event LiquidityAdded(
        PoolId indexed poolId,
        address indexed provider,
        address indexed to,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when liquidity is removed from a pool
    event LiquidityRemoved(
        PoolId indexed poolId, address indexed provider, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when a user claims their LP fees
    event FeesClaimed(
        PoolId indexed poolId,
        address indexed user,
        Currency indexed currency0,
        Currency currency1,
        uint256 fee0Amount,
        uint256 fee1Amount
    );

    /// @notice Reverts when a pool has not been initialized by the hook.
    error PoolNotInitialized();

    /// @notice Reverts when the pool tickSpacing is not the expected default.
    error TickSpacingNotDefault();

    /// @notice Reverts when the pool fee configuration is not set to dynamic fee.
    error FeeMustBeDynamic();

    /// @notice Reverts when a supplied PoolKey points at a different hook address.
    error HookAddressMismatch();

    /// @notice Reverts when pool liquidity exists but no tracked LP shares can earn fees.
    error NoActiveLiquidityShares();

    /// @notice Reverts when a restricted hook-only function is called by an external sender.
    error SenderMustBeHook();

    /// @notice Reverts when `deadline` is in the past.
    error ExpiredPastDeadline();

    /// @notice Reverts when actual amounts are worse than user-provided minimums.
    error TooMuchSlippage();

    /// @notice Reverts when an exact-input swap underdelivers the expected pool-side input.
    error ExactInputPartialFill();

    /// @notice Reverts when an exact-output swap underdelivers the expected pool-side output.
    error ExactOutputPartialFill();

    /// @notice Reverts when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Reverts when a hook-managed pool or protocol config uses native currency.
    error NativeCurrencyUnsupported();

    /// @notice Reverts when a launch fee configuration value is zero or invalid.
    error ZeroValue();

    /// @notice Reverts when a given currency is not supported by configuration.
    error CurrencyNotSupported();

    /// @notice Reverts when the caller is not authorized.
    error Unauthorized();

    /// @notice Reverts when the pool initializer router is not authorized.
    error UnauthorizedPoolInitializer();

    /// @notice Reverts when a pool initialization has not been pre-authorized.
    error UnauthorizedPoolInitialization();

    /// @notice Reverts when a pool initialization authorization is already active.
    error PoolInitializationAlreadyAuthorized();

    /// @notice Reverts when pool initialization uses a different price than authorized.
    error InvalidInitialPrice();

    /// @notice Reverts when a public swap is attempted during the post-unlock protection window.
    error PublicSwapDisabled();

    /// @notice Reverts when an ERC20 transfer returns false.
    error ERC20TransferFailed();

    /// @notice Reverts when the hook and engine are constructed with different PoolManager addresses.
    error DynamicFeeEnginePoolManagerMismatch(address hookPoolManager, address enginePoolManager);

    /// @notice Reverts when the new dynamic fee engine has not authorized this hook as a caller.
    error EngineNotAuthorizedCaller(address engine);

    /// @notice Reverts when the dynamic fee engine owner is not the hook proxy itself.
    error DynamicFeeEngineOwnerMismatch(address engine, address expectedOwner, address actualOwner);

    /// @notice Reverts when the LP token implementation address has no deployed code.
    error LPTokenImplementationCodeNotReady(address implementation);

    /// @notice Reverts when the preorder settlement executor address has no deployed code.
    error PreorderSettlementExecutorCodeNotReady(address executor);

    /// @notice Reverts when the executor is immutable-bound to a hook other than this hook proxy.
    error PreorderSettlementExecutorHookMismatch(address executor, address expectedHook, address actualHook);

    /// @notice Reverts when the executor-reported output-side protocol fee does not match the hook-derived amount.
    error PreorderSettlementFeeMismatch();

    /// @notice Migrates the hook to a new dynamic fee engine proxy.
    /// @dev `newEngine` must be an initialized engine proxy owned by this hook proxy and authorized for this hook.
    ///      Do not pass an implementation address here; use `upgradeDynamicFeeEngineImplementation` to upgrade the
    ///      currently bound engine proxy implementation.
    /// @param newEngine Initialized engine proxy owned by this hook proxy and authorized for this hook.
    function upgradeDynamicFeeEngine(IMemeverseDynamicFeeEngine newEngine) external;

    /// @notice Upgrades the implementation used by the currently bound dynamic fee engine proxy.
    /// @param newImplementation New engine implementation address.
    /// @param data Optional initialization or migration calldata forwarded to the engine upgrade.
    function upgradeDynamicFeeEngineImplementation(address newImplementation, bytes calldata data) external;

    /// @notice Replaces the stateless preorder settlement executor.
    /// @param executor New executor implementation with deployed code.
    function setPreorderSettlementExecutor(IMemeversePreorderSettlementExecutor executor) external;

    /// @notice Updates the clone template used to deploy LP tokens for new pools.
    /// @dev Implementations are expected to restrict this to an admin or owner role.
    ///      Existing LP clones are unaffected — they are independent contracts.
    /// @param implementation_ The new LP token clone implementation.
    function setLpTokenImplementation(address implementation_) external;

    /// @notice Emitted when the dynamic fee engine pointer is updated.
    event DynamicFeeEngineUpdated(address oldEngine, address newEngine);

    /// @notice Emitted when the LP token implementation pointer is initialized or updated.
    event LPTokenImplementationUpdated(address oldImplementation, address newImplementation);

    /// @notice Emitted when the preorder settlement executor pointer is initialized or updated.
    event PreorderSettlementExecutorUpdated(address oldExecutor, address newExecutor);
}
