// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {SplitterToken} from "./SplitterToken.sol";

/// @title YieldToken
/// @notice The verse's yield token (YT). After settlement, YT claims the uAsset left after PT
///         coverage plus all recovered memecoin via `POLSplitter.redeemYT`. Identical mechanics to
///         PrincipalToken — the PT/YT difference lives in how POLSplitter treats each token.
contract YieldToken is SplitterToken {}
