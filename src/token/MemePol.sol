// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPol, PoolId} from "./interfaces/IPol.sol";
import {OutrunOFTInit} from "../common/omnichain/oft/OutrunOFTInit.sol";

/**
 * @title Omnichain Memecoin Proof Of Liquidity(POL) Token
 */
contract MemePol is IPol, OutrunOFTInit {
    address public memecoin;
    address public memeverseLauncher;

    PoolId public poolId;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    /**
     * @param _lzEndpoint The local LayerZero endpoint address.
     */
    constructor(address _lzEndpoint) OutrunOFTInit(_lzEndpoint) {}

    /// @notice Initializes the liquid-proof token proxy.
    /// @dev Sets OFT metadata, stores the paired memecoin address (init-only pointer, see `memecoin()`), and records the launcher that governs minting and pool setup.
    /// @param name_ Human-readable token name.
    /// @param symbol_ Token ticker symbol.
    /// @param memecoin_ Paired memecoin address for this POL token.
    /// @param memeverseLauncher_ Launcher allowed to mint and configure this token.
    /// @param delegate_ Delegate that receives initial ownership and LayerZero admin rights.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address memecoin_,
        address memeverseLauncher_,
        address delegate_
    ) external override initializer {
        __OutrunOFT_init(name_, symbol_, delegate_);
        __OutrunOwnable_init(delegate_);

        // Defense in depth, mirroring the launcher facade's ZeroInput checks: a zero launcher would
        // permanently freeze minting and pool setup (no setter exists), and a zero memecoin link
        // would leave the pairing getter permanently empty — reject both at initialization time.
        require(memecoin_ != address(0) && memeverseLauncher_ != address(0), ZeroInput());
        memecoin = memecoin_;
        memeverseLauncher = memeverseLauncher_;
    }

    /// @notice Records the Uniswap pool managed by this POL token.
    /// @dev Only the launcher may set the pool id after liquidity deployment. Not one-shot: the
    ///      launcher may overwrite the value, and every write emits `PoolIdSet`.
    /// @param _poolId Pool identifier associated with POL liquidity.
    function setPoolId(PoolId _poolId) external override onlyMemeverseLauncher {
        emit PoolIdSet(poolId, _poolId);
        poolId = _poolId;
    }

    /// @notice Mints POL to `account`.
    /// @dev Only the launcher may mint.
    /// @param account Recipient of the newly minted POL.
    /// @param amount Amount of POL to mint.
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        require(amount != 0, ZeroInput());

        _mint(account, amount);
    }

    /// @notice Burns POL from `account`, spending allowance when called by a third party.
    /// @dev Used by launcher and redemption flows that may burn on behalf of a holder.
    /// @param account Account whose POL is being burned.
    /// @param amount Amount of POL to burn.
    function burn(address account, uint256 amount) external {
        require(amount != 0, ZeroInput());
        // Third-party burns spend allowance: the launcher proxy burns on the holder's behalf
        // (redeemMemecoinLiquidity runs under delegatecall, so the proxy is the spender and the
        // holder must pre-approve it). The msg.sender == account skip also lets the launcher's own
        // settlement self-burns proceed without a self-allowance. Memecoin has no such overload
        // because its launcher only burns tokens it already holds.
        if (msg.sender != account) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @notice Burns POL from the caller.
    /// @dev Convenience overload for self-burn flows.
    /// @param amount Amount of POL to burn.
    function burn(uint256 amount) external {
        require(amount != 0, ZeroInput());
        _burn(msg.sender, amount);
    }
}
