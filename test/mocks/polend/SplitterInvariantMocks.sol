// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {IMemeverseLauncher} from "src/verse/interfaces/IMemeverseLauncher.sol";

/// @notice Stage-controllable launcher stand-in for the POLSplitter invariant suite.
/// @dev Exposes exactly the surface POLSplitterUpgradeable reads: `polend()` (resolved
///      at splitter initialize), `getStageByVerseId`, and the 6-param
///      `redeemMemecoinLiquidity` shape used by POLSplitterUpgradeable::_settlePOLCollateral.
///      The redemption path pulls POL from the caller (the splitter approves first)
///      and mints the configured recovery amounts to the caller, so settlement pools
///      are a controlled fuzz variable. Modeled on the inline MockLauncher in
///      test/polend/POLSplitter.t.sol; it proves wiring, not real router semantics.
contract StageAwareLauncherMock {
    struct RedemptionSeed {
        uint256 uAssetAmount;
        uint256 memecoinAmount;
    }

    MockERC20 internal immutable pol;
    MockERC20 internal immutable uAsset;
    MockERC20 internal immutable memecoin;
    address internal polendAddress;
    IMemeverseLauncher.Stage public stage = IMemeverseLauncher.Stage.Locked;
    mapping(uint256 verseId => RedemptionSeed) internal redemptionSeeds;

    constructor(MockERC20 pol_, MockERC20 uAsset_, MockERC20 memecoin_) {
        pol = pol_;
        uAsset = uAsset_;
        memecoin = memecoin_;
    }

    function setStage(IMemeverseLauncher.Stage stage_) external {
        stage = stage_;
    }

    function setPolend(address polend_) external {
        polendAddress = polend_;
    }

    function seedRedemption(uint256 verseId, uint256 uAssetAmount, uint256 memecoinAmount) external {
        redemptionSeeds[verseId] = RedemptionSeed({uAssetAmount: uAssetAmount, memecoinAmount: memecoinAmount});
    }

    function polend() external view returns (address) {
        return polendAddress;
    }

    function getStageByVerseId(uint256) external view returns (IMemeverseLauncher.Stage) {
        return stage;
    }

    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool, uint256, uint256, uint256)
        external
        returns (uint256 amountInLP)
    {
        require(pol.transferFrom(msg.sender, address(this), amountInPOL), "POL pull failed");
        RedemptionSeed memory seed = redemptionSeeds[verseId];
        if (seed.uAssetAmount != 0) uAsset.mint(msg.sender, seed.uAssetAmount);
        if (seed.memecoinAmount != 0) memecoin.mint(msg.sender, seed.memecoinAmount);
        return amountInPOL;
    }
}

/// @notice POLend stand-in for the splitter invariant suite.
/// @dev Records `burnPreRedeemedBacking` calls and pulls the repaid uAsset (the real
///      POLend pulls via the splitter's approval), so the suite can assert the repaid
///      amount matches the recorded backing exactly.
contract SimplePOLendMock {
    MockERC20 internal immutable uAsset;

    uint256 public burnPreRedeemedBackingCallCount;
    uint256 public lastBurnPreRedeemedBackingVerseId;
    uint256 public lastBurnPreRedeemedBackingAmount;
    uint256 public totalBurnedPreRedeemedBacking;

    constructor(MockERC20 uAsset_) {
        uAsset = uAsset_;
    }

    function burnPreRedeemedBacking(uint256 verseId, uint256 amount) external {
        require(uAsset.transferFrom(msg.sender, address(this), amount), "uAsset pull failed");
        burnPreRedeemedBackingCallCount++;
        lastBurnPreRedeemedBackingVerseId = verseId;
        lastBurnPreRedeemedBackingAmount = amount;
        totalBurnedPreRedeemedBacking += amount;
    }
}
