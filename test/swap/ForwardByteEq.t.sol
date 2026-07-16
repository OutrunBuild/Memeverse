// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ISwapFacet} from "../../src/swap/interfaces/ISwapFacet.sol";
import {ISettlementFacet} from "../../src/swap/interfaces/ISettlementFacet.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";

/// @notice Forward byte-equality drift guard: proves `bytes.concat(innerSelector, msg.data[4:])` is byte-identical to
///         `abi.encodeCall(innerFunc, (args))` for every thin entry whose inner `*Logic` signature mirrors
///         the outer entry 1:1. This is the invariant that lets `MemeverseUniswapHook._forwardCalldata`
///         skip abi re-encoding. If a future signature change breaks the 1:1 mirror, the matching probe
///         call reverts here instead of silently corrupting the facet dispatch.
contract ForwardByteEqProbe {
    /// @dev Reverts with a labeled message if the selector-swap encoding differs from the canonical
    ///      `abi.encodeCall` encoding for the same args.
    function _check(bytes4 innerSel, bytes memory calldataArgs, bytes memory encodeCallFull, string memory label)
        internal
        pure
    {
        bytes memory viaOpt = bytes.concat(innerSel, calldataArgs);
        if (viaOpt.length != encodeCallFull.length) revert(string.concat("len mismatch: ", label));
        if (keccak256(viaOpt) != keccak256(encodeCallFull)) revert(string.concat("bytes mismatch: ", label));
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
    {
        _check(
            ISwapFacet.beforeSwapLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISwapFacet.beforeSwapLogic, (sender, key, params, hookData)),
            "beforeSwap"
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        _check(
            ISwapFacet.afterSwapLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISwapFacet.afterSwapLogic, (sender, key, params, delta, hookData)),
            "afterSwap"
        );
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external {
        _check(
            ISwapFacet.beforeInitializeLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISwapFacet.beforeInitializeLogic, (sender, key, sqrtPriceX96)),
            "beforeInit"
        );
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external {
        _check(
            ISwapFacet.beforeAddLiquidityLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISwapFacet.beforeAddLiquidityLogic, (sender, key, params, hookData)),
            "beforeAddLiq"
        );
    }

    function executePreorderSettlement(IMemeverseUniswapHook.PreorderSettlementParams calldata params) external {
        _check(
            ISettlementFacet.executeSettlementLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISettlementFacet.executeSettlementLogic, (params)),
            "executePreorderSettlement"
        );
    }

    function updateUserSnapshot(PoolId id, address user) external {
        _check(
            ISwapFacet.updateUserSnapshotLogic.selector,
            msg.data[4:],
            abi.encodeCall(ISwapFacet.updateUserSnapshotLogic, (id, user)),
            "updateUserSnapshot"
        );
    }

    /// @dev The settlement unlock envelope is `abi.encode(kind, data)` with a fully
    ///      static `SettlementCallbackData`. Slice-forwarding `rawData[32:]` after the facet selector
    ///      must stay byte-identical to `abi.encodeCall(settlementUnlockCallback, (data))`. If the
    ///      struct gains a dynamic field, this reverts (and production must leave the slice path).
    function settlementUnlockSliceForward(ISettlementFacet.SettlementCallbackData calldata data) external pure {
        bytes memory envelope = abi.encode(IMemeverseUniswapHook.UnlockCallbackKind.Settlement, data);
        _check(
            ISettlementFacet.settlementUnlockCallback.selector,
            _tailAfterFirstWord(envelope),
            abi.encodeCall(ISettlementFacet.settlementUnlockCallback, (data)),
            "settlementUnlockSliceForward"
        );
    }

    function _tailAfterFirstWord(bytes memory envelope) private pure returns (bytes memory tail) {
        if (envelope.length < 32) revert("settlementUnlockSliceForward: envelope too short");
        tail = new bytes(envelope.length - 32);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = envelope[i + 32];
        }
    }
}

/// @notice Forward byte-equality coverage: one fuzz test per thin entry plus boundary cases for empty/long
///         `bytes` payloads. Each fuzz case passes iff the probe does not revert.
contract ForwardByteEqTest is Test {
    ForwardByteEqProbe internal probe;

    function setUp() public {
        probe = new ForwardByteEqProbe();
    }

    function testFuzz_BeforeSwapByteEq(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        probe.beforeSwap(sender, key, params, hookData);
    }

    function testFuzz_AfterSwapByteEq(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        probe.afterSwap(sender, key, params, delta, hookData);
    }

    function testFuzz_BeforeInitializeByteEq(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external {
        probe.beforeInitialize(sender, key, sqrtPriceX96);
    }

    function testFuzz_BeforeAddLiquidityByteEq(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external {
        probe.beforeAddLiquidity(sender, key, params, hookData);
    }

    function testFuzz_ExecutePreorderSettlementByteEq(IMemeverseUniswapHook.PreorderSettlementParams calldata params)
        external
    {
        probe.executePreorderSettlement(params);
    }

    function testFuzz_UpdateUserSnapshotByteEq(PoolId id, address user) external {
        probe.updateUserSnapshot(id, user);
    }

    /// @notice Fuzzes that settlement unlock slice-forward equals encodeCall for any
    ///         SettlementCallbackData. Fails if the struct stops being fully static.
    function testFuzz_SettlementUnlockSliceForwardByteEq(ISettlementFacet.SettlementCallbackData calldata data)
        external
        view
    {
        probe.settlementUnlockSliceForward(data);
    }

    /// @notice A fixed non-zero fixture exercises addresses, PoolKey, SwapParams, and bool
    ///         through the same static slice-forward equality as production `unlockCallback`.
    function test_SettlementUnlockSliceForward_NonZeroFields() external view {
        PoolKey memory key = _anyKey();
        ISettlementFacet.SettlementCallbackData memory data = ISettlementFacet.SettlementCallbackData({
            recipient: address(0xA11CE),
            treasury: address(0xB0B),
            key: key,
            swapParams: SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 1 << 96}),
            protocolFeeOnInput: true
        });
        probe.settlementUnlockSliceForward(data);
    }

    /// @notice Guards against outer-signature drift on the two non-v4 entries (v4 callbacks are locked by
    ///         IHooks). If a future interface change alters the outer selector without updating the probe,
    ///         this fails at compile time (selector mismatch) before the byte-equality test silently passes
    ///         with a stale probe signature.
    function test_nonV4OuterSelectorTracksInterface() public {
        assertEq(
            ForwardByteEqProbe.executePreorderSettlement.selector,
            IMemeverseUniswapHook.executePreorderSettlement.selector,
            "executePreorderSettlement outer selector drift"
        );
        assertEq(
            ForwardByteEqProbe.updateUserSnapshot.selector,
            IMemeverseUniswapHook.updateUserSnapshot.selector,
            "updateUserSnapshot outer selector drift"
        );
    }

    /// @notice Boundary: empty `bytes` payloads for every hook-data argument. `bytes.concat(selector, "")`
    ///         must still equal `abi.encodeCall(...)` (which encodes an empty dynamic bytes as offset+0 len).
    function test_BoundaryEmptyBytesPayloads() external {
        PoolKey memory key = _anyKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: 0});
        bytes memory empty = bytes("");

        probe.beforeSwap(address(1), key, params, empty);
        probe.afterSwap(address(1), key, params, BalanceDelta.wrap(0), empty);
        probe.beforeAddLiquidity(address(1), key, _anyModifyLiquidityParams(), empty);
    }

    /// @notice Boundary: a 4096-byte hook payload (well above a single calldata word) stresses the
    ///         dynamic-bytes tail encoding path.
    function test_BoundaryLongHookData() external {
        PoolKey memory key = _anyKey();
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        bytes memory longHookData = new bytes(4096);
        for (uint256 i = 0; i < longHookData.length; i++) {
            longHookData[i] = bytes1(uint8(i % 251 + 1));
        }

        probe.beforeSwap(address(2), key, params, longHookData);
        probe.beforeInitialize(address(2), key, type(uint160).max);
    }

    function _anyKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
    }

    function _anyModifyLiquidityParams() internal pure returns (ModifyLiquidityParams memory params) {
        params = ModifyLiquidityParams({
            tickLower: -887200, tickUpper: 887200, liquidityDelta: 1e18, salt: bytes32(uint256(0xabc))
        });
    }
}
