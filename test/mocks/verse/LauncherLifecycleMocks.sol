// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {IMemeverseOFTEnum} from "../../../src/common/types/IMemeverseOFTEnum.sol";
import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../../../src/polend/interfaces/IPOLSplitter.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

interface IRefundCallbackObserver {
    /// @notice Handles the token refund callback emitted by the test refund token.
    /// @dev Used to assert CEI ordering during refund-sensitive launcher flows.
    function onRefundCallback() external;
}

interface IClaimNormalFeesReentryObserver {
    function onRedeemPTCallback() external;
}

contract MockPreorderSettlementHookForLauncherTest {
    using PoolIdLibrary for PoolKey;

    struct LaunchSwapResult {
        uint256 amountIn;
        uint256 amountOut;
    }

    struct FeeQuote {
        uint256 fee0;
        uint256 fee1;
    }

    address internal boundLauncher;
    mapping(bytes32 => LaunchSwapResult) internal launchSwapResults;
    mapping(bytes32 => uint40) internal publicSwapResumeTimes;
    mapping(bytes32 => FeeQuote) internal previewQuotes;
    mapping(bytes32 => FeeQuote) internal claimQuotes;
    uint160 internal expectedZeroForOneSqrtPriceLimitX96;
    uint160 internal expectedOneForZeroSqrtPriceLimitX96;
    address internal initializer;
    bool internal enforceExpectedSqrtPriceLimitX96;
    bool internal revertPreorderSettlement;
    string internal preorderSettlementRevertReason;
    bool internal lastPreorderSettlementZeroForOne;
    uint160 internal lastPreorderSettlementSqrtPriceLimitX96;
    uint256 internal preorderSettlementCallCount;

    constructor(address boundLauncher_, address initializer_) {
        boundLauncher = boundLauncher_;
        initializer = initializer_;
    }

    function launcher() external view returns (address launcher_) {
        return boundLauncher;
    }

    function poolInitializer() external view returns (address initializer_) {
        return initializer;
    }

    function setPoolInitializer(address initializer_) external {
        initializer = initializer_;
    }

    function setLaunchSwapResult(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        launchSwapResults[keccak256(abi.encode(_pairKey(tokenIn, tokenOut), tokenIn, tokenOut))] =
            LaunchSwapResult({amountIn: amountIn, amountOut: amountOut});
    }

    function setPreviewQuote(address tokenA, address tokenB, address owner, uint256 fee0, uint256 fee1) external {
        previewQuotes[keccak256(abi.encode(_pairKey(tokenA, tokenB), owner))] = FeeQuote({fee0: fee0, fee1: fee1});
    }

    function setClaimQuote(address tokenA, address tokenB, address owner, uint256 fee0, uint256 fee1) external {
        claimQuotes[keccak256(abi.encode(_pairKey(tokenA, tokenB), owner))] = FeeQuote({fee0: fee0, fee1: fee1});
    }

    function setPublicSwapResumeTime(bytes32 poolId, uint40 resumeTime) external {
        require(msg.sender == boundLauncher, "unauthorized launcher");
        publicSwapResumeTimes[poolId] = resumeTime;
    }

    function setPublicSwapResumeTime(address tokenA, address tokenB, uint40 resumeTime) external {
        require(msg.sender == boundLauncher, "unauthorized launcher");
        publicSwapResumeTimes[_poolId(tokenA, tokenB)] = resumeTime;
    }

    function publicSwapResumeTime(bytes32 poolId) external view returns (uint40 resumeTime) {
        return publicSwapResumeTimes[poolId];
    }

    function claimableFees(PoolKey calldata key, address owner) external view returns (uint256 fee0, uint256 fee1) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        FeeQuote memory quote = previewQuotes[keccak256(abi.encode(_pairKey(token0, token1), owner))];
        return (quote.fee0, quote.fee1);
    }

    function claimFeesCore(IMemeverseUniswapHook.ClaimFeesCoreParams calldata params)
        external
        returns (uint256 fee0, uint256 fee1)
    {
        address token0 = Currency.unwrap(params.key.currency0);
        address token1 = Currency.unwrap(params.key.currency1);
        FeeQuote memory quote = claimQuotes[keccak256(abi.encode(_pairKey(token0, token1), msg.sender))];

        fee0 = quote.fee0;
        fee1 = quote.fee1;

        if (fee0 != 0) MockERC20(token0).mint(params.recipient, fee0);
        if (fee1 != 0) MockERC20(token1).mint(params.recipient, fee1);
    }

    function setExpectedLaunchSqrtPriceLimit(bool zeroForOne, uint160 expectedSqrtPriceLimitX96) external {
        if (zeroForOne) {
            expectedZeroForOneSqrtPriceLimitX96 = expectedSqrtPriceLimitX96;
        } else {
            expectedOneForZeroSqrtPriceLimitX96 = expectedSqrtPriceLimitX96;
        }
        enforceExpectedSqrtPriceLimitX96 = true;
    }

    function setPreorderSettlementRevert(string calldata reason) external {
        revertPreorderSettlement = true;
        preorderSettlementRevertReason = reason;
    }

    function lastSettlementZeroForOne() external view returns (bool zeroForOne) {
        return lastPreorderSettlementZeroForOne;
    }

    function lastSettlementSqrtPriceLimitX96() external view returns (uint160 sqrtPriceLimitX96) {
        return lastPreorderSettlementSqrtPriceLimitX96;
    }

    function settlementCallCount() external view returns (uint256 count) {
        return preorderSettlementCallCount;
    }

    function executePreorderSettlement(IMemeverseUniswapHook.PreorderSettlementParams calldata params)
        external
        returns (BalanceDelta delta)
    {
        require(msg.sender == boundLauncher, "unauthorized launcher");
        if (revertPreorderSettlement) revert(preorderSettlementRevertReason);
        lastPreorderSettlementZeroForOne = params.params.zeroForOne;
        lastPreorderSettlementSqrtPriceLimitX96 = params.params.sqrtPriceLimitX96;
        preorderSettlementCallCount++;
        if (enforceExpectedSqrtPriceLimitX96) {
            uint160 expectedSqrtPriceLimitX96 =
                params.params.zeroForOne ? expectedZeroForOneSqrtPriceLimitX96 : expectedOneForZeroSqrtPriceLimitX96;
            require(params.params.sqrtPriceLimitX96 == expectedSqrtPriceLimitX96, "unexpected sqrtPriceLimitX96");
        }
        address tokenIn =
            params.params.zeroForOne ? Currency.unwrap(params.key.currency0) : Currency.unwrap(params.key.currency1);
        address tokenOut =
            params.params.zeroForOne ? Currency.unwrap(params.key.currency1) : Currency.unwrap(params.key.currency0);
        LaunchSwapResult memory result =
            launchSwapResults[keccak256(abi.encode(_pairKey(tokenIn, tokenOut), tokenIn, tokenOut))];
        if (result.amountOut != 0) {
            MockERC20(tokenOut).mint(params.recipient, result.amountOut);
        }
        require(uint256(-params.params.amountSpecified) == result.amountIn, "unexpected amountIn");

        if (params.params.zeroForOne) {
            return toBalanceDelta(-int128(int256(result.amountIn)), int128(int256(result.amountOut)));
        }
        return toBalanceDelta(int128(int256(result.amountOut)), -int128(int256(result.amountIn)));
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1));
    }

    function _poolId(address tokenA, address tokenB) internal view returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return PoolId.unwrap(
            PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 200,
                hooks: IHooks(address(this))
            }).toId()
        );
    }
}

// `MemeverseLauncherSwapIntegration.t.sol` currently covers the real launch-settlement path and exposes the
// current real-stack `mintPOLToken` / fee-claim blockers.
// This mock router remains for broader lifecycle-focused tests that isolate launcher control flow from router internals.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    // Boundary note:
    // removeLiquidity fixtures below only prove launcher-side forwarding for lifecycle tests.
    // They do not prove real router/hook settlement semantics.

    struct Quote {
        uint256 fee0;
        uint256 fee1;
    }

    struct AddLiquidityResult {
        uint128 liquidity;
        uint256 amount0Used;
        uint256 amount1Used;
    }

    struct RemoveLiquidityResult {
        uint256 amount0Out;
        uint256 amount1Out;
    }

    mapping(bytes32 => Quote) internal previewQuotes;
    mapping(bytes32 => Quote) internal claimQuotes;
    mapping(bytes32 => address) internal lpTokens;
    mapping(bytes32 => AddLiquidityResult) internal addLiquidityResults;
    mapping(bytes32 => RemoveLiquidityResult) internal removeLiquidityResults;
    mapping(bytes32 => uint128) internal lastRemoveLiquidity;
    mapping(bytes32 => uint256) internal paddedLiquidityQuoteAmountA;
    mapping(bytes32 => uint256) internal paddedLiquidityQuoteAmountB;
    mapping(bytes32 => uint256) internal exactLiquidityQuoteAmountA;
    mapping(bytes32 => uint256) internal exactLiquidityQuoteAmountB;
    MockPreorderSettlementHookForLauncherTest internal immutable settlementHook;
    uint256 internal addLiquidityCallCount_;
    uint256 internal addLiquidityDetailedCallCount_;
    uint256 internal createPoolAndAddLiquidityCallCount_;
    address internal reenterLauncher;
    uint256 internal reenterVerseId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bool internal revertNextRemoveLiquidity;

    constructor(address launcher_) {
        settlementHook = new MockPreorderSettlementHookForLauncherTest(launcher_, address(this));
    }

    /// @notice Exposes the mock hook used by the router.
    /// @dev Returns the helper hook that supports explicit preorder settlement execution.
    /// @return hookAddress Mock hook address.
    function hook() external view returns (address) {
        return address(settlementHook);
    }

    function addLiquidityCallCount() external view returns (uint256 count) {
        return addLiquidityCallCount_;
    }

    function addLiquidityDetailedCallCount() external view returns (uint256 count) {
        return addLiquidityDetailedCallCount_;
    }

    function createPoolAndAddLiquidityCallCount() external view returns (uint256 count) {
        return createPoolAndAddLiquidityCallCount_;
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1));
    }

    function _normalizePairAmounts(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (tokenA < tokenB) return (amountA, amountB);
        return (amountB, amountA);
    }

    function _liquidityKey(address tokenA, address tokenB, uint128 liquidityDesired) internal pure returns (bytes32) {
        return keccak256(abi.encode(_pairKey(tokenA, tokenB), liquidityDesired));
    }

    /// @notice Sets both preview and claim fee quotes for a token pair and owner.
    /// @dev Used by tests to keep preview and redemption expectations aligned.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param owner Owner whose quote should be returned.
    /// @param fee0 Mock fee amount for token0.
    /// @param fee1 Mock fee amount for token1.
    function setQuote(address tokenA, address tokenB, address owner, uint256 fee0, uint256 fee1) external {
        setPreviewQuote(tokenA, tokenB, owner, fee0, fee1);
        setClaimQuote(tokenA, tokenB, owner, fee0, fee1);
    }

    /// @notice Sets the preview fee quote for a token pair and owner.
    /// @dev Stores fees using normalized token ordering.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param owner Owner whose preview quote should be returned.
    /// @param fee0 Mock fee amount for token0.
    /// @param fee1 Mock fee amount for token1.
    function setPreviewQuote(address tokenA, address tokenB, address owner, uint256 fee0, uint256 fee1) public {
        previewQuotes[keccak256(abi.encode(_pairKey(tokenA, tokenB), owner))] = Quote({fee0: fee0, fee1: fee1});
        settlementHook.setPreviewQuote(tokenA, tokenB, owner, fee0, fee1);
    }

    /// @notice Sets the claim fee quote for a token pair and owner.
    /// @dev Stores fees using normalized token ordering.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param owner Owner whose claim quote should be returned.
    /// @param fee0 Mock fee amount for token0.
    /// @param fee1 Mock fee amount for token1.
    function setClaimQuote(address tokenA, address tokenB, address owner, uint256 fee0, uint256 fee1) public {
        claimQuotes[keccak256(abi.encode(_pairKey(tokenA, tokenB), owner))] = Quote({fee0: fee0, fee1: fee1});
        settlementHook.setClaimQuote(tokenA, tokenB, owner, fee0, fee1);
    }

    /// @notice Sets the LP token returned for a token pair.
    /// @dev Stores the LP token using normalized token ordering.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param liquidityToken Mock LP token address for the pair.
    function setLpToken(address tokenA, address tokenB, address liquidityToken) external {
        lpTokens[_pairKey(tokenA, tokenB)] = liquidityToken;
    }

    /// @notice Sets the mocked add-liquidity execution result for a pair.
    /// @dev Stores the actual token usage and LP liquidity that `addLiquidity(...)` should produce.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param liquidity Mock LP liquidity to mint.
    /// @param amountAUsed Mock amount of `tokenA` consumed.
    /// @param amountBUsed Mock amount of `tokenB` consumed.
    function setAddLiquidityResult(
        address tokenA,
        address tokenB,
        uint128 liquidity,
        uint256 amountAUsed,
        uint256 amountBUsed
    ) external {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 amount0Used, uint256 amount1Used) = _normalizePairAmounts(tokenA, tokenB, amountAUsed, amountBUsed);
        addLiquidityResults[_pairKey(token0, token1)] =
            AddLiquidityResult({liquidity: liquidity, amount0Used: amount0Used, amount1Used: amount1Used});
    }

    /// @notice Sets the mocked exact-liquidity quote for a pair.
    /// @dev Stores the required input amounts using the caller-facing token order.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param liquidityDesired Target liquidity to quote.
    /// @param amountARequired Mock required amount of `tokenA`.
    /// @param amountBRequired Mock required amount of `tokenB`.
    function setQuoteAmountsForLiquidity(
        address tokenA,
        address tokenB,
        uint128 liquidityDesired,
        uint256 amountARequired,
        uint256 amountBRequired
    ) external {
        bytes32 key = _liquidityKey(tokenA, tokenB, liquidityDesired);
        paddedLiquidityQuoteAmountA[key] = amountARequired;
        paddedLiquidityQuoteAmountB[key] = amountBRequired;
    }

    /// @notice Sets the mocked exact-liquidity quote for a pair.
    /// @dev Stores the exact-path input amounts separately from the padded quote fixture.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param liquidityDesired Target liquidity to quote.
    /// @param amountARequired Mock exact-path amount of `tokenA`.
    /// @param amountBRequired Mock exact-path amount of `tokenB`.
    function setExactQuoteAmountsForLiquidity(
        address tokenA,
        address tokenB,
        uint128 liquidityDesired,
        uint256 amountARequired,
        uint256 amountBRequired
    ) external {
        bytes32 key = _liquidityKey(tokenA, tokenB, liquidityDesired);
        exactLiquidityQuoteAmountA[key] = amountARequired;
        exactLiquidityQuoteAmountB[key] = amountBRequired;
    }

    function setRemoveLiquidityResult(address tokenA, address tokenB, uint256 amountAOut, uint256 amountBOut) external {
        (uint256 amount0Out, uint256 amount1Out) = _normalizePairAmounts(tokenA, tokenB, amountAOut, amountBOut);
        removeLiquidityResults[_pairKey(tokenA, tokenB)] =
            RemoveLiquidityResult({amount0Out: amount0Out, amount1Out: amount1Out});
    }

    function setRedeemReentry(address launcher, uint256 verseId) external {
        reenterLauncher = launcher;
        reenterVerseId = verseId;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function setRevertNextRemoveLiquidity() external {
        revertNextRemoveLiquidity = true;
    }

    function clearRevertNextRemoveLiquidity() external {
        revertNextRemoveLiquidity = false;
    }

    function redeemAuxiliary(address launcher, uint256 verseId)
        external
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        return IMemeverseLauncher(launcher).redeemAuxiliaryLiquidity(verseId);
    }

    function lastRemoveLiquidityAmount(address tokenA, address tokenB) external view returns (uint128 liquidity) {
        return lastRemoveLiquidity[_pairKey(tokenA, tokenB)];
    }

    /// @notice Sets the mocked launch preorder swap result for a pair.
    /// @dev Stores the input budget consumed and the memecoin amount returned to the recipient.
    /// @param tokenIn Input token used by the preorder settlement swap.
    /// @param tokenOut Output token returned by the preorder settlement swap.
    /// @param amountIn Mock amount of `tokenIn` consumed.
    /// @param amountOut Mock amount of `tokenOut` returned.
    function setLaunchSwapResult(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        settlementHook.setLaunchSwapResult(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Returns the mocked preview fees for a token pair and owner.
    /// @dev Mimics router-side pair normalization.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param owner Owner whose preview quote is requested.
    /// @return fee0 Mock fee amount for token0.
    /// @return fee1 Mock fee amount for token1.
    function previewClaimableFees(address tokenA, address tokenB, address owner)
        external
        view
        returns (uint256 fee0, uint256 fee1)
    {
        Quote memory quote = previewQuotes[keccak256(abi.encode(_pairKey(tokenA, tokenB), owner))];
        return (quote.fee0, quote.fee1);
    }

    /// @notice Returns the mocked LP token for a token pair.
    /// @dev Mimics router-side pair normalization.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @return liquidityToken Mock LP token address for the pair.
    function lpToken(address tokenA, address tokenB) external view returns (address liquidityToken) {
        return lpTokens[_pairKey(tokenA, tokenB)];
    }

    /// @notice Returns the mocked required token amounts for a target liquidity.
    /// @dev Reads the caller-facing token-order quote seeded by the test.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @param liquidityDesired Target liquidity to quote.
    /// @return amountARequired Mock required amount of `tokenA`.
    /// @return amountBRequired Mock required amount of `tokenB`.
    function quoteAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        returns (uint256 amountARequired, uint256 amountBRequired)
    {
        bytes32 key = _liquidityKey(tokenA, tokenB, liquidityDesired);
        return (paddedLiquidityQuoteAmountA[key], paddedLiquidityQuoteAmountB[key]);
    }

    function quoteExactAmountsForLiquidity(address tokenA, address tokenB, uint128 liquidityDesired)
        external
        view
        returns (uint256 amountARequired, uint256 amountBRequired)
    {
        bytes32 key = _liquidityKey(tokenA, tokenB, liquidityDesired);
        return (exactLiquidityQuoteAmountA[key], exactLiquidityQuoteAmountB[key]);
    }

    /// @notice Returns a normalized mock pool key for a token pair.
    /// @dev Matches the launcher's expectations for router pool-key derivation.
    /// @param tokenA First token in the pair.
    /// @param tokenB Second token in the pair.
    /// @return key Mock pool key for the pair.
    function getHookPoolKey(address tokenA, address tokenB) external view returns (PoolKey memory key) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(settlementHook))
        });
    }

    /// @notice Mints mocked claim fees to the requested recipient.
    /// @dev Uses the caller as the fee owner, matching launcher integration tests.
    /// @param key Mock pool key whose fees are claimed.
    /// @param recipient Recipient of the mocked claimed fees.
    /// @param deadline Unused mock signature deadline.
    /// @param v Unused mock signature recovery byte.
    /// @param r Unused mock signature r value.
    /// @param s Unused mock signature s value.
    /// @return fee0 Mock claimed fee amount for token0.
    /// @return fee1 Mock claimed fee amount for token1.
    function claimFees(PoolKey calldata key, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 fee0, uint256 fee1)
    {
        deadline;
        v;
        r;
        s;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        Quote memory quote = claimQuotes[keccak256(abi.encode(_pairKey(token0, token1), msg.sender))];

        fee0 = quote.fee0;
        fee1 = quote.fee1;

        if (fee0 != 0) MockERC20(token0).mint(recipient, fee0);
        if (fee1 != 0) MockERC20(token1).mint(recipient, fee1);
    }

    /// @notice Executes a mocked add-liquidity call for a pair.
    /// @dev Pulls the configured used amounts from the caller and mints mock LP shares to `to`.
    /// @param currency0 First pool currency.
    /// @param currency1 Second pool currency.
    /// @param amount0Desired Unused desired amount for `currency0`.
    /// @param amount1Desired Unused desired amount for `currency1`.
    /// @param amount0Min Unused minimum amount for `currency0`.
    /// @param amount1Min Unused minimum amount for `currency1`.
    /// @param to Recipient of the mocked LP shares.
    /// @param deadline Unused deadline.
    /// @return liquidity Mock LP liquidity minted to `to`.
    function addLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint128 liquidity) {
        addLiquidityCallCount_++;
        (liquidity,,) = _addLiquidityDetailed(
            currency0, currency1, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
        );
    }

    /// @notice Executes a mocked add-liquidity call and returns the actual spend alongside minted liquidity.
    /// @dev Mirrors the router detailed entrypoint by normalizing pool order internally but returning spend in caller order.
    /// @return liquidity Mock LP liquidity minted to `to`.
    /// @return amount0Used Mock amount of the first supplied currency consumed.
    /// @return amount1Used Mock amount of the second supplied currency consumed.
    function addLiquidityDetailed(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        addLiquidityDetailedCallCount_++;
        return _addLiquidityDetailed(
            currency0, currency1, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
        );
    }

    function _addLiquidityDetailed(
        Currency currency0,
        Currency currency1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) internal returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        amount0Min;
        amount1Min;
        deadline;

        address tokenA = Currency.unwrap(currency0);
        address tokenB = Currency.unwrap(currency1);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 amount0Budget, uint256 amount1Budget) =
            _normalizePairAmounts(tokenA, tokenB, amount0Desired, amount1Desired);
        AddLiquidityResult memory result = addLiquidityResults[_pairKey(token0, token1)];
        require(result.amount0Used <= amount0Budget && result.amount1Used <= amount1Budget, "mock over budget");
        (uint256 amountAUsed, uint256 amountBUsed) =
            tokenA < tokenB ? (result.amount0Used, result.amount1Used) : (result.amount1Used, result.amount0Used);
        if (amountAUsed != 0) IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountAUsed);
        if (amountBUsed != 0) IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBUsed);

        address liquidityToken = lpTokens[_pairKey(token0, token1)];
        if (result.liquidity != 0 && liquidityToken != address(0)) {
            MockERC20(liquidityToken).mint(to, result.liquidity);
        }
        return (result.liquidity, amountAUsed, amountBUsed);
    }

    /// @notice Executes a mocked pool bootstrap for a pair.
    /// @dev Reuses the configured add-liquidity result and returns the normalized pool key.
    /// @param tokenA First bootstrap token.
    /// @param tokenB Second bootstrap token.
    /// @param amountADesired Unused desired amount for `tokenA`.
    /// @param amountBDesired Unused desired amount for `tokenB`.
    /// @param startPrice Unused pool start price.
    /// @param recipient Recipient of mocked LP shares.
    /// @param deadline Unused deadline.
    /// @return liquidity Mock LP liquidity minted to `recipient`.
    /// @return poolKey Normalized mock pool key for the pair.
    /// @return amountAUsed Mock spend for `tokenA`.
    /// @return amountBUsed Mock spend for `tokenB`.
    function createPoolAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint160 startPrice,
        address recipient,
        uint256 deadline
    ) external returns (uint128 liquidity, PoolKey memory poolKey, uint256 amountAUsed, uint256 amountBUsed) {
        startPrice;
        deadline;

        createPoolAndAddLiquidityCallCount_++;
        poolKey = this.getHookPoolKey(tokenA, tokenB);
        AddLiquidityResult memory result = addLiquidityResults[_pairKey(tokenA, tokenB)];
        (amountAUsed, amountBUsed) =
            tokenA < tokenB ? (result.amount0Used, result.amount1Used) : (result.amount1Used, result.amount0Used);
        if (amountAUsed == 0 && amountBUsed == 0) {
            amountAUsed = amountADesired;
            amountBUsed = amountBDesired;
        }
        address liquidityToken = lpTokens[_pairKey(tokenA, tokenB)];
        if (result.liquidity != 0 && liquidityToken != address(0)) {
            MockERC20(liquidityToken).mint(recipient, result.liquidity);
        }
        return (result.liquidity, poolKey, amountAUsed, amountBUsed);
    }

    function removeLiquidity(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (BalanceDelta delta) {
        amount0Min;
        amount1Min;
        deadline;

        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        lastRemoveLiquidity[_pairKey(token0, token1)] = liquidity;
        if (revertNextRemoveLiquidity) {
            revertNextRemoveLiquidity = false;
            revert("mock removeLiquidity revert");
        }
        if (reenterLauncher != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            try IMemeverseLauncher(reenterLauncher).redeemAuxiliaryLiquidity(reenterVerseId) returns (
                uint256, uint256, uint256
            ) {
                reentrySucceeded = true;
            } catch {}
        }
        address liquidityToken = lpTokens[_pairKey(token0, token1)];
        if (liquidityToken != address(0) && liquidity != 0) {
            IERC20(liquidityToken).safeTransferFrom(msg.sender, address(this), liquidity);
        }

        RemoveLiquidityResult memory result = removeLiquidityResults[_pairKey(token0, token1)];
        if (result.amount0Out != 0) MockERC20(token0).mint(to, result.amount0Out);
        if (result.amount1Out != 0) MockERC20(token1).mint(to, result.amount1Out);
        return toBalanceDelta(int128(uint128(result.amount0Out)), int128(uint128(result.amount1Out)));
    }
}

contract MockSwapRouterWithBrokenPoolKey {
    address internal immutable hookAddress;

    constructor(address hookAddress_) {
        hookAddress = hookAddress_;
    }

    function hook() external view returns (address) {
        return hookAddress;
    }

    function getHookPoolKey(address, address) external pure returns (PoolKey memory) {
        revert("pool key helper unused");
    }
}

contract MockLiquidProof is MockERC20 {
    uint256 public burnedAmount;
    bytes32 public lastPoolId;

    constructor() MockERC20("POL", "POL", 18) {}

    /// @notice Burns POL from an account and records the amount.
    /// @dev Extends the mock token so tests can assert the burn side effect.
    /// @param from Account whose balance is burned.
    /// @param value Amount of POL to burn.
    function burn(address from, uint256 value) public override {
        burnedAmount += value;
        super.burn(from, value);
    }

    /// @notice Stores the latest pool id configured by the launcher.
    /// @dev Mirrors the launcher-only hook setup side effect for tests.
    /// @param poolId Mock pool id.
    function setPoolId(bytes32 poolId) external {
        lastPoolId = poolId;
    }
}

contract RefundCallbackToken is MockERC20 {
    address public callbackTarget;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    /// @notice Sets the address that should receive the refund callback.
    /// @dev Tests point this at an observer contract to detect transfer ordering.
    /// @param target Callback recipient triggered after successful transfers.
    function setCallbackTarget(address target) external {
        callbackTarget = target;
    }

    /// @notice Transfers tokens and triggers the test refund callback when needed.
    /// @dev Calls `onRefundCallback()` only when the recipient matches `callbackTarget`.
    /// @param to Transfer recipient.
    /// @param amount Token amount to transfer.
    /// @return success True when the ERC20 transfer succeeded.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (success && to == callbackTarget) {
            IRefundCallbackObserver(to).onRefundCallback();
        }
        return success;
    }
}

contract MintPolRefundObserver is IRefundCallbackObserver {
    IMemeverseLauncher public immutable launcher;
    IERC20 public immutable uAsset;
    IERC20 public immutable memecoin;
    IERC20 public immutable liquidProof;
    uint256 public immutable verseId;
    bool public sawPolDuringRefund;

    constructor(IMemeverseLauncher launcher_, IERC20 uAsset_, IERC20 memecoin_, IERC20 liquidProof_, uint256 verseId_) {
        launcher = launcher_;
        uAsset = uAsset_;
        memecoin = memecoin_;
        liquidProof = liquidProof_;
        verseId = verseId_;
    }

    /// @notice Grants the launcher unlimited approval over the observer's test assets.
    /// @dev Used before invoking mint flows that pull uAsset and memecoin from this helper.
    function approveLauncher() external {
        uAsset.approve(address(launcher), type(uint256).max);
        memecoin.approve(address(launcher), type(uint256).max);
    }

    /// @notice Forwards a `mintPOLToken` call through the observer contract.
    /// @dev Lets the test observe whether POL exists before refund callbacks fire.
    /// @param amountInUAssetDesired Desired uAsset spend.
    /// @param amountInMemecoinDesired Desired memecoin spend.
    /// @param amountInUAssetMin Minimum accepted uAsset spend.
    /// @param amountInMemecoinMin Minimum accepted memecoin spend.
    /// @param amountOutDesired Desired POL output.
    /// @param deadline Latest valid execution timestamp.
    /// @return amountInUAsset Actual uAsset spent.
    /// @return amountInMemecoin Actual memecoin spent.
    /// @return amountOut Actual POL minted.
    function executeMintPOLToken(
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    ) external returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) {
        return launcher.mintPOLToken(
            verseId,
            amountInUAssetDesired,
            amountInMemecoinDesired,
            amountInUAssetMin,
            amountInMemecoinMin,
            amountOutDesired,
            deadline
        );
    }

    /// @notice Observes the refund callback and records whether POL had already been minted.
    /// @dev Reverts unless the callback came from the memecoin refund token and POL is already present.
    function onRefundCallback() external override {
        require(msg.sender == address(memecoin), "unexpected callback token");
        sawPolDuringRefund = liquidProof.balanceOf(address(this)) != 0;
        require(sawPolDuringRefund, "POL not minted before refund");
    }
}

contract MockPredictOnlyProxyDeployer {
    address public immutable predictedYieldVault;
    address public immutable predictedGovernor;
    address public immutable predictedIncentivizer;

    constructor(address yieldVault, address governor, address incentivizer) {
        predictedYieldVault = yieldVault;
        predictedGovernor = governor;
        predictedIncentivizer = incentivizer;
    }

    /// @notice Returns the mocked predicted yield vault address.
    /// @dev Ignores the verse id because this mock always returns a fixed address.
    /// @param uniqueId Unused mock verse id.
    /// @return yieldVault The mocked predicted yield vault address.
    function predictYieldVaultAddress(uint256 uniqueId) external view returns (address) {
        uniqueId;
        return predictedYieldVault;
    }

    /// @notice Returns the mocked predicted governor and incentivizer addresses.
    /// @dev Ignores the verse id because this mock always returns fixed addresses.
    /// @param uniqueId Unused mock verse id.
    /// @return governor The mocked governor address.
    /// @return incentivizer The mocked incentivizer address.
    function computeGovernorAndIncentivizerAddress(uint256 uniqueId)
        external
        view
        returns (address governor, address incentivizer)
    {
        uniqueId;
        return (predictedGovernor, predictedIncentivizer);
    }
}

contract MockPOLendForLifecycle {
    uint256 internal totalLeveragedDebt_;
    uint256 internal totalLeveragedInterest_;
    uint256 internal totalLeveragedYT_;
    address internal uAsset_;
    address internal pt_;
    address internal yt_;
    uint8 internal state_;
    address internal settlementLauncher_;
    bool internal settleAuxiliaryOnGlobalSettlement_;
    uint256 public preRedeemPTFeeCallCount;
    uint256 public lastPreRedeemPTFeeVerseId;
    uint256 public lastPreRedeemPTFeeAmount;
    address public lastPreRedeemPTFeeMintTo;
    address public lastFundSettlementDustReserveUAsset;
    uint256 public lastFundSettlementDustReserveAmount;
    uint256 internal preRedeemPTFeeBacking_;
    bool internal hasPreRedeemPTFeeBacking_;

    function setTotalLeveragedDebt(uint256 verseId, uint256 amount) external {
        verseId;
        totalLeveragedDebt_ = amount;
    }

    function setTotalLeveragedInterest(uint256 verseId, uint256 amount) external {
        verseId;
        totalLeveragedInterest_ = amount;
    }

    function setLendMarket(address pt, address yt) external {
        pt_ = pt;
        yt_ = yt;
    }

    function setLendMarketUAsset(address uAsset) external {
        uAsset_ = uAsset;
    }

    function registerLendMarket(uint256) external {}

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

    function getTotalDebtByUAsset(address uAsset) external view returns (uint256) {
        if (uAsset == address(0)) revert IPOLend.ZeroInput();
        return uAsset == uAsset_ ? totalLeveragedDebt_ : 0;
    }

    function settlementDustStates(address) external pure returns (uint128 reserve, uint128 maxReserve) {
        return (0, 0);
    }

    function fundSettlementDustReserve(address uAsset, uint256 amount) external {
        lastFundSettlementDustReserveUAsset = uAsset;
        lastFundSettlementDustReserveAmount = amount;
    }

    function getLeveragedDebtInfo(uint256) external view returns (IPOLend.LeveragedDebtInfo memory info) {
        info.totalLeveragedInterest = totalLeveragedInterest_;
        info.totalLeveragedDebt = totalLeveragedDebt_;
    }

    function getLendMarket(uint256) external view returns (IPOLend.LendMarket memory market) {
        market.yt = yt_;
        market.totalLeveragedInterest = totalLeveragedInterest_;
        market.totalLeveragedYT = totalLeveragedYT_;
        market.state = IPOLend.MarketState(state_);
        market.uAsset = uAsset_;
    }

    function finalizeLeveragedGenesis(uint256 verseId) external {
        verseId;
        state_ = 2;
    }

    function recordLeveragedYT(uint256 verseId, address yt, uint256 totalLeveragedYT) external {
        verseId;
        yt_ = yt;
        totalLeveragedYT_ = totalLeveragedYT;
    }

    function markRefundable(uint256 verseId) external {
        verseId;
        state_ = 4;
    }

    function setPreRedeemPTFeeBacking(uint256 backing) external {
        preRedeemPTFeeBacking_ = backing;
        hasPreRedeemPTFeeBacking_ = true;
    }

    function setSettleAuxiliaryOnGlobalSettlement(address launcher, bool enabled) external {
        settlementLauncher_ = launcher;
        settleAuxiliaryOnGlobalSettlement_ = enabled;
    }

    function executeGlobalSettlement(uint256 verseId) external {
        state_ = 3;
        if (settleAuxiliaryOnGlobalSettlement_) {
            IMemeverseLauncher(settlementLauncher_).settleLeveragedAuxiliaryLiquidity(verseId);
        }
    }

    function preRedeemPTFee(uint256 verseId, uint256 ptAmount, address mintTo)
        external
        returns (uint256 uAssetBacking)
    {
        preRedeemPTFeeCallCount++;
        lastPreRedeemPTFeeVerseId = verseId;
        lastPreRedeemPTFeeAmount = ptAmount;
        lastPreRedeemPTFeeMintTo = mintTo;

        uAssetBacking = hasPreRedeemPTFeeBacking_ ? preRedeemPTFeeBacking_ : ptAmount;
        if (ptAmount != 0 && uAssetBacking == 0) revert IPOLend.InvalidClaim();
        address uAsset = uAsset_;
        if (uAsset == address(0)) uAsset = IMemeverseLauncher(msg.sender).getMemeverseByVerseId(verseId).uAsset;
        MockERC20(uAsset).mint(mintTo, uAssetBacking);
    }

    function burnPreRedeemedBacking(uint256, uint256) external {}
}

contract RedeemMemecoinLiquidityReenterer {
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public lastRevertData;

    function redeemDuringSettlement(IMemeverseLauncher launcher, uint256 verseId, uint256 amountInPOL) external {
        reentryAttempted = true;
        delete lastRevertData;
        try launcher.redeemMemecoinLiquidity(verseId, amountInPOL, false) returns (uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }
}

contract ClaimNormalFeesReenterer is IClaimNormalFeesReentryObserver {
    IMemeverseLauncher public immutable launcher;
    IERC20 public immutable uAsset;
    IERC20 public immutable pt;
    uint256 public immutable verseId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public lastRevertData;

    constructor(IMemeverseLauncher launcher_, IERC20 uAsset_, IERC20 pt_, uint256 verseId_) {
        launcher = launcher_;
        uAsset = uAsset_;
        pt = pt_;
        verseId = verseId_;
    }

    function claimNormalFees() external returns (uint256 uAssetAmount, uint256 ptAmount) {
        return launcher.claimNormalFees(verseId);
    }

    function claimNormalYT() external returns (uint256 amount) {
        return launcher.claimNormalYT(verseId);
    }

    function redeemAuxiliaryLiquidity() external returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount) {
        return launcher.redeemAuxiliaryLiquidity(verseId);
    }

    function onRedeemPTCallback() external override {
        reentryAttempted = true;
        delete lastRevertData;
        try launcher.claimNormalFees(verseId) returns (uint256, uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }

    function onRedeemPTClaimNormalYTCallback() external {
        reentryAttempted = true;
        delete lastRevertData;
        try launcher.claimNormalYT(verseId) returns (uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }

    function onRedeemPTRedeemAuxiliaryLiquidityCallback() external {
        reentryAttempted = true;
        delete lastRevertData;
        try launcher.redeemAuxiliaryLiquidity(verseId) returns (uint256, uint256, uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }
}

contract MockPOLSplitterForLifecycle {
    address internal immutable pt;
    address internal immutable yt;
    uint256 public initializeVerseCallCount;
    uint256 public bridgeRedeemCallCount;
    uint256 public lastBridgeRedeemVerseId;
    uint256 public lastBridgeRedeemPTAmount;
    uint256 public redeemPTCallCount;
    uint256 public lastRedeemPTVerseId;
    uint256 public lastRedeemPTAmount;
    address public lastRedeemPTTo;
    address internal reenterLauncher;
    uint256 internal reenterVerseId;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bool public initializeReentryAttempted;
    bool public initializeGenesisSucceeded;
    bool public initializePreorderSucceeded;
    IMemeverseLauncher.Stage public initializeObservedStage;
    address internal memecoinLiquidityReenterer;
    uint256 internal reenterMemecoinLiquidityAmount;
    address internal claimNormalFeesReenterer;
    uint8 internal claimNormalFeesReentryMode;
    bool internal settled;
    uint256 internal previewPTToUAssetResult;
    bool internal hasPreviewPTToUAssetResult;
    uint256 internal previewPTToUAssetNumerator;
    uint256 internal previewPTToUAssetDenominator;
    mapping(uint256 => uint256) internal ptBackingNumerators;
    mapping(uint256 => uint256) internal ptBackingDenominators;

    constructor(address pt_, address yt_) {
        pt = pt_;
        yt = yt_;
    }

    function initializeVerse(uint256 verseId, address, address, address, string calldata, string calldata)
        external
        returns (address, address)
    {
        initializeVerseCallCount++;
        if (reenterLauncher != address(0) && reenterVerseId == verseId && !initializeReentryAttempted) {
            initializeReentryAttempted = true;
            IMemeverseLauncher launcher = IMemeverseLauncher(reenterLauncher);
            initializeObservedStage = launcher.getStageByVerseId(verseId);
            try launcher.genesis(verseId, 1, address(this)) {
                initializeGenesisSucceeded = true;
            } catch {}
            try launcher.preorder(verseId, 1, address(this)) {
                initializePreorderSucceeded = true;
            } catch {}
        }
        return (pt, yt);
    }

    function splitInfos(uint256)
        external
        view
        returns (address, address, address, address, address, uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (pt, yt, address(0), address(0), address(0), 0, 0, 0, 0, 0, settled);
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
        return (pt, settled);
    }

    function setSettled(bool settled_) external {
        settled = settled_;
    }

    function setPreviewPTToUAssetResult(uint256 result) external {
        previewPTToUAssetResult = result;
        hasPreviewPTToUAssetResult = true;
    }

    function setPreviewPTToUAssetRatio(uint256 numerator, uint256 denominator) external {
        require(denominator != 0, "zero denominator");
        previewPTToUAssetNumerator = numerator;
        previewPTToUAssetDenominator = denominator;
        hasPreviewPTToUAssetResult = false;
    }

    function setInitializeVerseReentry(address launcher, uint256 verseId) external {
        reenterLauncher = launcher;
        reenterVerseId = verseId;
        initializeReentryAttempted = false;
        initializeGenesisSucceeded = false;
        initializePreorderSucceeded = false;
        initializeObservedStage = IMemeverseLauncher.Stage.Genesis;
    }

    function split(uint256, uint256 polAmount) external returns (uint256 ptAmount, uint256 ytAmount) {
        MockERC20(pt).mint(msg.sender, polAmount);
        MockERC20(yt).mint(msg.sender, polAmount);
        return (polAmount, polAmount);
    }

    function recordPTBackingRatio(uint256 verseId, uint256 numerator, uint256 denominator) external {
        ptBackingNumerators[verseId] = numerator;
        ptBackingDenominators[verseId] = denominator;
    }

    function setSettleReentry(address launcher, uint256 verseId) external {
        reenterLauncher = launcher;
        reenterVerseId = verseId;
        memecoinLiquidityReenterer = address(0);
        reenterMemecoinLiquidityAmount = 0;
        reentryAttempted = false;
        reentrySucceeded = false;
        initializeReentryAttempted = false;
        initializeGenesisSucceeded = false;
        initializePreorderSucceeded = false;
        initializeObservedStage = IMemeverseLauncher.Stage.Genesis;
    }

    function setSettleMemecoinLiquidityReentry(
        address reenterer,
        address launcher,
        uint256 verseId,
        uint256 amountInPOL
    ) external {
        reenterLauncher = launcher;
        reenterVerseId = verseId;
        memecoinLiquidityReenterer = reenterer;
        reenterMemecoinLiquidityAmount = amountInPOL;
        reentryAttempted = false;
        reentrySucceeded = false;
        initializeReentryAttempted = false;
        initializeGenesisSucceeded = false;
        initializePreorderSucceeded = false;
        initializeObservedStage = IMemeverseLauncher.Stage.Genesis;
    }

    function setClaimNormalFeesReentry(address reenterer) external {
        claimNormalFeesReenterer = reenterer;
        claimNormalFeesReentryMode = 1;
    }

    function setClaimNormalFeesReentryMode(address reenterer, uint8 mode) external {
        claimNormalFeesReenterer = reenterer;
        claimNormalFeesReentryMode = mode;
    }

    function settle(uint256) external returns (uint256 settlementUAsset, uint256 settlementMemecoin) {
        if (reenterLauncher != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            if (memecoinLiquidityReenterer != address(0)) {
                RedeemMemecoinLiquidityReenterer(memecoinLiquidityReenterer)
                    .redeemDuringSettlement(
                        IMemeverseLauncher(reenterLauncher), reenterVerseId, reenterMemecoinLiquidityAmount
                    );
            } else {
                try IMemeverseLauncher(reenterLauncher).redeemAuxiliaryLiquidity(reenterVerseId) returns (
                    uint256, uint256, uint256
                ) {
                    reentrySucceeded = true;
                } catch {}
            }
        }
        return (0, 0);
    }

    function merge(uint256, uint256) external pure returns (uint256) {
        revert("unused");
    }

    function preRedeemPTFee(uint256, uint256) external pure returns (uint256 uAssetBacking) {
        return 0;
    }

    function redeemPT(uint256 verseId, uint256 ptAmount, address to) external returns (uint256 uAssetAmount) {
        redeemPTCallCount++;
        lastRedeemPTVerseId = verseId;
        lastRedeemPTAmount = ptAmount;
        lastRedeemPTTo = to;
        uAssetAmount = _previewPTToUAsset(verseId, ptAmount);
        if (uAssetAmount == 0) revert IPOLSplitter.InvalidClaim();
        MockERC20(pt).burn(msg.sender, ptAmount);
        address uAsset = IMemeverseLauncher(msg.sender).getMemeverseByVerseId(verseId).uAsset;
        MockERC20(uAsset).mint(to, uAssetAmount);
        if (claimNormalFeesReenterer != address(0) && to == claimNormalFeesReenterer) {
            if (claimNormalFeesReentryMode == 2) {
                ClaimNormalFeesReenterer(claimNormalFeesReenterer).onRedeemPTClaimNormalYTCallback();
            } else if (claimNormalFeesReentryMode == 3) {
                ClaimNormalFeesReenterer(claimNormalFeesReenterer).onRedeemPTRedeemAuxiliaryLiquidityCallback();
            } else {
                IClaimNormalFeesReentryObserver(claimNormalFeesReenterer).onRedeemPTCallback();
            }
        }
        return uAssetAmount;
    }

    function redeemYT(uint256, uint256, address) external pure returns (uint256, uint256) {
        revert("unused");
    }

    function previewRedeemYTUAsset(uint256, uint256) external pure returns (uint256 uAssetAmount) {
        return 0;
    }

    function previewPTToUAsset(uint256 verseId, uint256 ptAmount) external view returns (uint256 uAssetAmount) {
        return _previewPTToUAsset(verseId, ptAmount);
    }

    function _previewPTToUAsset(uint256 verseId, uint256 ptAmount) internal view returns (uint256 uAssetAmount) {
        if (hasPreviewPTToUAssetResult) return previewPTToUAssetResult;
        if (previewPTToUAssetDenominator != 0) {
            return FullMath.mulDiv(ptAmount, previewPTToUAssetNumerator, previewPTToUAssetDenominator);
        }
        if (ptBackingDenominators[verseId] != 0) {
            return FullMath.mulDiv(ptAmount, ptBackingNumerators[verseId], ptBackingDenominators[verseId]);
        }
        return ptAmount;
    }
}

contract MockOFTDispatcher {
    uint256 public composeCallCount;
    address public lastToken;
    bytes public lastMessage;

    /// @notice Records a mocked compose dispatch.
    /// @dev Stores the last token and payload for launcher fee-distribution assertions.
    /// @param _from Token address associated with the compose message.
    /// @param _guid Unused mock compose guid.
    /// @param _message Mock compose payload.
    /// @param _executor Unused mock executor address.
    /// @param _extraData Unused mock extra data.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable {
        _guid;
        _executor;
        _extraData;
        composeCallCount++;
        lastToken = _from;
        lastMessage = _message;
    }

    /// @notice Records a mocked same-chain dispatch.
    /// @dev Reuses the lzCompose counters/fields so existing assertions stay unchanged.
    /// Message is encoded as (receiver, tokenType, amount) to match the prior same-chain
    /// compose payload, keeping `abi.decode(lastMessage, (address, uint8, uint256))` valid.
    /// @param token Token being distributed.
    /// @param receiver Recipient of the distribution.
    /// @param tokenType Enum identifying the token type.
    /// @param amount Amount being distributed.
    function distributeSameChain(address token, address receiver, IMemeverseOFTEnum.TokenType tokenType, uint256 amount)
        external
    {
        composeCallCount++;
        lastToken = token;
        lastMessage = abi.encode(receiver, tokenType, amount);
    }
}

contract MockLzEndpointRegistry {
    mapping(uint32 chainId => uint32 endpointId) public lzEndpointIdOfChain;

    /// @notice Set endpoint.
    /// @dev Mirrors the registry setter so tests can control chain/endpoint mapping.
    /// @param chainId See implementation.
    /// @param endpointId See implementation.
    function setEndpoint(uint32 chainId, uint32 endpointId) external {
        lzEndpointIdOfChain[chainId] = endpointId;
    }
}

contract MockOFTToken is MockERC20, IOFT {
    MessagingFee internal nextQuoteFee;
    bool internal quoteAmountAsFee;
    uint32 public lastSendDstEid;
    address public lastRefundAddress;
    uint256 public lastNativeFeePaid;
    uint256 public lastSendAmountLD;
    /// @notice Last `SendParam.extraOptions` observed by `send`.
    /// @dev Recorded verbatim so tests can assert the executor options (receive/compose gas limits) that the
    ///      production settlement path encodes for the remote lzCompose execution; without this, an options-wiring
    ///      regression ships with a green suite (F-100 test anchor).
    bytes public lastSendOptions;
    uint256 public sendCallCount;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    /// @notice Set quote fee.
    /// @dev Stores the per-chain fee used by remote quote tests.
    /// @param nativeFee See implementation.
    function setQuoteFee(uint256 nativeFee) external {
        nextQuoteFee = MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function setQuoteAmountAsFee(bool enabled) external {
        quoteAmountAsFee = enabled;
    }

    /// @notice Oft version.
    /// @dev Returns the IOFT interface id and mock version used by the dispatcher.
    /// @return interfaceId See implementation.
    /// @return version See implementation.
    function oftVersion() external pure returns (bytes4 interfaceId, uint64 version) {
        return (type(IOFT).interfaceId, 1);
    }

    /// @notice Token.
    /// @dev Always returns `address(this)` because this mock represents that token.
    /// @return See implementation.
    function token() external view returns (address) {
        return address(this);
    }

    /// @notice Approval required.
    /// @dev Matches the IOFT interface by allowing immediate approval.
    /// @return See implementation.
    function approvalRequired() external pure returns (bool) {
        return false;
    }

    /// @notice Shared decimals.
    /// @dev Signals the decimals that accompany messaging fees.
    /// @return See implementation.
    function sharedDecimals() external pure returns (uint8) {
        return 6;
    }

    /// @notice Quote oft — mirrors `OutrunOFTCoreInit._debitView`/`_removeDust` truncation.
    /// @dev The production OFT truncates the local-decimal amount to
    ///      `(amountLD / decimalConversionRate) * decimalConversionRate` before encoding the shared-decimal amount on
    ///      the wire, so a sub-`decimalConversionRate` `amountLD` collapses to `amountSentLD = amountReceivedLD = 0`.
    ///      The settlement path's `_sendRedeemedFeesCrossChain` now pre-checks this receipt's `amountReceivedLD`,
    ///      so the mock must implement the same truncation (rate = 1e12 for this 18-decimal mock, sharedDecimals = 6).
    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory)
    {
        uint256 rate = 10 ** (this.decimals() - this.sharedDecimals());
        uint256 amountSentLD = (sendParam.amountLD / rate) * rate;
        return (OFTLimit(0, type(uint64).max), new OFTFeeDetail[](0), OFTReceipt(amountSentLD, amountSentLD));
    }

    /// @notice Quote send.
    /// @dev Returns the previously stored messaging fee for the requested payload.
    /// @param sendParam See implementation.
    /// @param payInLzToken See implementation.
    /// @return fee See implementation.
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory fee)
    {
        payInLzToken;
        if (quoteAmountAsFee) return MessagingFee({nativeFee: sendParam.amountLD, lzTokenFee: 0});
        fee = nextQuoteFee;
    }

    /// @notice Send.
    /// @dev Records the last dispatch payload and returns deterministic receipts.
    /// @param sendParam See implementation.
    /// @param fee See implementation.
    /// @param refundAddress See implementation.
    /// @return receipt See implementation.
    /// @return oftReceipt See implementation.
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        lastSendDstEid = sendParam.dstEid;
        lastRefundAddress = refundAddress;
        lastNativeFeePaid = msg.value;
        lastSendAmountLD = sendParam.amountLD;
        lastSendOptions = sendParam.extraOptions;
        sendCallCount++;

        receipt = MessagingReceipt({guid: bytes32("oft-guid"), nonce: 1, fee: fee});
        oftReceipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: sendParam.amountLD});
    }
}
