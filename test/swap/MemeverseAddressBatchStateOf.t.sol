// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @notice Round-trip coverage for `IMemeverseUniswapHook.addressBatchStateOf`.
/// @dev The getter body is a single storage
///      return with no value-sensitive branch, so fixed examples (0 / type-max / mid) cover the bit-pack
///      edges as well as a fuzz run would. This test catches READ-SIDE drift between the getter's automatic
///      layout derivation and an independent manual slot computation:
///        1. Field offset — if `addressBatchState` moves within `MemeverseUniswapHookStorage`, the manual
///           `OFF_ADDRESS_BATCH_STATE` below and the getter's auto-derived offset diverge.
///        2. Field packing — if `AddressBatchState` field order/widths change without the getter being
///           updated, the packed slot decode (uint192 low | uint64 high) mismatches.
///        3. Mapping key order — reversing `[trader][poolId]` hashing silently returns wrong state.
///      It does NOT catch a WRITE-SIDE namespace mismatch where `DynamicFeeFacet.updateAfterSwap` writes a
///      facet-local ERC-7201 namespace while the Router getter reads the hook namespace: both the test's
///      `vm.store` and the getter would agree on the Router slot and pass. Write-side coverage
///      requires a swap-level integration test that triggers `updateAfterSwap` (no Router-direct entrypoint
///      exists — it runs inside the afterSwap callback) and reads back via the getter; the swap suites under
///      test/swap/ exercise `updateAfterSwap` indirectly through fee assertions.
///      Does NOT inherit the upgradeable hook production contract; it talks to the deployed transparent proxy
///      through the `IMemeverseUniswapHook` interface (AGENTS.md "Test Code Rules").
contract MemeverseAddressBatchStateOfTest is Test, HookStorageHelper {
    // Field offset of `addressBatchState` inside `MemeverseUniswapHookStorage`
    // (src/swap/interfaces/IMemeverseHookStorage.sol). Must be updated in lockstep with any storage struct
    // reorder; appending at the end preserves it.
    uint256 internal constant OFF_ADDRESS_BATCH_STATE = 13;

    // Post-addressBatchState field offsets (IMemeverseHookStorage.sol:88-94). Append-only invariant: these
    // MUST track the struct declaration order. A reorder silently re-slots the auto-derived Router getters
    // (referrerRebateBps / pendingRebateOf / swapFacet / dynamicFeeFacet / settlementFacet) while these
    // constants stay fixed — exactly the READ-SIDE drift this test catches.
    uint256 internal constant OFF_REFERRER_REBATE_BPS = 14; // uint24 scalar
    uint256 internal constant OFF_PENDING_REBATE = 15; // mapping(address => mapping(Currency => uint256))
    uint256 internal constant OFF_SWAP_FACET = 16; // address scalar
    uint256 internal constant OFF_DYNAMIC_FEE_FACET = 17; // address scalar
    uint256 internal constant OFF_SETTLEMENT_FACET = 18; // address scalar

    IMemeverseUniswapHook internal hook;

    // Cached once in setUp: TRADER and POOL_ID are fixed after setUp, so the slot is invariant across test
    // bodies and need not be recomputed per assertion.
    bytes32 internal batchStateSlot;

    address internal constant TRADER = address(0xA11CE);
    PoolId internal POOL_ID;

    function setUp() public {
        IPoolManager manager = IPoolManager(address(new MockPoolManagerForHookLiquidity()));
        address hookProxy = deployHookAtFlagAddress(manager, address(this), address(this));
        hook = IMemeverseUniswapHook(hookProxy);
        // Synthetic PoolId is sufficient: the getter maps it directly through the storage key hash, so no
        // pool initialization is required for `addressBatchStateOf` (a pure direct storage read).
        POOL_ID = PoolId.wrap(bytes32(uint256(0xC0FFEE)));
        batchStateSlot = _addressBatchStateSlot(TRADER, POOL_ID);

        vm.label(hookProxy, "hookProxy");
        vm.label(TRADER, "trader");
    }

    /// @dev Read-side round-trip over fixed examples covering the bit-pack edges. The fresh-zero sanity
    ///      check runs once up front — the cached slot is reused and overwritten across examples, so
    ///      re-checking zero before each example would read the previous example's written value.
    function test_RoundTripAddressBatchStateOf() external {
        IDynamicFeeFacet.AddressBatchState memory fresh = hook.addressBatchStateOf(TRADER, POOL_ID);
        assertEq(uint256(fresh.batchAccumPpm), 0, "fresh batchAccumPpm should be zero");
        assertEq(uint256(fresh.batchStartTs), 0, "fresh batchStartTs should be zero");

        _assertRoundTrip(type(uint192).max, type(uint64).max);
        _assertRoundTrip(uint192(1) << 100, uint64(1) << 30);
    }

    /// @dev Writes a known packed `AddressBatchState` at the cached slot and asserts the getter reads the
    ///      exact same field values back. The slot is overwritten each call; the fresh-zero sanity check
    ///      lives in the caller so it runs once.
    function _assertRoundTrip(uint192 batchAccumPpm, uint64 batchStartTs) internal {
        // `AddressBatchState{uint192 batchAccumPpm; uint64 batchStartTs}` packs into a single 256-bit slot:
        // low 192 bits = batchAccumPpm, high 64 bits = batchStartTs.
        bytes32 packed = bytes32((uint256(batchStartTs) << 192) | uint256(batchAccumPpm));
        vm.store(address(hook), batchStateSlot, packed);

        IDynamicFeeFacet.AddressBatchState memory afterWrite = hook.addressBatchStateOf(TRADER, POOL_ID);
        assertEq(uint256(afterWrite.batchAccumPpm), uint256(batchAccumPpm), "batchAccumPpm round-trip");
        assertEq(uint256(afterWrite.batchStartTs), uint256(batchStartTs), "batchStartTs round-trip");
    }

    /// @dev Two-level mapping slot for `addressBatchState[trader][poolId]` in the hook's ERC-7201 namespace.
    ///      Outer key: `address trader`; inner key: `PoolId poolId`. Reversing the key order would yield a
    ///      different slot, and the round-trip assertion above would fail — that is the point.
    function _addressBatchStateSlot(address trader, PoolId poolId) internal pure returns (bytes32) {
        bytes32 outerBase = bytes32(uint256(HOOK_SLOT) + OFF_ADDRESS_BATCH_STATE);
        bytes32 outerSlot = keccak256(abi.encode(trader, outerBase));
        return keccak256(abi.encode(PoolId.unwrap(poolId), outerSlot));
    }

    /// @notice Round-trip coverage for the storage fields following `addressBatchState`:
    ///         `referrerRebateBps`, `pendingRebate`, and the three facet pointers.
    /// @dev Each field is written at its manually-computed ERC-7201 slot (base `HOOK_SLOT + OFF_*`) and read
    ///      back via the Router's public getter (`referrerRebateBps` / `pendingRebateOf` / `swapFacet` /
    ///      `dynamicFeeFacet` / `settlementFacet`). Solidity auto-derives each getter's slot from the struct
    ///      field declaration order; if a field is reordered, the auto-derived slot diverges from the manual
    ///      `OFF_*` constant and the round-trip fails. Same READ-SIDE drift hazard as `addressBatchState`,
    ///      extended to the fields appended after it.
    function test_RoundTripPostBatchStorageFields() external {
        // referrerRebateBps — uint24 scalar at base + 14. The getter reads only the low 3 bytes.
        uint256 seededRebateBps = 1234;
        vm.store(address(hook), bytes32(uint256(HOOK_SLOT) + OFF_REFERRER_REBATE_BPS), bytes32(seededRebateBps));
        assertEq(hook.referrerRebateBps(), seededRebateBps, "referrerRebateBps round-trip");

        // pendingRebate — two-level mapping(address => mapping(Currency => uint256)) at base + 15.
        Currency currency = Currency.wrap(address(0xBEEF));
        uint256 seededRebateAmount = 5 ether;
        bytes32 rebateSlot = _pendingRebateSlot(TRADER, currency);
        vm.store(address(hook), rebateSlot, bytes32(seededRebateAmount));
        assertEq(hook.pendingRebateOf(TRADER, currency), seededRebateAmount, "pendingRebate round-trip");

        // swapFacet — address scalar at base + 16. Address occupies the low 20 bytes of the slot.
        address seededSwapFacet = address(0x5AAA);
        vm.store(
            address(hook), bytes32(uint256(HOOK_SLOT) + OFF_SWAP_FACET), bytes32(uint256(uint160(seededSwapFacet)))
        );
        assertEq(hook.swapFacet(), seededSwapFacet, "swapFacet round-trip");

        // dynamicFeeFacet — address scalar at base + 17.
        address seededDynamicFeeFacet = address(0xDFAC);
        vm.store(
            address(hook),
            bytes32(uint256(HOOK_SLOT) + OFF_DYNAMIC_FEE_FACET),
            bytes32(uint256(uint160(seededDynamicFeeFacet)))
        );
        assertEq(hook.dynamicFeeFacet(), seededDynamicFeeFacet, "dynamicFeeFacet round-trip");

        // settlementFacet — address scalar at base + 18.
        address seededSettlementFacet = address(0x5E77);
        vm.store(
            address(hook),
            bytes32(uint256(HOOK_SLOT) + OFF_SETTLEMENT_FACET),
            bytes32(uint256(uint160(seededSettlementFacet)))
        );
        assertEq(hook.settlementFacet(), seededSettlementFacet, "settlementFacet round-trip");
    }

    /// @dev Two-level mapping slot for `pendingRebate[referrer][currency]` in the hook's ERC-7201 namespace.
    ///      Outer key: `address referrer`; inner key: `Currency currency` (wraps `address`). Reversing the
    ///      key order or the field offset yields a different slot, and the round-trip above would fail.
    function _pendingRebateSlot(address referrer, Currency currency) internal pure returns (bytes32) {
        bytes32 outerBase = bytes32(uint256(HOOK_SLOT) + OFF_PENDING_REBATE);
        bytes32 outerSlot = keccak256(abi.encode(referrer, outerBase));
        return keccak256(abi.encode(Currency.unwrap(currency), outerSlot));
    }
}
