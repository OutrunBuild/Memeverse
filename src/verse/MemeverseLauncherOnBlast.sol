// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { MemeverseLauncher } from "./MemeverseLauncher.sol";
import { BlastGovernorable } from "../common/blast/BlastGovernorable.sol";

/**
 * @title Trapping into the memeverse on blast
 */
contract MemeverseLauncherOnBlast is MemeverseLauncher, BlastGovernorable {
    constructor(
        string memory _name,
        string memory _symbol,
        address _UPT,
        address _owner,
        address _blastGovernor,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter,
        uint256 _minTotalFunds,
        uint256 _fundBasedAmount
    ) MemeverseLauncher(
            _name,
            _symbol,
            _UPT,
            _owner,
            _revenuePool,
            _outrunAMMFactory,
            _outrunAMMRouter,
            _minTotalFunds,
            _fundBasedAmount
    ) BlastGovernorable(_blastGovernor){
    }
}
