// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

import { TokenHelper } from "../common/TokenHelper.sol";
import { IMemecoin } from "../token/interfaces/IMemecoin.sol";
import { OutrunAMMLibrary } from "../libraries/OutrunAMMLibrary.sol";
import { IOutrunAMMPair } from "../common/interfaces/IOutrunAMMPair.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IMemeLiquidProof } from "../token/interfaces/IMemeLiquidProof.sol";
import { IMemeverseCommonInfo } from "./interfaces/IMemeverseCommonInfo.sol";
import { IMemecoinYieldVault } from "../yield/interfaces/IMemecoinYieldVault.sol";
import { IMemeverseProxyDeployer } from "./interfaces/IMemeverseProxyDeployer.sol";
import { IMemeverseLiquidityRouter } from "../common/interfaces/IMemeverseLiquidityRouter.sol";

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
    address public oftDispatcher;
    address public memeverseRegistrar;
    address public memeverseProxyDeployer;
    
    uint256 public executorRewardRate;
    uint128 public oftReceiveGasLimit;
    uint128 public oftDispatcherGasLimit;

    mapping(address UPT => FundMetaData) public fundMetaDatas;
    mapping(address memecoin => uint256) public memecoinToIds;
    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => uint256) public totalClaimablePOLs;
    mapping(uint256 verseId => uint256) public totalTreasuryPOLs;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;
    mapping(uint256 verseId => mapping(uint256 provider => string)) public communitiesMap;     // provider -> 0:Website, 1:X, 2:Discord, 3:Telegram, >4:Others

    constructor(
        address _owner,
        address _outrunAMMFactory,
        address _liquidityRouter,
        address _localLzEndpoint,
        address _memeverseRegistrar,
        address _memeverseProxyDeployer,
        address _oftDispatcher,
        address _memeverseCommonInfo,
        uint256 _executorRewardRate,
        uint128 _oftReceiveGasLimit,
        uint128 _oftDispatcherGasLimit
    ) Ownable(_owner) {
        liquidityRouter = _liquidityRouter;
        outrunAMMFactory = _outrunAMMFactory;
        localLzEndpoint = _localLzEndpoint;
        memeverseRegistrar = _memeverseRegistrar;
        memeverseProxyDeployer = _memeverseProxyDeployer;
        memeverseCommonInfo = _memeverseCommonInfo;
        oftDispatcher = _oftDispatcher;
        executorRewardRate =_executorRewardRate;
        oftReceiveGasLimit = _oftReceiveGasLimit;
        oftDispatcherGasLimit = _oftDispatcherGasLimit;
    }

    modifier versIdValidate(uint256 verseId) {
        require(memeverses[verseId].memecoin != address(0), InvalidVerseId());
        _;
    }

    /**
     * @notice Get the verse id by memecoin.
     * @param memecoin -The address of the memecoin.
     * @return verseId The verse id.
     */
    function getVerseIdByMemecoin(address memecoin) external view override returns (uint256 verseId) {
        require(memecoin != address(0), ZeroInput());
        verseId = memecoinToIds[memecoin];
    }

    /**
     * @notice Get the memeverse by verse id.
     * @param verseId - The verse id.
     * @return verse - The memeverse.
     */
    function getMemeverseByVerseId(uint256 verseId) external view override returns (Memeverse memory verse) {
        require(verseId != 0, ZeroInput());
        verse = memeverses[verseId];
    }

    /**
     * @notice Get the memeverse by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return verse - The memeverse.
     */
    function getMemeverseByMemecoin(address memecoin) external view override returns (Memeverse memory verse) {
        require(memecoin != address(0), ZeroInput());
        verse = memeverses[memecoinToIds[memecoin]];
    }

    /**
     * @notice Get the Stage by verse id.
     * @param verseId - The verse id.
     * @return stage - The memeverse current stage.
     */
    function getStageByVerseId(uint256 verseId) external view override returns (Stage stage) {
        require(verseId != 0, ZeroInput());
        stage = memeverses[verseId].currentStage;
    }

    /**
     * @notice Get the Stage by memecoin.
     * @param memecoin - The address of the memecoin.
     * @return stage - The memeverse current stage.
     */
    function getStageByMemecoin(address memecoin) external view override returns (Stage stage) {
        require(memecoin != address(0), ZeroInput());
        stage = memeverses[memecoinToIds[memecoin]].currentStage;
    }

    /**
     * @notice Get the yield vault by verse id.
     * @param verseId - The verse id.
     * @return yieldVault - The yield vault.
     */
    function getYieldVaultByVerseId(uint256 verseId) external view override returns (address yieldVault) {
        require(verseId != 0, ZeroInput());
        yieldVault = memeverses[verseId].yieldVault;
    }

    /**
     * @notice Get the governor by verse id.
     * @param verseId - The verse id.
     * @return governor - The governor.
     */
    function getGovernorByVerseId(uint256 verseId) external view override returns (address governor) {
        require(verseId != 0, ZeroInput());
        governor = memeverses[verseId].governor;
    }

    /**
     * @dev Preview claimable POLs token of user after Genesis Stage 
     * @param verseId - Memeverse id
     * @return claimableAmount - The claimable amount.
     */
    function userClaimablePOLs(uint256 verseId) public view override returns (uint256 claimableAmount) {
        require(verseId != 0, ZeroInput());
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, NotReachedLockedStage());

        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint256 totalFunds = genesisFund.totalMemecoinFunds + genesisFund.totalLiquidProofFunds;
        uint256 userFunds = userTotalFunds[verseId][msg.sender];
        uint256 totalClaimable = totalClaimablePOLs[verseId];
        claimableAmount = totalClaimable * userFunds / totalFunds;
    }

    /**
     * @dev Preview Genesis liquidity market maker fees for DAO Treasury (UPT) and Yield Vault(Memecoin)
     * @param verseId - Memeverse id
     * @return UPTFee - The UPT fee.
     * @return memecoinFee - The memecoin fee.
     */
    function previewGenesisMakerFees(uint256 verseId) public view override returns (uint256 UPTFee, uint256 memecoinFee) {
        require(verseId != 0, ZeroInput());
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
        (amount0, amount1) = liquidProofPair.previewMakerFee();
        token0 = liquidProofPair.token0();
        UPTFee = token0 == UPT ? UPTFee + amount0 : UPTFee + amount1;
    }

    /**
     * @dev Quote the LZ fee for the redemption and distribution of fees
     * @param verseId - Memeverse id
     * @return lzFee - The LZ fee.
     * @notice The LZ fee is only charged when the governance chain is not the same as the current chain,
     *         and msg.value needs to be greater than the quoted lzFee for the redeemAndDistributeFees transaction.
     */
    function quoteDistributionLzFee(uint256 verseId) external view override returns (uint256 lzFee) {
        require(verseId != 0, ZeroInput());
        Memeverse storage verse = memeverses[verseId];
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;
        
        (uint256 UPTFee, uint256 memecoinFee) = previewGenesisMakerFees(verseId);
        uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
        bytes memory oftDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, oftDispatcherGasLimit, 0);

        if (UPTFee != 0) {
            (, MessagingFee memory govMessagingFee) = _buildSendParamAndMessagingFee(
                    govEndpointId,
                    UPTFee,
                    verse.UPT,
                    verse.governor,
                    TokenType.UPT,
                    oftDispatcherOptions
            );
            lzFee += govMessagingFee.nativeFee;
        }

        if (memecoinFee != 0) {
            (, MessagingFee memory memecoinMessagingFee) = _buildSendParamAndMessagingFee(
                    govEndpointId,
                    memecoinFee,
                    verse.memecoin,
                    verse.yieldVault,
                    TokenType.MEMECOIN,
                    oftDispatcherOptions
            );
            lzFee += memecoinMessagingFee.nativeFee;
        }
    }

    /**
     * @dev Quote the LZ fee for processing TreasuryPOL on non-governance chains
     * @param verseId - Memeverse id
     * @return lzFee - The LZ fee.
     * @notice The LZ fee is only charged when the governance chain is not the same as the current chain,
     *         and msg.value needs to be greater than the quoted lzFee for the processNonGovChainTreasuryPOL transaction.
     */
    function quoteProcessTreasuryPolLzFee(uint256 verseId) external view override returns (uint256 lzFee) {
        require(verseId != 0, ZeroInput());
        Memeverse storage verse = memeverses[verseId];
        uint32 govChainId = verse.omnichainIds[0];
        if (govChainId == block.chainid) return 0;
        
        uint256 treasuryPOL = totalTreasuryPOLs[verseId];
        uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
        bytes memory oftDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, oftDispatcherGasLimit, 0);

        if (treasuryPOL != 0) {
            (, MessagingFee memory messagingFee) = _buildSendParamAndMessagingFee(
                    govEndpointId,
                    treasuryPOL,
                    verse.liquidProof,
                    verse.governor,
                    TokenType.POL,
                    oftDispatcherOptions
            );
            lzFee += messagingFee.nativeFee;
        }
    }

    /**
     * @dev Genesis memeverse by depositing UPT
     * @param verseId - Memeverse id
     * @param amountInUPT - Amount of UPT
     * @param user - Address of user participating in the genesis
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint128 amountInUPT, address user) external versIdValidate(verseId) whenNotPaused override {
        require(verseId != 0 && amountInUPT != 0 && user != address(0), ZeroInput());
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Genesis, NotGenesisStage());

        _transferIn(verse.UPT, msg.sender, amountInUPT);

        uint128 increasedMemecoinFund;
        uint128 increasedLiquidProofFund;
        unchecked {
            increasedLiquidProofFund = amountInUPT / 5;
            increasedMemecoinFund = amountInUPT - increasedLiquidProofFund;
        }

        GenesisFund storage genesisFund = genesisFunds[verseId];
        unchecked {
            genesisFund.totalMemecoinFunds += increasedMemecoinFund;
            genesisFund.totalLiquidProofFunds += increasedLiquidProofFund;
            userTotalFunds[verseId][user] += amountInUPT;
        }

        emit Genesis(verseId, user, increasedMemecoinFund, increasedLiquidProofFund);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     * @return currentStage - The current stage.
     */
    function changeStage(uint256 verseId) external versIdValidate(verseId) whenNotPaused override returns (Stage currentStage) {
        require(verseId != 0, ZeroInput());
        uint256 currentTime = block.timestamp;
        Memeverse storage verse = memeverses[verseId];
        currentStage = verse.currentStage;
        require(currentStage != Stage.Refund && currentStage != Stage.Unlocked, ReachedFinalStage());

        if (currentStage == Stage.Genesis) {
            currentStage = _handleGenesisStage(verseId, currentTime, verse);
        } else if (currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            verse.currentStage = Stage.Unlocked;
            currentStage = Stage.Unlocked;
        }

        emit ChangeStage(verseId, currentStage);
    }

    /**
     * @dev Handle Genesis stage logic
     * @param verseId - Memeverse id
     * @param currentTime - Current timestamp
     * @param verse - Memeverse storage reference
     * @return currentStage - The current stage
     */
    function _handleGenesisStage(uint256 verseId, uint256 currentTime, Memeverse storage verse) internal returns (Stage currentStage) {
        address UPT = verse.UPT;
        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        bool meetMinTotalFund = totalMemecoinFunds + totalLiquidProofFunds >= fundMetaDatas[UPT].minTotalFund;
        uint256 endTime = verse.endTime;
        require(
            endTime != 0 && meetMinTotalFund && (currentTime > endTime || verse.flashGenesis), 
            StillInGenesisStage(endTime)
        );

        if (!meetMinTotalFund) {
            verse.currentStage = Stage.Refund;
            return Stage.Refund;
        } else {
            _deployAndSetupMemeverse(verseId, verse, UPT, totalMemecoinFunds, totalLiquidProofFunds);
            verse.currentStage = Stage.Locked;
            return Stage.Locked;
        }
    }

    /**
     * @dev Deploy and setup memeverse components
     * @param verseId - Memeverse id
     * @param verse - Memeverse storage reference
     * @param UPT - UPT address
     * @param totalMemecoinFunds - Total memecoin funds
     * @param totalLiquidProofFunds - Total liquid proof funds
     */
    function _deployAndSetupMemeverse(
        uint256 verseId,
        Memeverse storage verse,
        address UPT,
        uint128 totalMemecoinFunds,
        uint128 totalLiquidProofFunds
    ) internal {
        string memory name = verse.name;
        string memory symbol = verse.symbol;
        address memecoin = verse.memecoin;
        address pol = verse.liquidProof;
        uint32 govChainId = verse.omnichainIds[0];

        // Deploy Yield Vault, DAO Governor and Incentivizer
        (address yieldVault, address governor, address incentivizer) = _deployGovernanceComponents(verseId, govChainId, name, symbol, UPT, memecoin, pol);
        verse.yieldVault = yieldVault;
        verse.governor = governor;
        verse.incentivizer = incentivizer;

        // Deploy liquidity
        uint256 unlockTime = verse.unlockTime;
        _deployLiquidity(verseId, govChainId, governor, UPT, memecoin, pol, unlockTime, totalMemecoinFunds, totalLiquidProofFunds);
    }

    /**
     * @dev Deploy governance components
     * @param verseId - Memeverse id
     * @param govChainId - Governance chain id
     * @param name - Token name
     * @param symbol - Token symbol
     * @param UPT - UPT address
     * @param memecoin - Memecoin address
     * @param pol - POL address
     */
    function _deployGovernanceComponents(
        uint256 verseId,
        uint32 govChainId,
        string memory name,
        string memory symbol,
        address UPT,
        address memecoin,
        address pol
    ) internal returns (address yieldVault, address governor, address incentivizer) {
        uint256 proposalThreshold = IMemecoin(memecoin).totalSupply() / 50;
        
        if (govChainId == block.chainid) {
            yieldVault = IMemeverseProxyDeployer(memeverseProxyDeployer).deployYieldVault(verseId);
            IMemecoinYieldVault(yieldVault).initialize(
                string(abi.encodePacked("Staked ", name)),
                string(abi.encodePacked("s", symbol)),
                oftDispatcher,
                memecoin,
                verseId
            );
            (governor, incentivizer) = IMemeverseProxyDeployer(memeverseProxyDeployer).deployGovernorAndIncentivizer(
                name, UPT, memecoin, pol, yieldVault, verseId, proposalThreshold
            );
        } else {
            yieldVault = IMemeverseProxyDeployer(memeverseProxyDeployer).predictYieldVaultAddress(verseId);
            (governor, incentivizer) = IMemeverseProxyDeployer(memeverseProxyDeployer).computeGovernorAndIncentivizerAddress(verseId);
        }
    }

    /**
     * @dev Deploy liquidity pools
     * @param verseId - Memeverse id
     * @param govChainId - Governance chain id
     * @param governor - Memecoin DAO governor address
     * @param UPT - UPT address
     * @param memecoin - Memecoin address
     * @param pol - POL address
     * @param unlockTime - Memeverse genesis liquidity unlockTime
     * @param totalMemecoinFunds - Total memecoin funds
     * @param totalLiquidProofFunds - Total liquid proof funds
     */
    function _deployLiquidity(
        uint256 verseId,
        uint32 govChainId,
        address governor,
        address UPT,
        address memecoin,
        address pol,
        uint256 unlockTime,
        uint128 totalMemecoinFunds,
        uint128 totalLiquidProofFunds
    ) internal {
        // Deploy memecoin liquidity
        uint256 memecoinAmount = totalMemecoinFunds * fundMetaDatas[UPT].fundBasedAmount;
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
            unlockTime,
            block.timestamp
        );

        // Mint liquidity proof token
        IMemeLiquidProof(pol).mint(address(this), memecoinLiquidity);
        uint256 treasuryPOL = memecoinLiquidity / 4;
        
        if (govChainId == block.chainid) {
            _transferOut(pol, oftDispatcher, treasuryPOL);
            ILayerZeroComposer(oftDispatcher).lzCompose(pol, bytes32(0), abi.encode(governor, TokenType.POL, treasuryPOL), address(0), "");
        } else {
            totalTreasuryPOLs[verseId] = treasuryPOL;
        }
        
        // Deploy POL liquidity
        _safeApproveInf(UPT, liquidityRouter);
        _safeApproveInf(pol, liquidityRouter);
        uint256 deployedPOL = memecoinLiquidity / 8;
        IMemeverseLiquidityRouter(liquidityRouter).addExactTokensForLiquidity(
            UPT,
            pol,
            SWAP_FEERATE,
            totalLiquidProofFunds,
            deployedPOL,
            totalLiquidProofFunds,
            deployedPOL,
            address(this),
            unlockTime,
            block.timestamp
        );
        totalClaimablePOLs[verseId] = memecoinLiquidity - treasuryPOL - deployedPOL;
    }

    /**
     * @dev Refund UPT after genesis Failed, total omnichain funds didn't meet the minimum funding requirement
     * @param verseId - Memeverse id
     */
    function refund(uint256 verseId) external whenNotPaused override returns (uint256 userFunds) {
        require(verseId != 0, ZeroInput());
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
     * @dev Process non-govChain treasury POL
     * @param verseId - Memeverse id
     */
    function processNonGovChainTreasuryPOL(uint256 verseId) external payable whenNotPaused override {
        require(verseId != 0, ZeroInput());
        uint256 treasuryPOL = totalTreasuryPOLs[verseId];
        require(treasuryPOL > 0, InsufficientTreasuryPOL());

        totalTreasuryPOLs[verseId] = 0;
        Memeverse storage verse = memeverses[verseId];
        uint32 govChainId = verse.omnichainIds[0];
        uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
        bytes memory oftDispatcherOptions = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
            .addExecutorLzComposeOption(0, oftDispatcherGasLimit, 0);

        address pol = verse.liquidProof;
        (SendParam memory sendParam, MessagingFee memory messagingFee) = _buildSendParamAndMessagingFee(
            govEndpointId,
            treasuryPOL,
            pol,
            verse.governor,
            TokenType.POL,
            oftDispatcherOptions
        );

        require(msg.value >= messagingFee.nativeFee, InsufficientLzFee());
        IOFT(pol).send{value: messagingFee.nativeFee}(sendParam, messagingFee, msg.sender);

        emit ProcessNonGovChainTreasuryPOL(verseId, treasuryPOL);
    }

    /**
     * @dev Claim POL tokens in stage Locked
     * @param verseId - Memeverse id
     */
    function claimPOLs(uint256 verseId) external whenNotPaused override returns (uint256 amount) {
        require(verseId != 0, ZeroInput());
        amount = userClaimablePOLs(verseId);
        require(amount != 0, NoPOLAvailable());

        address msgSender = msg.sender;
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(memeverses[verseId].liquidProof, msgSender, amount);
        
        emit ClaimPOLs(verseId, msgSender, amount);
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     * @param rewardReceiver - Address of executor reward receiver
     * @return govFee - The Gov fee.
     * @return memecoinFee - The memecoin fee.
     * @return liquidProofFee - The liquidProof fee.
     * @return executorReward  - The executor reward.
     * @notice Anyone who calls this method will be rewarded with executorReward.
     */
    function redeemAndDistributeFees(uint256 verseId, address rewardReceiver) external payable whenNotPaused override 
    returns (uint256 govFee, uint256 memecoinFee, uint256 liquidProofFee, uint256 executorReward) {
        require(verseId != 0 && rewardReceiver != address(0), ZeroInput());
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
        // POL pair
        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(outrunAMMFactory, liquidProof, UPT, SWAP_FEERATE));
        (amount0, amount1) = liquidProofPair.claimMakerFee();
        token0 = liquidProofPair.token0();
        UPTFee = token0 == UPT ? UPTFee + amount0 : UPTFee + amount1;
        liquidProofFee = token0 == liquidProof ? amount0 : amount1;

        if (UPTFee == 0 && memecoinFee == 0 && liquidProofFee == 0) return (0, 0, 0, 0);
        // Burn liquidProof fee
        IMemeLiquidProof(liquidProof).burn(address(this), liquidProofFee);

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
                _transferOut(UPT, oftDispatcher, govFee);
                ILayerZeroComposer(oftDispatcher).lzCompose(UPT, bytes32(0), abi.encode(governor, TokenType.UPT, govFee), address(0), "");
            }
            if (memecoinFee != 0) {
                _transferOut(memecoin, oftDispatcher, memecoinFee);
                ILayerZeroComposer(oftDispatcher).lzCompose(memecoin, bytes32(0), abi.encode(yieldVault, TokenType.MEMECOIN, memecoinFee), address(0), "");
            }
        } else {
            uint32 govEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(govChainId);
            
            bytes memory oftDispatcherOptions = OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(oftReceiveGasLimit, 0)
                .addExecutorLzComposeOption(0, oftDispatcherGasLimit, 0);

            SendParam memory sendUPTParam;
            MessagingFee memory govMessagingFee;
            if (govFee != 0) {
                (sendUPTParam, govMessagingFee) = _buildSendParamAndMessagingFee(
                    govEndpointId,
                    govFee,
                    UPT,
                    governor,
                    TokenType.UPT,
                    oftDispatcherOptions
                );
            }

            SendParam memory sendMemecoinParam;
            MessagingFee memory memecoinMessagingFee;
            if (memecoinFee != 0) {
                (sendMemecoinParam, memecoinMessagingFee) = _buildSendParamAndMessagingFee(
                    govEndpointId,
                    memecoinFee,
                    memecoin,
                    yieldVault,
                    TokenType.MEMECOIN,
                    oftDispatcherOptions
                );
            }

            require(msg.value >= govMessagingFee.nativeFee + memecoinMessagingFee.nativeFee, InsufficientLzFee());
            if (govFee != 0) IOFT(UPT).send{value: govMessagingFee.nativeFee}(sendUPTParam, govMessagingFee, msg.sender);
            if (memecoinFee != 0) IOFT(memecoin).send{value: memecoinMessagingFee.nativeFee}(sendMemecoinParam, memecoinMessagingFee, msg.sender);
        }
        
        emit RedeemAndDistributeFees(verseId, govFee, memecoinFee, liquidProofFee, executorReward);
    }

    /**
     * @dev Burn liquidProof to claim the locked liquidity
     * @param verseId - Memeverse id
     * @param amountInPOL - Burned liquid proof token amount
     * @notice User must have approved this contract to spend POL
     */
    function redeemLiquidity(uint256 verseId, uint256 amountInPOL) external whenNotPaused override {
        require(verseId != 0 && amountInPOL != 0, ZeroInput());
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage());

        IMemeLiquidProof(verse.liquidProof).burn(msg.sender, amountInPOL);
        address UPT = verse.UPT;
        address memecoinPair = OutrunAMMLibrary.pairFor(outrunAMMFactory, verse.memecoin, UPT, SWAP_FEERATE);
        address liquidProofPair = OutrunAMMLibrary.pairFor(outrunAMMFactory, verse.liquidProof, UPT, SWAP_FEERATE);
        uint256 liquidProofLPAmount = amountInPOL / 5;
        require(
            IERC20(memecoinPair).balanceOf(address(this)) >= amountInPOL &&
            IERC20(liquidProofPair).balanceOf(address(this)) >= liquidProofLPAmount, 
            InsufficientLPBalance()
        );

        _transferOut(memecoinPair, msg.sender, amountInPOL);
        _transferOut(liquidProofPair, msg.sender, liquidProofLPAmount);

        emit RedeemLiquidity(verseId, msg.sender, amountInPOL, liquidProofLPAmount);
    }

    /**
     * @dev Mint POL token by add memecoin liquidity when currentStage >= Stage.Locked.
     * @param verseId - Memeverse id
     * @param amountInUPTDesired - Amount of UPT transfered into Launcher
     * @param amountInMemecoinDesired - Amount of transfered into Launcher
     * @param amountInUPTMin - Minimum amount of UPT
     * @param amountInMemecoinMin - Minimum amount of memecoin
     * @param amountOutDesired - Amount of POL token desired, If the amountOut is 0, the output quantity will be automatically calculated.
     * @param deadline - Transaction deadline
     */
    function mintPOLToken(
        uint256 verseId, 
        uint256 amountInUPTDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUPTMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired,
        uint256 deadline
    ) external override returns (uint256 amountInUPT, uint256 amountInMemecoin, uint256 amountOut) {
        require(verseId != 0 && amountInUPTDesired != 0 && amountInMemecoinDesired != 0, ZeroInput());
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
                0,
                deadline
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
                deadline
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
        address pol = IMemeverseProxyDeployer(memeverseProxyDeployer).deployPOL(uniqueId);
        IMemecoin(memecoin).initialize(name, symbol, address(this), address(this));
        IMemeLiquidProof(pol).initialize(
            string(abi.encodePacked("POL ", name)), 
            string(abi.encodePacked("POL ", symbol)), 
            memecoin, 
            address(this),
            address(this)
        );
        
        _lzConfigure(memecoin, pol, omnichainIds);

        Memeverse storage verse = memeverses[uniqueId];
        verse.name = name;
        verse.symbol = symbol;
        verse.UPT = UPT;
        verse.memecoin = memecoin;
        verse.liquidProof = pol;
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
    function _lzConfigure(address memecoin, address pol, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);

        // Use default config
        for (uint256 i = 0; i < omnichainIds.length;) {
            uint32 omnichainId = omnichainIds[i];
            unchecked { i++; }
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = IMemeverseCommonInfo(memeverseCommonInfo).lzEndpointIdMap(omnichainId);
            require(remoteEndpointId != 0, InvalidOmnichainId(omnichainId));

            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
            IOAppCore(pol).setPeer(remoteEndpointId, bytes32(uint256(uint160(pol))));
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
     * @dev Set memeverse oftDispatcher contract
     * @param _oftDispatcher - Address of oftDispatcher
     */
    function setOFTDispatcher(address _oftDispatcher) external override onlyOwner {
        require(_oftDispatcher != address(0), ZeroInput());

        oftDispatcher = _oftDispatcher;

        emit SetOFTDispatcher(_oftDispatcher);
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
     * @param _oftDispatcherGasLimit - Gas limit for yield dispatcher
     */
    function setGasLimits(uint128 _oftReceiveGasLimit, uint128 _oftDispatcherGasLimit) external override onlyOwner {
        require(_oftReceiveGasLimit > 0 && _oftDispatcherGasLimit > 0, ZeroInput());

        oftReceiveGasLimit = _oftReceiveGasLimit;
        oftDispatcherGasLimit = _oftDispatcherGasLimit;

        emit SetGasLimits(_oftReceiveGasLimit, _oftDispatcherGasLimit);
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
            for (uint256 i = 0; i < communities.length;) {
                communitiesMap[verseId][i] = communities[i];
                unchecked { i++; }
            }
        }

        emit SetExternalInfo(verseId, uri, description, communities);
    }

    function _buildSendParamAndMessagingFee(
        uint32 govEndpointId,
        uint256 amount,
        address token,
        address receiver,
        TokenType tokenType,
        bytes memory oftDispatcherOptions
    ) internal view returns (SendParam memory sendParam, MessagingFee memory messagingFee) {
        sendParam = SendParam({
            dstEid: govEndpointId,
            to: bytes32(uint256(uint160(oftDispatcher))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: oftDispatcherOptions,
            composeMsg: abi.encode(receiver, tokenType),
            oftCmd: abi.encode()
        });
        messagingFee = IOFT(token).quoteSend(sendParam, false);
    }
}
