// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {LiquidityAmounts} from "../../../src/swap/libraries/LiquidityAmounts.sol";

/// @dev Mock-harness boundary:
/// - RealisticSwapManagerHarness is a simplified PoolManager used by the integration test base.
///   It only covers the swap/liquidity/settle/take paths exercised by the integration tests,
///   plus the extsload override hooks those tests rely on. It must not be used to infer
///   broader PoolManager economics outside that subset.
contract RealisticSwapManagerHarness {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error ManagerLocked();
    error AlreadyUnlocked();
    error CurrencyNotSettled();
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    struct Slot0State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    bytes internal constant ZERO_BYTES = bytes("");
    // Mirrors v4 `StateLibrary.POOLS_SLOT` (v4-core/src/libraries/StateLibrary.sol:11) and
    // `LIQUIDITY_OFFSET` (ibid.:19) so `StateLibrary.getSlot0/getLiquidity` can read mock state
    // through `extsload` exactly as it reads real singleton storage. BRITTLE COUPLING: if v4
    // changes its `_pools` mapping slot or the `Pool.State` field layout, these constants and
    // `_syncPoolStorage` must be updated in lockstep, or DrainedPool/integration tests silently
    // read stale/zero values. Re-verify on any v4-core bump.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    bool internal unlocked;
    mapping(bytes32 => bytes32) internal extStorage;
    mapping(bytes32 => bool) internal isPoolStateSlot;
    mapping(bytes32 => PoolId) internal poolIdForStateSlot;
    mapping(PoolId => Slot0State) internal slot0State;
    mapping(PoolId => uint128) internal liquidityState;
    mapping(PoolId => uint256) internal nextExactInputPoolInputAmount;
    mapping(PoolId => uint256) internal nextExactOutputAmount;
    mapping(PoolId => bool) internal hasNextExactOutputAmount;
    mapping(PoolId => uint160) internal nextSwapSqrtPriceX96;
    mapping(PoolId => mapping(address => uint160)) internal callerSlot0OverrideX96;
    mapping(bytes32 => int256) internal currencyDeltaState;
    /// @dev Per-currency backed amount: total tokens available for take() for this currency.
    ///      Increased when a caller settles (transfers tokens to manager); decreased on take().
    mapping(Currency => uint256) internal backedAmountState;
    mapping(Currency => address[]) internal deltaAddressesForCurrency;
    mapping(bytes32 => bool) internal isTrackedDeltaAddress;
    bool internal syncedCurrencySet;
    Currency internal syncedCurrency;
    uint256 internal syncedReserves;
    uint256 internal nonzeroDeltaCount;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        // No self-call skip needed here: production never calls poolManager.initialize from within
        // the hook — the only call site is MemeverseSwapRouter.createPoolAndAddLiquidity
        // (MemeverseSwapRouter.sol:519), where msg.sender is the router, not the hook. So the v4
        // `msg.sender == address(key.hooks)` skip condition is never met for initialize, and
        // beforeInitialize correctly fires in both real v4 and this mock. Also note: real v4 calls
        // afterInitialize here (PoolManager.sol:140); this mock omits it because the production
        // hook sets `afterInitialize: false` (MemeverseUniswapHookUpgradeable.sol:440).
        PoolId poolId = key.toId();
        slot0State[poolId] = Slot0State({sqrtPriceX96: sqrtPriceX96, tick: 0, protocolFee: 0, lpFee: 0});
        _syncPoolStorage(poolId);
        key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
        return 0;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (nonzeroDeltaCount != 0) revert CurrencyNotSettled();
        unlocked = false;
        syncedCurrencySet = false;
        syncedCurrency = Currency.wrap(address(0));
        syncedReserves = 0;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        hookData;
        if (!unlocked) revert ManagerLocked();
        uint256 amount0Used;
        uint256 amount1Used;

        if (params.liquidityDelta > 0) {
            // Real v4 skips beforeModifyLiquidity/afterModifyLiquidity when msg.sender == address(key.hooks)
            // (Hooks.sol noSelfCall guard). Production addLiquidityCore/removeLiquidityCore route through
            // poolManager.unlock() reentry (MemeverseUniswapHookUpgradeable.sol:647), so msg.sender here IS the hook;
            // the beforeAddLiquidity callback must be skipped to match v4, otherwise the mock double-fires
            // the hook's beforeAddLiquidityLogic on every LP add/remove.
            if (msg.sender != address(key.hooks)) {
                key.hooks.beforeAddLiquidity(msg.sender, key, params, ZERO_BYTES);
            }
            liquidityState[key.toId()] += uint128(uint256(params.liquidityDelta));
            _syncPoolStorage(key.toId());
            (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
                slot0State[key.toId()].sqrtPriceX96,
                TickMath.MIN_SQRT_PRICE + 1,
                TickMath.MAX_SQRT_PRICE - 1,
                uint128(uint256(params.liquidityDelta))
            );
            delta = toBalanceDelta(-int128(int256(amount0Used)), -int128(int256(amount1Used)));
            _accountPoolBalanceDelta(key, delta, msg.sender);
            return (delta, feesAccrued);
        }

        liquidityState[key.toId()] -= uint128(uint256(-params.liquidityDelta));
        _syncPoolStorage(key.toId());
        (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
            slot0State[key.toId()].sqrtPriceX96,
            TickMath.MIN_SQRT_PRICE + 1,
            TickMath.MAX_SQRT_PRICE - 1,
            uint128(uint256(-params.liquidityDelta))
        );
        delta = toBalanceDelta(int128(int256(amount0Used)), int128(int256(amount1Used)));
        _accountPoolBalanceDelta(key, delta, msg.sender);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        // PREREQUISITE on the production hook under test: all LP and protocol fees must be
        // collected at the hook layer (beforeSwap/afterSwap deltas), so the pool runs with
        // zero pool-level fee. Real v4 `Pool.swap` charges swapFee (lpFee + protocolFee) on
        // the input leg inside the step loop and accrues protocol fee via `_updateProtocolFees`
        // (Pool.sol:279-). This mock's `_exactInputDelta`/`_exactOutputDelta` perform pure
        // SqrtPriceMath with NO fee deduction and NO protocol fee accrual. If a future hook
        // revision relies on pool-level static fee (non-dynamic `key.fee`), these tests will
        // silently miss that path — route such changes to the fork suite instead.
        if (!unlocked) revert ManagerLocked();

        PoolId poolId = key.toId();
        Slot0State memory state = slot0State[poolId];
        _validatePriceLimit(state.sqrtPriceX96, params);

        // Real v4 skips both swap callbacks when the hook itself calls PoolManager.swap. Other callers,
        // including callback-token reentry, still execute the configured hook callbacks.
        bool callSwapHooks = msg.sender != address(key.hooks);
        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        int256 amountToSwap = params.amountSpecified;
        if (callSwapHooks) {
            (, beforeSwapDelta,) = key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }
        amountToSwap += beforeSwapDelta.getSpecifiedDelta();

        BalanceDelta poolDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if (amountToSwap != 0) {
            if (params.amountSpecified < 0) {
                poolDelta = _exactInputDelta(poolId, state.sqrtPriceX96, params.zeroForOne, uint256(-amountToSwap));
            } else {
                poolDelta = _exactOutputDelta(poolId, state.sqrtPriceX96, params.zeroForOne, uint256(amountToSwap));
            }
        }

        _applyNextSwapPriceOverride(poolId);

        int128 afterSwapUnspecifiedDelta;
        if (callSwapHooks) {
            (, afterSwapUnspecifiedDelta) = key.hooks.afterSwap(msg.sender, key, params, poolDelta, hookData);
        }

        int128 hookDeltaSpecified = beforeSwapDelta.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapDelta.getUnspecifiedDelta() + afterSwapUnspecifiedDelta;
        BalanceDelta callerDelta = poolDelta;
        if (hookDeltaSpecified != 0 || hookDeltaUnspecified != 0) {
            BalanceDelta hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
            _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));
            callerDelta = poolDelta - hookDelta;
        }

        _accountPoolBalanceDelta(key, callerDelta, msg.sender);
        return callerDelta;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        // INVARIANT divergence from real v4: real `PoolManager.take` (PoolManager.sol:289-295)
        // only does `_accountDelta` + `currency.transfer`; it does NOT pre-check balances — a
        // shortfall surfaces as the transfer itself reverting. This mock adds a two-layer guard:
        // (1) `backedAmountState` (credited in settle() for positive deltas), then
        // (2) a `balanceOf` fallback for currencies funded by the manager's own balance
        //     (e.g. pol output from locking) rather than a caller settle() payment.
        // Behavioral risk: when `backedAmountState[currency] >= amount`, take() succeeds here
        // even if a real v4 transfer would have reverted for a different reason. Do not use
        // this path to assert real take() failure modes — use the fork suite for that.
        uint256 backed = backedAmountState[currency];
        if (backed >= amount) {
            backedAmountState[currency] = backed - amount;
        } else {
            // No backed amount (or insufficient): verify real balance covers the take.
            // This path is used for currencies not settled through a caller's payment
            // (e.g. pol output from pool reserves).  The caller's settle() ensured the
            // manager holds enough of the settled currency; other currencies rely on the
            // manager's existing balance from locking.
            if (currency.isAddressZero()) {
                require(address(this).balance >= amount, "take: insufficient balance");
            } else {
                require(
                    IERC20(Currency.unwrap(currency)).balanceOf(address(this)) >= amount, "take: insufficient balance"
                );
            }
        }
        _accountDelta(currency, -int128(int256(amount)), msg.sender);
        if (currency.isAddressZero()) {
            (bool success,) = to.call{value: amount}("");
            require(success, "native take");
        } else {
            require(MockERC20(Currency.unwrap(currency)).transfer(to, amount), "erc20 take");
        }
    }

    function sync(Currency currency) external {
        if (!unlocked) revert ManagerLocked();
        syncedCurrencySet = true;
        syncedCurrency = currency;
        syncedReserves = currency.isAddressZero() ? 0 : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        if (!unlocked) revert ManagerLocked();

        Currency currency = syncedCurrencySet ? syncedCurrency : Currency.wrap(address(0));
        uint256 paid;
        if (currency.isAddressZero()) {
            paid = msg.value;
        } else {
            uint256 reservesNow = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
            paid = reservesNow - syncedReserves;
        }

        syncedCurrencySet = false;
        syncedCurrency = Currency.wrap(address(0));
        syncedReserves = 0;

        // CAUTION — this is NOT real PoolManager settle() semantics.
        // Real v4 `_settle(recipient)` accounts `paid` to a SINGLE recipient only; each address
        // must settle its own delta (PoolManager.sol:347-363). This mock instead clears ALL
        // non-zero deltas for `currency` in one pass, crediting `backedAmountState` for positive
        // ones. It is a deliberate simplification so a single callback settle() can cover both
        // the caller's pool input and any hook-returned fees without per-address settle calls.
        // Consequence: it can MASK bugs where the hook fails to settle its own negative delta —
        // in real v4 that would leave `nonzeroDeltaCount != 0` and revert at unlock() exit, but
        // here it is silently absorbed. Do not rely on this path to validate hook settle behavior.
        //
        // backedAmountState tracks per-currency tokens available for take().  We credit it
        // only for positive deltas (addresses owed tokens) because the caller's payment backs
        // their claims.  Addresses with negative deltas are the ones paying—they
        // don't receive backing.  This keeps sum(positive deltas) == paid == backed amount.
        address[] storage addrs = deltaAddressesForCurrency[currency];
        for (uint256 i = 0; i < addrs.length; ++i) {
            bytes32 k = keccak256(abi.encode(addrs[i], Currency.unwrap(currency)));
            int256 d = currencyDeltaState[k];
            if (d == 0) continue;
            if (d > 0) {
                // Positive delta: this address is owed tokens.  The caller's payment backs it.
                backedAmountState[currency] += uint256(d);
            }
            currencyDeltaState[k] = 0;
            unchecked {
                --nonzeroDeltaCount;
            }
        }
        return paid;
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        if (isPoolStateSlot[slot]) {
            uint160 overridePriceX96 = callerSlot0OverrideX96[poolIdForStateSlot[slot]][msg.sender];
            if (overridePriceX96 != 0) {
                return bytes32(uint256(overridePriceX96));
            }
        }
        return extStorage[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; ++i) {
            values[i] = extStorage[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            values[i] = extStorage[slots[i]];
        }
    }

    function setNextExactInputPoolInputAmount(PoolId poolId, uint256 amount) external {
        nextExactInputPoolInputAmount[poolId] = amount;
    }

    function setNextExactOutputAmount(PoolId poolId, uint256 amount) external {
        nextExactOutputAmount[poolId] = amount;
        hasNextExactOutputAmount[poolId] = true;
    }

    function setNextSwapSqrtPriceX96(PoolId poolId, uint160 sqrtPriceX96) external {
        nextSwapSqrtPriceX96[poolId] = sqrtPriceX96;
    }

    function setCallerSlot0OverrideX96(PoolId poolId, address caller, uint160 sqrtPriceX96) external {
        callerSlot0OverrideX96[poolId][caller] = sqrtPriceX96;
    }

    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        Slot0State memory state = slot0State[poolId];
        return (state.sqrtPriceX96, state.tick, state.protocolFee, state.lpFee);
    }

    function _validatePriceLimit(uint160 sqrtPriceCurrentX96, SwapParams memory params) internal pure {
        if (params.zeroForOne) {
            if (params.sqrtPriceLimitX96 >= sqrtPriceCurrentX96) {
                revert PriceLimitAlreadyExceeded(sqrtPriceCurrentX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
            return;
        }

        if (params.sqrtPriceLimitX96 <= sqrtPriceCurrentX96) {
            revert PriceLimitAlreadyExceeded(sqrtPriceCurrentX96, params.sqrtPriceLimitX96);
        }
        if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
        }
    }

    function _exactInputDelta(PoolId poolId, uint160 sqrtPriceCurrentX96, bool zeroForOne, uint256 inputAmount)
        internal
        returns (BalanceDelta delta)
    {
        uint256 configuredInputAmount = nextExactInputPoolInputAmount[poolId];
        if (configuredInputAmount != 0) {
            inputAmount = configuredInputAmount;
            delete nextExactInputPoolInputAmount[poolId];
        }

        uint128 liquidity = liquidityState[poolId];
        uint160 nextSqrtPriceX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceCurrentX96, liquidity, inputAmount, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(nextSqrtPriceX96, sqrtPriceCurrentX96, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, nextSqrtPriceX96, liquidity, false);

        slot0State[poolId].sqrtPriceX96 = nextSqrtPriceX96;
        _syncPoolStorage(poolId);

        return zeroForOne
            ? toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)))
            : toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
    }

    function _exactOutputDelta(PoolId poolId, uint160 sqrtPriceCurrentX96, bool zeroForOne, uint256 outputAmount)
        internal
        returns (BalanceDelta delta)
    {
        if (hasNextExactOutputAmount[poolId]) {
            uint256 configuredOutputAmount = nextExactOutputAmount[poolId];
            outputAmount = configuredOutputAmount;
            delete nextExactOutputAmount[poolId];
            delete hasNextExactOutputAmount[poolId];
        }

        uint128 liquidity = liquidityState[poolId];
        uint160 nextSqrtPriceX96 =
            SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceCurrentX96, liquidity, outputAmount, zeroForOne);
        uint256 inputAmount = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(nextSqrtPriceX96, sqrtPriceCurrentX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, nextSqrtPriceX96, liquidity, true);

        slot0State[poolId].sqrtPriceX96 = nextSqrtPriceX96;
        _syncPoolStorage(poolId);

        return zeroForOne
            ? toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)))
            : toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
    }

    function _applyNextSwapPriceOverride(PoolId poolId) internal {
        uint160 overridePriceX96 = nextSwapSqrtPriceX96[poolId];
        if (overridePriceX96 == 0) return;

        slot0State[poolId].sqrtPriceX96 = overridePriceX96;
        _syncPoolStorage(poolId);
        delete nextSwapSqrtPriceX96[poolId];
    }

    function _syncPoolStorage(PoolId poolId) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        Slot0State memory state = slot0State[poolId];

        if (!isPoolStateSlot[stateSlot]) {
            isPoolStateSlot[stateSlot] = true;
            poolIdForStateSlot[stateSlot] = poolId;
        }
        extStorage[stateSlot] = bytes32(uint256(state.sqrtPriceX96));
        extStorage[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidityState[poolId]));
    }

    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }

    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;

        bytes32 slot = keccak256(abi.encode(target, Currency.unwrap(currency)));
        int256 previous = currencyDeltaState[slot];
        int256 next = previous + delta;
        currencyDeltaState[slot] = next;

        if (next == 0) {
            unchecked {
                --nonzeroDeltaCount;
            }
        } else if (previous == 0) {
            unchecked {
                ++nonzeroDeltaCount;
            }
        }

        // Track which addresses have deltas for this currency so settle() can iterate them.
        bytes32 trackKey = keccak256(abi.encode(target, Currency.unwrap(currency), "tracked"));
        if (!isTrackedDeltaAddress[trackKey]) {
            isTrackedDeltaAddress[trackKey] = true;
            deltaAddressesForCurrency[currency].push(target);
        }
    }

    receive() external payable {}
}

contract MockPermit2ForRouterIntegration {
    using SafeERC20 for IERC20;

    address public lastOwner;
    address public lastRecipient;
    address public lastToken;
    uint256 public lastRequestedAmount;
    bytes32 public lastWitness;
    string public lastWitnessTypeString;
    bytes public lastSignature;

    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        lastOwner = owner;
        lastRecipient = transferDetails.to;
        lastToken = permit.permitted.token;
        lastRequestedAmount = transferDetails.requestedAmount;
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastSignature = signature;

        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
