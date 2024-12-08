// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/ERC4626.sol)
pragma solidity ^0.8.20;

import { MemecoinVault } from "./MemecoinVault.sol";
import { BlastGovernorable } from "../common/blast/BlastGovernorable.sol";

/**
 * @dev Yields mainly comes from memeverse transaction fees
 */
contract MemecoinVaultOnBlast is MemecoinVault, BlastGovernorable {
    constructor(
        string memory _name, 
        string memory _symbol,
        address _asset,
        address _memeverse,
        address _blastGovernor,
        uint256 _verseId
    ) MemecoinVault(_name, _symbol, _asset, _memeverse, _verseId) BlastGovernorable(_blastGovernor) {
    }
}
