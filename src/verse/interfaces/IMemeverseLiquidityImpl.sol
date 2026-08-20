// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title IMemeverseLiquidityImpl
/// @notice Selector interface for the MemeverseLiquidityImpl delegatecall sibling. The MemeverseLauncherUpgradeable
///         facade encodes these selectors when delegatecalling into the liquidity sibling, and the
///         MemeverseLaunchImpl sibling uses `deployBootstrapLiquidity.selector` for its nested bootstrap
///         delegatecall. Each signature must match the implementation byte-for-byte so the delegatecall
///         selector resolves correctly.
interface IMemeverseLiquidityImpl {
    /// @notice Bootstrap liquidity entrypoint. Invoked by the launcher facade via `_deployLiquidity`
    ///         (itself nested inside `MemeverseLaunchImpl.changeStage`) so it writes to the proxy's
    ///         MemeverseLauncherStorage. Renamed from the old `deployLiquidity`; the selector changes.
    /// @dev Delegatecall-only by construction (no initializer, no own mutable state). See
    ///      MemeverseLiquidityImpl.deployBootstrapLiquidity for the full invariant.
    function deployBootstrapLiquidity(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) external;

    /// @notice Collects uAsset/memecoin from the caller, adds liquidity via the verse router, mints POL to the
    ///         caller, and refunds any unused input.
    /// @dev Invoked via delegatecall by the facade's `mintPOLToken`. Under delegatecall `msg.sender` is still
    ///      the original caller (transfer-in payer, POL mint recipient, refund target) and `address(this)` is
    ///      the launcher proxy (token custody, approval owner, router liquidity recipient).
    function mintPOLToken(
        address uAsset,
        address memecoin,
        address pol,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    ) external returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut);

    /// @notice Redeems launcher-managed memecoin-side LP using POL, optionally unwrapping into underlying.
    ///         Approve the launcher proxy as a POL spender first (the burn is executed by the proxy on the
    ///         caller's behalf).
    /// @dev Invoked via delegatecall by the facade's `redeemMemecoinLiquidity`. Under delegatecall `msg.sender`
    ///      is the original caller (POL burner, LP/refund recipient). POLendUpgradeable also reaches this entry through
    ///      the facade callback ABI. The POL burn is executed by the launcher proxy on the caller's behalf, so
    ///      the caller must first approve the launcher proxy as a POL spender for at least `amountInPOL`;
    ///      otherwise the call reverts with `ERC20InsufficientAllowance`.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        returns (uint256 amountInLP);

    /// @notice Redeems launcher-managed memecoin-side LP using POL, optionally unwrapping into underlying
    ///         with slippage protection.
    ///         Approve the launcher proxy as a POL spender first. When `unwrap` is true, `amount0Min`/`amount1Min`
    ///         and `deadline` enforce slippage protection on the underlying `removeLiquidity` (zero means no
    ///         protection — callers should set them to their minimum acceptable outputs). When `unwrap` is false
    ///         the slippage params are ignored.
    /// @dev Invoked via delegatecall by the facade's slippage-protected `redeemMemecoinLiquidity`. See the
    ///      3-arg overload for delegatecall semantics.
    /// @param verseId Memeverse id.
    /// @param amountInPOL POL amount to burn (1:1 with LP).
    /// @param unwrap Whether to unwrap LP into underlying assets.
    /// @param amount0Min Minimum currency0 output when unwrapping (sorted order at router).
    /// @param amount1Min Minimum currency1 output when unwrapping.
    /// @param deadline Latest timestamp for the unwrap removal (passed to router).
    function redeemMemecoinLiquidity(
        uint256 verseId,
        uint256 amountInPOL,
        bool unwrap,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amountInLP);

    /// @notice Redeems the caller's post-settlement auxiliary-liquidity share.
    /// @dev Invoked via delegatecall by the facade's `redeemAuxiliaryLiquidity`. Under delegatecall `msg.sender`
    ///      is the original caller (LP and residual-claim recipient).
    function redeemAuxiliaryLiquidity(uint256 verseId)
        external
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount);

    /// @notice Settles the leveraged auxiliary-liquidity portion on behalf of POLendUpgradeable.
    /// @dev Invoked via delegatecall by the facade's `settleLeveragedAuxiliaryLiquidity`. The facade keeps the
    ///      `msg.sender == polend` guard on the facade ABI, so under delegatecall `msg.sender` here is POLendUpgradeable.
    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount);
}
