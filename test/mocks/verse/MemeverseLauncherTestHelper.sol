// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StorageSlotPrimitives} from "../StorageSlotPrimitives.sol";
import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../../../src/polend/interfaces/IPOLSplitter.sol";
import {IPol} from "../../../src/token/interfaces/IPol.sol";
import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemecoin} from "../../../src/token/interfaces/IMemecoin.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";
import {InitialPriceCalculator} from "../../../src/verse/libraries/InitialPriceCalculator.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Standalone white-box accessor for MemeverseLauncherUpgradeable proxy storage.
///         Does not inherit any src/ contract. Reads/writes proxy storage slots via vm.load/vm.store.
///         Your test contract should inherit this helper (`is Test, MemeverseLauncherTestHelper`).
abstract contract MemeverseLauncherTestHelper is StorageSlotPrimitives {
    // ── Internal struct used by forceDeployLiquidity ──

    struct BootstrapPolPlan {
        uint256 polForPolUAsset;
        uint256 normalPolToSplit;
        uint256 leveragedPolToSplit;
        uint256 polForPtPol;
    }

    // Storage layout mirrors MemeverseLauncherStorage (src/verse/MemeverseLauncherUpgradeable.sol:64-95).
    // Slot offsets below correspond to field positions in that struct.
    // Memeverse sub-struct layout: slots 0-3 = string offsets, slot+4 = uAsset|currentStage|flashGenesis (packed),
    //   slots 5-9 = addresses, 10 = endTime|unlockTime, 11 = omnichainIds length.

    bytes32 internal constant LAUNCHER_SLOT = 0xe4d68b4f0bdabf27c869795dba7c9a87fd97b24006928b28f58769be5bd8f500;

    // Struct field slot offsets — each number corresponds to the field position in the struct above
    uint256 internal constant OFF_POLEND = 7;
    uint256 internal constant OFF_POL_SPLITTER = 8;
    uint256 internal constant OFF_POL_TO_IDS = 13;
    uint256 internal constant OFF_MEMECOIN_TO_IDS = 14;
    uint256 internal constant OFF_MEMEVERSES = 15;
    uint256 internal constant OFF_FUND_META_DATAS = 16;
    uint256 internal constant OFF_TOTAL_NORMAL_FUNDS = 17;
    uint256 internal constant OFF_PREORDER_STATES = 18;
    uint256 internal constant OFF_AUX_LIQUIDITIES = 19;
    uint256 internal constant OFF_BOOTSTRAP_CLAIMS = 20;
    uint256 internal constant OFF_TOTAL_NORMAL_YT = 21;
    uint256 internal constant OFF_USER_GENESIS = 23;
    uint256 internal constant OFF_USER_PREORDER = 24;
    uint256 internal constant OFF_NORMAL_FEES = 26;
    uint256 internal constant OFF_PENDING_GOV_FEE = 28;

    // ── Slot computation helpers ──

    /// @dev Slot for mapping(uint256 => T) at struct field offset fieldOffset with key
    function _mappingSlot(uint256 fieldOffset, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(LAUNCHER_SLOT) + fieldOffset)));
    }

    /// @dev Slot for mapping(uint256 => mapping(address => T))
    function _nestedMappingSlot(uint256 fieldOffset, uint256 key1, address key2) internal pure returns (bytes32) {
        return keccak256(abi.encode(key2, _mappingSlot(fieldOffset, key1)));
    }

    /// @dev mapping(address => T) slot
    function _mappingAddrSlot(uint256 fieldOffset, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(LAUNCHER_SLOT) + fieldOffset)));
    }

    // ── Read methods ──

    /// @notice Read preorderStates[verseId] from proxy (mirrors TestBase.getPreorderStateForTest)
    function getPreorderStateForTest(address proxy, uint256 verseId)
        public
        view
        returns (uint256 totalFunds, uint256 settledMemecoin, uint40 settlementTimestamp)
    {
        bytes32 base = _mappingSlot(OFF_PREORDER_STATES, verseId);
        totalFunds = uint256(_loadSlot(proxy, base));
        settledMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(base) + 1)));
        settlementTimestamp = uint40(uint256(_loadSlot(proxy, bytes32(uint256(base) + 2))));
    }

    /// @notice Read claimable preorder memecoin after vesting from proxy
    ///         mirrors MemeverseLauncherUpgradeable.sol:435-465, uses FullMath.mulDiv
    function claimablePreorderMemecoinForTest(address proxy, uint256 verseId, address account)
        public
        view
        returns (uint256 amount)
    {
        // Skip _versIdValidate and currentStage checks — invalid verseId yields totalFunds=0, returns 0

        // — PreorderState storage preorderState = $.preorderStates[verseId] —
        bytes32 preorderBase = _mappingSlot(OFF_PREORDER_STATES, verseId);
        uint256 totalFunds = uint256(_loadSlot(proxy, preorderBase));
        uint256 settledMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(preorderBase) + 1)));
        uint40 settlementTimestamp = uint40(uint256(_loadSlot(proxy, bytes32(uint256(preorderBase) + 2))));

        if (settlementTimestamp == 0) return 0;

        // — PreorderData storage preorderData = $.userPreorderData[verseId][account] —
        bytes32 preorderDataBase = _nestedMappingSlot(OFF_USER_PREORDER, verseId, account);
        uint256 userFunds = uint256(_loadSlot(proxy, preorderDataBase));
        uint256 claimedMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(preorderDataBase) + 1)));

        if (userFunds == 0 || totalFunds == 0) return 0;

        // — Vesting calculation (mirrors MemeverseLauncherUpgradeable.sol:454-465) —
        uint256 purchasedMemecoin = FullMath.mulDiv(settledMemecoin, userFunds, totalFunds);
        if (purchasedMemecoin <= claimedMemecoin) return 0;

        uint256 vestingDuration = uint256(_loadSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + 11)));
        uint256 elapsed = block.timestamp > settlementTimestamp ? block.timestamp - settlementTimestamp : 0;
        if (elapsed >= vestingDuration) {
            return purchasedMemecoin - claimedMemecoin;
        }

        uint256 vested = FullMath.mulDiv(purchasedMemecoin, elapsed, vestingDuration);
        if (vested <= claimedMemecoin) return 0;
        return vested - claimedMemecoin;
    }

    // ── Write methods — simple fields ──

    function setPolendForTest(address proxy, address _polend) internal {
        _writeSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + OFF_POLEND), bytes32(uint256(uint160(_polend))));
    }

    function setPolSplitterForTest(address proxy, address _polSplitter) internal {
        _writeSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + OFF_POL_SPLITTER), bytes32(uint256(uint160(_polSplitter))));
    }

    function setGenesisFundForTest(address proxy, uint256 verseId, uint256 amount) internal {
        _writeSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_FUNDS, verseId), bytes32(amount));
    }

    function setTotalNormalClaimableYTForTest(address proxy, uint256 verseId, uint256 amount) internal {
        _writeSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_YT, verseId), bytes32(amount));
    }

    function setVerseIdByMemecoinForTest(address proxy, address memecoin, uint256 verseId) internal {
        _writeSlot(proxy, _mappingAddrSlot(OFF_MEMECOIN_TO_IDS, memecoin), bytes32(verseId));
    }

    // ── Write methods — struct fields ──

    function setUserGenesisDataForTest(
        address proxy,
        uint256 verseId,
        address account,
        uint256 genesisFund,
        bool isRefunded,
        bool isRedeemed
    ) internal {
        bytes32 base = _nestedMappingSlot(OFF_USER_GENESIS, verseId, account);
        // Packed single slot (per GenesisData): genesisFund uint128 (bytes 0-15) | isRefunded (byte 16) | isRedeemed (byte 17)
        _writeSlot(
            proxy,
            base,
            bytes32(genesisFund | (uint256(isRefunded ? 1 : 0) << 128) | (uint256(isRedeemed ? 1 : 0) << 136))
        );
    }

    function setUserPreorderDataForTest(
        address proxy,
        uint256 verseId,
        address account,
        uint256 funds,
        uint256 claimedMemecoin,
        bool isRefunded
    ) internal {
        bytes32 base = _nestedMappingSlot(OFF_USER_PREORDER, verseId, account);
        _writeSlot(proxy, base, bytes32(funds));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(claimedMemecoin));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(uint256(isRefunded ? 1 : 0)));
    }

    function setPreorderStateForTest(
        address proxy,
        uint256 verseId,
        uint256 totalFunds,
        uint256 settledMemecoin,
        uint40 settlementTimestamp
    ) internal {
        bytes32 base = _mappingSlot(OFF_PREORDER_STATES, verseId);
        _writeSlot(proxy, base, bytes32(totalFunds));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(settledMemecoin));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(uint256(settlementTimestamp)));
    }

    function setAuxiliaryLiquiditiesForTest(
        address proxy,
        uint256 verseId,
        uint256 polUAsset,
        uint256 ptUAsset,
        uint256 ptPol
    ) internal {
        bytes32 base = _mappingSlot(OFF_AUX_LIQUIDITIES, verseId);
        _writeSlot(proxy, base, bytes32(polUAsset));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(ptUAsset));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(ptPol));
    }

    function setBootstrapResidualClaimsForTest(
        address proxy,
        uint256 verseId,
        uint256 normalResidualPOL,
        uint256 normalResidualPT,
        uint256 leveragedResidualPOL,
        uint256 leveragedResidualPT
    ) internal {
        bytes32 base = _mappingSlot(OFF_BOOTSTRAP_CLAIMS, verseId);
        _writeSlot(proxy, base, bytes32(normalResidualPOL));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(normalResidualPT));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(leveragedResidualPOL));
        _writeSlot(proxy, bytes32(uint256(base) + 3), bytes32(leveragedResidualPT));
    }

    function setNormalFeeStateForTest(address proxy, uint256 verseId, uint256 accUAssetFee, uint256 accPTFee) internal {
        bytes32 base = _mappingSlot(OFF_NORMAL_FEES, verseId);
        _writeSlot(proxy, base, bytes32(accUAssetFee));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(accPTFee));
    }

    function setPendingAuxiliaryGovFeeForTest(address proxy, uint256 verseId, uint256 uFee, uint256 ptFee) internal {
        bytes32 base = _mappingSlot(OFF_PENDING_GOV_FEE, verseId);
        _writeSlot(proxy, base, bytes32(uFee));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(ptFee));
    }

    function setFundMetaDataForTest(address proxy, address uAsset, uint256 minTotalFund, uint256 fundBasedAmount)
        internal
    {
        bytes32 base = _mappingAddrSlot(OFF_FUND_META_DATAS, uAsset);
        _writeSlot(proxy, base, bytes32(minTotalFund));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(fundBasedAmount));
    }

    /// @notice Set commonly-used fields of Memeverse struct. Complex dynamic fields (name/symbol/uri/desc/omnichainIds)
    ///         are not written field-by-field here; use proxy's initialize() for full setup.
    function setMemeverseForTest(
        address proxy,
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        address yieldVault,
        address governor,
        address incentivizer,
        uint128 endTime,
        uint128 unlockTime,
        IMemeverseLauncher.Stage currentStage,
        bool flashGenesis
    ) internal {
        bytes32 base = _mappingSlot(OFF_MEMEVERSES, verseId);
        // slot+4 packs uAsset (bytes 0-19), currentStage (byte 20), flashGenesis (byte 21) per F-89 layout.
        _writeSlot(
            proxy,
            bytes32(uint256(base) + 4),
            bytes32(
                uint256(uint160(uAsset)) | (uint256(uint8(currentStage)) << 160)
                    | (flashGenesis ? uint256(1) << 168 : 0)
            )
        );
        _writeSlot(proxy, bytes32(uint256(base) + 5), bytes32(uint256(uint160(memecoin))));
        _writeSlot(proxy, bytes32(uint256(base) + 6), bytes32(uint256(uint160(pol))));
        _writeSlot(proxy, bytes32(uint256(base) + 7), bytes32(uint256(uint160(yieldVault))));
        _writeSlot(proxy, bytes32(uint256(base) + 8), bytes32(uint256(uint160(governor))));
        _writeSlot(proxy, bytes32(uint256(base) + 9), bytes32(uint256(uint160(incentivizer))));
        // endTime (uint128) and unlockTime (uint128) are packed into one slot
        _writeSlot(
            proxy,
            bytes32(uint256(base) + 10),
            bytes32(uint256(uint128(endTime)) | (uint256(uint128(unlockTime)) << 128))
        );
    }

    // ── Dynamic array fields ──

    /// @notice Set omnichainIds for a verse. Writes length at the array slot
    ///         and element data at keccak256(slot).
    function setOmnichainIdsForTest(address proxy, uint256 verseId, uint32[] memory chainIds) internal {
        bytes32 base = _mappingSlot(OFF_MEMEVERSES, verseId);
        bytes32 arraySlot = bytes32(uint256(base) + 11);
        // Write length
        _writeSlot(proxy, arraySlot, bytes32(chainIds.length));
        // Write each element
        bytes32 dataSlot = keccak256(abi.encode(arraySlot));
        for (uint256 i = 0; i < chainIds.length; i++) {
            _writeSlot(proxy, bytes32(uint256(dataSlot) + i), bytes32(uint256(chainIds[i])));
        }
    }

    // ── forceDeployLiquidity replica ──
    //
    // Full replica of MemeverseLauncherUpgradeable._deployLiquidity + call chain.
    // Because _deployLiquidity is internal, it cannot be called via proxy ABI.
    // This replicates its logic using vm.load/vm.store for proxy storage,
    // and direct external calls (router, hook, polend, splitter, pol, memecoin)
    // through the proxy via vm.prank.

    uint256 internal constant MAX_SUPPORTED_TOTAL_GENESIS_FUNDS = type(uint128).max;

    function forceDeployLiquidity(
        address proxy,
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address polendAddr,
        address polSplitterAddr
    ) internal {
        require(polendAddr != address(0) && polSplitterAddr != address(0), "Missing POLendUpgradeable or splitter");

        // Read storage
        uint256 normalFunds = uint256(_loadSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_FUNDS, verseId)));
        uint256 totalGenesisFunds = _checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 mainPoolUAssetBudget = FullMath.mulDiv(totalGenesisFunds, 7, 10);
        address swapRouter = address(uint160(uint256(_loadSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + 5)))));
        address hookAddress = address(uint160(uint256(_loadSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + 6)))));
        require(swapRouter != address(0) && hookAddress != address(0), "Missing router or hook");

        uint256 fundBasedAmount =
            uint256(_loadSlot(proxy, bytes32(uint256(_mappingAddrSlot(OFF_FUND_META_DATAS, uAsset)) + 1)));
        uint256 mainPoolMemecoinBudget = mainPoolUAssetBudget * fundBasedAmount;

        // _safeApprove(uAsset, swapRouter, totalGenesisFunds)
        _proxyApprove(proxy, uAsset, swapRouter, totalGenesisFunds);
        // _safeApprove(memecoin, swapRouter, mainPoolMemecoinBudget)
        _proxyApprove(proxy, memecoin, swapRouter, mainPoolMemecoinBudget);
        // _safeApproveInf(uAsset, hookAddress)
        _proxyApprove(proxy, uAsset, hookAddress, 0);
        _proxyApprove(proxy, uAsset, hookAddress, type(uint256).max);

        // == _createBootstrapPools ==
        // --- _createMainBootstrapPool ---
        // mint memecoin for main pool
        _proxyMint(proxy, memecoin, mainPoolMemecoinBudget);

        uint160 mainPoolStartPrice = InitialPriceCalculator.calculateInitialSqrtPriceX96(
            memecoin, uAsset, mainPoolMemecoinBudget, mainPoolUAssetBudget
        );
        vm.prank(proxy);
        (uint128 mainPoolLiquidity, PoolKey memory poolKey, uint256 mainPoolMemecoinUsed, uint256 mainPoolUAssetUsed) = IMemeverseSwapRouter(
                swapRouter
            )
            .createPoolAndAddLiquidity(
                memecoin,
                uAsset,
                mainPoolMemecoinBudget,
                mainPoolUAssetBudget,
                mainPoolStartPrice,
                proxy,
                block.timestamp
            );

        uint256 burnedMemecoin = mainPoolMemecoinBudget - mainPoolMemecoinUsed;
        if (burnedMemecoin != 0) {
            vm.prank(proxy);
            IMemecoin(memecoin).burn(burnedMemecoin);
        }

        // --- _settlePreorder ---
        // mainPoolPOLRawAmount = liquidity returned by router (represents POL-equivalent raw amount)
        uint128 mainPoolPOLRawAmount = mainPoolLiquidity;
        _settlePreorder(proxy, verseId, poolKey, uAsset, memecoin);

        // --- _buildBootstrapPolPlan ---
        BootstrapPolPlan memory plan = _buildBootstrapPolPlan(normalFunds, mainPoolPOLRawAmount, totalLeveragedDebt);

        // --- _bootstrapPOLAndAuxiliaryPools ---
        // approve pol for pol/uAsset + pt/pol pools
        _proxyApprove(proxy, pol, swapRouter, plan.polForPolUAsset + plan.polForPtPol);

        // --- _bootstrapPOLPool ---
        // mint POL for main pool backing
        vm.prank(proxy);
        IPol(pol).mint(proxy, mainPoolPOLRawAmount);
        vm.prank(proxy);
        IPol(pol).setPoolId(PoolIdLibrary.toId(poolKey));

        // get PT and YT addresses
        (address pt, address yt) = IPOLSplitter(polSplitterAddr).getPTAndYT(verseId);

        // record PT backing ratio
        vm.prank(proxy);
        IPOLSplitter(polSplitterAddr).recordPTBackingRatio(verseId, mainPoolUAssetUsed, mainPoolPOLRawAmount);

        // create POL/uAsset pool
        uint256 polUAssetRequired = FullMath.mulDiv(plan.polForPolUAsset, mainPoolUAssetUsed, mainPoolPOLRawAmount);
        uint160 polUAssetPrice =
            InitialPriceCalculator.calculateInitialSqrtPriceX96(pol, uAsset, plan.polForPolUAsset, polUAssetRequired);
        vm.prank(proxy);
        (uint128 polUAssetLpAmount,, uint256 polUsedForPolUAsset, uint256 polUAssetUsed) = IMemeverseSwapRouter(
                swapRouter
            )
            .createPoolAndAddLiquidity(
                pol, uAsset, plan.polForPolUAsset, polUAssetRequired, polUAssetPrice, proxy, block.timestamp
            );

        // write polUAssetLpAmount to auxiliaryLiquidities
        bytes32 auxBase = _mappingSlot(OFF_AUX_LIQUIDITIES, verseId);
        _writeSlot(proxy, auxBase, bytes32(uint256(polUAssetLpAmount)));

        // --- _bootstrapPTPools ---
        // approve pol infinite for splitter
        _proxyApprove(proxy, pol, polSplitterAddr, 0);
        _proxyApprove(proxy, pol, polSplitterAddr, type(uint256).max);

        // split POL into PT + YT
        vm.prank(proxy);
        (uint256 totalPT,) =
            IPOLSplitter(polSplitterAddr).split(verseId, plan.normalPolToSplit + plan.leveragedPolToSplit);

        // approve pt for router
        _proxyApprove(proxy, pt, swapRouter, totalPT);

        uint256 ptForPtUAsset = totalPT / 3;
        uint256 ptForPtPol = totalPT - ptForPtUAsset;

        // create PT/uAsset pool
        uint256 ptUAssetRequired = FullMath.mulDiv(ptForPtUAsset, mainPoolUAssetUsed, mainPoolPOLRawAmount);
        uint160 ptUAssetPrice =
            InitialPriceCalculator.calculateInitialSqrtPriceX96(pt, uAsset, ptForPtUAsset, ptUAssetRequired);
        vm.prank(proxy);
        (uint128 ptUAssetLpAmount,, uint256 ptUsedForPtUAsset, uint256 ptUAssetUsed) = IMemeverseSwapRouter(swapRouter)
            .createPoolAndAddLiquidity(
                pt, uAsset, ptForPtUAsset, ptUAssetRequired, ptUAssetPrice, proxy, block.timestamp
            );
        // write ptUAssetLpAmount
        _writeSlot(proxy, bytes32(uint256(auxBase) + 1), bytes32(uint256(ptUAssetLpAmount)));

        // create PT/pol pool
        uint160 ptPolPrice = InitialPriceCalculator.calculateInitialSqrtPriceX96(pt, pol, ptForPtPol, plan.polForPtPol);
        vm.prank(proxy);
        (uint128 ptPolLpAmount,, uint256 ptUsedForPtPol, uint256 polUsedForPtPol) = IMemeverseSwapRouter(swapRouter)
            .createPoolAndAddLiquidity(pt, pol, ptForPtPol, plan.polForPtPol, ptPolPrice, proxy, block.timestamp);
        // write ptPolLpAmount
        _writeSlot(proxy, bytes32(uint256(auxBase) + 2), bytes32(uint256(ptPolLpAmount)));

        // write totalNormalClaimableYT
        _writeSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_YT, verseId), bytes32(plan.normalPolToSplit));

        // --- _recordBootstrapResidualClaims ---
        uint256 residualPOL = plan.polForPolUAsset - polUsedForPolUAsset + plan.polForPtPol - polUsedForPtPol;
        uint256 residualPT = ptForPtUAsset - ptUsedForPtUAsset + ptForPtPol - ptUsedForPtPol;
        _recordBootstrapResidualClaims(proxy, verseId, residualPOL, residualPT, totalLeveragedDebt, totalGenesisFunds);

        // --- transfer leveraged YT to polend ---
        if (plan.leveragedPolToSplit != 0) {
            vm.prank(proxy);
            require(IERC20(yt).transfer(polendAddr, plan.leveragedPolToSplit), "YT transfer failed");
            vm.prank(proxy);
            IPOLend(polendAddr).recordLeveragedYT(verseId, yt, plan.leveragedPolToSplit);
        }

        // --- _handleBootstrapResiduals ---
        uint256 totalSpent = mainPoolUAssetUsed + polUAssetUsed + ptUAssetUsed;
        uint256 unusedBootstrapUAsset = totalSpent < totalGenesisFunds ? totalGenesisFunds - totalSpent : 0;
        _handleBootstrapResiduals(proxy, verseId, uAsset, memecoin, unusedBootstrapUAsset, burnedMemecoin, polendAddr);
    }

    function _settlePreorder(address proxy, uint256 verseId, PoolKey memory poolKey, address uAsset, address memecoin)
        internal
    {
        bytes32 preorderBase = _mappingSlot(OFF_PREORDER_STATES, verseId);
        uint256 totalFunds = uint256(_loadSlot(proxy, preorderBase));
        if (totalFunds == 0) return;

        address hookAddress = address(uint160(uint256(_loadSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + 6)))));
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == uAsset;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        vm.prank(proxy);
        BalanceDelta delta = IMemeverseUniswapHook(hookAddress)
            .executePreorderSettlement(
                IMemeverseUniswapHook.PreorderSettlementParams({
                key: poolKey,
                params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(totalFunds), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
                recipient: proxy
            })
            );

        uint256 settledMemecoin = _deltaAmountForToken(delta, memecoin, poolKey);
        // write settledMemecoin and settlementTimestamp
        _writeSlot(proxy, bytes32(uint256(preorderBase) + 1), bytes32(settledMemecoin));
        _writeSlot(proxy, bytes32(uint256(preorderBase) + 2), bytes32(uint256(uint40(block.timestamp))));
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

    function _buildBootstrapPolPlan(uint256 normalFunds, uint256 totalPOL, uint256 totalLeveragedDebt)
        internal
        pure
        returns (BootstrapPolPlan memory plan)
    {
        uint256 totalGenesisFunds = _checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        if (totalGenesisFunds == 0) return plan;

        plan.polForPolUAsset = FullMath.mulDiv(totalPOL, 2, 7);
        uint256 polToSplit = FullMath.mulDiv(totalPOL, 3, 7);
        plan.normalPolToSplit = FullMath.mulDiv(polToSplit, normalFunds, totalGenesisFunds);
        plan.leveragedPolToSplit = polToSplit - plan.normalPolToSplit;
        plan.polForPtPol = totalPOL - plan.polForPolUAsset - polToSplit;
    }

    function _recordBootstrapResidualClaims(
        address proxy,
        uint256 verseId,
        uint256 residualPOL,
        uint256 residualPT,
        uint256 totalLeveragedDebt,
        uint256 totalGenesisFunds
    ) internal {
        bytes32 claimsBase = _mappingSlot(OFF_BOOTSTRAP_CLAIMS, verseId);
        uint256 leveragedResidualPOL = FullMath.mulDiv(residualPOL, totalLeveragedDebt, totalGenesisFunds);
        uint256 leveragedResidualPT = FullMath.mulDiv(residualPT, totalLeveragedDebt, totalGenesisFunds);
        _writeSlot(proxy, claimsBase, bytes32(residualPOL - leveragedResidualPOL)); // normalResidualPOL
        _writeSlot(proxy, bytes32(uint256(claimsBase) + 1), bytes32(residualPT - leveragedResidualPT)); // normalResidualPT
        _writeSlot(proxy, bytes32(uint256(claimsBase) + 2), bytes32(leveragedResidualPOL)); // leveragedResidualPOL
        _writeSlot(proxy, bytes32(uint256(claimsBase) + 3), bytes32(leveragedResidualPT)); // leveragedResidualPT
    }

    function _handleBootstrapResiduals(
        address proxy,
        uint256 verseId,
        address uAsset,
        address memecoin,
        uint256 unusedBootstrapUAsset,
        uint256 burnedMemecoin,
        address polendAddr
    ) internal {
        // credited/treasuryExcess stay 0 when no unused uAsset is routed, so the single emit below
        // naturally reports (0, 0) for the unused-asset fields — both residual shapes share one emit site.
        uint256 credited;
        uint256 treasuryExcess;
        if (unusedBootstrapUAsset != 0) {
            (uint128 reserveBefore, uint128 maxReserve) = IPOLend(polendAddr).settlementDustStates(uAsset);
            uint256 capacity = maxReserve > reserveBefore ? uint256(maxReserve - reserveBefore) : 0;
            credited = unusedBootstrapUAsset < capacity ? unusedBootstrapUAsset : capacity;
            treasuryExcess = unusedBootstrapUAsset - credited;

            // reset + set approval
            _proxyApprove(proxy, uAsset, polendAddr, 0);
            _proxyApprove(proxy, uAsset, polendAddr, unusedBootstrapUAsset);

            vm.prank(proxy);
            IPOLend(polendAddr).fundSettlementDustReserve(uAsset, unusedBootstrapUAsset);
        }
        // Emit only when something actually happened: unused uAsset routed, or memecoin burned.
        if (unusedBootstrapUAsset != 0 || burnedMemecoin != 0) {
            emit IMemeverseLauncher.BootstrapUnusedAssetsHandled(
                verseId, uAsset, memecoin, unusedBootstrapUAsset, credited, treasuryExcess, burnedMemecoin
            );
        }
    }

    function _checkedTotalGenesisFunds(uint256 normalFunds, uint256 leveragedDebt)
        internal
        pure
        returns (uint256 totalFunds)
    {
        totalFunds = normalFunds + leveragedDebt;
        require(totalFunds <= MAX_SUPPORTED_TOTAL_GENESIS_FUNDS, "TotalGenesisFundsTooHigh");
    }

    function _proxyApprove(address proxy, address token, address spender, uint256 amount) internal {
        vm.prank(proxy);
        IERC20(token).approve(spender, amount);
    }

    function _proxyMint(address proxy, address memecoin, uint256 amount) internal {
        vm.prank(proxy);
        IMemecoin(memecoin).mint(proxy, amount);
    }
}
