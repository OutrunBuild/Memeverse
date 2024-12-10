//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemeverseRegistrar } from "../../verse/interfaces/IMemeverseRegistrar.sol";

interface IMemeverseRegistrarAtLocal {
    function registerAtLocal(IMemeverseRegistrar.MemeverseParam calldata param) external returns (address memecoin, address liquidProof);
}