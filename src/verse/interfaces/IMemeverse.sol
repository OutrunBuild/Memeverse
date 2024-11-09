// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

/**
 * @title Memeverse interface
 */
interface IMemeverse {
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
        uint128 totalMemecoinFunds;      // Initial fundraising(UPT) for memecoin liquidity
        uint128 totalLiquidProofFunds;   // Initial fundraising(UPT) for liquidProof liquidity
        uint256 maxFund;                // Max fundraising(UPT) limit, if 0 => no limit
        uint256 endTime;                // EndTime of launchPool
        uint256 lockupDays;             // LockupDays of liquidity
        uint32[] omnichainIds;          // ChainIds of the token's omnichain(EVM)
        Stage currentStage;             // Current stage 
    }

    function getMemeverseUnlockTime(uint256 verseId) external view  returns (uint256 unlockTime);

    function claimableLiquidProof(uint256 verseId) external view returns (uint256 claimableAmount);

    function previewTransactionFees(uint256 verseId) external view returns (uint256 UPTFee, uint256 memecoinYields);

    function initialize(
        uint256 genesisFee,
        uint256 minTotalFund,
        uint256 fundBasedAmount,
        uint128 minDurationDays,
        uint128 maxDurationDays,
        uint128 minLockupDays,
        uint128 maxLockupDays
    ) external;

    function genesis(uint256 verseId, uint256 amountInUPT) external;

    function refund(uint256 verseId) external;

    function changeStage(
        uint256 verseId, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external;

    function claimLiquidProof(uint256 verseId) external;

    function redeemLiquidity(uint256 verseId, uint256 proofTokenAmount) external;

    function redeemAndDistributeFees(uint256 verseId) external returns (uint256 UPTFee, uint256 memecoinYields);

    function registerMemeverse(
        string calldata _name,
        string calldata _symbol,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable;

    function registerOmnichainMemeverse(
        string calldata _name,
        string calldata _symbol,
        address memecoin,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint128 maxFund,
        uint32[] calldata omnichainIds,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable;

    function setRevenuePool(address revenuePool) external;

    function setGenesisFee(uint256 genesisFee) external;

    function setMinTotalFund(uint256 minTotalFund) external;

    function setFundBasedAmount(uint256 fundBasedAmount) external;

    function setDurationDaysRange(uint128 minDurationDays, uint128 maxDurationDays) external;

    function setLockupDaysRange(uint128 minLockupDays, uint128 maxLockupDays) external;
    
    error ZeroInput();

    error ErrorInput();

    error InvalidSigner();

    error PermissionDenied();

    error InvalidRegisterInfo();

    error NotGenesisStage(uint256 endTime);

    error ExpiredSignature(uint256 deadline);

    error InTheGenesisStage(uint256 endTime);

    error NotRefundStage(Stage currentStage);

    error NotLockedStage(Stage currentStage);

    error NotUnlockedStage(Stage currentStage);

    error InsufficientGenesisFee(uint256 genesisFee);

    event Genesis(
        uint256 indexed verseId, 
        address indexed depositer, 
        uint256 amountInUPTWithMeme, 
        uint256 amountInUPTWithLP
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
        uint256 memecoinYields
    );

    event RegisterMemeverse(
        uint256 indexed verseId, 
        address indexed owner, 
        address memecoin, 
        address liquidProof,
        address memecoinVault
    );

    event UpdateSigner(
        address indexed oldSigner, 
        address indexed newSigner
    );
}
