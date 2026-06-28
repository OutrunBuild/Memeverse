// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

contract MemeverseSwapForkSmokeTest is MemeverseSwapForkBase {
    function setUp() public {
        // Smoke only verifies fork + V4 pool init + hook flag; protocol-fee wiring belongs to
        // the dedicated swap tests (the setter is owner-only and not on the abstract interface).
        _setUpBase(IPermit2(address(0)));
    }

    function testSmoke_ForkAndPoolInitialized() external view {
        // Pool is initialized on the real V4 PoolManager: slot0 sqrtPrice == 1.0
        (uint160 sqrtPriceX96,,,) = _slot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool initialized at 1.0 on real V4");
        // Hook proxy carries the mined flag bits (low 14 == 0x28CC).
        assertEq(uint160(address(key.hooks)) & 0x3FFF, 0x28CC, "hook flag address");
    }
}
