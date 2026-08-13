// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMemecoin} from "./interfaces/IMemecoin.sol";
import {OutrunOFTInit} from "../common/omnichain/oft/OutrunOFTInit.sol";

/**
 * @title Omnichain Memecoin
 */
contract Memecoin is IMemecoin, OutrunOFTInit {
    address public memeverseLauncher;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    /**
     * @param _lzEndpoint The local LayerZero endpoint address.
     */
    constructor(address _lzEndpoint) OutrunOFTInit(_lzEndpoint) {}

    /// @notice Initializes the memecoin proxy instance.
    /// @dev Wires OFT metadata and records the launcher that controls future minting.
    /// @param name_ Human-readable token name.
    /// @param symbol_ Token ticker symbol.
    /// @param _memeverseLauncher Launcher allowed to mint new supply.
    /// @param _delegate Delegate that receives initial ownership and LayerZero admin rights.
    function initialize(string calldata name_, string calldata symbol_, address _memeverseLauncher, address _delegate)
        external
        override
        initializer
    {
        __OutrunOFT_init(name_, symbol_, _delegate);
        __OutrunOwnable_init(_delegate);

        // Defense in depth, mirroring the launcher facade's ZeroInput checks: a zero launcher would
        // permanently freeze minting (no setter exists), so reject it at initialization time.
        require(_memeverseLauncher != address(0), ZeroInput());
        memeverseLauncher = _memeverseLauncher;
    }

    /// @notice Mints new memecoin supply to `account`.
    /// @dev Only the configured launcher may mint.
    /// @param account Recipient of the newly minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        require(amount != 0, ZeroInput());
        _mint(account, amount);
    }

    /// @notice Burns memecoin from the caller.
    /// @dev Used by holders or downstream protocol flows that first move tokens into the caller.
    /// @param amount Amount of tokens to burn.
    function burn(uint256 amount) external override {
        require(amount != 0, ZeroInput());
        // Self-burn only by design: the launcher and protocol flows always burn tokens they already
        // hold (leftover bootstrap budget, vault yield), so unlike MemePol there is no allowance-based
        // third-party burn overload — see MemePol.burn(address,uint256) for the sibling variant.
        _burn(msg.sender, amount);
    }
}
