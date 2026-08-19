// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {MemeverseRegistrarAbstract} from "../../../src/verse/registration/MemeverseRegistrarAbstract.sol";
import {MemeverseRegistrarOmnichain} from "../../../src/verse/registration/MemeverseRegistrarOmnichain.sol";
import {IMemeverseRegistrar} from "../../../src/verse/interfaces/IMemeverseRegistrar.sol";
import {IMemeverseRegistrarOmnichain} from "../../../src/verse/interfaces/IMemeverseRegistrarOmnichain.sol";
import {IMemeverseRegistrationCenter} from "../../../src/verse/interfaces/IMemeverseRegistrationCenter.sol";

contract MockOmnichainLauncher {
    uint256 public lastRegisteredUniqueId;
    address public lastRegisteredUAsset;
    bool public lastRegisteredFlashGenesis;
    uint256 public lastExternalInfoUniqueId;
    string public lastUri;

    /// @notice Register memeverse.
    /// @param name See implementation.
    /// @param symbol See implementation.
    /// @param uniqueId See implementation.
    /// @param endTime See implementation.
    /// @param unlockTime See implementation.
    /// @param omnichainIds See implementation.
    /// @param uAsset See implementation.
    /// @param flashGenesis See implementation.
    function registerMemeverse(
        string memory name,
        string memory symbol,
        uint256 uniqueId,
        uint128 endTime,
        uint128 unlockTime,
        uint32[] memory omnichainIds,
        address uAsset,
        bool flashGenesis
    ) external {
        name;
        symbol;
        endTime;
        unlockTime;
        omnichainIds;
        lastRegisteredUniqueId = uniqueId;
        lastRegisteredUAsset = uAsset;
        lastRegisteredFlashGenesis = flashGenesis;
    }

    /// @notice Set external info.
    /// @param uniqueId See implementation.
    /// @param uri See implementation.
    function setExternalInfo(uint256 uniqueId, string memory uri, string memory, string[] memory) external {
        lastExternalInfoUniqueId = uniqueId;
        lastUri = uri;
    }
}

contract MockRegistrarOmnichainEndpoint {
    error InvalidQuotedNativeFee(uint256 expectedNativeFee, uint256 msgValue);

    address public delegate;
    uint256 public quotedNativeFee;
    address public lastRefundAddress;
    uint256 public lastSendValue;
    uint256 public lastRefundedNative;
    uint32 public lastDstEid;
    bytes32 public lastReceiver;
    bytes public lastMessage;
    bytes public lastOptions;
    bool public lastPayInLzToken;
    bytes32 public sendGuid = bytes32("guid");
    uint64 public sendNonce = 7;

    /// @notice Set delegate.
    /// @param delegate_ See implementation.
    function setDelegate(address delegate_) external {
        delegate = delegate_;
    }

    /// @notice Lz token.
    /// @return See implementation.
    function lzToken() external pure returns (address) {
        return address(0);
    }

    /// @notice Set quoted native fee.
    /// @param fee See implementation.
    function setQuotedNativeFee(uint256 fee) external {
        quotedNativeFee = fee;
    }

    /// @notice Quote.
    /// @param params See implementation.
    /// @param sender See implementation.
    /// @return fee See implementation.
    function quote(MessagingParams calldata params, address sender) external view returns (MessagingFee memory fee) {
        params;
        sender;
        fee = MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    /// @notice Send.
    /// @param params See implementation.
    /// @param refundAddress See implementation.
    /// @return receipt See implementation.
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        if (msg.value < quotedNativeFee) {
            revert InvalidQuotedNativeFee(quotedNativeFee, msg.value);
        }

        lastDstEid = params.dstEid;
        lastReceiver = params.receiver;
        lastMessage = params.message;
        lastOptions = params.options;
        lastPayInLzToken = params.payInLzToken;
        lastRefundAddress = refundAddress;
        lastSendValue = msg.value;
        lastRefundedNative = msg.value - quotedNativeFee;
        if (lastRefundedNative > 0) {
            (bool success,) = payable(refundAddress).call{value: lastRefundedNative}("");
            require(success, "refund failed");
        }
        receipt = MessagingReceipt({
            guid: sendGuid, nonce: sendNonce, fee: MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0})
        });
    }
}

contract MemeverseRegistrarOmnichainTest is Test {
    using OptionsBuilder for bytes;

    address internal constant OWNER = address(0xABCD);
    address internal constant OTHER = address(0xCAFE);
    uint32 internal constant CENTER_EID = 301;
    uint32 internal constant CENTER_CHAIN_ID = 101;

    MockRegistrarOmnichainEndpoint internal endpoint;
    MockOmnichainLauncher internal launcher;
    MemeverseRegistrarOmnichain internal registrar;

    receive() external payable {}

    /// @notice Set up.
    function setUp() external {
        endpoint = new MockRegistrarOmnichainEndpoint();
        launcher = new MockOmnichainLauncher();
        registrar = new MemeverseRegistrarOmnichain(
            OWNER, address(endpoint), address(launcher), address(0x1234), CENTER_EID, CENTER_CHAIN_ID, 100, 10, 20
        );

        vm.prank(OWNER);
        registrar.setPeer(CENTER_EID, bytes32(uint256(uint160(address(0xBEEF)))));
    }

    /// @notice Test quote register builds center message and uses endpoint quote.
    function testQuoteRegisterBuildsCenterMessageAndUsesEndpointQuote() external {
        endpoint.setQuotedNativeFee(0.75 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        bytes memory expectedOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(150, 77);

        vm.expectCall(
            address(endpoint),
            abi.encodeWithSelector(
                MockRegistrarOmnichainEndpoint.quote.selector,
                MessagingParams({
                    dstEid: CENTER_EID,
                    receiver: bytes32(uint256(uint160(address(0xBEEF)))),
                    message: abi.encode(param),
                    options: expectedOptions,
                    payInLzToken: false
                }),
                address(registrar)
            )
        );

        uint256 quotedFee = registrar.quoteRegister(param, 77);

        assertEq(quotedFee, 0.75 ether);
    }

    /// @notice Test register at center requires enough fee and sends message through endpoint.
    function testRegisterAtCenterRequiresEnoughFeeAndSendsMessageThroughEndpoint() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        uint256 quotedFee = registrar.quoteRegister(param, 33);

        vm.expectRevert(IMemeverseRegistrarOmnichain.InsufficientLzFee.selector);
        registrar.registerAtCenter(param, 33);

        registrar.registerAtCenter{value: quotedFee}(param, 33);

        bytes memory expectedOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(150, 33);
        assertEq(endpoint.lastDstEid(), CENTER_EID);
        assertEq(endpoint.lastRefundAddress(), address(this));
        assertEq(endpoint.lastSendValue(), quotedFee);
        assertEq(endpoint.lastMessage(), abi.encode(param));
        assertEq(endpoint.lastOptions(), expectedOptions);
        assertFalse(endpoint.lastPayInLzToken());
    }

    /// @notice Test register at center accepts overpayment and refunds the excess back to the caller.
    function testRegisterAtCenterAcceptsOverpaymentAndRefundsExcess() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        uint256 quotedFee = registrar.quoteRegister(param, 44);
        uint256 overpayment = quotedFee + 0.2 ether;

        vm.deal(address(this), 2 ether);
        uint256 balanceBefore = address(this).balance;

        registrar.registerAtCenter{value: overpayment}(param, 44);

        assertEq(endpoint.lastRefundAddress(), address(this));
        assertEq(endpoint.lastSendValue(), overpayment);
        assertEq(endpoint.lastRefundedNative(), overpayment - quotedFee);
        assertEq(address(this).balance, balanceBefore - quotedFee);
    }

    /// @notice Test endpoint send reverts if callers use a stale quote.
    function testMockRegistrarEndpointSendRejectsStaleQuote() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        MessagingParams memory params = MessagingParams({
            dstEid: CENTER_EID,
            receiver: bytes32(uint256(uint160(address(0xBEEF)))),
            message: abi.encode(_registrationParam()),
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(150, 33),
            payInLzToken: false
        });
        uint256 staleQuote = endpoint.quote(params, address(registrar)).nativeFee;

        endpoint.setQuotedNativeFee(0.6 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockRegistrarOmnichainEndpoint.InvalidQuotedNativeFee.selector, 0.6 ether, staleQuote
            )
        );
        endpoint.send{value: staleQuote}(params, address(this));
    }

    /// @notice Test set registration gas limit only owner.
    function testSetRegistrationGasLimitOnlyOwner() external {
        IMemeverseRegistrarOmnichain.RegistrationGasLimit memory gasLimit =
            IMemeverseRegistrarOmnichain.RegistrationGasLimit({
                baseRegistrationGasLimit: 1, localRegistrationGasLimit: 2, omnichainRegistrationGasLimit: 3
            });

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        registrar.setRegistrationGasLimit(gasLimit);

        vm.prank(OWNER);
        registrar.setRegistrationGasLimit(gasLimit);

        (uint80 base, uint80 local, uint80 omnichain) = registrar.registrationGasLimit();
        assertEq(base, 1);
        assertEq(local, 2);
        assertEq(omnichain, 3);
    }

    /// @notice Test lz receive from endpoint and peer forwards registration to launcher.
    function testLzReceiveFromEndpointAndPeerForwardsRegistrationToLauncher() external {
        IMemeverseRegistrar.MemeverseParam memory param = _memeverseParam();
        Origin memory origin =
            Origin({srcEid: CENTER_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 1});

        vm.prank(address(endpoint));
        registrar.lzReceive(origin, bytes32("guid"), abi.encode(param), address(0), "");

        assertEq(launcher.lastRegisteredUniqueId(), param.uniqueId);
        assertEq(launcher.lastRegisteredUAsset(), param.uAsset);
        assertEq(launcher.lastRegisteredFlashGenesis(), param.flashGenesis);
        assertEq(launcher.lastExternalInfoUniqueId(), param.uniqueId);
        assertEq(launcher.lastUri(), param.uri);
    }

    /// @notice Test lz receive rejects non-endpoint callers.
    function testLzReceiveRejectsNonEndpointCaller() external {
        IMemeverseRegistrar.MemeverseParam memory param = _memeverseParam();
        Origin memory origin =
            Origin({srcEid: CENTER_EID, sender: bytes32(uint256(uint160(address(0xBEEF)))), nonce: 1});

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, OTHER));
        registrar.lzReceive(origin, bytes32("guid"), abi.encode(param), address(0), "");
    }

    /// @notice Test lz receive rejects unexpected peers even from the endpoint.
    function testLzReceiveRejectsUnexpectedPeer() external {
        IMemeverseRegistrar.MemeverseParam memory param = _memeverseParam();
        Origin memory origin = Origin({srcEid: CENTER_EID, sender: bytes32(uint256(uint160(OTHER))), nonce: 1});

        vm.prank(address(endpoint));
        vm.expectRevert(
            abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, CENTER_EID, bytes32(uint256(uint160(OTHER))))
        );
        registrar.lzReceive(origin, bytes32("guid"), abi.encode(param), address(0), "");
    }

    /// @notice Test renounceOwnership is permanently disabled (never-renounceable repo invariant).
    /// @dev The error is declared on the shared `MemeverseRegistrarAbstract` base, hence the
    ///      base-qualified selector.
    function testRenounceOwnershipIsDisabled() external {
        vm.prank(OWNER);
        vm.expectRevert(MemeverseRegistrarAbstract.OwnershipRenounceDisabled.selector);
        registrar.renounceOwnership();
    }

    function _registrationParam() internal view returns (IMemeverseRegistrationCenter.RegistrationParam memory param) {
        param.name = "Memeverse";
        param.symbol = "OMEME";
        param.uri = "ipfs://omemeverse";
        param.desc = "Omnichain Memeverse";
        param.communities = new string[](1);
        param.communities[0] = "https://omemeverse.example";
        param.durationDays = 3;
        param.omnichainIds = new uint32[](3);
        param.omnichainIds[0] = CENTER_CHAIN_ID;
        param.omnichainIds[1] = uint32(block.chainid);
        param.omnichainIds[2] = 202;
        param.uAsset = address(0x7777);
        param.flashGenesis = true;
    }

    function _memeverseParam() internal view returns (IMemeverseRegistrar.MemeverseParam memory param) {
        IMemeverseRegistrationCenter.RegistrationParam memory registrationParam = _registrationParam();
        param.name = registrationParam.name;
        param.symbol = registrationParam.symbol;
        param.uri = registrationParam.uri;
        param.desc = registrationParam.desc;
        param.communities = registrationParam.communities;
        param.uniqueId = 5678;
        param.endTime = uint64(block.timestamp + 3 days);
        param.unlockTime = uint64(block.timestamp + 8 days);
        param.omnichainIds = registrationParam.omnichainIds;
        param.uAsset = registrationParam.uAsset;
        param.flashGenesis = registrationParam.flashGenesis;
    }
}
