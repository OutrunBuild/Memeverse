// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {MemeverseUniswapHook} from "../../src/swap/MemeverseUniswapHook.sol";
import {SettlementFacet} from "../../src/swap/SettlementFacet.sol";
import {SwapFacet} from "../../src/swap/SwapFacet.sol";
import {DynamicFeeFacet} from "../../src/swap/DynamicFeeFacet.sol";
import {FacetGuard} from "../../src/swap/FacetGuard.sol";
import {UniswapLP} from "../../src/swap/tokens/UniswapLP.sol";
import {ISettlementFacet} from "../../src/swap/interfaces/ISettlementFacet.sol";
import {ISwapFacet} from "../../src/swap/interfaces/ISwapFacet.sol";
import {IDynamicFeeFacet} from "../../src/swap/interfaces/IDynamicFeeFacet.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {OutrunOwnableUpgradeable} from "../../src/common/access/OutrunOwnableUpgradeable.sol";

import {MockPoolManagerForHookLiquidity} from "../mocks/swap/HookLiquidityMocks.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";
import {DynamicFeeFacetReplacementMock} from "../mocks/swap/DynamicFeeFacetReplacementMock.sol";

/// @title MemeverseDiamondFacetsTest
/// @notice Security coverage for the diamond facet guards and unsupported-selector fallback.
/// @dev Three closures are covered:
///      1. `setFacet` replacement is controlled: only-owner, non-zero, deployed-code, shared-PoolManager,
///         and known-role checks, plus the invariant that replacing a facet updates the pointer, emits
///         `FacetUpdated`, and the new facet still rejects direct CALLs via `onlyViaRouter` AND the
///         delegatecall accept path still works.
///      2. Each facet rejects direct CALLs: `onlyViaRouter` trips because a direct call observes
///         `address(this) == __self` (the facet's own immutable address), whereas under Router
///         delegatecall `address(this)` is the hook proxy (≠ `__self`).
///      3. Any selector absent from the hook ABI reverts with `UnsupportedSelector` and reports the exact selector.
///      The setUp mirrors `MemeverseUniswapHookLiquidityTest` but needs no pool liquidity — the guards are
///      storage/access checks that fire before any pool interaction.
contract MemeverseDiamondFacetsTest is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    MockPoolManagerForHookLiquidity internal mockManager;
    MemeverseUniswapHook internal hook;

    function setUp() public {
        mockManager = new MockPoolManagerForHookLiquidity();
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(mockManager)), address(this), address(this));
        hook = MemeverseUniswapHook(hookProxy);
    }

    // -------------------------------------------------------------------------
    // Closure 1 — setFacet replacement is controlled
    // -------------------------------------------------------------------------

    /// @notice `setFacet` is `onlyOwner`: a non-owner caller is rejected with `OwnableUnauthorizedAccount`.
    /// @dev The facet argument is never read — `onlyOwner` reverts first — so no real facet deployment is needed.
    function test_setFacet_RevertIf_NotOwner() external {
        address stranger = makeAddr("stranger");
        bytes32 role = hook.SETTLEMENT_FACET_ROLE();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setFacet(role, address(0xBEEF));
    }

    /// @notice A zero facet address is rejected before any code/manager check.
    function test_setFacet_RevertIf_ZeroAddress() external {
        bytes32 role = hook.SETTLEMENT_FACET_ROLE();
        vm.expectRevert(IMemeverseUniswapHook.ZeroAddress.selector);
        hook.setFacet(role, address(0));
    }

    /// @notice A facet with no deployed bytecode is rejected by `_requireFacetPoolManager`.
    function test_setFacet_RevertIf_FacetCodeNotReady() external {
        address eoa = address(0xBEEF);
        bytes32 role = hook.SETTLEMENT_FACET_ROLE();

        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.FacetCodeNotReady.selector, eoa));
        hook.setFacet(role, eoa);
    }

    /// @notice A facet immutable-bound to a different PoolManager than the hook is rejected.
    /// @dev `_requireFacetPoolManager` compares the facet's `ImmutableState.poolManager()` against the
    ///      hook's own manager; a mismatch would settle/take against the wrong manager under delegatecall.
    function test_setFacet_RevertIf_FacetPoolManagerMismatch() external {
        MockPoolManagerForHookLiquidity freshManager = new MockPoolManagerForHookLiquidity();
        SettlementFacet badFacet = new SettlementFacet(IPoolManager(address(freshManager)));
        bytes32 role = hook.SETTLEMENT_FACET_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.FacetPoolManagerMismatch.selector,
                address(badFacet),
                address(mockManager),
                address(freshManager)
            )
        );
        hook.setFacet(role, address(badFacet));
    }

    /// @notice An unrecognized role discriminator is rejected after the facet passes the poolManager check.
    function test_setFacet_RevertIf_UnknownFacetRole() external {
        bytes32 unknownRole = bytes32(uint256(0xBAD));
        // A valid facet is required so `_requireFacetPoolManager` passes and the role check is reached.
        SettlementFacet validFacet = new SettlementFacet(IPoolManager(address(mockManager)));

        vm.expectRevert(abi.encodeWithSelector(IMemeverseUniswapHook.UnknownFacetRole.selector, unknownRole));
        hook.setFacet(unknownRole, address(validFacet));
    }

    /// @notice `initialize` rejects any facet immutable-bound to a different PoolManager — one test per
    ///         `_requireFacetPoolManager` call site (swapFacet, dynamicFeeFacet, settlementFacet).
    /// @dev `deployHookAtFlagAddress` always binds all three facets to the same manager, so each variant
    ///      etches the hook impl's runtime bytecode to a fresh address: the immutable `poolManager` is
    ///      preserved in bytecode, while storage is empty (`_initialized == 0`) so the `initializer`
    ///      modifier passes. `_requireFacetPoolManager` runs BEFORE `_validateProxyHookAddress` in
    ///      `initialize`, so the mismatched facet reverts there — no flag-valid proxy address and no
    ///      inheritance of the upgradeable hook needed.
    function test_initialize_RevertIf_SwapFacetPoolManagerMismatch() external {
        _assertInitializeRevertsOnBadFacet(0, "etchedSwap");
    }

    function test_initialize_RevertIf_DynamicFeeFacetPoolManagerMismatch() external {
        _assertInitializeRevertsOnBadFacet(1, "etchedDyn");
    }

    function test_initialize_RevertIf_SettlementFacetPoolManagerMismatch() external {
        _assertInitializeRevertsOnBadFacet(2, "etchedSettlement");
    }

    /// @dev Shared harness for the three initialize-mismatch variants. `badPosition` selects which facet
    ///      (0=swap, 1=dynamicFee, 2=settlement) is bound to a fresh PoolManager; the other two bind to
    ///      the hook's manager. Etches the hook impl to a fresh address (immutable `poolManager` preserved,
    ///      storage empty) and asserts `initialize` reverts with `FacetPoolManagerMismatch(badFacet, ...)`.
    function _assertInitializeRevertsOnBadFacet(uint256 badPosition, string memory etchLabel) internal {
        MockPoolManagerForHookLiquidity freshManager = new MockPoolManagerForHookLiquidity();
        IPoolManager bad = IPoolManager(address(freshManager));
        IPoolManager good = IPoolManager(address(mockManager));
        SwapFacet swapFacet = new SwapFacet(badPosition == 0 ? bad : good);
        DynamicFeeFacet dynFacet = new DynamicFeeFacet(badPosition == 1 ? bad : good);
        SettlementFacet settlementFacet = new SettlementFacet(badPosition == 2 ? bad : good);
        address badFacet =
            badPosition == 0 ? address(swapFacet) : badPosition == 1 ? address(dynFacet) : address(settlementFacet);

        MemeverseUniswapHook hookImpl = new MemeverseUniswapHook(good);
        address etched = makeAddr(etchLabel);
        vm.etch(etched, address(hookImpl).code);
        UniswapLP lpImpl = new UniswapLP();

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseUniswapHook.FacetPoolManagerMismatch.selector,
                badFacet,
                address(mockManager),
                address(freshManager)
            )
        );
        MemeverseUniswapHook(etched)
            .initialize(
                address(this),
                address(this),
                address(lpImpl),
                address(swapFacet),
                address(dynFacet),
                address(settlementFacet)
            );
    }

    /// @notice Replacing a facet updates the pointer, emits `FacetUpdated`, and the new facet still rejects
    ///         direct CALLs via `onlyViaRouter`.
    /// @dev Covers the SETTLEMENT_FACET_ROLE branch. The direct-call rejection is checked separately
    ///      (`_assertDirectCallReverts`): `__self` is baked at facet construction, so a freshly-wired facet
    ///      still reverts on a direct CALL.
    function test_setFacet_ReplacedFacetStillRejectsDirectCall() external {
        SettlementFacet newFacet = new SettlementFacet(IPoolManager(address(mockManager)));
        _assertFacetReplacement(hook.SETTLEMENT_FACET_ROLE(), hook.settlementFacet(), address(newFacet));
        assertEq(hook.settlementFacet(), address(newFacet), "pointer updated");
        _assertDirectCallReverts(
            address(newFacet), abi.encodeCall(ISettlementFacet.executeSettlementLogic, (_dummySettlementParams()))
        );
    }

    /// @notice Replacing SWAP_FACET_ROLE and DYNAMIC_FEE_FACET_ROLE updates their pointers, emits
    ///         `FacetUpdated`, and the new facets still reject direct CALLs — covering the two setFacet
    ///         role branches not exercised by the settlement test.
    function test_setFacet_UpdatesSwapAndDynamicFeePointers() external {
        SwapFacet newSwap = new SwapFacet(IPoolManager(address(mockManager)));
        DynamicFeeFacet newDyn = new DynamicFeeFacet(IPoolManager(address(mockManager)));

        _assertFacetReplacement(hook.SWAP_FACET_ROLE(), hook.swapFacet(), address(newSwap));
        assertEq(hook.swapFacet(), address(newSwap), "swap pointer updated");
        _assertDirectCallReverts(
            address(newSwap),
            abi.encodeCall(ISwapFacet.beforeSwapLogic, (address(this), _dummyKey(), _dummySwapParams(), bytes("")))
        );

        _assertFacetReplacement(hook.DYNAMIC_FEE_FACET_ROLE(), hook.dynamicFeeFacet(), address(newDyn));
        assertEq(hook.dynamicFeeFacet(), address(newDyn), "dynamicFee pointer updated");
        _assertDirectCallReverts(
            address(newDyn), abi.encodeCall(IDynamicFeeFacet.prepareSwapFee, (_dummyPrepareSwapFeeParams()))
        );
    }

    /// @notice Replacing DYNAMIC_FEE_FACET_ROLE changes both public-swap fee preparation and realized-state writes.
    function test_setFacet_ReplacedDynamicFeeFacetDrivesPublicSwapFeeAndState() external {
        MockERC20 firstToken = new MockERC20("First Token", "FIRST", 18);
        MockERC20 secondToken = new MockERC20("Second Token", "SECOND", 18);
        address firstTokenAddress = address(firstToken);
        address secondTokenAddress = address(secondToken);
        Currency currency0 =
            Currency.wrap(firstTokenAddress < secondTokenAddress ? firstTokenAddress : secondTokenAddress);
        Currency currency1 =
            Currency.wrap(firstTokenAddress < secondTokenAddress ? secondTokenAddress : firstTokenAddress);
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0x800000, tickSpacing: 200, hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();

        hook.setProtocolFeeCurrency(currency0, true);
        _writeSlot(address(hook), _poolIdMappingSlot(OFF_CACHED_LP_TOTAL_SUPPLY, poolId), bytes32(uint256(1 ether)));
        MockERC20(Currency.unwrap(currency0)).mint(address(mockManager), 10_000);

        DynamicFeeFacetReplacementMock replacement =
            new DynamicFeeFacetReplacementMock(IPoolManager(address(mockManager)));
        _assertFacetReplacement(hook.DYNAMIC_FEE_FACET_ROLE(), hook.dynamicFeeFacet(), address(replacement));

        BalanceDelta delta = mockManager.swapAsUnlocked(
            key, SwapParams({zeroForOne: true, amountSpecified: -10_000, sqrtPriceLimitX96: 0}), bytes("")
        );

        assertEq(delta.amount0(), -9_000, "replacement fee changes pool input");
        IDynamicFeeFacet.DynamicFeeState memory state = hook.dynamicFeeStateOf(poolId);
        assertEq(state.shortImpactPpm, 77_777, "replacement afterSwap writes shared state");
    }

    /// @notice Replacing SWAP_FACET_ROLE actually re-routes dispatch to the new facet: a Router entry
    ///         that delegates via `_forwardCalldata` must reach the new facet and pass its `onlyViaRouter`
    ///         guard. `updateUserSnapshot(dummyPoolId, address(0))` takes the `user == address(0)` early-exit
    ///         in `SwapFacet._updateUserSnapshot`, so it succeeds without pool initialization — a non-revert
    ///         here proves the new facet ran in the proxy's storage context (a direct CALL still reverts —
    ///         `onlyViaRouter` is selector-independent; `test_setFacet_UpdatesSwapAndDynamicFeePointers`
    ///         asserts the equivalent direct-call revert for `beforeSwapLogic`).
    function test_setFacet_ReplacedSwapFacetDispatchesViaDelegatecall() external {
        SwapFacet newSwap = new SwapFacet(IPoolManager(address(mockManager)));
        _assertFacetReplacement(hook.SWAP_FACET_ROLE(), hook.swapFacet(), address(newSwap));

        // A direct CALL to `newSwap` reverts (onlyViaRouter: address(this) == __self under a direct call);
        // only the proxy delegatecall path satisfies address(this) != __self, so a non-revert here proves the
        // new swapFacet executed in the proxy storage context.
        hook.updateUserSnapshot(PoolId.wrap(bytes32(0)), address(0));
    }

    // -------------------------------------------------------------------------
    // Closure 2 — facet cannot be called directly (onlyViaRouter)
    // -------------------------------------------------------------------------

    /// @notice `settlementFacet.executeSettlementLogic` rejects a direct CALL.
    function test_settlementFacet_RevertIf_DirectCallExecuteSettlementLogic() external {
        _assertDirectCallReverts(
            hook.settlementFacet(), abi.encodeCall(ISettlementFacet.executeSettlementLogic, (_dummySettlementParams()))
        );
    }

    /// @notice `swapFacet.beforeSwapLogic` rejects a direct CALL.
    function test_swapFacet_RevertIf_DirectCallBeforeSwapLogic() external {
        _assertDirectCallReverts(
            hook.swapFacet(),
            abi.encodeCall(ISwapFacet.beforeSwapLogic, (address(this), _dummyKey(), _dummySwapParams(), bytes("")))
        );
    }

    /// @notice `dynamicFeeFacet.prepareSwapFee` rejects a direct CALL.
    function test_dynamicFeeFacet_RevertIf_DirectCallPrepareSwapFee() external {
        _assertDirectCallReverts(
            hook.dynamicFeeFacet(), abi.encodeCall(IDynamicFeeFacet.prepareSwapFee, (_dummyPrepareSwapFeeParams()))
        );
    }

    // -------------------------------------------------------------------------
    // Closure 3 — unsupported selectors diagnose via fallback
    // -------------------------------------------------------------------------

    /// @notice Any selector absent from the hook ABI falls through to `fallback` and reverts with
    ///         `UnsupportedSelector(selector)` instead of an opaque revert.
    /// @dev Low-level `.call()` is required because unsupported selectors have no interface entry. `hook` is the
    ///      proxy address; the call reaches the implementation's `fallback` via ERC1967 delegatecall, where
    ///      `msg.sig` correctly reflects the caller-provided selector. Both the error kind and the reported
    ///      selector are asserted in one pass per selector.
    function test_UnsupportedSelectors_RevertWithExactSelector() external {
        bytes4[3] memory unsupportedSelectors = [bytes4(0xdeadbeef), bytes4(0x01020304), bytes4(0xffffffff)];

        for (uint256 i = 0; i < unsupportedSelectors.length; i++) {
            bytes4 sel = unsupportedSelectors[i];
            (bool ok, bytes memory ret) = address(hook).call(abi.encodeWithSelector(sel));

            assertFalse(ok, "unsupported selector must revert");
            assertEq(bytes4(ret), IMemeverseUniswapHook.UnsupportedSelector.selector, "error kind");
            // Decode the `UnsupportedSelector(bytes4)` argument: bytes4 is ABI-left-aligned, so the
            // reported selector occupies the high 4 bytes of the 32-byte word at data offset 4.
            assertGe(ret.length, 36, "revert data must carry the selector argument");
            bytes32 arg;
            assembly ("memory-safe") {
                arg := mload(add(add(ret, 0x20), 4)) // data start (0x20 past length) + 4-byte selector
            }
            assertEq(bytes4(arg), sel, "reported selector");
        }
    }

    // -------------------------------------------------------------------------
    // Shared helpers
    // -------------------------------------------------------------------------

    /// @dev Asserts a facet replacement: `FacetUpdated` emitted with (role, old, new) and `setFacet`
    ///      succeeds. The pointer-update and direct-call rejection are asserted by the caller
    ///      (role-specific getter / callData). The guard uses `__self`, so no storage invariant is checked here.
    function _assertFacetReplacement(bytes32 role, address oldFacet, address newFacet) internal {
        // FacetUpdated has 1 indexed topic (role); topics 2 and 3 are absent — checkData validates old/new.
        vm.expectEmit(true, false, false, true, address(hook));
        // FacetUpdated is declared on IMemeverseUniswapHook; emit it through that interface so the qualified
        // reference resolves unambiguously.
        emit IMemeverseUniswapHook.FacetUpdated(role, oldFacet, newFacet);
        hook.setFacet(role, newFacet);
    }

    /// @dev Asserts a direct CALL to a facet reverts with `DirectFacetCallForbidden`. The call data must
    ///      be ABI-decodable to the target function's signature, but argument values are irrelevant — the
    ///      `onlyViaRouter` modifier reverts before the body reads them.
    function _assertDirectCallReverts(address facet, bytes memory callData) internal {
        (bool ok, bytes memory returnData) = address(facet).call(callData);
        assertFalse(ok, "direct facet call must revert");
        assertEq(bytes4(returnData), FacetGuard.DirectFacetCallForbidden.selector, "DirectFacetCallForbidden");
    }

    /// @dev Minimal settlement payload. Values are irrelevant: the direct-call guard reverts first.
    function _dummySettlementParams() internal view returns (IMemeverseUniswapHook.PreorderSettlementParams memory) {
        return IMemeverseUniswapHook.PreorderSettlementParams({
            key: _dummyKey(), params: _dummySwapParams(), recipient: address(this)
        });
    }

    /// @dev Minimal prepareSwapFee payload. Values are irrelevant: the direct-call guard reverts first.
    function _dummyPrepareSwapFeeParams() internal view returns (IDynamicFeeFacet.PrepareSwapFeeParams memory) {
        return IDynamicFeeFacet.PrepareSwapFeeParams({
            poolId: PoolId.wrap(bytes32(0)),
            zeroForOne: true,
            amountSpecified: -100 ether,
            trader: address(this),
            preSqrtPriceX96: 0,
            liquidity: 0,
            protocolFeeOnInput: false
        });
    }

    function _dummyKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
    }

    function _dummySwapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
    }
}
