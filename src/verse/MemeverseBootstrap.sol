// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {InitialPriceCalculator} from "./libraries/InitialPriceCalculator.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";
import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {IPol} from "../token/interfaces/IPol.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemeverseSwapRouter} from "../swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseBootstrap} from "./interfaces/IMemeverseBootstrap.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";

/// @title MemeverseBootstrap
/// @notice Delegatecall-only sibling holding the bootstrap liquidity chain relocated from
///         MemeverseLauncher. Binds the SAME ERC-7201 slot so under delegatecall it operates on
///         the proxy's MemeverseLauncherStorage. No Initializable, no own storage, empty constructor.
contract MemeverseBootstrap layout at erc7201("outrun.storage.MemeverseLauncher") is TokenHelper, IMemeverseBootstrap {
    MemeverseLauncherStorage private memeverseLauncherStorage;

    constructor() {}

    // === relocated bootstrap chain (from MemeverseLauncher) ===
    //
    // Nested types (Memeverse, FundMetaData, PreorderState, AuxiliaryLiquidity,
    // BootstrapResidualClaims, BootstrapPolPlan, etc.) and the Stage enum are declared inside
    // interface IMemeverseLauncher. Unlike the facade (which inherits IMemeverseLauncher and can
    // use bare names), this sibling only inherits TokenHelper, so every reference below is
    // qualified as IMemeverseLauncher.X.

    /**
     * @notice Bootstrap liquidity entrypoint. Invoked by the MemeverseLauncher facade via
     *         delegatecall so it writes to the proxy's MemeverseLauncherStorage.
     * @dev Delegatecall-only by construction, not by a runtime guard. The sibling has no initializer
     *      and no setter, so its own storage is permanently uninitialized: memeverseSwapRouter and
     *      memeverseUniswapHook read as address(0) under a direct (non-delegatecall) call, and
     *      MemeverseLauncherLib.validateSettlementWiring reverts on its zero-address require. A msg.sender guard
     *      would be wrong here — under delegatecall msg.sender is the facade's caller (arbitrary),
     *      not the facade. This invariant is locked by test_directCallToSiblingReverts. Visibility is
     *      external to match the IMemeverseBootstrap entrypoint shape; body is byte-for-byte the
     *      facade logic.
     */
    function deployLiquidity(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) external override {
        require(_polend != address(0) && _polSplitter != address(0), IMemeverseLauncher.PermissionDenied());

        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalGenesisFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 mainPoolUAssetBudget = FullMath.mulDiv(totalGenesisFunds, 7, 10);
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address hookAddress = memeverseLauncherStorage.memeverseUniswapHook;

        MemeverseLauncherLib.validateSettlementWiring(swapRouter, hookAddress);
        _safeApprove(uAsset, swapRouter, totalGenesisFunds);
        _safeApprove(
            memecoin, swapRouter, mainPoolUAssetBudget * memeverseLauncherStorage.fundMetaDatas[uAsset].fundBasedAmount
        );
        _safeApproveInf(uAsset, hookAddress);

        (uint256 mainPoolUAssetUsed, uint256 polUAssetUsed, uint256 ptUAssetUsed, uint256 burnedMemecoin) = _createBootstrapPools(
            verseId,
            uAsset,
            memecoin,
            pol,
            normalFunds,
            totalLeveragedDebt,
            mainPoolUAssetBudget,
            swapRouter,
            _polSplitter,
            _polend
        );

        uint256 totalSpent = mainPoolUAssetUsed + polUAssetUsed + ptUAssetUsed;
        uint256 unusedBootstrapUAsset = totalSpent < totalGenesisFunds ? totalGenesisFunds - totalSpent : 0;
        _handleBootstrapResiduals(verseId, uAsset, memecoin, unusedBootstrapUAsset, burnedMemecoin, _polend);
    }

    function _createBootstrapPools(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 normalFunds,
        uint256 totalLeveragedDebt,
        uint256 mainPoolUAssetBudget,
        address swapRouter,
        address _polSplitter,
        address _polend
    )
        internal
        returns (uint256 mainPoolUAssetUsed, uint256 polUAssetUsed, uint256 ptUAssetUsed, uint256 burnedMemecoin)
    {
        uint128 mainPoolPOLRawAmount;
        PoolKey memory poolKey;
        (mainPoolPOLRawAmount, poolKey, mainPoolUAssetUsed, burnedMemecoin) =
            _createMainBootstrapPool(memecoin, uAsset, mainPoolUAssetBudget, swapRouter);

        _settlePreorder(verseId, poolKey, uAsset, memecoin);
        IMemeverseLauncher.BootstrapPolPlan memory plan =
            _buildBootstrapPolPlan(normalFunds, mainPoolPOLRawAmount, totalLeveragedDebt);

        address yt;
        (polUAssetUsed, ptUAssetUsed, yt) = _bootstrapPOLAndAuxiliaryPools(
            verseId,
            uAsset,
            pol,
            swapRouter,
            _polSplitter,
            plan,
            mainPoolPOLRawAmount,
            mainPoolUAssetUsed,
            poolKey.toId(),
            totalLeveragedDebt
        );

        if (plan.leveragedPolToSplit != 0) {
            _transferOut(yt, _polend, plan.leveragedPolToSplit);
            IPOLend(_polend).recordLeveragedYT(verseId, yt, plan.leveragedPolToSplit);
        }
    }

    function _createMainBootstrapPool(
        address memecoin,
        address uAsset,
        uint256 mainPoolUAssetBudget,
        address swapRouter
    )
        internal
        returns (
            uint128 mainPoolPOLRawAmount,
            PoolKey memory poolKey,
            uint256 mainPoolUAssetUsed,
            uint256 burnedMemecoin
        )
    {
        uint256 mainPoolMemecoinBudget = mainPoolUAssetBudget
            * memeverseLauncherStorage.fundMetaDatas[uAsset].fundBasedAmount;
        uint160 mainPoolStartPrice = InitialPriceCalculator.calculateInitialSqrtPriceX96(
            memecoin, uAsset, mainPoolMemecoinBudget, mainPoolUAssetBudget
        );
        IMemecoin(memecoin).mint(address(this), mainPoolMemecoinBudget);

        uint256 mainPoolMemecoinUsed;
        (mainPoolPOLRawAmount, poolKey, mainPoolMemecoinUsed, mainPoolUAssetUsed) = IMemeverseSwapRouter(swapRouter)
            .createPoolAndAddLiquidity(
                memecoin,
                uAsset,
                mainPoolMemecoinBudget,
                mainPoolUAssetBudget,
                mainPoolStartPrice,
                address(this),
                block.timestamp
            );

        burnedMemecoin = mainPoolMemecoinBudget - mainPoolMemecoinUsed;
        if (burnedMemecoin != 0) IMemecoin(memecoin).burn(burnedMemecoin);
    }

    function _bootstrapPOLAndAuxiliaryPools(
        uint256 verseId,
        address uAsset,
        address pol,
        address swapRouter,
        address _polSplitter,
        IMemeverseLauncher.BootstrapPolPlan memory plan,
        uint256 mainPoolPOLRawAmount,
        uint256 mainPoolUAssetUsed,
        PoolId poolId,
        uint256 totalLeveragedDebt
    ) internal returns (uint256 polUAssetUsed, uint256 ptUAssetUsed, address yt) {
        _safeApprove(pol, swapRouter, plan.polForPolUAsset + plan.polForPtPol);

        uint256 polUsedForPolUAsset;
        address pt;
        (polUAssetUsed, polUsedForPolUAsset, pt, yt) = _bootstrapPOLPool(
            verseId, uAsset, pol, swapRouter, _polSplitter, plan, mainPoolPOLRawAmount, mainPoolUAssetUsed, poolId
        );

        ptUAssetUsed = _bootstrapPTPools(
            verseId,
            uAsset,
            pol,
            pt,
            swapRouter,
            _polSplitter,
            plan,
            mainPoolUAssetUsed,
            mainPoolPOLRawAmount,
            polUsedForPolUAsset,
            totalLeveragedDebt
        );
    }

    function _bootstrapPOLPool(
        uint256 verseId,
        address uAsset,
        address pol,
        address swapRouter,
        address _polSplitter,
        IMemeverseLauncher.BootstrapPolPlan memory plan,
        uint256 mainPoolPOLRawAmount,
        uint256 mainPoolUAssetUsed,
        PoolId poolId
    ) internal returns (uint256 polUAssetUsed, uint256 polUsedForPolUAsset, address pt, address yt) {
        IPol(pol).mint(address(this), mainPoolPOLRawAmount);
        IPol(pol).setPoolId(poolId);

        (pt, yt) = IPOLSplitter(_polSplitter).getPTAndYT(verseId);

        IPOLSplitter(_polSplitter).recordPTBackingRatio(verseId, mainPoolUAssetUsed, mainPoolPOLRawAmount);
        uint256 polUAssetRequired = FullMath.mulDiv(plan.polForPolUAsset, mainPoolUAssetUsed, mainPoolPOLRawAmount);
        uint128 polUAssetLpAmount;
        (polUAssetLpAmount,, polUsedForPolUAsset, polUAssetUsed) =
            _createPoolAndAddLiquidity(swapRouter, pol, uAsset, plan.polForPolUAsset, polUAssetRequired, address(this));
        memeverseLauncherStorage.auxiliaryLiquidities[verseId].polUAssetLpAmount = polUAssetLpAmount;
    }

    function _bootstrapPTPools(
        uint256 verseId,
        address uAsset,
        address pol,
        address pt,
        address swapRouter,
        address _polSplitter,
        IMemeverseLauncher.BootstrapPolPlan memory plan,
        uint256 mainPoolUAssetUsed,
        uint256 mainPoolPOLRawAmount,
        uint256 polUsedForPolUAsset,
        uint256 totalLeveragedDebt
    ) internal returns (uint256 ptUAssetUsed) {
        _safeApproveInf(pol, _polSplitter);
        (uint256 totalPT,) = IPOLSplitter(_polSplitter).split(verseId, plan.normalPolToSplit + plan.leveragedPolToSplit);
        _safeApprove(pt, swapRouter, totalPT);
        uint256 ptForPtUAsset = totalPT / 3;
        uint256 ptForPtPol = totalPT - ptForPtUAsset;

        uint256 ptUsedForPtUAsset;
        uint256 ptUsedForPtPol;
        uint256 polUsedForPtPol;
        (ptUAssetUsed, ptUsedForPtUAsset) = _createPTUAssetAuxiliaryPool(
            verseId, uAsset, pt, swapRouter, mainPoolUAssetUsed, mainPoolPOLRawAmount, ptForPtUAsset
        );
        (ptUsedForPtPol, polUsedForPtPol) =
            _createPTPOLAuxiliaryPool(verseId, pol, pt, swapRouter, ptForPtPol, plan.polForPtPol);

        memeverseLauncherStorage.totalNormalClaimableYT[verseId] = plan.normalPolToSplit;
        _recordPTBootstrapResiduals(
            verseId,
            plan,
            polUsedForPolUAsset,
            polUsedForPtPol,
            ptForPtUAsset,
            ptUsedForPtUAsset,
            ptForPtPol,
            ptUsedForPtPol,
            totalLeveragedDebt
        );
    }

    function _createPTUAssetAuxiliaryPool(
        uint256 verseId,
        address uAsset,
        address pt,
        address swapRouter,
        uint256 mainPoolUAssetUsed,
        uint256 mainPoolPOLRawAmount,
        uint256 ptForPtUAsset
    ) internal returns (uint256 ptUAssetUsed, uint256 ptUsedForPtUAsset) {
        uint256 ptUAssetRequired = FullMath.mulDiv(ptForPtUAsset, mainPoolUAssetUsed, mainPoolPOLRawAmount);
        uint128 ptUAssetLpAmount;
        (ptUAssetLpAmount,, ptUsedForPtUAsset, ptUAssetUsed) =
            _createPoolAndAddLiquidity(swapRouter, pt, uAsset, ptForPtUAsset, ptUAssetRequired, address(this));
        memeverseLauncherStorage.auxiliaryLiquidities[verseId].ptUAssetLpAmount = ptUAssetLpAmount;
    }

    function _createPTPOLAuxiliaryPool(
        uint256 verseId,
        address pol,
        address pt,
        address swapRouter,
        uint256 ptForPtPol,
        uint256 polForPtPol
    ) internal returns (uint256 ptUsedForPtPol, uint256 polUsedForPtPol) {
        uint128 ptPolLpAmount;
        (ptPolLpAmount,, ptUsedForPtPol, polUsedForPtPol) =
            _createPoolAndAddLiquidity(swapRouter, pt, pol, ptForPtPol, polForPtPol, address(this));
        memeverseLauncherStorage.auxiliaryLiquidities[verseId].ptPolLpAmount = ptPolLpAmount;
    }

    function _recordPTBootstrapResiduals(
        uint256 verseId,
        IMemeverseLauncher.BootstrapPolPlan memory plan,
        uint256 polUsedForPolUAsset,
        uint256 polUsedForPtPol,
        uint256 ptForPtUAsset,
        uint256 ptUsedForPtUAsset,
        uint256 ptForPtPol,
        uint256 ptUsedForPtPol,
        uint256 totalLeveragedDebt
    ) internal {
        uint256 residualPOL =
            plan.polForPolUAsset - polUsedForPolUAsset + plan.polForPtPol - polUsedForPtPol;
        uint256 residualPT = ptForPtUAsset - ptUsedForPtUAsset + ptForPtPol - ptUsedForPtPol;
        uint256 _totalGenesisFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(
            memeverseLauncherStorage.totalNormalFunds[verseId], totalLeveragedDebt
        );
        _recordBootstrapResidualClaims(verseId, residualPOL, residualPT, totalLeveragedDebt, _totalGenesisFunds);
    }

    function _handleBootstrapResiduals(
        uint256 verseId,
        address uAsset,
        address memecoin,
        uint256 unusedBootstrapUAsset,
        uint256 burnedMemecoin,
        address _polend
    ) internal {
        // credited/treasuryExcess stay 0 when no unused uAsset is routed, so the single emit below
        // naturally reports (0, 0) for the unused-asset fields — both residual shapes share one emit site.
        uint256 credited;
        uint256 treasuryExcess;
        if (unusedBootstrapUAsset != 0) {
            (uint128 reserveBefore, uint128 maxReserve) = IPOLend(_polend).settlementDustStates(uAsset);
            uint256 capacity = maxReserve > reserveBefore ? uint256(maxReserve - reserveBefore) : 0;
            credited = unusedBootstrapUAsset < capacity ? unusedBootstrapUAsset : capacity;
            treasuryExcess = unusedBootstrapUAsset - credited;
            _safeApprove(uAsset, _polend, 0);
            _safeApprove(uAsset, _polend, unusedBootstrapUAsset);
            IPOLend(_polend).fundSettlementDustReserve(uAsset, unusedBootstrapUAsset);
        }
        // Emit only when something actually happened: unused uAsset routed, or memecoin burned.
        if (unusedBootstrapUAsset != 0 || burnedMemecoin != 0) {
            emit IMemeverseLauncher.BootstrapUnusedAssetsHandled(
                verseId, uAsset, memecoin, unusedBootstrapUAsset, credited, treasuryExcess, burnedMemecoin
            );
        }
    }

    function _createPoolAndAddLiquidity(
        address swapRouter,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        address recipient
    ) internal returns (uint128 liquidity, PoolKey memory poolKey, uint256 amountAUsed, uint256 amountBUsed) {
        uint160 startPrice =
            InitialPriceCalculator.calculateInitialSqrtPriceX96(tokenA, tokenB, amountADesired, amountBDesired);
        return IMemeverseSwapRouter(swapRouter)
            .createPoolAndAddLiquidity(
                tokenA, tokenB, amountADesired, amountBDesired, startPrice, recipient, block.timestamp
            );
    }

    function _buildBootstrapPolPlan(uint256 normalFunds, uint256 totalPOL, uint256 totalLeveragedDebt)
        internal
        pure
        returns (IMemeverseLauncher.BootstrapPolPlan memory plan)
    {
        uint256 totalGenesisFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        if (totalGenesisFunds == 0) return plan;

        plan.polForPolUAsset = FullMath.mulDiv(totalPOL, 2, 7);
        uint256 polToSplit = FullMath.mulDiv(totalPOL, 3, 7);
        plan.normalPolToSplit = FullMath.mulDiv(polToSplit, normalFunds, totalGenesisFunds);
        plan.leveragedPolToSplit = polToSplit - plan.normalPolToSplit;
        plan.polForPtPol = totalPOL - plan.polForPolUAsset - polToSplit;
    }

    function _recordBootstrapResidualClaims(
        uint256 verseId,
        uint256 residualPOL,
        uint256 residualPT,
        uint256 totalLeveragedDebt,
        uint256 totalGenesisFunds
    ) internal {
        IMemeverseLauncher.BootstrapResidualClaims storage claims =
            memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        // Residual tokens follow the same normal/leveraged funding split as auxiliary LP ownership.
        uint256 leveragedResidualPOL = FullMath.mulDiv(residualPOL, totalLeveragedDebt, totalGenesisFunds);
        uint256 leveragedResidualPT = FullMath.mulDiv(residualPT, totalLeveragedDebt, totalGenesisFunds);
        claims.leveragedResidualPOL = leveragedResidualPOL;
        claims.normalResidualPOL = residualPOL - leveragedResidualPOL;
        claims.leveragedResidualPT = leveragedResidualPT;
        claims.normalResidualPT = residualPT - leveragedResidualPT;
    }

    function _settlePreorder(uint256 verseId, PoolKey memory poolKey, address uAsset, address memecoin) internal {
        IMemeverseLauncher.PreorderState storage preorderState = memeverseLauncherStorage.preorderStates[verseId];
        uint256 totalFunds = preorderState.totalFunds;
        if (totalFunds == 0) return;

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == uAsset;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // Settlement goes through the hook's dedicated preorder-settlement path so preorder accounting stays isolated from public swap flow.
        BalanceDelta delta = IMemeverseUniswapHook(memeverseLauncherStorage.memeverseUniswapHook)
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                key: poolKey,
                params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(totalFunds), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
                recipient: address(this)
            })
            );

        uint256 settledMemecoin = _deltaAmountForToken(delta, memecoin, poolKey);
        // Later vesting claims split this aggregate fill pro rata by each user's preorder funds and anchor to this timestamp.
        preorderState.settledMemecoin = settledMemecoin;
        preorderState.settlementTimestamp = uint40(block.timestamp);
    }

    function _deltaAmountForToken(BalanceDelta delta, address token, PoolKey memory poolKey)
        internal
        pure
        returns (uint256 amount)
    {
        if (Currency.unwrap(poolKey.currency0) == token) {
            int128 amount0 = delta.amount0();
            return amount0 > 0 ? uint256(uint128(amount0)) : 0;
        }

        if (Currency.unwrap(poolKey.currency1) == token) {
            int128 amount1 = delta.amount1();
            return amount1 > 0 ? uint256(uint128(amount1)) : 0;
        }

        return 0;
    }
}
