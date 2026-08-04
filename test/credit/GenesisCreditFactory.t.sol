// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {GenesisCreditFactory} from "../../src/credit/GenesisCreditFactory.sol";
import {IGenesisCreditFactory} from "../../src/credit/interfaces/IGenesisCreditFactory.sol";
import {GenesisCredit} from "../../src/credit/GenesisCredit.sol";

/// @notice Minimal LayerZero endpoint stand-in: supports `setDelegate` (OFTCore constructor) and
///         exposes `eid()` (auto-generated getter of the EndpointV2 `eid` immutable).
contract MockFactoryEndpoint {
    address public delegate;
    uint32 public immutable eid;

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }
}

/// @title GenesisCreditFactoryTest
/// @notice Verifies CREATE3-based deterministic deployment (factory self-inlined), registry, access
///         control, and that contracts produced by the factory are functional GenesisCredit instances.
contract GenesisCreditFactoryTest is Test {
    GenesisCreditFactory internal factory;

    // Test inputs reused across cases. Real 18-dec mock tokens so `deployCredit` can read
    // `IERC20Metadata(uAsset).decimals()` once the factory enforces the 18-dec constraint.
    MockERC20 internal uAsset;
    MockERC20 internal otherUAsset;
    address internal delegate = makeAddr("delegate");
    uint32 internal constant HOME_CHAIN_EID = 30_111;

    MockFactoryEndpoint internal endpoint;

    /// @dev Selector of OZ Ownable.OwnableUnauthorizedAccount(address), inherited by both the
    ///      factory (Ownable) and deployed credits (OFTCore -> OAppCore Ownable).
    bytes4 internal constant OwnableUnauthorizedAccountSelector = bytes4(0x118cdaa7);

    function setUp() public {
        endpoint = new MockFactoryEndpoint(HOME_CHAIN_EID);
        uAsset = new MockERC20("UASSET", "UASSET", 18);
        otherUAsset = new MockERC20("OTHER", "OTHER", 18);
        factory = new GenesisCreditFactory(address(endpoint), HOME_CHAIN_EID, address(this));
    }

    /// @notice deployCredit lands at predictCredit and registers the credit in creditOf; the plain
    ///         contract is constructed in-line with name/symbol/delegate wired through OFT.
    function test_DeployCredit_CreatesAtDeterministicAddress() public {
        address predicted = factory.predictCredit(address(uAsset));
        assertTrue(predicted != address(0), "predict must be non-zero before deploy");

        vm.expectEmit(true, true, false, true);
        emit IGenesisCreditFactory.CreditDeployed(address(uAsset), predicted);

        address deployed = factory.deployCredit(address(uAsset), "Credit", "CRT", delegate);

        // CREATE3 determinism: predicted address must equal the deployed address.
        assertEq(deployed, factory.predictCredit(address(uAsset)), "deployed must match predict");
        assertEq(factory.creditOf(address(uAsset)), deployed, "creditOf must record deployed address");
        assertTrue(deployed != address(0), "deployed must be non-zero");

        // Constructor args wired through OFT in-line; homeChainEid is immutable on the instance.
        GenesisCredit credit = GenesisCredit(deployed);
        assertEq(credit.name(), "Credit", "name");
        assertEq(credit.symbol(), "CRT", "symbol");
        assertEq(credit.owner(), delegate, "owner/delegate");
        assertEq(uint256(credit.homeChainEid()), uint256(HOME_CHAIN_EID), "homeChainEid");
        assertEq(uint256(credit.homeChainEid()), uint256(factory.homeChainEid()), "homeChainEid from factory");
    }

    /// @notice predictCredit is a pure function of (factory, uAsset) and never changes.
    function test_PredictCredit_StableAcrossCalls() public {
        address p1 = factory.predictCredit(address(uAsset));
        address p2 = factory.predictCredit(address(uAsset));
        address p3 = factory.predictCredit(address(otherUAsset));

        assertEq(p1, p2, "same uAsset must predict same address");
        assertTrue(p1 != p3, "different uAsset must predict different address");
        assertTrue(p1 != address(0), "predict must be non-zero");
    }

    /// @notice Re-deploying the same uAsset reverts with AlreadyDeployed.
    function test_RevertWhen_DeployCreditAlreadyDeployed() public {
        factory.deployCredit(address(uAsset), "Credit", "CRT", delegate);

        vm.expectRevert(IGenesisCreditFactory.AlreadyDeployed.selector);
        factory.deployCredit(address(uAsset), "Credit2", "CRT2", delegate);
    }

    /// @notice uAsset zero is rejected.
    function test_RevertWhen_DeployCreditZeroUAsset() public {
        vm.expectRevert(IGenesisCreditFactory.ZeroUAsset.selector);
        factory.deployCredit(address(0), "Credit", "CRT", delegate);
    }

    /// @notice GenesisCredit is fixed at 18 decimals, so credit-path raw-unit 1:1 accounting only
    ///         holds when the uAsset is also 18 decimals. A non-18-dec uAsset must be rejected at
    ///         deploy time with `InvalidUAssetDecimals(actual, expected=18)`.
    function test_RevertWhen_DeployCreditUAssetDecimalsNot18() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.expectRevert(
            abi.encodeWithSelector(IGenesisCreditFactory.InvalidUAssetDecimals.selector, uint8(6), uint8(18))
        );
        factory.deployCredit(address(usdc), "Credit", "CRT", delegate);
    }

    /// @notice A non-contract uAsset must fail metadata decoding before CREATE3 deployment.
    function test_RevertWhen_DeployCreditUAssetIsNotAContract() public {
        address nonContract = address(0x123456);
        assertEq(nonContract.code.length, 0);

        vm.expectRevert();
        factory.deployCredit(nonContract, "Credit", "CRT", delegate);

        assertEq(factory.creditOf(nonContract), address(0));
    }

    /// @notice A non-owner caller cannot deploy. OwnableUnauthorizedAccount is inherited from the
    ///         factory's own OZ Ownable.
    function test_RevertWhen_DeployCreditByNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodePacked(OwnableUnauthorizedAccountSelector, abi.encode(attacker)));
        factory.deployCredit(address(uAsset), "Credit", "CRT", delegate);
    }

    /// @notice Constructing the factory with a zero-address endpoint reverts.
    function test_RevertWhen_ConstructWithZeroEndpoint() public {
        vm.expectRevert(IGenesisCreditFactory.ZeroAddress.selector);
        new GenesisCreditFactory(address(0), HOME_CHAIN_EID, address(this));
    }

    /// @notice A credit produced by the factory behaves like a standalone GenesisCredit: setMerkleRoot,
    ///         claim, and burn all work, and two siblings deployed for different uAssets maintain
    ///         independent storage (proving the CREATE3 instances are isolated full contracts).
    function test_DeployedCredit_IsFunctional() public {
        address deployed = factory.deployCredit(address(uAsset), "Credit", "CRT", delegate);
        GenesisCredit credit = GenesisCredit(deployed);

        // Single-leaf merkle tree: root = double-hashed leaf.
        address alice = makeAddr("alice");
        uint256 allocation = 100 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, allocation))));
        bytes32 root = leaf;

        vm.prank(delegate);
        credit.setMerkleRoot(root);

        // Claim mints to alice.
        vm.prank(alice);
        bytes32[] memory proof = new bytes32[](0);
        credit.claim(allocation, proof);

        assertEq(credit.balanceOf(alice), allocation, "alice balance after claim");

        // Burn reduces the caller's balance.
        vm.prank(alice);
        credit.burn(allocation);

        assertEq(credit.balanceOf(alice), 0, "alice balance after burn");

        // Independent storage: a second uAsset's instance does not see alice's claim.
        address otherDeployed = factory.deployCredit(address(otherUAsset), "Credit2", "CRT2", delegate);
        GenesisCredit otherCredit = GenesisCredit(otherDeployed);
        assertEq(otherCredit.balanceOf(alice), 0, "sibling instance must be isolated");
    }
}
