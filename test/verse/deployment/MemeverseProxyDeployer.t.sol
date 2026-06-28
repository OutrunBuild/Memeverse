// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CREATE3} from "solmate/utils/CREATE3.sol";

import {MemeverseProxyDeployer} from "../../../src/verse/deployment/MemeverseProxyDeployer.sol";
import {IMemeverseProxyDeployer} from "../../../src/verse/interfaces/IMemeverseProxyDeployer.sol";
import {IOutrunDeployer} from "../../../script/IOutrunDeployer.sol";
import {MemeverseScript} from "../../../script/MemeverseScript.s.sol";
import {MemeverseUniswapHookLens} from "../../../src/swap/MemeverseUniswapHookLens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MemeverseLauncher} from "../../../src/verse/MemeverseLauncher.sol";
import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {LauncherReadinessMockBase} from "../../mocks/verse/LauncherReadinessMockBase.sol";

contract MockDeployerCloneable {
    uint256 public marker;

    /// @notice Set marker.
    /// @param marker_ See implementation.
    function setMarker(uint256 marker_) external {
        marker = marker_;
    }
}

contract MockDeployerGovernor {
    string public name;
    address public token;
    uint48 public votingDelay;
    uint32 public votingPeriod;
    uint256 public proposalThreshold;
    uint256 public quorumNumerator;
    address public incentivizer;
    uint256 public minQuorum;
    uint256 public governanceStartTime;
    uint256 public maxTreasurySpendRatio;
    uint256 public upgradeSupermajorityRatio;

    function initialize(
        string memory name_,
        address token_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_,
        address incentivizer_,
        uint256 minQuorum_,
        uint256 bootstrapPeriod_,
        uint256 maxTreasurySpendRatio_,
        uint256 upgradeSupermajorityRatio_
    ) external {
        name = name_;
        token = token_;
        votingDelay = votingDelay_;
        votingPeriod = votingPeriod_;
        proposalThreshold = proposalThreshold_;
        quorumNumerator = quorumNumerator_;
        incentivizer = incentivizer_;
        minQuorum = minQuorum_;
        governanceStartTime = block.timestamp + bootstrapPeriod_;
        maxTreasurySpendRatio = maxTreasurySpendRatio_;
        upgradeSupermajorityRatio = upgradeSupermajorityRatio_;
    }
}

contract MockDeployerIncentivizer {
    address public governor;
    address[] public initFundTokens;

    /// @notice Initialize.
    /// @param governor_ See implementation.
    /// @param initFundTokens_ See implementation.
    function initialize(address governor_, address[] memory initFundTokens_) external {
        governor = governor_;
        initFundTokens = initFundTokens_;
    }

    /// @notice Init fund token.
    /// @param index See implementation.
    /// @return See implementation.
    function initFundToken(uint256 index) external view returns (address) {
        return initFundTokens[index];
    }
}

contract MockDeployerMemecoin {
    uint256 public totalSupply = 1_000_000 ether;
}

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

    constructor(address launcher_) {
        memeverseLauncher = launcher_;
    }

    function setLauncher(address launcher_) external {
        memeverseLauncher = launcher_;
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
    address public dynamicFeeEngine;
    address public poolManager;
}

contract MockReadinessEngine {
    address public authorizedHook;
    address public owner;
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
        MEMEVERSE_COMMON_INFO = lzEndpointRegistry_;
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

    function envAddressWithFallbackHarness(string memory primary, string memory fallbackName)
        external
        view
        returns (address)
    {
        return _envAddressWithFallback(primary, fallbackName);
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
        MEMEVERSE_COMMON_INFO = lzEndpointRegistry_;
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

contract MemeverseProxyDeployerTest is Test {
    using Clones for address;

    address internal constant OWNER = address(0xABCD);
    address internal constant LAUNCHER = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);

    MockDeployerCloneable internal memecoinImplementation;
    MockDeployerCloneable internal polImplementation;
    MockDeployerCloneable internal vaultImplementation;
    MockDeployerGovernor internal governorImplementation;
    MockDeployerIncentivizer internal incentivizerImplementation;
    MemeverseProxyDeployer internal deployer;
    MockDeployerMemecoin internal mockMemecoin;

    /// @notice Set up.
    function setUp() external {
        memecoinImplementation = new MockDeployerCloneable();
        polImplementation = new MockDeployerCloneable();
        vaultImplementation = new MockDeployerCloneable();
        governorImplementation = new MockDeployerGovernor();
        incentivizerImplementation = new MockDeployerIncentivizer();
        mockMemecoin = new MockDeployerMemecoin();

        deployer = new MemeverseProxyDeployer(
            OWNER,
            LAUNCHER,
            address(memecoinImplementation),
            address(polImplementation),
            address(vaultImplementation),
            address(governorImplementation),
            address(incentivizerImplementation),
            25,
            10,
            7 days,
            1000,
            6000
        );
    }

    /// @notice Test clone deployments only launcher and use deterministic addresses.
    function testCloneDeploymentsOnlyLauncherAndUseDeterministicAddresses() external {
        uint256 uniqueId = 7;

        vm.expectRevert(IMemeverseProxyDeployer.PermissionDenied.selector);
        deployer.deployMemecoin(uniqueId);

        address predictedMemecoin = address(memecoinImplementation)
            .predictDeterministicAddress(keccak256(abi.encode(uniqueId)), address(deployer));
        vm.prank(LAUNCHER);
        address deployedMemecoin = deployer.deployMemecoin(uniqueId);
        assertEq(deployedMemecoin, predictedMemecoin);

        address predictedPol =
            address(polImplementation).predictDeterministicAddress(keccak256(abi.encode(uniqueId)), address(deployer));
        vm.prank(LAUNCHER);
        address deployedPol = deployer.deployPOL(uniqueId);
        assertEq(deployedPol, predictedPol);

        address predictedVault = deployer.predictYieldVaultAddress(uniqueId);
        vm.prank(LAUNCHER);
        address deployedVault = deployer.deployYieldVault(uniqueId);
        assertEq(deployedVault, predictedVault);
    }

    /// @notice Test compute governor and incentivizer matches deployed proxies and initializes them.
    function testComputeGovernorAndIncentivizerMatchesDeployedProxiesAndInitializesThem() external {
        uint256 uniqueId = 42;
        address uAsset = address(0x1111);
        address memecoin = address(mockMemecoin);
        address pol = address(0x3333);
        address yieldVault = address(0x4444);

        (address predictedGovernor, address predictedIncentivizer) =
            deployer.computeGovernorAndIncentivizerAddress(uniqueId);

        vm.prank(LAUNCHER);
        (address governor, address incentivizer) =
            deployer.deployGovernorAndIncentivizer("MEME", uAsset, memecoin, pol, yieldVault, uniqueId, 123);

        assertEq(governor, predictedGovernor);
        assertEq(incentivizer, predictedIncentivizer);

        MockDeployerGovernor governorProxy = MockDeployerGovernor(governor);
        assertEq(governorProxy.name(), "MEME DAO");
        assertEq(governorProxy.token(), yieldVault);
        assertEq(governorProxy.votingDelay(), 1 days);
        assertEq(governorProxy.votingPeriod(), 1 weeks);
        assertEq(governorProxy.proposalThreshold(), 123);
        assertEq(governorProxy.quorumNumerator(), 25);
        assertEq(governorProxy.incentivizer(), incentivizer);
        assertEq(governorProxy.minQuorum(), 1_000_000 ether * 10 / 100);
        assertEq(governorProxy.governanceStartTime(), block.timestamp + 7 days);
        assertEq(governorProxy.maxTreasurySpendRatio(), 1000);
        assertEq(governorProxy.upgradeSupermajorityRatio(), 6000);

        MockDeployerIncentivizer incentivizerProxy = MockDeployerIncentivizer(incentivizer);
        assertEq(incentivizerProxy.governor(), governor);
        assertEq(incentivizerProxy.initFundToken(0), uAsset);
        assertEq(incentivizerProxy.initFundToken(1), memecoin);
        assertEq(incentivizerProxy.initFundToken(2), pol);
        assertEq(incentivizerProxy.initFundToken(3), yieldVault);
    }

    /// @notice Test set quorum numerator only owner and rejects zero.
    function testSetQuorumNumeratorOnlyOwnerAndRejectsZero() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        deployer.setQuorumNumerator(77);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseProxyDeployer.ZeroInput.selector);
        deployer.setQuorumNumerator(0);

        vm.prank(OWNER);
        deployer.setQuorumNumerator(77);
        assertEq(deployer.quorumNumerator(), 77);
    }

    /// @notice Test set min quorum numerator only owner and rejects zero.
    function testSetMinQuorumNumeratorOnlyOwnerAndRejectsZero() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        deployer.setMinQuorumNumerator(50);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseProxyDeployer.ZeroInput.selector);
        deployer.setMinQuorumNumerator(0);

        vm.prank(OWNER);
        deployer.setMinQuorumNumerator(50);
        assertEq(deployer.minQuorumNumerator(), 50);
    }

    /// @notice Test set bootstrap period only owner and rejects zero.
    function testSetBootstrapPeriodOnlyOwnerAndRejectsZero() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        deployer.setBootstrapPeriod(14 days);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseProxyDeployer.ZeroInput.selector);
        deployer.setBootstrapPeriod(0);

        vm.prank(OWNER);
        deployer.setBootstrapPeriod(14 days);
        assertEq(deployer.bootstrapPeriod(), 14 days);
    }

    /// @notice Test set max treasury spend ratio only owner and rejects zero.
    function testSetMaxTreasurySpendRatioOnlyOwnerAndRejectsZero() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        deployer.setMaxTreasurySpendRatio(2000);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseProxyDeployer.ZeroInput.selector);
        deployer.setMaxTreasurySpendRatio(0);

        vm.prank(OWNER);
        deployer.setMaxTreasurySpendRatio(2000);
        assertEq(deployer.maxTreasurySpendRatio(), 2000);
    }

    /// @notice Test set upgrade supermajority ratio only owner and rejects zero.
    function testSetUpgradeSupermajorityRatioOnlyOwnerAndRejectsZero() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        deployer.setUpgradeSupermajorityRatio(7000);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseProxyDeployer.ZeroInput.selector);
        deployer.setUpgradeSupermajorityRatio(0);

        vm.prank(OWNER);
        deployer.setUpgradeSupermajorityRatio(7000);
        assertEq(deployer.upgradeSupermajorityRatio(), 7000);
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
        MemeverseLauncher deployedLauncher = MemeverseLauncher(proxy);

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
        MemeverseLauncher impl = MemeverseLauncher(implementation);
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
        MemeverseLauncher deployedLauncher = MemeverseLauncher(proxy);
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
    ///         MemeverseLauncher — not just on mock contracts.
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
        MemeverseLauncher deployedLauncher = MemeverseLauncher(proxy);

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
        assertEq(MemeverseLauncher(proxy).owner(), initialOwner, "owner mismatch");
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
        assertEq(MemeverseLauncher(proxy).polend(), expectedPolend);
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
        assertEq(MemeverseLauncher(proxy).getLauncherContracts().polSplitter, expectedPolSplitter);
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

    // readiness 校验 POLend.creditFactory() 指向有 code 的合约（POLEND_CREDIT_FACTORY_NOT_READY）。
    // 该检查在 reserve/sibling 检查之前，接好全部依赖后把 creditFactory 置空，应即回退。
    function testRequireDeploymentReadyRevertsWhenPolendCreditFactoryHasNoCode() external {
        MockReadinessLauncher readyLauncher =
            _configureReadyDependencies(address(0), address(0), address(0), address(0));
        MockReadinessPOLend polend = MockReadinessPOLend(readyLauncher.polend());
        polend.setCreditFactory(address(0));

        vm.expectRevert("POLEND_CREDIT_FACTORY_NOT_READY");
        scriptHarness.requireDeploymentReadyHarness(readySwapRouter, readySwapHook);
    }

    function testEnvAddressWithFallbackUsesPrimaryWhenPresent() external {
        vm.setEnv("TEST_PRIMARY_LZ_ENDPOINT_REGISTRY", "0x0000000000000000000000000000000000001234");
        vm.setEnv("TEST_FALLBACK_MEMEVERSE_COMMON_INFO", "0x0000000000000000000000000000000000005678");

        address resolved = scriptHarness.envAddressWithFallbackHarness(
            "TEST_PRIMARY_LZ_ENDPOINT_REGISTRY", "TEST_FALLBACK_MEMEVERSE_COMMON_INFO"
        );

        assertEq(resolved, address(0x1234));
    }

    function testEnvAddressWithFallbackUsesFallbackWhenPrimaryMissing() external {
        vm.setEnv("TEST_ONLY_FALLBACK_MEMEVERSE_COMMON_INFO", "0x0000000000000000000000000000000000009ABC");

        address resolved = scriptHarness.envAddressWithFallbackHarness(
            "TEST_MISSING_PRIMARY_LZ_ENDPOINT_REGISTRY", "TEST_ONLY_FALLBACK_MEMEVERSE_COMMON_INFO"
        );

        assertEq(resolved, address(0x9ABC));
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
        polend.setDependencies(launcherAddress, address(splitter));
        splitter.setDependencies(launcherAddress, address(polend));
        // readiness checks POLend.creditFactory() points at a contract with code
        // (POLEND_CREDIT_FACTORY_NOT_READY); wire a coded address so the check passes.
        address creditFactoryAddr = address(uint160(0x6001));
        vm.etch(creditFactoryAddr, type(MockReadinessHook).creationCode);
        polend.setCreditFactory(creditFactoryAddr);
        polend.setReserve(UETH, 1);
        polend.setReserve(UUSD, 1);
        launcher.setFundMetaData(UETH, 1, 1);
        launcher.setFundMetaData(UUSD, 1, 1);

        address poolManager = address(uint160(0x4631));
        MockReadinessRouter router = new MockReadinessRouter(
            address(0), address(new MemeverseUniswapHookLens(IPoolManager(poolManager))), poolManager
        );
        MockReadinessHook hookImpl = new MockReadinessHook();
        readySwapHook = address(uint160(0x28cc));
        vm.etch(readySwapHook, address(hookImpl).code);
        vm.mockCall(readySwapHook, abi.encodeWithSignature("launcher()"), abi.encode(launcherAddress));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("poolInitializer()"), abi.encode(address(router)));

        MockReadinessEngine engine = new MockReadinessEngine();
        vm.mockCall(readySwapHook, abi.encodeWithSignature("dynamicFeeEngine()"), abi.encode(address(engine)));
        vm.mockCall(readySwapHook, abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));
        vm.mockCall(address(engine), abi.encodeWithSignature("authorizedHook()"), abi.encode(readySwapHook));
        vm.mockCall(address(engine), abi.encodeWithSignature("owner()"), abi.encode(readySwapHook));
        vm.mockCall(address(engine), abi.encodeWithSignature("poolManager()"), abi.encode(poolManager));

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
