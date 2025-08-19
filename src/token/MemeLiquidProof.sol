// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { OutrunNoncesInit } from "../common/OutrunNoncesInit.sol";
import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";
import { OutrunOFTInit } from "../common/layerzero/oft/OutrunOFTInit.sol";
import { OutrunERC20PermitInit } from "../common/OutrunERC20PermitInit.sol";
import { IMemeverseLauncher } from "../verse/interfaces/IMemeverseLauncher.sol";
import { OutrunERC20Init, OutrunERC20VotesInit } from "../common/governance/OutrunERC20VotesInit.sol";

/**
 * @title Omnichain Memecoin Proof Of Liquidity(POL) Token
 */
contract MemeLiquidProof is IMemeLiquidProof, OutrunERC20PermitInit, OutrunERC20VotesInit, OutrunOFTInit {
    address public pair;
    address public memecoin;
    address public memeverseLauncher;

    modifier onlyMemeverseLauncher {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    /**
     * @param _lzEndpoint The local LayerZero endpoint address.
     */
    constructor(address _lzEndpoint) OutrunOFTInit(_lzEndpoint) {}

    /**
     * @dev Initialize the memecoin liquidProof.
     * @param name_ - The name of the memecoin liquidProof.
     * @param symbol_ - The symbol of the memecoin liquidProof.
     * @param memecoin_ - The address of the memecoin.
     * @param memeverseLauncher_ - The address of the memeverse launcher.
     * @param delegate_ - The address of the OFT delegate.
     */
    function initialize(
        string memory name_, 
        string memory symbol_, 
        address memecoin_, 
        address memeverseLauncher_,
        address delegate_
    ) external override initializer {
        __OutrunOFT_init(name_, symbol_, delegate_);
        __OutrunOwnable_init(delegate_);

        memecoin = memecoin_;
        memeverseLauncher = memeverseLauncher_;
    }
    
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Set pair address after deploying liquidity
     */
    function setPair(address _pair) external override onlyMemeverseLauncher {
        require(_pair != address(0), ZeroInput());
        pair = _pair;
    }

    /**
     * @dev Mint the memeverse proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memeverse proof.
     * @notice Only the memeverse launcher can mint the memeverse proof.
     */
    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        require(amount != 0, ZeroInput());
        
        _mint(account, amount);
    }

    /**
     * @dev Burn the memecoin liquid proof.
     * @param account - The address of the account.
     * @param amount - The amount of the memecoin liquid proof.
     * @notice User must have approved msg.sender to spend UPT
     */
    function burn(address account, uint256 amount) external {
        require(amount != 0, ZeroInput());
        if(msg.sender != account) _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /**
     * @dev Burn the liquid proof by self.
     */
    function burn(uint256 amount) external {
        require(amount != 0, ZeroInput());
        _burn(msg.sender, amount);
    }

    /**
     * @dev If the DAO contract on governance chain cannot be deployed, burn the POL tokens in the DAO address.
     */
    function burnDAO() external {
        IMemeverseLauncher.Memeverse memory verse = IMemeverseLauncher(memeverseLauncher).getMemeverseByMemecoin(memecoin);
        if (block.chainid == verse.omnichainIds[0] && verse.currentStage == IMemeverseLauncher.Stage.Refund) {
            _burn(verse.governor, balanceOf(verse.governor));
        }
    }

    function nonces(address owner) public view override(OutrunERC20PermitInit, OutrunNoncesInit) returns (uint256) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal override(OutrunERC20Init, OutrunERC20VotesInit) {
        super._update(from, to, value);
    }
}
