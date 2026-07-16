// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MemeverseScript} from "../../script/MemeverseScript.s.sol";
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

    function setBootstrapImpl(address impl) external {
        bootstrapImpl = impl;
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

contract MockScriptYieldDispatcher {
    address public memeverseLauncher;

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
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
    }

    function testReadinessRevertsWhenUethReserveMaxIsZero() external {
        polend.setSettlementDustState(UETH, 0, 0);
        polend.setSettlementDustState(UUSD, 0, 1);

        vm.expectRevert("UETH_RESERVE_NOT_READY");
        script.requireDeploymentReady(address(0), address(0));
    }

    // readiness 校验 POLend.creditFactory() 指向有 code 的合约（POLEND_CREDIT_FACTORY_NOT_READY）。
    // 该检查在 reserve/sibling 检查之前，接好全部依赖后把 creditFactory 置空，应即回退。
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

    function testPublicOpenSupportedUAssetsLoadsEnvAndOpensWhenReady() external {
        MemeverseScriptHarness publicEntryScript = new MemeverseScriptHarness();
        publicEntryScript.setBroadcastSender(address(this));
        MockScriptRegistrationCenter center = new MockScriptRegistrationCenter();
        (address readyRouter, address readyHook) = _configureReadySwap();
        polend.setSettlementDustState(UETH, 0, 1);
        polend.setSettlementDustState(UUSD, 0, 1);
        _setReadinessEnv(address(script), address(launcher), address(polend), address(splitter));

        publicEntryScript.openSupportedUAssetsAfterReadiness(address(center), readyRouter, readyHook);

        assertTrue(center.supportedUAssets(UETH));
        assertTrue(center.supportedUAssets(UUSD));
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

        // readiness 校验四个 delegatecall/view sibling 有代码（_readLauncherImplSiblings 的
        // BOOTSTRAP/FEE_DISTRIBUTOR/FEE_PREVIEW/POL_MINTER 检查）；etch 有代码的地址并接线。
        address bootstrapImplAddr = address(uint160(0x5001));
        address feeDistributorImplAddr = address(uint160(0x5002));
        address feePreviewReaderAddr = address(uint160(0x5003));
        address polMinterImplAddr = address(uint160(0x5004));
        bytes memory siblingCode = address(hookImpl).code;
        vm.etch(bootstrapImplAddr, siblingCode);
        vm.etch(feeDistributorImplAddr, siblingCode);
        vm.etch(feePreviewReaderAddr, siblingCode);
        vm.etch(polMinterImplAddr, siblingCode);
        launcher.setBootstrapImpl(bootstrapImplAddr);
        launcher.setFeeDistributorImpl(feeDistributorImplAddr);
        launcher.setFeePreviewReader(feePreviewReaderAddr);
        launcher.setPOLMinterImpl(polMinterImplAddr);
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

    function _setReadinessEnv(address owner_, address launcher_, address polend_, address splitter_) internal {
        vm.setEnv("OWNER", vm.toString(owner_));
        vm.setEnv("UETH", vm.toString(UETH));
        vm.setEnv("UUSD", vm.toString(UUSD));
        vm.setEnv("MEMEVERSE_LAUNCHER", vm.toString(launcher_));
        vm.setEnv("MEMEVERSE_REGISTRAR", vm.toString(address(registrar)));
        vm.setEnv("MEMEVERSE_PROXY_DEPLOYER", vm.toString(address(proxyDeployer)));
        vm.setEnv("MEMEVERSE_YIELD_DISPATCHER", vm.toString(address(yieldDispatcher)));
        vm.setEnv("POLEND", vm.toString(polend_));
        vm.setEnv("POLSPLITTER", vm.toString(splitter_));
    }
}
