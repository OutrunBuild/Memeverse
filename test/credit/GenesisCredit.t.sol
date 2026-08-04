// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {
    MessagingFee,
    MessagingReceipt,
    MessagingParams,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {GenesisCredit} from "../../src/credit/GenesisCredit.sol";
import {IGenesisCredit} from "../../src/credit/interfaces/IGenesisCredit.sol";

/// @notice Minimal LayerZero endpoint stand-in: supports `setDelegate` (OFTCore constructor) and
///         exposes `eid()` (auto-generated getter of the EndpointV2 `eid` immutable) for the home-chain gate.
contract MockGenesisCreditEndpoint {
    address public delegate;
    uint32 public immutable eid;
    uint32 public lastDstEid;
    bytes32 public lastReceiver;
    bytes public lastMessage;
    bytes public lastOptions;
    address public lastRefundAddress;
    uint256 public lastNativeValue;
    uint256 public quoteNativeFee;

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }

    function setQuoteNativeFee(uint256 nativeFee) external {
        quoteNativeFee = nativeFee;
    }

    function quote(MessagingParams calldata params, address sender) external view returns (MessagingFee memory fee) {
        params;
        sender;
        fee = MessagingFee({nativeFee: quoteNativeFee, lzTokenFee: 0});
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        lastDstEid = params.dstEid;
        lastReceiver = params.receiver;
        lastMessage = params.message;
        lastOptions = params.options;
        lastRefundAddress = refundAddress;
        lastNativeValue = msg.value;
        receipt = MessagingReceipt({
            guid: bytes32("send-guid"), nonce: 1, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }
}

contract GenesisCreditTest is Test {
    /// @dev Selector of OZ Ownable.OwnableUnauthorizedAccount(address), inherited from OFTCore via OAppCore.
    bytes4 internal constant OwnableUnauthorizedAccountSelector = bytes4(0x118cdaa7);

    uint32 internal constant HOME_EID = 30_111;
    uint32 internal constant REMOTE_EID = 40_111;
    address internal constant DELEGATE = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockGenesisCreditEndpoint internal homeEndpoint;
    MockGenesisCreditEndpoint internal remoteEndpoint;
    GenesisCredit internal credit;

    bytes32 internal merkleRoot;
    bytes32[] internal aliceProof;

    function setUp() external {
        homeEndpoint = new MockGenesisCreditEndpoint(HOME_EID);
        remoteEndpoint = new MockGenesisCreditEndpoint(REMOTE_EID);
        // Plain deployment: constructor runs in-line, no clone / initialize.
        credit = new GenesisCredit("GenesisCredit", "GCR", address(homeEndpoint), DELEGATE, HOME_EID);

        // Build a single-leaf merkle tree: root = leaf (no intermediates) for ALICE allocation.
        (merkleRoot, aliceProof) = _buildMerkle(ALICE, 100 ether);
        vm.prank(DELEGATE);
        credit.setMerkleRoot(merkleRoot);
    }

    /// @notice Claim mints on the home chain and records the per-user claim.
    function test_Claim_MintsOnHomeChain() external {
        vm.expectEmit(true, false, false, true);
        emit IGenesisCredit.Claimed(ALICE, 100 ether);

        vm.prank(ALICE);
        credit.claim(100 ether, aliceProof);

        assertEq(credit.balanceOf(ALICE), 100 ether);
        assertEq(credit.claimed(ALICE), 100 ether);
    }

    /// @notice Verifies the concrete GenesisCredit OFT send and receive surfaces with a remote instance.
    function test_OFTSendAndReceive_UsesGenesisCreditBridgeSurface() external {
        vm.prank(ALICE);
        credit.claim(100 ether, aliceProof);

        uint256 bridgeAmount = 40 ether;
        SendParam memory sendParam = SendParam({
            dstEid: REMOTE_EID,
            to: bytes32(uint256(uint160(BOB))),
            amountLD: bridgeAmount,
            minAmountLD: bridgeAmount,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        GenesisCredit remoteCredit =
            new GenesisCredit("GenesisCredit", "GCR", address(remoteEndpoint), DELEGATE, HOME_EID);
        vm.prank(DELEGATE);
        credit.setPeer(REMOTE_EID, bytes32(uint256(uint160(address(remoteCredit)))));
        vm.prank(DELEGATE);
        remoteCredit.setPeer(HOME_EID, bytes32(uint256(uint160(address(credit)))));

        MessagingFee memory fee = MessagingFee({nativeFee: 0.01 ether, lzTokenFee: 0});
        homeEndpoint.setQuoteNativeFee(fee.nativeFee);

        assertEq(credit.quoteSend(sendParam, false).nativeFee, fee.nativeFee);

        vm.deal(ALICE, fee.nativeFee);
        vm.prank(ALICE);
        credit.send{value: fee.nativeFee}(sendParam, fee, ALICE);
        assertEq(credit.balanceOf(ALICE), 60 ether);
        assertEq(homeEndpoint.lastDstEid(), REMOTE_EID);
        assertEq(homeEndpoint.lastReceiver(), bytes32(uint256(uint160(address(remoteCredit)))));
        assertEq(homeEndpoint.lastRefundAddress(), ALICE);
        assertEq(homeEndpoint.lastNativeValue(), fee.nativeFee);

        bytes memory message = homeEndpoint.lastMessage();
        Origin memory origin = Origin({srcEid: HOME_EID, sender: bytes32(uint256(uint160(address(credit)))), nonce: 1});

        vm.prank(address(remoteEndpoint));
        remoteCredit.lzReceive(origin, bytes32("receive-guid"), message, address(0), bytes(""));

        assertEq(remoteCredit.balanceOf(BOB), bridgeAmount);
    }

    /// @notice A second claim by the same user reverts.
    function test_RevertWhen_ClaimTwice() external {
        vm.startPrank(ALICE);
        credit.claim(100 ether, aliceProof);
        vm.expectRevert(IGenesisCredit.AlreadyClaimed.selector);
        credit.claim(100 ether, aliceProof);
        vm.stopPrank();
    }

    /// @notice Root rotation is an owner capability (correcting or appending allocations). A user
    ///         who already claimed under a prior root must NOT mint again with a fresh proof under
    ///         the new root: `claimed` is the sole cross-root double-mint defense and is never
    ///         cleared by setMerkleRoot. Also pins the claim-check ordering — `claimed` is checked
    ///         before the proof, so a valid new-root proof still reverts AlreadyClaimed.
    function test_RevertWhen_ReclaimAfterRootRotation() external {
        // ALICE claims the full 100 ether allocation under root1 (set in setUp).
        vm.prank(ALICE);
        credit.claim(100 ether, aliceProof);
        assertEq(credit.claimed(ALICE), 100 ether);

        // Owner rotates to root2 where ALICE has a fresh, larger allocation (200 ether).
        address bob = address(0xB0B);
        bytes32 la2 = _leaf(ALICE, 200 ether);
        bytes32 lb = _leaf(bob, 300 ether);
        bytes32 root2 = _pair(la2, lb);
        bytes32[] memory aliceProof2 = new bytes32[](1);
        aliceProof2[0] = lb;
        vm.prank(DELEGATE);
        credit.setMerkleRoot(root2);

        // aliceProof2 is valid for (ALICE, 200) under root2, yet the `claimed` guard fires first
        // (check order: claimed -> proof), so cross-root reclaim reverts AlreadyClaimed.
        vm.prank(ALICE);
        vm.expectRevert(IGenesisCredit.AlreadyClaimed.selector);
        credit.claim(200 ether, aliceProof2);

        // setMerkleRoot never touches `claimed`: the prior claim record survives the rotation.
        assertEq(credit.claimed(ALICE), 100 ether);
    }

    /// @notice Root rotation must remain a usable ops path: a NEW recipient added under root2 can
    ///         claim. Pairs with test_RevertWhen_ReclaimAfterRootRotation to pin both faces of
    ///         rotation (already-claimed blocked, new recipient served).
    function test_Claim_NewUserAfterRootRotation() external {
        address bob = address(0xB0B);
        bytes32 la2 = _leaf(ALICE, 200 ether);
        bytes32 lb = _leaf(bob, 300 ether);
        bytes32 root2 = _pair(la2, lb);
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = la2;
        vm.prank(DELEGATE);
        credit.setMerkleRoot(root2);

        vm.prank(bob);
        credit.claim(300 ether, bobProof);

        assertEq(credit.balanceOf(bob), 300 ether);
        assertEq(credit.claimed(bob), 300 ether);
    }

    /// @notice Claim on a non-home-chain deployment reverts with the configured home eid. Proves the
    ///         eid gate works even when the OFT instance is wired to a foreign-chain endpoint.
    function test_RevertWhen_ClaimOnNonHomeChain() external {
        // Deploy a second plain instance against the remote endpoint; its homeChainEid is still HOME_EID
        // but endpoint.eid() now reports REMOTE_EID, so the home-chain gate must reject the claim.
        GenesisCredit remoteCredit =
            new GenesisCredit("GenesisCredit", "GCR", address(remoteEndpoint), DELEGATE, HOME_EID);
        vm.prank(DELEGATE);
        remoteCredit.setMerkleRoot(merkleRoot);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IGenesisCredit.NotHomeChain.selector, HOME_EID));
        remoteCredit.claim(100 ether, aliceProof);
    }

    /// @notice An invalid merkle proof reverts.
    function test_RevertWhen_InvalidProof() external {
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xdead));

        vm.prank(ALICE);
        vm.expectRevert(IGenesisCredit.InvalidProof.selector);
        credit.claim(100 ether, badProof);
    }

    /// @notice Multi-leaf tree (4 leaves, 2 internal levels): each leaf claims with a non-empty
    ///         proof. Exercises the sorted pair-hash traversal inside verifyCalldata that a
    ///         single-leaf tree (root = leaf, empty proof) never reaches.
    function test_Claim_MultiLeafTree_EachLeafValidProof() external {
        address bob = address(0xB0B);
        address carol = address(0xCA401);
        address dave = address(0xDA7E);

        bytes32 la = _leaf(ALICE, 100 ether);
        bytes32 lb = _leaf(bob, 200 ether);
        bytes32 lc = _leaf(carol, 300 ether);
        bytes32 ld = _leaf(dave, 400 ether);
        bytes32 n1 = _pair(la, lb); // internal node: alice + bob
        bytes32 n2 = _pair(lc, ld); // internal node: carol + dave
        bytes32 root = _pair(n1, n2);

        vm.prank(DELEGATE);
        credit.setMerkleRoot(root);

        // Proof order is leaf -> root: [sibling leaf, sibling internal node].
        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = lb;
        proofA[1] = n2;
        bytes32[] memory proofB = new bytes32[](2);
        proofB[0] = la;
        proofB[1] = n2;
        bytes32[] memory proofC = new bytes32[](2);
        proofC[0] = ld;
        proofC[1] = n1;
        bytes32[] memory proofD = new bytes32[](2);
        proofD[0] = lc;
        proofD[1] = n1;

        vm.prank(ALICE);
        credit.claim(100 ether, proofA);
        vm.prank(bob);
        credit.claim(200 ether, proofB);
        vm.prank(carol);
        credit.claim(300 ether, proofC);
        vm.prank(dave);
        credit.claim(400 ether, proofD);

        assertEq(credit.balanceOf(ALICE), 100 ether);
        assertEq(credit.balanceOf(bob), 200 ether);
        assertEq(credit.balanceOf(carol), 300 ether);
        assertEq(credit.balanceOf(dave), 400 ether);
    }

    /// @notice Cross-leaf swap: alice claiming with bob's amount + bob's proof reverts. The
    ///         contract recomputes leaf = doubleHash(alice, 200) != bob's leaf, so the proof does
    ///         not match. Proves the proof binds to msg.sender, not a reusable credential.
    ///         (amount-binding is covered by the positive tests, which pin the exact leaf.)
    function test_RevertWhen_CrossLeafProof() external {
        address bob = address(0xB0B);
        bytes32 la = _leaf(ALICE, 100 ether);
        bytes32 lb = _leaf(bob, 200 ether);
        bytes32 root = _pair(la, lb);

        vm.prank(DELEGATE);
        credit.setMerkleRoot(root);

        // bob's sibling is alice's leaf.
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = la;

        vm.prank(ALICE);
        vm.expectRevert(IGenesisCredit.InvalidProof.selector);
        credit.claim(200 ether, bobProof);
    }

    /// @notice A zero-amount claim reverts.
    function test_RevertWhen_ClaimZeroAmount() external {
        vm.prank(ALICE);
        vm.expectRevert(IGenesisCredit.ZeroInput.selector);
        credit.claim(0, aliceProof);
    }

    /// @notice A non-owner cannot set the merkle root. OwnableUnauthorizedAccount is inherited from
    ///         OFTCore via OAppCore (plain OZ Ownable), so the revert data is ABI-encoded with the caller.
    function test_RevertWhen_SetMerkleRootByNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodePacked(OwnableUnauthorizedAccountSelector, abi.encode(ALICE)));
        credit.setMerkleRoot(bytes32(0));
    }

    /// @notice Owner setting a new root emits MerkleRootSet with that root and persists it.
    function test_SetMerkleRoot_EmitsEvent() external {
        bytes32 newRoot = bytes32(uint256(0xbabe));

        vm.prank(DELEGATE);
        vm.expectEmit(false, false, false, true);
        emit IGenesisCredit.MerkleRootSet(newRoot);

        credit.setMerkleRoot(newRoot);

        assertEq(credit.merkleRoot(), newRoot);
    }

    /// @notice Claim then burn leaves the caller with zero balance.
    function test_Burn_SelfBurnsCallerBalance() external {
        vm.prank(ALICE);
        credit.claim(100 ether, aliceProof);

        vm.prank(ALICE);
        credit.burn(100 ether);

        assertEq(credit.balanceOf(ALICE), 0);
    }

    /// @notice Burning zero reverts.
    function test_RevertWhen_BurnZeroAmount() external {
        vm.prank(ALICE);
        vm.expectRevert(IGenesisCredit.ZeroInput.selector);
        credit.burn(0);
    }

    /// @notice Immutable home-chain eid survives a plain deployment, and ERC-20 metadata +
    ///         ownership are wired through the OFT constructor.
    function test_ImmutableConfigAfterDeploy() external {
        assertEq(credit.homeChainEid(), HOME_EID);
        assertEq(credit.merkleRoot(), merkleRoot);
        assertEq(credit.name(), "GenesisCredit");
        assertEq(credit.symbol(), "GCR");
        // delegate_ passed to the OFT constructor becomes the owner via OFTCore -> OAppCore Ownable.
        assertEq(credit.owner(), DELEGATE);
    }

    /// @dev Builds a single-leaf merkle tree matching GenesisCredit's double-hashed leaf.
    function _buildMerkle(address user, uint256 amount) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = _leaf(user, amount);
        proof = new bytes32[](0);
    }

    /// @dev Double-hashed leaf, matching GenesisCredit.claim's second-preimage defense.
    function _leaf(address user, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
    }

    /// @dev Sorted pair hash, matching OZ Hashes.commutativeKeccak256 used by verifyCalldata.
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
