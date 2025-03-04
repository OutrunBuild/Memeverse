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
        string name; // Token name
        string symbol; // Token symbol
        string uri; // Image uri
        address memecoin; // Omnichain memecoin address
        address creator; // Token creator
        address liquidProof; // POL token address
        address yieldVault; // Memecoin yield vault
        address governor; // Memecoin DAO governor
        uint128 endTime; // EndTime of launchPool
        uint128 unlockTime; // UnlockTime of liquidity
        uint32[] omnichainIds; // ChainIds of the token's omnichain(EVM),The first chainId is main governance chain
        Stage currentStage; // Current stage
    }

    struct GenesisFund {
        uint128 totalMemecoinFunds; // Initial fundraising(UPT) for memecoin liquidity
        uint128 totalLiquidProofFunds; // Initial fundraising(UPT) for liquidProof liquidity
    }

    function getVerseIdByMemecoin(address memecoin) external view returns (uint256 verseId);

    function getMemeverseByVerseId(uint256 verseId) external view returns (Memeverse memory verse);

    function getMemeverseByMemecoin(address memecoin) external view returns (Memeverse memory verse);

    function getYieldVaultByVerseId(uint256 verseId) external view returns (address yieldVault);

    function getYieldVaultByMemecoin(address memecoin) external view returns (address yieldVault);

    function getGovernorByVerseId(uint256 verseId) external view returns (address governor);

    function getGovernorByMemecoin(address memecoin) external view returns (address governor);

    function claimableLiquidProof(uint256 verseId) external view returns (uint256 claimableAmount);

    function previewGenesisMakerFees(uint256 verseId) external view returns (uint256 UPTFee, uint256 memecoinFee);

    function quoteDistributionLzFee(uint256 verseId) external view returns (uint256 lzFee);


    function genesis(uint256 verseId, uint256 amountInUPT, address user) external;

    function refund(uint256 verseId) external returns (uint256 userFunds);

    function changeStage(uint256 verseId) external returns (Stage currentStage);

    function claimLiquidProof(uint256 verseId) external returns (uint256 amount);

    function redeemAndDistributeFees(uint256 verseId, address botFeeReceiver) external payable 
    returns (uint256 govFee, uint256 memecoinFee, uint256 autoBotFee);

    function redeemLiquidity(uint256 verseId, uint256 proofTokenAmount) external;

    function mintLiquidProof(
        uint256 verseId, 
        uint256 amountInUPTDesired,
        uint256 amountInMemecoinDesired,
        uint256 amountInUPTMin,
        uint256 amountInMemecoinMin
    ) external returns (uint256);

    function registerMemeverse(
        string calldata _name,
        string calldata _symbol,
        string calldata uri,
        address creator,
        address memecoin,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds
    ) external;

    function removeGasDust(address receiver) external;


    function setMemeverseRegistrar(address _registrar) external;

    function setMinTotalFund(uint256 minTotalFund) external;

    function setFundBasedAmount(uint256 fundBasedAmount) external;

    function setAutoBotFeeRate(uint256 autoBotFeeRate) external;

    function setPolImplementation(address polImplementation) external;

    function setVaultImplementation(address vaultImplementation) external;

    function setGovernorImplementation(address governorImplementation) external;

    function setYieldDispatcher(address yieldDispatcher) external;

    function setGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit) external;


    error ZeroInput();

    error FeeRateOverFlow();

    error PermissionDenied();

    error InsufficientLzFee();

    error InsufficientUserFunds();

    error NotGenesisStage(uint256 endTime);

    error ExpiredSignature(uint256 deadline);

    error InTheGenesisStage(uint256 endTime);

    error NotRefundStage(Stage currentStage);

    error NotLockedStage(Stage currentStage);

    error NotUnlockedStage(Stage currentStage);

    event Genesis(
        uint256 indexed verseId,
        address indexed depositer,
        uint256 increasedMemecoinFund,
        uint256 increasedLiquidProofFund
    );

    event Refund(uint256 indexed verseId, address indexed receiver, uint256 refundAmount);

    event ChangeStage(uint256 indexed verseId, Stage currentStage, address memecoinYieldVault);

    event ClaimLiquidProof(uint256 indexed verseId, address indexed receiver, uint256 claimedAmount);

    event RedeemAndDistributeFees(
        uint256 indexed verseId, 
        bool indexed isLocalBurned, 
        uint256 govFee, 
        uint256 memecoinFee, 
        uint256 autoBotFee, 
        uint256 burnedUPT, 
        uint256 burnedLiquidProof
    );

    event RedeemLiquidity(uint256 indexed verseId, address indexed receiver, uint256 liquidity);

    event MintLiquidProof(
        uint256 indexed verseId, 
        address indexed memecoin, 
        address indexed liquidProof, 
        address receiver, 
        uint256 amount
    );

    event RegisterMemeverse(uint256 indexed verseId, Memeverse verse);

    event RemoveGasDust(address indexed receiver, uint256 dust);

    event SetMemeverseRegistrar(address registrar);

    event SetMinTotalFund(uint256 minTotalFunds);

    event SetFundBasedAmount(uint256 fundBasedAmount);

    event SetAutoBotFeeRate(uint256 autoBotFeeRate);

    event SetPolImplementation(address polImplementation);

    event SetVaultImplementation(address vaultImplementation);

    event SetGovernorImplementation(address governorImplementation);
    
    event SetYieldDispatcher(address yieldDispatcher);

    event SetGasLimits(uint128 oftReceiveGasLimit, uint128 yieldDispatcherGasLimit);
}
