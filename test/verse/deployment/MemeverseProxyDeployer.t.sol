// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MemeverseProxyDeployer} from "../../../src/verse/deployment/MemeverseProxyDeployer.sol";
import {IMemeverseProxyDeployer} from "../../../src/verse/interfaces/IMemeverseProxyDeployer.sol";

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

    /// @notice Regression: setter rejects min quorum numerator above 100.
    ///         A value >100 is a percent of total supply and makes governance quorum permanently
    ///         unreachable, so both the upper boundary (100) and lower boundary (1) must pass
    ///         while anything above the cap reverts with `InvalidMinQuorumNumerator`.
    function testSetMinQuorumNumeratorRejectsAboveUpperBound() external {
        vm.prank(OWNER);
        vm.expectRevert(MemeverseProxyDeployer.InvalidMinQuorumNumerator.selector);
        deployer.setMinQuorumNumerator(101);

        vm.prank(OWNER);
        deployer.setMinQuorumNumerator(100);
        assertEq(deployer.minQuorumNumerator(), 100);

        vm.prank(OWNER);
        deployer.setMinQuorumNumerator(1);
        assertEq(deployer.minQuorumNumerator(), 1);
    }

    /// @notice Regression: constructor enforces the same >0 && <=100 range as the setter.
    function testConstructorRejectsMinQuorumNumeratorAboveUpperBound() external {
        vm.expectRevert(MemeverseProxyDeployer.InvalidMinQuorumNumerator.selector);
        new MemeverseProxyDeployer(
            OWNER,
            LAUNCHER,
            address(memecoinImplementation),
            address(polImplementation),
            address(vaultImplementation),
            address(governorImplementation),
            address(incentivizerImplementation),
            25, // _quorumNumerator
            101, // _minQuorumNumerator (above the 100 cap)
            7 days,
            1000,
            6000
        );
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

    /// @notice Test renounceOwnership is permanently disabled (never-renounceable repo invariant).
    function testRenounceOwnershipIsDisabled() external {
        vm.prank(OWNER);
        vm.expectRevert(MemeverseProxyDeployer.OwnershipRenounceDisabled.selector);
        deployer.renounceOwnership();
    }
}
