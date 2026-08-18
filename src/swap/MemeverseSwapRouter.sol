// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {IMemeverseUniswapHookLens} from "./interfaces/IMemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "./interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseSwapRouter} from "./interfaces/IMemeverseSwapRouter.sol";
import {LiquidityQuote} from "./libraries/LiquidityQuote.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {SwapGuardMath} from "./libraries/SwapGuardMath.sol";
import {MemeversePoolKeyLib} from "./libraries/MemeversePoolKeyLib.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {SwapFeeMath} from "./libraries/SwapFeeMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title MemeverseSwapRouter
/// @notice Recommended single public periphery entrypoint for Memeverse swap and LP flows.
/// @dev Swaps always execute or revert. For exact-output swaps, callers are expected to source `amountInMaximum`
/// from `MemeverseSwapRouter.quoteSwap()` or a stricter front-end slippage policy. The underlying hook remains
/// callable as a Core API for custom routers and integrators, but this router is the intended canonical entrypoint
/// for end-user and on-chain SDK integrations, covering quote, swap, LP, fee claim, and hook-backed pool bootstrap
/// flows.
contract MemeverseSwapRouter is SafeCallback, IMemeverseSwapRouter {
    using OutrunSafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for int128;

    struct CallbackData {
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    IMemeverseUniswapHook public immutable override hook;
    IPermit2 public immutable override permit2;
    IMemeverseUniswapHookLens public immutable override hookLens;
    /* solhint-disable gas-small-strings */
    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)"
    );
    bytes32 internal constant ADD_LIQUIDITY_WITNESS_TYPEHASH = keccak256(
        "MemeverseAddLiquidityWitness(address currency0,address currency1,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)"
    );
    bytes32 internal constant REMOVE_LIQUIDITY_WITNESS_TYPEHASH = keccak256(
        "MemeverseRemoveLiquidityWitness(address currency0,address currency1,uint128 liquidity,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)"
    );
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "MemeverseSwapWitness witness)MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)TokenPermissions(address token,uint256 amount)";
    string internal constant ADD_LIQUIDITY_WITNESS_TYPE_STRING =
        "MemeverseAddLiquidityWitness witness)MemeverseAddLiquidityWitness(address currency0,address currency1,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)TokenPermissions(address token,uint256 amount)";
    string internal constant REMOVE_LIQUIDITY_WITNESS_TYPE_STRING =
        "MemeverseRemoveLiquidityWitness witness)MemeverseRemoveLiquidityWitness(address currency0,address currency1,uint128 liquidity,uint256 amount0Min,uint256 amount1Min,address to,uint256 deadline)TokenPermissions(address token,uint256 amount)";

    /* solhint-enable gas-small-strings */

    /// @param _manager The Uniswap v4 pool manager.
    /// @param _hook The Memeverse hook that owns launch-fee and LP accounting for routed swaps.
    /// @param _hookLens Stateless read-only calculator for hook quote and preview APIs.
    /// @param _permit2 The Permit2 entrypoint used for signature-based ERC20 pulls.
    constructor(
        IPoolManager _manager,
        IMemeverseUniswapHook _hook,
        IMemeverseUniswapHookLens _hookLens,
        IPermit2 _permit2
    ) SafeCallback(_manager) {
        hook = _hook;
        _validateHookLens(_hookLens);
        hookLens = _hookLens;
        permit2 = _permit2;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    modifier differentTokens(address tokenA, address tokenB) {
        if (tokenA == tokenB) revert InvalidTokenPair();
        _;
    }

    modifier onlyLauncher() {
        if (msg.sender != hook.launcher()) revert UnauthorizedLauncher();
        _;
    }

    modifier erc20Pair(Currency currency0, Currency currency1) {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(currency0, currency1);
        _;
    }

    /// @inheritdoc IMemeverseSwapRouter
    function getHookPoolKey(address tokenA, address tokenB)
        public
        view
        override
        differentTokens(tokenA, tokenB)
        erc20Pair(Currency.wrap(tokenA), Currency.wrap(tokenB))
        returns (PoolKey memory key)
    {
        key = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, address(hook));
    }

    /// @inheritdoc IMemeverseSwapRouter
    function previewClaimableFees(address tokenA, address tokenB, address owner)
        external
        view
        override
        returns (uint256 fee0, uint256 fee1)
    {
        PoolKey memory key = getHookPoolKey(tokenA, tokenB);
        return hookLens.claimableFees(hook, key, owner);
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Resolves the hook pool key from token addresses and reads the hook pool information.
    function lpToken(address tokenA, address tokenB) external view override returns (address liquidityToken) {
        PoolKey memory key = getHookPoolKey(tokenA, tokenB);
        liquidityToken = hook.liquidityTokenOf(key.toId());
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Resolves the hook pool key, reads the current pool price, and applies the same full-range liquidity math
    ///      used by the Router and Hook Core add-liquidity paths.
    function quoteAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        override
        differentTokens(tokenA, tokenB)
        erc20Pair(Currency.wrap(tokenA), Currency.wrap(tokenB))
        returns (uint256 amountARequired, uint256 amountBRequired)
    {
        (,, bool tokenAIsCurrency0) = MemeversePoolKeyLib.sortedCurrencies(tokenA, tokenB);
        PoolKey memory key = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, address(hook));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (uint256 amount0Required, uint256 amount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, LiquidityQuote.MIN_SQRT_PRICE_X96, LiquidityQuote.MAX_SQRT_PRICE_X96, liquidityDesired
        );

        // `LiquidityAmounts.getAmountsForLiquidity` truncates (floor); the `++` pads each required amount so the
        // quote never understates what minting `liquidityDesired` needs — mirroring the explicit roundUp=true
        // used by `_exactLiquidityAmountsAtPrice`.
        if (liquidityDesired != 0) {
            if (sqrtPriceX96 <= LiquidityQuote.MIN_SQRT_PRICE_X96) {
                unchecked {
                    ++amount0Required;
                }
            } else if (sqrtPriceX96 < LiquidityQuote.MAX_SQRT_PRICE_X96) {
                unchecked {
                    ++amount0Required;
                    ++amount1Required;
                }
            } else {
                unchecked {
                    ++amount1Required;
                }
            }
        }

        return tokenAIsCurrency0 ? (amount0Required, amount1Required) : (amount1Required, amount0Required);
    }

    /// @inheritdoc IMemeverseSwapRouter
    function quoteExactAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        override
        differentTokens(tokenA, tokenB)
        returns (uint256 amountARequired, uint256 amountBRequired)
    {
        (Currency currency0, Currency currency1, bool tokenAIsCurrency0) =
            MemeversePoolKeyLib.sortedCurrencies(tokenA, tokenB);
        (uint256 amount0Required, uint256 amount1Required) =
            _quoteExactLiquidityAmounts(currency0, currency1, liquidityDesired);
        return tokenAIsCurrency0 ? (amount0Required, amount1Required) : (amount1Required, amount0Required);
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev This router-first facade keeps quote logic centralized while reusing the hook's internal math.
    ///      The Lens enforces read-only execution with `STATICCALL`; the EIP-214 static context propagates
    ///      through the hook's storage-sharing `delegatecall` and rejects any attempted facet state write.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params, address trader)
        external
        view
        override
        returns (IMemeverseUniswapHook.SwapQuote memory quote)
    {
        return hookLens.quoteSwap(hook, key, params, trader);
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Swaps always settle or revert; the caller must cover slippage via `amountOutMinimum` or `amountInMaximum`,
    ///      and any leftover budget is refunded to the caller.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData
    ) external override returns (BalanceDelta delta) {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(key.currency0, key.currency1);

        (Currency inputCurrency, uint256 inputBudget) = _swapInputContext(key, params, amountInMaximum);
        _pullCurrency(inputCurrency, msg.sender, inputBudget);

        return _swap(
            key,
            params,
            recipient,
            deadline,
            amountOutMinimum,
            amountInMaximum,
            hookData,
            msg.sender,
            inputCurrency,
            inputBudget
        );
    }

    /// @inheritdoc IMemeverseSwapRouter
    function swapWithPermit2(
        IMemeverseSwapRouter.Permit2SingleParams calldata permitParams,
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData
    ) external override returns (BalanceDelta delta) {
        SwapGuardMath.revertIfNativeCurrencyUnsupported(key.currency0, key.currency1);

        (Currency inputCurrency, uint256 inputBudget) = _swapInputContext(key, params, amountInMaximum);
        _prepareSwapPermit2Input(
            permitParams,
            key,
            params,
            recipient,
            deadline,
            amountOutMinimum,
            amountInMaximum,
            hookData,
            inputCurrency,
            inputBudget
        );

        return _swap(
            key,
            params,
            recipient,
            deadline,
            amountOutMinimum,
            amountInMaximum,
            hookData,
            msg.sender,
            inputCurrency,
            inputBudget
        );
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Pulls the caller's desired budgets, validates min amounts, and refunds any unused input budget
    ///      back to the caller.
    function addLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external override returns (uint128 liquidity) {
        (liquidity,,) = _addLiquidity(
            currency0, currency1, amount0Desired, amount1Desired, amount0Min, amount1Min, to, msg.sender, deadline
        );
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Pulls the caller's desired budgets, normalizes pool ordering internally, refunds any unused input budget,
    ///      and exposes the settled spend in caller order.
    function addLiquidityDetailed(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external override returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        return _addLiquidity(
            currency0, currency1, amount0Desired, amount1Desired, amount0Min, amount1Min, to, msg.sender, deadline
        );
    }

    /// @inheritdoc IMemeverseSwapRouter
    function addLiquidityWithPermit2(
        IMemeverseSwapRouter.Permit2BatchParams calldata permitParams,
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external override returns (uint128 liquidity) {
        (PoolKey memory key,) = _resolveAddLiquidityExecutionContext(currency0, currency1, deadline);
        (uint256 amount0Budget, uint256 amount1Budget) =
            _normalizePairAmounts(currency0, currency1, amount0Desired, amount1Desired);
        (uint256 amount0Floor, uint256 amount1Floor) =
            _normalizePairAmounts(currency0, currency1, amount0Min, amount1Min);
        _pullCurrenciesWithPermit2(
            permitParams,
            msg.sender,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            amount0Desired,
            amount1Desired,
            _addLiquidityPermit2Witness(
                currency0, currency1, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
            ),
            ADD_LIQUIDITY_WITNESS_TYPE_STRING
        );
        _approvePreparedAddLiquidityBudgets(key.currency0, key.currency1, amount0Budget, amount1Budget);

        (liquidity,,) =
            _addLiquidityViaHook(key, amount0Budget, amount1Budget, amount0Floor, amount1Floor, to, msg.sender);
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Pulls LP shares into the router, calls the hook core, validates minimum outputs, and forwards the assets.
    function removeLiquidity(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external override returns (BalanceDelta delta) {
        PoolKey memory key = _canonicalHookPoolKey(currency0, currency1);
        return
            _removeLiquidity(
                currency0, currency1, liquidity, amount0Min, amount1Min, to, deadline, msg.sender, false, key
            );
    }

    /// @inheritdoc IMemeverseSwapRouter
    function removeLiquidityWithPermit2(
        IMemeverseSwapRouter.Permit2SingleParams calldata permitParams,
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external override returns (BalanceDelta delta) {
        PoolKey memory key = _canonicalHookPoolKey(currency0, currency1);
        address liquidityToken = hook.liquidityTokenOf(key.toId());
        _pullCurrencyWithPermit2(
            permitParams,
            msg.sender,
            liquidityToken,
            uint256(liquidity),
            _removeLiquidityPermit2Witness(currency0, currency1, liquidity, amount0Min, amount1Min, to, deadline),
            REMOVE_LIQUIDITY_WITNESS_TYPE_STRING
        );

        return
            _removeLiquidity(
                currency0, currency1, liquidity, amount0Min, amount1Min, to, deadline, msg.sender, true, key
            );
    }

    /// @inheritdoc IMemeverseSwapRouter
    /// @dev Pulls the caller's desired budgets, initializes the pool, and adds liquidity through the hook core.
    function createPoolAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint160 startPrice,
        address recipient,
        uint256 deadline
    )
        external
        override
        onlyLauncher
        returns (uint128 liquidity, PoolKey memory poolKey, uint256 amountAUsed, uint256 amountBUsed)
    {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Used;
        uint256 amount1Used;
        PoolKey memory preparedKey;
        (amount0Desired, amount1Desired, preparedKey) =
            _prepareCreatePoolAndAddLiquidityExecution(tokenA, tokenB, amountADesired, amountBDesired, deadline);
        // Pull then approve each budget leg in pool order (currency0 fully before currency1) so the hook
        // can spend the pulled budgets the moment the bootstrap add-liquidity runs.
        _pullCurrency(preparedKey.currency0, msg.sender, amount0Desired);
        _ensureHookApproval(preparedKey.currency0, amount0Desired);
        _pullCurrency(preparedKey.currency1, msg.sender, amount1Desired);
        _ensureHookApproval(preparedKey.currency1, amount1Desired);
        hook.authorizePoolInitialization(preparedKey, startPrice);
        poolManager.initialize(preparedKey, startPrice);
        // Bootstrap first liquidity: no lower-bound slippage check (min amounts = 0); only the
        // `used > desired` upper-bound guard in _handleAddLiquiditySettlement stays active.
        (liquidity, amount0Used, amount1Used) =
            _addLiquidityViaHook(preparedKey, amount0Desired, amount1Desired, 0, 0, recipient, msg.sender);
        poolKey = preparedKey;
        if (Currency.unwrap(preparedKey.currency0) == tokenA) {
            amountAUsed = amount0Used;
            amountBUsed = amount1Used;
        } else {
            amountAUsed = amount1Used;
            amountBUsed = amount0Used;
        }
    }

    /// @dev Executes the actual swap during the manager unlock window and settles the caller delta.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            data.key.currency0.settle(poolManager, address(this), uint256((-amount0).toUint128()));
        }
        if (amount1 < 0) {
            data.key.currency1.settle(poolManager, address(this), uint256((-amount1).toUint128()));
        }
        if (amount0 > 0) {
            data.key.currency0.take(poolManager, data.recipient, uint256(amount0.toUint128()));
        }
        if (amount1 > 0) {
            data.key.currency1.take(poolManager, data.recipient, uint256(amount1.toUint128()));
        }

        return abi.encode(delta);
    }

    function _swap(
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData,
        address payer,
        Currency inputCurrency,
        uint256 inputBudget
    ) internal beforeDeadline(deadline) returns (BalanceDelta delta) {
        if (address(key.hooks) != address(hook)) revert InvalidHook();
        // Reject zero-address recipients before they reach the unlock callback, where output
        // tokens would be taken to the zero address.
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        if (params.amountSpecified > 0 && amountInMaximum == 0) revert AmountInMaximumRequired();

        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData({recipient: recipient, key: key, params: params, hookData: hookData}))
            ),
            (BalanceDelta)
        );

        uint256 actualInputAmount = SwapFeeMath.actualInputAmount(delta, params.zeroForOne);
        if (amountInMaximum > 0 && actualInputAmount > amountInMaximum) {
            revert InputAmountExceedsMaximum(actualInputAmount, amountInMaximum);
        }
        uint256 minimumOutput = amountOutMinimum;
        if (params.amountSpecified > 0) {
            uint256 requestedOutput = uint256(params.amountSpecified);
            if (minimumOutput < requestedOutput) minimumOutput = requestedOutput;
        }
        if (minimumOutput > 0) {
            uint256 actualOutputAmount = SwapFeeMath.actualOutputAmount(delta, params.zeroForOne);
            if (actualOutputAmount < minimumOutput) {
                revert OutputAmountBelowMinimum(actualOutputAmount, minimumOutput);
            }
        }

        _refundUnusedInput(inputCurrency, payer, inputBudget, actualInputAmount);
        return delta;
    }

    function _pullCurrency(Currency currency, address from, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20Minimal(Currency.unwrap(currency)).transferFrom(from, address(this), amount)) {
            revert IMemeverseUniswapHook.ERC20TransferFailed();
        }
    }

    function _prepareSwapPermit2Input(
        IMemeverseSwapRouter.Permit2SingleParams calldata permitParams,
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData,
        Currency inputCurrency,
        uint256 inputBudget
    ) internal {
        if (inputBudget == 0) return;

        _pullCurrencyWithPermit2(
            permitParams,
            msg.sender,
            Currency.unwrap(inputCurrency),
            inputBudget,
            _swapPermit2Witness(key, params, recipient, deadline, amountOutMinimum, amountInMaximum, hookData),
            SWAP_WITNESS_TYPE_STRING
        );
    }

    function _pullCurrencyWithPermit2(
        IMemeverseSwapRouter.Permit2SingleParams calldata permitParams,
        address owner,
        address token,
        uint256 amount,
        bytes32 witness,
        string memory witnessTypeString
    ) internal {
        if (permitParams.permit.permitted.token != token) {
            revert InvalidPermit2Token(0, token, permitParams.permit.permitted.token);
        }
        if (permitParams.transferDetails.to != address(this)) revert InvalidPermit2Target(0);
        if (permitParams.transferDetails.requestedAmount != amount) {
            revert InvalidPermit2Amount(0, amount, permitParams.transferDetails.requestedAmount);
        }
        permit2.permitWitnessTransferFrom(
            permitParams.permit, permitParams.transferDetails, owner, witness, witnessTypeString, permitParams.signature
        );
    }

    function _pullCurrenciesWithPermit2(
        IMemeverseSwapRouter.Permit2BatchParams calldata permitParams,
        address owner,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        bytes32 witness,
        string memory witnessTypeString
    ) internal {
        if (permitParams.permit.permitted.length != 2 || permitParams.transferDetails.length != 2) {
            revert InvalidPermit2Length();
        }

        _validatePermit2BatchEntry(permitParams, 0, token0, amount0);
        _validatePermit2BatchEntry(permitParams, 1, token1, amount1);

        permit2.permitWitnessTransferFrom(
            permitParams.permit, permitParams.transferDetails, owner, witness, witnessTypeString, permitParams.signature
        );
    }

    function _validatePermit2BatchEntry(
        IMemeverseSwapRouter.Permit2BatchParams calldata permitParams,
        uint256 index,
        address expectedToken,
        uint256 expectedAmount
    ) internal view {
        address actualToken = permitParams.permit.permitted[index].token;
        if (actualToken != expectedToken) revert InvalidPermit2Token(index, expectedToken, actualToken);
        if (permitParams.transferDetails[index].to != address(this)) {
            revert InvalidPermit2Target(index);
        }
        if (permitParams.transferDetails[index].requestedAmount != expectedAmount) {
            revert InvalidPermit2Amount(index, expectedAmount, permitParams.transferDetails[index].requestedAmount);
        }
    }

    function _resolveAddLiquidityExecutionContext(Currency currency0, Currency currency1, uint256 deadline)
        internal
        view
        beforeDeadline(deadline)
        returns (PoolKey memory key, bool callerOrderMatchesPoolOrder)
    {
        // Reuse the canonical sort so add/remove liquidity always derive the same PoolKey.
        key = _canonicalHookPoolKey(currency0, currency1);
        callerOrderMatchesPoolOrder = Currency.unwrap(currency0) < Currency.unwrap(currency1);
    }

    function _addLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        address payer,
        uint256 deadline
    ) internal returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        (PoolKey memory key, bool callerOrderMatchesPoolOrder) =
            _resolveAddLiquidityExecutionContext(currency0, currency1, deadline);
        (uint256 amount0Budget, uint256 amount1Budget) =
            _normalizePairAmounts(currency0, currency1, amount0Desired, amount1Desired);
        (uint256 amount0Floor, uint256 amount1Floor) =
            _normalizePairAmounts(currency0, currency1, amount0Min, amount1Min);
        _pullCurrency(currency0, payer, amount0Desired);
        _pullCurrency(currency1, payer, amount1Desired);
        _approvePreparedAddLiquidityBudgets(key.currency0, key.currency1, amount0Budget, amount1Budget);

        (liquidity, amount0Used, amount1Used) =
            _addLiquidityViaHook(key, amount0Budget, amount1Budget, amount0Floor, amount1Floor, to, payer);
        if (!callerOrderMatchesPoolOrder) {
            (amount0Used, amount1Used) = (amount1Used, amount0Used);
        }
    }

    function _removeLiquidity(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline,
        address payer,
        bool liquidityPrepared,
        PoolKey memory key
    ) internal beforeDeadline(deadline) returns (BalanceDelta delta) {
        // `key` is the canonical pool key resolved once by the caller (see removeLiquidity /
        // removeLiquidityWithPermit2). Reusing it avoids a redundant _canonicalHookPoolKey call.
        if (!liquidityPrepared) {
            address liquidityToken = hook.liquidityTokenOf(key.toId());
            IERC20(liquidityToken).safeTransferFrom(payer, address(this), liquidity);
        }
        (uint256 amount0Floor, uint256 amount1Floor) =
            _normalizePairAmounts(currency0, currency1, amount0Min, amount1Min);

        delta = hook.removeLiquidityCore(
            IMemeverseUniswapHook.RemoveLiquidityCoreParams({
                currency0: key.currency0, currency1: key.currency1, liquidity: liquidity, recipient: address(this)
            })
        );

        (uint256 amount0Out, uint256 amount1Out) = _receivedLiquidityAmounts(delta);
        if (amount0Out < amount0Floor || amount1Out < amount1Floor) {
            revert IMemeverseUniswapHook.TooMuchSlippage();
        }

        key.currency0.transferWithGuard(to, amount0Out);
        key.currency1.transferWithGuard(to, amount1Out);
    }

    function _prepareCreatePoolAndAddLiquidityExecution(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 deadline
    )
        internal
        view
        beforeDeadline(deadline)
        differentTokens(tokenA, tokenB)
        erc20Pair(Currency.wrap(tokenA), Currency.wrap(tokenB))
        returns (uint256 amount0Desired, uint256 amount1Desired, PoolKey memory poolKey)
    {
        (,, bool tokenAIsCurrency0) = MemeversePoolKeyLib.sortedCurrencies(tokenA, tokenB);
        (amount0Desired, amount1Desired) =
            tokenAIsCurrency0 ? (amountADesired, amountBDesired) : (amountBDesired, amountADesired);
        poolKey = MemeversePoolKeyLib.hookPoolKey(tokenA, tokenB, address(hook));
    }

    function _addLiquidityViaHook(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        address payer
    ) internal returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        BalanceDelta delta;
        (liquidity, delta) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                to: to
            })
        );

        (amount0Used, amount1Used) = _handleAddLiquiditySettlement(
            key.currency0, key.currency1, delta, amount0Desired, amount1Desired, amount0Min, amount1Min, payer
        );
    }

    function _approvePreparedAddLiquidityBudgets(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal {
        _ensureHookApproval(currency0, amount0Desired);
        _ensureHookApproval(currency1, amount1Desired);
    }

    function _handleAddLiquiditySettlement(
        Currency currency0,
        Currency currency1,
        BalanceDelta delta,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address payer
    ) internal returns (uint256 amount0Used, uint256 amount1Used) {
        (amount0Used, amount1Used) = _spentLiquidityAmounts(delta);
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert IMemeverseUniswapHook.TooMuchSlippage();
        }
        if (amount0Used < amount0Min || amount1Used < amount1Min) {
            revert IMemeverseUniswapHook.TooMuchSlippage();
        }

        _refundUnusedInput(currency0, payer, amount0Desired, amount0Used);
        _refundUnusedInput(currency1, payer, amount1Desired, amount1Used);
    }

    function _ensureHookApproval(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        if (IERC20Minimal(token).allowance(address(this), address(hook)) < amount) {
            if (!IERC20Minimal(token).approve(address(hook), type(uint256).max)) {
                revert ERC20ApproveFailed();
            }
        }
    }

    function _refundUnusedInput(Currency currency, address recipient, uint256 desiredAmount, uint256 usedAmount)
        internal
    {
        if (desiredAmount <= usedAmount) return;
        unchecked {
            currency.transferWithGuard(recipient, desiredAmount - usedAmount);
        }
    }

    function _swapInputContext(PoolKey calldata key, SwapParams calldata params, uint256 amountInMaximum)
        internal
        pure
        returns (Currency inputCurrency, uint256 inputBudget)
    {
        inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        inputBudget = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : amountInMaximum;
    }

    /// @dev Validates that the lens has deployed code and reads from the same PoolManager as the router.
    function _validateHookLens(IMemeverseUniswapHookLens newLens) internal view {
        address newLensAddress = address(newLens);
        if (newLensAddress.code.length == 0) revert HookLensCodeNotReady(newLensAddress);

        address expectedPoolManager = address(poolManager);
        address actualPoolManager = address(newLens.poolManager());
        // Quotes must read slot0 and liquidity from the same PoolManager used for routed swaps.
        if (actualPoolManager != expectedPoolManager) {
            revert HookLensPoolManagerMismatch(expectedPoolManager, actualPoolManager);
        }
    }

    function _quoteExactLiquidityAmounts(Currency currency0, Currency currency1, uint128 liquidityDesired)
        internal
        view
        erc20Pair(currency0, currency1)
        returns (uint256 amount0Required, uint256 amount1Required)
    {
        PoolKey memory key =
            MemeversePoolKeyLib.hookPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), address(hook));
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return _exactLiquidityAmountsAtPrice(sqrtPriceX96, liquidityDesired);
    }

    function _exactLiquidityAmountsAtPrice(uint160 sqrtPriceX96, uint128 liquidityDesired)
        internal
        pure
        returns (uint256 amount0Required, uint256 amount1Required)
    {
        if (sqrtPriceX96 <= LiquidityQuote.MIN_SQRT_PRICE_X96) {
            amount0Required = SqrtPriceMath.getAmount0Delta(
                LiquidityQuote.MIN_SQRT_PRICE_X96, LiquidityQuote.MAX_SQRT_PRICE_X96, liquidityDesired, true
            );
        } else if (sqrtPriceX96 < LiquidityQuote.MAX_SQRT_PRICE_X96) {
            amount0Required =
                SqrtPriceMath.getAmount0Delta(sqrtPriceX96, LiquidityQuote.MAX_SQRT_PRICE_X96, liquidityDesired, true);
            amount1Required =
                SqrtPriceMath.getAmount1Delta(LiquidityQuote.MIN_SQRT_PRICE_X96, sqrtPriceX96, liquidityDesired, true);
        } else {
            amount1Required = SqrtPriceMath.getAmount1Delta(
                LiquidityQuote.MIN_SQRT_PRICE_X96, LiquidityQuote.MAX_SQRT_PRICE_X96, liquidityDesired, true
            );
        }
    }

    function _canonicalHookPoolKey(Currency currency0, Currency currency1)
        internal
        view
        erc20Pair(currency0, currency1)
        returns (PoolKey memory)
    {
        return MemeversePoolKeyLib.hookPoolKey(Currency.unwrap(currency0), Currency.unwrap(currency1), address(hook));
    }

    function _normalizePairAmounts(Currency currencyA, Currency currencyB, uint256 amountA, uint256 amountB)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        address tokenA = Currency.unwrap(currencyA);
        address tokenB = Currency.unwrap(currencyB);
        if (tokenA < tokenB) {
            return (amountA, amountB);
        }
        return (amountB, amountA);
    }

    function _spentLiquidityAmounts(BalanceDelta delta)
        internal
        pure
        returns (uint256 amount0Used, uint256 amount1Used)
    {
        amount0Used = uint256((-delta.amount0()).toUint128());
        amount1Used = uint256((-delta.amount1()).toUint128());
    }

    function _receivedLiquidityAmounts(BalanceDelta delta)
        internal
        pure
        returns (uint256 amount0Received, uint256 amount1Received)
    {
        amount0Received = uint256(delta.amount0().toUint128());
        amount1Received = uint256(delta.amount1().toUint128());
    }

    function _swapPermit2Witness(
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData
    ) internal pure returns (bytes32 witness) {
        witness = keccak256(
            abi.encode(
                SWAP_WITNESS_TYPEHASH,
                key.toId(),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                recipient,
                deadline,
                amountOutMinimum,
                amountInMaximum,
                keccak256(hookData)
            )
        );
    }

    function _addLiquidityPermit2Witness(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) internal pure returns (bytes32 witness) {
        witness = keccak256(
            abi.encode(
                ADD_LIQUIDITY_WITNESS_TYPEHASH,
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                amount0Desired,
                amount1Desired,
                amount0Min,
                amount1Min,
                to,
                deadline
            )
        );
    }

    function _removeLiquidityPermit2Witness(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) internal pure returns (bytes32 witness) {
        witness = keccak256(
            abi.encode(
                REMOVE_LIQUIDITY_WITNESS_TYPEHASH,
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                liquidity,
                amount0Min,
                amount1Min,
                to,
                deadline
            )
        );
    }
}
