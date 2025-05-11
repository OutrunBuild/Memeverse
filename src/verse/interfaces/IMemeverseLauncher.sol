// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @title MemeverseLauncher interface
 */
interface IMemeverseLauncher {
    enum Stage {
        Genesis,
        Refund,
        Locked,
        Unlocked
    }

    struct Memeverse {
        string name;                    // Token name
        string symbol;                  // Token symbol
        string uri;                     // Token icon uri
        string desc;                    // Description
        address UPT;                    // Genesis fund type
        address memecoin;               // Omnichain memecoin address
        address liquidProof;            // POL token address
        address yieldVault;             // Memecoin yield vault
        address governor;               // Memecoin DAO governor
        uint128 endTime;                // End time of Genesis stage 
        uint128 unlockTime;             // UnlockTime of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM),The first chainId is main governance chain
        Stage currentStage;             // Current stage
        bool flashGenesis;              // Allowing the transition to the liquidity lock stage once the minimum funding requirement is met, without waiting for the genesis stage to end.
    }

    struct GenesisFund {
        uint128 totalMemecoinFunds;     // Initial fundraising(UPT) for memecoin liquidity
        uint128 totalLiquidProofFunds;  // Initial fundraising(UPT) for liquidProof liquidity
    }

    struct FundMetaData{
        uint256 minTotalFund;           // The minimum participation genesis fund corresponding to UPT
        uint256 fundBasedAmount;        // The number of Memecoins minted per unit of Memecoin genesis fund
    }

    function getVerseIdByMemecoin(address memecoin) external view returns (uint256 verseId);

    function getMemeverseByVerseId(uint256 verseId) external view returns (Memeverse memory verse);

    function getMemeverseByMemecoin(address memecoin) external view returns (Memeverse memory verse);

    function getYieldVaultByVerseId(uint256 verseId) external view returns (address yieldVault);

    function getGovernorByVerseId(uint256 verseId) external view returns (address governor);

    function userClaimablePOLs(uint256 verseId) external view returns (uint256 claimableAmount);

    function previewGenesisMakerFees(uint256 verseId) external view returns (uint256 UPTFee, uint256 memecoinFee);

    function quoteDistributionLzFee(uint256 verseId) external view returns (uint256 lzFee);


    function genesis(uint256 verseId, uint256 amountInUPT, address user) external;

    function refund(uint256 verseId) external returns (uint256 userFunds);

    function changeStage(uint256 verseId) external returns (Stage currentStage);

    function claimPOLs(uint256 verseId) external returns (uint256 amount);

    function redeemAndDistributeFees(uint256 verseId, address rewardReceiver) external payable 
    returns (uint256 govFee, uint256 memecoinFee, uint256 executorReward);

    function redeemLiquidity(uint256 verseId, uint256 amountInPOL) external;

    function redeemUnlockedCoins(uint256 verseId) external;

    function mintPOLToken(
        uint256 verseId, 
        uint256 amountInUPTDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUPTMin,
        uint256 amountInMemecoinMin,
        uint256 amountOutDesired
    ) external returns (uint256 amountInUPT, uint256 amountInMemecoin, uint256 amountOut);

    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        address UPT,
        bool flashGenesis
    ) external;

    function removeGasDust(address receiver) external;

    function setLiquidityRouter(address liquidityRouter) external;

    function setMemeverseCommonInfo(address memeverseCommonInfo) external;

    function setMemeverseRegistrar(address memeverseRegistrar) external;

    function setMemeverseProxyDeployer(address memeverseProxyDeployer) external;

    function setYieldDispatcher(address yieldDispatcher) external;

    function setFundMetaData(address upt, uint256 minTotalFund, uint256 fundBasedAmount) external;

    function setExecutorRewardRate(uint256 executorRewardRate) external;

    function setGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit) external;

    function setExternalInfo(
        uint256 verseId,
        string calldata uri,
        string calldata description,
        string[] calldata communities
    ) external; 


    error ZeroInput();

    error InvalidLength();
    
    error NoPOLAvailable();
    
    error NotRefundStage();

    error NotGenesisStage();

    error FeeRateOverFlow();

    error NoCoinsToUnlock();

    error PermissionDenied();

    error NotUnlockedStage();

    error InsufficientLzFee();

    error ReachedFinalStage();

    error InsufficientUserFunds();
    
    error NotReachedLockedStage();

    error LiquidityProtectionPeriod();

    error ExpiredSignature(uint256 deadline);

    error StillInGenesisStage(uint256 endTime);

    error InvalidOmnichainId(uint32 omnichainId);


    event Genesis(
        uint256 indexed verseId,
        address indexed depositer,
        uint256 increasedMemecoinFund,
        uint256 increasedLiquidProofFund
    );

    event Refund(uint256 indexed verseId, address indexed receiver, uint256 refundAmount);

    event ChangeStage(uint256 indexed verseId, Stage currentStage);

    event ClaimLiquidProof(uint256 indexed verseId, address indexed receiver, uint256 claimedAmount);

    event RedeemAndDistributeFees(
        uint256 indexed verseId, 
        uint256 govFee, 
        uint256 memecoinFee, 
        uint256 executorReward, 
        uint256 burnedUPT, 
        uint256 burnedPOL
    );

    event RedeemLiquidity(uint256 indexed verseId, address indexed receiver, uint256 liquidity);

    event RedeemUnlockedCoins(uint256 indexed verseId, address indexed sender, uint256 amountInMemecoin);
    
    event MintPOLToken(
        uint256 indexed verseId, 
        address indexed memecoin, 
        address indexed liquidProof, 
        address receiver, 
        uint256 amount
    );

    event RegisterMemeverse(uint256 indexed verseId, Memeverse verse);

    event RemoveGasDust(address indexed receiver, uint256 dust);

    event SetLiquidityRouter(address liquidityRouter);

    event SetMemeverseCommonInfo(address memeverseCommonInfo);

    event SetMemeverseRegistrar(address memeverseRegistrar);

    event SetMemeverseProxyDeployer(address memeverseProxyDeployer);

    event SetYieldDispatcher(address yieldDispatcher);

    event SetFundMetaData(address indexed upt, uint256 minTotalFund, uint256 fundBasedAmount);

    event SetExecutorRewardRate(uint256 executorRewardRate);

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit);

    event SetExternalInfo(uint256 indexed verseId, string uri, string description, string[] community);
}
