// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {OutrunOwnable} from "../../src/common/access/OutrunOwnable.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";

contract MockPreorderSettlementHookConfig {
    address internal boundLauncher;
    address internal initializer;

    constructor(address boundLauncher_) {
        boundLauncher = boundLauncher_;
    }

    /// @notice Returns the configured launcher binding.
    /// @dev Mirrors the real hook accessor for launcher validation.
    /// @return launcher_ Configured launcher binding.
    function launcher() external view returns (address launcher_) {
        return boundLauncher;
    }

    function poolInitializer() external view returns (address initializer_) {
        return initializer;
    }

    /// @notice Updates the launcher binding used by the mock hook.
    /// @dev Allows tests to require explicit hook-to-launcher binding.
    /// @param boundLauncher_ New launcher stored by the mock.
    function setLauncher(address boundLauncher_) external {
        boundLauncher = boundLauncher_;
    }

    function setPoolInitializer(address initializer_) external {
        initializer = initializer_;
    }
}

contract MockPreorderSettlementRouterConfig {
    address internal hookAddress;

    constructor(address hookAddress_) {
        hookAddress = hookAddress_;
    }

    /// @notice Returns the configured hook address.
    /// @dev Lets tests simulate the hook pointer the router expects.
    /// @return hookAddress_ Configured hook address.
    function hook() external view returns (address) {
        return hookAddress;
    }
}

contract MemeverseLauncherConfigTest is Test {
    address internal constant OTHER = address(0xBEEF);
    uint256 internal constant MAX_SUPPORTED_FUND_BASED_AMOUNT = (1 << 64) - 1;
    MemeverseLauncherUpgradeable internal launcher;

    function _launcherInitData(address initialOwner, uint256 rewardRate) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
            initialOwner,
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4),
            address(0x5),
            address(0x10),
            address(0x11),
            rewardRate,
            115_000,
            135_000,
            2_500,
            7 days
        );
    }

    function _initializeLauncher(MemeverseLauncherUpgradeable target, address initialOwner, uint256 rewardRate)
        internal
    {
        target.initialize(
            initialOwner,
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4),
            address(0x5),
            address(0x10),
            address(0x11),
            rewardRate,
            115_000,
            135_000,
            2_500,
            7 days
        );
    }

    function _deployProxyLauncher(address initialOwner) internal returns (MemeverseLauncherUpgradeable) {
        MemeverseLauncherUpgradeable implementation = new MemeverseLauncherUpgradeable();
        return MemeverseLauncherUpgradeable(
            address(new ERC1967Proxy(address(implementation), _launcherInitData(initialOwner, 25)))
        );
    }

    function _setMemeverseUniswapHook(address hookAddress) internal returns (bool ok, bytes memory data) {
        return address(launcher).call(abi.encodeWithSignature("setMemeverseUniswapHook(address)", hookAddress));
    }

    function _readMemeverseUniswapHook() internal view returns (address hookAddress) {
        return launcher.getLauncherContracts().memeverseUniswapHook;
    }

    /// @notice Set up.
    /// @dev Deploys the launcher with dummy dependencies for the configuration tests.
    function setUp() external {
        launcher = _deployProxyLauncher(address(this));
    }

    function testProxyInitializeStoresOwnerAndConfiguration() external view {
        assertEq(launcher.owner(), address(this));
        assertFalse(launcher.paused());
        IMemeverseLauncher.LauncherContracts memory contracts = launcher.getLauncherContracts();
        assertEq(contracts.localLzEndpoint, address(0x1));
        assertEq(contracts.memeverseRegistrar, address(0x2));
        assertEq(contracts.memeverseProxyDeployer, address(0x3));
        assertEq(contracts.yieldDispatcher, address(0x4));
        assertEq(contracts.lzEndpointRegistry, address(0x5));
        assertEq(contracts.polSplitter, address(0x11));
        assertEq(launcher.polend(), address(0x10));
        IMemeverseLauncher.LauncherParameters memory parameters = launcher.getLauncherParameters();
        assertEq(parameters.executorRewardRate, 25);
        assertEq(parameters.oftReceiveGasLimit, 115_000);
        assertEq(parameters.yieldDispatcherGasLimit, 135_000);
        assertEq(parameters.preorderCapRatio, 2_500);
        assertEq(parameters.preorderVestingDuration, 7 days);
    }

    function testImplementationInitializeIsDisabled() external {
        MemeverseLauncherUpgradeable implementation = new MemeverseLauncherUpgradeable();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initializeLauncher(implementation, address(this), 25);
    }

    function testProxyInitializeRevertsSecondTime() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _initializeLauncher(launcher, address(this), 25);
    }

    function testInitializeRevertsWhenExecutorRewardRateEqualsRatio() external {
        MemeverseLauncherUpgradeable implementation = new MemeverseLauncherUpgradeable();
        vm.expectRevert(IMemeverseLauncher.FeeRateOverFlow.selector);
        new ERC1967Proxy(address(implementation), _launcherInitData(address(this), 10_000));
    }

    // ----------------------------------------------------------------
    // initialize: zero-value parameter revert tests
    // ----------------------------------------------------------------

    /// @notice Builds init data with one address parameter zeroed out by index.
    /// @dev Index 0 = initialOwner, 1 = localLzEndpoint_, ..., 7 = polSplitter_.
    /// @param zeroIndex Which address parameter to set to address(0).
    /// @return ABI-encoded initialize calldata.
    function _launcherInitDataWithZeroAddr(uint256 zeroIndex) internal pure returns (bytes memory) {
        address[8] memory addrs = [
            address(0xA1), // initialOwner
            address(0x1), // localLzEndpoint_
            address(0x2), // memeverseRegistrar_
            address(0x3), // memeverseProxyDeployer_
            address(0x4), // yieldDispatcher_
            address(0x5), // lzEndpointRegistry_
            address(0x10), // polend_
            address(0x11) // polSplitter_
        ];
        addrs[zeroIndex] = address(0);
        return abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
            addrs[0],
            addrs[1],
            addrs[2],
            addrs[3],
            addrs[4],
            addrs[5],
            addrs[6],
            addrs[7],
            25,
            115_000,
            135_000,
            2_500,
            7 days
        );
    }

    /// @notice Verifies initialize reverts for each zero-valued address parameter.
    /// @dev Each address is zeroed individually; index 0 (initialOwner) triggers OwnableInvalidOwner
    ///      before ZeroInput because ownership initialization runs first.
    function testInitializeRevertsZeroAddressParams() external {
        // index 0: initialOwner -> ownership initialization reverts first
        {
            MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
            vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableInvalidOwner.selector, address(0)));
            new ERC1967Proxy(address(impl), _launcherInitDataWithZeroAddr(0));
        }

        // indices 1-7: other address params → ZeroInput
        for (uint256 i = 1; i < 8; i++) {
            MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
            vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
            new ERC1967Proxy(address(impl), _launcherInitDataWithZeroAddr(i));
        }
    }

    /// @notice Verifies initialize reverts ZeroInput when gas limits are zero.
    function testInitializeRevertsZeroGasLimits() external {
        MemeverseLauncherUpgradeable impl1 = new MemeverseLauncherUpgradeable();
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        new ERC1967Proxy(
            address(impl1),
            abi.encodeWithSignature(
                "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
                address(0xA1),
                address(0x1),
                address(0x2),
                address(0x3),
                address(0x4),
                address(0x5),
                address(0x10),
                address(0x11),
                25,
                uint128(0),
                135_000,
                2_500,
                7 days
            )
        );

        MemeverseLauncherUpgradeable impl2 = new MemeverseLauncherUpgradeable();
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeWithSignature(
                "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
                address(0xA1),
                address(0x1),
                address(0x2),
                address(0x3),
                address(0x4),
                address(0x5),
                address(0x10),
                address(0x11),
                25,
                115_000,
                uint128(0),
                2_500,
                7 days
            )
        );
    }

    /// @notice Verifies initialize reverts ZeroInput when preorder params are zero.
    function testInitializeRevertsZeroPreorderParams() external {
        MemeverseLauncherUpgradeable impl1 = new MemeverseLauncherUpgradeable();
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        new ERC1967Proxy(
            address(impl1),
            abi.encodeWithSignature(
                "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
                address(0xA1),
                address(0x1),
                address(0x2),
                address(0x3),
                address(0x4),
                address(0x5),
                address(0x10),
                address(0x11),
                25,
                115_000,
                135_000,
                0,
                7 days
            )
        );

        MemeverseLauncherUpgradeable impl2 = new MemeverseLauncherUpgradeable();
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeWithSignature(
                "initialize(address,address,address,address,address,address,address,address,uint256,uint128,uint128,uint256,uint256)",
                address(0xA1),
                address(0x1),
                address(0x2),
                address(0x3),
                address(0x4),
                address(0x5),
                address(0x10),
                address(0x11),
                25,
                115_000,
                135_000,
                2_500,
                0
            )
        );
    }

    function testOwnerCanUpgradeAndNonOwnerCannot() external {
        MemeverseLauncherUpgradeable newImplementation = new MemeverseLauncherUpgradeable();

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, OTHER));
        launcher.upgradeToAndCall(address(newImplementation), "");

        launcher.upgradeToAndCall(address(newImplementation), "");
    }

    /// @notice Re-initialization through upgradeToAndCall must revert.
    /// @dev The initializer modifier checks _initialized in proxy storage, which is already 1.
    function testUpgradeToAndCall_RevertsWhenCallingInitialize() external {
        MemeverseLauncherUpgradeable newImplementation = new MemeverseLauncherUpgradeable();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        launcher.upgradeToAndCall(address(newImplementation), _launcherInitData(address(this), 25));
    }

    /// @notice Direct upgradeToAndCall on implementation must revert (onlyProxy guard).
    /// @dev UUPSUpgradeable._checkProxy() rejects calls where address(this) == __self.
    function testImplementationUpgradeToAndCallIsDisabled() external {
        MemeverseLauncherUpgradeable implementation = new MemeverseLauncherUpgradeable();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(0), "");
    }

    function testConfigSetterRevertsForNonOwner() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, OTHER));
        launcher.setLzEndpointRegistry(address(0xBEEF));
    }

    /// @notice Verifies onlyOwner enforcement on config setters works through the proxy.
    function testSetExecutorRewardRate_RevertsWhenNotOwner() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, OTHER));
        launcher.setExecutorRewardRate(500);
    }

    /// @notice Test proxiableUUID returns the expected ERC-1967 value.
    /// @dev proxiableUUID uses the notDelegated modifier (reverts via proxy),
    /// so we call it directly on the implementation.
    function testProxiableUUID_ReturnsExpectedValue() external {
        bytes32 expectedUUID = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        MemeverseLauncherUpgradeable implementation = new MemeverseLauncherUpgradeable();
        assertEq(implementation.proxiableUUID(), expectedUUID);
    }

    /// @notice Test pause and unpause are owner only.
    /// @dev Verifies only the owner can toggle the paused state.
    function testPauseAndUnpauseAreOwnerOnly() external {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, OTHER));
        launcher.pause();

        launcher.pause();
        assertTrue(launcher.paused());

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OutrunOwnable.OwnableUnauthorizedAccount.selector, OTHER));
        launcher.unpause();

        launcher.unpause();
        assertFalse(launcher.paused());
    }

    /// @notice Test swap infra config requires a bound hook and a matching router->hook edge.
    /// @dev The launcher should reject either side of the double binding when the approved wiring is wrong.
    function testSetMemeverseSwapInfra_RequiresMatchingHookAndRouterBindings() external {
        MockPreorderSettlementHookConfig invalidLauncherHook = new MockPreorderSettlementHookConfig(OTHER);
        (bool invalidHookOk, bytes memory invalidHookData) = _setMemeverseUniswapHook(address(invalidLauncherHook));
        assertFalse(invalidHookOk, "hook with wrong launcher should fail");
        assertEq(bytes4(invalidHookData), IMemeverseLauncher.InvalidPreorderSettlementConfig.selector, "hook revert");

        MockPreorderSettlementHookConfig configuredHook = new MockPreorderSettlementHookConfig(address(launcher));
        (bool setHookOk, bytes memory setHookData) = _setMemeverseUniswapHook(address(configuredHook));
        assertTrue(setHookOk, string(setHookData));

        MockPreorderSettlementHookConfig mismatchedRouterHook = new MockPreorderSettlementHookConfig(address(launcher));
        MockPreorderSettlementRouterConfig mismatchedRouter =
            new MockPreorderSettlementRouterConfig(address(mismatchedRouterHook));

        vm.expectRevert(IMemeverseLauncher.InvalidPreorderSettlementConfig.selector);
        launcher.setMemeverseSwapRouter(address(mismatchedRouter));

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setMemeverseSwapRouter(address(0));

        MockPreorderSettlementRouterConfig settledRouter =
            new MockPreorderSettlementRouterConfig(address(configuredHook));
        configuredHook.setPoolInitializer(address(settledRouter));
        launcher.setMemeverseSwapRouter(address(settledRouter));
        assertEq(launcher.getLauncherContracts().memeverseSwapRouter, address(settledRouter));

        address storedHook = _readMemeverseUniswapHook();
        assertEq(storedHook, address(configuredHook));
    }

    function testSetMemeverseSwapRouter_RevertsWhenHookPoolInitializerDiffers() external {
        MockPreorderSettlementHookConfig configuredHook = new MockPreorderSettlementHookConfig(address(launcher));
        (bool setHookOk, bytes memory setHookData) = _setMemeverseUniswapHook(address(configuredHook));
        assertTrue(setHookOk, string(setHookData));

        MockPreorderSettlementRouterConfig router = new MockPreorderSettlementRouterConfig(address(configuredHook));

        vm.expectRevert(IMemeverseLauncher.InvalidPreorderSettlementConfig.selector);
        launcher.setMemeverseSwapRouter(address(router));

        assertEq(launcher.getLauncherContracts().memeverseSwapRouter, address(0));
    }

    /// @notice Verifies swap infra can be configured in router-then-hook order when the bindings eventually match.
    /// @dev This keeps admin configuration order-independent while preserving the final double-binding checks.
    function testSetMemeverseSwapInfra_AllowsRouterBeforeHookWhenBindingsMatch() external {
        MockPreorderSettlementHookConfig configuredHook = new MockPreorderSettlementHookConfig(address(launcher));
        MockPreorderSettlementRouterConfig router = new MockPreorderSettlementRouterConfig(address(configuredHook));

        launcher.setMemeverseSwapRouter(address(router));
        assertEq(
            launcher.getLauncherContracts().memeverseSwapRouter, address(router), "router should store before hook"
        );

        configuredHook.setPoolInitializer(address(router));
        launcher.setMemeverseUniswapHook(address(configuredHook));

        address storedHook = _readMemeverseUniswapHook();
        assertEq(storedHook, address(configuredHook));
    }

    /// @notice Verifies the launcher hook binding is write-once while routers may rebind after hook initializer sync.
    /// @dev This prevents unlock protection from drifting to a different hook namespace after pools already exist.
    function testSetMemeverseSwapInfra_HookIsWriteOnceButRouterCanRebindToSameHook() external {
        MockPreorderSettlementHookConfig configuredHook = new MockPreorderSettlementHookConfig(address(launcher));
        (bool firstSetOk, bytes memory firstSetData) = _setMemeverseUniswapHook(address(configuredHook));
        assertTrue(firstSetOk, string(firstSetData));

        MockPreorderSettlementRouterConfig firstRouter = new MockPreorderSettlementRouterConfig(address(configuredHook));
        MockPreorderSettlementRouterConfig secondRouter =
            new MockPreorderSettlementRouterConfig(address(configuredHook));

        configuredHook.setPoolInitializer(address(firstRouter));
        launcher.setMemeverseSwapRouter(address(firstRouter));
        configuredHook.setPoolInitializer(address(secondRouter));
        launcher.setMemeverseSwapRouter(address(secondRouter));
        assertEq(launcher.getLauncherContracts().memeverseSwapRouter, address(secondRouter), "router should rebind");

        vm.expectRevert();
        launcher.setMemeverseUniswapHook(address(configuredHook));
    }

    /// @notice Test set lz endpoint registry stores address and rejects zero.
    /// @dev Asserts the registry setter complains about zero addresses.
    function testSetLzEndpointRegistryStoresAddressAndRejectsZero() external {
        launcher.setLzEndpointRegistry(address(0xBEEF));
        assertEq(launcher.getLauncherContracts().lzEndpointRegistry, address(0xBEEF));

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setLzEndpointRegistry(address(0));
    }

    /// @notice Test set memeverse registrar stores address and rejects zero.
    /// @dev Ensures the registrar setter rejects zero and persists valid values.
    function testSetMemeverseRegistrarStoresAddressAndRejectsZero() external {
        launcher.setMemeverseRegistrar(address(0xBEEF));
        assertEq(launcher.getLauncherContracts().memeverseRegistrar, address(0xBEEF));

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setMemeverseRegistrar(address(0));
    }

    /// @notice Test set memeverse proxy deployer stores address and rejects zero.
    /// @dev Checks the proxy deployer setter enforces non-zero input.
    function testSetMemeverseProxyDeployerStoresAddressAndRejectsZero() external {
        launcher.setMemeverseProxyDeployer(address(0xBEEF));
        assertEq(launcher.getLauncherContracts().memeverseProxyDeployer, address(0xBEEF));

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setMemeverseProxyDeployer(address(0));
    }

    /// @notice Test set oftdispatcher stores address and rejects zero.
    /// @dev Guards the OFT dispatcher setter against zero inputs.
    function testSetYieldDispatcherStoresAddressAndRejectsZero() external {
        launcher.setYieldDispatcher(address(0xBEEF));
        assertEq(launcher.getLauncherContracts().yieldDispatcher, address(0xBEEF));

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setYieldDispatcher(address(0));
    }

    /// @notice Test set launch impl rejects zero.
    /// @dev Guards the launch sibling setter against zero inputs; `launchImpl` has no getter, so only
    ///      the zero-address revert is asserted here (happy-path delegatecall runs in BootstrapLiquidity.t.sol).
    function testSetLaunchImplRejectsZero() external {
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setLaunchImpl(address(0));
    }

    /// @notice Test set fund meta data stores values and guards inputs.
    /// @dev Verifies the metadata setter stores limits and rejects invalid caps.
    function testSetFundMetaDataStoresValuesAndGuardsInputs() external {
        launcher.setFundMetaData(address(0xBEEF), 1 ether, 2 ether);
        (uint256 minTotalFund, uint256 fundBasedAmount) = launcher.fundMetaDatas(address(0xBEEF));
        assertEq(minTotalFund, 1 ether);
        assertEq(fundBasedAmount, 2 ether);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setFundMetaData(address(0xBEEF), 0, 1);

        uint256 tooHigh = uint256(1 << 64);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseLauncher.FundBasedAmountTooHigh.selector, tooHigh, uint256((1 << 64) - 1))
        );
        launcher.setFundMetaData(address(0xBEEF), 1 ether, tooHigh);
    }

    /// @notice Test fund metadata allows large minTotalFund values while still capping fundBasedAmount.
    function testSetFundMetaData_AllowsMinTotalFundAboveFundBasedAmountCap() external {
        uint256 largeMinTotalFund = MAX_SUPPORTED_FUND_BASED_AMOUNT + 1;

        launcher.setFundMetaData(address(0xBEEF), largeMinTotalFund, 1);

        (uint256 minTotalFund, uint256 fundBasedAmount) = launcher.fundMetaDatas(address(0xBEEF));
        assertEq(minTotalFund, largeMinTotalFund);
        assertEq(fundBasedAmount, 1);
    }

    /// @notice Derived virtual buffer V = minTotalFund * fundBasedAmount * 7 / 1000 must be > 0.
    /// @dev Boundary: 142*7=994 -> 0 (rejected); 143*7=1001 -> 1 (accepted). Guards against a config
    ///      that makes MemecoinYieldVault.initialize revert ZeroVirtualAssets() and DoS governance deploy.
    function testSetFundMetaData_RevertsWhenVirtualAssetsRoundsToZero() external {
        // Just below boundary: 142 * 1 * 7 = 994, floor /1000 = 0 -> revert.
        vm.expectRevert(IMemeverseLauncher.VirtualAssetsTooLow.selector);
        launcher.setFundMetaData(address(0xBEEF), 142, 1);

        // Just above boundary: 143 * 1 * 7 = 1001, floor /1000 = 1 > 0 -> stored.
        launcher.setFundMetaData(address(0xBEEF), 143, 1);
        (uint256 minTotalFund, uint256 fundBasedAmount) = launcher.fundMetaDatas(address(0xBEEF));
        assertEq(minTotalFund, 143);
        assertEq(fundBasedAmount, 1);
    }

    /// @notice Test set executor reward rate stores value and rejects overflow.
    /// @dev Asserts the fee rate setter guards against overflow values.
    function testSetExecutorRewardRateStoresValueAndRejectsOverflow() external {
        launcher.setExecutorRewardRate(9999);
        assertEq(launcher.getLauncherParameters().executorRewardRate, 9999);

        vm.expectRevert(IMemeverseLauncher.FeeRateOverFlow.selector);
        launcher.setExecutorRewardRate(10_000);
    }

    /// @notice Test set preorder config stores values and rejects zero.
    /// @dev Confirms the preorder setter enforces non-zero caps and valid ranges.
    function testSetPreorderConfigStoresValuesAndRejectsZero() external {
        launcher.setPreorderConfig(2_000, 14 days);
        assertEq(launcher.getLauncherParameters().preorderCapRatio, 2_000);
        assertEq(launcher.getLauncherParameters().preorderVestingDuration, 14 days);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setPreorderConfig(0, 14 days);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setPreorderConfig(2_000, 0);

        vm.expectRevert(IMemeverseLauncher.FeeRateOverFlow.selector);
        launcher.setPreorderConfig(10_001, 14 days);
    }

    /// @notice Test set gas limits stores values and rejects zero.
    /// @dev Makes sure each gas-limit setter requires a non-zero throttle.
    function testSetGasLimitsStoresValuesAndRejectsZero() external {
        launcher.setGasLimits(1, 2);
        assertEq(launcher.getLauncherParameters().oftReceiveGasLimit, 1);
        assertEq(launcher.getLauncherParameters().yieldDispatcherGasLimit, 2);

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.setGasLimits(0, 1);
    }

    /// @notice Test remove gas dust transfers balance to receiver.
    /// @dev Verifies the owner-only dust sweep actually sends the native balance.
    function testRemoveGasDustTransfersBalanceToReceiver() external {
        vm.deal(address(launcher), 1 ether);
        uint256 before = address(this).balance;

        launcher.removeGasDust(address(this));

        assertEq(address(this).balance, before + 1 ether);
        assertEq(address(launcher).balance, 0);
    }

    /// @notice Accepts native value when config tests inadvertently send ETH.
    /// @dev Provides a payable fallback so the test contract can hold refunds.
    receive() external payable {}
}
