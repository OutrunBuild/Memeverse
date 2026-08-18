// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {CurrencySettler} from "../../../src/swap/libraries/CurrencySettler.sol";
import {OutrunSafeERC20} from "../../../src/common/token/OutrunSafeERC20.sol";

import {
    FalseTransferFromToken,
    FalseTransferToken,
    NoReturnTransferToken,
    MockPoolManager
} from "../../mocks/swap/CurrencySettlerMocks.sol";

contract CurrencySettlerHarness {
    using CurrencySettler for Currency;

    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount) external {
        currency.settle(manager, payer, amount);
    }

    /// @dev Exposes transferWithGuard for unit testing (CI-010).
    function transferWithGuard(Currency currency, address to, uint256 amount) external {
        currency.transferWithGuard(to, amount);
    }
}

contract CurrencySettlerTest is Test {
    CurrencySettlerHarness internal harness;
    MockPoolManager internal manager;

    function setUp() external {
        harness = new CurrencySettlerHarness();
        manager = new MockPoolManager();
    }

    function testSettleRevertsWithERC20TransferFromFailed() external {
        FalseTransferFromToken token = new FalseTransferFromToken();

        vm.expectRevert(
            abi.encodeWithSelector(
                CurrencySettler.ERC20TransferFromFailed.selector, address(this), address(manager), 1 ether
            )
        );
        harness.settle(Currency.wrap(address(token)), IPoolManager(address(manager)), address(this), 1 ether);
    }

    function testSettleRevertsWithERC20TransferFailed() external {
        FalseTransferToken token = new FalseTransferToken();

        vm.expectRevert(abi.encodeWithSelector(CurrencySettler.ERC20TransferFailed.selector, address(manager), 1 ether));
        vm.prank(address(harness));
        harness.settle(Currency.wrap(address(token)), IPoolManager(address(manager)), address(harness), 1 ether);
    }

    /// @dev Zero-amount is a no-op: no external call, no revert (CI-010 guard).
    function testTransferWithGuardSkipsZeroAmount() external {
        FalseTransferToken token = new FalseTransferToken();

        // Would revert if the guard did not short-circuit on amount == 0.
        harness.transferWithGuard(Currency.wrap(address(token)), address(0xBEEF), 0);
    }

    /// @dev Zero-address recipient reverts before any external call (CI-010 guard).
    function testTransferWithGuardRevertsOnZeroAddressRecipient() external {
        FalseTransferToken token = new FalseTransferToken();

        vm.expectRevert(CurrencySettler.ZeroAddress.selector);
        harness.transferWithGuard(Currency.wrap(address(token)), address(0), 1 ether);
    }

    /// @dev Non-compliant ERC20 (transfer returns no bool) succeeds — the core behavior change of CI-010.
    function testTransferWithGuardSucceedsWithNonCompliantERC20() external {
        NoReturnTransferToken token = new NoReturnTransferToken();

        // No revert: OutrunSafeERC20 treats empty returndata + extcodesize>0 as success.
        harness.transferWithGuard(Currency.wrap(address(token)), address(0xBEEF), 1 ether);
    }

    /// @dev Compliant ERC20 returning false still reverts with SafeERC20FailedOperation (CI-010).
    function testTransferWithGuardRevertsWhenTransferReturnsFalse() external {
        FalseTransferToken token = new FalseTransferToken();

        vm.expectRevert(abi.encodeWithSelector(OutrunSafeERC20.SafeERC20FailedOperation.selector, address(token)));
        harness.transferWithGuard(Currency.wrap(address(token)), address(0xBEEF), 1 ether);
    }
}
