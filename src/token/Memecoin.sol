// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemecoin } from "./interfaces/IMemecoin.sol";
import { OutrunOFTInit } from "../common/layerzero/oft/OutrunOFTInit.sol";

/**
 * @title Omnichain Memecoin
 */
contract Memecoin is IMemecoin, OutrunOFTInit {
    uint256 public unlockTime;
    address public memeverseLauncher;
    address public genesisLiquidityPool;

    modifier onlyMemeverseLauncher {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    /**
     * @notice Initialize the memecoin.
     * @param name_ - The name of the memecoin.
     * @param symbol_ - The symbol of the memecoin.
     * @param decimals_ - The decimals of the memecoin.
     * @param _unlockTime - The unlock time of liquidity.
     * @param _memeverseLauncher - The address of the memeverse launcher.
     * @param _lzEndpoint - The address of the LayerZero endpoint.
     * @param _delegate - The address of the delegate.
     */
    function initialize(
        string memory name_, 
        string memory symbol_,
        uint8 decimals_, 
        uint256 _unlockTime, 
        address _memeverseLauncher, 
        address _lzEndpoint,
        address _delegate
    ) external override initializer {
        __OutrunOFT_init(name_, symbol_, decimals_, _lzEndpoint, _delegate);
        __OutrunOwnable_init(_delegate);

        unlockTime = _unlockTime;
        memeverseLauncher = _memeverseLauncher;
    }

    /**
     * @notice Set GenesisLiquidityPool.
     * @param _genesisLiquidityPool - The address of the genesisLiquidityPool.
     */
    function setGenesisLiquidityPool(address _genesisLiquidityPool) external override onlyMemeverseLauncher {
        genesisLiquidityPool = _genesisLiquidityPool;
    }

    /**
     * @notice Mint the memecoin.
     * @param account - The address of the account.
     * @param amount - The amount of the memecoin.
     */
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        _mint(account, amount);
    }

    /**
     * @notice Burn the memecoin.
     * @param amount - The amount of the memecoin.
     */
    function burn(uint256 amount) external override {
        address msgSender = msg.sender;
        require(balanceOf(msgSender) >= amount, InsufficientBalance());
        _burn(msgSender, amount);
    }

    function _transfer(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }

        // The Liquidity Protection Period is an essential mechanism for safeguarding token liquidity and 
        // price stability. When the block time reaches the unlock time, some POL token holders may rush 
        // to redeem their liquidity and immediately sell the redeemed tokens. Without a Liquidity Protection 
        // Period, this behavior can lead to a gradual decrease in the value of subsequent redemptions, 
        // violating the principle of fairness and triggering panic redemptions and sales, which can destabilize 
        // the market. 
        // By implementing a 24-hour Liquidity Protection Period immediately after the block time reaches the 
        // liquidity unlock time, only token transfers from the liquidity pool are permitted during this interval. 
        // This means that only the purchase of tokens and the redemption of liquidity can be executed. This 
        // ensures consistency in the value of liquidity redeemed by burning POL tokens within this 24-hour 
        // window and provides users who redeem liquidity with a period to consider their next steps, preventing 
        // panic-induced stampedes and severe market fluctuations.
        require(
            block.timestamp < unlockTime || block.timestamp > unlockTime + 1 days || from == genesisLiquidityPool,
            LiquidityProtectionPeriod()
        );

        _update(from, to, value);
    }
}
