// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {SettlementSettleReenterer} from "../mocks/swap/SettlementSettleReenterer.sol";

/// @title SettlementSamePoolReentrancyTest
/// @notice A callback-token same-pool reentry during the settlement settle/take window is
///         blocked by the per-pool swap-lifecycle lock.
/// @dev The settlement swap is a hook self-call, so v4 skips beforeSwap/afterSwap for it and the
///      `SwapFacet.beforeSwapLogic` lock never engages on the settlement's own swap. `SettlementFacet` therefore
///      acquires/releases the lock itself around its swap → settle/take window. This test arms a callback token
///      that is BOTH the settlement pool's input currency AND the reentry caller, with `forgedKey == settlementPoolKey`
///      so the reentrant `poolManager.swap` targets the SAME pool whose lock the outer settlement holds. The
///      reentrant swap reenters `SwapFacet.beforeSwapLogic`, the acquire fails with `SwapLifecycleReentrant`, and
///      that revert bubbles through the settle transfer back into the settlement and reverts the whole unlock.
///
///      v4 wraps a `beforeSwap` hook revert as `CustomRevert.WrappedError(target, beforeSwap.selector, reason, details)`,
///      so the settlement surfaces a `WrappedError`, not the raw `SwapLifecycleReentrant` selector. The test
///      decodes the wrapped `reason` and asserts it carries `SwapLifecycleReentrant.selector`: that selector is
///      reachable ONLY via the reentrant public-path swap failing the acquire in `beforeSwapLogic` (the hook's own
///      settlement swap skips v4 callbacks), so its presence proves both that the settle/take window was reached
///      AND that the lock tripped.
///
///      Cross-pool reentry is documented as permitted (per-pool lock) by `SettlementReentrancyRealV4.t.sol`, which
///      proves a reentry targeting a DIFFERENT poolId completes successfully; this file focuses only on the
///      same-pool block.
///
///      Does NOT inherit any upgradeable production contract — `HookStorageHelper` is a standalone Test helper
///      and all hook interaction is via the external `MemeverseUniswapHook` interface.
contract SettlementSamePoolReentrancyTest is Test, HookStorageHelper {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Selector of v4's `CustomRevert.WrappedError(address,bytes4,bytes,bytes)` — the ERC-7751 wrapper v4 uses
    // when a hook's beforeSwap/afterSwap revert bubbles back through PoolManager.swap.
    bytes4 internal constant _WRAPPED_ERROR_SELECTOR = bytes4(0x90bfb865);
    // Selector of v4's `IHooks.beforeSwap` callback — the `selector` field v4 stores in the WrappedError when a
    // beforeSwap revert bubbles up. Confirming it proves the wrapped revert came from the beforeSwap entry, not
    // some unrelated hook callback.
    bytes4 internal constant _BEFORE_SWAP_SELECTOR = bytes4(0x575e24b4);

    IPoolManager internal manager;
    MemeverseUniswapHook internal hook;
    SettlementSettleReenterer internal callbackToken;
    MockERC20 internal token1;
    PoolKey internal settlementPoolKey;
    bool internal settlementZeroForOne;
    address internal treasury = address(0xFEE);

    function setUp() public {
        manager = deployRealPoolManager();
        token1 = new MockERC20("Token1", "TK1", 18);
        // The callback token is BOTH the settlement pool's input currency AND the reentry caller. Its transfer
        // callback fires inside `CurrencySettler.settle` during the settlement unlock window.
        callbackToken = new SettlementSettleReenterer();

        token1.mint(address(this), 1_000_000 ether);
        callbackToken.mint(address(this), 1_000_000 ether);
        // The callback token is the caller of the inner swap and must pay its own reentrant input leg.
        callbackToken.mint(address(callbackToken), 100 ether);

        address hookProxy = deployHookAtFlagAddress(manager, address(this), treasury);
        hook = MemeverseUniswapHook(hookProxy);
        hook.setLauncher(address(this));
        hook.setPoolInitializer(address(this));

        token1.approve(address(hook), type(uint256).max);
        callbackToken.approve(address(hook), type(uint256).max);

        settlementPoolKey = _dynamicPoolKey(address(callbackToken), address(token1));
        settlementZeroForOne = Currency.unwrap(settlementPoolKey.currency0) == address(callbackToken);

        _initializeAndFundPool(settlementPoolKey);

        // Register callbackToken as a protocol-fee token so the input leg deterministically carries the
        // fee (registration selects the leg; the input-side fee would also fire for an ordinary pool).
        hook.setProtocolFeeCurrency(Currency.wrap(address(callbackToken)), true);
        vm.warp(block.timestamp + 900);
    }

    /// @notice Same-pool reentry during the settlement settle/take window is blocked — the settlement surfaces a
    ///         v4-wrapped `SwapLifecycleReentrant` and reverts.
    /// @dev The callback token's `forgedKey` IS the settlement pool, so its reentrant swap reenters
    ///      `SwapFacet.beforeSwapLogic` on the poolId whose lock the outer settlement holds. The acquire fails,
    ///      and v4 wraps the `beforeSwap` revert into `CustomRevert.WrappedError`; that wrapper bubbles through
    ///      `transfer` → `CurrencySettler.settle` → `settlementUnlockCallback` and reverts the unlock. The test
    ///      asserts the wrapped `reason` carries `SwapLifecycleReentrant.selector`, which can only originate from
    ///      the reentrant public-path swap hitting the lock (the hook's own settlement swap skips v4 callbacks).
    function test_SamePoolSettleReentryRevertsSwapLifecycleReentrant() public {
        callbackToken.arm(manager, settlementPoolKey, _reentrySwapParams());

        // Open a session so the reentrant callback-token public swap passes the session gate and reaches the
        // per-pool lifecycle lock (asserted `SwapLifecycleReentrant`), not the session gate. The settlement
        // self-call itself skips v4 callbacks and is unaffected by the session.
        hook.beginAccountSession();
        bytes memory reason = _captureSettlementRevert();
        hook.endAccountSession();

        // v4 wraps the beforeSwap hook revert as WrappedError(target, beforeSwap.selector, reason, details).
        // Decode the inner reason (offset at WrappedError field index 2) and assert it is SwapLifecycleReentrant.
        assertEq(_wrappedReasonSelector(reason), IMemeverseUniswapHook.SwapLifecycleReentrant.selector);
    }

    /// @dev Invokes the settlement inside a try/catch so the reverted bytes are inspectable. The catch body
    ///      requires an external call (forge-std rule), so this helper is `external` and only called from the test.
    function _captureSettlementRevert() internal returns (bytes memory reason) {
        try this._runSettlementReverting() {
            revert("expected settlement to revert");
        } catch (bytes memory revertData) {
            return revertData;
        }
    }

    /// @notice External settlement runner used only by `_captureSettlementRevert` so the revert can be caught.
    function _runSettlementReverting() external {
        hook.executePreorderSettlement(
            IMemeverseUniswapHook.PreorderSettlementParams({
                key: settlementPoolKey, params: _settlementSwapParams(), recipient: address(this)
            })
        );
    }

    /// @dev Extracts the wrapped `reason` selector from a `CustomRevert.WrappedError(target, selector, reason, details)`.
    ///      v4 wraps a beforeSwap hook revert as this ERC-7751 error; the `reason` bytes carry the original hook
    ///      revert data, whose leading 4 bytes are the hook's error selector. Decodes the ABI body inline
    ///      (`bytes` slice access is calldata-only, so the offsets are resolved via assembly over `wrapped`).
    function _wrappedReasonSelector(bytes memory wrapped) internal pure returns (bytes4 selector) {
        if (bytes4(wrapped) != _WRAPPED_ERROR_SELECTOR) {
            // Not a WrappedError (e.g. an earlier guard tripped) — surface the raw selector for diagnosis.
            return bytes4(wrapped);
        }
        // WrappedError body follows the 4-byte selector at `wrapped + 0x24` (wrapped points at its length word).
        // Head layout (each 32 bytes): [0] address | [1] bytes4 (right-aligned) | [2] reason offset | [3] details offset.
        // The `bytes4` arg is right-aligned in its head slot, so the low 4 bytes of the 32-byte word carry it.
        bytes4 fnSelector;
        uint256 reasonOffset;
        assembly {
            fnSelector := mload(add(wrapped, 0x44)) // selector + Head[0] (address, 0x20) = 0x24 + 0x20 = 0x44
            reasonOffset := mload(add(wrapped, 0x64)) // + Head[1] (0x20) = 0x64 → Head[2] reason offset
        }
        require(fnSelector == _BEFORE_SWAP_SELECTOR, "wrapped revert not from beforeSwap");
        // reason is a dynamic `bytes`: reasonOffset is relative to the body start (immediately after the 4-byte
        // error selector). `wrapped` points at the length word, so data starts at wrapped+0x20; body starts at
        // wrapped+0x24. The reason length word lives at wrapped+0x24+reasonOffset, reason data 0x20 after it.
        uint256 reasonLen;
        uint256 reasonDataRel = 0x24 + reasonOffset + 0x20;
        assembly {
            reasonLen := mload(add(wrapped, sub(reasonDataRel, 0x20)))
        }
        require(reasonLen >= 4, "wrapped reason too short");
        assembly {
            selector := mload(add(wrapped, reasonDataRel))
        }
    }

    function _reentrySwapParams() internal pure returns (SwapParams memory) {
        // Direction follows the settlement pool so the callback token pays its own input leg.
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _settlementSwapParams() internal view returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: settlementZeroForOne,
            amountSpecified: -int256(10 ether),
            sqrtPriceLimitX96: settlementZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _dynamicPoolKey(address currencyA, address currencyB) internal view returns (PoolKey memory key) {
        (address currency0, address currency1) = currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _initializeAndFundPool(PoolKey memory key) internal {
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: address(this)
            })
        );
    }
}
