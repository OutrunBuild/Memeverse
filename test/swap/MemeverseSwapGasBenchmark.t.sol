// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MemeverseSwapRouter} from "../../src/swap/MemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {MemeverseYTFlashSwapRouter} from "../../src/swap/MemeverseYTFlashSwapRouter.sol";

import {MemeverseYTFlashSwapRouterIntegrationTest} from "./MemeverseYTFlashSwapRouterIntegration.t.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @title MemeverseSwapGasBenchmark
/// @notice Measures the gas of one swap routed through a smart-account frame (`AtomicSessionAccount.executeSession`)
///         for the ordinary Swap Router and the YT Flash Swap Router, on the SAME PT/POL pool, SAME amount (1e18),
///         SAME state.
///
/// @dev === WHAT THE NUMBER COVERS ===
///      `gasleft()` brackets the single `account.executeSession(hook, router, cd)` call. Inside that frame
///      (see AtomicSessionAccount.executeSession) the full swap path runs: `beginAccountSession` → router call
///      (unlock → v4 swap → real hook callbacks → settle/take) → `endAccountSession`. So the reported number is
///      the **swap body + the bare account-forwarding overhead** (calldata memory copy + returndata capture), at
///      real-v4 execution cost. This is enough to compare the three operations against each other on identical state.
///
///      === WHAT THE NUMBER DOES NOT COVER (not measurable by any forge test) ===
///      1. EVM 21,000 intrinsic — charged at tx start before any bytecode runs; forge tests are calls, not txs.
///      2. Tx calldata gas (4/16 per byte) — the user→account tx calldata; forge builds calldata in memory.
///      3. Account verification layer — ERC-4337 EntryPoint handleOps validation, Safe signature/module checks,
///         EIP-7702 ecrecover + delegation setup. `AtomicSessionAccount` is a bare forwarder with NO signature,
///         nonce, or identity checks (see AccountSessionMocks.sol), so this cost is ~0 here and UNDERCOUNTS any
///         real account type by roughly 3k–30k depending on implementation.
///      4. Cold-access surcharge (EIP-2929, ~2,600 per first-touched address / ~2,100 per cold slot) — the
///         `setUp()`/`_ensureOrdinaryRouter`/`_configureProtocolFeeSide` runs warm up hook, manager, pool tokens,
///         splitter, account, router before the gas window opens, so the measurement sees WARM prices. A real
///         standalone tx starts cold (~20k–30k extra across all first-touched addresses).
///      5. EIP-3529 refund cap — `gasleft()` reports gross gas; SSTORE refunds apply at tx end, not mid-frame.
///
///      === HOW TO READ THE NUMBERS ===
///      - For RELATIVE comparison (Flash vs ordinary, same pool/amount/state): directly comparable, the gaps above
///        are identical across the three tests so they cancel out. Flash Buy ≈ +53%, Flash Sell ≈ +47% over ordinary.
///      - For ABSOLUTE "full user-tx gasUsed": add 21,000 + tx-calldata + the chosen account type's verification
///        cost + cold-access (~20k–30k). forge cannot produce this number directly.
contract MemeverseSwapGasBenchmark is MemeverseYTFlashSwapRouterIntegrationTest {
    /// @notice The ordinary Memeverse Swap Router. The parent fixture deploys only the YT Flash Router.
    MemeverseSwapRouter internal ordinaryRouter;
    bool internal _ordinaryReady;

    /// @dev Lazy one-time init of the ordinary router + `account` allowance for it. The parent `setUp()` is
    ///      non-virtual so it cannot be overridden; this runs before the first gas measurement instead. `account`
    ///      is already funded (POL/PT/YT) and approved for the settler + flash router by the parent fixture; it
    ///      only needs an extra allowance for the ordinary router, which pulls PT input via transferFrom.
    ///
    ///      GAS-WINDOW NOTE: this runs BEFORE `gasBefore`, so its own gas is not measured. But it WARMS UP the
    ///      ordinaryRouter address and the allowance storage slots, which is why the measurement sees them at warm
    ///      price (see contract-level cold-access caveat #4). Identical warm-up happens in all three tests.
    function _ensureOrdinaryRouter() internal {
        if (_ordinaryReady) return;
        ordinaryRouter =
            new MemeverseSwapRouter(manager, IMemeverseUniswapHook(address(hook)), lens, IPermit2(address(0)));
        vm.startPrank(address(account));
        MockERC20Like(pt).approve(address(ordinaryRouter), type(uint256).max);
        MockERC20Like(address(pol)).approve(address(ordinaryRouter), type(uint256).max);
        vm.stopPrank();
        _ordinaryReady = true;
    }

    /// @notice Ordinary-swap gas inside the account frame: executeSession(ordinaryRouter.swap).
    /// @dev Same PT/POL pool, same 1e18 input as the Flash Buy benchmark. Direction PT->POL matches the flash
    ///      buy's underlying leg (buy swaps PT->POL then splits). Fee side: `_configureProtocolFeeSide(..., Buy,
    ///      true)` puts the protocol fee on the PT (input) side — IDENTICAL to test_Gas_FlashSwap_BuyYT, so the
    ///      ordinary-vs-flash-buy comparison is on byte-identical fee state. Note test_Gas_FlashSwap_SellYT uses
    ///      the Sell/input-fee-on-POL side (correct for a sell), so cross-reading it against this number is NOT a
    ///      pure same-fee-side comparison — see the sell test's note.
    function test_Gas_OrdinarySwap_PTforPOL() public {
        _ensureOrdinaryRouter();
        _configureProtocolFeeSide(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, true);
        SwapParams memory params = SwapParams({
            zeroForOne: ptIsCurrency0,
            amountSpecified: -int256(uint256(YT_AMOUNT)),
            sqrtPriceLimitX96: _priceLimitFor(ptIsCurrency0)
        });
        bytes memory cd =
            abi.encodeCall(ordinaryRouter.swap, (key, params, recipient, block.timestamp + 600, 0, YT_AMOUNT, ""));

        uint256 gasBefore = gasleft();
        vm.prank(address(account));
        account.executeSession(hook, address(ordinaryRouter), cd);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS ordinary swap PT->POL (executeSession frame)", gasUsed);
    }

    /// @notice YT Flash Buy gas inside the account frame: executeSession(swapPOLForExactYT).
    /// @dev Fee side: `_configureProtocolFeeSide(..., Buy, true)` = protocol fee on PT (input) side, IDENTICAL to
    ///      test_Gas_OrdinarySwap_PTforPOL. So ordinary-vs-flash-buy is a clean same-pool/same-amount/same-fee
    ///      comparison; Flash Buy ≈ +53% over ordinary.
    function test_Gas_FlashSwap_BuyYT() public {
        _ensureOrdinaryRouter(); // keeps the three tests' init path identical
        _configureProtocolFeeSide(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Buy, true);
        bytes memory cd = abi.encodeCall(
            router.swapPOLForExactYT,
            (
                primaryVersePool.verseId,
                YT_AMOUNT,
                YT_AMOUNT,
                _priceLimitFor(ptIsCurrency0),
                recipient,
                block.timestamp + 600,
                referrer
            )
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(account));
        account.executeSession(hook, address(router), cd);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS flash buy YT (executeSession frame)", gasUsed);
    }

    /// @notice YT Flash Sell gas inside the account frame: executeSession(swapExactYTForPOL).
    /// @dev Fee side: `_configureProtocolFeeSide(..., Sell, true)` = protocol fee on POL (input) side — the
    ///      CORRECT fee placement for a sell direction. This differs from the Buy tests (fee on PT), so this
    ///      number is NOT directly cross-comparable to the buy/ordinary numbers under the same fee model.
    ///      Comparing it against ordinary is for rough magnitude only, not a controlled-fee comparison.
    function test_Gas_FlashSwap_SellYT() public {
        _ensureOrdinaryRouter();
        _configureProtocolFeeSide(primaryVersePool, MemeverseYTFlashSwapRouter.FlashAction.Sell, true);
        bytes memory cd = abi.encodeCall(
            router.swapExactYTForPOL,
            (
                primaryVersePool.verseId,
                YT_AMOUNT,
                0,
                _priceLimitFor(!ptIsCurrency0),
                recipient,
                block.timestamp + 600,
                referrer
            )
        );

        uint256 gasBefore = gasleft();
        vm.prank(address(account));
        account.executeSession(hook, address(router), cd);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS flash sell YT (executeSession frame)", gasUsed);
    }
}

/// @dev Minimal ERC20 mutate surface for approvals. Avoids importing concrete test-only tokens.
interface MockERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}
