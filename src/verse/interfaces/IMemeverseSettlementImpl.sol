// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title IMemeverseSettlementImpl
/// @notice Selector interface for the MemeverseSettlementImpl delegatecall sibling. The MemeverseLauncherUpgradeable
///         facade encodes these selectors when delegatecalling into the settlement sibling. Each signature
///         must match the implementation byte-for-byte so the delegatecall selector resolves correctly.
interface IMemeverseSettlementImpl {
    /// @notice Refund the caller's uAsset genesis contribution after a verse resolved to `Stage.Refund`.
    /// @dev Invoked via delegatecall by the facade's `refund`. Under delegatecall `msg.sender` is the
    ///      original caller (refund recipient) and `address(this)` is the launcher proxy.
    /// @param verseId Memeverse id.
    /// @return genesisFund The refunded genesis contribution amount.
    function refund(uint256 verseId) external returns (uint256 genesisFund);

    /// @notice Refund the caller's uAsset preorder contribution after a verse resolved to `Stage.Refund`.
    /// @dev Invoked via delegatecall by the facade's `refundPreorder`. Under delegatecall `msg.sender` is
    ///      the original caller (refund recipient) and `address(this)` is the launcher proxy.
    /// @param verseId Memeverse id.
    /// @return preorderFund The refunded preorder contribution amount.
    function refundPreorder(uint256 verseId) external returns (uint256 preorderFund);

    /// @notice Claim the caller's normal YT (Yield Token) share after Genesis resolves to `Locked`.
    /// @dev Invoked via delegatecall by the facade's `claimNormalYT`. Under delegatecall `msg.sender` is
    ///      the original caller (YT recipient) and `address(this)` is the launcher proxy.
    /// @param verseId Memeverse id.
    /// @return amount The claimed YT amount.
    function claimNormalYT(uint256 verseId) external returns (uint256 amount);

    /// @notice Claim the caller's accumulated uAsset and PT normal-fee entitlements.
    /// @dev Invoked via delegatecall by the facade's `claimNormalFees`. Under delegatecall `msg.sender`
    ///      is the original caller (fee recipient) and `address(this)` is the launcher proxy.
    /// @param verseId Memeverse id.
    /// @return uAssetAmount The claimed uAsset fee amount.
    /// @return ptAmount The PT fee amount: transferred PT, or zero when redeemed to uAsset in place;
    ///      on the settled zero-backing dust path it reports the still-pending PT entitlement.
    function claimNormalFees(uint256 verseId) external returns (uint256 uAssetAmount, uint256 ptAmount);

    /// @notice Claim the caller's currently vested unlocked preorder memecoin.
    /// @dev Invoked via delegatecall by the facade's `claimUnlockedPreorderMemecoin`. Under delegatecall
    ///      `msg.sender` is the original caller (memecoin recipient) and `address(this)` is the launcher
    ///      proxy. Uses the shared `MemeverseLauncherLib.claimablePreorderMemecoinForAccount` helper so the
    ///      view and the claim path cannot drift.
    /// @param verseId Memeverse id.
    /// @return amount The claimed preorder memecoin amount.
    function claimUnlockedPreorderMemecoin(uint256 verseId) external returns (uint256 amount);

    /// @notice Collect redeemed fees, burn POL, split the executor reward, and distribute the rest.
    /// @dev Invoked via delegatecall by the facade's `redeemAndDistributeFees`. `msg.value` is the
    ///      caller-supplied LayerZero native fee and is preserved across the delegatecall, hence `payable`.
    ///      Under delegatecall `msg.sender` is the facade's caller (arbitrary executor + refund target).
    /// @param verseId Memeverse id.
    /// @param rewardReceiver Receiver of the executor reward.
    /// @param polSplitter The launcher's configured POLSplitterUpgradeable address (forwarded by the facade).
    /// @return govFee The distributed governor fee amount.
    /// @return memecoinFee The distributed memecoin fee amount.
    /// @return polFee The distributed POL fee amount.
    /// @return executorReward The distributed executor reward amount.
    /// @return hadFees True iff any redeemed fees were collected (the facade emits only when true).
    function collectAndDistributeFees(uint256 verseId, address rewardReceiver, address polSplitter)
        external
        payable
        returns (uint256 govFee, uint256 memecoinFee, uint256 polFee, uint256 executorReward, bool hadFees);

    /// @notice Consolidate the facade's `changeStage` Locked -> Unlocked branch: capture locked auxiliary
    ///         fees, advance the stage, settle POLSplitterUpgradeable / POLendUpgradeable, and arm post-unlock public-swap
    ///         protection.
    /// @dev Invoked via a nested delegatecall from the launch sibling's `changeStage`. The launch sibling
    ///      owns the `ChangeStage` emit; this entry performs the state transition only. Under delegatecall
    ///      `msg.sender` is the facade's caller (arbitrary stage advancer) and `address(this)` is the
    ///      launcher proxy.
    /// @param verseId Memeverse id.
    /// @param polSplitter The launcher's configured POLSplitterUpgradeable address (forwarded by the facade).
    /// @param hook The launcher's configured MemeverseUniswapHookUpgradeable address (forwarded by the facade).
    function unlockFromLocked(uint256 verseId, address polSplitter, address hook) external;
}
