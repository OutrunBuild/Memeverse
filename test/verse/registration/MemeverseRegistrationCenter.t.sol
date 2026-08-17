// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {
    MemeverseRegistrationCenterUpgradeable
} from "../../../src/verse/registration/MemeverseRegistrationCenterUpgradeable.sol";
import {IMemeverseRegistrar} from "../../../src/verse/interfaces/IMemeverseRegistrar.sol";
import {IMemeverseRegistrationCenter} from "../../../src/verse/interfaces/IMemeverseRegistrationCenter.sol";
import {LzEndpointRegistry} from "../../../src/common/omnichain/LzEndpointRegistry.sol";
import {ILzEndpointRegistry} from "../../../src/common/omnichain/interfaces/ILzEndpointRegistry.sol";
import {OutrunOAppUpgradeable} from "../../../src/common/omnichain/oapp/OutrunOAppUpgradeable.sol";
import {
    MemeverseRegistrationCenterUpgradeableV2
} from "../../mocks/upgrade/MemeverseRegistrationCenterUpgradeableV2.sol";

contract MockCenterEndpoint {
    bool public quoteBlocked;
    bool public sendBlocked;
    /// @dev Keyed by the calling OApp, mirroring EndpointV2's own `delegates(address)` mapping, so tests can
    ///      prove which address the endpoint saw as the caller of `setDelegate`.
    mapping(address oapp => address delegate) public delegates;
    uint256 public quotedNativeFee;
    uint256 public actualNativeFee;
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
        delegates[msg.sender] = delegate_;
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

    /// @notice Set actual native fee.
    /// @param fee See implementation.
    function setActualNativeFee(uint256 fee) external {
        actualNativeFee = fee;
    }

    /// @notice Block or unblock quote calls.
    /// @param blocked See implementation.
    function setQuoteBlocked(bool blocked) external {
        quoteBlocked = blocked;
    }

    /// @notice Block or unblock send calls.
    /// @param blocked See implementation.
    function setSendBlocked(bool blocked) external {
        sendBlocked = blocked;
    }

    /// @notice Quote.
    /// @param params See implementation.
    /// @param sender See implementation.
    /// @return fee See implementation.
    function quote(MessagingParams calldata params, address sender) external view returns (MessagingFee memory fee) {
        params;
        sender;
        require(!quoteBlocked, "quote blocked");
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
        require(!sendBlocked, "send blocked");
        lastDstEid = params.dstEid;
        lastReceiver = params.receiver;
        lastMessage = params.message;
        lastOptions = params.options;
        lastPayInLzToken = params.payInLzToken;
        lastRefundAddress = refundAddress;
        lastSendValue = msg.value;
        uint256 retainedNativeFee = actualNativeFee == 0 ? quotedNativeFee : actualNativeFee;
        if (msg.value > retainedNativeFee) {
            lastRefundedNative = msg.value - retainedNativeFee;
            (bool success,) = payable(refundAddress).call{value: lastRefundedNative}("");
            require(success, "refund failed");
        } else {
            lastRefundedNative = 0;
        }
        receipt = MessagingReceipt({
            guid: sendGuid, nonce: sendNonce, fee: MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0})
        });
    }
}

contract MockCenterRegistrar {
    uint256 public lastUniqueId;
    address public lastUAsset;
    bool public lastFlashGenesis;
    uint64 public lastEndTime;
    uint64 public lastUnlockTime;
    string public lastName;
    string public lastSymbol;

    /// @notice Local registration.
    /// @param param See implementation.
    function localRegistration(IMemeverseRegistrar.MemeverseParam calldata param) external {
        lastUniqueId = param.uniqueId;
        lastUAsset = param.uAsset;
        lastFlashGenesis = param.flashGenesis;
        lastEndTime = param.endTime;
        lastUnlockTime = param.unlockTime;
        lastName = param.name;
        lastSymbol = param.symbol;
    }
}

/// @notice Upgrade-target shell that deploys with code but exposes no `endpoint()` getter.
/// @dev The center's `_authorizeUpgrade` probes targets through `IOAppCore.endpoint()`; with no matching
///      selector and no fallback the probe call reverts into the probe's catch branch.
contract EndpointGetterMissingShell {
    /// @notice Unrelated placeholder whose only job is to give the shell deployed code.
    /// @return Fixed marker value.
    function marker() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Upgrade-target shell whose `endpoint()` getter exists but always reverts.
contract EndpointGetterRevertingShell {
    error GetterReverted();

    /// @notice Getter-shaped probe target that fails on demand.
    function endpoint() external view {
        revert GetterReverted();
    }
}

/// @notice Upgrade-target shell whose `endpoint()` getter succeeds but returns empty returndata.
contract EndpointGetterEmptyReturnShell {
    /// @notice Getter-shaped probe target returning zero bytes of returndata.
    /// @dev A plain view function must return a declared value, so `return(0, 0)` in assembly is the only
    ///      way to make the STATICCALL succeed while returning nothing decodable into an address.
    function endpoint() external view {
        assembly {
            return(0, 0)
        }
    }
}

contract MemeverseRegistrationCenterTest is Test {
    using OptionsBuilder for bytes;

    address internal constant OWNER = address(0xABCD);
    uint32 internal constant REMOTE_CHAIN_ID = 202;
    uint32 internal constant REMOTE_EID = 302;
    uint32 internal constant SOURCE_EID = 401;

    MockCenterEndpoint internal endpoint;
    MockCenterRegistrar internal registrar;
    LzEndpointRegistry internal registry;
    MemeverseRegistrationCenterUpgradeable internal center;

    /// @notice Set up.
    /// @dev UUPS deployment shape: implementation + ERC1967Proxy with initialize in the constructor data,
    ///      mirroring the script's `_deployRegistrationCenter`.
    function setUp() external {
        endpoint = new MockCenterEndpoint();
        registrar = new MockCenterRegistrar();
        registry = new LzEndpointRegistry(OWNER);
        MemeverseRegistrationCenterUpgradeable implementation =
            new MemeverseRegistrationCenterUpgradeable(address(endpoint));
        center = MemeverseRegistrationCenterUpgradeable(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            MemeverseRegistrationCenterUpgradeable.initialize,
                            (OWNER, address(registrar), address(registry))
                        )
                    )
                ))
        );

        vm.prank(OWNER);
        registry.setLzEndpointIds(_endpointPairs());

        vm.startPrank(OWNER);
        center.setSupportedUAsset(address(0x7777), true);
        center.setDurationDaysRange(1, 10);
        center.setRegisterGasLimit(150);
        center.setPeer(REMOTE_EID, bytes32(uint256(uint160(address(0xBEEF)))));
        center.setPeer(SOURCE_EID, bytes32(uint256(uint160(address(registrar)))));
        vm.stopPrank();
    }

    /// @notice Test config setters and preview registration.
    function testConfigSettersAndPreviewRegistration() external {
        vm.prank(OWNER);
        center.setSupportedUAsset(address(0x8888), true);
        vm.prank(OWNER);
        center.setDurationDaysRange(2, 12);
        vm.prank(OWNER);
        center.setRegisterGasLimit(321);

        assertTrue(center.previewRegistration("NEW"));
        string memory longSymbol = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef";
        assertFalse(center.previewRegistration(longSymbol));
        assertEq(center.minDurationDays(), 2);
        assertEq(center.maxDurationDays(), 12);
        assertEq(center.registerGasLimit(), 321);
    }

    /// @notice Test preview registration returns false while symbol is still locked.
    function testPreviewRegistrationReturnsFalseWhileSymbolIsStillLocked() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        center.registration{value: 0.5 ether}(param);

        assertFalse(center.previewRegistration(param.symbol));
    }

    /// @notice Test config setters reject invalid inputs.
    function testConfigSettersRejectInvalidInputs() external {
        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        center.setSupportedUAsset(address(0), true);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidInput.selector);
        center.setDurationDaysRange(0, 1);

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        center.setRegisterGasLimit(0);
    }

    /// @notice Test setRegisterGasLimit rejects values above the uint128 consumption ceiling.
    /// @dev Storage keeps the full uint256, but the LayerZero receive-options builder narrows the stored
    ///      limit to uint128 (`quoteSend` / `_omnichainSend`); a value above `type(uint128).max` would be
    ///      silently truncated there, so the setter must reject it with `InvalidInput`.
    function testSetRegisterGasLimitRejectsValuesAboveUint128() external {
        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidInput.selector);
        center.setRegisterGasLimit(2 ** 128);
    }

    /// @notice Test setRegisterGasLimit accepts the exact uint128 ceiling losslessly.
    /// @dev `type(uint128).max` is the largest value whose uint128 narrowing cast in the options builder
    ///      is lossless, so the getter must read back the exact stored value.
    function testSetRegisterGasLimitAcceptsUint128Max() external {
        vm.prank(OWNER);
        center.setRegisterGasLimit(type(uint128).max);

        assertEq(center.registerGasLimit(), type(uint128).max);
    }

    /// @notice Test quote send skips local and quotes remote path.
    function testQuoteSendSkipsLocalAndQuotesRemotePath() external {
        endpoint.setQuotedNativeFee(0.4 ether);
        uint32[] memory omnichainIds = new uint32[](2);
        omnichainIds[0] = uint32(block.chainid);
        omnichainIds[1] = REMOTE_CHAIN_ID;
        bytes memory message = bytes("hello");
        bytes memory expectedOptions =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(center.registerGasLimit()), 0);

        vm.expectCall(
            address(endpoint),
            abi.encodeCall(
                MockCenterEndpoint.quote,
                (
                    MessagingParams({
                        dstEid: REMOTE_EID,
                        receiver: bytes32(uint256(uint160(address(0xBEEF)))),
                        message: message,
                        options: expectedOptions,
                        payInLzToken: false
                    }),
                    address(center)
                )
            )
        );

        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = center.quoteSend(omnichainIds, message);

        assertEq(totalFee, 0.4 ether);
        assertEq(fees.length, 2);
        assertEq(fees[0], 0);
        assertEq(fees[1], 0.4 ether);
        assertEq(eids[0], 0);
        assertEq(eids[1], REMOTE_EID);
    }

    /// @notice Test quote send returns zero for all local targets.
    function testQuoteSendReturnsZeroForAllLocalTargets() external {
        endpoint.setQuoteBlocked(true);
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = uint32(block.chainid);

        (uint256 totalFee, uint256[] memory fees, uint32[] memory eids) = center.quoteSend(omnichainIds, bytes("hello"));

        assertEq(totalFee, 0);
        assertEq(fees.length, 1);
        assertEq(fees[0], 0);
        assertEq(eids[0], 0);
    }

    /// @notice Test quote send reverts on invalid remote omnichain id.
    function testQuoteSendRevertsOnInvalidRemoteOmnichainId() external {
        uint32[] memory omnichainIds = new uint32[](1);
        omnichainIds[0] = 999;

        vm.expectRevert(abi.encodeWithSelector(IMemeverseRegistrationCenter.InvalidOmnichainId.selector, uint32(999)));
        center.quoteSend(omnichainIds, bytes("hello"));
    }

    /// @notice Test registration stores symbol registers local and sends remote.
    function testRegistrationStoresSymbolRegistersLocalAndSendsRemote() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        uint64 expectedEndTime = uint64(block.timestamp + param.durationDays * center.DAY());
        IMemeverseRegistrar.MemeverseParam memory expectedRemoteParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset))),
            endTime: expectedEndTime,
            unlockTime: uint64(expectedEndTime + 365 days),
            omnichainIds: param.omnichainIds,
            uAsset: param.uAsset,
            flashGenesis: param.flashGenesis
        });
        bytes memory expectedOptions =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(center.registerGasLimit()), 0);

        vm.expectCall(
            address(endpoint),
            0.5 ether,
            abi.encodeCall(
                MockCenterEndpoint.send,
                (
                    MessagingParams({
                        dstEid: REMOTE_EID,
                        receiver: bytes32(uint256(uint160(address(0xBEEF)))),
                        message: abi.encode(expectedRemoteParam),
                        options: expectedOptions,
                        payInLzToken: false
                    }),
                    address(center)
                )
            )
        );

        center.registration{value: 0.5 ether}(param);

        uint256 expectedUniqueId = uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset)));
        (uint256 uniqueId, uint64 endTime, uint192 nonce) = center.symbolRegistry(param.symbol);
        assertEq(uniqueId, expectedUniqueId);
        assertEq(endTime, uint64(block.timestamp + param.durationDays * center.DAY()));
        assertEq(nonce, 1);

        assertEq(registrar.lastUniqueId(), expectedUniqueId);
        assertEq(registrar.lastUAsset(), param.uAsset);
        assertEq(registrar.lastFlashGenesis(), param.flashGenesis);
        assertEq(registrar.lastEndTime(), uint64(block.timestamp + param.durationDays * center.DAY()));
        assertEq(registrar.lastUnlockTime(), uint64(block.timestamp + param.durationDays * center.DAY() + 365 days));
        assertEq(endpoint.lastDstEid(), REMOTE_EID);
        assertEq(endpoint.lastRefundAddress(), address(center));
        assertEq(endpoint.lastSendValue(), 0.5 ether);
    }

    /// @notice Test local-only registration never hits remote quote/send paths.
    function testRegistrationSkipsRemoteQuoteAndSendForLocalOnlyTargets() external {
        endpoint.setQuoteBlocked(true);
        endpoint.setSendBlocked(true);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _localOnlyRegistrationParam();

        center.registration(param);

        assertEq(registrar.lastUAsset(), param.uAsset);
        assertEq(registrar.lastName(), param.name);
        assertEq(registrar.lastSymbol(), param.symbol);
        assertEq(endpoint.lastDstEid(), 0);
        assertEq(endpoint.lastSendValue(), 0);
        assertEq(address(center).balance, 0);
    }

    /// @notice Test registration accepts native refunds sent back to the center contract.
    /// @dev Confirms remote endpoint refunds no longer revert when the center is the refund target.
    function testRegistrationAcceptsRemoteNativeRefundsAtCenter() external {
        endpoint.setQuotedNativeFee(0.4 ether);
        endpoint.setActualNativeFee(0.35 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        center.registration{value: 0.4 ether}(param);

        assertEq(endpoint.lastRefundAddress(), address(center));
        assertEq(endpoint.lastSendValue(), 0.4 ether);
        assertEq(endpoint.lastRefundedNative(), 0.05 ether);
        assertEq(address(center).balance, 0.05 ether);
    }

    /// @notice Test a direct plain-ETH send to the raw implementation reverts and bounces the funds back.
    /// @dev The implementation lives at a deterministic, publicly derivable address with a permanently
    ///      zero owner (`_disableInitializers`), so ETH landing there could never be swept via the
    ///      owner-only `removeGasDust`. The inherited `DelegatecallOnly.onlyDelegatecall` guard makes the
    ///      send revert instead of stranding the ETH.
    function testReceiveRevertsOnDirectPlainSendToTheImplementation() external {
        MemeverseRegistrationCenterUpgradeable implementation =
            new MemeverseRegistrationCenterUpgradeable(address(endpoint));
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(implementation).call{value: 1 ether}("");

        assertFalse(ok);
        assertEq(address(this).balance, 1 ether, "misdirected ETH must bounce back to the sender");
        assertEq(address(implementation).balance, 0);
    }

    /// @notice Test a plain-ETH send to the proxy still lands (the LayerZero refund acceptance path).
    /// @dev Refunds arrive at the proxy as empty-calldata value calls; under the delegatecall
    ///      `address(this)` is the proxy (not the implementation's `_SELF`), so the `onlyDelegatecall`
    ///      guard passes and the refund acceptance pinned by
    ///      `testRegistrationAcceptsRemoteNativeRefundsAtCenter` is preserved.
    function testReceiveAcceptsPlainNativeSendAtTheProxy() external {
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(center).call{value: 1 ether}("");

        assertTrue(ok);
        assertEq(address(center).balance, 1 ether);

        vm.prank(OWNER);
        center.removeGasDust(OWNER);
        assertEq(address(center).balance, 0);
    }

    /// @notice Test registration increments nonce and changes unique id on re-registration.
    function testRegistrationIncrementsNonceAndChangesUniqueIdOnReregistration() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        center.registration{value: 0.5 ether}(param);
        (uint256 firstUniqueId, uint64 firstEndTime, uint192 firstNonce) = center.symbolRegistry(param.symbol);

        assertEq(firstUniqueId, uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset))));
        assertEq(firstNonce, 1);

        vm.warp(firstEndTime + 1);
        center.registration{value: 0.5 ether}(param);

        (uint256 secondUniqueId,, uint192 secondNonce) = center.symbolRegistry(param.symbol);
        (uint256 historyUniqueId, uint64 historyEndTime, uint192 historyNonce) =
            center.symbolHistory(param.symbol, firstUniqueId);

        assertEq(secondUniqueId, uint256(keccak256(abi.encodePacked(param.symbol, uint192(2), param.uAsset))));
        assertTrue(secondUniqueId != firstUniqueId);
        assertEq(secondNonce, 2);
        assertEq(historyUniqueId, firstUniqueId);
        assertEq(historyEndTime, firstEndTime);
        assertEq(historyNonce, 1);
    }

    /// @notice Test registration rejects invalid params and stores prior registration in history.
    function testRegistrationRejectsInvalidParamsAndStoresPriorRegistrationInHistory() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        param.durationDays = 11;
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidDurationDays.selector);
        center.registration(param);

        param = _registrationParam();
        param.uAsset = address(0x9999);
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidUAsset.selector);
        center.registration(param);

        param = _registrationParam();
        param.name = "";
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidLength.selector);
        center.registration(param);

        param = _registrationParam();
        param.symbol = "";
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidLength.selector);
        center.registration(param);

        param = _registrationParam();
        param.uri = "";
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidLength.selector);
        center.registration(param);

        param = _registrationParam();
        param.desc = "";
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidLength.selector);
        center.registration(param);

        param = _registrationParam();
        param.omnichainIds = new uint32[](0);
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidLength.selector);
        center.registration(param);

        param = _registrationParam();
        center.registration{value: 0.5 ether}(param);
        (uint256 firstUniqueId, uint64 firstEndTime, uint192 firstNonce) = center.symbolRegistry(param.symbol);
        assertEq(firstNonce, 1);

        vm.warp(firstEndTime + 1);
        center.registration{value: 0.5 ether}(param);

        (uint256 currentUniqueId,,) = center.symbolRegistry(param.symbol);
        (uint256 historyUniqueId, uint64 historyEndTime, uint192 historyNonce) =
            center.symbolHistory(param.symbol, firstUniqueId);
        assertTrue(currentUniqueId != 0);
        assertTrue(currentUniqueId != firstUniqueId);
        assertEq(historyUniqueId, firstUniqueId);
        assertEq(historyEndTime, firstEndTime);
        assertEq(historyNonce, 1);

        (, uint64 currentEndTime,) = center.symbolRegistry(param.symbol);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseRegistrationCenter.SymbolNotUnlock.selector, uint256(currentEndTime))
        );
        center.registration(param);
    }

    /// @notice Test registration rejects windows that would overflow uint64 when applying the fixed lockup.
    function testRegistrationRevertsWhenFixedUnlockTimeOverflowsUint64() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        vm.warp(type(uint64).max - 365 days - center.DAY() + 1);
        vm.expectRevert(IMemeverseRegistrationCenter.InvalidInput.selector);
        center.registration{value: 0.5 ether}(param);
    }

    /// @notice Test registration deduplicates omnichain ids and requires enough fee.
    function testRegistrationDeduplicatesOmnichainIdsAndRequiresEnoughFee() external {
        endpoint.setQuotedNativeFee(0.5 ether);
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        param.omnichainIds = new uint32[](3);
        param.omnichainIds[0] = uint32(block.chainid);
        param.omnichainIds[1] = REMOTE_CHAIN_ID;
        param.omnichainIds[2] = REMOTE_CHAIN_ID;

        vm.expectRevert(IMemeverseRegistrationCenter.InsufficientLzFee.selector);
        center.registration(param);

        center.registration{value: 0.5 ether}(param);
        assertEq(endpoint.lastDstEid(), REMOTE_EID);
    }

    /// @notice Test lz receive from registrar sender triggers registration.
    function testLzReceiveFromRegistrarSenderTriggersRegistration() external {
        IMemeverseRegistrationCenter.RegistrationParam memory param = _localOnlyRegistrationParam();
        Origin memory origin =
            Origin({srcEid: SOURCE_EID, sender: bytes32(uint256(uint160(address(registrar)))), nonce: 1});

        vm.prank(address(endpoint));
        center.lzReceive(origin, bytes32("guid"), abi.encode(param), address(0), "");

        assertEq(registrar.lastUAsset(), param.uAsset);
        assertEq(registrar.lastName(), param.name);
        assertEq(registrar.lastSymbol(), param.symbol);
    }

    /// @notice Test lz receive rejects unexpected sender and lz send is self only.
    function testLzReceiveRejectsUnexpectedSenderAndLzSendIsSelfOnly() external {
        IMemeverseRegistrationCenter.RegistrationParam memory param = _localOnlyRegistrationParam();
        vm.prank(OWNER);
        center.setPeer(SOURCE_EID, bytes32(uint256(uint160(address(0x1234)))));
        Origin memory badOrigin =
            Origin({srcEid: SOURCE_EID, sender: bytes32(uint256(uint160(address(0x1234)))), nonce: 1});

        vm.prank(address(endpoint));
        vm.expectRevert(IMemeverseRegistrationCenter.PermissionDenied.selector);
        center.lzReceive(badOrigin, bytes32("guid"), abi.encode(param), address(0), "");

        vm.expectRevert(IMemeverseRegistrationCenter.PermissionDenied.selector);
        center.lzSend(
            REMOTE_EID, bytes("msg"), bytes("opts"), MessagingFee({nativeFee: 0, lzTokenFee: 0}), address(this)
        );
    }

    /// @notice Test remove gas dust owner path transfers balance.
    function testRemoveGasDustOwnerPathTransfersBalance() external {
        vm.deal(address(center), 1 ether);
        uint256 before = OWNER.balance;

        vm.prank(OWNER);
        center.removeGasDust(OWNER);

        assertEq(OWNER.balance - before, 1 ether);
        assertEq(address(center).balance, 0);
    }

    /// @notice Test initialize rejects zero registrar or zero registry pointers.
    /// @dev initialize runs inside the ERC1967Proxy constructor, so the reverting initializer fails the
    ///      proxy deploy itself.
    function testInitializeRejectsZeroRegistrarAndRegistry() external {
        MemeverseRegistrationCenterUpgradeable implementation =
            new MemeverseRegistrationCenterUpgradeable(address(endpoint));

        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(MemeverseRegistrationCenterUpgradeable.initialize, (OWNER, address(0), address(registry)))
        );

        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(MemeverseRegistrationCenterUpgradeable.initialize, (OWNER, address(registrar), address(0)))
        );
    }

    /// @notice Test the implementation constructor rejects a zero endpoint with the named error.
    /// @dev OAppCoreUpgradeable's own constructor does not zero-check; without this guard a zero endpoint
    ///      would only surface at initialize's setDelegate CALL with an opaque revert.
    function testConstructorRejectsZeroEndpoint() external {
        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        new MemeverseRegistrationCenterUpgradeable(address(0));
    }

    /// @notice Test initialize cannot run twice on the proxy (OZ initializer guard).
    function testInitializeCannotBeReRunOnTheProxy() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        center.initialize(OWNER, address(registrar), address(registry));
    }

    /// @notice Test initialize registers the owner as the endpoint delegate keyed by the proxy address.
    /// @dev SECR-001 adjudication: initialize runs inside the ERC1967Proxy constructor delegatecall, so
    ///      `__OApp_init`'s `endpoint.setDelegate(_owner)` CALL executes with msg.sender == the proxy
    ///      (address(this) of the delegatecall frame), not the implementation or any deploy factory. The
    ///      mock keys `delegates` by caller, so this assertion fails under any other keying.
    function testInitializeRegistersOwnerAsEndpointDelegate() external {
        assertEq(endpoint.delegates(address(center)), OWNER, "delegate must be keyed by the proxy address");
    }

    /// @notice Test owner-upgraded V2 shell keeps every namespaced storage slot intact.
    /// @dev The V2 shell (test/mocks/upgrade) has no getters, so post-upgrade state is proven by raw
    ///      `vm.load` reads on the erc7201("outrun.storage.MemeverseRegistrationCenter") namespace. The
    ///      pre-upgrade `vm.load` assertions double as a self-check of the slot math: a wrong base slot or
    ///      mapping-key formula would fail them before the upgrade ever runs.
    function testUpgradeToV2ShellPreservesNamespacedStorage() external {
        // Known state: one local-only registration plus the setUp config vars.
        IMemeverseRegistrationCenter.RegistrationParam memory param = _localOnlyRegistrationParam();
        center.registration(param);
        uint256 expectedUniqueId = uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset)));
        (uint256 uniqueId, uint64 endTime, uint192 nonce) = center.symbolRegistry(param.symbol);
        assertEq(uniqueId, expectedUniqueId);
        assertEq(nonce, 1);

        // ERC-7201 base slot: keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(uint256(0xff)).
        bytes32 baseSlot = _centerStorageBaseSlot();
        // Scalar fields: memeverseRegistrar(+0), lzEndpointRegistry(+1), min/maxDurationDays packed(+2),
        // registerGasLimit(+3).
        assertEq(vm.load(address(center), baseSlot), bytes32(uint256(uint160(address(registrar)))));
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 1)), bytes32(uint256(uint160(address(registry)))));
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 2)), bytes32(uint256(1) | (uint256(10) << 128)));
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 3)), bytes32(uint256(150)));
        // symbolRegistry lives at +4; a string key hashes via its unpadded bytes (Solidity storage layout),
        // and the SymbolRegistration struct packs endTime (low 8 bytes) with nonce (high 24 bytes) one slot
        // past uniqueId.
        bytes32 symbolSlot = keccak256(abi.encodePacked(bytes(param.symbol), bytes32(uint256(baseSlot) + 4)));
        assertEq(vm.load(address(center), symbolSlot), bytes32(expectedUniqueId));
        assertEq(
            vm.load(address(center), bytes32(uint256(symbolSlot) + 1)),
            bytes32(uint256(endTime) | (uint256(uint192(1)) << 64))
        );

        // Capture the six observed words: post-upgrade assertions compare against these captures, so the
        // config literals above stay maintained exactly once, in the pre-upgrade block.
        bytes32 registrarSlotValue = vm.load(address(center), baseSlot);
        bytes32 registrySlotValue = vm.load(address(center), bytes32(uint256(baseSlot) + 1));
        bytes32 durationLimitsSlotValue = vm.load(address(center), bytes32(uint256(baseSlot) + 2));
        bytes32 registerGasLimitSlotValue = vm.load(address(center), bytes32(uint256(baseSlot) + 3));
        bytes32 uniqueIdSlotValue = vm.load(address(center), symbolSlot);
        bytes32 endTimeNonceSlotValue = vm.load(address(center), bytes32(uint256(symbolSlot) + 1));

        // Owner upgrades to the shell constructed with the SAME endpoint; the V1 guard runs during the jump.
        MemeverseRegistrationCenterUpgradeableV2 shell = new MemeverseRegistrationCenterUpgradeableV2(address(endpoint));
        vm.prank(OWNER);
        center.upgradeToAndCall(address(shell), "");

        assertEq(MemeverseRegistrationCenterUpgradeableV2(address(center)).upgradeVersion(), 2);
        // Storage preserved: post-upgrade slots equal the captured pre-upgrade words.
        assertEq(vm.load(address(center), baseSlot), registrarSlotValue);
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 1)), registrySlotValue);
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 2)), durationLimitsSlotValue);
        assertEq(vm.load(address(center), bytes32(uint256(baseSlot) + 3)), registerGasLimitSlotValue);
        assertEq(vm.load(address(center), symbolSlot), uniqueIdSlotValue);
        assertEq(vm.load(address(center), bytes32(uint256(symbolSlot) + 1)), endTimeNonceSlotValue);
    }

    /// @notice Test upgradeToAndCall reverts for a non-owner.
    function testUpgradeToAndCallRevertsForNonOwner() external {
        MemeverseRegistrationCenterUpgradeableV2 shell = new MemeverseRegistrationCenterUpgradeableV2(address(endpoint));
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        center.upgradeToAndCall(address(shell), "");
    }

    /// @notice Test upgradeToAndCall reverts on a no-code target with the named guard error.
    function testUpgradeToAndCallRevertsOnNoCodeTarget() external {
        address codeless = makeAddr("codeless-upgrade-target");
        assertTrue(codeless.code.length == 0);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseRegistrationCenter.UpgradeTargetCodeNotReady.selector, codeless)
        );
        center.upgradeToAndCall(codeless, "");
    }

    /// @notice Test upgradeToAndCall reverts when the shell was constructed with a different endpoint.
    function testUpgradeToAndCallRevertsOnEndpointMismatch() external {
        MockCenterEndpoint otherEndpoint = new MockCenterEndpoint();
        MemeverseRegistrationCenterUpgradeableV2 wrongShell =
            new MemeverseRegistrationCenterUpgradeableV2(address(otherEndpoint));

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemeverseRegistrationCenter.UpgradeEndpointMismatch.selector, address(endpoint), address(otherEndpoint)
            )
        );
        center.upgradeToAndCall(address(wrongShell), "");
    }

    /// @notice Test upgradeToAndCall reverts with the named guard error when the target has code but no
    ///         `endpoint()` getter at all.
    /// @dev LR-001 coverage: the `_authorizeUpgrade` probe's catch branch must fold this honest-failure
    ///      class into `UpgradeEndpointUnreadable` so the upgrade still fails closed with a greppable
    ///      label instead of a bare revert.
    function testUpgradeRevertsWhenEndpointGetterMissing() external {
        EndpointGetterMissingShell shell = new EndpointGetterMissingShell();

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseRegistrationCenter.UpgradeEndpointUnreadable.selector, address(shell))
        );
        center.upgradeToAndCall(address(shell), "");
    }

    /// @notice Test upgradeToAndCall reverts with the named guard error when the target's `endpoint()`
    ///         getter exists but reverts.
    /// @dev LR-001 coverage: second catch-branch input — a reverting getter must fail closed through the
    ///      same `UpgradeEndpointUnreadable` label, not surface the getter's own error.
    function testUpgradeRevertsWhenEndpointGetterReverts() external {
        EndpointGetterRevertingShell shell = new EndpointGetterRevertingShell();

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IMemeverseRegistrationCenter.UpgradeEndpointUnreadable.selector, address(shell))
        );
        center.upgradeToAndCall(address(shell), "");
    }

    /// @notice Test upgradeToAndCall still fails closed when the target's `endpoint()` getter succeeds but
    ///         returns undecodable (empty) data.
    /// @dev Semantic boundary of the catch branch, pinned as an executable negative-space assertion: the
    ///      raw low-level call must revert while its revert selector must NOT equal
    ///      `UpgradeEndpointUnreadable` — Solidity try/catch does not catch "call succeeded but return
    ///      data cannot be ABI-decoded", so that class bubbles up as the raw decode revert instead of the
    ///      named error; the upgrade is still rejected (fail-closed holds, only the label differs; see
    ///      `_authorizeUpgrade`'s dev note and the `UpgradeEndpointUnreadable` doc comment on the
    ///      interface). If the probe is ever rewritten as a manual staticcall that folds decode failure
    ///      into the named error, this test fails and flags those two docs (plus this comment) as stale.
    ///      A bare `vm.expectRevert()` matches any revert, so it cannot distinguish the two labels.
    ///      `bytes4(ret)` zero-pads returndata shorter than 4 bytes, keeping the selector comparison
    ///      safe for any revert payload shape.
    function testUpgradeRevertsWhenEndpointGetterReturnsUndecodableData() external {
        EndpointGetterEmptyReturnShell shell = new EndpointGetterEmptyReturnShell();

        // Owner prank is load-bearing: without it the call dies at `onlyOwner` before the probe and the
        // negative-space assertion below would pass vacuously.
        vm.prank(OWNER);
        (bool ok, bytes memory ret) =
            address(center).call(abi.encodeCall(center.upgradeToAndCall, (address(shell), "")));

        assertFalse(ok, "undecodable getter returndata must still reject the upgrade (fail-closed)");
        assertFalse(
            bytes4(ret) == IMemeverseRegistrationCenter.UpgradeEndpointUnreadable.selector,
            "decode failure must bubble up as the raw decode revert, not fold into the named error"
        );
    }

    /// @notice Test renounceOwnership is permanently disabled (never-renounceable repo invariant).
    /// @dev The error is declared on the shared `OutrunOAppUpgradeable` base (single declaration —
    ///      re-declaring it on the interface alongside the inherited base copy is compile Error 9097);
    ///      qualified error lookup resolves on the declaring contract, hence the base-qualified selector.
    function testRenounceOwnershipIsDisabled() external {
        vm.prank(OWNER);
        vm.expectRevert(OutrunOAppUpgradeable.OwnershipRenounceDisabled.selector);
        center.renounceOwnership();
    }

    /// @notice Test registrar-pointer replacement unlocks the local path immediately and pairs with
    ///         `setPeer` for inbound (LR-003 deadlock unlock).
    /// @dev The local-chain `localRegistration` callback follows the storage pointer alone; inbound
    ///      `_lzReceive` additionally passes the OApp base's peer check first, so re-pointing inbound
    ///      traffic requires the paired `setPeer`. The intermediate state (pointer moved, peer still old)
    ///      must fail closed on BOTH origins.
    function testSetMemeverseRegistrarUnlocksLocalPathAndPairsWithSetPeerForInbound() external {
        MockCenterRegistrar newRegistrar = new MockCenterRegistrar();

        // Zero address and non-owner calls are rejected.
        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrationCenter.ZeroInput.selector);
        center.setMemeverseRegistrar(address(0));

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        center.setMemeverseRegistrar(address(newRegistrar));

        // The setter emits old + new pointers.
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit IMemeverseRegistrationCenter.SetMemeverseRegistrar(address(registrar), address(newRegistrar));
        center.setMemeverseRegistrar(address(newRegistrar));

        // Local-chain path: a local-only registration now records on the NEW registrar mock; the old mock
        // was never called (setUp only wires it, no registration ran against it).
        IMemeverseRegistrationCenter.RegistrationParam memory param = _localOnlyRegistrationParam();
        center.registration(param);
        assertEq(newRegistrar.lastSymbol(), param.symbol);
        assertEq(newRegistrar.lastUAsset(), param.uAsset);
        assertEq(registrar.lastSymbol(), "");

        // Intermediate fail-closed state, side 1: inbound from the OLD origin passes the peer check (the
        // peer is still the old registrar) but dies at `_lzReceive`'s storage-pointer check.
        Origin memory oldOrigin =
            Origin({srcEid: SOURCE_EID, sender: bytes32(uint256(uint160(address(registrar)))), nonce: 1});
        vm.prank(address(endpoint));
        vm.expectRevert(IMemeverseRegistrationCenter.PermissionDenied.selector);
        center.lzReceive(oldOrigin, bytes32("guid"), abi.encode(param), address(0), "");

        // Intermediate fail-closed state, side 2: inbound from the NEW origin dies at the OApp base's
        // peer check — the pointer moved but the peer did not.
        Origin memory newOrigin =
            Origin({srcEid: SOURCE_EID, sender: bytes32(uint256(uint160(address(newRegistrar)))), nonce: 2});
        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, SOURCE_EID, newOrigin.sender));
        center.lzReceive(newOrigin, bytes32("guid"), abi.encode(param), address(0), "");

        // Paired setPeer completes the runbook: inbound from the NEW origin now registers (fresh symbol,
        // since the local-path registration above locked the previous one).
        vm.prank(OWNER);
        center.setPeer(SOURCE_EID, bytes32(uint256(uint160(address(newRegistrar)))));
        param.symbol = "INBOUND";
        vm.prank(address(endpoint));
        center.lzReceive(newOrigin, bytes32("guid"), abi.encode(param), address(0), "");

        assertEq(newRegistrar.lastSymbol(), "INBOUND");
        assertEq(newRegistrar.lastUAsset(), param.uAsset);
    }

    /// @notice ERC-7201 base slot of the center's namespaced storage.
    function _centerStorageBaseSlot() internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256("outrun.storage.MemeverseRegistrationCenter")) - 1))
            & ~bytes32(uint256(0xff));
    }

    function _registrationParam() internal view returns (IMemeverseRegistrationCenter.RegistrationParam memory param) {
        param.name = "CenterVerse";
        param.symbol = "CNTR";
        param.uri = "ipfs://center";
        param.desc = "Center desc";
        param.communities = new string[](1);
        param.communities[0] = "https://center.example";
        param.durationDays = 3;
        param.omnichainIds = new uint32[](2);
        param.omnichainIds[0] = uint32(block.chainid);
        param.omnichainIds[1] = REMOTE_CHAIN_ID;
        param.uAsset = address(0x7777);
        param.flashGenesis = true;
    }

    function _localOnlyRegistrationParam()
        internal
        view
        returns (IMemeverseRegistrationCenter.RegistrationParam memory param)
    {
        param = _registrationParam();
        param.symbol = "LCL";
        param.omnichainIds = new uint32[](1);
        param.omnichainIds[0] = uint32(block.chainid);
    }

    function _endpointPairs() internal pure returns (ILzEndpointRegistry.LzEndpointIdPair[] memory pairs) {
        pairs = new ILzEndpointRegistry.LzEndpointIdPair[](1);
        pairs[0] = ILzEndpointRegistry.LzEndpointIdPair({chainId: REMOTE_CHAIN_ID, endpointId: REMOTE_EID});
    }
}
