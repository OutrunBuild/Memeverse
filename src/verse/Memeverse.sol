// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC721, ERC721Burnable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";

import { Memecoin, IMemecoin, IERC20 } from "../token/Memecoin.sol";
import { IMemeverse } from "./interfaces/IMemeverse.sol";
import { IOutrunAMMPair } from "../external/IOutrunAMMPair.sol";
import { IOutrunAMMRouter } from "../external/IOutrunAMMRouter.sol";
import { TokenHelper } from "../libraries/TokenHelper.sol";
import { FixedPoint128 } from "../libraries/FixedPoint128.sol";
import { Initializable } from "../libraries/Initializable.sol";
import { OutrunAMMLibrary } from "../libraries/OutrunAMMLibrary.sol";
import { AutoIncrementId } from "../libraries/AutoIncrementId.sol";
import { IMemecoinVault, MemecoinVault } from "../yield/MemecoinVault.sol";
import { MemeLiquidProof, IMemeLiquidProof } from "../token/MemeLiquidProof.sol";

/**
 * @title Trapping into the memeverse
 */
contract Memeverse is IMemeverse, ERC721Burnable, TokenHelper, Ownable, Initializable, AutoIncrementId {
    uint256 public constant DAY = 24 * 3600;
    uint256 public constant SWAP_FEERATE = 100;
    address public immutable OUTRUN_AMM_ROUTER;
    address public immutable OUTRUN_AMM_FACTORY;
    address public immutable UPT;

    address public signer;
    address public revenuePool;
    uint256 public genesisFee;
    uint256 public minTotalFund;
    uint256 public fundBasedAmount;
    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint128 public minLockupDays;
    uint128 public maxLockupDays;

    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => mapping(address account => uint256)) public liquidProofliquiditys;

    constructor(
        string memory _name,
        string memory _symbol,
        address _UPT,
        address _owner,
        address _signer,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter
    ) ERC721(_name, _symbol) Ownable(_owner) {
        UPT = _UPT;
        signer = _signer;
        revenuePool = _revenuePool;
        OUTRUN_AMM_ROUTER = _outrunAMMRouter;
        OUTRUN_AMM_FACTORY = _outrunAMMFactory;

        _safeApproveInf(_UPT, _outrunAMMRouter);
    }

    /**
     * @dev Preview transaction fees for owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     */
    function previewTransactionFees(uint256 verseId) external view override returns (uint256 UPTFee, uint256 memecoinYields) {
        Memeverse storage verse = memeverses[verseId];
        address memecoin = verse.memecoin;
        IOutrunAMMPair pair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));

        (uint256 amount0, uint256 amount1) = pair.previewMakerFee();
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        address token0 = pair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinYields = token0 == memecoin ? amount0 : amount1;
    }

    function initialize(
        uint256 _genesisFee,
        uint256 _minTotalFund,
        uint256 _fundBasedAmount,
        uint128 _minDurationDays,
        uint128 _maxDurationDays,
        uint128 _minLockupDays,
        uint128 _maxLockupDays
    ) external override initializer onlyOwner {
        genesisFee = _genesisFee;
        minTotalFund = _minTotalFund;
        fundBasedAmount = _fundBasedAmount;
        minDurationDays = _minDurationDays;
        maxDurationDays = _maxDurationDays;
        minLockupDays = _minLockupDays;
        maxLockupDays = _maxLockupDays;
    }

    /**
     * @dev Genesis memeverse, deposit UPT to mint memecoin
     * @param verseId - Memeverse id
     * @param amountInUPT - Amount of UPT
     * @notice Approve fund token first
     */
    function genesis(uint256 verseId, uint256 amountInUPT) external override {
        Memeverse storage verse = memeverses[verseId];
        uint256 totalFund = verse.totalFund;
        uint256 maxFund = verse.maxFund;
        address msgSender = msg.sender;
        if (maxFund !=0 && totalFund + amountInUPT > maxFund) amountInUPT = maxFund - totalFund;
        _transferIn(UPT, msgSender, amountInUPT);

        uint256 endTime = verse.endTime;
        uint256 currentTime = block.timestamp;
        require(currentTime < endTime, NotGenesisStage(endTime));

        // Mint memecoin
        address memecoin = verse.memecoin;
        uint256 amountInUPTWithMemecoin;
        uint256 deployMemeAmount;
        unchecked {
            amountInUPTWithMemecoin = 2 * amountInUPT / 3;
            deployMemeAmount = amountInUPTWithMemecoin * fundBasedAmount;
        }
        IMemecoin(memecoin).mint(address(this), deployMemeAmount);

        // Deploy memecoin liquidity
        _safeApproveInf(memecoin, OUTRUN_AMM_ROUTER);
        _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
        (,, uint256 liquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
            UPT,
            memecoin,
            amountInUPTWithMemecoin,
            deployMemeAmount,
            amountInUPTWithMemecoin,
            deployMemeAmount,
            address(this),
            block.timestamp + 600
        );

        // Mint liquidity proof token
        uint256 amountInUPTWithLP;
        uint256 deployLiquidProofAmount;
        unchecked {
            amountInUPTWithLP = amountInUPT / 3;
            deployLiquidProofAmount = liquidity / 4;
        }
        address liquidProof = verse.liquidProof;
        IMemeLiquidProof(liquidProof).mint(address(this), deployLiquidProofAmount);
        IMemeLiquidProof(liquidProof).mint(msgSender, liquidity - deployLiquidProofAmount);
        
        // Deploy liquid proof liquidity
        _safeApproveInf(liquidProof, OUTRUN_AMM_ROUTER);
        _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
        (,, uint256 liquidProofliquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
            UPT,
            liquidProof,
            amountInUPTWithLP,
            deployLiquidProofAmount,
            amountInUPTWithLP,
            deployLiquidProofAmount,
            address(this),
            block.timestamp + 600
        );

        unchecked {
            verse.totalFund += amountInUPTWithMemecoin + amountInUPTWithLP;
            liquidProofliquiditys[verseId][msgSender] += liquidProofliquidity;
        }

        emit Deposit(verseId, msgSender, amountInUPTWithMemecoin, amountInUPTWithLP);
    }

    /**
     * @dev Refund UPT after genesis Failed
     * @param verseId - Memeverse id
     */
    function genesisFailedRefund(uint256 verseId) external override {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Refund, NotRefundStage(currentStage));
        
        // Remove liquidProof liquidity and burn liquidProof
        address msgSender = msg.sender;
        address liquidProof = verse.liquidProof;
        address pairOfLiquidProof = OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, liquidProof, UPT, SWAP_FEERATE);
        IMemeLiquidProof(liquidProof).addTransferWhiteList(pairOfLiquidProof);
        _safeApproveInf(pairOfLiquidProof, OUTRUN_AMM_ROUTER);
        
        uint256 liquidProofliquidity = liquidProofliquiditys[verseId][msgSender];
        (uint256 amountInLiquidProof, uint256 amountInUPTWithLP) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).removeLiquidity(
            liquidProof, UPT, 
            liquidProofliquidity, 
            0, 0, 
            address(this), 
            600
        );
        IMemeLiquidProof(liquidProof).burn(address(this), amountInLiquidProof);
        uint256 msgSenderBalanceOfliquidProof = IERC20(liquidProof).balanceOf(msgSender);
        IMemeLiquidProof(liquidProof).burn(msgSender, msgSenderBalanceOfliquidProof);

        // Remove memecoin liquidity and burn memecoin
        address memecoin = verse.memecoin;
        address pairOfMemecoin = OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE);
        IMemecoin(memecoin).addTransferWhiteList(pairOfMemecoin);
        _safeApproveInf(pairOfMemecoin, OUTRUN_AMM_ROUTER);
        (uint256 amountInMemecoin, uint256 amountInUPTWithMemecoin) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).removeLiquidity(
            memecoin, UPT, 
            amountInLiquidProof + msgSenderBalanceOfliquidProof, 
            0, 0, 
            address(this), 
            600
        );
        IMemecoin(memecoin).burn(amountInMemecoin);

        // Refund UPT
        uint256 refundUPT = amountInUPTWithLP + amountInUPTWithMemecoin;
        _transferOut(UPT, msgSender, refundUPT);

        emit GenesisFailsRefund(verseId, msgSender, refundUPT);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     */
    function changeStage(
        uint256 verseId, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external override {
        uint256 currentTime = block.timestamp;
        require(currentTime > deadline, ExpiredSignature(deadline));

        Memeverse storage verse = memeverses[verseId];
        uint256 endTime = verse.endTime;
        require(currentTime > endTime, InTheGenesisStage(endTime));
        uint256 unlockedTime = endTime + verse.lockupDays * DAY;

        if (verse.currentStage == Stage.Genesis && currentTime > endTime + 14 * DAY) {
            bytes32 messageHash = keccak256(abi.encode(verseId, Stage.Refund, block.chainid, deadline));
            bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
            require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

            verse.currentStage = Stage.Refund;
        } else if (verse.currentStage == Stage.Genesis && currentTime < unlockedTime) {
            bytes32 messageHash = keccak256(abi.encode(verseId, Stage.Locked, block.chainid, deadline));
            bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
            require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

            IMemecoin(verse.memecoin).enableTransfer();
            IMemeLiquidProof(verse.liquidProof).enableTransfer();
            verse.currentStage = Stage.Locked;
        } else if (verse.currentStage == Stage.Locked && currentTime > unlockedTime) {
            verse.currentStage = Stage.Unlocked;
        }
    }

    /**
     * @dev Burn liquidProof to claim the locked liquidity
     * @param verseId - Memeverse id
     * @param proofTokenAmount - Burned liquid proof token amount
     */
    function redeemLiquidity(uint256 verseId, uint256 proofTokenAmount) external {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(verse.currentStage == Stage.Unlocked, NotUnlockedStage(currentStage));

        address msgSender = msg.sender;
        IMemeLiquidProof(verse.liquidProof).burn(msgSender, proofTokenAmount);
        address pair = OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, verse.memecoin, UPT, SWAP_FEERATE);
        _transferOut(pair, msgSender, proofTokenAmount);

        emit RedeemLiquidity(verseId, msgSender, proofTokenAmount);
    }

    /**
     * @dev Redeem transaction fees and distribute them to the owner(UPT) and vault(Memecoin)
     * @param verseId - Memeverse id
     */
    function redeemAndDistributeFees(uint256 verseId) external override returns (uint256 UPTFee, uint256 memecoinYields) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, PermissionDenied());

        address memecoin = verse.memecoin;
        IOutrunAMMPair pair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));

        (uint256 amount0, uint256 amount1) = pair.claimMakerFee();
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        address token0 = pair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinYields = token0 == memecoin ? amount0 : amount1;

        address owner = ownerOf(verseId);
        _transferOut(UPT, ownerOf(verseId), UPTFee);

        address memecoinVault = verse.memecoinVault;
        _safeApproveInf(memecoin, memecoinVault);
        IMemecoinVault(memecoinVault).accumulateYields(memecoinYields);
        
        emit RedeemAndDistributeFees(verseId, owner, UPTFee, memecoinYields);
    }

    /**
     * @dev register memeverse
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param uniqueId - Unique verseId
     * @param durationDays - Duration days of launchpool
     * @param lockupDays - LockupDay of liquidity
     * @param maxFund - Max fundraising(UPT) limit, if 0 => no limit
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
    function registerMemeverse(
        string calldata _name,
        string calldata _symbol,
        uint256 uniqueId,
        uint256 durationDays,
        uint256 lockupDays,
        uint256 maxFund,
        uint24[] calldata omnichainIds,
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external payable override {
        require(block.timestamp > deadline, ExpiredSignature(deadline));
        uint256 _genesisFee = genesisFee;
        require(msg.value >= _genesisFee, InsufficientGenesisFee(_genesisFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        bytes32 messageHash = keccak256(abi.encode(
            _name, 
            _symbol, 
            uniqueId, 
            durationDays, 
            lockupDays, 
            maxFund, 
            omnichainIds, 
            block.chainid, 
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        require(
            lockupDays >= minLockupDays && 
            lockupDays <= maxLockupDays && 
            durationDays >= minDurationDays && 
            durationDays <= maxDurationDays && 
            bytes(_name).length < 32 && 
            bytes(_symbol).length < 32, 
            InvalidRegisterInfo()
        );

        // Deploy memecoin and liquidProof token
        address msgSender = msg.sender;
        address memecoin = address(new Memecoin(_name, _symbol, 18, address(this)));
        address liquidProof = address(new MemeLiquidProof(
            string(abi.encodePacked(_name, " Liquid")),
            string(abi.encodePacked(_symbol, " LIQUID")),
            18,
            memecoin,
            address(this)
        ));

        // Deploy memecoin vault
        address memecoinVault = address(new MemecoinVault(
            string(abi.encodePacked(_name, " Vault")),
            string(abi.encodePacked(_name, " VAULT")),
            memecoin,
            address(this),
            uniqueId
        ));

        Memeverse memory verse = Memeverse(
            _name, 
            _symbol, 
            memecoin, 
            liquidProof, 
            memecoinVault, 
            0, 
            maxFund,
            block.timestamp + durationDays * DAY,
            lockupDays, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        _safeMint(msgSender, uniqueId);

        emit RegisterMemeverse(uniqueId, msgSender, memecoin, liquidProof, memecoinVault);
    }

    function updateSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), ZeroInput());
        address oldSigner = signer;
        signer = newSigner;
        emit UpdateSigner(oldSigner, newSigner);
    }

    /**
     * @dev Set revenuePool
     * @param _revenuePool - Revenue verse address
     */
    function setRevenuePool(address _revenuePool) external override onlyOwner {
        require(_revenuePool != address(0), ZeroInput());

        revenuePool = _revenuePool;
    }

    /**
     * @dev Set genesis fee, prevent spam attacks
     * @param _genesisFee - Genesis Fee
     */
    function setGenesisFee(uint256 _genesisFee) external override onlyOwner {
        genesisFee = _genesisFee;
    }

    /**
     * @dev Set min totalFund in launch verse
     * @param _minTotalFund - Min totalFund
     */
    function setMinTotalFund(uint256 _minTotalFund) external override onlyOwner {
        require(_minTotalFund != 0, ZeroInput());

        minTotalFund = _minTotalFund;
    }

    /**
     * @dev Set token mint amount based fund
     * @param _fundBasedAmount - Token mint amount based fund
     */
    function setFundBasedAmount(uint256 _fundBasedAmount) external override onlyOwner {
        require(_fundBasedAmount != 0, ZeroInput());

        fundBasedAmount = _fundBasedAmount;
    }

    /**
     * @dev Set launch verse duration days range
     * @param _minDurationDays - Min launch verse duration days
     * @param _maxDurationDays - Max launch verse duration days
     */
    function setDurationDaysRange(uint128 _minDurationDays, uint128 _maxDurationDays) external override onlyOwner {
        require(
            _minDurationDays != 0 && 
            _maxDurationDays != 0 && 
            _minDurationDays < _maxDurationDays, 
            ErrorInput()
        );

        minDurationDays = _minDurationDays;
        maxDurationDays = _maxDurationDays;
    }

    /**
     * @dev Set liquidity lockup days range
     * @param _minLockupDays - Min liquidity lockup days
     * @param _maxLockupDays - Max liquidity lockup days
     */
    function setLockupDaysRange(uint128 _minLockupDays, uint128 _maxLockupDays) external override onlyOwner {
        require(
            _minLockupDays != 0 && 
            _maxLockupDays != 0 && 
            _minLockupDays < _maxLockupDays, 
            ErrorInput()
        );

        minLockupDays = _minLockupDays;
        maxLockupDays = _maxLockupDays;
    }
}
