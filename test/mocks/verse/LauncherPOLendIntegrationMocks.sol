// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BurnableMockERC20Base} from "../common/BurnableMockERC20Base.sol";
import {MintableToken} from "../polend/POLendMocks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {MemeverseLauncherUpgradeable} from "../../../src/verse/MemeverseLauncherUpgradeable.sol";
import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseProxyDeployer} from "../../../src/verse/interfaces/IMemeverseProxyDeployer.sol";
import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../../../src/polend/interfaces/IPOLSplitter.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

contract MockMemecoinForPOLendIntegration is BurnableMockERC20Base {
    address public memeverseLauncher;

    constructor(address launcher_) BurnableMockERC20Base("MEME", "MEME", 18, BurnMode.Accumulate) {
        memeverseLauncher = launcher_;
    }

    function mint(address to, uint256 amount) public override {
        _mint(to, amount);
    }

    function initialize(string calldata, string calldata, address, address) external {}
}

contract MockPolForPOLendIntegration is MockERC20 {
    address public memecoin;
    address public memeverseLauncher;
    uint256 public burnedAmount;

    constructor(address launcher_, address memecoin_) MockERC20("POL", "POL", 18) {
        memeverseLauncher = launcher_;
        memecoin = memecoin_;
    }

    function mint(address to, uint256 amount) public override {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public override {
        burnedAmount += amount;
        _burn(from, amount);
    }

    function initialize(string calldata, string calldata, address, address, address) external {}
}

contract MockHookForPOLendIntegration {
    address public launcher;
    address public poolInitializer;
    CallRecorder internal recorder;
    uint256 public firstProtectionCallIndex;

    struct Quote {
        uint256 fee0;
        uint256 fee1;
    }
    mapping(bytes32 => Quote) internal claimQuotes;

    constructor(address launcher_, CallRecorder recorder_) {
        launcher = launcher_;
        recorder = recorder_;
    }

    function setPublicSwapResumeTime(address, address, uint40) external {
        if (firstProtectionCallIndex == 0) firstProtectionCallIndex = recorder.next();
    }

    function setPoolInitializer(address poolInitializer_) external {
        poolInitializer = poolInitializer_;
    }

    function setClaimQuote(address tokenA, address tokenB, uint256 fee0, uint256 fee1) external {
        claimQuotes[_pairKey(tokenA, tokenB)] = Quote({fee0: fee0, fee1: fee1});
    }

    function claimableFees(PoolKey calldata key, address)
        external
        view
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        Quote memory quote = claimQuotes[_pairKey(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1))];
        return (quote.fee0, quote.fee1);
    }

    function claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams calldata params)
        external
        returns (uint256 fee0Amount, uint256 fee1Amount)
    {
        address token0 = Currency.unwrap(params.key.currency0);
        address token1 = Currency.unwrap(params.key.currency1);
        Quote memory quote = claimQuotes[_pairKey(token0, token1)];
        fee0Amount = quote.fee0;
        fee1Amount = quote.fee1;

        _payClaimFee(token0, params.recipient, fee0Amount);
        _payClaimFee(token1, params.recipient, fee1Amount);
    }

    function _payClaimFee(address token, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (MockERC20(token).balanceOf(address(this)) >= amount) {
            require(MockERC20(token).transfer(recipient, amount), "transfer failed");
            return;
        }
        MintableToken(token).mint(recipient, amount);
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA));
    }
}

contract MockRouterForPOLendIntegration {
    address internal immutable hookAddress;
    uint128 internal createLiquidityResult;
    uint128 internal addLiquidityResult;
    mapping(bytes32 => address) internal lpTokens;
    mapping(bytes32 => bool) internal initializedPools;
    mapping(bytes32 => PairSpend) internal createSpendByPair;
    uint256 public createPoolAndAddLiquidityCallCount;
    mapping(bytes32 => uint256) internal lastCreateAmount0ByPair;
    mapping(bytes32 => uint256) internal lastCreateAmount1ByPair;
    mapping(bytes32 => uint256) internal lastAddAmount0ByPair;
    mapping(bytes32 => uint256) internal lastAddAmount1ByPair;

    struct RemoveLiquidityResult {
        uint256 amount0Out;
        uint256 amount1Out;
    }

    struct PairSpend {
        uint256 amount0Used;
        uint256 amount1Used;
    }

    mapping(bytes32 => RemoveLiquidityResult) internal removeLiquidityResults;
    address internal observedLauncher;
    uint256 internal observedVerseId;
    bool internal rejectZeroRemoveLiquidity;
    uint256 public removeLiquidityCallCount;
    mapping(uint256 callIndex => uint256 polUAssetLpAmount) public observedPolUAssetLpByCall;
    mapping(uint256 callIndex => uint256 ptUAssetLpAmount) public observedPtUAssetLpByCall;
    mapping(uint256 callIndex => uint256 ptPolLpAmount) public observedPtPolLpByCall;

    constructor(address hookAddress_) {
        hookAddress = hookAddress_;
    }

    // Boundary note:
    // This router proves launcher-side fund routing, pool-call ordering, and slippage/deadline parameter correctness.
    // It validates that the launcher passes proper slippage and deadline parameters but does not prove real Uniswap v4 settlement semantics.
    function hook() external view returns (address) {
        return hookAddress;
    }

    function setCreateLiquidityResult(uint128 liquidity_) external {
        createLiquidityResult = liquidity_;
    }

    function setAddLiquidityResult(uint128 liquidity_) external {
        addLiquidityResult = liquidity_;
    }

    function setLpToken(address tokenA, address tokenB, address liquidityToken) external {
        lpTokens[_pairKey(tokenA, tokenB)] = liquidityToken;
    }

    function setCreateSpend(address tokenA, address tokenB, uint256 amountAUsed, uint256 amountBUsed) external {
        (uint256 amount0Used, uint256 amount1Used) =
            tokenA < tokenB ? (amountAUsed, amountBUsed) : (amountBUsed, amountAUsed);
        createSpendByPair[_pairKey(tokenA, tokenB)] = PairSpend({amount0Used: amount0Used, amount1Used: amount1Used});
    }

    function lpToken(address tokenA, address tokenB) external view returns (address liquidityToken) {
        return lpTokens[_pairKey(tokenA, tokenB)];
    }

    function lastCreateAmounts(address tokenA, address tokenB)
        external
        view
        returns (uint256 amountA, uint256 amountB)
    {
        bytes32 pairKey = _pairKey(tokenA, tokenB);
        if (tokenA < tokenB) {
            return (lastCreateAmount0ByPair[pairKey], lastCreateAmount1ByPair[pairKey]);
        }
        return (lastCreateAmount1ByPair[pairKey], lastCreateAmount0ByPair[pairKey]);
    }

    function createPoolAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint160 startPrice,
        address,
        uint256 deadline
    ) external returns (uint128 liquidity, PoolKey memory poolKey, uint256 amountAUsed, uint256 amountBUsed) {
        require(startPrice != 0, "startPrice cannot be zero");
        require(deadline >= block.timestamp, "expired deadline");
        bytes32 pairKey = _pairKey(tokenA, tokenB);
        PairSpend memory spend = createSpendByPair[pairKey];
        (amountAUsed, amountBUsed) =
            tokenA < tokenB ? (spend.amount0Used, spend.amount1Used) : (spend.amount1Used, spend.amount0Used);
        if (amountAUsed == 0 && amountBUsed == 0) {
            amountAUsed = amountADesired;
            amountBUsed = amountBDesired;
        }
        if (amountAUsed != 0) {
            require(MockERC20(tokenA).transferFrom(msg.sender, address(this), amountAUsed), "transfer failed");
        }
        if (amountBUsed != 0) {
            require(MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBUsed), "transfer failed");
        }
        initializedPools[pairKey] = true;
        createPoolAndAddLiquidityCallCount++;
        if (tokenA < tokenB) {
            lastCreateAmount0ByPair[pairKey] = amountAUsed;
            lastCreateAmount1ByPair[pairKey] = amountBUsed;
        } else {
            lastCreateAmount0ByPair[pairKey] = amountBUsed;
            lastCreateAmount1ByPair[pairKey] = amountAUsed;
        }
        liquidity = createLiquidityResult;
        poolKey = PoolKey({
            currency0: Currency.wrap(tokenA < tokenB ? tokenA : tokenB),
            currency1: Currency.wrap(tokenA < tokenB ? tokenB : tokenA),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(hookAddress)
        });
    }

    function addLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address,
        uint256
    ) external returns (uint128 liquidity) {
        require(amount0Desired >= amount0Min, "amount0 below min");
        require(amount1Desired >= amount1Min, "amount1 below min");
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        bytes32 pairKey = _pairKey(token0, token1);
        require(initializedPools[pairKey], "pool not initialized");
        if (token0 < token1) {
            lastAddAmount0ByPair[pairKey] = amount0Desired;
            lastAddAmount1ByPair[pairKey] = amount1Desired;
        } else {
            lastAddAmount0ByPair[pairKey] = amount1Desired;
            lastAddAmount1ByPair[pairKey] = amount0Desired;
        }
        if (amount0Desired != 0) {
            require(MockERC20(token0).transferFrom(msg.sender, address(this), amount0Desired), "transfer failed");
        }
        if (amount1Desired != 0) {
            require(MockERC20(token1).transferFrom(msg.sender, address(this), amount1Desired), "transfer failed");
        }
        return addLiquidityResult;
    }

    function setRemoveLiquidityResult(address tokenA, address tokenB, uint256 amountAOut, uint256 amountBOut) external {
        (uint256 amount0Out, uint256 amount1Out) = tokenA < tokenB ? (amountAOut, amountBOut) : (amountBOut, amountAOut);
        removeLiquidityResults[_pairKey(tokenA, tokenB)] =
            RemoveLiquidityResult({amount0Out: amount0Out, amount1Out: amount1Out});
    }

    function observeAuxiliaryLiquidity(address launcher_, uint256 verseId_) external {
        observedLauncher = launcher_;
        observedVerseId = verseId_;
    }

    function setRejectZeroRemoveLiquidity(bool reject) external {
        rejectZeroRemoveLiquidity = reject;
    }

    function removeLiquidity(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256
    ) external returns (BalanceDelta delta) {
        if (rejectZeroRemoveLiquidity) require(liquidity != 0, "zero liquidity");
        removeLiquidityCallCount++;
        if (observedLauncher != address(0)) {
            (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount) =
                MemeverseLauncherUpgradeable(observedLauncher).auxiliaryLiquidities(observedVerseId);
            observedPolUAssetLpByCall[removeLiquidityCallCount] = polUAssetLpAmount;
            observedPtUAssetLpByCall[removeLiquidityCallCount] = ptUAssetLpAmount;
            observedPtPolLpByCall[removeLiquidityCallCount] = ptPolLpAmount;
        }

        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        RemoveLiquidityResult memory result = removeLiquidityResults[_pairKey(token0, token1)];
        require(result.amount0Out >= amount0Min, "output0 below min");
        require(result.amount1Out >= amount1Min, "output1 below min");
        if (result.amount0Out != 0) MintableToken(token0).mint(to, result.amount0Out);
        if (result.amount1Out != 0) MintableToken(token1).mint(to, result.amount1Out);
        return toBalanceDelta(int128(uint128(result.amount0Out)), int128(uint128(result.amount1Out)));
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA));
    }
}

contract CallRecorder {
    uint256 public counter;

    function next() external returns (uint256 index) {
        counter++;
        return counter;
    }
}

contract MockProxyDeployerForPOLendIntegration is IMemeverseProxyDeployer {
    function predictYieldVaultAddress(uint256) external pure returns (address) {
        return address(0xD00D);
    }

    function computeGovernorAndIncentivizerAddress(uint256) external pure returns (address, address) {
        return (address(0xCAFE), address(0xBEEF));
    }

    function deployMemecoin(uint256) external pure returns (address) {
        revert PermissionDenied();
    }

    function deployPOL(uint256) external pure returns (address) {
        revert PermissionDenied();
    }

    function deployYieldVault(uint256) external pure returns (address) {
        revert PermissionDenied();
    }

    function deployGovernorAndIncentivizer(string calldata, address, address, address, address, uint256, uint256)
        external
        pure
        returns (address, address)
    {
        revert PermissionDenied();
    }

    function quorumNumerator() external pure returns (uint256) {
        return 0;
    }

    function setQuorumNumerator(uint256) external pure {}

    function minQuorumNumerator() external pure returns (uint256) {
        return 0;
    }

    function bootstrapPeriod() external pure returns (uint256) {
        return 0;
    }

    function setMinQuorumNumerator(uint256) external pure {}

    function setBootstrapPeriod(uint256) external pure {}

    function maxTreasurySpendRatio() external pure returns (uint256) {
        return 0;
    }

    function upgradeSupermajorityRatio() external pure returns (uint256) {
        return 0;
    }

    function setMaxTreasurySpendRatio(uint256) external pure {}

    function setUpgradeSupermajorityRatio(uint256) external pure {}
}

contract MockPOLendForPOLendIntegration {
    MockERC20 internal immutable uAsset;
    uint256 internal totalLeveragedDebt_;
    uint256 internal totalLeveragedInterest_;
    uint128 public mockSettlementDustReserve;
    uint128 public maxSettlementDustReserve = type(uint128).max;
    uint256 public lastFundSettlementDustReserveAmount;
    address public lastFundSettlementDustReserveUAsset;
    IPOLend.LendMarket internal market;
    uint256 internal lastRefundVerseId;
    uint256 public lastCallIndex;
    uint256 public preRedeemPTFeeCallCount;
    uint256 public lastPreRedeemPTFeeVerseId;
    uint256 public lastPreRedeemPTFeeAmount;
    address public lastPreRedeemPTFeeMintTo;
    IMemeverseLauncher.Stage public observedStageAtGlobalSettlement;
    CallRecorder internal recorder;

    constructor(MockERC20 uAsset_, CallRecorder recorder_) {
        uAsset = uAsset_;
        recorder = recorder_;
    }

    function setTotalLeveragedDebt(uint256 verseId, uint256 amount) external {
        verseId;
        totalLeveragedDebt_ = amount;
    }

    function setTotalLeveragedInterest(uint256 verseId, uint256 amount) external {
        verseId;
        totalLeveragedInterest_ = amount;
    }

    function setLendMarket(address pt, address yt) external {
        pt;
        market.yt = yt;
    }

    function registerLendMarket(uint256) external {}

    function settlementDustStates(address uAsset_) external view returns (uint128 reserve, uint128 maxReserve) {
        uAsset_;
        return (mockSettlementDustReserve, maxSettlementDustReserve);
    }

    function fundSettlementDustReserve(address uAsset_, uint256 amount) external {
        lastFundSettlementDustReserveUAsset = uAsset_;
        lastFundSettlementDustReserveAmount = amount;
        require(MockERC20(uAsset_).transferFrom(msg.sender, address(this), amount), "transfer failed");
        uint256 capacity = maxSettlementDustReserve - mockSettlementDustReserve;
        uint256 credited = amount < capacity ? amount : capacity;
        mockSettlementDustReserve += uint128(credited);
    }

    function getTotalLeveragedDebt(uint256) external view returns (uint256) {
        return totalLeveragedDebt_;
    }

    function getTotalLeveragedInterest(uint256) external view returns (uint256) {
        return totalLeveragedInterest_;
    }

    function getUserLeveragedDebt(uint256, address user) external pure returns (uint256) {
        if (user == address(0)) revert IPOLend.ZeroInput();
        return 0;
    }

    function getTotalDebtByUAsset(address uAsset_) external view returns (uint256) {
        if (uAsset_ == address(0)) revert IPOLend.ZeroInput();
        return uAsset_ == address(uAsset) ? totalLeveragedDebt_ : 0;
    }

    function getLeveragedDebtInfo(uint256) external view returns (IPOLend.LeveragedDebtInfo memory info) {
        info.totalLeveragedInterest = totalLeveragedInterest_;
        info.totalLeveragedDebt = totalLeveragedDebt_;
        info.interestRate = market.interestRate;
    }

    function getLendMarket(uint256) external view returns (IPOLend.LendMarket memory) {
        return market;
    }

    function finalizeLeveragedGenesis(uint256 verseId) external {
        verseId;
        if (totalLeveragedDebt_ != 0) uAsset.mint(msg.sender, totalLeveragedDebt_);
        market.state = IPOLend.MarketState.Locked;
    }

    function recordLeveragedYT(uint256 verseId, address yt_, uint256 totalLeveragedYT) external {
        verseId;
        market.yt = yt_;
        market.totalLeveragedYT = totalLeveragedYT;
    }

    function markRefundable(uint256 verseId) external {
        lastRefundVerseId = verseId;
        market.state = IPOLend.MarketState.Refund;
    }

    function executeGlobalSettlement(uint256 verseId) external {
        lastCallIndex = recorder.next();
        observedStageAtGlobalSettlement = IMemeverseLauncher(msg.sender).getStageByVerseId(verseId);
        market.state = IPOLend.MarketState.Settled;
    }

    function preRedeemPTFee(uint256 verseId, uint256 ptAmount, address mintTo)
        external
        returns (uint256 uAssetBacking)
    {
        preRedeemPTFeeCallCount++;
        lastPreRedeemPTFeeVerseId = verseId;
        lastPreRedeemPTFeeAmount = ptAmount;
        lastPreRedeemPTFeeMintTo = mintTo;
        uAsset.mint(mintTo, ptAmount);
        return ptAmount;
    }

    function burnPreRedeemedBacking(uint256, uint256) external {}

    function lastRefundedVerse() external view returns (uint256) {
        return lastRefundVerseId;
    }
}

contract MockPOLSplitterForPOLendIntegration is IPOLSplitter {
    address internal immutable pt;
    address internal immutable yt;
    address internal pol;
    address internal polendAddr;
    address internal launcherAddr;
    uint256 internal previewPTToUAssetResult;
    uint256 public lastCallIndex;
    uint256 public initializeVerseCallCount;
    uint256 public lastPTBackingVerseId;
    uint256 public lastPTBackingNumerator;
    uint256 public lastPTBackingDenominator;
    IMemeverseLauncher.Stage public observedStageAtSettle;
    CallRecorder internal recorder;

    constructor(address pt_, address yt_, CallRecorder recorder_) {
        pt = pt_;
        yt = yt_;
        recorder = recorder_;
    }

    function setPolForTest(address pol_) external {
        pol = pol_;
    }

    function setPolendForTest(address polend_) external {
        polendAddr = polend_;
    }

    function setLauncherForTest(address launcher_) external {
        launcherAddr = launcher_;
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, pol, address(0), address(0), 0, 0, 0, 0, 0, false);
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

    function getPTAndYTAndPOL(uint256) external view returns (address, address, address) {
        return (pt, yt, pol);
    }

    function getPTSettlementState(uint256) external view returns (address, bool) {
        return (pt, false);
    }

    function getPOLAndMemecoin(uint256) external view returns (address, address) {
        return (pol, address(0));
    }

    function preRedeemedStates(uint256) external pure returns (uint256 ptAmount, uint256 uAssetBacking) {
        return (0, 0);
    }

    function ptBackingRatios(uint256) external pure returns (uint256 numerator, uint256 denominator) {
        return (0, 0);
    }

    function initializeVerse(uint256, address, address, address, string calldata, string calldata)
        external
        returns (address, address)
    {
        initializeVerseCallCount++;
        return (pt, yt);
    }

    function split(uint256, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount) {
        MockERC20(pol).transferFrom(msg.sender, address(this), polAmount);
        MintableToken(pt).mint(msg.sender, polAmount);
        MintableToken(yt).mint(msg.sender, polAmount);
        return (polAmount, polAmount);
    }

    function merge(uint256, uint256) external pure returns (uint256) {
        revert PermissionDenied();
    }

    function settle(uint256 verseId) external returns (uint256, uint256) {
        lastCallIndex = recorder.next();
        observedStageAtSettle = IMemeverseLauncher(msg.sender).getStageByVerseId(verseId);
        return (0, 0);
    }

    function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external {
        lastPTBackingVerseId = verseId;
        lastPTBackingNumerator = numerator;
        lastPTBackingDenominator = denominator;
    }

    function setPreviewPTToUAssetResult(uint256 result) external {
        previewPTToUAssetResult = result;
    }

    function previewPTToUAsset(uint256, uint256 ptAmount) external view returns (uint256 uAssetAmount) {
        if (previewPTToUAssetResult != 0) return ptAmount;
        if (lastPTBackingNumerator == 0 || lastPTBackingDenominator == 0) return 0;
        return FullMath.mulDiv(ptAmount, lastPTBackingNumerator, lastPTBackingDenominator);
    }

    function preRedeemPTFee(uint256, uint256) external pure returns (uint256 uAssetBacking) {
        return 0;
    }

    function redeemPT(uint256, uint256, address) external pure returns (uint256) {
        revert PermissionDenied();
    }

    function redeemYT(uint256, uint256, address) external pure returns (uint256, uint256) {
        revert PermissionDenied();
    }

    function previewRedeemYTUAsset(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function setTokenImplementations(address, address) external pure {}

    function polend() external view returns (address) {
        return polendAddr;
    }

    function launcher() external view returns (address) {
        return launcherAddr;
    }
}
