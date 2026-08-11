// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BurnableMockERC20Base} from "../common/BurnableMockERC20Base.sol";

import {POLend} from "../../../src/polend/POLend.sol";

contract MintableToken is MockERC20 {
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}
}

contract BurnableMockERC20 is BurnableMockERC20Base {
    uint256 public repaidAmount;
    address public lastRepayAccount;
    bool public revertRepay;

    constructor(string memory name_, string memory symbol_)
        BurnableMockERC20Base(name_, symbol_, 18, BurnMode.Accumulate)
    {}

    function setRevertRepay(bool revertRepay_) external {
        revertRepay = revertRepay_;
    }

    function repay(address account, uint256 amount) public virtual {
        if (revertRepay) revert("repay failed");
        repaidAmount += amount;
        lastRepayAccount = account;
        _burn(account, amount);
    }
}

contract HookedBurnableMockERC20 is BurnableMockERC20 {
    enum HookMode {
        None,
        ReenterLeveragedGenesis,
        MintDebt,
        RepayDebt
    }

    HookMode internal hookMode;
    address internal hookPOLend;
    uint256 internal hookVerseId;
    uint256 internal expectedDebt;
    uint256 internal reentryInterestAmount;

    constructor(string memory name_, string memory symbol_) BurnableMockERC20(name_, symbol_) {}

    function enableLeveragedGenesisReentry(address polend_, uint256 verseId_, uint256 reentryInterestAmount_) external {
        mint(address(this), reentryInterestAmount_);
        allowance[address(this)][polend_] = reentryInterestAmount_;
        hookMode = HookMode.ReenterLeveragedGenesis;
        hookPOLend = polend_;
        hookVerseId = verseId_;
        reentryInterestAmount = reentryInterestAmount_;
    }

    function expectMintDebt(address polend_, uint256 expectedDebt_) external {
        hookMode = HookMode.MintDebt;
        hookPOLend = polend_;
        expectedDebt = expectedDebt_;
    }

    function expectRepayDebt(address polend_, uint256 expectedDebt_) external {
        hookMode = HookMode.RepayDebt;
        hookPOLend = polend_;
        expectedDebt = expectedDebt_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hookMode == HookMode.ReenterLeveragedGenesis) {
            hookMode = HookMode.None;
            POLend(hookPOLend).leveragedGenesis(hookVerseId, reentryInterestAmount);
        }
        return super.transferFrom(from, to, amount);
    }

    function mint(address to, uint256 value) public override {
        if (hookMode == HookMode.MintDebt) {
            require(POLend(hookPOLend).getTotalDebtByUAsset(address(this)) == expectedDebt, "hook debt");
            hookMode = HookMode.None;
        }
        super.mint(to, value);
    }

    function repay(address account, uint256 amount) public override {
        if (hookMode == HookMode.RepayDebt) {
            require(POLend(hookPOLend).getTotalDebtByUAsset(address(this)) == expectedDebt, "hook debt");
            hookMode = HookMode.None;
        }
        super.repay(account, amount);
    }
}

contract ReentrantClaimMockERC20 is BurnableMockERC20 {
    address internal reentryTarget;
    bytes internal reentryCallData;
    bytes4 internal expectedRevertSelector;
    bool public sawExpectedRevert;

    constructor(string memory name_, string memory symbol_) BurnableMockERC20(name_, symbol_) {}

    function armReentry(address target, bytes calldata callData, bytes4 expectedSelector) external {
        reentryTarget = target;
        reentryCallData = callData;
        expectedRevertSelector = expectedSelector;
        sawExpectedRevert = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool success) {
        success = super.transfer(to, amount);
        _reenter();
    }

    function _reenter() internal {
        address target = reentryTarget;
        if (target == address(0)) return;

        bytes memory callData = reentryCallData;
        bytes4 expectedSelector = expectedRevertSelector;
        reentryTarget = address(0);
        reentryCallData = "";
        expectedRevertSelector = bytes4(0);

        (bool success, bytes memory revertData) = target.call(callData);
        sawExpectedRevert = !success && revertData.length >= 4 && bytes4(revertData) == expectedSelector;
    }
}
