// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IPOLSplitter} from "../../../src/polend/interfaces/IPOLSplitter.sol";

interface IPOLSplitterReentryTarget {
    function onTokenTransferReenter(uint8 mode) external;
}

contract ReentrantMockERC20 is MockERC20 {
    uint8 internal reentryMode;
    address internal reentryTarget;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function armReentry(address target, uint8 mode) external {
        reentryTarget = target;
        reentryMode = mode;
    }

    function transfer(address to, uint256 amount) public override returns (bool success) {
        success = super.transfer(to, amount);
        _reenter();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool success) {
        success = super.transferFrom(from, to, amount);
        _reenter();
    }

    function _reenter() internal {
        uint8 mode = reentryMode;
        if (mode == 0) return;

        reentryMode = 0;
        IPOLSplitterReentryTarget(reentryTarget).onTokenTransferReenter(mode);
    }
}

contract POLSplitterReentryProbe is IPOLSplitterReentryTarget {
    uint8 internal constant MODE_SPLIT = 1;
    uint8 internal constant MODE_MERGE = 2;
    uint8 internal constant MODE_REDEEM_PT = 3;

    IPOLSplitter internal immutable splitter;
    ReentrantMockERC20 internal immutable pol;
    uint256 internal immutable verseId;

    constructor(IPOLSplitter splitter_, ReentrantMockERC20 pol_, uint256 verseId_) {
        splitter = splitter_;
        pol = pol_;
        verseId = verseId_;
    }

    function attackSplit(uint256 amount) external {
        pol.approve(address(splitter), type(uint256).max);
        pol.armReentry(address(this), MODE_SPLIT);
        splitter.split(verseId, amount);
    }

    function seedSplit(uint256 amount) external {
        pol.approve(address(splitter), type(uint256).max);
        splitter.split(verseId, amount);
    }

    function attackMerge(uint256 amount) external {
        pol.armReentry(address(this), MODE_MERGE);
        splitter.merge(verseId, amount);
    }

    function attackRedeemPT(uint256 amount) external {
        pol.armReentry(address(this), MODE_REDEEM_PT);
        splitter.redeemPT(verseId, amount, address(this));
    }

    function onTokenTransferReenter(uint8 mode) external {
        if (mode == MODE_SPLIT) {
            splitter.split(verseId, 1 ether);
        } else if (mode == MODE_MERGE) {
            splitter.merge(verseId, 1 ether);
        } else if (mode == MODE_REDEEM_PT) {
            splitter.redeemPT(verseId, 1 ether, address(this));
        }
    }
}
