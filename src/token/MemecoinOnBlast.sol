// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Memecoin } from "./Memecoin.sol";
import { GasManagerable } from "../blast/GasManagerable.sol";

/**
 * @title MemecoinOnBlast contract
 */
contract MemecoinOnBlast is Memecoin, GasManagerable {
    constructor(
        string memory _name, 
        string memory _symbol,
        uint8 _decimals, 
        address _memeverseLauncher, 
        address _gasManager
    ) Memecoin(_name, _symbol, _decimals, _memeverseLauncher) GasManagerable(_gasManager) {
    }
}
