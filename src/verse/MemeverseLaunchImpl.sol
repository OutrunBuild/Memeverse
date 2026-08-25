// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {TokenHelper} from "../common/token/TokenHelper.sol";
import {DelegatecallOnly} from "../common/access/DelegatecallOnly.sol";
import {IMemecoin} from "../token/interfaces/IMemecoin.sol";
import {IPol} from "../token/interfaces/IPol.sol";
import {IPOLend} from "../polend/interfaces/IPOLend.sol";
import {IPOLSplitter} from "../polend/interfaces/IPOLSplitter.sol";
import {IMemecoinYieldVault} from "../yield/interfaces/IMemecoinYieldVault.sol";
import {IMemeverseProxyDeployer} from "./interfaces/IMemeverseProxyDeployer.sol";
import {ILzEndpointRegistry} from "../common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {IMemeverseLauncher} from "./interfaces/IMemeverseLauncher.sol";
import {MemeverseLauncherStorage} from "./interfaces/IMemeverseLauncherStorage.sol";
import {MemeverseLauncherLib} from "./libraries/MemeverseLauncherLib.sol";
import {IMemeverseLiquidityImpl} from "./interfaces/IMemeverseLiquidityImpl.sol";
import {IMemeverseSettlementImpl} from "./interfaces/IMemeverseSettlementImpl.sol";

/// @title MemeverseLaunchImpl
/// @notice Delegatecall-only sibling that owns the launch-lifecycle flows for MemeverseLauncherUpgradeable: verse
///         registration (memecoin/POL deploy, LayerZero peer wiring, verse config storage), genesis and
///         preorder deposits, and the adaptive `changeStage` dispatcher (Genesis -> Locked/Refund,
///         Locked -> Unlocked).
/// @dev Binds the launcher's ERC-7201 namespace, so under delegatecall `msg.sender` is the facade's
///      original caller (registrar, genesis/preorder depositor, or stage advancer) and `address(this)`
///      is the launcher proxy; no initializer, owner, or own state, and direct calls revert via the
///      inherited `onlyDelegatecall` guard. Nested types live in IMemeverseLauncher and are qualified
///      as `IMemeverseLauncher.X` below.
///      ACL that must travel with the call (e.g. the `msg.sender == memeverseRegistrar` check in
///      `registerMemeverse`) stays in the body and resolves correctly under delegatecall. The facade
///      keeps the outer `versIdValidate` / `whenNotPaused` guards and re-applies them before
///      delegatecalling, so this sibling does NOT re-apply them.
contract MemeverseLaunchImpl layout at erc7201("outrun.storage.MemeverseLauncher") is TokenHelper, DelegatecallOnly {
    using Address for address;

    MemeverseLauncherStorage private memeverseLauncherStorage;

    // =========================================================================================================
    // Verse registration (relocated from MemeverseLauncherUpgradeable facade; bodies byte-for-byte, only the
    // `whenNotPaused` modifier moved back to the facade — the `msg.sender == memeverseRegistrar` ACL stays
    // in the body because it travels correctly under delegatecall).
    // =========================================================================================================

    /// See `IMemeverseLaunchImpl.registerMemeverse` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `whenNotPaused` guard; this sibling owns the registrar ACL,
    ///      fund-metadata validation, token deploy, LayerZero peer wiring, verse storage, and emit.
    function registerMemeverse(
        string calldata name,
        string calldata symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        address uAsset,
        bool flashGenesis
    ) external onlyDelegatecall {
        require(msg.sender == memeverseLauncherStorage.memeverseRegistrar, IMemeverseLauncher.PermissionDenied());
        require(
            memeverseLauncherStorage.polend != address(0) && memeverseLauncherStorage.polSplitter != address(0),
            IMemeverseLauncher.PermissionDenied()
        );
        require(uAsset != address(0), IMemeverseLauncher.ZeroInput());
        require(omnichainIds.length != 0, IMemeverseLauncher.InvalidLength());
        IMemeverseLauncher.FundMetaData memory fundMetaData = memeverseLauncherStorage.fundMetaDatas[uAsset];
        require(fundMetaData.minTotalFund != 0 && fundMetaData.fundBasedAmount != 0, IMemeverseLauncher.ZeroInput());

        (address memecoin, address pol) = _deployAndInitializeVerseTokens(uniqueId, name, symbol);
        _lzConfigure(memecoin, pol, omnichainIds);
        _storeRegisteredMemeverse(
            uniqueId, name, symbol, uAsset, memecoin, pol, endTime, unlockTime, omnichainIds, flashGenesis
        );

        memeverseLauncherStorage.memecoinToIds[memecoin] = uniqueId;
        memeverseLauncherStorage.polToIds[pol] = uniqueId;
        IPOLend(memeverseLauncherStorage.polend).registerLendMarket(uniqueId);

        emit IMemeverseLauncher.RegisterMemeverse(uniqueId, memeverseLauncherStorage.memeverses[uniqueId]);
    }

    function _storeRegisteredMemeverse(
        uint256 uniqueId,
        string calldata name,
        string calldata symbol,
        address uAsset,
        address memecoin,
        address pol,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] calldata omnichainIds,
        bool flashGenesis
    ) internal {
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[uniqueId];
        verse.name = name;
        verse.symbol = symbol;
        verse.uAsset = uAsset;
        verse.memecoin = memecoin;
        verse.pol = pol;
        verse.endTime = endTime;
        verse.unlockTime = unlockTime;
        verse.omnichainIds = omnichainIds;
        verse.flashGenesis = flashGenesis;
    }

    function _deployAndInitializeVerseTokens(uint256 uniqueId, string calldata name, string calldata symbol)
        internal
        returns (address memecoin, address pol)
    {
        IMemeverseProxyDeployer deployer = IMemeverseProxyDeployer(memeverseLauncherStorage.memeverseProxyDeployer);
        memecoin = deployer.deployMemecoin(uniqueId);
        pol = deployer.deployPOL(uniqueId);
        IMemecoin(memecoin).initialize(name, symbol, address(this), address(this));
        IPol(pol)
            .initialize(
                // POL token name/symbol uses the fixed "POL-" + verse name/symbol prefix naming convention.
                string(abi.encodePacked("POL-", name)),
                string(abi.encodePacked("POL-", symbol)),
                memecoin,
                address(this),
                address(this)
            );
    }

    /// @dev Memecoin Layerzero configure. See: https://docs.layerzero.network/v2/developers/evm/create-lz-oapp/configuring-pathways
    function _lzConfigure(address memecoin, address pol, uint32[] memory omnichainIds) internal {
        uint32 currentChainId = uint32(block.chainid);
        uint256 omnichainIdsLength = omnichainIds.length;

        // Use default config
        address _lzEndpointRegistry = memeverseLauncherStorage.lzEndpointRegistry;
        for (uint256 i = 0; i < omnichainIdsLength;) {
            uint32 omnichainId = omnichainIds[i];
            unchecked {
                ++i;
            }
            if (omnichainId == currentChainId) continue;

            uint32 remoteEndpointId = ILzEndpointRegistry(_lzEndpointRegistry).lzEndpointIdOfChain(omnichainId);
            require(remoteEndpointId != 0, IMemeverseLauncher.InvalidOmnichainId(omnichainId));

            // Peer = LOCAL token address. This assumes a same-address multichain deployment: every chain deploys
            // memecoin/POL with the same clone salt (uniqueId) and the same implementation address, so local ==
            // remote. Implementation-address drift across chains makes LayerZero's OnlyPeer reject messages permanently.
            IOAppCore(memecoin).setPeer(remoteEndpointId, bytes32(uint256(uint160(memecoin))));
            IOAppCore(pol).setPeer(remoteEndpointId, bytes32(uint256(uint160(pol))));
        }
    }

    // =========================================================================================================
    // Genesis + preorder deposits (relocated from MemeverseLauncherUpgradeable facade; bodies byte-for-byte, only the
    // `versIdValidate` / `whenNotPaused` modifiers moved back to the facade).
    // =========================================================================================================

    /// See `IMemeverseLaunchImpl.genesis` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `versIdValidate` + `whenNotPaused` guards; this sibling owns the
    ///      stage check, cap check, accounting update, transfer-in, and emit.
    function genesis(uint256 verseId, uint256 amountInUAsset, address user) external onlyDelegatecall {
        _genesis(verseId, amountInUAsset, user);
    }

    /**
     * @dev Genesis deposit core logic, shared by `genesis` and `genesisAndPreorder`. Owns the stage check,
     *      the aggregate cap check, the accounting update, the transfer-in, and the emit. CEI-ordered.
     */
    function _genesis(uint256 verseId, uint256 amountInUAsset, address user) internal {
        require(verseId != 0 && amountInUAsset != 0 && user != address(0), IMemeverseLauncher.ZeroInput());
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Genesis, IMemeverseLauncher.NotGenesisStage());
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 currentTotalGenesisFunds =
            normalFunds + IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 projectedTotalGenesisFunds = currentTotalGenesisFunds + amountInUAsset;
        if (projectedTotalGenesisFunds > MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS) {
            revert IMemeverseLauncher.TotalGenesisFundsTooHigh(
                projectedTotalGenesisFunds, MemeverseLauncherLib.MAX_SUPPORTED_TOTAL_GENESIS_FUNDS
            );
        }

        memeverseLauncherStorage.totalNormalFunds[verseId] = normalFunds + amountInUAsset;
        // The aggregate cap check above bounds projected total genesis funds (hence this deposit's
        // amountInUAsset) at uint128.max, so the narrowing cast cannot truncate. See GenesisData.genesisFund.
        memeverseLauncherStorage.userGenesisData[verseId][user].genesisFund += uint128(amountInUAsset);

        _transferIn(verse.uAsset, msg.sender, amountInUAsset);

        emit IMemeverseLauncher.Genesis(verseId, msg.sender, user, amountInUAsset);
    }

    /// See `IMemeverseLaunchImpl.preorder` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `versIdValidate` + `whenNotPaused` guards; this sibling owns the
    ///      stage check, capacity check (via the shared `MemeverseLauncherLib.preorderMaxCapacity` helper
    ///      so the cap cannot drift from the facade view), accounting update, transfer-in, and emit. The
    ///      preorder pool is capped relative to the current memecoin-side genesis funds.
    function preorder(uint256 verseId, uint256 amountInUAsset, address user) external onlyDelegatecall {
        _preorder(verseId, amountInUAsset, user);
    }

    /**
     * @dev Preorder deposit core logic, shared by `preorder` and `genesisAndPreorder`. Reads the live
     *      `totalNormalFunds` (already incremented when called right after `_genesis` in the combined entry, so
     *      the capacity check reflects the genesis top-up) and enforces the cap with `InvalidLength`.
     *      CEI-ordered.
     */
    function _preorder(uint256 verseId, uint256 amountInUAsset, address user) internal {
        require(verseId != 0 && amountInUAsset != 0 && user != address(0), IMemeverseLauncher.ZeroInput());
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        require(verse.currentStage == IMemeverseLauncher.Stage.Genesis, IMemeverseLauncher.NotGenesisStage());

        IMemeverseLauncher.PreorderState storage preorderState = memeverseLauncherStorage.preorderStates[verseId];
        uint256 nextTotalPreorderFunds = preorderState.totalFunds + amountInUAsset;
        uint256 totalLeveragedDebt = IPOLend(memeverseLauncherStorage.polend).getTotalLeveragedDebt(verseId);
        uint256 normalFunds = memeverseLauncherStorage.totalNormalFunds[verseId];
        uint256 totalBaseFunds = MemeverseLauncherLib.checkedTotalGenesisFunds(normalFunds, totalLeveragedDebt);
        uint256 maxCapacity = MemeverseLauncherLib.preorderMaxCapacity(memeverseLauncherStorage, totalBaseFunds);
        require(nextTotalPreorderFunds <= maxCapacity, IMemeverseLauncher.InvalidLength());

        preorderState.totalFunds = nextTotalPreorderFunds;
        memeverseLauncherStorage.userPreorderData[verseId][user].funds += amountInUAsset;

        _transferIn(verse.uAsset, msg.sender, amountInUAsset);

        emit IMemeverseLauncher.Preorder(verseId, msg.sender, user, amountInUAsset);
    }

    /// See `IMemeverseLaunchImpl.genesisAndPreorder` for the full facade-facing documentation.
    /// @dev Runs `_genesis` first (which writes `totalNormalFunds` before returning) so the subsequent
    ///      `_preorder` capacity check sees the enlarged base, letting the same payer secure preorder
    ///      capacity the genesis top-up just opened. Both helpers re-check the Genesis stage and emit
    ///      their own events. If `_preorder` reverts (e.g. the preorder amount exceeds the enlarged cap),
    ///      the whole transaction reverts, so genesis accounting and the uAsset transfer-in never
    ///      partially apply.
    function genesisAndPreorder(uint256 verseId, uint256 genesisAmount, uint256 preorderAmount, address user)
        external
        onlyDelegatecall
    {
        require(
            verseId != 0 && genesisAmount != 0 && preorderAmount != 0 && user != address(0),
            IMemeverseLauncher.ZeroInput()
        );
        _genesis(verseId, genesisAmount, user);
        _preorder(verseId, preorderAmount, user);
    }

    // =========================================================================================================
    // changeStage dispatcher (relocated from MemeverseLauncherUpgradeable facade; body byte-for-byte, only the
    // `versIdValidate` modifier moved back to the facade). The Genesis branch runs the bootstrap deploy
    // chain inline and ends with a nested delegatecall into the liquidity sibling; the Locked branch issues
    // a nested delegatecall into the settlement sibling. Both nested delegatecalls are
    // delegatecall-within-delegatecall: the sibling addresses are read from `memeverseLauncherStorage` and
    // the call runs in the proxy context.
    // =========================================================================================================

    /// See `IMemeverseLaunchImpl.changeStage` for the full facade-facing documentation.
    /// @dev The facade keeps the outer `versIdValidate` guard; this sibling owns the eligibility checks.
    ///      Ordering invariant (reentrancy-critical): in the Genesis->Locked branch `verse.currentStage =
    ///      Stage.Locked` is written BEFORE `_deployAndSetupMemeverse`, which performs external token deploys
    ///      and router calls; the reentrancy test depends on observing the Locked stage during these calls.
    ///      Intentionally omits `whenNotPaused` and `nonReentrant` (mirrors the facade): settlement flows must
    ///      stay executable during a pause, and the Locked->Unlocked transition relies on cross-contract
    ///      callbacks (`IPOLSplitter.settle`, `IPOLend.executeGlobalSettlement`) that must re-enter the launcher.
    function changeStage(uint256 verseId) external onlyDelegatecall returns (IMemeverseLauncher.Stage currentStage) {
        require(verseId != 0, IMemeverseLauncher.ZeroInput());
        uint256 currentTime = block.timestamp;
        IMemeverseLauncher.Memeverse storage verse = memeverseLauncherStorage.memeverses[verseId];
        currentStage = verse.currentStage;
        require(
            currentStage != IMemeverseLauncher.Stage.Refund && currentStage != IMemeverseLauncher.Stage.Unlocked,
            IMemeverseLauncher.ReachedFinalStage()
        );

        if (currentStage == IMemeverseLauncher.Stage.Genesis) {
            // Genesis is the only stage that can resolve into either a successful launch or a refund outcome.
            currentStage = _handleGenesisStage(verseId, currentTime, verse);
        } else if (currentStage == IMemeverseLauncher.Stage.Locked && currentTime > verse.unlockTime) {
            address impl = memeverseLauncherStorage.settlementImpl;
            require(impl != address(0), IMemeverseLauncher.SettlementImplNotSet());
            impl.functionDelegateCall(
                abi.encodeWithSelector(
                    IMemeverseSettlementImpl.unlockFromLocked.selector,
                    verseId,
                    memeverseLauncherStorage.polSplitter,
                    memeverseLauncherStorage.memeverseUniswapHook
                )
            );
            currentStage = IMemeverseLauncher.Stage.Unlocked;
        }

        emit IMemeverseLauncher.ChangeStage(verseId, currentStage);
    }

    /// @notice Resolves a verse out of the Genesis stage: into `Locked` (successful launch) or `Refund` (missed min).
    /// @dev Launch readiness is judged against actual uAsset paid (interest), while post-launch fund sizing uses the
    /// derived debt principal.
    function _handleGenesisStage(uint256 verseId, uint256 currentTime, IMemeverseLauncher.Memeverse storage verse)
        internal
        returns (IMemeverseLauncher.Stage currentStage)
    {
        address _polend = memeverseLauncherStorage.polend;
        address _polSplitter = memeverseLauncherStorage.polSplitter;
        address uAsset = verse.uAsset;
        uint256 minTotalFund = memeverseLauncherStorage.fundMetaDatas[uAsset].minTotalFund;
        uint256 totalLeveragedInterest = IPOLend(_polend).getTotalLeveragedInterest(verseId);
        uint256 totalLeveragedDebt = IPOLend(_polend).getTotalLeveragedDebt(verseId);
        // The launch gate measures paid interest (real uAsset users committed), not the derived debt principal;
        // `totalLeveragedDebt` is only used downstream to size the four deployment pools.
        bool leveragedLaunchReady = totalLeveragedInterest >= minTotalFund;
        bool meetMinTotalFund =
            memeverseLauncherStorage.totalNormalFunds[verseId] >= minTotalFund || leveragedLaunchReady;
        uint256 endTime = verse.endTime;

        if ((verse.flashGenesis && meetMinTotalFund) || (currentTime > endTime && meetMinTotalFund)) {
            // Reentrancy-critical ordering: stamp Locked BEFORE the deploy chain so reentrant calls observe
            // the post-genesis stage during the external token deploys and router calls.
            verse.currentStage = IMemeverseLauncher.Stage.Locked;
            _deployAndSetupMemeverse(verseId, verse, uAsset, totalLeveragedDebt, _polend, _polSplitter);
            return IMemeverseLauncher.Stage.Locked;
        }

        // Missing the minimum at `endTime` permanently sends the verse into the refund branch; there is no partial launch path.
        require(currentTime > endTime, IMemeverseLauncher.StillInGenesisStage(endTime));
        verse.currentStage = IMemeverseLauncher.Stage.Refund;
        if (totalLeveragedDebt != 0) IPOLend(_polend).markRefundable(verseId);
        return IMemeverseLauncher.Stage.Refund;
    }

    function _deployAndSetupMemeverse(
        uint256 verseId,
        IMemeverseLauncher.Memeverse storage verse,
        address uAsset,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) internal {
        string memory name = verse.name;
        string memory symbol = verse.symbol;
        address memecoin = verse.memecoin;
        address pol = verse.pol;
        uint32 govChainId = verse.omnichainIds[0];

        if (totalLeveragedDebt != 0) IPOLend(_polend).finalizeLeveragedGenesis(verseId);
        IPOLSplitter(_polSplitter).initializeVerse(verseId, pol, memecoin, uAsset, name, symbol);

        _deployLiquidity(verseId, uAsset, memecoin, pol, totalLeveragedDebt, _polend, _polSplitter);

        (address yieldVault, address governor, address incentivizer) =
            _deployGovernanceComponents(verseId, govChainId, name, symbol, uAsset, memecoin, pol);
        verse.yieldVault = yieldVault;
        verse.governor = governor;
        verse.incentivizer = incentivizer;
    }

    function _deployGovernanceComponents(
        uint256 verseId,
        uint32 govChainId,
        string memory name,
        string memory symbol,
        address uAsset,
        address memecoin,
        address pol
    ) internal returns (address yieldVault, address governor, address incentivizer) {
        uint256 proposalThreshold = IMemecoin(memecoin).totalSupply() / 50;
        address _proxyDeployer = memeverseLauncherStorage.memeverseProxyDeployer;

        if (govChainId == block.chainid) {
            // On the governance chain we deploy concrete contracts immediately because fee distribution will target them locally.
            yieldVault = IMemeverseProxyDeployer(_proxyDeployer).deployYieldVault(verseId);
            // Size the permanent virtual buffer from the per-uAsset fund metadata: 0.7% of the minimum
            // main-pool memecoin provision. registerMemeverse already enforces both fields are non-zero.
            IMemeverseLauncher.FundMetaData storage _meta = memeverseLauncherStorage.fundMetaDatas[uAsset];
            uint256 _virtualAssets = MemeverseLauncherLib.virtualAssetsBuffer(_meta.minTotalFund, _meta.fundBasedAmount);
            IMemecoinYieldVault(yieldVault)
                .initialize(
                    string(abi.encodePacked("Staked ", name)),
                    string(abi.encodePacked("s", symbol)),
                    memecoin,
                    verseId,
                    _virtualAssets
                );
            (governor, incentivizer) = IMemeverseProxyDeployer(_proxyDeployer)
                .deployGovernorAndIncentivizer(name, uAsset, memecoin, pol, yieldVault, verseId, proposalThreshold);
        } else {
            // Remote governance chains receive bridged assets later, so launcher only records the deterministic target addresses here.
            yieldVault = IMemeverseProxyDeployer(_proxyDeployer).predictYieldVaultAddress(verseId);
            (governor, incentivizer) =
                IMemeverseProxyDeployer(_proxyDeployer).computeGovernorAndIncentivizerAddress(verseId);
        }
    }

    function _deployLiquidity(
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        uint256 totalLeveragedDebt,
        address _polend,
        address _polSplitter
    ) internal {
        address impl = memeverseLauncherStorage.liquidityImpl;
        require(impl != address(0), IMemeverseLauncher.LiquidityImplNotSet());
        // OZ functionDelegateCall returns bytes memory AND bubbles the sibling's revert reason.
        // deployBootstrapLiquidity is void; the return value is discarded. This is a nested delegatecall
        // (delegatecall-within-delegatecall): it reads the proxy's storage and runs in the proxy context.
        impl.functionDelegateCall(
            abi.encodeWithSelector(
                IMemeverseLiquidityImpl.deployBootstrapLiquidity.selector,
                verseId,
                uAsset,
                memecoin,
                pol,
                totalLeveragedDebt,
                _polend,
                _polSplitter
            )
        );
    }
}
