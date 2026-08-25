// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Memecoin interface
 */
interface IMemecoin is IERC20 {
    /**
     * @notice Get the memeverse launcher.
     * @dev Launcher is the privileged controller for issuance and lifecycle operations.
     */
    function memeverseLauncher() external view returns (address);

    /**
     * @notice Initializes memecoin metadata and omnichain delegate wiring.
     * @dev Must be called once during verse deployment before minting.
     * @param name_ ERC20 name.
     * @param symbol_ ERC20 symbol.
     * @param _memeverseLauncher Authorized launcher address.
     * @param _delegate LayerZero delegate used for OFT configuration.
     */
    function initialize(string calldata name_, string calldata symbol_, address _memeverseLauncher, address _delegate)
        external;

    /**
     * @notice Mints memecoin to a target account.
     * @dev Access should be restricted to launcher-controlled issuance paths.
     * @param account Recipient account.
     * @param amount Amount to mint.
     */
    function mint(address account, uint256 amount) external;

    /**
     * @notice Burns memecoin from caller-controlled supply.
     * @dev Used by settlement and redemption flows to retire supply.
     * @param amount Amount to burn.
     */
    function burn(uint256 amount) external;

    error ZeroInput();

    /// @dev Thrown when a privileged action is invoked by an account that is not the authorized controller.
    error PermissionDenied();
}
