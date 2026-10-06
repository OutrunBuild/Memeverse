// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {MemeverseScript} from "../../script/MemeverseScript.s.sol";
import {IOutrunDeployer} from "../../script/deployment/interfaces/IOutrunDeployer.sol";
import {OutrunDeployer} from "../../script/deployment/OutrunDeployer.sol";
import {YieldDispatcherUpgradeable} from "../../src/verse/YieldDispatcherUpgradeable.sol";
import {OmnichainMemecoinStakerUpgradeable} from "../../src/interoperation/OmnichainMemecoinStakerUpgradeable.sol";
import {MemeverseOmnichainInteroperation} from "../../src/interoperation/MemeverseOmnichainInteroperation.sol";
import {
    MemeverseRegistrationCenterUpgradeable
} from "../../src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol";
import {IMemeverseRegistrationCenter} from "../../src/verse/interfaces/IMemeverseRegistrationCenter.sol";
import {LzEndpointRegistry} from "../../src/common/omnichain/LzEndpointRegistry.sol";
import {ILzEndpointRegistry} from "../../src/common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {LauncherReadinessMockBase} from "../mocks/verse/LauncherReadinessMockBase.sol";
import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";

contract MockScriptLauncher is LauncherReadinessMockBase {
    mapping(address => FundMetaData) internal metadata;

    struct FundMetaData {
        uint256 minTotalFund;
        uint256 fundBasedAmount;
    }

    function setLauncherDependencies(address registrar_, address proxyDeployer_, address yieldDispatcher_) external {
        memeverseRegistrar = registrar_;
        memeverseProxyDeployer = proxyDeployer_;
        yieldDispatcher = yieldDispatcher_;
    }

    function setPolend(address polend_) external {
        polend = polend_;
    }

    function setPolSplitter(address polSplitter_) external {
        polSplitter = polSplitter_;
    }

    function setFundMetaData(address uAsset, uint256 minTotalFund, uint256 fundBasedAmount) external {
        metadata[uAsset] = FundMetaData({minTotalFund: minTotalFund, fundBasedAmount: fundBasedAmount});
    }

    function fundMetaDatas(address uAsset) external view returns (uint256 minTotalFund, uint256 fundBasedAmount) {
        FundMetaData memory data = metadata[uAsset];
        return (data.minTotalFund, data.fundBasedAmount);
    }

    function setLaunchImpl(address impl) external {
        launchImpl = impl;
    }
}

contract MockScriptRegistrar {
    address public MEMEVERSE_LAUNCHER;

    constructor(address launcher_) {
        MEMEVERSE_LAUNCHER = launcher_;
    }
}

contract MockScriptProxyDeployer {
    address public memeverseLauncher;
    address public memecoinImplementation;
    address public polImplementation;
    address public vaultImplementation;
    address public governorImplementation;
    address public incentivizerImplementation;

    constructor(
        address launcher_,
        address memecoinImplementation_,
        address polImplementation_,
        address vaultImplementation_,
        address governorImplementation_,
        address incentivizerImplementation_
    ) {
        memeverseLauncher = launcher_;
        memecoinImplementation = memecoinImplementation_;
        polImplementation = polImplementation_;
        vaultImplementation = vaultImplementation_;
        governorImplementation = governorImplementation_;
        incentivizerImplementation = incentivizerImplementation_;
    }

    // Readiness models pointers that have no code at their targets (the codeless-pin attack path);
    // constructor baking alone cannot re-point one getter for a single test.
    function setMemecoinImplementation(address memecoinImplementation_) external {
        memecoinImplementation = memecoinImplementation_;
    }

    function setPolImplementation(address polImplementation_) external {
        polImplementation = polImplementation_;
    }

    function setVaultImplementation(address vaultImplementation_) external {
        vaultImplementation = vaultImplementation_;
    }

    function setGovernorImplementation(address governorImplementation_) external {
        governorImplementation = governorImplementation_;
    }

    function setIncentivizerImplementation(address incentivizerImplementation_) external {
        incentivizerImplementation = incentivizerImplementation_;
    }
}

// Captures the creationCode passed to OUTRUN_DEPLOYER so a test can execute the script's
// exact constructor-arg encoding and pin its order/count against the real YieldDispatcherUpgradeable.
contract MockScriptOutrunDeployer is IOutrunDeployer {
    struct DeployCall {
        bytes32 salt;
        bytes creationCode;
    }

    bytes public lastCreationCode;
    bytes32 public lastSalt;
    DeployCall[] public deployCalls;

    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed) {
        lastSalt = salt;
        lastCreationCode = creationCode;
        deployCalls.push(DeployCall({salt: salt, creationCode: creationCode}));
        return address(0);
    }

    function getDeployed(address, bytes32) external view returns (address deployed) {
        return address(0);
    }
}

contract MockScriptYieldDispatcher {
    address public memeverseLauncher;
    address public localEndpoint;

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
    }

    function setLocalEndpoint(address localEndpoint_) external {
        localEndpoint = localEndpoint_;
    }
}

contract MockScriptPOLend {
    address public launcher;
    address public splitter;
    address public creditFactory;
    mapping(address => DustState) internal dustStates;

    struct DustState {
        uint128 reserve;
        uint128 maxReserve;
    }

    constructor(address launcher_, address splitter_) {
        launcher = launcher_;
        splitter = splitter_;
        creditFactory = address(this);
    }

    function setSplitter(address splitter_) external {
        splitter = splitter_;
    }

    function setCreditFactory(address creditFactory_) external {
        creditFactory = creditFactory_;
    }

    function setSettlementDustState(address uAsset, uint128 reserve, uint128 maxReserve) external {
        dustStates[uAsset] = DustState({reserve: reserve, maxReserve: maxReserve});
    }

    function settlementDustStates(address uAsset) external view returns (uint128 reserve, uint128 maxReserve) {
        DustState memory state = dustStates[uAsset];
        return (state.reserve, state.maxReserve);
    }
}

contract MockScriptPOLSplitter {
    address public launcher;
    address public polend;

    constructor(address launcher_, address polend_) {
        launcher = launcher_;
        polend = polend_;
    }

    function setPolend(address polend_) external {
        polend = polend_;
    }
}

contract MockScriptHook {
    address public launcher;
    address public poolInitializer;

    constructor(address launcher_, address poolInitializer_) {
        launcher = launcher_;
        poolInitializer = poolInitializer_;
    }
}

contract MockScriptRouter {
    address public hook;
    address public hookLens;
    address public poolManager;

    constructor(address hook_, address hookLens_, address poolManager_) {
        hook = hook_;
        hookLens = hookLens_;
        poolManager = poolManager_;
    }
}

contract MockScriptRegistrationCenter {
    mapping(address => bool) public supportedUAssets;

    uint256 internal day = 24 * 3600;

    /// @dev Production-configured DAY so the script's DAY() == DAY readiness assertion passes;
    ///      overridable via setDay for the negative (REGISTRATION_DAY_NOT_READY) path.
    function DAY() external view returns (uint256) {
        return day;
    }

    // Defaulted to zero and must be pointed at the test's registry pin via setLzEndpointRegistry:
    // setUp deploys a real LzEndpointRegistry at a runtime address, so no fixed default can match
    // the pin (the script's identity readback REGISTRATION_CENTER_REGISTRY_NOT_READY fails loudly
    // on a forgotten setter).
    address internal registryPin;

    function lzEndpointRegistry() external view returns (address) {
        return registryPin;
    }

    function setDay(uint256 day_) external {
        day = day_;
    }

    function setLzEndpointRegistry(address lzEndpointRegistry_) external {
        registryPin = lzEndpointRegistry_;
    }

    function setSupportedUAsset(address uAsset, bool isSupported) external {
        supportedUAssets[uAsset] = isSupported;
    }
}

// Minimal stand-in for the readiness face of MemeverseOmnichainInteroperation: readiness reads back
// its constructor-baked LZ_ENDPOINT_REGISTRY immutable and compares it with the script pin.
contract MockScriptInteroperation {
    address public LZ_ENDPOINT_REGISTRY;

    constructor(address lzEndpointRegistry_) {
        LZ_ENDPOINT_REGISTRY = lzEndpointRegistry_;
    }

    function setLzEndpointRegistry(address lzEndpointRegistry_) external {
        LZ_ENDPOINT_REGISTRY = lzEndpointRegistry_;
    }
}

contract MemeverseScriptHarness is MemeverseScript {
    function setDeploymentAddresses(
        address owner_,
        address ueth,
        address uusd,
        address launcher,
        address registrar,
        address proxyDeployer,
        address yieldDispatcher,
        address polend,
        address polSplitter
    ) external {
        owner = owner_;
        UETH = ueth;
        UUSD = uusd;
        MEMEVERSE_LAUNCHER = launcher;
        MEMEVERSE_REGISTRAR = registrar;
        MEMEVERSE_PROXY_DEPLOYER = proxyDeployer;
        MEMEVERSE_YIELD_DISPATCHER = yieldDispatcher;
        POLEND = polend;
        POLSPLITTER = polSplitter;
    }

    function requireDeploymentReady(address swapRouter, address hook) external view {
        _requireDeploymentReady(swapRouter, hook);
    }

    function requireSwapReady(address router, address hook) external view {
        _requireSwapReady(router, hook);
    }

    function openSupportedUAssetsAfterReadinessForTest(address registrationCenter, address router, address hook)
        external
    {
        _openSupportedUAssetsAfterReadiness(registrationCenter, router, hook);
    }

    function setOutrunDeployerForTest(address deployer) external {
        OUTRUN_DEPLOYER = deployer;
    }

    function setExpectedRegistrationDayForTest(uint256 day) external {
        expectedRegistrationDay = day;
    }

    /// @dev Reaches onboardUAsset's DAY gate without `_loadReadinessEnv`, so the second
    ///      `_requireRegistrationCenterReady` call site is pinned via storage setters (env vars are
    ///      not set in these tests). Mirrors onboardUAsset's checks up to the DAY gate.
    function onboardUAssetForTest(address registrationCenter, address uAsset) external {
        require(deployer == owner, "SIGNER_NOT_OWNER");
        require(uAsset != address(0), "ZERO_UASSET");
        require(registrationCenter != address(0), "ZERO_REGISTRATION_CENTER");
        _requireContractCode(MEMEVERSE_LAUNCHER, "LAUNCHER_CODE_NOT_READY");
        _requireContractCode(POLEND, "POLEND_CODE_NOT_READY");
        _requireRegistrationCenterReady(registrationCenter);
    }

    /// @dev Reaches the per-chain registration readiness gate without `_loadReadinessEnv` /
    ///      `_chainsInit` (env vars are not set in these tests); the pins and chain list come from
    ///      the storage setters, mirroring the openSupportedUAssetsAfterReadinessForTest precedent.
    function checkPerChainRegistrationReadinessForTest(address[] calldata uAssets) external view {
        _checkPerChainRegistrationReadiness(uAssets);
    }

    function setEndpointForTest(uint32 chainId, address endpoint) external {
        endpoints[chainId] = endpoint;
    }

    /// @dev Content-probe inputs: production fills omnichainIds/endpointIds via _chainsInit (env);
    ///      this harness has no env, so pin them explicitly to mirror the deployed registry pairs.
    function setOmnichainIdsForTest(uint32[] memory chainIds) external {
        omnichainIds = chainIds;
    }

    function setEndpointIdForTest(uint32 chainId, uint32 endpointId) external {
        endpointIds[chainId] = endpointId;
    }

    function setOmnichainMemecoinStakerForTest(address staker) external {
        OMNICHAIN_MEMECOIN_STAKER = staker;
    }

    /// @dev Mirrors the five implementation env pins: production loads them via _loadReadinessEnv /
    ///      _loadScriptEnv; this harness has no env, so tests set them explicitly.
    function setImplementationPinsForTest(
        address memecoinImplementation_,
        address polImplementation_,
        address vaultImplementation_,
        address governorImplementation_,
        address incentivizerImplementation_
    ) external {
        MEMECOIN_IMPLEMENTATION = memecoinImplementation_;
        POL_IMPLEMENTATION = polImplementation_;
        MEMECOIN_VAULT_IMPLEMENTATION = vaultImplementation_;
        MEMECOIN_GOVERNOR_IMPLEMENTATION = governorImplementation_;
        CYCLE_INCENTIVIZER_IMPLEMENTATION = incentivizerImplementation_;
    }

    function setMemeverseOmnichainInteroperationForTest(address interoperation) external {
        MEMEVERSE_OMNICHAIN_INTEROPERATION = interoperation;
    }

    function setMemeverseLauncherForTest(address launcher_) external {
        MEMEVERSE_LAUNCHER = launcher_;
    }

    function setMemeverseProxyDeployerForTest(address proxyDeployer_) external {
        MEMEVERSE_PROXY_DEPLOYER = proxyDeployer_;
    }

    function setMemeverseYieldDispatcherForTest(address yieldDispatcher_) external {
        MEMEVERSE_YIELD_DISPATCHER = yieldDispatcher_;
    }

    function setMemeverseRegistrarForTest(address registrar_) external {
        MEMEVERSE_REGISTRAR = registrar_;
    }

    function setLzEndpointRegistryForTest(address lzEndpointRegistry_) external {
        LZ_ENDPOINT_REGISTRY = lzEndpointRegistry_;
    }

    function setProtocolTreasuryForTest(address treasury) external {
        PROTOCOL_TREASURY = treasury;
    }

    function deployOmnichainMemecoinStakerForTest(uint256 nonce) external {
        _deployOmnichainMemecoinStaker(nonce);
    }

    function deployMemeverseOmnichainInteroperationForTest(uint256 nonce) external {
        _deployMemeverseOmnichainInteroperation(nonce);
    }

    function deployYieldDispatcherForTest(uint256 nonce) external {
        _deployYieldDispatcher(nonce);
    }

    function deployImplementationForTest(uint256 nonce) external {
        _deployImplementation(nonce);
    }

    function deployMemecoinPOLImplementationForTest(uint256 nonce) external {
        _deployMemecoinPOLImplementation(nonce);
    }

    function deployMemecoinGovernorImplementationForTest(uint256 nonce) external {
        _deployMemecoinGovernorImplementation(nonce);
    }

    function deployRegistrationCenterForTest(uint256 nonce) external {
        _deployRegistrationCenter(nonce);
    }

    function deployMemeverseRegistrarForTest(uint256 nonce) external {
        _deployMemeverseRegistrar(nonce);
    }

    function deployLzEndpointRegistryForTest(uint256 nonce) external {
        _deployLzEndpointRegistry(nonce);
    }

    function deployMemeverseProxyDeployerForTest(uint256 nonce) external {
        _deployMemeverseProxyDeployer(nonce);
    }

    function optionalEnvAddressForTest(string memory name) external view returns (address) {
        return _optionalEnvAddress(name);
    }

    function setBroadcastSender(address sender) external {
        deployer = sender;
    }
}

contract MemeverseScriptTest is Test {
    address internal constant UETH = address(0x1001);
    address internal constant UUSD = address(0x1002);
    address internal constant LOCAL_ENDPOINT = address(0x1337);
    address internal constant STAKER = address(0x6002);
    // The five implementation pointers burned into MockScriptProxyDeployer's constructor and
    // mirrored as the script's pins; each is etched with code in setUp so the readiness code
    // probes pass, matching how the production deployer bakes coded artifacts.
    address internal constant MEMECOIN_IMPL = address(0x6101);
    address internal constant POL_IMPL = address(0x6102);
    address internal constant VAULT_IMPL = address(0x6103);
    address internal constant GOVERNOR_IMPL = address(0x6104);
    address internal constant INCENTIVIZER_IMPL = address(0x6105);
    // Registry pin: assigned in setUp to a REAL LzEndpointRegistry (owner = this test contract) so
    // the content probes exercise the production contract instead of an etch placeholder.
    address internal LZ_ENDPOINT_REGISTRY;
    // eid() the mocked local endpoint reports; must equal the registry's local-chain pair.
    uint32 internal constant LOCAL_ENDPOINT_EID = 40_001;
    // Probe chain/eid pairs, named after the _chainsInit env vars they mirror (BSC_TESTNET_* /
    // BASE_SEPOLIA_*). Every registry pair, harness endpointId and wrong-value derivation below
    // references these, so a chain-list edit cannot desynchronize setUp from the drift/boundary
    // tests (a stale hardcoded chain would make the boundary test pass vacuously on 0 == 0).
    uint32 internal constant BSC_TESTNET_CHAIN_ID = 97;
    uint32 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint32 internal constant BSC_TESTNET_EID = 40102;
    uint32 internal constant BASE_SEPOLIA_EID = 40245;
    address internal constant MOCK_POOL_MANAGER = address(0x4631);
    // Facet addresses wired onto readyHook by _mockFacetsOnHook; named so individual tests can override one facet.
    address internal constant READY_SWAP_FACET = address(uint160(0xFAB1));
    address internal constant READY_DYNAMIC_FEE_FACET = address(uint160(0xFAB2));
    address internal constant READY_SETTLEMENT_FACET = address(uint160(0xFAB3));
    // Launcher sibling slots wired with code for every readiness path (launchImpl is the mock's
    // constructor-baked dummy and already coded); _configureReadySwap re-wires these same slots.
    address internal constant SIBLING_SETTLEMENT_IMPL = address(uint160(0x5002));
    address internal constant SIBLING_FEE_PREVIEW_READER = address(uint160(0x5003));
    address internal constant SIBLING_LIQUIDITY_IMPL = address(uint160(0x5004));
    // Minimum green launcher fund metadata: the smallest (minTotalFund, fundBasedAmount) pair whose
    // derived virtual buffer rounds above zero (143 * 1 * 7 / 1000 = 1 > 0); one tick below on
    // minTotalFund rounds V to zero and readiness keeps registration closed.
    uint256 internal constant MIN_GREEN_MIN_TOTAL_FUND = 143;
    uint256 internal constant MIN_GREEN_FUND_BASED_AMOUNT = 1;

    MemeverseScriptHarness internal script;
    MemeverseUniswapHookLens internal lens;
    // Typed handle on the deployed registry pin; owner (this contract) re-points pairs in the
    // content-probe regression tests below.
    LzEndpointRegistry internal lzEndpointRegistry;
    MockScriptLauncher internal launcher;
    MockScriptRegistrar internal registrar;
    MockScriptProxyDeployer internal proxyDeployer;
    MockScriptYieldDispatcher internal yieldDispatcher;
    MockScriptPOLend internal polend;
    MockScriptPOLSplitter internal splitter;
    MockScriptInteroperation internal interoperation;

    function setUp() external {
        script = new MemeverseScriptHarness();
        lens = new MemeverseUniswapHookLens(IPoolManager(MOCK_POOL_MANAGER));
        launcher = new MockScriptLauncher();
        registrar = new MockScriptRegistrar(address(launcher));
        proxyDeployer = new MockScriptProxyDeployer(
            address(launcher), MEMECOIN_IMPL, POL_IMPL, VAULT_IMPL, GOVERNOR_IMPL, INCENTIVIZER_IMPL
        );
        yieldDispatcher = new MockScriptYieldDispatcher(address(launcher));
        splitter = new MockScriptPOLSplitter(address(launcher), address(0));
        polend = new MockScriptPOLend(address(launcher), address(splitter));
        splitter.setPolend(address(polend));
        // readiness checks POLendUpgradeable.creditFactory() points at a contract with code
        // (POLEND_CREDIT_FACTORY_NOT_READY); wire a coded address so the check passes.
        vm.etch(address(0x6001), address(lens).code);
        polend.setCreditFactory(address(0x6001));

        launcher.setOwner(address(script));
        launcher.setLauncherDependencies(address(registrar), address(proxyDeployer), address(yieldDispatcher));
        launcher.setPolend(address(polend));
        launcher.setPolSplitter(address(splitter));
        // Readiness wiring: _requireDeploymentReady's tail and the per-chain registration gate both
        // require code at the launcher's settlement/liquidity/fee-preview siblings before the system
        // opens (launchImpl is the constructor-baked dummy and already has code).
        vm.etch(SIBLING_SETTLEMENT_IMPL, address(lens).code);
        vm.etch(SIBLING_FEE_PREVIEW_READER, address(lens).code);
        vm.etch(SIBLING_LIQUIDITY_IMPL, address(lens).code);
        launcher.setSettlementImpl(SIBLING_SETTLEMENT_IMPL);
        launcher.setFeePreviewReader(SIBLING_FEE_PREVIEW_READER);
        launcher.setLiquidityImpl(SIBLING_LIQUIDITY_IMPL);
        // Minimum config that passes the derived virtual-buffer guard (143 * 1 * 7 / 1000 = 1 > 0);
        // values below 143 would round V to zero and keep registration closed.
        launcher.setFundMetaData(UETH, MIN_GREEN_MIN_TOTAL_FUND, MIN_GREEN_FUND_BASED_AMOUNT);
        launcher.setFundMetaData(UUSD, MIN_GREEN_MIN_TOTAL_FUND, MIN_GREEN_FUND_BASED_AMOUNT);
        script.setDeploymentAddresses(
            address(script),
            UETH,
            UUSD,
            address(launcher),
            address(registrar),
            address(proxyDeployer),
            address(yieldDispatcher),
            address(polend),
            address(splitter)
        );
        // Readiness wiring: _requireDeploymentReady now requires code at OMNICHAIN_MEMECOIN_STAKER and
        // consistency between the dispatcher's localEndpoint() and the harness endpoints mapping.
        vm.etch(STAKER, address(lens).code);
        // Readiness reads back staker.localEndpoint() (STAKER_ENDPOINT_NOT_READY); the etched lens code
        // has no such getter, so mock it to match endpoints[block.chainid].
        vm.mockCall(STAKER, abi.encodeWithSignature("localEndpoint()"), abi.encode(LOCAL_ENDPOINT));
        script.setOmnichainMemecoinStakerForTest(STAKER);
        yieldDispatcher.setLocalEndpoint(LOCAL_ENDPOINT);
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        // Readiness wiring: _requireDeploymentReady checks code at the registry pin
        // (REGISTRY_CODE_NOT_READY), reads the launcher's lzEndpointRegistry back against the same
        // pin (LAUNCHER_REGISTRY_NOT_READY), and probes the registry's chain->eid pairs against the
        // harness endpointIds plus a local anchor against the endpoint's own eid()
        // (REGISTRY_PAIR_NOT_READY / REGISTRY_LOCAL_EID_NOT_READY). Deploy a REAL registry with
        // owner-written pairs so the probes exercise the production contract; the pin is therefore
        // an setUp-assigned address, not a fixed constant.
        lzEndpointRegistry = new LzEndpointRegistry(address(this));
        ILzEndpointRegistry.LzEndpointIdPair[] memory registryPairs = new ILzEndpointRegistry.LzEndpointIdPair[](3);
        registryPairs[0] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: BSC_TESTNET_CHAIN_ID, endpointId: BSC_TESTNET_EID});
        registryPairs[1] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: BASE_SEPOLIA_CHAIN_ID, endpointId: BASE_SEPOLIA_EID});
        registryPairs[2] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: uint32(block.chainid), endpointId: LOCAL_ENDPOINT_EID});
        lzEndpointRegistry.setLzEndpointIds(registryPairs);
        LZ_ENDPOINT_REGISTRY = address(lzEndpointRegistry);
        launcher.setLzEndpointRegistry(LZ_ENDPOINT_REGISTRY);
        script.setLzEndpointRegistryForTest(LZ_ENDPOINT_REGISTRY);
        // Content-probe inputs: mirror the registry pairs above through the harness (production
        // fills these via _chainsInit; this harness has no env).
        uint32[] memory chainIds = new uint32[](2);
        chainIds[0] = BSC_TESTNET_CHAIN_ID;
        chainIds[1] = BASE_SEPOLIA_CHAIN_ID;
        script.setOmnichainIdsForTest(chainIds);
        script.setEndpointIdForTest(BSC_TESTNET_CHAIN_ID, BSC_TESTNET_EID);
        script.setEndpointIdForTest(BASE_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_EID);
        // Local anchor: the probe reads the endpoint's eid() back on-chain, so satisfy it with the
        // value the registry maps for the local chain (mockCall, like the composeQueue probe above).
        vm.mockCall(LOCAL_ENDPOINT, abi.encodeWithSignature("eid()"), abi.encode(LOCAL_ENDPOINT_EID));
        // Readiness wiring: _requireDeploymentReady checks code at the interoperation address and
        // reads its constructor-baked LZ_ENDPOINT_REGISTRY immutable back against the same pin
        // (INTEROPERATION_CODE_NOT_READY / INTEROPERATION_REGISTRY_NOT_READY). The deployed mock is a
        // real contract, so the address has code without an extra etch.
        interoperation = new MockScriptInteroperation(LZ_ENDPOINT_REGISTRY);
        script.setMemeverseOmnichainInteroperationForTest(address(interoperation));
        // Readiness wiring: _requireDeploymentReady reads the deployer's five implementation
        // pointers back (code probe MEMECOIN_IMPLEMENTATION_CODE_NOT_READY family, then identity
        // against the script pins), so each pointer needs code and the pins must mirror the same
        // values the mock constructor baked.
        vm.etch(MEMECOIN_IMPL, address(lens).code);
        vm.etch(POL_IMPL, address(lens).code);
        vm.etch(VAULT_IMPL, address(lens).code);
        vm.etch(GOVERNOR_IMPL, address(lens).code);
        vm.etch(INCENTIVIZER_IMPL, address(lens).code);
        script.setImplementationPinsForTest(MEMECOIN_IMPL, POL_IMPL, VAULT_IMPL, GOVERNOR_IMPL, INCENTIVIZER_IMPL);
        // _deployYieldDispatcher reads PROTOCOL_TREASURY (UASSET no-code settlement sink). Default it to a non-zero
        // address so the dispatcher deploy tests pass; the zero-treasury test overrides it.
        script.setProtocolTreasuryForTest(address(0xBEEF));
        // Endpoint capability check: _requireDeploymentReady now requires the endpoint to have code
        // and expose the MessagingComposer composeQueue getter. The harness endpoint has no real
        // code, so etch lens bytecode and mock the probe with the exact placeholder calldata the
        // script uses (vm.mockCall cannot fake EXTCODESIZE; etch provides the code length).
        vm.etch(LOCAL_ENDPOINT, address(lens).code);
        vm.mockCall(
            LOCAL_ENDPOINT,
            abi.encodeWithSignature(
                "composeQueue(address,address,bytes32,uint16)", address(1), address(1), bytes32(0), uint16(0)
            ),
            abi.encode(bytes32(0))
        );
    }

    function testReadinessRevertsWhenUethReserveMaxIsZero() external {
        polend.setSettlementDustState(UETH, 0, 0);
        polend.setSettlementDustState(UUSD, 0, 1);

        vm.expectRevert("UETH_RESERVE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // readiness check: POLendUpgradeable.creditFactory() must point to a contract with code (POLEND_CREDIT_FACTORY_NOT_READY).
    // This check runs before the reserve/sibling checks; after wiring all dependencies, blanking creditFactory
    // should revert immediately.
    function testReadinessRevertsWhenPolendCreditFactoryHasNoCode() external {
        polend.setCreditFactory(address(0));

        vm.expectRevert("POLEND_CREDIT_FACTORY_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // readiness must reject fund metadata whose derived virtual buffer V would round to zero,
    // since a zero V would make MemecoinYieldVault.initialize revert and DoS governance-chain deploy.
    // 142 * 1 * 7 = 994 -> floor(/1000) = 0, while setUp leaves UUSD at 143 (1 > 0). Only UETH fails,
    // and it is checked before UUSD, so the revert surfaces the UETH message.
    function testReadinessRevertsWhenVirtualAssetsWouldRoundToZero() external {
        // Reserve checks run before fund-metadata checks, so wire both reserves to pass
        // and then only break the derived virtual buffer for UETH.
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        launcher.setFundMetaData(UETH, MIN_GREEN_MIN_TOTAL_FUND - 1, MIN_GREEN_FUND_BASED_AMOUNT);

        vm.expectRevert("UETH_FUND_METADATA_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    function testSwapReadinessRejectsHookFlagsAndAcceptsExpectedFlags() external {
        address badHook = address(uint160(0x28cd));
        address goodHook = address(uint160(0x28cc));

        MockScriptRouter badRouter = new MockScriptRouter(badHook, address(lens), MOCK_POOL_MANAGER);
        MockScriptRouter goodRouter = new MockScriptRouter(goodHook, address(lens), MOCK_POOL_MANAGER);
        MockScriptHook hookImpl = new MockScriptHook(address(launcher), address(goodRouter));

        vm.etch(badHook, address(hookImpl).code);
        vm.etch(goodHook, address(hookImpl).code);
        vm.mockCall(badHook, abi.encodeWithSignature("launcher()"), abi.encode(address(launcher)));
        vm.mockCall(badHook, abi.encodeWithSignature("poolInitializer()"), abi.encode(address(badRouter)));
        vm.mockCall(goodHook, abi.encodeWithSignature("launcher()"), abi.encode(address(launcher)));
        vm.mockCall(goodHook, abi.encodeWithSignature("poolInitializer()"), abi.encode(address(goodRouter)));
        _mockFacetsOnHook(goodHook);

        launcher.setMemeverseSwapRouter(address(badRouter));
        launcher.setMemeverseUniswapHook(badHook);

        vm.expectRevert("HOOK_FLAGS_NOT_READY");
        script.requireSwapReady(address(badRouter), badHook);

        launcher.setMemeverseSwapRouter(address(goodRouter));
        launcher.setMemeverseUniswapHook(goodHook);

        script.requireSwapReady(address(goodRouter), goodHook);
    }

    function testSwapReadinessRevertsWhenSwapFacetCodeMissing() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        // Override swapFacet() to return an address with no code.
        vm.mockCall(readyHook, abi.encodeWithSignature("swapFacet()"), abi.encode(address(0xDEAD)));

        vm.expectRevert("SWAP_FACET_CODE_NOT_READY");
        script.requireSwapReady(readyRouter, readyHook);
    }

    function testSwapReadinessRevertsWhenDynamicFeeFacetCodeMissing() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        vm.mockCall(readyHook, abi.encodeWithSignature("dynamicFeeFacet()"), abi.encode(address(0xDEAD)));

        vm.expectRevert("DYNAMIC_FEE_FACET_CODE_NOT_READY");
        script.requireSwapReady(readyRouter, readyHook);
    }

    function testSwapReadinessRevertsWhenSettlementFacetCodeMissing() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        vm.mockCall(readyHook, abi.encodeWithSignature("settlementFacet()"), abi.encode(address(0xDEAD)));

        vm.expectRevert("SETTLEMENT_FACET_CODE_NOT_READY");
        script.requireSwapReady(readyRouter, readyHook);
    }

    // readiness must reject when a facet's poolManager differs from the hook's
    // (mirrors hook.initialize _requireFacetPoolManager).
    function testSwapReadinessRevertsWhenSwapFacetPoolManagerMismatch() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        vm.mockCall(READY_SWAP_FACET, abi.encodeWithSignature("poolManager()"), abi.encode(address(0xBAD)));

        vm.expectRevert("SWAP_FACET_POOL_MANAGER_NOT_READY");
        script.requireSwapReady(readyRouter, readyHook);
    }

    // readiness must reject when the router's poolManager differs from the hook's: the router unlocks/
    // initializes on its own PoolManager, whose callback into the hook is gated by onlyPoolManager against
    // the hook's PoolManager, so a mismatch DoSes every swap and pool initialization.
    function testSwapReadinessRevertsWhenRouterPoolManagerMismatch() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        vm.mockCall(readyHook, abi.encodeWithSignature("poolManager()"), abi.encode(address(0xBAD)));

        vm.expectRevert("ROUTER_POOL_MANAGER_NOT_READY");
        script.requireSwapReady(readyRouter, readyHook);
    }

    function testOpenSupportedUAssetsAfterReadinessDoesNotOpenWhenReadinessFails() external {
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setLzEndpointRegistry(LZ_ENDPOINT_REGISTRY);
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 0);
        polend.setSettlementDustState(UUSD, 0, 1);

        vm.expectRevert("UETH_RESERVE_NOT_READY");
        script.openSupportedUAssetsAfterReadinessForTest(address(center), readyRouter, readyHook);

        assertFalse(center.supportedUAssets(UETH));
        assertFalse(center.supportedUAssets(UUSD));
    }

    function testOpenSupportedUAssetsAfterReadinessRejectsMissingRegistrationCenterCode() external {
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        vm.expectRevert("REGISTRATION_CENTER_CODE_NOT_READY");
        script.openSupportedUAssetsAfterReadinessForTest(address(0xCAFE), readyRouter, readyHook);
    }

    function testOpenSupportedUAssetsAfterReadinessOpensWhenReadinessPasses() external {
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setLzEndpointRegistry(LZ_ENDPOINT_REGISTRY);
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        script.openSupportedUAssetsAfterReadinessForTest(address(center), readyRouter, readyHook);

        assertTrue(center.supportedUAssets(UETH));
        assertTrue(center.supportedUAssets(UUSD));
    }

    // Regression: the open path must reject a RegistrationCenter whose DAY() does not match the
    // expected deployment value (default production 86400), so the whitelist is never written for a
    // center configured for a non-prod day (the DAY() == expected-day check runs before the
    // launch/settlement/liquidity readiness gates).
    function testOpenSupportedUAssetsAfterReadinessRevertsWhenDayIsNotProduction() external {
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setDay(180);
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        vm.expectRevert("REGISTRATION_DAY_NOT_READY");
        script.openSupportedUAssetsAfterReadinessForTest(address(center), readyRouter, readyHook);

        assertFalse(center.supportedUAssets(UETH));
        assertFalse(center.supportedUAssets(UUSD));
    }

    // Testnet path: a center configured for the fast-window DAY (180) is accepted when the
    // deployment sets EXPECTED_DAY=180, so testnet keeps the practical short window.
    function testOpenSupportedUAssetsAfterReadinessOpensWhenDayMatchesTestnetValue() external {
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setDay(180);
        center.setLzEndpointRegistry(LZ_ENDPOINT_REGISTRY);
        script.setExpectedRegistrationDayForTest(180);
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        script.openSupportedUAssetsAfterReadinessForTest(address(center), readyRouter, readyHook);

        assertTrue(center.supportedUAssets(UETH));
        assertTrue(center.supportedUAssets(UUSD));
    }

    // Regression: onboardUAsset's DAY gate (the second _requireRegistrationCenterReady call site) must
    // reject a center whose DAY() != expected. The shared helper is tested via the open path; this pins
    // the onboardUAsset call site through a harness entry that skips env-loading.
    function testOnboardUAssetRevertsWhenDayIsNotProduction() external {
        script.setBroadcastSender(address(script));
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setDay(180);

        vm.expectRevert("REGISTRATION_DAY_NOT_READY");
        script.onboardUAssetForTest(address(center), UETH);
    }

    // Readiness gate: a no-code staker must reject with STAKER_CODE_NOT_READY (the center code/DAY
    // check and the other dependency code checks pass; only the staker code check fails).
    function testReadinessRevertsWhenStakerHasNoCode() external {
        script.setOmnichainMemecoinStakerForTest(address(0xDEAD));

        vm.expectRevert("STAKER_CODE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate: the dispatcher's localEndpoint() must match endpoints[block.chainid]; a mismatch
    // must be rejected with YIELD_DISPATCHER_ENDPOINT_NOT_READY.
    function testReadinessRevertsWhenDispatcherEndpointMismatchesLocal() external {
        yieldDispatcher.setLocalEndpoint(address(0x9999));

        vm.expectRevert("YIELD_DISPATCHER_ENDPOINT_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate: the launcher's lzEndpointRegistry is initialize-only (no setter), so a launcher
    // bound to a different registry than the script pin can only be fixed by redeploying; readiness
    // must reject it before the system opens.
    function testReadinessRevertsWhenLauncherRegistryMismatchesPin() external {
        launcher.setLzEndpointRegistry(address(0xBAD));

        vm.expectRevert("LAUNCHER_REGISTRY_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate: the registry pin must point at a contract with code like every other launcher
    // dependency pin — launcher initialize deliberately accepts codeless predicted addresses, so
    // equality alone cannot catch a wrong env value when both sides share the same mistake.
    function testReadinessRevertsWhenRegistryPinHasNoCode() external {
        address codelessRegistry = address(0x9999);
        launcher.setLzEndpointRegistry(codelessRegistry);
        script.setLzEndpointRegistryForTest(codelessRegistry);

        vm.expectRevert("REGISTRY_CODE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate: the RegistrationCenter binds lzEndpointRegistry as an initialize-time storage
    // pointer with no setter (quoteSend/registration resolve omnichain eids through it), so a center
    // bound to a different registry than the script pin can only be fixed by redeploying; the center
    // gate must reject it
    // before the whitelist is written (runs inside _requireRegistrationCenterReady, before
    // _requireDeploymentReady).
    function testReadinessRevertsWhenCenterRegistryMismatchesPin() external {
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        center.setLzEndpointRegistry(address(0xBAD));

        vm.expectRevert("REGISTRATION_CENTER_REGISTRY_NOT_READY");
        script.openSupportedUAssetsAfterReadinessForTest(address(center), address(0), address(0));

        assertFalse(center.supportedUAssets(UETH));
        assertFalse(center.supportedUAssets(UUSD));
    }

    // Readiness gate: MemeverseOmnichainInteroperation bakes LZ_ENDPOINT_REGISTRY as its own
    // constructor immutable (gov-chain sends resolve dst eids through it); a mismatch with the script
    // pin is only fixable by redeploying, so readiness must reject it before the system opens.
    function testReadinessRevertsWhenInteroperationRegistryMismatchesPin() external {
        interoperation.setLzEndpointRegistry(address(0xBAD));

        vm.expectRevert("INTEROPERATION_REGISTRY_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate: every one of the five deployer implementation pointers must match its script
    // pin. The pointers are cloned into every per-verse token, so a pointer that drifted from its
    // pin (cross-session env drift, or a stale pre-nonce-bump artifact) must block before the
    // system opens. Parametrized over the pin slots: exactly one slot drifts per pass, proving each
    // branch surfaces its own named error (the readback pointer keeps code, so the identity
    // readback is what fires).
    function testReadinessRevertsWhenAnyImplementationPinMismatchesDeployer() external {
        address driftPin = address(0xBAD);
        string[5] memory expectedErrors = [
            "PROXY_DEPLOYER_MEMECOIN_IMPLEMENTATION_NOT_READY",
            "PROXY_DEPLOYER_POL_IMPLEMENTATION_NOT_READY",
            "PROXY_DEPLOYER_VAULT_IMPLEMENTATION_NOT_READY",
            "PROXY_DEPLOYER_GOVERNOR_IMPLEMENTATION_NOT_READY",
            "PROXY_DEPLOYER_INCENTIVIZER_IMPLEMENTATION_NOT_READY"
        ];

        for (uint256 i = 0; i < expectedErrors.length; i++) {
            // Rebuilt from the setUp constants every pass, so exactly one slot drifts per pass.
            script.setImplementationPinsForTest(
                i == 0 ? driftPin : MEMECOIN_IMPL,
                i == 1 ? driftPin : POL_IMPL,
                i == 2 ? driftPin : VAULT_IMPL,
                i == 3 ? driftPin : GOVERNOR_IMPL,
                i == 4 ? driftPin : INCENTIVIZER_IMPL
            );

            vm.expectRevert(bytes(expectedErrors[i]));
            script.requireDeploymentReady(address(0), address(0));
        }
    }

    // Readiness gate: a codeless pointer must block ahead of the identity readback — clones would
    // derive from a codeless implementation, which no runtime path can repair. Parametrized over
    // the five getters: exactly one slot is blanked per pass, proving each code check surfaces its
    // own named error. Every pass resets all five getters to their setUp values first — the same
    // rebuild pattern as the pin-drift test — so no state leaks across passes.
    function testReadinessRevertsWhenAnyImplementationPointerHasNoCode() external {
        address codelessPin = address(0xDEAD);
        string[5] memory expectedErrors = [
            "MEMECOIN_IMPLEMENTATION_CODE_NOT_READY",
            "POL_IMPLEMENTATION_CODE_NOT_READY",
            "VAULT_IMPLEMENTATION_CODE_NOT_READY",
            "GOVERNOR_IMPLEMENTATION_CODE_NOT_READY",
            "INCENTIVIZER_IMPLEMENTATION_CODE_NOT_READY"
        ];

        for (uint256 i = 0; i < expectedErrors.length; i++) {
            proxyDeployer.setMemecoinImplementation(i == 0 ? codelessPin : MEMECOIN_IMPL);
            proxyDeployer.setPolImplementation(i == 1 ? codelessPin : POL_IMPL);
            proxyDeployer.setVaultImplementation(i == 2 ? codelessPin : VAULT_IMPL);
            proxyDeployer.setGovernorImplementation(i == 3 ? codelessPin : GOVERNOR_IMPL);
            proxyDeployer.setIncentivizerImplementation(i == 4 ? codelessPin : INCENTIVIZER_IMPL);

            vm.expectRevert(bytes(expectedErrors[i]));
            script.requireDeploymentReady(address(0), address(0));
        }
    }

    // Readiness gate (content probe): the registry's chain->eid pairs must match the harness
    // endpointIds for every omnichain chain. Models the pre-open owner re-point drift vector: an
    // owner setLzEndpointIds between deploy and the gate re-points chain 97 to a different eid, so
    // every consumer resolving dst eids through the registry would misroute; readiness must block
    // with REGISTRY_PAIR_NOT_READY.
    function testReadinessRevertsWhenRegistryPairDriftsFromEndpointIds() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory repointed = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        repointed[0] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: BSC_TESTNET_CHAIN_ID, endpointId: BSC_TESTNET_EID + 897});
        lzEndpointRegistry.setLzEndpointIds(repointed);

        vm.expectRevert("REGISTRY_PAIR_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Readiness gate (local anchor): the registry's local-chain entry must equal the endpoint's own
    // eid() read back on-chain — the env-independent slice of the content probe. A registry that
    // disagrees with the endpoint deployed next to it must block with REGISTRY_LOCAL_EID_NOT_READY
    // even when the env-sourced pairs all agree.
    function testReadinessRevertsWhenRegistryLocalEidMismatchesEndpoint() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory repointed = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        repointed[0] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: uint32(block.chainid), endpointId: LOCAL_ENDPOINT_EID + 1});
        lzEndpointRegistry.setLzEndpointIds(repointed);

        vm.expectRevert("REGISTRY_LOCAL_EID_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Epistemic boundary, pinned honestly: when the registry pairs and endpointIds drift TOGETHER
    // (same wrong value on every chain, and the local anchor equally wrong on both sides), the
    // content probe passes — inside one process there is no independent ground truth to disagree
    // with. This is the same-source blind spot the script documents at the probe: its value is
    // cross-session/standalone drift and stale registry instances, not same-source corruption
    // (here registry, endpointIds and the mocked eid() all come from this one setUp, exactly like
    // a single run() reads one env).
    function testReadinessPassesWhenRegistryAndEndpointIdsShareSameWrongValues() external {
        uint32 wrongBscEid = BSC_TESTNET_EID + 1000;
        uint32 wrongBaseEid = BASE_SEPOLIA_EID + 1000;
        uint32 wrongLocalEid = LOCAL_ENDPOINT_EID + 1000;
        ILzEndpointRegistry.LzEndpointIdPair[] memory drifted = new ILzEndpointRegistry.LzEndpointIdPair[](3);
        drifted[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: BSC_TESTNET_CHAIN_ID, endpointId: wrongBscEid});
        drifted[1] = ILzEndpointRegistry.LzEndpointIdPair({chainId: BASE_SEPOLIA_CHAIN_ID, endpointId: wrongBaseEid});
        drifted[2] = ILzEndpointRegistry.LzEndpointIdPair({chainId: uint32(block.chainid), endpointId: wrongLocalEid});
        lzEndpointRegistry.setLzEndpointIds(drifted);
        script.setEndpointIdForTest(BSC_TESTNET_CHAIN_ID, wrongBscEid);
        script.setEndpointIdForTest(BASE_SEPOLIA_CHAIN_ID, wrongBaseEid);
        vm.mockCall(LOCAL_ENDPOINT, abi.encodeWithSignature("eid()"), abi.encode(wrongLocalEid));

        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        (address readyRouter, address readyHook) = _configureReadySwap();

        script.requireDeploymentReady(readyRouter, readyHook);
    }

    // Per-chain readiness gate: the canonical UETH/UUSD pair plus a green uAsset input and matching
    // registry pairs must pass with no revert — this gate is the remote-chain fan-out precondition,
    // so its positive path must be reachable with only this chain's own contracts wired.
    function testCheckPerChainRegistrationReadinessPassesWhenCanonicalPairAndUAssetReady() external {
        address uAsset = address(0x2001);
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        polend.setSettlementDustState(uAsset, 0, 1);
        // Same minimum green metadata as setUp's canonical pair (143 * 1 * 7 / 1000 = 1 > 0).
        launcher.setFundMetaData(uAsset, MIN_GREEN_MIN_TOTAL_FUND, MIN_GREEN_FUND_BASED_AMOUNT);

        address[] memory uAssets = new address[](1);
        uAssets[0] = uAsset;

        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate: a uAsset whose settlement-dust reserve cap is zero must block with
    // RESERVE_NOT_READY — POLendUpgradeable refuses market registration until the cap is configured,
    // which would otherwise surface only as a user-facing revert on the remote chain.
    function testCheckPerChainRegistrationReadinessRevertsWhenUAssetReserveIsZero() external {
        address uAsset = address(0x2001);
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        launcher.setFundMetaData(uAsset, MIN_GREEN_MIN_TOTAL_FUND, MIN_GREEN_FUND_BASED_AMOUNT);
        // uAsset reserve deliberately left at (0, 0); reserve is checked before fund metadata.

        address[] memory uAssets = new address[](1);
        uAssets[0] = uAsset;

        vm.expectRevert("RESERVE_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate: a uAsset with a usable reserve but zero launcher fund metadata must
    // block with FUND_METADATA_NOT_READY — registration reverts ZeroInput until it is set.
    function testCheckPerChainRegistrationReadinessRevertsWhenUAssetFundMetaDataIsZero() external {
        address uAsset = address(0x2001);
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        polend.setSettlementDustState(uAsset, 0, 1);
        // uAsset fund metadata deliberately left at (0, 0).

        address[] memory uAssets = new address[](1);
        uAssets[0] = uAsset;

        vm.expectRevert("FUND_METADATA_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate: a zero address in the uAsset list must block with ZERO_UASSET; the
    // fully green leading element proves each element is validated in order before the failure.
    function testCheckPerChainRegistrationReadinessRevertsWhenUAssetIsZero() external {
        address uAsset = address(0x2001);
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        polend.setSettlementDustState(uAsset, 0, 1);
        launcher.setFundMetaData(uAsset, MIN_GREEN_MIN_TOTAL_FUND, MIN_GREEN_FUND_BASED_AMOUNT);

        address[] memory uAssets = new address[](2);
        uAssets[0] = uAsset;
        uAssets[1] = address(0);

        vm.expectRevert("ZERO_UASSET");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate: the canonical UETH/UUSD pair is checked unconditionally — with an
    // EMPTY uAsset list a zero UETH reserve still blocks (UUSD is wired green so the revert pins
    // the UETH slot, which is checked first).
    function testCheckPerChainRegistrationReadinessRevertsWhenCanonicalUethReserveIsZero() external {
        polend.setSettlementDustState(UUSD, 0, 1);
        // UETH reserve deliberately left at (0, 0); empty input list.
        address[] memory uAssets = new address[](0);

        vm.expectRevert("UETH_RESERVE_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (registry content probe): the shared _requireRegistryPairsReady probe
    // must fire through this entry too — a registry pair re-pointed away from this run's endpointIds
    // would silently misroute every omnichain send from this chain, so the gate must block with
    // REGISTRY_PAIR_NOT_READY before the whitelist opens at the center. Mirrors the
    // requireDeploymentReady drift test's registry re-point construction.
    function testCheckPerChainRegistrationReadinessRevertsWhenRegistryPairDrifts() external {
        ILzEndpointRegistry.LzEndpointIdPair[] memory repointed = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        repointed[0] =
            ILzEndpointRegistry.LzEndpointIdPair({chainId: BSC_TESTNET_CHAIN_ID, endpointId: BSC_TESTNET_EID + 897});
        lzEndpointRegistry.setLzEndpointIds(repointed);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("REGISTRY_PAIR_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (registrar code check): the registrar is the registration-path ACL
    // consumer on this chain, and the launcher-wiring identity readback cannot catch a wrong env
    // value when the launcher and the pin share the same codeless prediction — so the per-chain
    // gate must require code at the pin with the deployment gate's named error. Both the launcher
    // wiring and the script pin point at the same codeless address, so the identity readback would
    // agree and only the code check can fire; it runs ahead of every other per-chain probe, so no
    // reserve wiring is needed.
    function testCheckPerChainRegistrationReadinessRevertsWhenRegistrarPinHasNoCode() external {
        address codelessRegistrar = address(0x9999);
        launcher.setLauncherDependencies(codelessRegistrar, address(proxyDeployer), address(yieldDispatcher));
        script.setMemeverseRegistrarForTest(codelessRegistrar);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("REGISTRAR_CODE_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (baked-pointer readback): the deployer's five implementation pointers
    // are cloned into every per-verse token, so a script pin that drifted from the pointer baked into
    // THIS chain's deployer must block this chain's gate with the same named error the deployment
    // gate uses. Mirrors the requireDeploymentReady pin-drift construction through the per-chain
    // entry; fires before the reserve checks, so no reserve wiring is needed.
    function testCheckPerChainRegistrationReadinessRevertsWhenBakedPointerMismatchesPin() external {
        script.setImplementationPinsForTest(address(0xBAD), POL_IMPL, VAULT_IMPL, GOVERNOR_IMPL, INCENTIVIZER_IMPL);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("PROXY_DEPLOYER_MEMECOIN_IMPLEMENTATION_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (launcher sibling code check): a liquidityImpl without code would
    // defer this chain's setup mistake into a user-facing registration-time revert, so the gate must
    // block with LIQUIDITY_IMPL_NOT_READY — the deployment gate's tail probe reached through the
    // per-chain entry. Canonical reserves are wired green so the revert pins the sibling probe, not
    // the canonical reserve check that runs before it.
    function testCheckPerChainRegistrationReadinessRevertsWhenLiquidityImplHasNoCode() external {
        launcher.setLiquidityImpl(address(0xDEAD));
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("LIQUIDITY_IMPL_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (launcher registry identity readback): remote registration resolves
    // dst eids through the launcher's initialize-only lzEndpointRegistry pointer, so a launcher baked
    // with a different registry than this run's pin (cross-session env drift, or a stale pre-nonce-
    // bump instance) would leave this gate's registry content probe green while every remote
    // registration misroutes; the gate must block with the deployment gate's named error. Only the
    // launcher-side pointer drifts — the pin keeps pointing at setUp's real registry, so the content
    // probe stays green and the revert pins the identity readback itself. Canonical reserves are
    // wired green because the readback runs after the canonical pair check.
    function testCheckPerChainRegistrationReadinessRevertsWhenLauncherRegistryMismatchesPin() external {
        launcher.setLzEndpointRegistry(address(0xBAD));
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("LAUNCHER_REGISTRY_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (launcher proxyDeployer identity readback): verse clones are
    // deployed through the launcher's baked proxyDeployer storage pointer, not the env pin, so a
    // launcher initialized with a different deployer than this run's pin (cross-session env drift)
    // would leave this gate green while every per-verse token deploy resolves through an
    // unverified deployer; the gate must block with the deployment gate's named error. Only the
    // launcher-side pointer drifts — the pin keeps pointing at setUp's real deployer, so the
    // deployer-side probes stay green and the revert pins the identity readback itself. Canonical
    // reserves are wired green because the readback runs after the canonical pair check.
    function testCheckPerChainRegistrationReadinessRevertsWhenLauncherProxyDeployerMismatchesPin() external {
        launcher.setLauncherDependencies(address(registrar), address(0xBAD), address(yieldDispatcher));
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);

        address[] memory uAssets = new address[](0);

        vm.expectRevert("LAUNCHER_PROXY_DEPLOYER_NOT_READY");
        script.checkPerChainRegistrationReadinessForTest(uAssets);
    }

    // Per-chain readiness gate (launcher wiring identity readback): the gate consumes the launcher's
    // full wiring through the shared _requireLauncherWiringReady helper, so any of the four pointers
    // beyond the registry/proxyDeployer pair already covered above (registrar, yieldDispatcher,
    // polend, polSplitter) drifting from this run's pin must block with the deployment gate's named
    // error. Parametrized over the four slots: exactly one launcher-side pointer drifts per pass
    // while the pins keep pointing at setUp's real instances, so the code probes and registry content
    // probe stay green and the revert pins the identity readback itself. Canonical reserves are wired
    // green because the readback runs after the canonical pair check.
    function testCheckPerChainRegistrationReadinessRevertsWhenAnyLauncherWiringMismatchesPin() external {
        string[4] memory expectedErrors = [
            "LAUNCHER_REGISTRAR_NOT_READY",
            "LAUNCHER_YIELD_DISPATCHER_NOT_READY",
            "LAUNCHER_POLEND_NOT_READY",
            "LAUNCHER_POLSPLITTER_NOT_READY"
        ];

        for (uint256 i = 0; i < expectedErrors.length; i++) {
            // Exactly one launcher-side pointer drifts per pass; every other slot keeps its setUp value.
            launcher.setLauncherDependencies(
                i == 0 ? address(0xBAD) : address(registrar),
                address(proxyDeployer),
                i == 1 ? address(0xBAD) : address(yieldDispatcher)
            );
            launcher.setPolend(i == 2 ? address(0xBAD) : address(polend));
            launcher.setPolSplitter(i == 3 ? address(0xBAD) : address(splitter));
            polend.setSettlementDustState(UETH, 0, 1);
            polend.setSettlementDustState(UUSD, 0, 1);

            address[] memory uAssets = new address[](0);

            vm.expectRevert(bytes(expectedErrors[i]));
            script.checkPerChainRegistrationReadinessForTest(uAssets);
        }
    }

    function testOptionalEnvAddressReturnsZeroWhenMissing() external view {
        assertEq(script.optionalEnvAddressForTest("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_MISSING_FOR_TEST"), address(0));
    }

    function testOptionalEnvAddressReturnsEnvValueWhenPresent() external {
        vm.setEnv("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_PRESENT_FOR_TEST", "0x0000000000000000000000000000000000001234");

        assertEq(
            script.optionalEnvAddressForTest("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_PRESENT_FOR_TEST"), address(0x1234)
        );
    }

    // Regression: pins _deployYieldDispatcher's two-step UUPS encoding (impl CREATE3, then ERC1967Proxy CREATE3
    // wrapping initializeData) against the real YieldDispatcherUpgradeable ABI. The script builds both creation codes by
    // type-erased abi encoding, so an initialize-signature drift compiles cleanly and would silently bake a proxy
    // that initializes with wrong args. Byte-equality alone cannot catch arg-order drift (both sides keep the same
    // handwritten order), so initializeData is ALSO executed against a real impl+proxy and every arg read back: any
    // arg-count mismatch reverts the proxy's delegatecall, any arg-order mismatch flips a read-back. The captured
    // proxy creationCode embeds implementation=address(0) (the mock returns 0) and so cannot be `create`d directly —
    // the read-back uses a separate real impl+proxy deploy with the identical initializeData args instead.
    function testDeployYieldDispatcherPinsConstructorArgEncoding() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        address localEndpoint = address(0x1234);
        address treasury = address(0xBEEF);
        // owner comes from setUp (setDeploymentAddresses wired owner = address(script)); launcher from setUp.
        address expectedOwner = address(script);
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        script.setProtocolTreasuryForTest(treasury);
        // The mock returns address(0) for every deploy, so the dispatcher pin must mirror that actual
        // for the post-deploy env-pin guard (YIELD_DISPATCHER_DEPLOY_MISMATCH).
        script.setMemeverseYieldDispatcherForTest(address(0));

        script.deployYieldDispatcherForTest(2);

        // Deploy #1: implementation (no constructor args).
        (bytes32 implSalt, bytes memory implCreationCode) = deployer.deployCalls(0);
        assertEq(implSalt, keccak256(abi.encodePacked("YieldDispatcherImplementation", uint256(2))));
        assertEq(implCreationCode, type(YieldDispatcherUpgradeable).creationCode);

        // Deploy #2: ERC1967Proxy wrapping (implementation, initializeData). The mock returns address(0) for the
        // impl deploy, so the encoded implementation address is address(0).
        bytes memory initializeData = abi.encodeCall(
            YieldDispatcherUpgradeable.initialize, (expectedOwner, localEndpoint, address(launcher), treasury)
        );
        (bytes32 proxySalt, bytes memory proxyCreationCode) = deployer.deployCalls(1);
        assertEq(proxySalt, keccak256(abi.encodePacked("YieldDispatcher", uint256(2))));
        assertEq(
            proxyCreationCode, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(0), initializeData))
        );

        // Read-back: a REAL impl+proxy deploy with the identical initializeData args, read through the proxy.
        YieldDispatcherUpgradeable impl = new YieldDispatcherUpgradeable();
        YieldDispatcherUpgradeable proxy =
            YieldDispatcherUpgradeable(address(new ERC1967Proxy(address(impl), initializeData)));
        assertEq(proxy.localEndpoint(), localEndpoint);
        assertEq(proxy.memeverseLauncher(), address(launcher));
        assertEq(proxy.protocolTreasury(), treasury);
        assertEq(proxy.owner(), expectedOwner);
    }

    // Regression: a zero PROTOCOL_TREASURY must fail loudly at deploy time instead of initializing a dispatcher
    // that routes UASSET no-code settlement to address(0). Pins that the guard fires BEFORE any OutrunDeployer call.
    function testDeployYieldDispatcherRevertsOnZeroProtocolTreasury() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        script.setProtocolTreasuryForTest(address(0));

        vm.expectRevert("ZERO_PROTOCOL_TREASURY");
        script.deployYieldDispatcherForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Address-stability: the proxy still lands at the CREATE3 address derived from (factory, owner, SALT_YIELD_DISPATCHER),
    // independent of the creationCode change to the UUPS proxy form. Deploys through a REAL OutrunDeployer (CREATE3)
    // and asserts the proxy lands at getDeployed(owner, salt) and is a real initialized YieldDispatcherUpgradeable there.
    function testDeployYieldDispatcherProxyAddressIsCreate3Stable() external {
        // Real CREATE3 factory owned by the harness (= the deploy caller / owner), so its onlyOwner deploy gate passes.
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        address localEndpoint = address(0x4321);
        address treasury = address(0xCAFE);
        script.setOutrunDeployerForTest(address(realDeployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        script.setProtocolTreasuryForTest(treasury);
        // Pre-fill the dispatcher env pin with the current-nonce CREATE3 prediction, as the deploy
        // guard (YIELD_DISPATCHER_DEPLOY_MISMATCH) requires.
        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", uint256(7)));
        address predictedProxy = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        script.setMemeverseYieldDispatcherForTest(predictedProxy);

        script.deployYieldDispatcherForTest(7);

        // The proxy is deployed and is a real initialized dispatcher at the predicted CREATE3 address.
        assertGt(predictedProxy.code.length, 0, "proxy not deployed at predicted address");
        assertEq(YieldDispatcherUpgradeable(predictedProxy).localEndpoint(), localEndpoint);
        assertEq(YieldDispatcherUpgradeable(predictedProxy).memeverseLauncher(), address(launcher));
        assertEq(YieldDispatcherUpgradeable(predictedProxy).protocolTreasury(), treasury);
        assertEq(YieldDispatcherUpgradeable(predictedProxy).owner(), address(script));
    }

    // Regression: under the documented dual-role deployment (deployer/broadcaster != owner), the CREATE3
    // namespace is keyed by the deploy caller (msg.sender = address(script) here), NOT by owner. The proxy must land
    // at getDeployed(deployCaller, salt) and the assert must pass even though owner (the initialize initialOwner,
    // the multisig) differs from the deploy caller.
    function testDeployYieldDispatcherDualRoleOwnerDistinctFromCaller() external {
        address multisig = makeAddr("multisig"); // OWNER env = protocol owner, distinct from the deploy caller
        // Re-wire owner = multisig; the deploy caller stays address(script) (the harness calling OutrunDeployer.deploy).
        script.setDeploymentAddresses(
            multisig,
            UETH,
            UUSD,
            address(launcher),
            address(registrar),
            address(proxyDeployer),
            address(yieldDispatcher),
            address(polend),
            address(splitter)
        );

        OutrunDeployer realDeployer = new OutrunDeployer(address(script)); // owned by the deploy caller
        address localEndpoint = address(0x4321);
        address treasury = address(0xCAFE);
        script.setOutrunDeployerForTest(address(realDeployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        script.setProtocolTreasuryForTest(treasury);

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", uint256(7)));
        address predictedByCaller = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        address predictedByOwner = IOutrunDeployer(address(realDeployer)).getDeployed(multisig, salt);
        // Pre-fill the dispatcher env pin with the caller-namespaced prediction the deploy guard
        // (YIELD_DISPATCHER_DEPLOY_MISMATCH) requires.
        script.setMemeverseYieldDispatcherForTest(predictedByCaller);

        script.deployYieldDispatcherForTest(7);

        // The dual-role setup must actually diverge — otherwise the branch under test is not exercised.
        assertFalse(predictedByCaller == predictedByOwner, "dual-role namespaces must diverge");
        // The proxy lands at the deploy-caller-namespaced address (not owner's), proving the prediction caller is correct.
        assertGt(predictedByCaller.code.length, 0, "proxy not deployed at caller-namespaced address");
        assertEq(
            YieldDispatcherUpgradeable(predictedByCaller).owner(),
            multisig,
            "dispatcher owner is the multisig, not the caller"
        );
        assertEq(YieldDispatcherUpgradeable(predictedByCaller).localEndpoint(), localEndpoint);
        assertEq(YieldDispatcherUpgradeable(predictedByCaller).memeverseLauncher(), address(launcher));
        assertEq(YieldDispatcherUpgradeable(predictedByCaller).protocolTreasury(), treasury);
    }

    // Mirror of testDeployYieldDispatcherPinsConstructorArgEncoding for the staker. Same motivation:
    // _deployOmnichainMemecoinStaker builds both creation codes by type-erased abi encoding (a bare
    // parameterless UUPS implementation, then an ERC1967Proxy wrapping initializeData), so an
    // initialize-signature drift compiles cleanly and would silently bake a proxy that initializes with
    // wrong args — a wrong localEndpoint makes the lzCompose `msg.sender == localEndpoint` guard
    // permanently false, so the staker would silently drop every omnichain staking message.
    // Byte-equality alone cannot catch arg-order drift (both sides keep the same handwritten order), so
    // initializeData is ALSO executed against a real impl+proxy and every arg read back: any arg-count
    // mismatch reverts the proxy's delegatecall, any arg-order mismatch flips a read-back. The captured
    // proxy creationCode embeds implementation=address(0) (the mock returns 0), so the read-back uses a
    // separate real impl+proxy deploy with the identical initializeData args instead.
    function testDeployOmnichainMemecoinStakerPinsConstructorArgEncoding() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        address localEndpoint = address(0x1234);
        // owner comes from setUp (setDeploymentAddresses wired owner = address(script)).
        address expectedOwner = address(script);
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        // The mock returns address(0) for every deploy, so the staker pin must mirror that actual for
        // the post-deploy env-pin guard (OMNICHAIN_MEMECOIN_STAKER_DEPLOY_MISMATCH).
        script.setOmnichainMemecoinStakerForTest(address(0));

        script.deployOmnichainMemecoinStakerForTest(2);

        // Deploy #1: parameterless UUPS implementation (bare creationCode).
        (bytes32 implSalt, bytes memory implCreationCode) = deployer.deployCalls(0);
        assertEq(implSalt, keccak256(abi.encodePacked("OmnichainMemecoinStakerImplementation", uint256(2))));
        assertEq(implCreationCode, type(OmnichainMemecoinStakerUpgradeable).creationCode);

        // Deploy #2: ERC1967Proxy wrapping (implementation, initializeData). The mock returns address(0)
        // for the impl deploy, so the encoded implementation address is address(0).
        bytes memory initializeData =
            abi.encodeCall(OmnichainMemecoinStakerUpgradeable.initialize, (expectedOwner, localEndpoint));
        (bytes32 proxySalt, bytes memory proxyCreationCode) = deployer.deployCalls(1);
        assertEq(proxySalt, keccak256(abi.encodePacked("OmnichainMemecoinStaker", uint256(2))));
        assertEq(
            proxyCreationCode, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(0), initializeData))
        );

        // Read-back: a REAL impl+proxy deploy with the identical initializeData args, read through the
        // proxy.
        OmnichainMemecoinStakerUpgradeable impl = new OmnichainMemecoinStakerUpgradeable();
        OmnichainMemecoinStakerUpgradeable proxy =
            OmnichainMemecoinStakerUpgradeable(address(new ERC1967Proxy(address(impl), initializeData)));
        assertEq(proxy.localEndpoint(), localEndpoint);
        assertEq(proxy.owner(), expectedOwner);
    }

    // Mirror of testDeployYieldDispatcherPinsConstructorArgEncoding for the registration center. The center
    // is the family's only conversion that combines BOTH encodings: the implementation creationCode itself
    // takes abi.encode(localEndpoint) (burned in as the constructor immutable, unlike the parameterless
    // dispatcher/staker implementations) AND the proxy calldata packs a three-arg initialize by type-erased
    // abi encoding. A parameter reorder there compiles cleanly and silently bakes a proxy whose
    // registrar/registry pointers are swapped (both address-typed — the swap only surfaces at runtime as
    // misrouted registrations). Byte-equality alone cannot catch arg-order drift (both sides keep the same
    // handwritten order), so initializeData is ALSO executed against a real impl+proxy and every arg read
    // back: any arg-count mismatch reverts the proxy's delegatecall, any arg-order mismatch flips a
    // read-back. The captured proxy creationCode embeds implementation=address(0) (the mock returns 0), so
    // the read-back uses a separate real impl+proxy deploy with the identical initializeData args instead.
    function testDeployRegistrationCenterPinsConstructorArgEncoding() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        address localEndpoint = address(0x1234);
        // owner and MEMEVERSE_REGISTRAR come from setUp (setDeploymentAddresses wired owner =
        // address(script) and the registrar pin); LZ_ENDPOINT_REGISTRY is setUp's real registry instance.
        address expectedOwner = address(script);
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        // The post-deploy peer/ULN wiring loop targets centerAddr = address(0) (the mock's return), which
        // this pin does not cover; clear setUp's probe chains so the loop is skipped.
        script.setOmnichainIdsForTest(new uint32[](0));
        // Same reason for the script's trailing owner wiring (setRegisterGasLimit/setDurationDaysRange on
        // centerAddr = address(0)): a high-level void call reverts on Solidity's extcodesize guard (the
        // compiled script checks extcodesize before the CALL), so mock both. foundry intercepts any call
        // matching the registered (address(0), exact calldata prefix) and bypasses that guard entirely.
        // Using the script's exact wiring literals (1000000 / 1,3) in the prefix is a deliberate secondary
        // pin: editing either literal makes the interception miss, the real call falls back to the guard,
        // and the test fails.
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IMemeverseRegistrationCenter.setRegisterGasLimit.selector, uint256(1000000)),
            bytes("mocked")
        );
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IMemeverseRegistrationCenter.setDurationDaysRange.selector, uint128(1), uint128(3)),
            bytes("mocked")
        );

        script.deployRegistrationCenterForTest(2);

        // Deploy #1: UUPS implementation whose creationCode appends the local endpoint (its only constructor
        // arg, shared by every upgrade).
        (bytes32 implSalt, bytes memory implCreationCode) = deployer.deployCalls(0);
        assertEq(implSalt, keccak256(abi.encodePacked("MemeverseRegistrationCenterImplementation", uint256(2))));
        assertEq(
            implCreationCode,
            abi.encodePacked(type(MemeverseRegistrationCenterUpgradeable).creationCode, abi.encode(localEndpoint))
        );

        // Deploy #2: ERC1967Proxy wrapping (implementation, initializeData). The mock returns address(0)
        // for the impl deploy, so the encoded implementation address is address(0).
        bytes memory initializeData = abi.encodeCall(
            MemeverseRegistrationCenterUpgradeable.initialize, (expectedOwner, address(registrar), LZ_ENDPOINT_REGISTRY)
        );
        (bytes32 proxySalt, bytes memory proxyCreationCode) = deployer.deployCalls(1);
        assertEq(proxySalt, keccak256(abi.encodePacked("MemeverseRegistrationCenter", uint256(2))));
        assertEq(
            proxyCreationCode, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(0), initializeData))
        );

        // Read-back: a REAL impl+proxy deploy with the identical initializeData args, read through the
        // proxy. initialize runs __OApp_init -> endpoint.setDelegate(owner), so the endpoint burned into the
        // read-back implementation must be a contract accepting setDelegate (the composer mock); the
        // script-side localEndpoint baked into deploy #1's creationCode is already pinned byte-exactly above.
        MockMessagingComposerEndpoint endpointMock = new MockMessagingComposerEndpoint();
        MemeverseRegistrationCenterUpgradeable impl = new MemeverseRegistrationCenterUpgradeable(address(endpointMock));
        MemeverseRegistrationCenterUpgradeable proxy =
            MemeverseRegistrationCenterUpgradeable(payable(address(new ERC1967Proxy(address(impl), initializeData))));
        assertEq(proxy.memeverseRegistrar(), address(registrar));
        assertEq(proxy.lzEndpointRegistry(), LZ_ENDPOINT_REGISTRY);
        assertEq(proxy.owner(), expectedOwner);
        // The constructor endpoint is read back through the OApp core getter exactly like _authorizeUpgrade.
        assertEq(address(IOAppCore(address(proxy)).endpoint()), address(endpointMock));
        assertEq(endpointMock.delegate(), expectedOwner);
    }

    // Mirror of testDeployYieldDispatcherPinsConstructorArgEncoding for the interoperation. Same
    // motivation but stronger: _deployMemeverseOmnichainInteroperation packs six constructor args by
    // type-erased abi.encode, so a parameter reorder or type swap compiles cleanly and silently bakes
    // wrong immutables. Byte-equality alone cannot catch arg-order drift, so the captured bytes are also
    // executed and ALL six constructor args are read back to detect any reorder or count change.
    function testDeployMemeverseOmnichainInteroperationPinsConstructorArgEncoding() external {
        // owner comes from setUp (setDeploymentAddresses wired owner = address(script)); owner is passed
        // as the first constructor arg and is the only input not exposed via a script storage slot, so it
        // is reused directly rather than re-set.
        address expectedOwner = address(script);
        // Gas limits are hardcoded in the script (115000 / 135000); mirror them exactly so the
        // byte-equality check would fail if either literal were edited.
        uint128 oftReceiveGasLimit = 115000;
        uint128 omnichainStakingGasLimit = 135000;

        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setLzEndpointRegistryForTest(LZ_ENDPOINT_REGISTRY);
        script.setMemeverseLauncherForTest(address(launcher));
        script.setOmnichainMemecoinStakerForTest(STAKER);

        script.deployMemeverseOmnichainInteroperationForTest(2);

        assertEq(
            deployer.lastCreationCode(),
            abi.encodePacked(
                type(MemeverseOmnichainInteroperation).creationCode,
                abi.encode(
                    expectedOwner,
                    LZ_ENDPOINT_REGISTRY,
                    address(launcher),
                    STAKER,
                    oftReceiveGasLimit,
                    omnichainStakingGasLimit
                )
            )
        );
        assertEq(deployer.lastSalt(), keccak256(abi.encodePacked("MemeverseOmnichainInteroperation", uint256(2))));

        // Execute the exact creation code and read back every constructor arg. The interoperation
        // constructor performs no external calls, so a plain create is safe in the test EVM.
        bytes memory creationCode = deployer.lastCreationCode();
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(deployed != address(0), "creationCode deploy reverted");
        // The script passes LZ_ENDPOINT_REGISTRY as the `_lzEndpointRegistry` constructor arg, so the
        // LZ_ENDPOINT_REGISTRY() read-back must equal the pin set above. Pinning this faithfully exposes
        // any future change to which script slot feeds that arg.
        assertEq(MemeverseOmnichainInteroperation(deployed).LZ_ENDPOINT_REGISTRY(), LZ_ENDPOINT_REGISTRY);
        assertEq(MemeverseOmnichainInteroperation(deployed).MEMEVERSE_LAUNCHER(), address(launcher));
        assertEq(MemeverseOmnichainInteroperation(deployed).OMNICHAIN_MEMECOIN_STAKER(), STAKER);
        assertEq(MemeverseOmnichainInteroperation(deployed).oftReceiveGasLimit(), oftReceiveGasLimit);
        assertEq(MemeverseOmnichainInteroperation(deployed).omnichainStakingGasLimit(), omnichainStakingGasLimit);
        assertEq(MemeverseOmnichainInteroperation(deployed).owner(), expectedOwner);
    }

    // REGISTRY_DEPLOY_MISMATCH regression: LZ_ENDPOINT_REGISTRY is a required env pin consumed by the
    // center/interoperation constructor args and the readiness probes. When the pin still
    // points at a stale (old-nonce) instance while CREATE3 deploys a fresh registry, the new deploy
    // would be orphaned and the whole system would wire itself to the env address — the deploy must
    // fail fast instead. The stale pin is modeled by setUp's `new`-deployed registry instance.
    function testDeployLzEndpointRegistryRevertsWhenPinMismatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        // Non-vacuous guard: the fresh CREATE3 prediction this run deploys at must differ from the pin.
        bytes32 salt = keccak256(abi.encodePacked("LzEndpointRegistry", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        assertFalse(predicted == LZ_ENDPOINT_REGISTRY, "stale pin must not equal fresh CREATE3 address");

        vm.expectRevert("REGISTRY_DEPLOY_MISMATCH");
        script.deployLzEndpointRegistryForTest(7);
    }

    // Positive mirror: when the env pin is pre-filled with the current-nonce CREATE3 prediction (the
    // documented operator step, _getDeployedLzEndpointRegistry), the deploy passes the mismatch assert,
    // and setLzEndpointIds writes this run's endpointIds pairs onto the deployed registry.
    function testDeployLzEndpointRegistryDeploysWhenPinMatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        bytes32 salt = keccak256(abi.encodePacked("LzEndpointRegistry", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        script.setLzEndpointRegistryForTest(predicted);

        script.deployLzEndpointRegistryForTest(7);

        // The registry is a real contract at the predicted address with the harness-written pairs; the
        // onlyOwner setLzEndpointIds also transitively proves the constructor baked owner = address(script).
        assertGt(predicted.code.length, 0, "registry not deployed at predicted address");
        assertEq(ILzEndpointRegistry(predicted).lzEndpointIdOfChain(BSC_TESTNET_CHAIN_ID), BSC_TESTNET_EID);
        assertEq(ILzEndpointRegistry(predicted).lzEndpointIdOfChain(BASE_SEPOLIA_CHAIN_ID), BASE_SEPOLIA_EID);
    }

    // MEMEVERSE_PROXY_DEPLOYER_DEPLOY_MISMATCH regression: MEMEVERSE_PROXY_DEPLOYER is a required
    // env pin burned into the launcher's initialize args.
    // When the pin still points at a stale (old-nonce) instance while CREATE3 deploys a fresh proxy
    // deployer, the new deploy would be orphaned and the launcher would initialize itself to the
    // stale env address — the deploy must fail fast instead. The stale pin is modeled by setUp's
    // `new`-deployed readiness mock proxyDeployer.
    function testDeployMemeverseProxyDeployerRevertsWhenPinMismatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        // Non-vacuous guard: the fresh CREATE3 prediction this run deploys at must differ from the pin.
        bytes32 salt = keccak256(abi.encodePacked("MemeverseProxyDeployer", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        assertFalse(predicted == address(proxyDeployer), "stale pin must not equal fresh CREATE3 address");

        vm.expectRevert("MEMEVERSE_PROXY_DEPLOYER_DEPLOY_MISMATCH");
        script.deployMemeverseProxyDeployerForTest(7);
    }

    // Positive mirror: when the env pin is pre-filled with the current-nonce CREATE3 prediction (the
    // documented operator step, _getDeployedMemeverseProxyDeployer), the deploy passes the mismatch
    // assert and a real MemeverseProxyDeployer lands at the predicted address.
    function testDeployMemeverseProxyDeployerDeploysWhenPinMatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        bytes32 salt = keccak256(abi.encodePacked("MemeverseProxyDeployer", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        script.setMemeverseProxyDeployerForTest(predicted);

        script.deployMemeverseProxyDeployerForTest(7);

        // The proxy deployer is a real contract at the predicted address (its constructor guards
        // require every setUp pin non-zero, so a deployed contract also proves the args were wired).
        assertGt(predicted.code.length, 0, "proxy deployer not deployed at predicted address");
    }

    // YIELD_DISPATCHER_DEPLOY_MISMATCH regression: MEMEVERSE_YIELD_DISPATCHER is a required env pin
    // burned into the launcher's initialize args and consumed by the readiness gates. When the pin
    // still points at a stale (old-nonce) instance while CREATE3 deploys a fresh dispatcher, the new
    // deploy would be orphaned and the launcher would wire itself to the stale env address — the
    // deploy must fail fast instead. The stale pin is modeled by setUp's readiness mock dispatcher.
    function testDeployYieldDispatcherRevertsWhenPinMismatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        // Non-vacuous guard: the fresh CREATE3 prediction this run deploys at must differ from the pin.
        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        assertFalse(predicted == address(yieldDispatcher), "stale pin must not equal fresh CREATE3 address");

        vm.expectRevert("YIELD_DISPATCHER_DEPLOY_MISMATCH");
        script.deployYieldDispatcherForTest(7);
    }

    // Positive mirror: when the env pin is pre-filled with the current-nonce CREATE3 prediction (the
    // documented operator step, _getDeployedYieldDispatcher), the deploy passes the mismatch assert
    // and a real initialized YieldDispatcherUpgradeable lands at the predicted address.
    function testDeployYieldDispatcherDeploysWhenPinMatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        bytes32 salt = keccak256(abi.encodePacked("YieldDispatcher", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        script.setMemeverseYieldDispatcherForTest(predicted);

        script.deployYieldDispatcherForTest(7);

        // The dispatcher is a real initialized contract at the predicted address (setUp wired owner,
        // launcher and treasury = address(0xBEEF), all read back through the proxy).
        assertGt(predicted.code.length, 0, "dispatcher not deployed at predicted address");
        assertEq(YieldDispatcherUpgradeable(predicted).memeverseLauncher(), address(launcher));
        assertEq(YieldDispatcherUpgradeable(predicted).protocolTreasury(), address(0xBEEF));
        assertEq(YieldDispatcherUpgradeable(predicted).owner(), address(script));
    }

    // OMNICHAIN_MEMECOIN_STAKER_DEPLOY_MISMATCH regression: OMNICHAIN_MEMECOIN_STAKER is a required
    // env pin that interoperation bakes as a constructor immutable (no setter, and the staker deploy
    // writes nothing back). When the pin still points at a stale (old-nonce) address while CREATE3
    // deploys a fresh staker, the fresh staker would be orphaned while interoperation irreversibly
    // wires itself to the stale env address — the deploy must fail fast instead. The stale pin is
    // modeled by setUp's etched STAKER constant.
    function testDeployOmnichainMemecoinStakerRevertsWhenPinMismatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        // Non-vacuous guard: the fresh CREATE3 prediction this run deploys at must differ from the pin.
        bytes32 salt = keccak256(abi.encodePacked("OmnichainMemecoinStaker", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        assertFalse(predicted == STAKER, "stale pin must not equal fresh CREATE3 address");

        vm.expectRevert("OMNICHAIN_MEMECOIN_STAKER_DEPLOY_MISMATCH");
        script.deployOmnichainMemecoinStakerForTest(7);
    }

    // Positive mirror: when the env pin is pre-filled with the current-nonce CREATE3 prediction (the
    // documented operator step, _getDeployedOmnichainMemecoinStaker), the deploy passes the mismatch
    // assert and a real initialized OmnichainMemecoinStakerUpgradeable lands at the predicted address.
    function testDeployOmnichainMemecoinStakerDeploysWhenPinMatchesCreate3Address() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));
        address localEndpoint = address(0x4321);
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);
        // Pre-fill the staker env pin with the current-nonce CREATE3 prediction, as the deploy guard
        // (OMNICHAIN_MEMECOIN_STAKER_DEPLOY_MISMATCH) requires.
        bytes32 salt = keccak256(abi.encodePacked("OmnichainMemecoinStaker", uint256(7)));
        address predicted = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), salt);
        script.setOmnichainMemecoinStakerForTest(predicted);

        script.deployOmnichainMemecoinStakerForTest(7);

        // The staker is a real initialized contract at the predicted address (setUp wired owner =
        // address(script), read back through the proxy with the fresh local endpoint).
        assertGt(predicted.code.length, 0, "staker not deployed at predicted address");
        assertEq(OmnichainMemecoinStakerUpgradeable(predicted).localEndpoint(), localEndpoint);
        assertEq(OmnichainMemecoinStakerUpgradeable(predicted).owner(), address(script));
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into a permanently unusable dispatcher (same guard as _deployGenesisCreditFactory).
    function testDeployYieldDispatcherRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployYieldDispatcherForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call. The revert alone would still
        // pass if the require were later moved after the deploy call (the mock deployer never reverts),
        // silently losing the "deploy never invoked" property this test exists to protect.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into a permanently unusable staker.
    function testDeployOmnichainMemecoinStakerRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployOmnichainMemecoinStakerForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero omnichain staker must fail loudly at deploy time instead of baking
    // OMNICHAIN_MEMECOIN_STAKER=0 into the interoperation contract (its send path would always target zero).
    function testDeployMemeverseOmnichainInteroperationRevertsOnZeroStaker() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setOmnichainMemecoinStakerForTest(address(0));

        vm.expectRevert("ZERO_OMNICHAIN_MEMECOIN_STAKER");
        script.deployMemeverseOmnichainInteroperationForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero MEMEVERSE_LAUNCHER must fail loudly at dispatcher deploy time instead of baking
    // memeverseLauncher=0 into the dispatcher (distributeSameChain would be permanently unusable).
    function testDeployYieldDispatcherRevertsOnZeroMemeverseLauncher() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        script.setMemeverseLauncherForTest(address(0));

        vm.expectRevert("ZERO_MEMEVERSE_LAUNCHER");
        script.deployYieldDispatcherForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero OUTRUN_DEPLOYER must fail loudly at dispatcher deploy time instead of
    // handing the CREATE3 salt/creation code to an unusable deployer (calls to address(0) succeed
    // silently with empty return data, so the deploy would look "successful" without deploying).
    function testDeployYieldDispatcherRevertsOnZeroOutrunDeployer() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(0));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);

        vm.expectRevert("ZERO_OUTRUN_DEPLOYER");
        script.deployYieldDispatcherForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into the Memecoin/MemecoinYieldVault/Incentivizer implementations.
    function testDeployImplementationRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployImplementationForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into the MemecoinPOL implementation.
    function testDeployMemecoinPOLImplementationRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployMemecoinPOLImplementationForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // IMPLEMENTATION_DEPLOY_MISMATCH coverage: the deploy asserts compare each fresh CREATE3 actual
    // against its env pin. The mock deployer returns address(0) for every deploy, so the
    // matching-pin positive must zero the pins (actual == pin); the negative cases keep the setUp
    // pins non-zero so the mock's actual diverges.
    function testDeployImplementationsPassWhenPinsMatchDeployedAddresses() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        script.setImplementationPinsForTest(address(0), address(0), address(0), address(0), address(0));

        script.deployImplementationForTest(2);
        script.deployMemecoinPOLImplementationForTest(2);
        script.deployMemecoinGovernorImplementationForTest(2);

        // Each mismatch guard runs after its deploy call, so all creation codes reached the deployer.
        (bytes32 memecoinSalt,) = deployer.deployCalls(0);
        (bytes32 polSalt,) = deployer.deployCalls(3);
        (bytes32 governorSalt,) = deployer.deployCalls(4);
        assertEq(memecoinSalt, keccak256(abi.encodePacked("MemecoinImplementation", uint256(2))));
        assertEq(polSalt, keccak256(abi.encodePacked("MemecoinPOLImplementation", uint256(2))));
        assertEq(governorSalt, keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", uint256(2))));
    }

    // Positive mirror of the proxyDeployer/registry deploy-gate family for the three implementation
    // deploy functions: with a REAL OutrunDeployer and every env pin pre-filled with the current-nonce
    // CREATE3 prediction (the documented operator step), each mismatch assert passes and a real
    // implementation lands at its predicted address with code. The pins are the real non-zero
    // getDeployed predictions — a degenerate pin (e.g. address(0)) cannot satisfy both the guard and
    // these code assertions, so the pass proves the guard admits exactly the fresh artifacts.
    function testDeployImplementationsDeploysWhenPinsMatchCreate3Addresses() external {
        OutrunDeployer realDeployer = new OutrunDeployer(address(script));
        script.setOutrunDeployerForTest(address(realDeployer));

        // Non-degenerate pins: each prediction is a real non-zero CREATE3 address.
        bytes32 memecoinSalt = keccak256(abi.encodePacked("MemecoinImplementation", uint256(7)));
        bytes32 vaultSalt = keccak256(abi.encodePacked("MemecoinYieldVaultImplementation", uint256(7)));
        bytes32 incentivizerSalt = keccak256(abi.encodePacked("GovernanceCycleIncentivizerImplementation", uint256(7)));
        bytes32 polSalt = keccak256(abi.encodePacked("MemecoinPOLImplementation", uint256(7)));
        bytes32 governorSalt = keccak256(abi.encodePacked("MemecoinDaoGovernorImplementation", uint256(7)));
        address predictedMemecoin = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), memecoinSalt);
        address predictedVault = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), vaultSalt);
        address predictedIncentivizer =
            IOutrunDeployer(address(realDeployer)).getDeployed(address(script), incentivizerSalt);
        address predictedPol = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), polSalt);
        address predictedGovernor = IOutrunDeployer(address(realDeployer)).getDeployed(address(script), governorSalt);
        assertTrue(
            predictedMemecoin != address(0) && predictedVault != address(0) && predictedIncentivizer != address(0)
                && predictedPol != address(0) && predictedGovernor != address(0),
            "predictions must be real non-zero CREATE3 addresses"
        );
        script.setImplementationPinsForTest(
            predictedMemecoin, predictedPol, predictedVault, predictedGovernor, predictedIncentivizer
        );

        script.deployImplementationForTest(7);
        script.deployMemecoinPOLImplementationForTest(7);
        script.deployMemecoinGovernorImplementationForTest(7);

        // Every mismatch guard passed (no revert) and each fresh implementation has code at its
        // predicted address; the five predictions must also be pairwise distinct artifacts.
        assertGt(predictedMemecoin.code.length, 0, "memecoin implementation not deployed at predicted address");
        assertGt(predictedVault.code.length, 0, "vault implementation not deployed at predicted address");
        assertGt(predictedIncentivizer.code.length, 0, "incentivizer implementation not deployed at predicted address");
        assertGt(predictedPol.code.length, 0, "POL implementation not deployed at predicted address");
        assertGt(predictedGovernor.code.length, 0, "governor implementation not deployed at predicted address");
        assertTrue(
            predictedMemecoin != predictedVault && predictedMemecoin != predictedIncentivizer
                && predictedMemecoin != predictedPol && predictedMemecoin != predictedGovernor
                && predictedVault != predictedIncentivizer && predictedVault != predictedPol
                && predictedVault != predictedGovernor && predictedIncentivizer != predictedPol
                && predictedIncentivizer != predictedGovernor && predictedPol != predictedGovernor,
            "predictions must be pairwise distinct"
        );
    }

    function testDeployImplementationRevertsWhenMemecoinPinMismatchesDeployedAddress() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        // setUp pins point at the readiness mocks (non-zero); the mock deploy returns address(0).

        vm.expectRevert("MEMECOIN_IMPLEMENTATION_DEPLOY_MISMATCH");
        script.deployImplementationForTest(2);
    }

    function testDeployMemecoinPOLImplementationRevertsWhenPinMismatchesDeployedAddress() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);

        vm.expectRevert("POL_IMPLEMENTATION_DEPLOY_MISMATCH");
        script.deployMemecoinPOLImplementationForTest(2);
    }

    function testDeployMemecoinGovernorImplementationRevertsWhenPinMismatchesDeployedAddress() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);

        vm.expectRevert("MEMECOIN_GOVERNOR_IMPLEMENTATION_DEPLOY_MISMATCH");
        script.deployMemecoinGovernorImplementationForTest(2);
    }

    // The mock deployer returns address(0) for every deploy, so every guard BEFORE the one under
    // test must see a matching (zero) pin, and the slot under test keeps its non-zero setUp pin.
    function testDeployImplementationRevertsWhenVaultPinMismatchesDeployedAddress() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        script.setImplementationPinsForTest(address(0), address(0), VAULT_IMPL, address(0), address(0));

        vm.expectRevert("MEMECOIN_VAULT_IMPLEMENTATION_DEPLOY_MISMATCH");
        script.deployImplementationForTest(2);
    }

    function testDeployImplementationRevertsWhenIncentivizerPinMismatchesDeployedAddress() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
        script.setImplementationPinsForTest(address(0), address(0), address(0), address(0), INCENTIVIZER_IMPL);

        vm.expectRevert("CYCLE_INCENTIVIZER_IMPLEMENTATION_DEPLOY_MISMATCH");
        script.deployImplementationForTest(2);
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into the registration center.
    function testDeployRegistrationCenterRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployRegistrationCenterForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into the memeverse registrar.
    function testDeployMemeverseRegistrarRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployMemeverseRegistrarForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero OUTRUN_DEPLOYER must fail loudly at staker deploy time (the endpoint guard
    // fires first, so wire a non-zero endpoint to reach the deployer guard).
    function testDeployOmnichainMemecoinStakerRevertsOnZeroOutrunDeployer() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(0));
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);

        vm.expectRevert("ZERO_OUTRUN_DEPLOYER");
        script.deployOmnichainMemecoinStakerForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Regression: a zero OUTRUN_DEPLOYER must fail loudly at interoperation deploy time (the staker
    // guard fires first, so wire a non-zero staker to reach the deployer guard).
    function testDeployMemeverseOmnichainInteroperationRevertsOnZeroOutrunDeployer() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(0));
        script.setOmnichainMemecoinStakerForTest(STAKER);

        vm.expectRevert("ZERO_OUTRUN_DEPLOYER");
        script.deployMemeverseOmnichainInteroperationForTest(2);

        // Pin that the guard fires BEFORE any OutrunDeployer call.
        assertEq(deployer.lastSalt(), bytes32(0));
        assertEq(deployer.lastCreationCode(), bytes(""));
    }

    // Endpoint capability check: readiness must reject an endpoint address with no code.
    // The endpoint identity readbacks (STAKER/YIELD_DISPATCHER_ENDPOINT_NOT_READY) compare against
    // the same endpoints[chainid] the deploy functions bake, so a wrong env value passes them; the
    // capability probe catches it. The readbacks run before the probe, so realign staker/dispatcher
    // localEndpoint to the new endpoint value to isolate the ENDPOINT_CODE_NOT_READY revert.
    function testReadinessRevertsWhenEndpointHasNoCode() external {
        address badEndpoint = address(0xDEAD);
        script.setEndpointForTest(uint32(block.chainid), badEndpoint);
        vm.mockCall(STAKER, abi.encodeWithSignature("localEndpoint()"), abi.encode(badEndpoint));
        yieldDispatcher.setLocalEndpoint(badEndpoint);

        vm.expectRevert("ENDPOINT_CODE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Endpoint capability check: readiness must reject an endpoint that has code but does not expose
    // the MessagingComposer composeQueue getter (e.g. a wrong contract wired as the endpoint).
    function testReadinessRevertsWhenEndpointLacksComposeQueue() external {
        address codedEndpoint = address(0x1234);
        vm.etch(codedEndpoint, address(lens).code);
        script.setEndpointForTest(uint32(block.chainid), codedEndpoint);
        vm.mockCall(STAKER, abi.encodeWithSignature("localEndpoint()"), abi.encode(codedEndpoint));
        yieldDispatcher.setLocalEndpoint(codedEndpoint);

        vm.expectRevert("ENDPOINT_COMPOSE_QUEUE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // Regression: readiness must reject a staker whose localEndpoint() differs from
    // endpoints[block.chainid] (mirror of the dispatcher's YIELD_DISPATCHER_ENDPOINT_NOT_READY check).
    function testReadinessRevertsWhenStakerEndpointMismatchesLocal() external {
        vm.mockCall(STAKER, abi.encodeWithSignature("localEndpoint()"), abi.encode(address(0x9999)));

        vm.expectRevert("STAKER_ENDPOINT_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    function _configureReadySwap() internal returns (address readyRouter, address readyHook) {
        readyHook = address(uint160(0x28cc));
        MockScriptRouter router = new MockScriptRouter(readyHook, address(lens), MOCK_POOL_MANAGER);
        MockScriptHook hookImpl = new MockScriptHook(address(launcher), address(router));
        vm.etch(readyHook, address(hookImpl).code);
        vm.mockCall(readyHook, abi.encodeWithSignature("launcher()"), abi.encode(address(launcher)));
        vm.mockCall(readyHook, abi.encodeWithSignature("poolInitializer()"), abi.encode(address(router)));
        _mockFacetsOnHook(readyHook);
        launcher.setMemeverseSwapRouter(address(router));
        launcher.setMemeverseUniswapHook(readyHook);

        // Readiness requires code at every launch/settlement/view/liquidity sibling before opening.
        // The three setUp-wired slots are re-pointed at the shared constants; launchImpl keeps a
        // dedicated address so this helper mirrors the deploy flow's fresh sibling wiring.
        address launchImplAddr = address(uint160(0x5001));
        bytes memory siblingCode = address(hookImpl).code;
        vm.etch(launchImplAddr, siblingCode);
        vm.etch(SIBLING_SETTLEMENT_IMPL, siblingCode);
        vm.etch(SIBLING_FEE_PREVIEW_READER, siblingCode);
        vm.etch(SIBLING_LIQUIDITY_IMPL, siblingCode);
        launcher.setLaunchImpl(launchImplAddr);
        launcher.setSettlementImpl(SIBLING_SETTLEMENT_IMPL);
        launcher.setFeePreviewReader(SIBLING_FEE_PREVIEW_READER);
        launcher.setLiquidityImpl(SIBLING_LIQUIDITY_IMPL);
        return (address(router), readyHook);
    }

    function _mockFacetsOnHook(address readyHook) internal {
        // vm.etch does not copy storage, so mock each getter individually.
        vm.mockCall(readyHook, abi.encodeWithSignature("swapFacet()"), abi.encode(READY_SWAP_FACET));
        vm.mockCall(readyHook, abi.encodeWithSignature("dynamicFeeFacet()"), abi.encode(READY_DYNAMIC_FEE_FACET));
        vm.mockCall(readyHook, abi.encodeWithSignature("settlementFacet()"), abi.encode(READY_SETTLEMENT_FACET));
        vm.mockCall(readyHook, abi.encodeWithSignature("poolManager()"), abi.encode(MOCK_POOL_MANAGER));
        // Each facet must have code and report the hook's PoolManager (mirrors _requireFacetPoolManager).
        bytes memory facetCode = address(this).code;
        vm.etch(READY_SWAP_FACET, facetCode);
        vm.etch(READY_DYNAMIC_FEE_FACET, facetCode);
        vm.etch(READY_SETTLEMENT_FACET, facetCode);
        vm.mockCall(READY_SWAP_FACET, abi.encodeWithSignature("poolManager()"), abi.encode(MOCK_POOL_MANAGER));
        vm.mockCall(READY_DYNAMIC_FEE_FACET, abi.encodeWithSignature("poolManager()"), abi.encode(MOCK_POOL_MANAGER));
        vm.mockCall(READY_SETTLEMENT_FACET, abi.encodeWithSignature("poolManager()"), abi.encode(MOCK_POOL_MANAGER));
    }
}
