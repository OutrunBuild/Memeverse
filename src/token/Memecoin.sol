// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IMemecoin } from "./interfaces/IMemecoin.sol";
import { OutrunOFTInit } from "../common/layerzero/oft/OutrunOFTInit.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IERC3156FlashLender, IERC3156FlashBorrower } from "../common/IERC3156FlashLender.sol";

/**
 * @title Omnichain Memecoin
 */
contract Memecoin is IMemecoin, OutrunOFTInit, IERC3156FlashLender {
    address public memeverseLauncher;

    /**
     * @notice Initialize the memecoin.
     * @param name_ - The name of the memecoin.
     * @param symbol_ - The symbol of the memecoin.
     * @param decimals_ - The decimals of the memecoin.
     * @param _memeverseLauncher - The address of the memeverse launcher.
     * @param _lzEndpoint - The address of the LayerZero endpoint.
     * @param _delegate - The address of the delegate.
     */
    function initialize(
        string memory name_, 
        string memory symbol_,
        uint8 decimals_, 
        address _memeverseLauncher, 
        address _lzEndpoint,
        address _delegate
    ) external override initializer {
        __OutrunOFT_init(name_, symbol_, decimals_, _lzEndpoint, _delegate);
        __OutrunOwnable_init(_delegate);

        memeverseLauncher = _memeverseLauncher;
    }

    /**
     * @notice Mint the memecoin.
     * @param account - The address of the account.
     * @param amount - The amount of the memecoin.
     */
    function mint(address account, uint256 amount) external override {
        require(msg.sender == memeverseLauncher, PermissionDenied());
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

    /**************************************************
     ********************* Flash Mint *****************
     **************************************************/
    bytes32 private constant RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public constant flashloanFeeRate = 25;   // 0.25 %.

    /**
     * @dev Returns the maximum amount of tokens available for loan.
     * @param token The address of the token that is requested.
     * @return The amount of token that can be loaned.
     */
    function maxFlashLoan(address token) public view virtual returns (uint256) {
        return token == address(this) ? type(uint256).max - totalSupply() : 0;
    }

    /**
     * @dev Returns the fee applied when doing flash loans.
     * @param token The token to be flash loaned.
     * @param value The amount of tokens to be loaned.
     * @return The fees applied to the corresponding flash loan.
     */
    function flashFee(address token, uint256 value) public view virtual returns (uint256) {
        require(token == address(this), ERC3156UnsupportedToken(token));

        return value * flashloanFeeRate / 10000;
    }

    /**
     * @dev Performs a flash loan. New tokens are minted and sent to the `receiver`, who is required to 
     * implement the {IERC3156FlashBorrower} interface. By the end of the flash loan, the receiver is 
     * expected to own value + fee tokens so they can be burned.
     * @param receiver The receiver of the flash loan. Should implement the {IERC3156FlashBorrower-onFlashLoan} interface.
     * @param token The token to be flash loaned. Only `address(this)` is supported.
     * @param value The amount of tokens to be loaned.
     * @param data An arbitrary datafield that is passed to the receiver.
     * @return `true` if the flash loan was successful.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 value,
        bytes calldata data
    ) public virtual returns (bool) {
        uint256 maxLoan = maxFlashLoan(token);
        require(value <= maxLoan, ERC3156ExceededMaxLoan(maxLoan));

        uint256 fee = flashFee(token, value);
        address receiverAddress = address(receiver);
        _mint(receiverAddress, value);
        require(
            receiver.onFlashLoan(msg.sender, token, value, fee, data) == RETURN_VALUE, 
            ERC3156InvalidReceiver(receiverAddress)
        );
        
        address yieldVault = IMemeverseLauncher(memeverseLauncher).getYieldVaultByMemecoin(address(this));
        if (fee == 0 || yieldVault == address(0)) {
            _burn(receiverAddress, value + fee);
        } else {
            _burn(receiverAddress, value);
            _transfer(receiverAddress, address(this), fee);
            IMemecoinYieldVault(yieldVault).accumulateYields(fee);
        }

        emit MemecoinFlashLoan(receiverAddress, value, fee, data);
        return true;
    }
}
