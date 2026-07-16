// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {IMemeverseUniswapHookLens} from "./IMemeverseUniswapHookLens.sol";
import {IMemeverseUniswapHook} from "./IMemeverseUniswapHook.sol";

/// @title IMemeverseSwapRouter
/// @notice User-facing interface for the Memeverse swap router.
/// @dev Exposes the router's quote, swap, liquidity, and fee-claim entrypoints and custom errors.
interface IMemeverseSwapRouter {
    /// @notice Permit2 parameters for a single ERC20 pull.
    struct Permit2SingleParams {
        ISignatureTransfer.PermitTransferFrom permit;
        ISignatureTransfer.SignatureTransferDetails transferDetails;
        bytes signature;
    }

    /// @notice Permit2 parameters for one or more ERC20 pulls in a batch.
    struct Permit2BatchParams {
        ISignatureTransfer.PermitBatchTransferFrom permit;
        ISignatureTransfer.SignatureTransferDetails[] transferDetails;
        bytes signature;
    }

    /// @notice Reverts when the pool key does not use the configured Memeverse hook.
    error InvalidHook();

    /// @notice Reverts when `deadline` has passed.
    error ExpiredPastDeadline();

    /// @notice Reverts when the swap amount is zero.
    error SwapAmountCannotBeZero();

    /// @notice Reverts when an exact-output swap omits `amountInMaximum`.
    error AmountInMaximumRequired();

    /// @notice Reverts when the required input exceeds `amountInMaximum`.
    error InputAmountExceedsMaximum(uint256 actualInputAmount, uint256 amountInMaximum);

    /// @notice Reverts when the received output is below `amountOutMinimum`.
    error OutputAmountBelowMinimum(uint256 actualOutputAmount, uint256 amountOutMinimum);

    /// @notice Reverts when bootstrap uses identical token addresses.
    error InvalidTokenPair();

    /// @notice Reverts when Permit2 batch arrays do not match the expected ERC20 funding leg count.
    error InvalidPermit2Length();

    /// @notice Reverts when a Permit2 batch entry does not match the expected token ordering.
    error InvalidPermit2Token(uint256 index, address expectedToken, address actualToken);

    /// @notice Reverts when a launcher-only bootstrap function is called by any other account.
    error UnauthorizedLauncher();

    /// @notice Reverts when a lens address has no deployed bytecode.
    /// @param lens Address that failed the code check.
    error HookLensCodeNotReady(address lens);

    /// @notice Reverts when a lens reads pool state from a different PoolManager than the router.
    /// @param expectedPoolManager PoolManager bound to the router.
    /// @param actualPoolManager PoolManager bound to the lens.
    error HookLensPoolManagerMismatch(address expectedPoolManager, address actualPoolManager);

    /// @notice Exposes the Memeverse hook wired into this router.
    /// @dev Integrations can use this to confirm they are quoting and routing against the expected deployment.
    /// @return memeverseHook Hook that owns fee logic and LP accounting.
    function hook() external view returns (IMemeverseUniswapHook memeverseHook);

    /// @notice Exposes the Permit2 contract used for signature-based ERC20 funding.
    /// @dev Exposed so frontends can build signatures against the exact Permit2 deployment the router expects.
    /// @return permit2Contract Permit2 entrypoint used by this router.
    function permit2() external view returns (IPermit2 permit2Contract);

    /// @notice Exposes the read-only hook lens used by quote and preview APIs.
    /// @return lens Current lens contract.
    function hookLens() external view returns (IMemeverseUniswapHookLens lens);

    /// @notice Request the hook's current swap quote so integrations can preview fees, side, and expected flows.
    /// @dev This router-first facade keeps quote logic centralized while reusing the hook's internal math.
    ///      The configured Lens uses `STATICCALL` so EIP-214 read-only enforcement reaches the delegated facet.
    /// @param key Pool key being quoted.
    /// @param params Swap parameters that define direction, amount, and slippage posture.
    /// @param trader Address whose per-address batch state determines the adverse fee component.
    /// @return quote A projected swap quote describing fees, estimated user input/output, and protocol split.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params, address trader)
        external
        view
        returns (IMemeverseUniswapHook.SwapQuote memory quote);

    /// @notice Derive the hook-managed pool key that corresponds to a given token pair.
    /// @dev Sorts the tokens canonically and attaches the router's hook configuration before delegating to the hook.
    /// @param tokenA One side of the pair.
    /// @param tokenB The other side of the pair.
    /// @return key Canonical hook pool key for the pair.
    function getHookPoolKey(address tokenA, address tokenB) external view returns (PoolKey memory key);

    /// @notice Preview how much LP fee an owner can claim for a token pair.
    /// @dev Resolves the hook pool key before delegating fee math to the hook.
    /// @param tokenA One side of the pair.
    /// @param tokenB The other side of the pair.
    /// @param owner LP owner whose pending fees are being inspected.
    /// @return fee0 Preview claimable amount in currency0.
    /// @return fee1 Preview claimable amount in currency1.
    function previewClaimableFees(address tokenA, address tokenB, address owner)
        external
        view
        returns (uint256 fee0, uint256 fee1);

    /// @notice Return the LP token contract for the hook-managed pair formed by two tokens.
    /// @dev Handy when integrations know the ERC20 addresses but need the minted LP token contract.
    /// @param tokenA One side of the pair.
    /// @param tokenB The other side of the pair.
    /// @return liquidityToken LP token contract for the pair.
    function lpToken(address tokenA, address tokenB) external view returns (address liquidityToken);

    /// @notice Quote how much of each pool token the router would spend to mint a desired liquidity amount.
    /// @dev Mirrors the math that the router and hook apply when adding full-range liquidity.
    /// @param tokenA One side of the pair.
    /// @param tokenB The other side of the pair.
    /// @param liquidityDesired Target LP liquidity to mint.
    /// @return amountARequired Required amount of `tokenA`.
    /// @return amountBRequired Required amount of `tokenB`.
    function quoteAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        returns (uint256 amountARequired, uint256 amountBRequired);

    /// @notice Quote the exact-path token amounts the router will use for an exact-liquidity mint at current slot0.
    /// @dev Unlike `quoteAmountsForLiquidity(...)`, this method may return the unpadded floor amounts when they already
    /// mint the requested liquidity, so exact-liquidity callers are not forced to over-budget against conservative padding.
    /// @param tokenA One side of the pair.
    /// @param tokenB The other side of the pair.
    /// @param liquidityDesired Target LP liquidity to mint.
    /// @return amountARequired Exact-path amount of `tokenA`.
    /// @return amountBRequired Exact-path amount of `tokenB`.
    function quoteExactAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        returns (uint256 amountARequired, uint256 amountBRequired);

    /// @notice Execute a swap through the Memeverse hook with router-managed slippage and caller-directed refunds.
    /// @dev Swaps always settle or revert; the caller must cover slippage via `amountOutMinimum` or `amountInMaximum`.
    /// @param key Pool key to swap against.
    /// @param params Swap parameters shaping direction, amounts, and price impact.
    /// @param recipient Address that should receive the swap output.
    /// @param deadline Timestamp by which the call must execute.
    /// @param amountOutMinimum Minimum net output the caller is willing to accept.
    /// @param amountInMaximum Maximum input the caller allows for exact-output swaps.
    /// @param hookData Opaque hook data forwarded to `poolManager.swap`.
    /// @return delta Balance delta describing the net token movement settled by the swap.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData
    ) external returns (BalanceDelta delta);

    /// @notice Execute a swap after funding the router via Permit2 signature transfer.
    /// @dev Behaves identically to `swap(...)` once the Permit2 pull completes.
    /// @custom:security Callers must sign Permit2 data that matches the intended input budget and token.
    /// @param permitParams Permit2 single-transfer parameters and signature for the routed input.
    /// @param key The pool key to swap against.
    /// @param params The swap parameters.
    /// @param recipient The address receiving any swap output.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @param amountOutMinimum The minimum net output the caller is willing to receive.
    /// @param amountInMaximum The maximum input the caller is willing to pay.
    /// @param hookData Opaque hook data forwarded to `poolManager.swap`.
    /// @return delta The final swap delta.
    function swapWithPermit2(
        Permit2SingleParams calldata permitParams,
        PoolKey calldata key,
        SwapParams calldata params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes calldata hookData
    ) external returns (BalanceDelta delta);

    /// @notice Add liquidity via the hook core while the router finalizes exact spend, enforces minimums, and refunds leftovers.
    /// @dev The router pulls desired budgets, resolves actual full-range spend at the current price, and forwards only what the hook needs.
    /// @custom:security Callers must approve ERC20 inputs to the router before calling and set min amounts that match their slippage tolerance.
    /// @param currency0 Pool currency0.
    /// @param currency1 Pool currency1.
    /// @param amount0Desired Desired currency0 budget.
    /// @param amount1Desired Desired currency1 budget.
    /// @param amount0Min Minimum currency0 spend accepted after routing to the hook.
    /// @param amount1Min Minimum currency1 spend accepted after routing to the hook.
    /// @param to Recipient of minted LP shares.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return liquidity The LP liquidity minted to `to`.
    function addLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint128 liquidity);

    /// @notice Add liquidity and return both minted LP liquidity and the actual token spend.
    /// @dev The router normalizes pool ordering internally and returns the actual spend in the same argument order
    /// supplied by the caller, bounded by the desired budgets.
    /// @custom:security Callers must approve ERC20 inputs to the router before calling and set min amounts that match their slippage tolerance.
    /// @param currency0 First currency supplied by the caller.
    /// @param currency1 Second currency supplied by the caller.
    /// @param amount0Desired Maximum budget for `currency0`.
    /// @param amount1Desired Maximum budget for `currency1`.
    /// @param amount0Min Minimum spend accepted for `currency0`.
    /// @param amount1Min Minimum spend accepted for `currency1`.
    /// @param to Recipient of minted LP shares.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return liquidity The LP liquidity minted to `to`.
    /// @return amount0Used Actual amount spent for `currency0`.
    /// @return amount1Used Actual amount spent for `currency1`.
    function addLiquidityDetailed(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);

    /// @notice Add liquidity after covering the ERC20 sides through a Permit2 signature transfer.
    /// @dev Once Permit2 funding succeeds, execution follows the same path as `addLiquidity(...)`.
    /// @custom:security The batch Permit2 payload must align with the ERC20 side(s) of this call.
    /// @param permitParams Permit2 batch-transfer parameters and signature that fund the ERC20 legs.
    /// @param currency0 Pool currency0.
    /// @param currency1 Pool currency1.
    /// @param amount0Desired Desired currency0 budget.
    /// @param amount1Desired Desired currency1 budget.
    /// @param amount0Min Minimum currency0 spend accepted.
    /// @param amount1Min Minimum currency1 spend accepted.
    /// @param to Recipient of minted LP shares.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return liquidity The LP liquidity minted to `to`.
    function addLiquidityWithPermit2(
        Permit2BatchParams calldata permitParams,
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint128 liquidity);

    /// @notice Remove liquidity through the hook while the router enforces min outputs and sends the underlying assets forward.
    /// @dev The router pulls LP shares, burns them, and forwards the hook's balance delta after validating slippage.
    /// @custom:security Callers must approve LP shares to the router and set output minimums to enforce slippage.
    /// @param currency0 Pool currency0.
    /// @param currency1 Pool currency1.
    /// @param liquidity LP liquidity to burn.
    /// @param amount0Min Minimum currency0 output accepted.
    /// @param amount1Min Minimum currency1 output accepted.
    /// @param to Recipient of withdrawn assets.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return delta The balance delta returned by the hook core.
    function removeLiquidity(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (BalanceDelta delta);

    /// @notice Remove liquidity after funding the LP side via Permit2 signature transfer.
    /// @dev After Permit2 funding succeeds, execution follows the same path as `removeLiquidity(...)`.
    /// @custom:security The Permit2 payload must authorize the hook LP token transfer required by this call.
    /// @param permitParams Permit2 single-transfer parameters and signature covering the LP token.
    /// @param currency0 Pool currency0.
    /// @param currency1 Pool currency1.
    /// @param liquidity LP liquidity to burn.
    /// @param amount0Min Minimum currency0 output accepted.
    /// @param amount1Min Minimum currency1 output accepted.
    /// @param to Recipient of withdrawn assets.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return delta The balance delta returned by the hook core.
    function removeLiquidityWithPermit2(
        Permit2SingleParams calldata permitParams,
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (BalanceDelta delta);

    /// @notice Initialize a hook-managed pool and seed its first full-range liquidity position.
    /// @dev Launcher-only. The router sorts the token pair, initializes the pool at `startPrice`, adds liquidity,
    /// and refunds unused input.
    /// @custom:security Token addresses must be distinct.
    /// @param tokenA One side of the pool pair.
    /// @param tokenB The other side of the pool pair.
    /// @param amountADesired Desired budget for `tokenA`.
    /// @param amountBDesired Desired budget for `tokenB`.
    /// @param startPrice The initial `sqrtPriceX96` passed to the pool manager.
    /// @param recipient Recipient of minted LP shares.
    /// @param deadline The latest timestamp at which the call is valid.
    /// @return liquidity The minted LP liquidity.
    /// @return poolKey The initialized pool key.
    /// @return amountAUsed Actual spend for `tokenA`.
    /// @return amountBUsed Actual spend for `tokenB`.
    function createPoolAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint160 startPrice,
        address recipient,
        uint256 deadline
    ) external returns (uint128 liquidity, PoolKey memory poolKey, uint256 amountAUsed, uint256 amountBUsed);
}
