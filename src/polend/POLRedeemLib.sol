// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "../common/token/OutrunERC20Init.sol";
import {OutrunSafeERC20} from "../common/token/OutrunSafeERC20.sol";
import {IMemeverseLauncher} from "../verse/interfaces/IMemeverseLauncher.sol";

/// @title POLRedeemLib
/// @notice Shared POL redemption and balance-delta measurement for the two settlement paths
///         (POLendUpgradeable global settlement and POLSplitterUpgradeable settle).
/// @dev Single-sourcing this sequence keeps both callers from drifting apart: a one-sided edit
///      of the redemption call parameters or the measurement basis would silently fork the two
///      settlement paths' accounting inputs. `redeemMemecoinLiquidity` returns the burned LP
///      amount, not the recovered tokens, so the before/after balance diff is the only reliable
///      measurement. Call-specific concerns (zero-amount handling, address resolution) stay at
///      the call sites; this library holds only what both paths must do identically.
library POLRedeemLib {
    using OutrunSafeERC20 for IERC20;

    /// @notice Approves and redeems `polAmount` of POL through the launcher with unwrap enabled,
    ///         then measures the recovered uAsset and memecoin by balance delta.
    /// @dev Zero min-outs and a same-block deadline are the shared call policy for both
    ///      settlement paths (the accepted zero-slippage risk); editing them here changes both
    ///      paths at once, which is the point of the shared source. This library is internal and
    ///      inlines into each caller's bytecode, so `address(this)` is the calling contract:
    ///      unwrapped tokens are sent to and measured for the caller itself.
    function redeemAndMeasure(
        address launcher,
        address pol,
        address uAsset,
        address memecoin,
        uint256 verseId,
        uint256 polAmount
    ) internal returns (uint256 uAssetAmount, uint256 memecoinAmount) {
        uint256 beforeUAsset = IERC20(uAsset).balanceOf(address(this));
        uint256 beforeMemecoin = IERC20(memecoin).balanceOf(address(this));

        IERC20(pol).safeApprove(launcher, polAmount);
        _redeemMemecoinLiquidity(launcher, verseId, polAmount);

        uAssetAmount = IERC20(uAsset).balanceOf(address(this)) - beforeUAsset;
        memecoinAmount = IERC20(memecoin).balanceOf(address(this)) - beforeMemecoin;
    }

    /// @notice Thin wrapper around the launcher's slippage-protected redemption; returns the
    ///         burned LP amount so the external call's return value is captured, not discarded.
    /// @dev `redeemAndMeasure` deliberately drops that LP figure — the library-level note above
    ///      is the single authoritative explanation of why the balance delta is the measurement.
    ///      Capturing the return also ABI-decodes the launcher's returndata, so a malformed
    ///      response fails loudly here instead of yielding a silently wrong measurement.
    function _redeemMemecoinLiquidity(address launcher, uint256 verseId, uint256 polAmount)
        internal
        returns (uint256 amountInLP)
    {
        amountInLP = IMemeverseLauncher(launcher)
            .redeemMemecoinLiquidity(verseId, polAmount, true, 0, 0, block.timestamp);
    }
}
