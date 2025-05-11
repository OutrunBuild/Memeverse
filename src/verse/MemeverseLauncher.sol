// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import { IBurnable } from "../common/IBurnable.sol";
import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemecoin } from "../token/interfaces/IMemecoin.sol";
import { IOutrunAMMPair } from "../common/IOutrunAMMPair.sol";
import { OutrunAMMLibrary } from "../libraries/OutrunAMMLibrary.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IMemeLiquidProof } from "../token/interfaces/IMemeLiquidProof.sol";
import { IMemeverseCommonInfo } from "./interfaces/IMemeverseCommonInfo.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IMemeverseProxyDeployer } from "./interfaces/IMemeverseProxyDeployer.sol";
import { IMemeverseLiquidityRouter } from "../common/IMemeverseLiquidityRouter.sol";

/**
 * @title Trapping into the memeverse
 */
contract MemeverseLauncher is IMemeverseLauncher, TokenHelper, Pausable, Ownable {
    using OptionsBuilder for bytes;

    uint256 public constant RATIO = 10000;
    uint256 public constant SWAP_FEERATE = 100;

    address public liquidityRouter;
    address public outrunAMMFactory;
    address public localLzEndpoint;
    address public memeverseCommonInfo;
    address public yieldDispatcher;
    address public memeverseRegistrar;
    address public memeverseProxyDeployer;
    
    uint256 public executorRewardRate;
    uint128 public oftReceiveGasLimit;
    uint128 public yieldDispatcherGasLimit;

    mapping(address UPT => FundMetaData) public fundMetaDatas;
    mapping(address memecoin => uint256) public memecoinToIds;
    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => uint256) public totalClaimablePOLs;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;
    mapping(uint256 verseId => mapping(address account => uint256)) public toBeUnlockedCoins;
    mapping(uint256 verseId => mapping(uint256 provider => string)) public communitiesMap;     // provider -> 0:Website, 1:X, 2:Discord, 3:Telegram, >4:Others

    constructor(
        address _owner,
        address _outrunAMMFactory,
        address _liquidityRouter,
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _memeverseProxyDeployer,
        address _yieldDispatcher,
        address _memeverseCommonInfo,
        uint256 _executorRewardRate,
        uint128 _oftReceiveGasLimit,
        uint128 _yieldDispatcherGasLimit
    ) Ownable(_owner) {
        liquidityRouter = _liquidityRouter;
        outrunAMMFactory = _outrunAMMFactory;
        localLzEndpoint = _localLzEndpoint;
        memeverseRegistrar = _memeverseRegistrar;
        memeverseProxyDeployer = _memeverseProxyDeployer;
        memeverseCommonInfo = _memeverseCommonInfo;
        yieldDispatcher = _yieldDispatcher;
        executorRewardRate =_executorRewardRate;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;
    }

    /**
     * @notice Get the verse id by memecoin.
     * @param memecoin -The address of the memecoin.
     * @return verseId The verse id.
     */
    function getVerseIdByMemecoin(address memecoin) external view override returns (uint256 verseId) {
        verseId = memecoinToIds[memecoin];
    }

    /**
     * @notice Get the memeverse by verse id.
     * @param verseId - The verse id.
     * @return verse - The memeverse.
     */
    function getMemeverseByVerseId(uint256 verseId) external view override returns (Memeverse memory verse) {
        verse = memeverses[verseId];
    }

    /**
     * @notice Get the memeverse by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return verse - The memeverse.
     */
    function getMemeverseByMemecoin(address memecoin) external view override returns (Memeverse memory verse) {
        verse = memeverses[memecoinToIds[memecoin]];
    }

    /**
     * @notice Get the yield vault by verse id.
     * @param verseId - The verse id.
     * @return yieldVault - The yield vault.
     */
    function getYieldVaultByVerseId(uint256 verseId) external view override returns (address yieldVault) {
        yieldVault = memeverses[verseId].yieldVault;
    }

    /**
     * @notice Get the governor by verse id.
     * @param verseId - The verse id.
     * @return governor - The governor.
     */
    function getGovernorByVerseId(uint256 verseId) external view override returns (address governor) {
        governor = memeverses[verseId].governor;
    }

    /**
     * @dev Preview claimable POLs token of user after Genesis Stage 
     * @param verseId - Memeverse id
     * @return claimableAmount - The claimable amount.
     */
    function userClaimablePOLs(uint256 verseId) public view override returns (uint256 claimableAmount) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        uint256 totalFunds = genesisFunds[verseId].totalMemecoinFunds + genesisFunds[verseId].totalLiquidProofFunds;
        uint256 userFunds = userTotalFunds[verseId][msg.sender];
        uint256 totalPOLs = totalClaimablePOLs[verseId];
        claimableAmount = totalPOLs * userFunds / totalFunds;
    }

    /**
     * @dev Preview Genesis liquidity market maker fees for DAO Treasury (UPT) and Yield Vault(Memecoin)
     * @param verseId - Memeverse id
     * @return UPTFee - The UPT fee.
     * @return memecoinFee - The memecoin fee.
     */
    function previewGenesisMakerFees(uint256 verseId) public view override returns (uint256 UPTFee, uint256 memecoinFee) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address UPT = verse.UPT;
        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(outrunAMMFactory, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.previewMakerFee();
        address token0 = memecoinPair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;

        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(outrunAMMFactory, liquidProof, UPT, SWAP_FEERATE));
        (uint256 amount2, uint256 amount3) = liquidProofPair.previewMakerFee();
        address token2 = liquidProofPair.token0();
        UPTFee = token2 == UPT ? UPTFee + amount2 : UPTFee + amount3;
    }

    /**
     * @dev Quote the LZ fee for the redemption and distribution of fees
     * @param verseId - Memeverse id
     * @return lzFee - The LZ fee.
     * @notice The LZ fee is only charged when the governance chain is not the same as the current chain,
     *         and msg.value needs to be greater than the quoted lzFee for the redeemAndDistributeFees transaction.
     */
    function quoteDistributionLzFee(uint256 verseId) external view returns (uint256 lzFee) {
        Memeverse storage verse = memeverses[verseId];
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;
        
        (uint256 UPTFee, uint256 memecoinFee) = previewGenesisMakerFees(verseId);
        uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
        bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0);
        if (UPTFee != 0) {
            SendParam memory sendUPTParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(yieldDispatcher))),
                amountLD: UPTFee,
                minAmountLD: 0,
                extraOptions: yieldDispatcherOptions,
                composeMsg: abi.encode(verse.governor, "UPT"),
                oftCmd: abi.encode()
            });
            MessagingFee memory govMessagingFee = IOFT(verse.UPT).quoteSend(sendUPTParam, false);
            lzFee += govMessagingFee.nativeFee;
        }

        if (memecoinFee != 0) {
            SendParam memory sendMemecoinParam = SendParam({
                dstEid: govEndpointId,
                to: bytes32(uint256(uint160(yieldDispatcher))),
                amountLD: memecoinFee,
                minAmountLD: 0,
                extraOptions: yieldDispatcherOptions,
                composeMsg: abi.encode(verse.yieldVault, "Memecoin"),
                oftCmd: abi.encode()
            });
            MessagingFee memory memecoinMessagingFee = IOFT(verse.memecoin).quoteSend(sendMemecoinParam, false);
            lzFee += memecoinMessagingFee.nativeFee;
        }
    }

    /**
     * @dev Genesis memeverse by depositing UPT
     * @param verseId - Memeverse id
     * @param amountInUPT - Amount of UPT
     * @param user - Address of user participating in the genesis
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint256 amountInUPT, address user) external whenNotPaused override {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Genesis, NotGenesisStage());

        _transferIn(verse.UPT, msg.sender, amountInUPT);

        uint256 increasedMemecoinFund;
        uint256 increasedLiquidProofFund;
        unchecked {
            increasedLiquidProofFund = amountInUPT / 3;
            increasedMemecoinFund = amountInUPT - increasedLiquidProofFund;
        }

        GenesisFund storage genesisFund = genesisFunds[verseId];
        unchecked {
            genesisFund.totalMemecoinFunds += uint128(increasedMemecoinFund);
            genesisFund.totalLiquidProofFunds += uint128(increasedLiquidProofFund);
            userTotalFunds[verseId][user] += amountInUPT;
        }

        emit Genesis(verseId, user, increasedMemecoinFund, increasedLiquidProofFund);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     * @return currentStage - The current stage.
     */
    function changeStage(uint256 verseId) external whenNotPaused override returns (Stage currentStage) {
        uint256 currentTime = block.timestamp;
        Memeverse storage verse = memeverses[verseId];
        currentStage = verse.currentStage;
        require(currentStage != Stage.Refund && currentStage != Stage.Unlocked, ReachedFinalStage());

        if (currentStage == Stage.Genesis) {
            address UPT = verse.UPT;
            GenesisFund storage genesisFund = genesisFunds[verseId];
            uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
            uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
            bool meetMinTotalFund = totalMemecoinFunds + totalLiquidProofFunds >= fundMetaDatas[UPT].minTotalFund;
            uint256 endTime = verse.endTime;
            require(
                endTime != 0 && (currentTime > endTime || (verse.flashGenesis && meetMinTotalFund)), 
                StillInGenesisStage(endTime)
            );

            if (!meetMinTotalFund) {
                verse.currentStage = Stage.Refund;
                currentStage = Stage.Refund;
            } else {
                string memory name = verse.name;
                string memory symbol = verse.symbol;
                address memecoin = verse.memecoin;

                // Deploy POL
                address liquidProof = IMemeverseProxyDeployer(memeverseProxyDeployer).deployPOL(verseId);
                IMemeLiquidProof(liquidProof).initialize(
                    string(abi.encodePacked("POL-", name)), 
                    string(abi.encodePacked("POL-", symbol)), 
                    18, 
                    memecoin, 
                    address(this)
                );
                verse.liquidProof = liquidProof;

                // Deploy Memecoin Yield Vault and Memecoin DAO Governor on Governance Chain
                uint32 govChainId = verse.omnichainIds[0];
                uint256 proposalThreshold = IMemecoin(memecoin).totalSupply() / 50;
                address yieldVault;
                if (govChainId == block.chainid) {
                    yieldVault = IMemeverseProxyDeployer(memeverseProxyDeployer).deployYieldVault(verseId);
                    IMemecoinYieldVault(yieldVault).initialize(
                        string(abi.encodePacked("Staked ", name)),
                        string(abi.encodePacked("s", symbol)),
                        yieldDispatcher,
                        memecoin,
                        verseId
                    );
                    verse.governor = IMemeverseProxyDeployer(memeverseProxyDeployer).deployDAOGovernor(name, yieldVault, verseId, proposalThreshold);
                } else {
                    yieldVault = IMemeverseProxyDeployer(memeverseProxyDeployer).predictYieldVaultAddress(verseId);
                    verse.governor = IMemeverseProxyDeployer(memeverseProxyDeployer).computeDAOGovernorAddress(name, yieldVault, verseId, proposalThreshold);
                }
                verse.yieldVault = yieldVault;

                // Deploy memecoin liquidity
                uint256 memecoinAmount = genesisFunds[verseId].totalMemecoinFunds * fundMetaDatas[UPT].fundBasedAmount;
                IMemecoin(memecoin).mint(address(this), memecoinAmount);
                _safeApproveInf(UPT, liquidityRouter);
                _safeApproveInf(memecoin, liquidityRouter);
                (,, uint256 memecoinLiquidity) = IMemeverseLiquidityRouter(liquidityRouter).addExactTokensForLiquidity(
                    UPT,
                    memecoin,
                    SWAP_FEERATE,
                    totalMemecoinFunds,
                    memecoinAmount,
                    totalMemecoinFunds,
                    memecoinAmount,
                    address(this),
                    block.timestamp
                );

                // Mint liquidity proof token and deploy liquid proof liquidity
                IMemeLiquidProof(liquidProof).mint(address(this), memecoinLiquidity);
                _safeApproveInf(UPT, liquidityRouter);
                _safeApproveInf(liquidProof, liquidityRouter);
                uint256 liquidProofAmount = memecoinLiquidity / 4;
                IMemeverseLiquidityRouter(liquidityRouter).addExactTokensForLiquidity(
                    UPT,
                    liquidProof,
                    SWAP_FEERATE,
                    totalLiquidProofFunds,
                    liquidProofAmount,
                    totalLiquidProofFunds,
                    liquidProofAmount,
                    address(0),
                    block.timestamp
                );
                totalClaimablePOLs[verseId] = memecoinLiquidity - liquidProofAmount;

                verse.currentStage = Stage.Locked;
                currentStage = Stage.Locked;
            }
        } else if (currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            verse.currentStage = Stage.Unlocked;
            currentStage = Stage.Unlocked;
        }

        emit ChangeStage(verseId, currentStage);
    }

    /**
     * @dev Refund UPT after genesis Failed, total omnichain funds didn't meet the minimum funding requirement
     * @param verseId - Memeverse id
     */
    function refund(uint256 verseId) external whenNotPaused override returns (uint256 userFunds) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Refund, NotRefundStage());
        
        address msgSender = msg.sender;
        userFunds = userTotalFunds[verseId][msgSender];
        require(userFunds > 0, InsufficientUserFunds());
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(verse.UPT, msgSender, userFunds);
        
        emit Refund(verseId, msgSender, userFunds);
    }

    /**
     * @dev Claim POL tokens in stage Locked
     * @param verseId - Memeverse id
     */
    function claimPOLs(uint256 verseId) external whenNotPaused override returns (uint256 amount) {
        amount = userClaimablePOLs(verseId);
        require(amount != 0, NoPOLAvailable());

        address msgSender = msg.sender;
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(memeverses[verseId].liquidProof, msgSender, amount);
        
        emit ClaimLiquidProof(verseId, msgSender, amount);
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     * @param rewardReceiver - Address of executor reward receiver
     * @return govFee - The UPT fee.
     * @return memecoinFee - The memecoin fee.
     * @return executorReward  - The executor reward.
     * @notice Anyone who calls this method will be rewarded with executorReward.
     */
    function redeemAndDistributeFees(uint256 verseId, address rewardReceiver) external payable whenNotPaused override 
    returns (uint256 govFee, uint256 memecoinFee, uint256 executorReward) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address UPT = verse.UPT;
        // Memecoin pair
        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(outrunAMMFactory, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.claimMakerFee();
        address token0 = memecoinPair.token0();
        uint256 UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinFee = token0 == memecoin ? amount0 : amount1;

        // LiquidProof pair
        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(outrunAMMFactory, liquidProof, UPT, SWAP_FEERATE));
        (amount0, amount1) = liquidProofPair.claimMakerFee();
        token0 = liquidProofPair.token0();
        uint256 burnedUPT = token0 == UPT ? amount0 : amount1;
        uint256 burnedPOL = token0 == liquidProof ? amount0 : amount1;

        if (UPTFee == 0 && memecoinFee == 0) return (0, 0, 0);

        // Burn the UPT fee and liquidProof fee from liquidProof pair
        if (burnedUPT != 0) IBurnable(UPT).burn(burnedUPT);
        if (burnedPOL != 0) IBurnable(liquidProof).burn(burnedPOL);

        // Executor Reward
        unchecked {
            executorReward = UPTFee * executorRewardRate / RATIO;
            govFee = UPTFee - executorReward;
        }
        if (executorReward != 0) _transferOut(UPT, rewardReceiver, executorReward);
        
        uint32 govChainId = verse.omnichainIds[0];
        address governor = verse.governor;
        address yieldVault = verse.yieldVault;

        if(govChainId == block.chainid) {
            if (govFee != 0) {
                _transferOut(UPT, yieldDispatcher, govFee);
                ILayerZeroComposer(yieldDispatcher).lzCompose(UPT, bytes32(0), abi.encode(governor, false, govFee), address(0), "");
            }
            if (memecoinFee != 0) {
                _transferOut(memecoin, yieldDispatcher, memecoinFee);
                ILayerZeroComposer(yieldDispatcher).lzCompose(memecoin, bytes32(0), abi.encode(yieldVault, true, memecoinFee), address(0), "");
            }
        } else {
            uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
            
            bytes memory yieldDispatcherOptions = OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
                .addExecutorLzComposeOption(0, yieldDispatcherGasLimit, 0);

            SendParam memory sendUPTParam;
            MessagingFee memory govMessagingFee;
            if (govFee != 0) {
                sendUPTParam = SendParam({
                    dstEid: govEndpointId,
                    to: bytes32(uint256(uint160(yieldDispatcher))),
                    amountLD: govFee,
                    minAmountLD: 0,
                    extraOptions: yieldDispatcherOptions,
                    composeMsg: abi.encode(governor, true),
                    oftCmd: abi.encode()
                });
                govMessagingFee = IOFT(UPT).quoteSend(sendUPTParam, false);
            }

            SendParam memory sendMemecoinParam;
            MessagingFee memory memecoinMessagingFee;
            if (memecoinFee != 0) {
                sendMemecoinParam = SendParam({
                    dstEid: govEndpointId,
                    to: bytes32(uint256(uint160(yieldDispatcher))),
                    amountLD: memecoinFee,
                    minAmountLD: 0,
                    extraOptions: yieldDispatcherOptions,
                    composeMsg: abi.encode(yieldVault, false),
                    oftCmd: abi.encode()
                });
                memecoinMessagingFee = IOFT(memecoin).quoteSend(sendMemecoinParam, false);
            }

            require(msg.value >= govMessagingFee.nativeFee + memecoinMessagingFee.nativeFee, InsufficientLzFee());
            if (govFee != 0) IOFT(UPT).send{value: govMessagingFee.nativeFee}(sendUPTParam, govMessagingFee, msg.sender);
            if (memecoinFee != 0) IOFT(memecoin).send{value: memecoinMessagingFee.nativeFee}(sendMemecoinParam, memecoinMessagingFee, msg.sender);
        }
        
        emit RedeemAndDistributeFees(verseId, govFee, memecoinFee, executorReward, burnedUPT, burnedPOL);
    }

    /**
     * @dev Burn liquidProof to claim the locked liquidity
     * @param verseId - Memeverse id
     * @param amountInPOL - Burned liquid proof token amount
     */
    function redeemLiquidity(uint256 verseId, uint256 amountInPOL) external whenNotPaused override {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        IMemeLiquidProof(verse.liquidProof).burn(msg.sender, amountInPOL);
        address UPT = verse.UPT;
        address memecoin = verse.memecoin;
        address pair = OutrunAMMLibrary.pairFor(outrunAMMFactory, memecoin, UPT, SWAP_FEERATE);
        _safeApproveInf(pair, liquidityRouter);
        (uint256 amountInUPT, uint256 amountInMemecoin) = IMemeverseLiquidityRouter(liquidityRouter).removeLiquidity(
            UPT,
            memecoin, 
            SWAP_FEERATE, 
            amountInPOL, 
            0, 
            0, 
            address(this), 
            block.timestamp
        );
        _transferOut(UPT, msg.sender, amountInUPT);
        if (block.timestamp > verse.unlockTime + 3 days) {
            _transferOut(memecoin, msg.sender, amountInMemecoin);
        } else {
            unchecked {
                toBeUnlockedCoins[verseId][msg.sender] += amountInMemecoin;
            }
        }

        emit RedeemLiquidity(verseId, msg.sender, amountInPOL);
    }

    /**
     * @dev Redeem Unlocked Coins
     * @param verseId - Memeverse id
     */
    function redeemUnlockedCoins(uint256 verseId) external whenNotPaused override {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());
        require(block.timestamp > verse.unlockTime + 3 days, LiquidityProtectionPeriod());

        uint256 amountInMemecoin = toBeUnlockedCoins[verseId][msg.sender];
        require(amountInMemecoin > 0, NoCoinsToUnlock());

        toBeUnlockedCoins[verseId][msg.sender] = 0;
        _transferOut(verse.memecoin, msg.sender, amountInMemecoin);

        emit RedeemUnlockedCoins(verseId, msg.sender, amountInMemecoin);
    }

    /**
     * @dev Mint POL token by add memecoin liquidity when currentStage >= Stage.Locked.
     * @param verseId - Memeverse id
     * @param amountInUPTDesired - Amount of UPT transfered into Launcher
     * @param amountInMemecoinDesired - Amount of transfered into Launcher
     * @param amountInUPTMin - Minimum amount of UPT
     * @param amountInMemecoinMin - Minimum amount of memecoin
     * @param amountOutDesired - Amount of POL token desired, If the amountOut is 0, the output quantity will be automatically calculated.
     */
    function mintPOLToken(
        uint256 verseId, 
        uint256 amountInUPTDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUPTMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired
    ) external override returns (uint256 amountInUPT, uint256 amountInMemecoin, uint256 amountOut) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        address UPT = verse.UPT;
        address memecoin = verse.memecoin;
        _transferIn(UPT, msg.sender, amountInUPTDesired);
        _transferIn(memecoin, msg.sender, amountInMemecoinDesired);
        _safeApproveInf(UPT, liquidityRouter);
        _safeApproveInf(memecoin, liquidityRouter);
        if (amountOutDesired == 0) {
            (amountInUPT, amountInMemecoin, amountOut) = IMemeverseLiquidityRouter(liquidityRouter).addExactTokensForLiquidity(
                UPT,
                memecoin,
                SWAP_FEERATE,
                amountInUPTDesired,
                amountInMemecoinDesired,
                amountInUPTMin,
                amountInMemecoinMin,
                address(this),
                block.timestamp
            );
        } else {
            (amountInUPT, amountInMemecoin, amountOut) = IMemeverseLiquidityRouter(liquidityRouter).addTokensForExactLiquidity(
                UPT, 
                memecoin, 
                SWAP_FEERATE, 
                amountOutDesired, 
                amountInUPTDesired, 
                amountInMemecoinDesired, 
                address(this), 
                block.timestamp
            );
        }

        uint256 UPTRefund = amountInUPTDesired - amountInUPT;
        uint256 memecoinRefund = amountInMemecoinDesired - amountInMemecoin;
        if (UPTRefund > 0) _transferOut(UPT, msg.sender, UPTRefund);
        if (memecoinRefund > 0) _transferOut(memecoin, msg.sender, memecoinRefund);
        address liquidProof = verse.liquidProof;
        IMemeLiquidProof(liquidProof).mint(msg.sender, amountOut);

        emit MintPOLToken(verseId, memecoin, liquidProof, msg.sender, amountOut);
    }

    /**
     * @dev Register memeverse
     * @param name - Name of memecoin
     * @param symbol - Symbol of memecoin
     * @param uniqueId - Unique verseId
     * @param endTime - Genesis stage end time
     * @param unlockTime - Unlock time of liquidity
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     * @param UPT - Genesis fund types
     * @param flashGenesis - Enable FlashGenesis mode
     */
    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        address UPT,
        bool flashGenesis
    ) external whenNotPaused override {
        require(msg.sender == memeverseRegistrar, PermissionDenied());

        address memecoin = IMemeverseProxyDeployer(memeverseProxyDeployer).deployMemecoin(uniqueId);
        IMemecoin(memecoin).initialize(name, symbol, 18, address(this), localLzEndpoint, address(this));
        _lzConfigure(memecoin, omnichainIds);

        Memeverse storage verse = memeverses[uniqueId];
        verse.name = name;
        verse.symbol = symbol;
        verse.UPT = UPT;
        verse.memecoin = memecoin;
        verse.endTime = endTime;
        verse.unlockTime = unlockTime;
        verse.omnichainIds = omnichainIds;
        verse.flashGenesis = flashGenesis;

        memeverses[uniqueId] = verse;
        memecoinToIds[memecoin] = uniqueId;

        emit RegisterMemeverse(uniqueId, verse);
    }

    /**
     * @dev Memecoin Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
     */
    function _lzConfigure(address memecoin, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length; i++) {
            uint32 omnichainId = omnichainIds[i];
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(omnichainId);
            require(remoteEndpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
        }
    }

    /**
     * @dev Remove gas dust from the contract
     */
    function removeGasDust(address receiver) external override {
        uint256 dust = address(this).balance;
        _transferOut(NATIVE, receiver, dust);

        emit RemoveGasDust(receiver, dust);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Set liquidityRouter contract
     * @param _liquidityRouter - Address of liquidityRouter
     */
    function setLiquidityRouter(address _liquidityRouter) external override onlyOwner {
        require(_liquidityRouter != address(0), ZeroInput());

        liquidityRouter = _liquidityRouter;

        emit SetLiquidityRouter(_liquidityRouter);
    }

    /**
     * @dev Set memeverse common info contract
     * @param _memeverseCommonInfo - Address of memeverseCommonInfo
     */
    function setMemeverseCommonInfo(address _memeverseCommonInfo) external override onlyOwner {
        require(_memeverseCommonInfo != address(0), ZeroInput());

        memeverseCommonInfo = _memeverseCommonInfo;

        emit SetMemeverseCommonInfo(_memeverseCommonInfo);
    }

    /**
     * @dev Set memeverse registrar contract
     * @param _memeverseRegistrar - Address of memeverseRegistrar
     */
    function setMemeverseRegistrar(address _memeverseRegistrar) external override onlyOwner {
        require(_memeverseRegistrar != address(0), ZeroInput());

        memeverseRegistrar = _memeverseRegistrar;

        emit SetMemeverseRegistrar(_memeverseRegistrar);
    }

    /**
     * @dev Set memeverse proxy deployer contract
     * @param _memeverseProxyDeployer - Address of memeverseProxyDeployer
     */
    function setMemeverseProxyDeployer(address _memeverseProxyDeployer) external override onlyOwner {
        require(_memeverseProxyDeployer != address(0), ZeroInput());

        memeverseProxyDeployer = _memeverseProxyDeployer;

        emit SetMemeverseProxyDeployer(_memeverseProxyDeployer);
    }

    /**
     * @dev Set memecoin yieldDispatcher contract
     * @param _yieldDispatcher - Address of yieldDispatcher
     */
    function setYieldDispatcher(address _yieldDispatcher) external override onlyOwner {
        require(_yieldDispatcher != address(0), ZeroInput());

        yieldDispatcher = _yieldDispatcher;

        emit SetYieldDispatcher(_yieldDispatcher);
    }

    /**
     * @dev Set fundMetaData
     * @param _upt - Genesis fund type
     * @param _minTotalFund - The minimum participation genesis fund corresponding to UPT
     * @param _fundBasedAmount - // The number of Memecoins minted per unit of Memecoin genesis fund
     */
    function setFundMetaData(address _upt, uint256 _minTotalFund, uint256 _fundBasedAmount) external override onlyOwner {
        require(_minTotalFund != 0 && _fundBasedAmount != 0, ZeroInput());

        fundMetaDatas[_upt] = FundMetaData(_minTotalFund, _fundBasedAmount);

        emit SetFundMetaData(_upt, _minTotalFund, _fundBasedAmount);
    }

    /**
     * @dev Set executor reward rate 
     * @param _executorRewardRate - Executor reward rate 
     */
    function setExecutorRewardRate(uint256 _executorRewardRate) external override onlyOwner {
        require(_executorRewardRate < RATIO, FeeRateOverFlow());

        executorRewardRate = _executorRewardRate;

        emit SetExecutorRewardRate(_executorRewardRate);
    }

    /**
     * @dev Set gas limits for OFT receive and yield dispatcher
     * @param _oftReceiveGasLimit - Gas limit for OFT receive
     * @param _yieldDispatcherGasLimit - Gas limit for yield dispatcher
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _yieldDispatcherGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _yieldDispatcherGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        yieldDispatcherGasLimit = _yieldDispatcherGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _yieldDispatcherGasLimit);
    }

    /**
     * @dev Set external info
     * @param verseId - Memeverse id
     * @param uri - IPFS URI of memecoin icon
     * @param description - Description
     * @param communities - Community(Website, X, Discord, Telegram and Others)
     */
    function setExternalInfo(
        uint256 verseId,
        string calldata uri,
        string calldata description,
        string[] calldata communities
    ) external override {
        require(msg.sender == memeverses[verseId].governor || msg.sender == memeverseRegistrar, PermissionDenied());
        require(bytes(description).length < 256, InvalidLength());

        if (bytes(uri).length != 0) memeverses[verseId].uri = uri;
        if (bytes(description).length != 0) memeverses[verseId].desc = description;
        if (communities.length != 0) {
            for (uint256 i = 0; i < communities.length; i++) {
                communitiesMap[verseId][i] = communities[i];
            }
        }

        emit SetExternalInfo(verseId, uri, description, communities);
    }
}
