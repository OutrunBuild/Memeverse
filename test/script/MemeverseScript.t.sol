// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MemeverseScript} from "../../script/MemeverseScript.s.sol";
import {IOutrunDeployer} from "../../script/IOutrunDeployer.sol";
import {YieldDispatcher} from "../../src/verse/YieldDispatcher.sol";
import {OmnichainMemecoinStaker} from "../../src/interoperation/OmnichainMemecoinStaker.sol";
import {MemeverseOmnichainInteroperation} from "../../src/interoperation/MemeverseOmnichainInteroperation.sol";
import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {LauncherReadinessMockBase} from "../mocks/verse/LauncherReadinessMockBase.sol";

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

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
    }
}

// Captures the creationCode passed to OUTRUN_DEPLOYER so a test can execute the script's
// exact constructor-arg encoding and pin its order/count against the real YieldDispatcher.
contract MockScriptOutrunDeployer is IOutrunDeployer {
    bytes public lastCreationCode;
    bytes32 public lastSalt;

    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed) {
        lastSalt = salt;
        lastCreationCode = creationCode;
        return address(0);
    }

    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed) {
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

    function setDay(uint256 day_) external {
        day = day_;
    }

    function setSupportedUAsset(address uAsset, bool isSupported) external {
        supportedUAssets[uAsset] = isSupported;
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

    function setEndpointForTest(uint32 chainId, address endpoint) external {
        endpoints[chainId] = endpoint;
    }

    function setOmnichainMemecoinStakerForTest(address staker) external {
        OMNICHAIN_MEMECOIN_STAKER = staker;
    }

    function setMemeverseLauncherForTest(address launcher_) external {
        MEMEVERSE_LAUNCHER = launcher_;
    }

    function setMemeverseCommonInfoForTest(address commonInfo_) external {
        MEMEVERSE_COMMON_INFO = commonInfo_;
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

    function deployRegistrationCenterForTest(uint256 nonce) external {
        _deployRegistrationCenter(nonce);
    }

    function deployMemeverseRegistrarForTest(uint256 nonce) external {
        _deployMemeverseRegistrar(nonce);
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
    address internal constant MOCK_POOL_MANAGER = address(0x4631);
    // Facet addresses wired onto readyHook by _mockFacetsOnHook; named so individual tests can override one facet.
    address internal constant READY_SWAP_FACET = address(uint160(0xFAB1));
    address internal constant READY_DYNAMIC_FEE_FACET = address(uint160(0xFAB2));
    address internal constant READY_SETTLEMENT_FACET = address(uint160(0xFAB3));

    MemeverseScriptHarness internal script;
    MemeverseUniswapHookLens internal lens;
    MockScriptLauncher internal launcher;
    MockScriptRegistrar internal registrar;
    MockScriptProxyDeployer internal proxyDeployer;
    MockScriptYieldDispatcher internal yieldDispatcher;
    MockScriptPOLend internal polend;
    MockScriptPOLSplitter internal splitter;

    function setUp() external {
        script = new MemeverseScriptHarness();
        lens = new MemeverseUniswapHookLens(IPoolManager(MOCK_POOL_MANAGER));
        launcher = new MockScriptLauncher();
        registrar = new MockScriptRegistrar(address(launcher));
        proxyDeployer = new MockScriptProxyDeployer(address(launcher));
        yieldDispatcher = new MockScriptYieldDispatcher(address(launcher));
        splitter = new MockScriptPOLSplitter(address(launcher), address(0));
        polend = new MockScriptPOLend(address(launcher), address(splitter));
        splitter.setPolend(address(polend));
        // readiness checks POLend.creditFactory() points at a contract with code
        // (POLEND_CREDIT_FACTORY_NOT_READY); wire a coded address so the check passes.
        vm.etch(address(0x6001), address(lens).code);
        polend.setCreditFactory(address(0x6001));

        launcher.setOwner(address(script));
        launcher.setLauncherDependencies(address(registrar), address(proxyDeployer), address(yieldDispatcher));
        launcher.setPolend(address(polend));
        launcher.setPolSplitter(address(splitter));
        // Minimum config that passes the derived virtual-buffer guard (143 * 1 * 7 / 1000 = 1 > 0);
        // values below 143 would round V to zero and keep registration closed.
        launcher.setFundMetaData(UETH, 143, 1);
        launcher.setFundMetaData(UUSD, 143, 1);
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
        // F3: readiness reads back staker.localEndpoint() (STAKER_ENDPOINT_NOT_READY); the etched lens code
        // has no such getter, so mock it to match endpoints[block.chainid].
        vm.mockCall(STAKER, abi.encodeWithSignature("localEndpoint()"), abi.encode(LOCAL_ENDPOINT));
        script.setOmnichainMemecoinStakerForTest(STAKER);
        yieldDispatcher.setLocalEndpoint(LOCAL_ENDPOINT);
        script.setEndpointForTest(uint32(block.chainid), LOCAL_ENDPOINT);
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

    // readiness check: POLend.creditFactory() must point to a contract with code (POLEND_CREDIT_FACTORY_NOT_READY).
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
        launcher.setFundMetaData(UETH, 142, 1);

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

    function testOptionalEnvAddressReturnsZeroWhenMissing() external view {
        assertEq(script.optionalEnvAddressForTest("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_MISSING_FOR_TEST"), address(0));
    }

    function testOptionalEnvAddressReturnsEnvValueWhenPresent() external {
        vm.setEnv("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_PRESENT_FOR_TEST", "0x0000000000000000000000000000000000001234");

        assertEq(
            script.optionalEnvAddressForTest("MEMEVERSE_SCRIPT_OPTIONAL_ADDRESS_PRESENT_FOR_TEST"), address(0x1234)
        );
    }

    // Regression: pins _deployYieldDispatcher's creationCode constructor-arg encoding (order + count)
    // against the real YieldDispatcher constructor. The script builds the creation code by type-erased
    // abi.encode, so a constructor-signature drift (e.g. the 3-arg-with-owner -> 2-arg change) compiles
    // cleanly and would silently deploy a dispatcher with wrong immutables. Byte-equality against a
    // hand-written expectation alone cannot catch constructor-side arg-order drift (both sides would
    // keep the same handwritten order), so the captured bytes are ALSO executed and the deployed
    // immutables read back: any arg-count mismatch reverts the create, any arg-order mismatch flips
    // localEndpoint()/memeverseLauncher() and fails the read-back assertions.
    function testDeployYieldDispatcherPinsConstructorArgEncoding() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        address localEndpoint = address(0x1234);
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);

        script.deployYieldDispatcherForTest(2);

        bytes memory expectedCreationCode =
            abi.encodePacked(type(YieldDispatcher).creationCode, abi.encode(localEndpoint, address(launcher)));
        assertEq(deployer.lastCreationCode(), expectedCreationCode);
        assertEq(deployer.lastSalt(), keccak256(abi.encodePacked("YieldDispatcher", uint256(2))));

        // Execute the exact creation code the script handed to the deployer and read back the
        // immutables the real constructor assigns. The YieldDispatcher constructor performs no
        // external calls, so a plain create is safe in the test EVM.
        bytes memory creationCode = deployer.lastCreationCode();
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(deployed != address(0), "creationCode deploy reverted");
        assertEq(YieldDispatcher(deployed).localEndpoint(), localEndpoint);
        assertEq(YieldDispatcher(deployed).memeverseLauncher(), address(launcher));
    }

    // Mirror of testDeployYieldDispatcherPinsConstructorArgEncoding for the staker. Same motivation:
    // _deployOmnichainMemecoinStaker builds the creation code by type-erased abi.encode, so a constructor
    // signature change would compile cleanly and silently bake a wrong localEndpoint immutable. A wrong
    // localEndpoint makes the lzCompose `msg.sender == localEndpoint` guard permanently false, so the
    // staker would silently drop every omnichain staking message. Byte-equality alone cannot catch
    // arg-order drift (both sides keep the handwritten order), so the captured bytes are also executed
    // and localEndpoint() read back: any arg-count mismatch reverts the create, any order mismatch
    // flips the read-back.
    function testDeployOmnichainMemecoinStakerPinsConstructorArgEncoding() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        address localEndpoint = address(0x1234);
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), localEndpoint);

        script.deployOmnichainMemecoinStakerForTest(2);

        assertEq(
            deployer.lastCreationCode(),
            abi.encodePacked(type(OmnichainMemecoinStaker).creationCode, abi.encode(localEndpoint))
        );
        assertEq(deployer.lastSalt(), keccak256(abi.encodePacked("OmnichainMemecoinStaker", uint256(2))));

        // Execute the exact creation code the script handed to the deployer and read back the immutable
        // the real constructor assigns. The staker constructor performs no external calls, so a plain
        // create is safe in the test EVM.
        bytes memory creationCode = deployer.lastCreationCode();
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(deployed != address(0), "creationCode deploy reverted");
        assertEq(OmnichainMemecoinStaker(deployed).localEndpoint(), localEndpoint);
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
        address commonInfo = address(0x4242);
        // Gas limits are hardcoded in the script (115000 / 135000); mirror them exactly so the
        // byte-equality check would fail if either literal were edited.
        uint128 oftReceiveGasLimit = 115000;
        uint128 omnichainStakingGasLimit = 135000;

        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setMemeverseCommonInfoForTest(commonInfo);
        script.setMemeverseLauncherForTest(address(launcher));
        script.setOmnichainMemecoinStakerForTest(STAKER);

        script.deployMemeverseOmnichainInteroperationForTest(2);

        assertEq(
            deployer.lastCreationCode(),
            abi.encodePacked(
                type(MemeverseOmnichainInteroperation).creationCode,
                abi.encode(
                    expectedOwner, commonInfo, address(launcher), STAKER, oftReceiveGasLimit, omnichainStakingGasLimit
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
        // The script passes MEMEVERSE_COMMON_INFO as the `_lzEndpointRegistry` constructor arg, so the
        // LZ_ENDPOINT_REGISTRY() read-back must equal commonInfo. Pinning this faithfully exposes any
        // future change to which script slot feeds that arg.
        assertEq(MemeverseOmnichainInteroperation(deployed).LZ_ENDPOINT_REGISTRY(), commonInfo);
        assertEq(MemeverseOmnichainInteroperation(deployed).MEMEVERSE_LAUNCHER(), address(launcher));
        assertEq(MemeverseOmnichainInteroperation(deployed).OMNICHAIN_MEMECOIN_STAKER(), STAKER);
        assertEq(MemeverseOmnichainInteroperation(deployed).oftReceiveGasLimit(), oftReceiveGasLimit);
        assertEq(MemeverseOmnichainInteroperation(deployed).omnichainStakingGasLimit(), omnichainStakingGasLimit);
        assertEq(MemeverseOmnichainInteroperation(deployed).owner(), expectedOwner);
    }

    // Regression: a zero local endpoint must fail loudly at deploy time instead of baking
    // localEndpoint=0 into a permanently unusable dispatcher (same guard as _deployGenesisCreditFactory).
    function testDeployYieldDispatcherRevertsOnZeroLocalEndpoint() external {
        MockScriptOutrunDeployer deployer = new MockScriptOutrunDeployer();
        script.setOutrunDeployerForTest(address(deployer));
        script.setEndpointForTest(uint32(block.chainid), address(0));

        vm.expectRevert("ZERO_LOCAL_ENDPOINT");
        script.deployYieldDispatcherForTest(2);

        // F1: pin that the guard fires BEFORE any OutrunDeployer call. The revert alone would still
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

    // RR-01 regression: a zero OUTRUN_DEPLOYER must fail loudly at dispatcher deploy time instead of
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

    // F1 regression: a zero local endpoint must fail loudly at deploy time instead of baking
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

    // F1 regression: a zero local endpoint must fail loudly at deploy time instead of baking
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

    // F1 regression: a zero local endpoint must fail loudly at deploy time instead of baking
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

    // F1 regression: a zero local endpoint must fail loudly at deploy time instead of baking
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

    // F2 regression: a zero OUTRUN_DEPLOYER must fail loudly at staker deploy time (the endpoint guard
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

    // F2 regression: a zero OUTRUN_DEPLOYER must fail loudly at interoperation deploy time (the staker
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

    // F3 regression: readiness must reject a staker whose localEndpoint() differs from
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
        address launchImplAddr = address(uint160(0x5001));
        address settlementImplAddr = address(uint160(0x5002));
        address feePreviewReaderAddr = address(uint160(0x5003));
        address liquidityImplAddr = address(uint160(0x5004));
        bytes memory siblingCode = address(hookImpl).code;
        vm.etch(launchImplAddr, siblingCode);
        vm.etch(settlementImplAddr, siblingCode);
        vm.etch(feePreviewReaderAddr, siblingCode);
        vm.etch(liquidityImplAddr, siblingCode);
        launcher.setLaunchImpl(launchImplAddr);
        launcher.setSettlementImpl(settlementImplAddr);
        launcher.setFeePreviewReader(feePreviewReaderAddr);
        launcher.setLiquidityImpl(liquidityImplAddr);
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
