// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BurnableMockERC20Base} from "../common/BurnableMockERC20Base.sol";

import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";

/// @notice POLendUpgradeable stand-in for the preorder-launcher integration test.
/// @dev Returns deterministic zero state for leveraged accounting; mirrors only the
///      surface that MemeverseLauncherUpgradeable reads during preorder settlement.
contract MockPOLendForPreorderIntegration {
    address internal pt_;
    address internal yt_;

    function setLendMarket(address pt, address yt) external {
        pt_ = pt;
        yt_ = yt;
    }

    function registerLendMarket(uint256) external {}

    function settlementDustStates(address) external pure virtual returns (uint128 reserve, uint128 maxReserve) {
        return (0, type(uint128).max);
    }

    function fundSettlementDustReserve(address, uint256) external virtual {}

    function getTotalLeveragedDebt(uint256) external pure returns (uint256) {
        return 0;
    }

    function getTotalLeveragedInterest(uint256) external pure returns (uint256) {
        return 0;
    }

    function getLendMarket(uint256) external view returns (IPOLend.LendMarket memory market) {
        market.yt = yt_;
    }

    function finalizeLeveragedGenesis(uint256) external {}

    function recordLeveragedYT(uint256, address, uint256) external {}

    function markRefundable(uint256) external {}

    function executeGlobalSettlement(uint256) external {}
}

/// @notice POL splitter stand-in for the preorder-launcher integration test.
/// @dev Splits POL 1:1 into PT/YT by minting both legs on demand. Backing ratio and
///      preview overrides are test knobs used to exercise settlement preview math.
contract MockPOLSplitterForPreorderIntegration {
    address internal immutable pt;
    address internal immutable yt;
    mapping(uint256 verseId => uint256 numerator) internal ptBackingNumerators;
    mapping(uint256 verseId => uint256 denominator) internal ptBackingDenominators;
    mapping(uint256 verseId => uint256 previewPTToUAssetResults) internal previewPTToUAssetResults;
    mapping(uint256 verseId => bool enabled) internal previewPTToUAssetOverrideEnabled;

    constructor(address pt_, address yt_) {
        pt = pt_;
        yt = yt_;
    }

    function initializeVerse(uint256, address, address, address, string calldata, string calldata)
        external
        view
        returns (address, address)
    {
        return (pt, yt);
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, address(0), address(0), address(0), 0, 0, 0, 0, 0, false);
    }

    function getPT(uint256) external view returns (address) {
        return pt;
    }

    function getYT(uint256) external view returns (address) {
        return yt;
    }

    function getMemecoin(uint256) external pure returns (address) {
        return address(0);
    }

    function getPTAndYT(uint256) external view returns (address, address) {
        return (pt, yt);
    }

    function getPTSettlementState(uint256) external view returns (address, bool) {
        return (pt, false);
    }

    function split(uint256, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount) {
        MockERC20(pt).mint(msg.sender, polAmount);
        MockERC20(yt).mint(msg.sender, polAmount);
        return (polAmount, polAmount);
    }

    function settle(uint256) external pure returns (uint256 settlementUAsset, uint256 settlementMemecoin) {
        return (0, 0);
    }

    function merge(uint256, uint256) external pure returns (uint256) {
        revert("unused");
    }

    function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external {
        ptBackingNumerators[verseId] = numerator;
        ptBackingDenominators[verseId] = denominator;
    }

    function previewPTToUAsset(uint256 verseId, uint256 ptAmount) external view returns (uint256 uAssetAmount) {
        if (previewPTToUAssetOverrideEnabled[verseId]) return previewPTToUAssetResults[verseId];
        uint256 denominator = ptBackingDenominators[verseId];
        if (denominator == 0) return ptAmount;
        return ptAmount * ptBackingNumerators[verseId] / denominator;
    }

    function setPreviewPTToUAssetResult(uint256 verseId, uint256 result) external {
        previewPTToUAssetResults[verseId] = result;
        previewPTToUAssetOverrideEnabled[verseId] = true;
    }

    function redeemPT(uint256, uint256, address) external pure returns (uint256) {
        revert("unused");
    }

    function redeemYT(uint256, uint256, address) external pure returns (uint256, uint256) {
        revert("unused");
    }

    function previewRedeemYTUAsset(uint256, uint256) external pure returns (uint256 uAssetAmount) {
        return 0;
    }
}

/// @notice Memecoin stand-in for the launcher integration tests.
/// @dev Mint is launcher-gated so only the launcher can issue the post-settlement supply.
contract MockIntegrationMemecoin is BurnableMockERC20Base {
    address public memeverseLauncher;
    mapping(uint32 eid => bytes32 peer) public peers;

    constructor() BurnableMockERC20Base("Mock Meme", "MMEME", 18, BurnMode.ZeroGuard) {}

    /// @notice Test helper for initialize.
    /// @param _name See implementation.
    /// @param _symbol See implementation.
    /// @param launcher_ See implementation.
    /// @param _unusedPeer See implementation.
    function initialize(string memory _name, string memory _symbol, address launcher_, address _unusedPeer) external {
        _name;
        _symbol;
        _unusedPeer;
        memeverseLauncher = launcher_;
    }

    /// @notice Test helper for setPeer.
    /// @param eid See implementation.
    /// @param peer See implementation.
    function setPeer(uint32 eid, bytes32 peer) external {
        peers[eid] = peer;
    }

    /// @notice Test helper for mint.
    /// @param account See implementation.
    /// @param amount See implementation.
    function mint(address account, uint256 amount) public override {
        require(msg.sender == memeverseLauncher, "not launcher");
        require(amount != 0, "zero");
        super.mint(account, amount);
    }
}

/// @notice POL token stand-in for the launcher integration tests.
/// @dev Mint and burn are launcher-gated to mirror the real MemeverseLiquidProof permissioning.
contract MockIntegrationLiquidProof is MockERC20 {
    address public memeverseLauncher;
    address public memecoin;
    mapping(uint32 eid => bytes32 peer) public peers;

    constructor() MockERC20("Mock POL", "MPOL", 18) {}

    /// @notice Test helper for initialize.
    /// @param _name See implementation.
    /// @param _symbol See implementation.
    /// @param memecoin_ See implementation.
    /// @param launcher_ See implementation.
    /// @param _unusedPeer See implementation.
    function initialize(
        string memory _name,
        string memory _symbol,
        address memecoin_,
        address launcher_,
        address _unusedPeer
    ) external {
        _name;
        _symbol;
        _unusedPeer;
        memecoin = memecoin_;
        memeverseLauncher = launcher_;
    }

    /// @notice Test helper for setPeer.
    /// @param eid See implementation.
    /// @param peer See implementation.
    function setPeer(uint32 eid, bytes32 peer) external {
        peers[eid] = peer;
    }


    /// @notice Test helper for mint.
    /// @param account See implementation.
    /// @param amount See implementation.
    function mint(address account, uint256 amount) public override {
        require(msg.sender == memeverseLauncher, "not launcher");
        require(amount != 0, "zero");
        super.mint(account, amount);
    }

    /// @notice Test helper for burn.
    /// @param account See implementation.
    /// @param amount See implementation.
    function burn(address account, uint256 amount) public override {
        require(amount != 0, "zero");
        require(msg.sender == account || msg.sender == memeverseLauncher, "not allowed");
        super.burn(account, amount);
    }
}

/// @notice Proxy deployer stand-in for the preorder-launcher integration test.
/// @dev Deploys fresh mock memecoin/POL per call and returns precomputed addresses for
///      governor/incentivizer so the launcher's CREATE2 address checks pass without real
///      deployer bytecode.
contract MockLauncherIntegrationProxyDeployer {
    address internal immutable predictedYieldVault;
    address internal immutable predictedGovernor;
    address internal immutable predictedIncentivizer;

    constructor(address _predictedYieldVault, address _predictedGovernor, address _predictedIncentivizer) {
        predictedYieldVault = _predictedYieldVault;
        predictedGovernor = _predictedGovernor;
        predictedIncentivizer = _predictedIncentivizer;
    }

    /// @notice Test helper for deployMemecoin.
    /// @param _verseId See implementation.
    /// @return memecoin See implementation.
    function deployMemecoin(uint256 _verseId) external returns (address memecoin) {
        _verseId;
        memecoin = address(new MockIntegrationMemecoin());
    }

    /// @notice Test helper for deployPOL.
    /// @param _verseId See implementation.
    /// @return pol See implementation.
    function deployPOL(uint256 _verseId) external returns (address pol) {
        _verseId;
        pol = address(new MockIntegrationLiquidProof());
    }

    /// @notice Test helper for predictYieldVaultAddress.
    /// @param _verseId See implementation.
    /// @return yieldVault See implementation.
    function predictYieldVaultAddress(uint256 _verseId) external view returns (address yieldVault) {
        _verseId;
        return predictedYieldVault;
    }

    /// @notice Test helper for computeGovernorAndIncentivizerAddress.
    /// @param _verseId See implementation.
    /// @return governor See implementation.
    /// @return incentivizer See implementation.
    function computeGovernorAndIncentivizerAddress(uint256 _verseId)
        external
        view
        returns (address governor, address incentivizer)
    {
        _verseId;
        return (predictedGovernor, predictedIncentivizer);
    }
}

/// @notice LZ endpoint registry stand-in for the launcher integration tests.
/// @dev Maps a human chain id to its LayerZero endpoint id so the launcher can resolve
///      cross-chain governance destinations without a real LZ endpoint.
contract MockLauncherIntegrationLzEndpointRegistry {
    mapping(uint32 chainId => uint32 endpointId) public lzEndpointIdOfChain;

    /// @notice Test helper for setEndpoint.
    /// @param chainId See implementation.
    /// @param endpointId See implementation.
    function setEndpoint(uint32 chainId, uint32 endpointId) external {
        lzEndpointIdOfChain[chainId] = endpointId;
    }
}
