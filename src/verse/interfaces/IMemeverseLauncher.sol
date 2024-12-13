// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

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
        address memecoin;               // Memecoin address
        address liquidProof;            // Liquidity proof token address
        address memecoinVault;          // Memecoin yield vault
        uint128 maxFund;                // Max fundraising(UPT) limit, if 0 => no limit
        uint64 endTime;                 // EndTime of launchPool
        uint64 unlockTime;              // UnlockTime of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        Stage currentStage;             // Current stage 
    }

    struct GenesisFund {
        uint128 totalMemecoinFunds;      // Initial fundraising(UPT) for memecoin liquidity
        uint128 totalLiquidProofFunds;   // Initial fundraising(UPT) for liquidProof liquidity
    }


    function getMemeverseUnlockTime(uint256 verseId) external view  returns (uint256 unlockTime);

    function claimableLiquidProof(uint256 verseId) external view returns (uint256 claimableAmount);

    function previewTransactionFees(uint256 verseId) external view returns (uint256 UPTFee, uint256 memecoinYields);

    function genesis(uint256 verseId, uint256 amountInUPT) external;

    function refund(uint256 verseId) external returns (uint256 userFunds);

    function changeStage(uint256 verseId) external payable returns (Stage currentStage);

    function claimLiquidProof(uint256 verseId) external returns (uint256 amount);

    function redeemLiquidity(uint256 verseId, uint256 proofTokenAmount) external;

    function redeemAndDistributeFees(uint256 verseId) external returns (uint256 UPTFee, uint256 memecoinYields, uint256 liquidProofFee);

    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address creator,
        address memecoin,
        address liquidProof,
        uint256 uniqueId,
        uint64 endTime,
        uint64 unlockTime,
        uint128 maxFund,
        uint32[] calldata omnichainIds
    ) external;

    function setMemeverseRegistrar(address _registrar) external;

    function setRevenuePool(address revenuePool) external;

    function setMinTotalFund(uint256 minTotalFund) external;

    function setFundBasedAmount(uint256 fundBasedAmount) external;
    

    error ZeroInput();

    error PermissionDenied();

    error InvalidRegisterInfo();

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

    event Refund(
        uint256 indexed verseId, 
        address indexed receiver, 
        uint256 refundAmount
    );

    event ClaimLiquidProof(
        uint256 indexed verseId, 
        address indexed receiver, 
        uint256 claimedAmount
    );

    event RedeemLiquidity(
        uint256 indexed verseId, 
        address indexed receiver, 
        uint256 liquidity
    );

    event RedeemAndDistributeFees(
        uint256 indexed verseId, 
        address indexed owner, 
        uint256 UPTFee, 
        uint256 memecoinYields, 
        uint256 liquidProofFee
    );

    event RegisterMemeverse(
        uint256 indexed verseId, 
        address indexed owner, 
        address indexed memecoin, 
        address liquidProof,
        address memecoinVault,
        uint32[] omnichainIds
    );
}
