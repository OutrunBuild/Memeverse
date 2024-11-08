// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/ERC4626.sol)

pragma solidity ^0.8.20;

import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { IERC20, ERC20 } from "../libraries/ERC20.sol";
import { IMemecoinVault } from "./interfaces/IMemecoinVault.sol";
import { IMemeverse } from "../verse/interfaces/IMemeverse.sol";

/**
 * @dev Yields mainly comes from memeverse transaction fees
 */
contract MemecoinVault is ERC20, IMemecoinVault {
    using SafeERC20 for IERC20;

    address public immutable asset;

    address public memeverse;
    uint256 public totalAssets;
    uint256 public verseId;

    constructor(
        string memory _name, 
        string memory _symbol,
        address _asset,
        address _memeverse,
        uint256 _verseId
    ) ERC20(_name, _symbol, 18) {
        asset = _asset;
        memeverse = _memeverse;
        verseId = _verseId;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, _previewTotalAssets());
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, _previewTotalAssets());
    }

    /**
     * @dev Mints shares Vault shares to receiver by depositing exactly amount of underlying tokens
     */
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        _refreshTotalAssets();
        uint256 shares = _convertToShares(assets, totalAssets);
        _deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    /**
     * @dev Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     */
    function redeem(uint256 shares, address receiver) external override returns (uint256) {
        _refreshTotalAssets();
        uint256 assets = _convertToAssets(shares, totalAssets);
        _withdraw(msg.sender, receiver, assets, shares);

        return assets;
    }

    /**
     * @dev Accumulate yields from memeverse or others
     */
    function accumulateYields(uint256 amount) external {
        address msgSender = msg.sender;
        IERC20(asset).safeTransferFrom(msgSender, address(this), amount);

        unchecked {
            totalAssets += amount;
        }

        emit AccumulateYields(msgSender, amount);
    }

    function _convertToShares(uint256 assets, uint256 latestTotalAssets) internal view returns (uint256) {
        uint256 _totalSupply = totalSupply;
        _totalSupply = _totalSupply == 0 ? 1 : _totalSupply;
        uint256 _totalAssets = latestTotalAssets;
        _totalAssets = _totalAssets == 0 ? 1 : _totalAssets;

        return assets * _totalSupply / _totalAssets;
    }

    function _convertToAssets(uint256 shares, uint256 latestTotalAssets) internal view returns (uint256) {
        uint256 _totalSupply = totalSupply;
        _totalSupply = _totalSupply == 0 ? 1 : _totalSupply;
        uint256 _totalAssets = latestTotalAssets;
        _totalAssets = _totalAssets == 0 ? 1 : _totalAssets;

        return shares * _totalAssets / _totalSupply;
    }

    function _deposit(address sender, address receiver, uint256 assets, uint256 shares) internal {
        IERC20(asset).safeTransferFrom(sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(sender, receiver, assets, shares);
    }

    function _withdraw(address sender, address receiver, uint256 assets, uint256 shares) internal {
        _burn(sender, shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(sender, receiver, assets, shares);
    }

    function _previewTotalAssets() internal view returns (uint256) {
        (, uint256 memecoinYields) = IMemeverse(memeverse).previewTransactionFees(verseId);
        return totalAssets + memecoinYields;
    }

    function _refreshTotalAssets() internal {
        IMemeverse(memeverse).redeemAndDistributeFees(verseId);
    }
}
