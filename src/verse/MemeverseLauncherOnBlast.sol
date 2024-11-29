// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import {MemeverseLauncher} from "./MemeverseLauncher.sol";
import {GasManagerable} from "../common/blast/GasManagerable.sol";

/**
 * @title Trapping into the memeverse on blast
 */
contract MemeverseLauncherOnBlast is MemeverseLauncher, GasManagerable {
    constructor(
        string memory _name,
        string memory _symbol,
        address _UPT,
        address _owner,
        address _signer,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter,
        address _gasManager
    )
        MemeverseLauncher(_name, _symbol, _UPT, _owner, _signer, _revenuePool, _outrunAMMFactory, _outrunAMMRouter)
        GasManagerable(_gasManager)
    {}
}
