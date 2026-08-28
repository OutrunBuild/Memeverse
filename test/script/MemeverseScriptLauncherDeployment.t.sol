// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title MemeverseScript launcher deployment orchestration tests
/// @notice Exercises the launcher deployment orchestration of script/MemeverseScript.s.sol:
///         the `_deployMemeverseLauncher` proxy deployment (CREATE3 salts, owner wiring, fund
///         metadata bootstrap) and the `_requireDeploymentReady` pre-open readiness gate.
import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";

import {MemeverseUniswapHookLens} from "../../src/swap/MemeverseUniswapHookLens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {LauncherReadinessMockBase} from "../mocks/verse/LauncherReadinessMockBase.sol";
import {IOutrunDeployer} from "../../script/deployment/interfaces/IOutrunDeployer.sol";
import {MemeverseScript} from "../../script/MemeverseScript.s.sol";

contract MockScriptOutrunDeployer is IOutrunDeployer {
    address public lastDeployed;
    address public lastDeployCaller;
    bytes32 public lastSalt;
    mapping(address deployCaller => mapping(bytes32 salt => address deployed)) public deployments;

    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed) {
        bytes32 namespacedSalt = keccak256(abi.encodePacked(msg.sender, salt));
        deployed = CREATE3.deploy(namespacedSalt, creationCode, msg.value);
        deployments[msg.sender][salt] = deployed;
        lastDeployCaller = msg.sender;
        lastSalt = salt;
        lastDeployed = deployed;
    }

    function getDeployed(address deployCaller, bytes32 salt) external view returns (address deployed) {
        bytes32 namespacedSalt = keccak256(abi.encodePacked(deployCaller, salt));
        return CREATE3.getDeployed(namespacedSalt);
    }
}

contract MockReadinessLauncher is LauncherReadinessMockBase {
    mapping(address uAsset => uint256 minTotalFund) internal minTotalFunds;
    mapping(address uAsset => uint256 fundBasedAmount) internal fundBasedAmounts;

    constructor(
        address owner_,
        address registrar_,
        address proxyDeployer_,
        address yieldDispatcher_,
        address polend_,
        address polSplitter_
    ) {
        owner = owner_;
        memeverseRegistrar = registrar_;
        memeverseProxyDeployer = proxyDeployer_;
        yieldDispatcher = yieldDispatcher_;
        polend = polend_;
        polSplitter = polSplitter_;
    }

    function setFundMetaData(address uAsset, uint256 minTotalFund, uint256 fundBasedAmount) external {
        minTotalFunds[uAsset] = minTotalFund;
        fundBasedAmounts[uAsset] = fundBasedAmount;
    }

    function fundMetaDatas(address uAsset) external view returns (uint256, uint256) {
        return (minTotalFunds[uAsset], fundBasedAmounts[uAsset]);
    }

    function setLaunchImpl(address impl) external {
        launchImpl = impl;
    }
}

contract MockReadinessRegistrar {
    address public MEMEVERSE_LAUNCHER;

    constructor(address launcher_) {
        MEMEVERSE_LAUNCHER = launcher_;
    }

    function setLauncher(address launcher_) external {
        MEMEVERSE_LAUNCHER = launcher_;
    }
}

contract MockReadinessProxyDeployer {
    address public memeverseLauncher;

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
    }

    function setLauncher(address launcher_) external {
        memeverseLauncher = launcher_;
    }
}

contract MockReadinessYieldDispatcher {
    address public memeverseLauncher;
    address public localEndpoint;

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
    }

    function setLauncher(address launcher_) external {
        memeverseLauncher = launcher_;
    }

    function setLocalEndpoint(address endpoint_) external {
        localEndpoint = endpoint_;
    }
}

contract MockReadinessPOLend {
    address public launcher;
    address public splitter;
    address public creditFactory;
    mapping(address uAsset => uint128 maxReserve) internal maxReserves;

    constructor(address launcher_, address splitter_) {
        launcher = launcher_;
        splitter = splitter_;
        creditFactory = address(this);
    }

    function setDependencies(address launcher_, address splitter_) external {
        launcher = launcher_;
        splitter = splitter_;
    }

    function setCreditFactory(address creditFactory_) external {
        creditFactory = creditFactory_;
    }

    function setReserve(address uAsset, uint128 maxReserve) external {
        maxReserves[uAsset] = maxReserve;
    }

    function settlementDustStates(address uAsset) external view returns (uint128, uint128) {
        return (0, maxReserves[uAsset]);
    }
}

contract MockReadinessPOLSplitter {
    address public launcher;
    address public polend;

    constructor(address launcher_, address polend_) {
        launcher = launcher_;
        polend = polend_;
    }

    function setDependencies(address launcher_, address polend_) external {
        launcher = launcher_;
        polend = polend_;
    }
}

contract MockReadinessRouter {
    address public hook;
    address public hookLens;
    address public poolManager;

    constructor(address hook_, address hookLens_, address poolManager_) {
        hook = hook_;
        hookLens = hookLens_;
        poolManager = poolManager_;
    }

    function setHook(address hook_) external {
        hook = hook_;
    }

    function setHookLens(address lens_) external {
        hookLens = lens_;
    }
}

contract MockReadinessHook {
    address public launcher;
    address public poolInitializer;
    address public poolManager;
}

contract TestableMemeverseScript is MemeverseScript {
    function configureLauncherDeployment(
        address localEndpoint_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address lzEndpointRegistry_,
        address polend_,
        address polSplitter_,
        address outrunDeployer_,
        address ueth_,
        address uusd_
    ) external {
        configureLauncherDeploymentWithOwner(
            address(this),
            localEndpoint_,
            memeverseRegistrar_,
            memeverseProxyDeployer_,
            yieldDispatcher_,
            lzEndpointRegistry_,
            polend_,
            polSplitter_,
            outrunDeployer_,
            ueth_,
            uusd_
        );
    }

    function configureLauncherDeploymentWithOwner(
        address initialOwner_,
        address localEndpoint_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address lzEndpointRegistry_,
        address polend_,
        address polSplitter_,
        address outrunDeployer_,
        address ueth_,
        address uusd_
    ) public {
        owner = initialOwner_;
        MEMEVERSE_REGISTRAR = memeverseRegistrar_;
        MEMEVERSE_PROXY_DEPLOYER = memeverseProxyDeployer_;
        MEMEVERSE_YIELD_DISPATCHER = yieldDispatcher_;
        LZ_ENDPOINT_REGISTRY = lzEndpointRegistry_;
        POLEND = polend_;
        POLSPLITTER = polSplitter_;
        OUTRUN_DEPLOYER = outrunDeployer_;
        UETH = ueth_;
        UUSD = uusd_;
        endpoints[uint32(block.chainid)] = localEndpoint_;
    }

    function deployMemeverseLauncherHarness(uint256 nonce) external {
        _deployMemeverseLauncher(nonce);
    }

    function setOmnichainMemecoinStakerForTest(address staker) external {
        OMNICHAIN_MEMECOIN_STAKER = staker;
    }

    function setMemeverseOmnichainInteroperationForTest(address interoperation) external {
        MEMEVERSE_OMNICHAIN_INTEROPERATION = interoperation;
    }

    function configureReadinessHarness(
        address launcher_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address polend_,
        address polSplitter_,
        address ueth_,
        address uusd_
    ) external {
        MEMEVERSE_LAUNCHER = launcher_;
        MEMEVERSE_REGISTRAR = memeverseRegistrar_;
        MEMEVERSE_PROXY_DEPLOYER = memeverseProxyDeployer_;
        MEMEVERSE_YIELD_DISPATCHER = yieldDispatcher_;
        POLEND = polend_;
        POLSPLITTER = polSplitter_;
        UETH = ueth_;
        UUSD = uusd_;
    }

    function requireDeploymentReadyHarness(address swapRouter, address hook) external view {
        _requireDeploymentReady(swapRouter, hook);
    }

    function _beginMemeverseLauncherOwnerExecution(address initialOwner) internal override {
        vm.startPrank(initialOwner);
    }

    function _endMemeverseLauncherOwnerExecution() internal override {
        vm.stopPrank();
    }
}

/// @notice Production-faithful harness: inherits `MemeverseScript` WITHOUT overriding
///         `_beginMemeverseLauncherOwnerExecution`, so the owner-execution hook stays the base
///         no-op (no `vm.startPrank(initialOwner)`). This mirrors how the script actually runs under
///         `forge script --broadcast`, where no prank rescues onlyOwner calls. Used by regression
///         tests that must exercise the real deployer != owner deployment path.
contract ProductionFaithfulMemeverseScript is MemeverseScript {
    function configureLauncherDeploymentWithOwner(
        address initialOwner_,
        address localEndpoint_,
        address memeverseRegistrar_,
        address memeverseProxyDeployer_,
        address yieldDispatcher_,
        address lzEndpointRegistry_,
        address polend_,
        address polSplitter_,
        address outrunDeployer_,
        address ueth_,
        address uusd_
    ) external {
        owner = initialOwner_;
        MEMEVERSE_REGISTRAR = memeverseRegistrar_;
        MEMEVERSE_PROXY_DEPLOYER = memeverseProxyDeployer_;
        MEMEVERSE_YIELD_DISPATCHER = yieldDispatcher_;
        LZ_ENDPOINT_REGISTRY = lzEndpointRegistry_;
        POLEND = polend_;
        POLSPLITTER = polSplitter_;
        OUTRUN_DEPLOYER = outrunDeployer_;
        UETH = ueth_;
        UUSD = uusd_;
        endpoints[uint32(block.chainid)] = localEndpoint_;
    }

    function deployMemeverseLauncherHarness(uint256 nonce) external {
        _deployMemeverseLauncher(nonce);
    }
}

contract MemeverseScriptLauncherDeploymentTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    address internal constant LOCAL_ENDPOINT = address(0x1001);
    address internal constant REGISTRAR = address(0x1002);
    address internal constant PROXY_DEPLOYER = address(0x1003);
    address internal constant YIELD_DISPATCHER = address(0x1004);
    address internal constant LZ_ENDPOINT_REGISTRY = address(0x1005);
    address internal constant POLEND = address(0x1006);
    address internal constant POLSPLITTER = address(0x1007);
    address internal constant UETH = address(0x1008);
    address internal constant UUSD = address(0x1009);
    address internal constant MEMEVERSE_OMNICHAIN_INTEROPERATION = address(0x100A);
    // eid() the mocked local endpoint reports; must equal the registry pin's local-chain answer so
    // the readiness local anchor (REGISTRY_LOCAL_EID_NOT_READY) is satisfied.
    uint32 internal constant LOCAL_CHAIN_EID = 40_001;

    TestableMemeverseScript internal scriptHarness;
    ProductionFaithfulMemeverseScript internal productionHarness;
    MockScriptOutrunDeployer internal outrunDeployer;
    address internal readySwapRouter;
    address internal readySwapHook;

    function setUp() external {
        scriptHarness = new TestableMemeverseScript();
        productionHarness = new ProductionFaithfulMemeverseScript();
        outrunDeployer = new MockScriptOutrunDeployer();
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );
    }

    function testDeployMemeverseLauncherDeploysUupsProxyAtCanonicalAddress() external {
        uint256 nonce = 2;
        address deployCaller = address(scriptHarness);
        address initialOwner = address(scriptHarness);
        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        bytes32 polendSalt = keccak256(abi.encodePacked("POLend", nonce));
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));

        address predictedProxy = outrunDeployer.getDeployed(deployCaller, launcherSalt);
        address predictedPolend = outrunDeployer.getDeployed(deployCaller, polendSalt);
        address predictedPolSplitter = outrunDeployer.getDeployed(deployCaller, polSplitterSalt);
        scriptHarness.deployMemeverseLauncherHarness(nonce);

        address proxy = outrunDeployer.deployments(deployCaller, launcherSalt);
        address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        MemeverseLauncherUpgradeable deployedLauncher = MemeverseLauncherUpgradeable(proxy);

        assertEq(proxy, predictedProxy);
        assertNotEq(proxy, implementation);
        assertGt(implementation.code.length, 0);
        assertEq(deployedLauncher.owner(), initialOwner);
        IMemeverseLauncher.LauncherContracts memory contracts = deployedLauncher.getLauncherContracts();
        IMemeverseLauncher.LauncherParameters memory parameters = deployedLauncher.getLauncherParameters();
        assertEq(contracts.localLzEndpoint, LOCAL_ENDPOINT);
        assertEq(contracts.memeverseRegistrar, REGISTRAR);
        assertEq(contracts.memeverseProxyDeployer, PROXY_DEPLOYER);
        assertEq(contracts.yieldDispatcher, YIELD_DISPATCHER);
        assertEq(contracts.lzEndpointRegistry, LZ_ENDPOINT_REGISTRY);
        assertEq(deployedLauncher.polend(), predictedPolend);
        assertEq(contracts.polSplitter, predictedPolSplitter);
        assertEq(parameters.executorRewardRate, 25);
        assertEq(parameters.oftReceiveGasLimit, 115000);
        assertEq(parameters.yieldDispatcherGasLimit, 135000);
        assertEq(parameters.preorderCapRatio, 2500);
        assertEq(parameters.preorderVestingDuration, 7 days);

        (uint256 uethMinTotalFund, uint256 uethFundBasedAmount) = deployedLauncher.fundMetaDatas(UETH);
        (uint256 uusdMinTotalFund, uint256 uusdFundBasedAmount) = deployedLauncher.fundMetaDatas(UUSD);

        assertEq(uethMinTotalFund, 1e19);
        assertEq(uethFundBasedAmount, 1000000);
        assertEq(uusdMinTotalFund, 20000 * 1e18);
        assertEq(uusdFundBasedAmount, 100000);

        // Verify implementation storage is completely isolated from proxy storage.
        // Direct calls on the implementation (not through the proxy) should return default values.
        MemeverseLauncherUpgradeable impl = MemeverseLauncherUpgradeable(implementation);
        assertEq(impl.owner(), address(0), "impl owner should be zero");
        assertEq(impl.getLauncherParameters().executorRewardRate, 0, "impl reward rate should be zero");
        assertEq(impl.getLauncherParameters().preorderCapRatio, 0, "impl preorder cap should be zero");
    }

    function testDeployMemeverseLauncherKeepsDeployNamespaceWhenInitialOwnerDiffers() external {
        uint256 nonce = 3;
        address deployCaller = address(scriptHarness);
        address initialOwner = address(0x4567);
        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        bytes32 polendSalt = keccak256(abi.encodePacked("POLend", nonce));
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));
        scriptHarness.configureLauncherDeploymentWithOwner(
            initialOwner,
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );

        address predictedProxy = outrunDeployer.getDeployed(deployCaller, launcherSalt);
        address predictedPolend = outrunDeployer.getDeployed(deployCaller, polendSalt);
        address predictedPolSplitter = outrunDeployer.getDeployed(deployCaller, polSplitterSalt);
        scriptHarness.deployMemeverseLauncherHarness(nonce);

        address proxy = outrunDeployer.deployments(deployCaller, launcherSalt);
        MemeverseLauncherUpgradeable deployedLauncher = MemeverseLauncherUpgradeable(proxy);
        (uint256 uethMinTotalFund, uint256 uethFundBasedAmount) = deployedLauncher.fundMetaDatas(UETH);
        (uint256 uusdMinTotalFund, uint256 uusdFundBasedAmount) = deployedLauncher.fundMetaDatas(UUSD);

        assertEq(proxy, predictedProxy);
        assertEq(deployedLauncher.owner(), initialOwner);
        assertEq(deployedLauncher.polend(), predictedPolend);
        assertEq(deployedLauncher.getLauncherContracts().polSplitter, predictedPolSplitter);
        // fund metadata remains zero: _setMemeverseLauncherFundMetaData is skipped when deployCaller != initialOwner
        assertEq(uethMinTotalFund, 0);
        assertEq(uethFundBasedAmount, 0);
        assertEq(uusdMinTotalFund, 0);
        assertEq(uusdFundBasedAmount, 0);
    }

    /// @notice Dual-role end-to-end: after deployCaller != initialOwner deploys the
    ///         proxy with zero metadata, initialOwner can call setFundMetaData and
    ///         the values are stored correctly.  This proves the handoff path that
    ///         readiness and open-registration depend on actually works on the real
    ///         MemeverseLauncherUpgradeable — not just on mock contracts.
    function testDualRoleOwnerCanWriteFundMetaDataAfterDeployment() external {
        uint256 nonce = 4;
        address deployCaller = address(scriptHarness);
        address initialOwner = address(0x4567);
        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        scriptHarness.configureLauncherDeploymentWithOwner(
            initialOwner,
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );

        scriptHarness.deployMemeverseLauncherHarness(nonce);

        address proxy = outrunDeployer.deployments(deployCaller, launcherSalt);
        MemeverseLauncherUpgradeable deployedLauncher = MemeverseLauncherUpgradeable(proxy);

        // Phase 1: metadata is zero immediately after dual-role deployment.
        (uint256 uethMinTotalFund, uint256 uethFundBasedAmount) = deployedLauncher.fundMetaDatas(UETH);
        (uint256 uusdMinTotalFund, uint256 uusdFundBasedAmount) = deployedLauncher.fundMetaDatas(UUSD);
        assertEq(uethMinTotalFund, 0, "ueth min should be zero before handoff");
        assertEq(uethFundBasedAmount, 0, "ueth based should be zero before handoff");
        assertEq(uusdMinTotalFund, 0, "uusd min should be zero before handoff");
        assertEq(uusdFundBasedAmount, 0, "uusd based should be zero before handoff");

        // Phase 2: initialOwner writes metadata — the handoff step that the
        // deploy script prints a WARNING about and that readiness depends on.
        vm.prank(initialOwner);
        deployedLauncher.setFundMetaData(UETH, 1e19, 1000000);
        vm.prank(initialOwner);
        deployedLauncher.setFundMetaData(UUSD, 50000 * 1e18, 200);

        (uethMinTotalFund, uethFundBasedAmount) = deployedLauncher.fundMetaDatas(UETH);
        (uusdMinTotalFund, uusdFundBasedAmount) = deployedLauncher.fundMetaDatas(UUSD);
        assertEq(uethMinTotalFund, 1e19, "ueth min should match after handoff");
        assertEq(uethFundBasedAmount, 1000000, "ueth based should match after handoff");
        assertEq(uusdMinTotalFund, 50000 * 1e18, "uusd min should match after handoff");
        assertEq(uusdFundBasedAmount, 200, "uusd based should match after handoff");

        // Phase 3: non-owner cannot write metadata — guard is still active.
        vm.prank(deployCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployCaller));
        deployedLauncher.setFundMetaData(UETH, 1, 1);
    }

    /// @notice Regression: in production-faithful mode (the owner-execution hook is the base no-op,
    ///         so NO vm.startPrank(initialOwner) wraps the deploy), a deployer != owner deployment
    ///         must NOT revert. Before the script fix, setLaunchImpl (onlyOwner) was called
    ///         unconditionally with msg.sender = deployer, reverting OwnableUnauthorizedAccount and
    ///         aborting the whole deploy. `scriptHarness` cannot catch this because it overrides the
    ///         hook to prank the owner; `productionHarness` does not, so it reproduces production.
    function testDeployerNotOwnerDoesNotRevertWhenBootstrapDeferredToOwner() external {
        uint256 nonce = 5;
        address initialOwner = address(0x4567);
        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));

        // deployer (= productionHarness address) != owner; the harness does not prank the owner.
        productionHarness.configureLauncherDeploymentWithOwner(
            initialOwner,
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );

        // Before the fix this reverted with OwnableUnauthorizedAccount; now bootstrap wiring is
        // deferred to the owner and the deploy completes.
        productionHarness.deployMemeverseLauncherHarness(nonce);

        address proxy = outrunDeployer.deployments(address(productionHarness), launcherSalt);
        assertNotEq(proxy, address(0), "launcher proxy not deployed");
        assertEq(MemeverseLauncherUpgradeable(proxy).owner(), initialOwner, "owner mismatch");
    }

    function testDeployMemeverseLauncherRevertsWhenUethUnset() external {
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            address(0),
            UUSD
        );

        vm.expectRevert("ZERO_UETH");
        scriptHarness.deployMemeverseLauncherHarness(2);
    }

    function testDeployMemeverseLauncherRevertsWhenUusdUnset() external {
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            address(0)
        );

        vm.expectRevert("ZERO_UUSD");
        scriptHarness.deployMemeverseLauncherHarness(2);
    }

    function testDeployMemeverseLauncherRevertsWhenLzEndpointRegistryUnset() external {
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            address(0),
            POLEND,
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );

        vm.expectRevert("ZERO_LZ_ENDPOINT_REGISTRY");
        scriptHarness.deployMemeverseLauncherHarness(2);
    }

    function testDeployMemeverseLauncherComputesPolendAddressFromDeployer() external {
        uint256 nonce = 2;
        address deployCaller = address(scriptHarness);
        bytes32 polendSalt = keccak256(abi.encodePacked("POLend", nonce));
        address expectedPolend = outrunDeployer.getDeployed(deployCaller, polendSalt);

        // Config POLEND is zero — deployer ignores it and computes from CREATE3.
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            address(0),
            POLSPLITTER,
            address(outrunDeployer),
            UETH,
            UUSD
        );
        scriptHarness.deployMemeverseLauncherHarness(nonce);

        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address proxy = outrunDeployer.deployments(deployCaller, launcherSalt);
        assertEq(MemeverseLauncherUpgradeable(proxy).polend(), expectedPolend);
    }

    function testDeployMemeverseLauncherComputesPolSplitterAddressFromDeployer() external {
        uint256 nonce = 2;
        address deployCaller = address(scriptHarness);
        bytes32 polSplitterSalt = keccak256(abi.encodePacked("POLSplitter", nonce));
        address expectedPolSplitter = outrunDeployer.getDeployed(deployCaller, polSplitterSalt);

        // Config POLSPLITTER is zero — deployer ignores it and computes from CREATE3.
        scriptHarness.configureLauncherDeployment(
            LOCAL_ENDPOINT,
            REGISTRAR,
            PROXY_DEPLOYER,
            YIELD_DISPATCHER,
            LZ_ENDPOINT_REGISTRY,
            POLEND,
            address(0),
            address(outrunDeployer),
            UETH,
            UUSD
        );
        scriptHarness.deployMemeverseLauncherHarness(nonce);

        bytes32 launcherSalt = keccak256(abi.encodePacked("MemeverseLauncher", nonce));
        address proxy = outrunDeployer.deployments(deployCaller, launcherSalt);
        assertEq(MemeverseLauncherUpgradeable(proxy).getLauncherContracts().polSplitter, expectedPolSplitter);
    }

    function testRequireDeploymentReadyChecksLauncherBoundDependencies() external {
        _configureReadyDependencies(address(0), address(0), address(0), address(0));

        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testRequireDeploymentReadyRevertsWhenLauncherOwnerDiffers() external {
        _configureReadyDependencies(address(0xDEAD), address(0), address(0), address(0));

        vm.expectRevert("LAUNCHER_OWNER_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testRequireDeploymentReadyRevertsWhenRegistrarUsesWrongLauncher() external {
        _configureReadyDependencies(address(0), address(0xDEAD), address(0), address(0));

        vm.expectRevert("REGISTRAR_LAUNCHER_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testRequireDeploymentReadyRevertsWhenProxyDeployerUsesWrongLauncher() external {
        _configureReadyDependencies(address(0), address(0), address(0xDEAD), address(0));

        vm.expectRevert("PROXY_DEPLOYER_LAUNCHER_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testRequireDeploymentReadyRevertsWhenYieldDispatcherUsesWrongLauncher() external {
        _configureReadyDependencies(address(0), address(0), address(0), address(0xDEAD));

        vm.expectRevert("YIELD_DISPATCHER_LAUNCHER_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testRequireDeploymentReadyRevertsWhenSettlementImplNotSet() external {
        // Readiness must reject opening when the settlement delegatecall sibling has no code.
        MockReadinessLauncher readyLauncher =
            _configureReadyDependencies(address(0), address(0), address(0), address(0));
        readyLauncher.setSettlementImpl(address(0));

        vm.expectRevert("SETTLEMENT_IMPL_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    // Readiness checks launchImpl before the other sibling contracts.
    function testRequireDeploymentReadyRevertsWhenLaunchImplNotSet() external {
        MockReadinessLauncher readyLauncher =
            _configureReadyDependencies(address(0), address(0), address(0), address(0));
        readyLauncher.setLaunchImpl(address(0));

        vm.expectRevert("LAUNCH_IMPL_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    // Readiness checks the independent fee preview reader after launch and settlement siblings.
    function testRequireDeploymentReadyRevertsWhenFeePreviewReaderNotSet() external {
        MockReadinessLauncher readyLauncher =
            _configureReadyDependencies(address(0), address(0), address(0), address(0));
        readyLauncher.setFeePreviewReader(address(0));

        vm.expectRevert("FEE_PREVIEW_READER_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    // readiness check: POLendUpgradeable.creditFactory() must point to a contract with code (POLEND_CREDIT_FACTORY_NOT_READY).
    // This check runs before the reserve/sibling checks; after wiring all dependencies, blanking creditFactory
    // should revert immediately.
    function testRequireDeploymentReadyRevertsWhenPolendCreditFactoryHasNoCode() external {
        MockReadinessLauncher readyLauncher =
            _configureReadyDependencies(address(0), address(0), address(0), address(0));
        MockReadinessPOLend polend = MockReadinessPOLend(readyLauncher.polend());
        polend.setCreditFactory(address(0));

        vm.expectRevert("POLEND_CREDIT_FACTORY_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function _configureReadyDependencies(
        address launcherOwner,
        address registrarLauncher,
        address proxyDeployerLauncher,
        address dispatcherLauncher
    ) internal returns (MockReadinessLauncher launcher) {
        MockReadinessRegistrar registrar = new MockReadinessRegistrar(address(0));
        MockReadinessProxyDeployer proxyDeployer = new MockReadinessProxyDeployer(address(0));
        MockReadinessYieldDispatcher dispatcher = new MockReadinessYieldDispatcher(address(0));
        MockReadinessPOLend polend = new MockReadinessPOLend(address(0), address(0));
        MockReadinessPOLSplitter splitter = new MockReadinessPOLSplitter(address(0), address(0));
        launcher = new MockReadinessLauncher(
            launcherOwner == address(0) ? address(scriptHarness) : launcherOwner,
            address(registrar),
            address(proxyDeployer),
            address(dispatcher),
            address(polend),
            address(splitter)
        );

        address launcherAddress = address(launcher);
        registrar.setLauncher(registrarLauncher == address(0) ? launcherAddress : registrarLauncher);
        proxyDeployer.setLauncher(proxyDeployerLauncher == address(0) ? launcherAddress : proxyDeployerLauncher);
        dispatcher.setLauncher(dispatcherLauncher == address(0) ? launcherAddress : dispatcherLauncher);
        // Readiness reads back launcher.lzEndpointRegistry and compares it with the script-side pin
        // (set to LZ_ENDPOINT_REGISTRY by setUp's configureLauncherDeployment); keep them consistent
        // and give the pin code (REGISTRY_CODE_NOT_READY) like the creditFactory/staker etches below.
        launcher.setLzEndpointRegistry(LZ_ENDPOINT_REGISTRY);
        vm.etch(LZ_ENDPOINT_REGISTRY, type(MockReadinessHook).creationCode);
        // Readiness reads back dispatcher.localEndpoint() and compares it with endpoints[block.chainid]
        // (set to LOCAL_ENDPOINT by setUp's configureLauncherDeployment); keep them consistent.
        dispatcher.setLocalEndpoint(LOCAL_ENDPOINT);
        // Endpoint capability check: _requireDeploymentReady now requires the endpoint to have code
        // and expose the MessagingComposer composeQueue getter (ENDPOINT_CODE_NOT_READY /
        // ENDPOINT_COMPOSE_QUEUE_NOT_READY). LOCAL_ENDPOINT (0x1001) has no code, so etch and mock
        // the probe like the staker/creditFactory etches above (mockCall cannot fake EXTCODESIZE).
        vm.etch(LOCAL_ENDPOINT, type(MockReadinessHook).creationCode);
        vm.mockCall(
            LOCAL_ENDPOINT,
            abi.encodeWithSignature(
                "composeQueue(address,address,bytes32,uint16)", address(1), address(1), bytes32(0), uint16(0)
            ),
            abi.encode(bytes32(0))
        );
        polend.setDependencies(launcherAddress, address(splitter));
        splitter.setDependencies(launcherAddress, address(polend));
        // readiness checks POLendUpgradeable.creditFactory() points at a contract with code
        // (POLEND_CREDIT_FACTORY_NOT_READY); wire a coded address so the check passes.
        address creditFactoryAddr = address(uint160(0x6001));
        vm.etch(creditFactoryAddr, type(MockReadinessHook).creationCode);
        polend.setCreditFactory(creditFactoryAddr);
        // Readiness requires code at OMNICHAIN_MEMECOIN_STAKER (STAKER_CODE_NOT_READY); wire a
        // coded address like the creditFactory etch above.
        address stakerAddr = address(uint160(0x6005));
        vm.etch(stakerAddr, type(MockReadinessHook).creationCode);
        scriptHarness.setOmnichainMemecoinStakerForTest(stakerAddr);
        // Readiness reads back staker.localEndpoint() (STAKER_ENDPOINT_NOT_READY); the etched
        // MockReadinessHook has no such getter, so mock it to match endpoints[block.chainid]
        // (LOCAL_ENDPOINT, kept consistent with the dispatcher above).
        vm.mockCall(stakerAddr, abi.encodeWithSignature("localEndpoint()"), abi.encode(LOCAL_ENDPOINT));
        // Readiness requires code at MEMEVERSE_OMNICHAIN_INTEROPERATION and reads its constructor-baked
        // LZ_ENDPOINT_REGISTRY immutable back against the pin (INTEROPERATION_CODE_NOT_READY /
        // INTEROPERATION_REGISTRY_NOT_READY); etch code and mock the getter like the staker above
        // (mockCall cannot fake EXTCODESIZE).
        vm.etch(MEMEVERSE_OMNICHAIN_INTEROPERATION, type(MockReadinessHook).creationCode);
        vm.mockCall(
            MEMEVERSE_OMNICHAIN_INTEROPERATION,
            abi.encodeWithSignature("LZ_ENDPOINT_REGISTRY()"),
            abi.encode(LZ_ENDPOINT_REGISTRY)
        );
        scriptHarness.setMemeverseOmnichainInteroperationForTest(MEMEVERSE_OMNICHAIN_INTEROPERATION);
        // Registry content probe: _requireDeploymentReady reads the registry pin's local-chain
        // lzEndpointIdOfChain and anchors it against endpoints[block.chainid].eid(). This harness
        // wires endpoints via configureLauncherDeployment (no env/_chainsInit, empty omnichainIds),
        // so only the local anchor fires; satisfy both sides with consistent mockCall answers like
        // the staker/interoperation mocks above.
        vm.mockCall(
            LZ_ENDPOINT_REGISTRY,
            abi.encodeWithSignature("lzEndpointIdOfChain(uint32)", uint32(block.chainid)),
            abi.encode(LOCAL_CHAIN_EID)
        );
        vm.mockCall(LOCAL_ENDPOINT, abi.encodeWithSignature("eid()"), abi.encode(LOCAL_CHAIN_EID));
        polend.setReserve(UETH, 1);
        polend.setReserve(UUSD, 1);
        // Minimum config that passes the derived virtual-buffer guard (143 * 1 * 7 / 1000 = 1 > 0);
        // values below 143 would round V to zero and keep readiness closed.
        launcher.setFundMetaData(UETH, 143, 1);
        launcher.setFundMetaData(UUSD, 143, 1);

        address poolManager = address(uint160(0x4631));
        MockReadinessRouter router = new MockReadinessRouter(
            address(0), address(new MemeverseUniswapHookLens(IPoolManager(poolManager))), poolManager
        );
        MockReadinessHook hookImpl = new MockReadinessHook();
        readySwapHook = address(uint160(0x28cc));
        vm.etch(readySwapHook, address(hookImpl).code);
        vm.mockCall(readySwapHook, abi.encodeWithSignature("launcher()"), abi.encode(launcherAddress));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("poolInitializer()"), abi.encode(address(router)));

        // Diamond facets must exist and share the hook's PoolManager (readiness mirrors _requireFacetPoolManager).
        address swapFacet = address(uint160(0xFAB1));
        address dynamicFeeFacet = address(uint160(0xFAB2));
        address settlementFacet = address(uint160(0xFAB3));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("swapFacet()"), abi.encode(swapFacet));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("dynamicFeeFacet()"), abi.encode(dynamicFeeFacet));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("settlementFacet()"), abi.encode(settlementFacet));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));
        bytes memory facetCode = type(MockReadinessHook).creationCode;
        vm.etch(swapFacet, facetCode);
        vm.etch(dynamicFeeFacet, facetCode);
        vm.etch(settlementFacet, facetCode);
        vm.mockCall(swapFacet, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));
        vm.mockCall(dynamicFeeFacet, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));
        vm.mockCall(settlementFacet, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));

        router.setHook(readySwapHook);
        readySwapRouter = address(router);
        launcher.setMemeverseSwapRouter(readySwapRouter);
        launcher.setMemeverseUniswapHook(readySwapHook);

        // Readiness requires code at every launch/settlement/view/liquidity sibling before opening.
        address launchImplAddr = address(uint160(0x5001));
        address settlementImplAddr = address(uint160(0x5002));
        address feePreviewReaderAddr = address(uint160(0x5003));
        address liquidityImplAddr = address(uint160(0x5004));
        bytes memory siblingCode = type(MockReadinessHook).creationCode;
        vm.etch(launchImplAddr, siblingCode);
        vm.etch(settlementImplAddr, siblingCode);
        vm.etch(feePreviewReaderAddr, siblingCode);
        vm.etch(liquidityImplAddr, siblingCode);
        launcher.setLaunchImpl(launchImplAddr);
        launcher.setSettlementImpl(settlementImplAddr);
        launcher.setFeePreviewReader(feePreviewReaderAddr);
        launcher.setLiquidityImpl(liquidityImplAddr);

        scriptHarness.configureReadinessHarness(
            launcherAddress,
            address(registrar),
            address(proxyDeployer),
            address(dispatcher),
            address(polend),
            address(splitter),
            UETH,
            UUSD
        );
    }
}
