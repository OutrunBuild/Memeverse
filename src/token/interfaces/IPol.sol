// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin Proof Of Liquidity(POL) Token Interface
 */
interface IPol is IERC20 {
    /**
     * @notice Get the memeverse launcher.
     * @dev Launcher is the only authorized minter/burner coordinator for POL lifecycle actions.
     */
    function memeverseLauncher() external view returns (address);

    /**
     * @notice Get the paired memecoin.
     * @dev Pointer-only: stored once at initialization for off-chain/integrator pairing and never
     *      read at runtime — no in-repo production code reads it. POL does not custody or consume
     *      the paired memecoin at the token layer (mint/burn only move POL balances).
     * @return memecoin The memecoin address associated with this POL token.
     */
    function memecoin() external view returns (address);

    /**
     * @notice Initializes POL token metadata and launcher wiring.
     * @dev Called once from deployment flow before any mint/burn activity.
     * @param name_ ERC20 name.
     * @param symbol_ ERC20 symbol.
     * @param memecoin_ Paired memecoin address associated with this POL token.
     * @param memeverseLauncher_ Authorized launcher controlling issuance flows.
     * @param delegate_ LayerZero delegate used by omnichain OFT setup.
     */
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address memecoin_,
        address memeverseLauncher_,
        address delegate_
    ) external;

    /**
     * @notice Mints POL tokens to a target account.
     * @dev Access is expected to be restricted to launcher-controlled paths.
     * @param account Recipient account.
     * @param amount Amount of POL tokens to mint.
     */
    function mint(address account, uint256 amount) external;

    /**
     * @notice Burns POL tokens from a target account.
     * @dev `account` may burn directly, or a caller may burn from `account` with sufficient allowance. Burning only destroys POL; redeem underlying liquidity through MemeverseLauncherUpgradeable.redeemMemecoinLiquidity.
     * @param account Account whose POL balance is reduced.
     * @param amount Amount of POL tokens to burn.
     */
    function burn(address account, uint256 amount) external;

    error ZeroInput();

    /// @dev Thrown when a privileged action is invoked by an account that is not the authorized controller.
    error PermissionDenied();
}
