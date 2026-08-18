// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {DelegatecallOnly} from "../common/access/DelegatecallOnly.sol";
import {InitialPriceCalculator} from "./libraries/InitialPriceCalculator.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";
import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {IPol} from "../token/interfaces/IPol.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemeverseSwapRouter} from "../swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../swap/interfaces/IMemeverseUniswapHook.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";

/// @title MemeverseLiquidityImpl
/// @notice Delegatecall-only sibling that owns every liquidity-side flow for MemeverseLauncherUpgradeable: bootstrap
///         liquidity deployment, POL minting, auxiliary-liquidity redemption, leveraged auxiliary settlement,
///         and memecoin-side liquidity redemption.
/// @dev Binds the SAME ERC-7201 namespace as the launcher facade
///      (`erc7201("outrun.storage.MemeverseLauncher")`), so under delegatecall every storage read/write lands
///      on the launcher proxy's MemeverseLauncherStorage. The sibling has no initializer, no owner, no own
///      mutable state, and intentionally no `msg.sender == launcher` guard: under delegatecall `msg.sender` is
///      the facade's original caller (user or POLendUpgradeable), and `address(this)` is the launcher proxy. A direct
///      (non-delegatecall) call reverts via the inherited `onlyDelegatecall` guard (see `DelegatecallOnly`)
///      before any storage or router access, so the sibling is explicitly guarded.
///
///      Nested types and the Stage enum live in interface IMemeverseLauncher; this sibling only inherits
///      TokenHelper, so every reference below is qualified as `IMemeverseLauncher.X` (unlike the facade, which
///      inherits IMemeverseLauncher and uses bare names).
contract MemeverseLiquidityImpl layout at erc7201("outrun.storage.MemeverseLauncher") is TokenHelper, DelegatecallOnly {
    using PoolIdLibrary for PoolKey;

    /// @dev Same ERC-7201 namespace as the launcher facade; under delegatecall this reads/writes the proxy's
    ///      MemeverseLauncherStorage. Do NOT add an initializer, owner, or any setter.
    MemeverseLauncherStorage private memeverseLauncherStorage;

    // =========================================================================================================
    // Bootstrap liquidity
    // =========================================================================================================

    /**
     * @notice Bootstrap liquidity entrypoint. Invoked by the MemeverseLauncherUpgradeable facade (via the nested
     *         delegatecall site `_deployLiquidity`, reached from `MemeverseLaunchImpl.changeStage`) so it
     *         writes to the proxy's MemeverseLauncherStorage.
     * @dev Delegatecall-only is enforced by the inherited `onlyDelegatecall` guard (see `DelegatecallOnly`),
     *      which reverts on direct call before any storage access.
     */
    function deployBootstrapLiquidity(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) external onlyDelegatecall {
        require(_polend != address(0) && _polSplitter != address(0), IMemeverseLauncher.PermissionDenied());

        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalGenesisFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 mainPoolUAssetBudget = FullMath.mulDiv(totalGenesisFunds, 7, 10);
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address hookAddress = memeverseLauncherStorage.memeverseUniswapHook;

        MemeverseLauncherLib.validateSettlementWiring(swapRouter, hookAddress);
        _safeApprove(uAsset, swapRouter, totalGenesisFunds);
        // Compute the memecoin bootstrap budget once here and forward it; the main-pool helper used to re-derive
        // it via the same MUL on the (warm) fundBasedAmount slot, so computing once saves one redundant product.
        uint256 mainPoolMemecoinBudget =
            mainPoolUAssetBudget * memeverseLauncherStorage.fundMetaDatas[uAsset].fundBasedAmount;
        _safeApprove(memecoin, swapRouter, mainPoolMemecoinBudget);
        _safeApproveInf(uAsset, hookAddress);

        (uint256 mainPoolUAssetUsed, uint256 polUAssetUsed, uint256 ptUAssetUsed, uint256 burnedMemecoin) = _createBootstrapPools(
            verseId,
            uAsset,
            memecoin,
            pol,
            normalFunds,
            totalLeveragedDebt,
            mainPoolUAssetBudget,
            mainPoolMemecoinBudget,
            swapRouter,
            hookAddress,
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
        uint256 mainPoolMemecoinBudget,
        address swapRouter,
        address hookAddress,
        address _polSplitter,
        address _polend
    )
        internal
        returns (uint256 mainPoolUAssetUsed, uint256 polUAssetUsed, uint256 ptUAssetUsed, uint256 burnedMemecoin)
    {
        uint128 mainPoolPOLRawAmount;
        PoolKey memory poolKey;
        (mainPoolPOLRawAmount, poolKey, mainPoolUAssetUsed, burnedMemecoin) =
            _createMainBootstrapPool(memecoin, uAsset, mainPoolUAssetBudget, mainPoolMemecoinBudget, swapRouter);

        _settlePreorder(verseId, poolKey, uAsset, memecoin, hookAddress);
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
        uint256 mainPoolMemecoinBudget,
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
        // Protocol self-mint of the bootstrap POL supply (the POL raw amount backing the main pool): POL is
        // minted to this contract rather than a user to seed the POL/uAsset and PT auxiliary pools below,
        // before any user-facing POL minting (mintPOLToken). mainPoolPOLRawAmount is the main-pool LP raw
        // amount, so this mints POL 1:1 with that LP — redeem later burns POL for the same LP amount
        // (see redeemMemecoinLiquidity); do not scale the mint (it must equal the LP added).
        IPol(pol).mint(address(this), mainPoolPOLRawAmount);
        // Bind the Uniswap pool deployed during bootstrap as this POL token's canonical pool.
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
        // Split the minted PT asymmetrically: ~1/3 pairs with uAsset to expose a PT/uAsset price,
        // ~2/3 pairs with POL to deepen the PT/POL swap leg used by YT flash swaps.
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

        // POL bootstrap is split into thirds over seven parts (2/7 + 3/7 + 2/7): one part seeds the POL/uAsset
        // auxiliary pool, the largest part is split into normal vs leveraged PT shares, and the remainder seeds the
        // PT/POL pool. Using a single 7-denominator keeps all three buckets additive without dust.
        plan.polForPolUAsset = FullMath.mulDiv(totalPOL, 2, 7);
        uint256 polToSplit = FullMath.mulDiv(totalPOL, 3, 7);
        plan.normalPolToSplit = FullMath.mulDiv(polToSplit, normalFunds, totalGenesisFunds);
        plan.leveragedPolToSplit = polToSplit - plan.normalPolToSplit;
        // Final 2/7 absorbs any dust from the prior truncated divisions so every unit of POL is routed.
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

    function _settlePreorder(
        uint256 verseId,
        PoolKey memory poolKey,
        address uAsset,
        address memecoin,
        address hookAddress
    ) internal {
        IMemeverseLauncher.PreorderState storage preorderState = memeverseLauncherStorage.preorderStates[verseId];
        uint256 totalFunds = preorderState.totalFunds;
        if (totalFunds == 0) return;

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == uAsset;
        // Full-range limit is intentional: preorder settlement must fill the entire `totalFunds`, and completeness
        // is enforced cross-file via ExactInputPartialFill (SettlementFacet.sol::settlementUnlockCallback) — this
        // MIN/MAX is the v4 tick-range safety bound, not a slippage intent.
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // Settlement goes through the hook's dedicated preorder-settlement path so preorder accounting stays isolated from public swap flow.
        BalanceDelta delta = IMemeverseUniswapHook(hookAddress)
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                key: poolKey,
                params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(totalFunds), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
                recipient: address(this)
            })
            );

        uint256 settledMemecoin = _positiveDeltaAmount(
            delta, memecoin, Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)
        );
        // Later vesting claims split this aggregate fill pro rata by each user's preorder funds and anchor to this timestamp.
        preorderState.settledMemecoin = settledMemecoin;
        preorderState.settlementTimestamp = uint40(block.timestamp);
    }

    /// @dev Core: return the positive leg of `delta` for `token`, given the pool's ordered token0/token1.
    ///      Both `_settlePreorder` (via PoolKey currencies) and `_positiveDeltaAmountForToken` (via raw
    ///      addresses) funnel through here so the positive-delta extraction has one source of truth.
    function _positiveDeltaAmount(BalanceDelta delta, address token, address token0, address token1)
        internal
        pure
        returns (uint256 amount)
    {
        if (token == token0) {
            int128 amount0 = delta.amount0();
            return amount0 > 0 ? uint256(uint128(amount0)) : 0;
        }

        if (token == token1) {
            int128 amount1 = delta.amount1();
            return amount1 > 0 ? uint256(uint128(amount1)) : 0;
        }

        return 0;
    }

    // =========================================================================================================
    // POL minting
    // =========================================================================================================

    /**
     * @notice Collects uAsset/memecoin from the caller, adds liquidity via the verse router, mints POL to the
     *         caller, and refunds any unused input.
     * @dev Invoked via delegatecall by the facade's `mintPOLToken`. The facade performs outer validation
     *      (verseId / pause / input non-zero / stage >= Locked) and reads verse.uAsset / verse.memecoin /
     *      verse.pol before delegating. Under delegatecall `msg.sender` is the original caller (transfer-in
     *      payer, POL mint recipient, refund target) and `address(this)` is the launcher proxy.
     */
    function mintPOLToken(
        address uAsset,
        address memecoin,
        address pol,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    ) external onlyDelegatecall returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) {
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        _transferIn(uAsset, msg.sender, amountInUAssetDesired);
        _transferIn(memecoin, msg.sender, amountInMemecoinDesired);
        _safeApprove(uAsset, swapRouter, amountInUAssetDesired);
        _safeApprove(memecoin, swapRouter, amountInMemecoinDesired);
        // Two liquidity modes: `amountOutDesired == 0` spends up to the provided budgets (auto mode);
        // a non-zero target first quotes the exact token amounts, then adds with the quote as the budget.
        if (amountOutDesired == 0) {
            (amountInUAsset, amountInMemecoin, amountOut) = _mintPOLTokenWithAutoLiquidity(
                uAsset,
                memecoin,
                amountInUAssetDesired,
                amountInMemecoinDesired,
                amountInUAssetMin,
                amountInMemecoinMin,
                deadline,
                swapRouter
            );
        } else {
            (amountInUAsset, amountInMemecoin, amountOut) = _mintPOLTokenWithExactLiquidity(
                uAsset, memecoin, amountInUAssetDesired, amountInMemecoinDesired, amountOutDesired, deadline, swapRouter
            );
        }

        // Mint POL 1:1 with the main-pool LP just added: amountOut is the LP the router minted, and redeem
        // later burns POL for the same LP amount (see redeemMemecoinLiquidity). Do not scale this mint
        // (no fee/rounding) — POL supply must stay equal to the launcher's main-pool LP.
        IPol(pol).mint(msg.sender, amountOut);
        _refundMintPOLTokenInputs(
            uAsset, memecoin, amountInUAssetDesired, amountInMemecoinDesired, amountInUAsset, amountInMemecoin
        );
    }

    function _mintPOLTokenWithAutoLiquidity(
        address uAsset,
        address memecoin,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAssetMin,
        uint256 amountInMemecoinMin,
        uint256 deadline,
        address swapRouter
    ) internal returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) {
        (amountOut, amountInUAsset, amountInMemecoin) = IMemeverseSwapRouter(swapRouter)
            .addLiquidityDetailed(
                Currency.wrap(uAsset),
                Currency.wrap(memecoin),
                amountInUAssetDesired,
                amountInMemecoinDesired,
                amountInUAssetMin,
                amountInMemecoinMin,
                address(this),
                deadline
            );
        // Auto mode has no LP-output floor of its own: with caller-supplied min=0 the router may settle 0 LP
        // (dust budgets or extreme pool price), which would otherwise reach IPol.mint(0) and surface the
        // misleading ZeroInput instead of a slippage error. Mirror the exact-mode guard's TooMuchSlippage.
        if (amountOut == 0) revert IMemeverseUniswapHook.TooMuchSlippage();
    }

    function _mintPOLTokenWithExactLiquidity(
        address uAsset,
        address memecoin,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountOutDesired,
        uint256 deadline,
        address swapRouter
    ) internal returns (uint256 amountInUAsset, uint256 amountInMemecoin, uint256 amountOut) {
        require(amountOutDesired <= type(uint128).max, IMemeverseLauncher.InvalidLength());
        // Quote the smallest router-side budgets that should mint the requested LP amount at the current pool price.
        (uint256 quotedUAsset, uint256 quotedMemecoin) =
            IMemeverseSwapRouter(swapRouter).quoteExactAmountsForLiquidity(uAsset, memecoin, uint128(amountOutDesired));
        if (quotedUAsset > amountInUAssetDesired) {
            revert IMemeverseSwapRouter.InputAmountExceedsMaximum(quotedUAsset, amountInUAssetDesired);
        }
        if (quotedMemecoin > amountInMemecoinDesired) {
            revert IMemeverseSwapRouter.InputAmountExceedsMaximum(quotedMemecoin, amountInMemecoinDesired);
        }
        // Reuse the exact quote as the desired budget so any price move that under-mints reverts instead of silently
        // minting less POL than requested.
        (amountOut, amountInUAsset, amountInMemecoin) = IMemeverseSwapRouter(swapRouter)
            .addLiquidityDetailed(
                Currency.wrap(uAsset),
                Currency.wrap(memecoin),
                quotedUAsset,
                quotedMemecoin,
                0,
                0,
                address(this),
                deadline
            );
        if (amountOut < amountOutDesired) revert IMemeverseUniswapHook.TooMuchSlippage();
    }

    function _refundMintPOLTokenInputs(
        address uAsset,
        address memecoin,
        uint256 amountInUAssetDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUAsset,
        uint256 amountInMemecoin
    ) internal {
        uint256 uAssetRefund = amountInUAssetDesired - amountInUAsset;
        uint256 memecoinRefund = amountInMemecoinDesired - amountInMemecoin;
        if (uAssetRefund > 0) _transferOut(uAsset, msg.sender, uAssetRefund);
        if (memecoinRefund > 0) _transferOut(memecoin, msg.sender, memecoinRefund);
    }

    // =========================================================================================================
    // Auxiliary-liquidity redemption + leveraged settlement + memecoin-liquidity redemption
    // =========================================================================================================

    /**
     * @notice Redeems the caller's post-settlement auxiliary-liquidity share (POL/uAsset, PT/uAsset, PT/POL LP
     *         plus the caller's normal residual-claim slice).
     * @dev Invoked via delegatecall by the facade's `redeemAuxiliaryLiquidity`. The facade keeps only the outer
     *      `versIdValidate` / `whenNotPaused` guards; this sibling owns the `Stage.Unlocked` check, the redemption
     *      state transition, every token movement, and the `RedeemAuxiliaryLiquidity` emit (the facade emits
     *      nothing to avoid a double-emit under delegatecall). Under delegatecall
     *      `msg.sender` is the original caller (LP/residual recipient).
     */
    function redeemAuxiliaryLiquidity(uint256 verseId)
        external
        onlyDelegatecall
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Unlocked, IMemeverseLauncher.NotUnlockedStage());

        uint256 userFund = _redeemableGenesisFund(verseId, msg.sender);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];

        address _polSplitter = memeverseLauncherStorage.polSplitter;
        address pt = IPOLSplitter(_polSplitter).getPT(verseId);
        (polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount) =
            _auxiliaryLiquidityRedemptionAmounts(verseId, userFund, normalFunds);

        memeverseLauncherStorage.userGenesisData[verseId][msg.sender].isRedeemed = true;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        _transferRedeemedAuxiliaryLiquidity(
            verse.pol, verse.uAsset, pt, msg.sender, polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount, swapRouter
        );
        _transferNormalResidualClaims(verseId, normalFunds, verse.pol, pt, msg.sender, userFund);
        emit IMemeverseLauncher.RedeemAuxiliaryLiquidity(
            verseId, msg.sender, polUAssetLpAmount, ptUAssetLpAmount, ptPolLpAmount
        );
    }

    function _transferNormalResidualClaims(
        uint256 verseId,
        uint256 normalFunds,
        address pol,
        address pt,
        address recipient,
        uint256 userFund
    ) internal {
        IMemeverseLauncher.BootstrapResidualClaims storage claims =
            memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        uint256 polAmount = FullMath.mulDiv(claims.normalResidualPOL, userFund, normalFunds);
        uint256 ptAmount = FullMath.mulDiv(claims.normalResidualPT, userFund, normalFunds);
        if (polAmount != 0) _transferOut(pol, recipient, polAmount);
        if (ptAmount != 0) _transferOut(pt, recipient, ptAmount);
    }

    function _redeemableGenesisFund(uint256 verseId, address account) internal view returns (uint256 userFund) {
        IMemeverseLauncher.GenesisData storage genesisData = memeverseLauncherStorage.userGenesisData[verseId][account];
        userFund = genesisData.genesisFund;
        require(userFund > 0 && !genesisData.isRedeemed, IMemeverseLauncher.InvalidClaim());
    }

    function _auxiliaryLiquidityRedemptionAmounts(uint256 verseId, uint256 userFund, uint256 normalFunds)
        internal
        view
        returns (uint256 polUAssetLpAmount, uint256 ptUAssetLpAmount, uint256 ptPolLpAmount)
    {
        IMemeverseLauncher.AuxiliaryLiquidity storage liq = memeverseLauncherStorage.auxiliaryLiquidities[verseId];
        polUAssetLpAmount = liq.polUAssetLpAmount * userFund / normalFunds;
        ptUAssetLpAmount = liq.ptUAssetLpAmount * userFund / normalFunds;
        ptPolLpAmount = liq.ptPolLpAmount * userFund / normalFunds;
    }

    function _transferRedeemedAuxiliaryLiquidity(
        address pol,
        address uAsset,
        address pt,
        address recipient,
        uint256 polUAssetLpAmount,
        uint256 ptUAssetLpAmount,
        uint256 ptPolLpAmount,
        address swapRouter
    ) internal {
        if (polUAssetLpAmount != 0) {
            _transferOut(_pairLpToken(pol, uAsset, swapRouter), recipient, polUAssetLpAmount);
        }
        if (ptUAssetLpAmount != 0) _transferOut(_pairLpToken(pt, uAsset, swapRouter), recipient, ptUAssetLpAmount);
        if (ptPolLpAmount != 0) _transferOut(_pairLpToken(pt, pol, swapRouter), recipient, ptPolLpAmount);
    }

    /**
     * @notice Settles the leveraged auxiliary-liquidity portion on behalf of POLendUpgradeable: removes the leveraged LP
     *         share, consumes the leveraged residual claims, and forwards all proceeds to POLendUpgradeable.
     * @dev Invoked via delegatecall by the facade's `settleLeveragedAuxiliaryLiquidity`. The facade keeps the
     *      `msg.sender == polend` + `Stage.Unlocked` guards on the public ABI; under delegatecall `msg.sender`
     *      here is POLendUpgradeable (the trusted caller). No outer `whenNotPaused` (mirrors the facade).
     */
    function settleLeveragedAuxiliaryLiquidity(uint256 verseId)
        external
        onlyDelegatecall
        returns (uint256 polAmount, uint256 ptAmount, uint256 uAssetAmount)
    {
        address _polend = memeverseLauncherStorage.polend;
        require(msg.sender == _polend, IMemeverseLauncher.PermissionDenied());

        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Unlocked, IMemeverseLauncher.NotUnlockedStage());

        address pt = IPOLSplitter(memeverseLauncherStorage.polSplitter).getPT(verseId);
        uint128 polUAssetLp;
        uint128 ptUAssetLp;
        uint128 ptPolLp;
        uint256 residualPOL;
        uint256 residualPT;
        {
            uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
            uint256 totalLeveragedDebt = IPOLend(_polend).getTotalLeveragedDebt(verseId);
            uint256 totalFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
            (polUAssetLp, ptUAssetLp, ptPolLp, residualPOL, residualPT) =
                _consumeLeveragedAuxiliaryClaims(verseId, totalLeveragedDebt, totalFunds);
        }

        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address pol = verse.pol;
        address uAsset = verse.uAsset;
        if (polUAssetLp != 0) _safeApprove(_pairLpToken(pol, uAsset, swapRouter), swapRouter, polUAssetLp);
        if (ptUAssetLp != 0) _safeApprove(_pairLpToken(pt, uAsset, swapRouter), swapRouter, ptUAssetLp);
        if (ptPolLp != 0) _safeApprove(_pairLpToken(pt, pol, swapRouter), swapRouter, ptPolLp);

        (BalanceDelta polUAssetDelta, BalanceDelta ptUAssetDelta, BalanceDelta ptPolDelta) =
            _removeLeveragedAuxiliaryLiquidity(pol, uAsset, pt, swapRouter, _polend, polUAssetLp, ptUAssetLp, ptPolLp);

        polAmount = _positiveDeltaAmountForToken(polUAssetDelta, pol, pol, uAsset)
            + _positiveDeltaAmountForToken(ptPolDelta, pol, pt, pol);
        ptAmount = _positiveDeltaAmountForToken(ptUAssetDelta, pt, pt, uAsset)
            + _positiveDeltaAmountForToken(ptPolDelta, pt, pt, pol);
        uAssetAmount = _positiveDeltaAmountForToken(polUAssetDelta, uAsset, pol, uAsset)
            + _positiveDeltaAmountForToken(ptUAssetDelta, uAsset, pt, uAsset);
        if (residualPOL != 0) {
            polAmount += residualPOL;
            _transferOut(pol, _polend, residualPOL);
        }
        if (residualPT != 0) {
            ptAmount += residualPT;
            _transferOut(pt, _polend, residualPT);
        }
    }

    function _removeLeveragedAuxiliaryLiquidity(
        address pol,
        address uAsset,
        address pt,
        address swapRouter,
        address polend_,
        uint128 polUAssetLp,
        uint128 ptUAssetLp,
        uint128 ptPolLp
    ) internal returns (BalanceDelta polUAssetDelta, BalanceDelta ptUAssetDelta, BalanceDelta ptPolDelta) {
        // Rounded-down zero LP shares must not call router removal; default deltas remain zero.
        polUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pol), Currency.wrap(uAsset), polUAssetLp, swapRouter, polend_
        );
        ptUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pt), Currency.wrap(uAsset), ptUAssetLp, swapRouter, polend_
        );
        ptPolDelta =
            _removeAuxiliaryLiquidityIfNonZero(Currency.wrap(pt), Currency.wrap(pol), ptPolLp, swapRouter, polend_);
    }

    function _removeAuxiliaryLiquidityIfNonZero(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        address swapRouter,
        address recipient
    ) internal returns (BalanceDelta delta) {
        if (liquidity == 0) return delta;

        return IMemeverseSwapRouter(swapRouter)
            .removeLiquidity(currency0, currency1, liquidity, 0, 0, recipient, block.timestamp);
    }

    function _consumeLeveragedAuxiliaryClaims(uint256 verseId, uint256 totalLeveragedDebt, uint256 totalFunds)
        internal
        returns (uint128 polUAssetLp, uint128 ptUAssetLp, uint128 ptPolLp, uint256 residualPOL, uint256 residualPT)
    {
        IMemeverseLauncher.AuxiliaryLiquidity storage liq = memeverseLauncherStorage.auxiliaryLiquidities[verseId];
        polUAssetLp = uint128(FullMath.mulDiv(liq.polUAssetLpAmount, totalLeveragedDebt, totalFunds));
        ptUAssetLp = uint128(FullMath.mulDiv(liq.ptUAssetLpAmount, totalLeveragedDebt, totalFunds));
        ptPolLp = uint128(FullMath.mulDiv(liq.ptPolLpAmount, totalLeveragedDebt, totalFunds));

        liq.polUAssetLpAmount -= polUAssetLp;
        liq.ptUAssetLpAmount -= ptUAssetLp;
        liq.ptPolLpAmount -= ptPolLp;

        IMemeverseLauncher.BootstrapResidualClaims storage claims =
            memeverseLauncherStorage.bootstrapResidualClaims[verseId];
        residualPOL = claims.leveragedResidualPOL;
        residualPT = claims.leveragedResidualPT;
        // Consume leveraged residuals in the same state transition as LP shares to prevent double settlement.
        claims.leveragedResidualPOL = 0;
        claims.leveragedResidualPT = 0;
    }

    /**
     * @notice Redeems launcher-managed memecoin-side LP using POL, optionally unwrapping the LP into underlying
     *         assets through the verse router.
     * @dev Invoked via delegatecall by the facade's `redeemMemecoinLiquidity`. The facade keeps the outer
     *      `versIdValidate` + `Stage.Unlocked` guards (and intentionally omits `whenNotPaused`); this sibling owns
     *      the input-non-zero check, POL burn, LP balance check, and unwrap/transfer. POLendUpgradeable also reaches this
     *      entry through the facade callback ABI. Under delegatecall `msg.sender` is the original caller (POL
     *      burner, LP/refund recipient). The 1:1 LP amount equals the burned POL amount by main-pool construction.
     *      The POL burn is executed by the launcher proxy on the caller's behalf: callers must first approve the
     *      launcher proxy as a POL spender for at least `amountInPOL`, or POL's `_spendAllowance` reverts with
     *      `ERC20InsufficientAllowance`.
     */
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        onlyDelegatecall
        returns (uint256 amountInLP)
    {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(amountInPOL != 0, IMemeverseLauncher.ZeroInput());

        require(verse.currentStage == IMemeverseLauncher.Stage.Unlocked, IMemeverseLauncher.NotUnlockedStage());

        IPol(verse.pol).burn(msg.sender, amountInPOL);

        amountInLP = amountInPOL;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address lpToken = _pairLpToken(verse.memecoin, verse.uAsset, swapRouter);
        require(IERC20(lpToken).balanceOf(address(this)) >= amountInLP, IMemeverseLauncher.InsufficientLPBalance());
        if (!unwrap) {
            _transferOut(lpToken, msg.sender, amountInLP);
        } else {
            _safeApprove(lpToken, swapRouter, amountInLP);
            _removeAuxiliaryLiquidityIfNonZero(
                Currency.wrap(verse.memecoin), Currency.wrap(verse.uAsset), uint128(amountInLP), swapRouter, msg.sender
            );
        }
        emit IMemeverseLauncher.RedeemMemecoinLiquidity(verseId, msg.sender, amountInLP);
    }

    function _pairLpToken(address tokenA, address tokenB, address swapRouter) internal view returns (address lpToken) {
        return IMemeverseSwapRouter(swapRouter).lpToken(tokenA, tokenB);
    }

    function _positiveDeltaAmountForToken(BalanceDelta delta, address token, address tokenA, address tokenB)
        internal
        pure
        returns (uint256 amount)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _positiveDeltaAmount(delta, token, token0, token1);
    }
}
