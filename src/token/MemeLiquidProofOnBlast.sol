// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { MemeLiquidProof } from "./MemeLiquidProof.sol";
import { GasManagerable } from "../blast/GasManagerable.sol";

/**
 * @title Memeverse Liquidity proof Token on Blast
 */
contract MemeLiquidProofOnBlast is MemeLiquidProof, GasManagerable {
    constructor(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals, 
        address _memecoin, 
        address _memeverseLauncher, 
        address _gasManager
    ) MemeLiquidProof(_name, _symbol, _decimals, _memecoin, _memeverseLauncher) GasManagerable(_gasManager) {
    }
}
