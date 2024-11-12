// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC721, ERC721Burnable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";

import { Memecoin, IMemecoin, IERC20 } from "../token/Memecoin.sol";
import { IMemeverse } from "./interfaces/IMemeverse.sol";
import { IOutrunAMMPair } from "../libraries/IOutrunAMMPair.sol";
import { IOutrunAMMRouter } from "../libraries/IOutrunAMMRouter.sol";
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
    uint256 public minTotalFunds;
    uint256 public fundBasedAmount;
    uint128 public minDurationDays;
    uint128 public maxDurationDays;
    uint128 public minLockupDays;
    uint128 public maxLockupDays;

    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => uint256) public claimableLiquidProofs;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;

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

    function getMemeverseUnlockTime(uint256 verseId) external view override returns (uint256 unlockTime) {
        Memeverse storage verse = memeverses[verseId];
        unlockTime = verse.endTime + verse.lockupDays * DAY;
    }

    /**
     * @dev Preview claimable liquidProof of user in stage Locked
     * @param verseId - Memeverse id
     */
    function claimableLiquidProof(uint256 verseId) public view override returns (uint256 claimableAmount) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(verse.currentStage == Stage.Locked, NotLockedStage(currentStage));

        uint256 totalFunds = genesisFunds[verseId].totalMemecoinFunds + genesisFunds[verseId].totalLiquidProofFunds;
        uint256 userFunds = userTotalFunds[verseId][msg.sender];
        uint256 totalUserLiquidProof = claimableLiquidProofs[verseId];
        claimableAmount = totalUserLiquidProof * userFunds / totalFunds;
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
        uint256 _minTotalFunds,
        uint256 _fundBasedAmount,
        uint128 _minDurationDays,
        uint128 _maxDurationDays,
        uint128 _minLockupDays,
        uint128 _maxLockupDays
    ) external override initializer onlyOwner {
        genesisFee = _genesisFee;
        minTotalFunds = _minTotalFunds;
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
        uint256 endTime = verse.endTime;
        uint256 currentTime = block.timestamp;
        require(currentTime < endTime, NotGenesisStage(endTime));

        
        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        uint256 totalFunds = totalMemecoinFunds + totalLiquidProofFunds;
        uint256 maxFund = verse.maxFund;
        address msgSender = msg.sender;
        if (maxFund !=0 && totalFunds + amountInUPT > maxFund) amountInUPT = maxFund - totalFunds;
        _transferIn(UPT, msgSender, amountInUPT);

        address memecoin = verse.memecoin;
        uint256 increasedMemecoinFund;
        uint256 increasedLiquidProofFund;
        uint256 increasedMemecoinAmount;
        unchecked {
            increasedLiquidProofFund = amountInUPT / 3;
            increasedMemecoinFund = amountInUPT - increasedLiquidProofFund;
            increasedMemecoinAmount = increasedMemecoinFund * fundBasedAmount;
        }
        IMemecoin(memecoin).mint(address(this), increasedMemecoinAmount);

        unchecked {
            genesisFund.totalMemecoinFunds = uint128(totalMemecoinFunds + increasedMemecoinFund);
            genesisFund.totalLiquidProofFunds = uint128(totalLiquidProofFunds + increasedLiquidProofFund);
            userTotalFunds[verseId][msgSender] += amountInUPT;
        }

        emit Genesis(verseId, msgSender, increasedMemecoinFund, increasedLiquidProofFund, increasedMemecoinAmount);
    }

    /**
     * @dev Refund UPT after genesis Failed, total omnichain funds didn't meet the minimum funding requirement
     * @param verseId - Memeverse id
     */
    function refund(uint256 verseId) external override {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Refund, NotRefundStage(currentStage));
        
        address msgSender = msg.sender;
        uint256 userFunds = userTotalFunds[verseId][msgSender];
        require(userFunds > 0, InsufficientUserFunds());
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(UPT, msgSender, userFunds);
        
        emit Refund(verseId, msgSender, userFunds);
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

        bytes32 refundSignedHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(verseId, Stage.Refund, block.chainid, deadline))
        );
        bytes32 LockedSignedHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(verseId, Stage.Locked, block.chainid, deadline))
        );

        if (verse.currentStage == Stage.Genesis) {
            if (signer == ECDSA.recover(refundSignedHash, v, r, s)) {
                // Total omnichain funds didn't meet the minimum funding requirement
                verse.currentStage = Stage.Refund;
                address memecoin = verse.memecoin;
                uint256 selfBalance = _selfBalance(IERC20(memecoin));
                IMemecoin(memecoin).burn(selfBalance);
            } else if (signer == ECDSA.recover(LockedSignedHash, v, r, s)) {
                verse.currentStage = Stage.Locked;

                // Deploy memecoin liquidity
                address memecoin = verse.memecoin;
                GenesisFund storage genesisFund = genesisFunds[verseId];
                uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
                uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
                uint256 memecoinLiquidityAmount = _selfBalance(IERC20(memecoin));
                _safeApproveInf(memecoin, OUTRUN_AMM_ROUTER);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                (,, uint256 memecoinliquidity) = IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    memecoin,
                    totalMemecoinFunds,
                    memecoinLiquidityAmount,
                    totalMemecoinFunds,
                    memecoinLiquidityAmount,
                    address(this),
                    block.timestamp + 600
                );

                // Mint liquidity proof token and deploy liquid proof liquidity
                address liquidProof = verse.liquidProof;
                IMemeLiquidProof(liquidProof).mint(address(this), memecoinliquidity);
                
                _safeApproveInf(liquidProof, OUTRUN_AMM_ROUTER);
                _safeApproveInf(UPT, OUTRUN_AMM_ROUTER);
                uint256 liquidProofLiquidityAmount = memecoinliquidity / 4;
                IOutrunAMMRouter(OUTRUN_AMM_ROUTER).addLiquidity(
                    UPT,
                    liquidProof,
                    totalLiquidProofFunds,
                    liquidProofLiquidityAmount,
                    totalLiquidProofFunds,
                    liquidProofLiquidityAmount,
                    address(0),
                    block.timestamp + 600
                );

                claimableLiquidProofs[verseId] = memecoinliquidity - liquidProofLiquidityAmount;
            } else {
                revert InvalidSigner();
            }
        } else if (verse.currentStage == Stage.Locked && currentTime > endTime + verse.lockupDays * DAY) {
            verse.currentStage = Stage.Unlocked;
        }
    }

    /**
     * @dev Claim liquidProof in stage Locked
     * @param verseId - Memeverse id
     */
    function claimLiquidProof(uint256 verseId) external {
        uint256 claimableAmount = claimableLiquidProof(verseId);
        if (claimableAmount != 0) {
            address msgSender = msg.sender;
            _transferOut(memeverses[verseId].liquidProof, msgSender, claimableAmount);
            userTotalFunds[verseId][msgSender] = 0;

            emit ClaimLiquidProof(verseId, msgSender, claimableAmount);
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
     * @dev register memeverse(single chain)
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param uniqueId - Unique verseId
     * @param durationDays - Duration days of launchpool
     * @param lockupDays - LockupDay of liquidity
     */
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
    ) external payable override {
        require(
            lockupDays >= minLockupDays && 
            lockupDays <= maxLockupDays && 
            durationDays >= minDurationDays && 
            durationDays <= maxDurationDays && 
            bytes(_name).length < 32 && 
            bytes(_symbol).length < 32, 
            InvalidRegisterInfo()
        );

        require(block.timestamp > deadline, ExpiredSignature(deadline));
        bytes32 messageHash = keccak256(abi.encode(
            _name, 
            _symbol, 
            uniqueId, 
            durationDays, 
            lockupDays, 
            block.chainid, 
            deadline
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        require(signer != ECDSA.recover(ethSignedHash, v, r, s), InvalidSigner());

        uint256 _genesisFee = genesisFee;
        require(msg.value >= _genesisFee, InsufficientGenesisFee(_genesisFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        // Deploy memecoin and liquidProof token
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
            string(abi.encodePacked("Staked ", _name)),
            string(abi.encodePacked("s", _symbol)),
            memecoin,
            address(this),
            uniqueId
        ));

        uint32[] memory omnichainIds;
        Memeverse memory verse = Memeverse(
            _name, 
            _symbol, 
            memecoin, 
            liquidProof, 
            memecoinVault, 
            0,
            block.timestamp + durationDays * DAY,
            lockupDays, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        address msgSender = msg.sender;
        _safeMint(msgSender, uniqueId);

        emit RegisterMemeverse(uniqueId, msgSender, memecoin, liquidProof, memecoinVault);
    }

    /**
     * @dev register omnichain memeverse
     * @param _name - Name of memecoin
     * @param _symbol - Symbol of memecoin
     * @param memecoin - Already created omnichain memecoin address
     * @param uniqueId - Unique verseId
     * @param durationDays - Duration days of launchpool
     * @param lockupDays - LockupDay of liquidity
     * @param maxFund - Max fundraising(UPT) limit, if 0 => no limit
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
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
    ) external payable override {
        require(
            lockupDays >= minLockupDays && 
            lockupDays <= maxLockupDays && 
            durationDays >= minDurationDays && 
            durationDays <= maxDurationDays && 
            maxFund > 0 && 
            bytes(_name).length < 32 && 
            bytes(_symbol).length < 32, 
            InvalidRegisterInfo()
        );

        require(block.timestamp > deadline, ExpiredSignature(deadline));
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

        uint256 _genesisFee = genesisFee;
        require(msg.value >= _genesisFee, InsufficientGenesisFee(_genesisFee));
        _transferOut(NATIVE, revenuePool, msg.value);

        // Deploy  liquidProof token
        address liquidProof = address(new MemeLiquidProof(
            string(abi.encodePacked(_name, " Liquid")),
            string(abi.encodePacked(_symbol, " LIQUID")),
            18,
            memecoin,
            address(this)
        ));

        // Deploy memecoin vault
        address memecoinVault = address(new MemecoinVault(
            string(abi.encodePacked("Staked ", _name)),
            string(abi.encodePacked("s", _symbol)),
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
            maxFund,
            block.timestamp + durationDays * DAY,
            lockupDays, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        address msgSender = msg.sender;
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
     * @dev Set min totalFunds in launch verse
     * @param _minTotalFunds - Min totalFunds
     */
    function setMinTotalFund(uint256 _minTotalFunds) external override onlyOwner {
        require(_minTotalFunds != 0, ZeroInput());

        minTotalFunds = _minTotalFunds;
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
