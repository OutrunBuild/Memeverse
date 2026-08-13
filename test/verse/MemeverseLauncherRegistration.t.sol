// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

import {MemeverseLauncherTestHelper} from "../mocks/verse/MemeverseLauncherTestHelper.sol";
import {MemeverseLauncherUpgradeable} from "../../src/verse/MemeverseLauncherUpgradeable.sol";
import {MemeverseLaunchImpl} from "../../src/verse/MemeverseLaunchImpl.sol";
import {IMemeverseLauncher} from "../../src/verse/interfaces/IMemeverseLauncher.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockLauncherRegistrationToken {
    string public name;
    string public symbol;
    address public memeverseLauncher;
    address public memecoin;
    address public delegate;
    mapping(uint32 eid => bytes32 peer) public peers;

    /// @notice Initialize.
    /// @dev Records the provided launcher and delegate addresses for registration assertions.
    /// @param name_ See implementation.
    /// @param symbol_ See implementation.
    /// @param launcher_ See implementation.
    /// @param delegate_ See implementation.
    function initialize(string memory name_, string memory symbol_, address launcher_, address delegate_) external {
        name = name_;
        symbol = symbol_;
        memeverseLauncher = launcher_;
        delegate = delegate_;
    }

    /// @notice Initialize.
    /// @dev Records memecoin references needed when registration creates linked tokens.
    /// @param name_ See implementation.
    /// @param symbol_ See implementation.
    /// @param memecoin_ See implementation.
    /// @param launcher_ See implementation.
    /// @param delegate_ See implementation.
    function initialize(
        string memory name_,
        string memory symbol_,
        address memecoin_,
        address launcher_,
        address delegate_
    ) external {
        name = name_;
        symbol = symbol_;
        memecoin = memecoin_;
        memeverseLauncher = launcher_;
        delegate = delegate_;
    }

    /// @notice Set peer.
    /// @dev Stores the remote peer reference that the launcher should read back later.
    /// @param eid See implementation.
    /// @param peer See implementation.
    function setPeer(uint32 eid, bytes32 peer) external {
        peers[eid] = peer;
    }
}

contract MockGovernorForExternalInfo {}

contract MockLauncherRegistrationProxyDeployer {
    address public nextMemecoin;
    address public nextPol;
    uint256 public deployMemecoinCount;
    uint256 public deployPOLCount;

    /// @notice Set next deployments.
    /// @dev Configures the mock deployer to return predetermined addresses.
    /// @param memecoin_ See implementation.
    /// @param pol_ See implementation.
    function setNextDeployments(address memecoin_, address pol_) external {
        nextMemecoin = memecoin_;
        nextPol = pol_;
    }

    /// @notice Deploy memecoin.
    /// @dev Always returns the configured mock memecoin address to keep tests deterministic.
    /// @param uniqueId See implementation.
    /// @return memecoin See implementation.
    function deployMemecoin(uint256 uniqueId) external returns (address memecoin) {
        uniqueId;
        deployMemecoinCount++;
        return nextMemecoin;
    }

    /// @notice Deploy pol.
    /// @dev Mirrors deployment without actually creating new contracts.
    /// @param uniqueId See implementation.
    /// @return pol See implementation.
    function deployPOL(uint256 uniqueId) external returns (address pol) {
        uniqueId;
        deployPOLCount++;
        return nextPol;
    }
}

contract MockLauncherRegistrationRegistry {
    mapping(uint32 chainId => uint32 endpointId) public lzEndpointIdOfChain;

    /// @notice Set endpoint.
    /// @dev Mimics the registry setter so tests can map chain ids to endpoint ids.
    /// @param chainId See implementation.
    /// @param endpointId See implementation.
    function setEndpoint(uint32 chainId, uint32 endpointId) external {
        lzEndpointIdOfChain[chainId] = endpointId;
    }
}

contract MockLauncherRegistrationPOLend {
    uint256 public lastVerseId;
    uint256 public registerCount;

    function registerLendMarket(uint256 verseId) external {
        lastVerseId = verseId;
        registerCount++;
    }
}

contract MemeverseLauncherRegistrationTest is Test, MemeverseLauncherTestHelper {
    address internal constant OWNER = address(0xABCD);
    address internal constant REGISTRAR = address(0xBEEF);
    uint32 internal constant REMOTE_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;

    IMemeverseLauncher internal launcher;
    address internal launcherProxy;
    MockLauncherRegistrationProxyDeployer internal proxyDeployer;
    MockLauncherRegistrationRegistry internal registry;
    MockLauncherRegistrationPOLend internal polend;
    MockLauncherRegistrationToken internal memecoin;
    MockLauncherRegistrationToken internal pol;

    /// @notice Set up.
    /// @dev Deploys the registration launcher test harness and wires necessary mocks.
    function setUp() external {
        proxyDeployer = new MockLauncherRegistrationProxyDeployer();
        registry = new MockLauncherRegistrationRegistry();
        polend = new MockLauncherRegistrationPOLend();
        memecoin = new MockLauncherRegistrationToken();
        pol = new MockLauncherRegistrationToken();
        MemeverseLauncherUpgradeable impl = new MemeverseLauncherUpgradeable();
        launcherProxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    MemeverseLauncherUpgradeable.initialize,
                    (
                        OWNER,
                        address(0x1),
                        REGISTRAR,
                        address(0x3),
                        address(0x4),
                        address(0x5),
                        address(polend),
                        address(0x1234),
                        25,
                        115_000,
                        135_000,
                        2_500,
                        7 days
                    )
                )
            )
        );
        launcher = IMemeverseLauncher(launcherProxy);

        proxyDeployer.setNextDeployments(address(memecoin), address(pol));

        vm.startPrank(OWNER);
        launcher.setMemeverseProxyDeployer(address(proxyDeployer));
        launcher.setLzEndpointRegistry(address(registry));
        launcher.setFundMetaData(address(0x7777), 10 ether, 1);
        // Phase 3B: registerMemeverse delegatecalls the launch sibling; bind it before tests call it.
        launcher.setLaunchImpl(address(new MemeverseLaunchImpl()));
        vm.stopPrank();
    }

    /// @notice Test register memeverse only registrar.
    /// @dev Ensures only the registrar role can call `registerMemeverse`.
    function testRegisterMemeverseOnlyRegistrar() external {
        vm.expectRevert(IMemeverseLauncher.PermissionDenied.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            1,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _omnichainIds(),
            address(0x7777),
            true
        );
    }

    function testRegisterMemeverse_RevertsOnInvalidInputsBeforeTokenDeployment() external {
        uint32[] memory emptyOmnichainIds = new uint32[](0);

        vm.startPrank(REGISTRAR);
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            20,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _localOmnichainIds(),
            address(0),
            true
        );

        vm.expectRevert(IMemeverseLauncher.InvalidLength.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            21,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            emptyOmnichainIds,
            address(0x7777),
            true
        );

        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            22,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _localOmnichainIds(),
            address(0x8888),
            true
        );
        vm.stopPrank();

        setFundMetaDataForTest(launcherProxy, address(0x9999), 0, 1);
        vm.prank(REGISTRAR);
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            23,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _localOmnichainIds(),
            address(0x9999),
            true
        );

        setFundMetaDataForTest(launcherProxy, address(0xAAAA), 10 ether, 0);
        vm.prank(REGISTRAR);
        vm.expectRevert(IMemeverseLauncher.ZeroInput.selector);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            24,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _localOmnichainIds(),
            address(0xAAAA),
            true
        );

        assertEq(proxyDeployer.deployMemecoinCount(), 0, "memecoin deployment skipped");
        assertEq(proxyDeployer.deployPOLCount(), 0, "pol deployment skipped");
    }

    /// @notice Test register memeverse reverts on invalid remote omnichain id.
    /// @dev Guards against registering remote peers that are not mapped in the registry.
    function testRegisterMemeverseRevertsOnInvalidRemoteOmnichainId() external {
        uint32[] memory omnichainIds = _omnichainIds();

        vm.prank(REGISTRAR);
        vm.expectRevert(abi.encodeWithSelector(IMemeverseLauncher.InvalidOmnichainId.selector, REMOTE_CHAIN_ID));
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            1,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            omnichainIds,
            address(0x7777),
            true
        );
    }

    /// @notice Test register memeverse stores verse and configures remote peers.
    /// @dev Verifies the registrar populates verse metadata and sets up peer references.
    function testRegisterMemeverseStoresVerseAndConfiguresRemotePeers() external {
        registry.setEndpoint(REMOTE_CHAIN_ID, REMOTE_EID);
        uint256 uniqueId = 7;
        uint32[] memory omnichainIds = _omnichainIds();

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            uniqueId,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            omnichainIds,
            address(0x7777),
            true
        );

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(uniqueId);
        assertEq(verse.name, "Memeverse");
        assertEq(verse.symbol, "MEME");
        assertEq(verse.uAsset, address(0x7777));
        assertEq(verse.memecoin, address(memecoin));
        assertEq(verse.pol, address(pol));
        assertEq(launcher.getVerseIdByMemecoin(address(memecoin)), uniqueId);

        assertEq(memecoin.memeverseLauncher(), address(launcher));
        assertEq(pol.memecoin(), address(memecoin));
        assertEq(polend.lastVerseId(), uniqueId);
        assertEq(polend.registerCount(), 1);
        assertEq(memecoin.peers(REMOTE_EID), bytes32(uint256(uint160(address(memecoin)))));
        assertEq(pol.peers(REMOTE_EID), bytes32(uint256(uint160(address(pol)))));
        assertEq(memecoin.peers(uint32(block.chainid)), bytes32(0));
    }

    /// @notice Test register memeverse local only omnichain ids skip peer configuration.
    /// @dev Checks that local-only chains do not trigger remote peer writes.
    function testRegisterMemeverse_LocalOnlyOmnichainIdsSkipPeerConfiguration() external {
        uint256 uniqueId = 8;
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = uint32(block.chainid);

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            uniqueId,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            omnichainIds,
            address(0x7777),
            true
        );

        assertEq(memecoin.peers(uint32(block.chainid)), bytes32(0));
        assertEq(pol.peers(uint32(block.chainid)), bytes32(0));
    }

    /// @notice Test set external info requires registrar or governor and rejects oversized description.
    /// @dev Confirms the external info setter admits both registrar and governor and enforces length limits.
    function testSetExternalInfoRequiresRegistrarOrGovernorAndRejectsOversizedDescription() external {
        registry.setEndpoint(REMOTE_CHAIN_ID, REMOTE_EID);
        uint256 uniqueId = 9;

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            uniqueId,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _omnichainIds(),
            address(0x7777),
            true
        );

        vm.expectRevert(IMemeverseLauncher.PermissionDenied.selector);
        launcher.setExternalInfo(uniqueId, "ipfs://meme", "desc", _communities("https://site"));

        vm.prank(REGISTRAR);
        launcher.setExternalInfo(uniqueId, "ipfs://meme", "desc", _communities("https://site"));

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(uniqueId);
        assertEq(verse.uri, "ipfs://meme");
        assertEq(verse.desc, "desc");

        string memory oversized = string(new bytes(256));
        vm.prank(REGISTRAR);
        vm.expectRevert(IMemeverseLauncher.InvalidLength.selector);
        launcher.setExternalInfo(uniqueId, "", oversized, new string[](0));
    }

    /// @notice Test set external info governor path supports selective updates.
    /// @dev Ensures the governor can update the info fields incrementally without overwriting unchanged content.
    function testSetExternalInfoGovernorPathSupportsSelectiveUpdates() external {
        registry.setEndpoint(REMOTE_CHAIN_ID, REMOTE_EID);
        uint256 uniqueId = 10;

        vm.prank(REGISTRAR);
        launcher.registerMemeverse(
            "Memeverse",
            "MEME",
            uniqueId,
            uint128(block.timestamp + 1 days),
            uint128(block.timestamp + 2 days),
            _omnichainIds(),
            address(0x7777),
            true
        );

        IMemeverseLauncher.Memeverse memory verse = launcher.getMemeverseByVerseId(uniqueId);
        address newGovernor = address(new MockGovernorForExternalInfo());
        setMemeverseForTest(
            launcherProxy,
            uniqueId,
            verse.uAsset,
            verse.memecoin,
            verse.pol,
            verse.yieldVault,
            newGovernor,
            verse.incentivizer,
            verse.endTime,
            verse.unlockTime,
            verse.currentStage,
            verse.flashGenesis
        );

        vm.prank(newGovernor);
        launcher.setExternalInfo(uniqueId, "ipfs://first", "first", _communities("https://site-1"));

        vm.prank(newGovernor);
        launcher.setExternalInfo(uniqueId, "", "", new string[](0));

        IMemeverseLauncher.Memeverse memory stored = launcher.getMemeverseByVerseId(uniqueId);
        assertEq(stored.uri, "ipfs://first");
        assertEq(stored.desc, "first");
        assertEq(MemeverseLauncherUpgradeable(launcherProxy).communitiesMap(uniqueId, 0), "https://site-1");
    }

    /// @notice Returns the standard omnichain id array used by tests.
    /// @dev Includes both the local chain and a remote chain id fixture.
    function _omnichainIds() internal view returns (uint32[] memory ids) {
        ids = new uint32[](2);
        ids[0] = uint32(block.chainid);
        ids[1] = REMOTE_CHAIN_ID;
    }

    function _localOmnichainIds() internal view returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = uint32(block.chainid);
    }

    /// @notice Builds a single-entry communities array for tests.
    /// @dev Simplifies storing community links during registration scenarios.
    function _communities(string memory website) internal pure returns (string[] memory communities) {
        communities = new string[](1);
        communities[0] = website;
    }
}
