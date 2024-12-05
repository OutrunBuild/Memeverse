// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC721, ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

import { Memecoin, IMemecoin, IERC20 } from "../token/Memecoin.sol";
import { IMemeverseLauncher } from "./interfaces/IMemeverseLauncher.sol";
import { IOutrunAMMPair } from "../common/IOutrunAMMPair.sol";
import { IOutrunAMMRouter } from "../common/IOutrunAMMRouter.sol";
import { TokenHelper } from "../common/TokenHelper.sol";
import { OutrunAMMLibrary } from "../libraries/OutrunAMMLibrary.sol";
import { MemecoinVault, IMemecoinVault } from "../yield/MemecoinVault.sol";
import { MemeLiquidProof, IMemeLiquidProof } from "../token/MemeLiquidProof.sol";
import { IMemeverseRegistrar } from "../token/interfaces/IMemeverseRegistrar.sol";

/**
 * @title Trapping into the memeverse
 */
contract MemeverseLauncher is IMemeverseLauncher, ERC721URIStorage, TokenHelper, Ownable {
    uint256 public constant SWAP_FEERATE = 100;
    address public immutable OUTRUN_AMM_ROUTER;
    address public immutable OUTRUN_AMM_FACTORY;
    address public immutable UPT;

    address public memeverseRegistrar;
    address public revenuePool;
    uint256 public minTotalFunds;
    uint256 public fundBasedAmount;

    mapping(uint256 verseId => Memeverse) public memeverses;
    mapping(uint256 verseId => uint256) public claimableLiquidProofs;
    mapping(uint256 verseId => GenesisFund) public genesisFunds;
    mapping(uint256 verseId => mapping(address account => uint256)) public userTotalFunds;

    constructor(
        string memory _name,
        string memory _symbol,
        address _UPT,
        address _owner,
        address _revenuePool,
        address _outrunAMMFactory,
        address _outrunAMMRouter,
        uint256 _minTotalFunds,
        uint256 _fundBasedAmount
    ) ERC721(_name, _symbol) Ownable(_owner) {
        UPT = _UPT;
        revenuePool = _revenuePool;
        OUTRUN_AMM_ROUTER = _outrunAMMRouter;
        OUTRUN_AMM_FACTORY = _outrunAMMFactory;
        minTotalFunds = _minTotalFunds;
        fundBasedAmount = _fundBasedAmount;

        _safeApproveInf(_UPT, _outrunAMMRouter);
    }

    function getMemeverseUnlockTime(uint256 verseId) external view override returns (uint256 unlockTime) {
        Memeverse storage verse = memeverses[verseId];
        unlockTime = verse.unlockTime;
    }

    /**
     * @dev Preview claimable liquidProof of user in stage Locked
     * @param verseId - Memeverse id
     */
    function claimableLiquidProof(uint256 verseId) public view override returns (uint256 claimableAmount) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Locked, NotLockedStage(currentStage));

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
    function refund(uint256 verseId) external override returns (uint256 userFunds) {
        Memeverse storage verse = memeverses[verseId];
        Stage currentStage = verse.currentStage;
        require(currentStage == Stage.Refund, NotRefundStage(currentStage));
        
        address msgSender = msg.sender;
        userFunds = userTotalFunds[verseId][msgSender];
        require(userFunds > 0, InsufficientUserFunds());
        userTotalFunds[verseId][msgSender] = 0;
        _transferOut(UPT, msgSender, userFunds);
        
        emit Refund(verseId, msgSender, userFunds);
    }

    /**
     * @dev Adaptively change the Memeverse stage
     * @param verseId - Memeverse id
     */
    function changeStage(uint256 verseId) external payable override returns (Stage currentStage) {
        Memeverse storage verse = memeverses[verseId];
        uint256 currentTime = block.timestamp;
        uint256 endTime = verse.endTime;
        require(currentTime > endTime, InTheGenesisStage(endTime));

        GenesisFund storage genesisFund = genesisFunds[verseId];
        uint128 totalMemecoinFunds = genesisFund.totalMemecoinFunds;
        uint128 totalLiquidProofFunds = genesisFund.totalLiquidProofFunds;
        if (verse.currentStage == Stage.Genesis) {
            if (totalMemecoinFunds + totalLiquidProofFunds < minTotalFunds) {
                address memecoin = verse.memecoin;
                uint256 selfBalance = _selfBalance(IERC20(memecoin));
                IMemecoin(memecoin).burn(selfBalance);

                verse.currentStage = Stage.Refund;
                currentStage = Stage.Refund;

                // Cancel registration
                IMemeverseRegistrar(memeverseRegistrar).cancelRegistration{value: msg.value}(verseId, verse.symbol, msg.sender);
            } else {
                // Deploy memecoin liquidity
                address memecoin = verse.memecoin;
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

                verse.currentStage = Stage.Locked;
                currentStage = Stage.Locked;
            }
        } else if (verse.currentStage == Stage.Locked && currentTime > verse.unlockTime) {
            verse.currentStage = Stage.Unlocked;
            currentStage = Stage.Unlocked;
        }
    }

    /**
     * @dev Claim liquidProof in stage Locked
     * @param verseId - Memeverse id
     */
    function claimLiquidProof(uint256 verseId) external returns (uint256 amount) {
        amount = claimableLiquidProof(verseId);
        if (amount != 0) {
            address msgSender = msg.sender;
            userTotalFunds[verseId][msgSender] = 0;
            _transferOut(memeverses[verseId].liquidProof, msgSender, amount);

            emit ClaimLiquidProof(verseId, msgSender, amount);
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
        require(currentStage == Stage.Unlocked, NotUnlockedStage(currentStage));

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
    function redeemAndDistributeFees(uint256 verseId) external override returns (uint256 UPTFee, uint256 memecoinYields, uint256 liquidProofFee) {
        Memeverse storage verse = memeverses[verseId];
        require(verse.currentStage >= Stage.Locked, PermissionDenied());

        // memecoin pair
        address memecoin = verse.memecoin;
        IOutrunAMMPair memecoinPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, memecoin, UPT, SWAP_FEERATE));
        (uint256 amount0, uint256 amount1) = memecoinPair.claimMakerFee();
        address token0 = memecoinPair.token0();
        UPTFee = token0 == UPT ? amount0 : amount1;
        memecoinYields = token0 == memecoin ? amount0 : amount1;

        // liquidProof pair
        address liquidProof = verse.liquidProof;
        IOutrunAMMPair liquidProofPair = IOutrunAMMPair(OutrunAMMLibrary.pairFor(OUTRUN_AMM_FACTORY, liquidProof, UPT, SWAP_FEERATE));
        (uint256 amount2, uint256 amount3) = liquidProofPair.claimMakerFee();
        address token2 = memecoinPair.token0();
        UPTFee = token2 == UPT ? UPTFee + amount2 : UPTFee + amount3;
        liquidProofFee = token2 == liquidProof ? amount2 : amount3;

        if (UPTFee == 0 && memecoinYields == 0 && liquidProofFee == 0) return (0, 0, 0);

        address owner = ownerOf(verseId);
        _transferOut(UPT, ownerOf(verseId), UPTFee);

        address memecoinVault = verse.memecoinVault;
        _safeApproveInf(memecoin, memecoinVault);
        IMemecoinVault(memecoinVault).accumulateYields(memecoinYields);

        _transferOut(liquidProof, revenuePool, liquidProofFee);
        
        emit RedeemAndDistributeFees(verseId, owner, UPTFee, memecoinYields, liquidProofFee);
    }

    /**
     * @dev register omnichain memeverse
     * @param name - Name of memecoin
     * @param symbol - Symbol of memecoin
     * @param memecoin - Already created omnichain memecoin address
     * @param liquidProof - Already created omnichain liquidProof address
     * @param uniqueId - Unique verseId
     * @param endTime - Genesis stage end time
     * @param unlockTime - Unlock time of liquidity
     * @param maxFund - Max fundraising(UPT) limit, if 0 => no limit
     * @param omnichainIds - ChainIds of the token's omnichain(EVM)
     */
    function registerOmnichainMemeverse(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address memecoin,
        address liquidProof,
        uint256 uniqueId,
        uint64 endTime,
        uint64 unlockTime,
        uint128 maxFund,
        uint32[] calldata omnichainIds
    ) external override {
        // Deploy memecoin vault
        address memecoinVault = address(new MemecoinVault(
            string(abi.encodePacked("Staked ", name)),
            string(abi.encodePacked("s", symbol)),
            memecoin,
            address(this),
            uniqueId
        ));

        Memeverse memory verse = Memeverse(
            name, 
            symbol, 
            memecoin, 
            liquidProof, 
            memecoinVault, 
            maxFund,
            endTime,
            unlockTime, 
            omnichainIds,
            Stage.Genesis
        );
        memeverses[uniqueId] = verse;
        address msgSender = msg.sender;
        _safeMint(msgSender, uniqueId);
        _setTokenURI(uniqueId, uri);

        emit RegisterMemeverse(uniqueId, msgSender, memecoin, liquidProof, memecoinVault, omnichainIds);
    }

    /**
     * @dev Set memeverse registrar
     * @param _registrar - Memeverse registrar address
     */
    function setMemeverseRegistrar(address _registrar) external override onlyOwner {
        require(_registrar != address(0), ZeroInput());

        memeverseRegistrar = _registrar;
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
}
