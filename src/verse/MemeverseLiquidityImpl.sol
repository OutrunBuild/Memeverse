// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
/// @dev Binds the launcher's ERC-7201 namespace, so under delegatecall `msg.sender` is the facade's
///      original caller (user or POLendUpgradeable) and `address(this)` is the launcher proxy; no
///      initializer, owner, or own state, and direct calls revert via the inherited `onlyDelegatecall`
///      guard. Nested types live in IMemeverseLauncher and are qualified as `IMemeverseLauncher.X` below.
contract MemeverseLiquidityImpl layout at erc7201("outrun.storage.MemeverseLauncher") is TokenHelper, DelegatecallOnly {
    using PoolIdLibrary for PoolKey;

    MemeverseLauncherStorage private memeverseLauncherStorage;

    // =========================================================================================================
    // Bootstrap liquidity
    // =========================================================================================================

    /// See `IMemeverseLiquidityImpl.deployBootstrapLiquidity` for the full facade-facing documentation.
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
        // `fundBasedAmount` is memecoins per raw unit of `uAsset` (bakes decimals scale — see
        // `MemeverseLauncherUpgradeable.sol:setFundMetaData` and `docs/spec/verse/config-matrix.md`);
        // non-credit genesis intentionally supports arbitrary decimals, correct per-raw-unit calibration
        // is operator responsibility.
        uint256 mainPoolMemecoinBudget =
            mainPoolUAssetBudget * memeverseLauncherStorage.fundMetaDatas[uAsset].fundBasedAmount;
        _safeApprove(memecoin, swapRouter, mainPoolMemecoinBudget);
        // hook uAsset allowance is now handled per-settlement in _settlePreorder with exact amount.

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

        // Tail revocation: clear residual router allowances after bootstrap (uAsset cross-verse, memecoin per-verse).
        if (uAsset != NATIVE) _safeApprove(uAsset, swapRouter, 0);
        if (memecoin != NATIVE) _safeApprove(memecoin, swapRouter, 0);
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
        // `InitialPriceCalculator` is intentionally pure and assumes 18-decimal-equivalent raw amounts
        // (see its NatSpec "under the 18-decimal token assumption"). Price is derived from the raw
        // `mainPoolMemecoinBudget` / `mainPoolUAssetBudget` ratio, so `fundBasedAmount` must already
        // encode the uAsset's decimals scale to achieve the intended economic price.
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
        uint256 totalLeveragedDebt
    ) internal returns (uint256 polUAssetUsed, uint256 ptUAssetUsed, address yt) {
        _safeApprove(pol, swapRouter, plan.polForPolUAsset + plan.polForPtPol);

        uint256 polUsedForPolUAsset;
        address pt;
        (polUAssetUsed, polUsedForPolUAsset, pt, yt) = _bootstrapPOLPool(
            verseId, uAsset, pol, swapRouter, _polSplitter, plan, mainPoolPOLRawAmount, mainPoolUAssetUsed
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

        // Clear residual pol->router allowance after auxiliary pools (pol is per-verse, hygiene).
        if (pol != NATIVE) _safeApprove(pol, swapRouter, 0);
    }

    function _bootstrapPOLPool(
        uint256 verseId,
        address uAsset,
        address pol,
        address swapRouter,
        address _polSplitter,
        IMemeverseLauncher.BootstrapPolPlan memory plan,
        uint256 mainPoolPOLRawAmount,
        uint256 mainPoolUAssetUsed
    ) internal returns (uint256 polUAssetUsed, uint256 polUsedForPolUAsset, address pt, address yt) {
        // Protocol self-mint of the bootstrap POL supply (the POL raw amount backing the main pool): POL is
        // minted to this contract rather than a user to seed the POL/uAsset and PT auxiliary pools below,
        // before any user-facing POL minting (mintPOLToken). mainPoolPOLRawAmount is the main-pool LP raw
        // amount, so this mints POL 1:1 with that LP — redeem later burns POL for the same LP amount
        // (see redeemMemecoinLiquidity); do not scale the mint (it must equal the LP added).
        IPol(pol).mint(address(this), mainPoolPOLRawAmount);

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
        uint256 totalToSplit = plan.normalPolToSplit + plan.leveragedPolToSplit;
        if (pol != NATIVE && totalToSplit != 0) _safeApprove(pol, _polSplitter, totalToSplit);
        (uint256 totalPT,) = IPOLSplitter(_polSplitter).split(verseId, totalToSplit);
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

        // Clear per-verse pol->splitter and pt->router allowances after PT pools.
        if (pol != NATIVE) _safeApprove(pol, _polSplitter, 0);
        if (pt != NATIVE) _safeApprove(pt, swapRouter, 0);

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
            // Clear exact polend allowance after funding (normally consumed, revoke for hygiene).
            if (uAsset != NATIVE) _safeApprove(uAsset, _polend, 0);
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
        // Use exact allowance for hook settlement (was _safeApproveInf). totalFunds is known.
        if (uAsset != NATIVE) _safeApprove(uAsset, hookAddress, totalFunds);
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
        // Clear exact hook allowance after settlement (no-op if reverted).
        if (uAsset != NATIVE) _safeApprove(uAsset, hookAddress, 0);

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

    /// See `IMemeverseLiquidityImpl.mintPOLToken` for the full facade-facing documentation.
    /// @dev The facade performs outer validation (verseId / pause / input non-zero / stage >= Locked) and
    ///      reads verse.uAsset / verse.memecoin / verse.pol before delegating.
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

    /// See `IMemeverseLiquidityImpl.redeemAuxiliaryLiquidity` for the full facade-facing documentation.
    /// @dev Redeems POL/uAsset, PT/uAsset, and PT/POL LP plus the caller's normal residual-claim slice.
    ///      The facade keeps only the outer `versIdValidate` / `whenNotPaused` guards; this sibling owns
    ///      the `Stage.Unlocked` check, the redemption state transition, every token movement, and the
    ///      `RedeemAuxiliaryLiquidity` emit.
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
        polUAssetLpAmount = FullMath.mulDiv(liq.polUAssetLpAmount, userFund, normalFunds);
        ptUAssetLpAmount = FullMath.mulDiv(liq.ptUAssetLpAmount, userFund, normalFunds);
        ptPolLpAmount = FullMath.mulDiv(liq.ptPolLpAmount, userFund, normalFunds);
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

    /// See `IMemeverseLiquidityImpl.settleLeveragedAuxiliaryLiquidity` for the full facade-facing documentation.
    /// @dev Removes the leveraged LP share, consumes the leveraged residual claims, and forwards all
    ///      proceeds to POLendUpgradeable. The facade keeps the `msg.sender == polend` + `Stage.Unlocked`
    ///      guards on the public ABI; under delegatecall `msg.sender` here is POLendUpgradeable (the
    ///      trusted caller). No outer `whenNotPaused` (mirrors the facade).
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

    /**
     * @dev Leveraged-side auxiliary liquidity removal — intentional 0,0 zero slippage (Accepted Risk, not a defect):
     * Liveness over precision tradeoff. Settlement is an internal protocol path with no user-supplied amountMin;
     * the 5-step atomic unlock _capture -> stage=Unlocked -> settle -> executeGlobalSettlement(0,0) -> write resumeTime [INV-07A]
     * executes remove before resumeTime is written, while the in-transaction quote is already polluted by the
     * preceding public swap. A tight lower bound (95%) would let price pushing grief the flow into
     * persistent TooMuchSlippage reverts that roll back Locked->Unlocked (DOS).
     * Using 0 guarantees unlock liveness; the price-push shortfall is bounded by settlementDustReserve [INV-13].
     * The trailing 24h publicSwapResumeTime blocks atomic sandwich attacks; single-leg pushing is grief-only, not profitable.
     * Monitor GlobalSettlementExecuted.totalRecoveredUAsset vs debt; no defect is declared.
     */
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
        // Internal settlement intentionally uses 0,0 — see function NatSpec above.
        polUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pol), Currency.wrap(uAsset), polUAssetLp, swapRouter, polend_, 0, 0, block.timestamp
        );
        ptUAssetDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pt), Currency.wrap(uAsset), ptUAssetLp, swapRouter, polend_, 0, 0, block.timestamp
        );
        ptPolDelta = _removeAuxiliaryLiquidityIfNonZero(
            Currency.wrap(pt), Currency.wrap(pol), ptPolLp, swapRouter, polend_, 0, 0, block.timestamp
        );
    }

    /**
     * @dev Auxiliary liquidity removal helper — leveraged settlement path always passes 0,0; Route-side
     * TooMuchSlippage checks are intentionally bypassed to preserve liveness, see _removeLeveragedAuxiliaryLiquidity NatSpec.
     * @param amount0Min/amount1Min Fixed to 0 for leveraged settlement; caller-supplied for normal paths.
     */
    function _removeAuxiliaryLiquidityIfNonZero(
        Currency currency0,
        Currency currency1,
        uint128 liquidity,
        address swapRouter,
        address recipient,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal returns (BalanceDelta delta) {
        if (liquidity == 0) return delta;

        return IMemeverseSwapRouter(swapRouter)
            .removeLiquidity(currency0, currency1, liquidity, amount0Min, amount1Min, recipient, deadline);
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

    /// See `IMemeverseLiquidityImpl.redeemMemecoinLiquidity` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `versIdValidate` + `Stage.Unlocked` guards (and intentionally omits
    ///      `whenNotPaused`); this sibling owns the input-non-zero check, POL burn, LP balance check, and
    ///      unwrap/transfer. The 1:1 LP amount equals the burned POL amount by main-pool construction.
    ///      Deprecated: the 3-arg overload keeps zero-slippage unwrap which is sandwichable after the protection
    ///      window. New callers must use the 6-arg overload with `amount0Min`/`amount1Min`/`deadline`.
    ///      This overload now reverts on `unwrap==true` to force migration to the slippage-protected path.
    function redeemMemecoinLiquidity(uint256 verseId, uint256 amountInPOL, bool unwrap)
        external
        onlyDelegatecall
        returns (uint256 amountInLP)
    {
        // Force unwrap callers to use the slippage-protected 6-arg overload.
        // The zero-slippage path is kept only for `unwrap==false` (LP transfer) which is not price-sensitive.
        require(!unwrap, IMemeverseLauncher.SlippageProtectionRequired());

        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(amountInPOL != 0, IMemeverseLauncher.ZeroInput());

        require(verse.currentStage == IMemeverseLauncher.Stage.Unlocked, IMemeverseLauncher.NotUnlockedStage());

        IPol(verse.pol).burn(msg.sender, amountInPOL);

        amountInLP = amountInPOL;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address lpToken = _pairLpToken(verse.memecoin, verse.uAsset, swapRouter);
        require(IERC20(lpToken).balanceOf(address(this)) >= amountInLP, IMemeverseLauncher.InsufficientLPBalance());
        emit IMemeverseLauncher.RedeemMemecoinLiquidity(verseId, msg.sender, amountInLP);
        _transferOut(lpToken, msg.sender, amountInLP);
    }

    /// See `IMemeverseLiquidityImpl.redeemMemecoinLiquidity` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `versIdValidate` + `Stage.Unlocked` guards (and intentionally omits
    ///      `whenNotPaused`); this sibling owns the input-non-zero check, POL burn, LP balance check, and
    ///      unwrap/transfer.
    function redeemMemecoinLiquidity(
        uint256 verseId,
        uint256 amountInPOL,
        bool unwrap,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external onlyDelegatecall returns (uint256 amountInLP) {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(amountInPOL != 0, IMemeverseLauncher.ZeroInput());

        require(verse.currentStage == IMemeverseLauncher.Stage.Unlocked, IMemeverseLauncher.NotUnlockedStage());

        IPol(verse.pol).burn(msg.sender, amountInPOL);

        amountInLP = amountInPOL;
        address swapRouter = memeverseLauncherStorage.memeverseSwapRouter;
        address lpToken = _pairLpToken(verse.memecoin, verse.uAsset, swapRouter);
        require(IERC20(lpToken).balanceOf(address(this)) >= amountInLP, IMemeverseLauncher.InsufficientLPBalance());
        emit IMemeverseLauncher.RedeemMemecoinLiquidity(verseId, msg.sender, amountInLP);
        if (!unwrap) {
            _transferOut(lpToken, msg.sender, amountInLP);
        } else {
            _safeApprove(lpToken, swapRouter, amountInLP);
            _removeAuxiliaryLiquidityIfNonZero(
                Currency.wrap(verse.memecoin),
                Currency.wrap(verse.uAsset),
                uint128(amountInLP),
                swapRouter,
                msg.sender,
                amount0Min,
                amount1Min,
                deadline
            );
        }
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
