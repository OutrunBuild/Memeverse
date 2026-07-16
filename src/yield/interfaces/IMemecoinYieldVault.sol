// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IERC20} from "../../common/token/OutrunERC20Init.sol";

interface IMemecoinYieldVault is IERC20 {
    struct RedeemRequest {
        uint192 amount; // Requested redeem amount
        uint64 requestTime; // Time when the redeem request was made
    }

    /// @notice Exposes the underlying memecoin managed by the vault.
    /// @dev This is the asset deposited by users and accumulated as yield.
    /// @return assetTokenAddress Underlying asset token address.
    function asset() external view returns (address assetTokenAddress);

    /// @notice Exposes the total amount of managed underlying assets.
    /// @dev Includes deposited principal plus any accumulated yield that has not been redeemed yet.
    /// @return totalManagedAssets Total managed asset amount.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Preview how many vault shares a deposit would mint at the current rate.
    /// @dev Uses the vault's current share pricing without mutating state.
    /// @param assets Amount of underlying asset to deposit.
    /// @return shares Shares that would be minted.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview how many underlying assets redeeming `shares` would unlock today.
    /// @dev Uses the vault's current share pricing without mutating state.
    /// @param shares Amount of vault shares to redeem.
    /// @return assets Underlying asset amount that would be redeemed.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Initializes the yield vault proxy.
    /// @dev Wires ERC20 share metadata, the yield dispatcher, the verse-specific underlying asset, and the
    ///      permanent virtual buffer used to dampen exchange-rate inflation.
    /// @param name Share token name.
    /// @param symbol Share token symbol.
    /// @param yieldDispatcher Address allowed to re-accumulate remote yield.
    /// @param asset Underlying memecoin address.
    /// @param verseId Verse id associated with this vault.
    /// @param virtualAssets Permanent virtual buffer V added symmetrically to the share/asset sides of every
    ///        conversion; sized by the launcher at 0.7% of the minimum main-pool memecoin provision.
    function initialize(
        string calldata name,
        string calldata symbol,
        address yieldDispatcher,
        address asset,
        uint256 verseId,
        uint256 virtualAssets
    ) external;

    /// @notice Adds freshly supplied yield into the vault.
    /// @dev Implementations may restrict who is allowed to call this entrypoint.
    /// @param amount Amount of underlying asset being contributed as yield.
    function accumulateYields(uint256 amount) external;

    /// @notice Retries a failed cross-chain yield accumulation using the stored compose payload.
    /// @dev Implementations may restrict who is allowed to call this entrypoint.
    /// @param lzGuid LayerZero compose guid for the failed yield transfer.
    function reAccumulateYields(bytes32 lzGuid) external;

    /// @notice Deposits underlying asset and mints vault shares.
    /// @dev Implementations may add validation around who may receive shares.
    /// @param assets Amount of underlying asset to deposit.
    /// @param receiver Recipient of the minted vault shares.
    /// @return shares Shares minted for the deposit.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Queues a redemption request subject to the vault's delay.
    /// @dev Implementations may add validation around who may queue redemptions.
    /// @param shares Amount of shares to burn into the redemption queue.
    /// @param receiver Account that will later execute the redemption.
    /// @return assets Underlying assets represented by the queued redemption.
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Redeems every matured request queued by the caller.
    /// @dev Implementations may aggregate multiple matured requests into a single transfer result.
    /// @return redeemedAmount Total underlying asset amount redeemed in this call.
    function executeRedeem() external returns (uint256 redeemedAmount);

    event AccumulateYields(address indexed yieldSource, uint256 yield, uint256 exchangeRate);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    event RedeemRequested(
        address indexed sender, address indexed receiver, uint256 assets, uint256 shares, uint256 requestTime
    );

    event RedeemExecuted(address indexed receiver, uint256 amount);

    error ZeroAddress();

    error ZeroVirtualAssets();

    error ZeroRedeemRequest();

    error MaxRedeemRequestsReached();

    error RedeemAmountOverflowed(uint256 assets);
}
