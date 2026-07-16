// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Minimal PoolManager stand-in exposing only the surface CurrencySettler may call.
contract MockPoolManager {
    function burn(address, uint256, uint256) external {}

    function settle() external payable {}

    function sync(Currency) external {}

    function take(Currency, address, uint256) external {}

    function mint(address, uint256, uint256) external {}
}

/// @notice Token whose transferFrom always fails, used to assert revert bubbling.
contract FalseTransferFromToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Token whose transfer always fails, used to assert revert bubbling.
contract FalseTransferToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Non-compliant ERC20 whose transfer returns no data (no bool).
/// @dev Exercises the OutrunSafeERC20 success-on-empty-returndata branch (CI-010).
contract NoReturnTransferToken {
    /// @dev Returns nothing — not even a bool. OZ-style safeTransfer treats this as success.
    function transfer(address, uint256) external {
        // intentionally no return
    }
}
