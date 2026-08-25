// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SplitterToken} from "./SplitterToken.sol";

/// @title PrincipalToken
/// @notice The verse's principal token (PT). Identical mechanics to YieldToken — the PT/YT
///         difference lives in how POLSplitterUpgradeable treats each token during redemption.
contract PrincipalToken is SplitterToken {}
