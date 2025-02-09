// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

import { IMemecoinYieldVault } from "./interfaces/IMemecoinYieldVault.sol";
import { OutrunSafeERC20 , IERC20} from "../libraries/OutrunSafeERC20.sol";
import { OutrunERC20PermitInit } from "../common/OutrunERC20PermitInit.sol";
import { OutrunERC20Init, OutrunERC20Votes } from "../common/governance/OutrunERC20Votes.sol";

/**
 * @dev Memecoin Yield Vault
 */
contract MemecoinYieldVault is IMemecoinYieldVault, OutrunERC20PermitInit, OutrunERC20Votes {
    using OutrunSafeERC20 for IERC20;

    uint256 public constant MAX_REDEEM_REQUESTS = 5;
    uint256 public constant REDEEM_DELAY = 1 days;  // Preventing flash attacks
    
    address public asset;
    uint256 public totalAssets;
    uint256 public verseId;

    mapping(address account => RedeemRequest[]) public redeemRequestQueues;

    function initialize(
        string memory _name, 
        string memory _symbol,
        address _asset,
        uint256 _verseId
    ) external override initializer {
        __OutrunERC20_init(_name, _symbol, 18);
        __OutrunERC20Permit_init(_name);

        asset = _asset;
        verseId = _verseId;
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, totalAssets);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, totalAssets);
    }

    /**
     * @dev Accumulate yields
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
        uint256 shares = _convertToShares(assets, totalAssets);
        _deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    /**
     * @dev Burns exactly shares from owner and request sends assets of underlying tokens to receiver.
     */
    function requestRedeem(uint256 shares, address receiver) external override returns (uint256) {
        require(receiver != address(0), ZeroAddress());

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
        
        for (uint256 i = requestQueue.length - 1 ; i >= 0; i--) {
            if (block.timestamp >= requestQueue[i].requestTime + REDEEM_DELAY) {
                uint256 amount = requestQueue[i].amount;
                IERC20(asset).safeTransfer(msg.sender, amount);
                redeemedAmount += amount;

                // Remove redeemed request
                if (i != requestQueue.length - 1) {
                    requestQueue[i] = requestQueue[requestQueue.length - 1];
                    requestQueue[requestQueue.length - 1].amount = 0;
                    requestQueue[requestQueue.length - 1].requestTime = 0;
                }
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
        uint256 _totalSupply = totalSupply();
        _totalSupply = _totalSupply == 0 ? 1 : _totalSupply;
        uint256 _totalAssets = latestTotalAssets;
        _totalAssets = _totalAssets == 0 ? 1 : _totalAssets;

        return assets * _totalSupply / _totalAssets;
    }

    function _convertToAssets(uint256 shares, uint256 latestTotalAssets) internal view returns (uint256) {
        uint256 _totalSupply = totalSupply();
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

    function _update(address from, address to, uint256 value) internal override(OutrunERC20Init, OutrunERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(OutrunERC20PermitInit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
