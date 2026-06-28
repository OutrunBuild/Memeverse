// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MemeverseDynamicFeeEngine} from "../../src/swap/MemeverseDynamicFeeEngine.sol";
import {IMemeverseDynamicFeeEngine} from "../../src/swap/interfaces/IMemeverseDynamicFeeEngine.sol";
import {RealisticSwapIntegrationBase} from "./helpers/RealisticSwapManagerHarness.sol";

/// @notice Fault-injection tests: verifies swap resilience when the hook points at an unauthorized engine.
///
/// Uses `vm.store` to bypass `upgradeDynamicFeeEngine` authorization and directly construct the
/// "hook points at an unauthorized engine" anomaly. In production this state can arise from:
///   - Engine upgrade with misconfigured authorization
///   - Storage migration or proxy upgrade data inconsistency
///
/// Normal upgrade-path authorization is covered separately in MemeverseUniswapHookLiquidity.t.sol:
///   - testUpgradeDynamicFeeEngineRevertsForUnauthorizedEngine (rejects unauthorized engine)
///   - testUpgradeDynamicFeeEngineRevertsForNonOwner (rejects non-owner caller)
///
/// Code paths exercised (all in `_beforeSwap` / `_afterSwap`, no try/catch protection):
///   Test 1: exact-input path (L559-565 branch) revert propagation
///   Test 2: broken engine blocks quote/swap because there is no emergency bypass
///   Test 4: no corrupt state after revert (confirms no swallowed exceptions, next swap succeeds)
///   Test 5: exact-output + output-side fee path (L572-578 branch) revert propagation
contract MemeverseDynamicFeeEngineRevertPropagationTest is RealisticSwapIntegrationBase {
    using BalanceDeltaLibrary for BalanceDelta;

    MemeverseDynamicFeeEngine internal engine;
    address internal constant UNAUTHORIZED_HOOK = address(0xDEAD);

    /// @notice Fault injection: forces the hook to point at an engine that does NOT authorize this hook.
    /// @dev Bypasses `upgradeDynamicFeeEngine` authorization via `vm.store`, simulating a misconfigured
    ///      engine whose `authorizedHook != address(hook)`. Direct storage write targets slot offset +11
    ///      relative to the ERC7201 base location where `dynamicFeeEngine` is stored.
    function _swapToUnauthorizedEngine() internal {
        MemeverseDynamicFeeEngine newEngineImpl = new MemeverseDynamicFeeEngine(hook.poolManager());
        MemeverseDynamicFeeEngine newEngine = MemeverseDynamicFeeEngine(
            address(
                new ERC1967Proxy(
                    address(newEngineImpl),
                    abi.encodeCall(MemeverseDynamicFeeEngine.initialize, (address(this), UNAUTHORIZED_HOOK))
                )
            )
        );
        // Bypass upgradeDynamicFeeEngine authorization check by writing directly to hook storage.
        // dynamicFeeEngine is at slot 11 relative to the base storage location.
        bytes32 baseSlot = HOOK_SLOT;
        vm.store(address(hook), bytes32(uint256(baseSlot) + 11), bytes32(uint256(uint160(address(newEngine)))));
        engine = newEngine;
    }

    function setUp() public {
        _setUpIntegration(IPermit2(address(0)));

        // Register a supported protocol fee currency so _resolveSwapFeeContext passes.
        hook.setProtocolFeeCurrency(key.currency0, true);

        // Cast the real engine deployed by _setUpIntegration.
        engine = MemeverseDynamicFeeEngine(address(hook.dynamicFeeEngine()));
    }

    // ── Helpers ─────────────────────────────────────────────────────

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _unauthorizedCallerRevert() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IMemeverseDynamicFeeEngine.UnauthorizedCaller.selector, address(hook));
    }

    // ── Test 1: prepareSwapFee revert propagates ────────────────────

    function test_prepareSwapFee_RevertPropagates_SwapReverts() external {
        _matureLaunchWindow();
        _swapToUnauthorizedEngine();

        vm.expectRevert(_unauthorizedCallerRevert());
        router.swap(key, _swapParams(true, -100 ether), address(this), block.timestamp, 0, 100 ether, "");
    }

    // ── Test 2: broken engine blocks quote/swap without emergency bypass ─

    function testUnauthorizedEngineBlocksPublicSwapWithoutEmergencyBypass() external {
        _matureLaunchWindow();
        _swapToUnauthorizedEngine();

        vm.expectRevert(_unauthorizedCallerRevert());
        router.swap(key, _swapParams(true, -100 ether), address(this), block.timestamp, 0, 100 ether, "");
    }

    function testUnauthorizedEngineBlocksQuoteWithoutEmergencyBypass() external {
        _matureLaunchWindow();
        _swapToUnauthorizedEngine();

        vm.expectRevert(_unauthorizedCallerRevert());
        router.quoteSwap(key, _swapParams(true, -100 ether), address(this));
    }

    // ── Test 4: Engine revert leaves no corrupt state ───────────────

    function test_engineRevert_NoStateCorruption_NextSwapSucceeds() external {
        _matureLaunchWindow();

        // Save original authorized engine before swapping to unauthorized one.
        IMemeverseDynamicFeeEngine originalEngine = hook.dynamicFeeEngine();

        // First swap: Unauthorized engine → swap reverts.
        _swapToUnauthorizedEngine();
        vm.expectRevert(_unauthorizedCallerRevert());
        router.swap(key, _swapParams(true, -100 ether), address(this), block.timestamp, 0, 100 ether, "");

        // Second swap: Upgrade back to original authorized engine → swap must succeed.
        hook.upgradeDynamicFeeEngine(originalEngine);
        engine = MemeverseDynamicFeeEngine(address(originalEngine));
        BalanceDelta delta =
            router.swap(key, _swapParams(true, -100 ether), address(this), block.timestamp, 0, 100 ether, "");

        // Verify the swap actually executed (non-zero delta).
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "swap must produce a delta");
    }

    // ── Test 5: Exact-output output-side fee revert propagates ──────

    function test_prepareSwapFee_RevertPropagates_ExactOutputOutputSideFee_SwapReverts() external {
        _matureLaunchWindow();
        hook.setProtocolFeeCurrency(key.currency0, false);
        hook.setProtocolFeeCurrency(key.currency1, true);
        _swapToUnauthorizedEngine();

        vm.expectRevert(_unauthorizedCallerRevert());
        router.swap(key, _swapParams(true, 1 ether), address(this), block.timestamp, 0, 10 ether, "");
    }
}
