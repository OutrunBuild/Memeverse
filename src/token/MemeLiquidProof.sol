// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";
import { OutrunERC20PermitInit } from "../common/OutrunERC20PermitInit.sol";
import { OutrunERC20Init, OutrunERC20Votes } from "../common/governance/OutrunERC20Votes.sol";
import { IERC3156FlashLender, IERC3156FlashBorrower } from "../common/IERC3156FlashLender.sol";

/**
 * @title Omnichain Memeverse Proof Of Liquidity Token
 */
contract MemeLiquidProof is IMemeLiquidProof, IERC3156FlashLender, OutrunERC20PermitInit, OutrunERC20Votes {
    address public memecoin;
    address public memeverseLauncher;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    /**
     * @notice Initialize the memeverse proof.
     * @param name_ - The name of the memeverse proof.
     * @param symbol_ - The symbol of the memeverse proof.
     * @param decimals_ - The decimals of the memeverse proof.
     * @param _memecoin - The address of the memecoin.
     * @param _memeverseLauncher - The address of the memeverse launcher.
     */
    function initialize(
        string memory name_, 
        string memory symbol_, 
        uint8 decimals_, 
        address _memecoin, 
        address _memeverseLauncher
    ) external override initializer {
        __OutrunERC20_init(name_, symbol_, decimals_);

        memecoin = _memecoin;
        memeverseLauncher = _memeverseLauncher;
    }
    
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Mint the memeverse proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memeverse proof.
     * @notice Only the memeverse launcher can mint the memeverse proof.
     */
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        _mint(account, amount);
    }

    /**
     * @notice Burn the memeverse proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memeverse proof.
     * @notice Only the memeverse launcher can burn the memeverse proof.
     */
    function burn(address account, uint256 amount) external onlyMemeverseLauncher {
        require(balanceOf(account) >= amount, InsufficientBalance());
        _burn(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(OutrunERC20Init, OutrunERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(OutrunERC20PermitInit, Nonces) returns (uint256) {
        return super.nonces(owner);
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
        return token == address(this) ? _maxSupply() - totalSupply() : 0;
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
        
        _burn(receiverAddress, value + fee);

        emit MemeLiquidProofFlashLoan(receiverAddress, value, fee, data);
        return true;
    }
}
