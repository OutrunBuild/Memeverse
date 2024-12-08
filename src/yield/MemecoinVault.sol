// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { IERC20, ERC20 } from "../common/ERC20.sol";
import { IMemecoinVault } from "./interfaces/IMemecoinVault.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";

/**
 * @dev Yields mainly comes from memeverseLauncher transaction fees
 */
contract MemecoinVault is ERC20, IMemecoinVault {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_REDEEM_REQUESTS = 5;
    uint256 public constant REDEEM_DELAY = 1 days;  // Preventing flash attacks
    address public immutable asset;

    address public memeverseLauncher;
    uint256 public totalAssets;
    uint256 public verseId;

    mapping(address account => RedeemRequest[]) public redeemRequestQueues;

    constructor(
        string memory _name, 
        string memory _symbol,
        address _asset,
        address _memeverseLauncher,
        uint256 _verseId
    ) ERC20(_name, _symbol, 18) {
        asset = _asset;
        memeverseLauncher = _memeverseLauncher;
        verseId = _verseId;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, _previewTotalAssets());
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, _previewTotalAssets());
    }

    /**
     * @dev Accumulate yields from memeverseLauncher or others
     */
    function accumulateYields(uint256 amount) external {
        address msgSender = msg.sender;
        IERC20(asset).safeTransferFrom(msgSender, address(this), amount);

        unchecked {
            totalAssets += amount;
        }

        emit AccumulateYields(msgSender, amount);
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
     * @dev Burns exactly shares from owner and request sends assets of underlying tokens to receiver.
     */
    function requestRedeem(uint256 shares, address receiver) external override returns (uint256) {
        require(receiver != address(0), ZeroAddresss());

        _refreshTotalAssets();
        uint256 assets = _convertToAssets(shares, totalAssets);
        require(assets > 0, ZeroRedeemRequest());

        _requestWithdraw(msg.sender, receiver, assets, shares);

        return assets;
    }

    /**
     * @dev Check the redeemable requests in the request queue and execute the redemption.
     */
    function executeRedeem() external override returns (uint256 redeemedAmount) {
        RedeemRequest[] storage requestQueue = redeemRequestQueues[msg.sender];
        
        for (uint256 i = 0; i < requestQueue.length; i++) {
            if (block.timestamp >= requestQueue[i].requestTime + REDEEM_DELAY) {
                uint256 amount = requestQueue[i].amount;
                IERC20(asset).safeTransfer(msg.sender, amount);
                redeemedAmount += amount;

                // Remove redeemed request
                requestQueue[i] = requestQueue[requestQueue.length - 1];
                requestQueue[requestQueue.length - 1].amount = 0;
                requestQueue[requestQueue.length - 1].requestTime = 0;
                requestQueue.pop();
                
                emit RedeemExecuted(msg.sender, amount);
            }
        }
    }

    function _requestWithdraw(address sender, address receiver, uint256 assets, uint256 shares) internal {
        uint256 requestCount = redeemRequestQueues[receiver].length;
        require(requestCount < MAX_REDEEM_REQUESTS, MaxRedeemRequestsReached());

        _burn(sender, shares);
        redeemRequestQueues[msg.sender].push(RedeemRequest({
            amount: uint192(assets),
            requestTime: uint64(block.timestamp)
        }));

        emit RedeemRequested(sender, receiver, assets, shares, block.timestamp);
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

    function _previewTotalAssets() internal view returns (uint256) {
        (, uint256 memecoinYields) = IMemeverseLauncher(memeverseLauncher).previewTransactionFees(verseId);
        return totalAssets + memecoinYields;
    }

    function _refreshTotalAssets() internal {
        IMemeverseLauncher(memeverseLauncher).redeemAndDistributeFees(verseId);
    }
}
