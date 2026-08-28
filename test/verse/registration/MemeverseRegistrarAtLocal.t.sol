// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MemeverseRegistrarAbstract} from "../../../src/verse/registration/MemeverseRegistrarAbstract.sol";
import {MemeverseRegistrarAtLocal} from "../../../src/verse/registration/MemeverseRegistrarAtLocal.sol";
import {IMemeverseRegistrar} from "../../../src/verse/interfaces/IMemeverseRegistrar.sol";
import {IMemeverseRegistrarAtLocal} from "../../../src/verse/interfaces/IMemeverseRegistrarAtLocal.sol";
import {IMemeverseRegistrationCenter} from "../../../src/verse/interfaces/IMemeverseRegistrationCenter.sol";

contract MockAtLocalRegistrationCenter {
    uint256 public quotedFee;
    address public lastRegistrationUAsset;
    bool public lastRegistrationFlashGenesis;
    uint256 public lastRegistrationValue;

    function DAY() external pure returns (uint256) {
        return 180;
    }

    function symbolRegistry(string calldata) external pure returns (uint256 uniqueId, uint64 endTime, uint192 nonce) {
        uniqueId;
        endTime;
        nonce = 0;
    }

    /// @notice Set quoted fee.
    /// @param fee See implementation.
    function setQuotedFee(uint256 fee) external {
        quotedFee = fee;
    }

    /// @notice Quote send.
    /// @param omnichainIds See implementation.
    /// @return totalFee See implementation.
    /// @return fees See implementation.
    /// @return eids See implementation.
    function quoteSend(uint32[] memory omnichainIds, bytes memory)
        external
        view
        returns (uint256 totalFee, uint256[] memory fees, uint32[] memory eids)
    {
        totalFee = quotedFee;
        fees = new uint256[](omnichainIds.length);
        eids = omnichainIds;
    }

    /// @notice Registration.
    /// @param param See implementation.
    function registration(IMemeverseRegistrationCenter.RegistrationParam calldata param) external payable {
        require(msg.value >= quotedFee, IMemeverseRegistrationCenter.InsufficientLzFee());
        lastRegistrationUAsset = param.uAsset;
        lastRegistrationFlashGenesis = param.flashGenesis;
        lastRegistrationValue = msg.value;
    }
}

contract MockAtLocalLauncher {
    uint256 public lastRegisteredUniqueId;
    address public lastRegisteredUAsset;
    bool public lastRegisteredFlashGenesis;
    uint256 public lastExternalInfoUniqueId;
    string public lastUri;
    string public lastDesc;
    string[] public lastCommunities;

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
    /// @param desc See implementation.
    /// @param communities See implementation.
    function setExternalInfo(uint256 uniqueId, string memory uri, string memory desc, string[] memory communities)
        external
    {
        lastExternalInfoUniqueId = uniqueId;
        lastUri = uri;
        lastDesc = desc;
        lastCommunities = communities;
    }

    /// @notice Community.
    /// @param index See implementation.
    /// @return See implementation.
    function community(uint256 index) external view returns (string memory) {
        return lastCommunities[index];
    }
}

contract MemeverseRegistrarAtLocalTest is Test {
    address internal constant OWNER = address(0xABCD);
    address internal constant OTHER = address(0xCAFE);

    MockAtLocalRegistrationCenter internal registrationCenter;
    MockAtLocalLauncher internal launcher;
    MemeverseRegistrarAtLocal internal registrar;

    /// @notice Set up.
    function setUp() external {
        registrationCenter = new MockAtLocalRegistrationCenter();
        launcher = new MockAtLocalLauncher();
        registrar =
            new MemeverseRegistrarAtLocal(OWNER, address(registrationCenter), address(launcher), address(0x1234));
    }

    /// @notice Test quote register builds memeverse param and returns center quote.
    function testQuoteRegisterBuildsMemeverseParamAndReturnsCenterQuote() external {
        registrationCenter.setQuotedFee(99 ether);

        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        uint64 expectedEndTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY());
        uint64 expectedUnlockTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY() + 365 days);
        IMemeverseRegistrar.MemeverseParam memory expectedMemeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset))),
            endTime: expectedEndTime,
            unlockTime: expectedUnlockTime,
            omnichainIds: param.omnichainIds,
            uAsset: param.uAsset,
            flashGenesis: param.flashGenesis
        });

        vm.expectCall(
            address(registrationCenter),
            abi.encodeWithSelector(
                MockAtLocalRegistrationCenter.quoteSend.selector, param.omnichainIds, abi.encode(expectedMemeverseParam)
            )
        );
        uint256 quoted = registrar.quoteRegister(param, 0);

        assertEq(quoted, 99 ether);
    }

    /// @notice Test quote register deduplicates omnichain ids before quoting the center.
    function testQuoteRegisterDeduplicatesOmnichainIds() external {
        registrationCenter.setQuotedFee(88 ether);

        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        param.omnichainIds = new uint32[](3);
        param.omnichainIds[0] = uint32(block.chainid);
        param.omnichainIds[1] = 101;
        param.omnichainIds[2] = 101;

        uint32[] memory expectedIds = new uint32[](2);
        expectedIds[0] = uint32(block.chainid);
        expectedIds[1] = 101;
        uint64 expectedEndTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY());
        uint64 expectedUnlockTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY() + 365 days);
        IMemeverseRegistrar.MemeverseParam memory expectedMemeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset))),
            endTime: expectedEndTime,
            unlockTime: expectedUnlockTime,
            omnichainIds: expectedIds,
            uAsset: param.uAsset,
            flashGenesis: param.flashGenesis
        });

        vm.expectCall(
            address(registrationCenter),
            abi.encodeWithSelector(
                MockAtLocalRegistrationCenter.quoteSend.selector, expectedIds, abi.encode(expectedMemeverseParam)
            )
        );

        assertEq(registrar.quoteRegister(param, 0), 88 ether);
    }

    /// @notice Test quote register ignores the interface value argument on the local path.
    function testQuoteRegisterIgnoresValueArgumentOnLocalPath() external {
        registrationCenter.setQuotedFee(77 ether);

        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        uint64 expectedEndTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY());
        uint64 expectedUnlockTime = uint64(block.timestamp + param.durationDays * registrationCenter.DAY() + 365 days);
        IMemeverseRegistrar.MemeverseParam memory expectedMemeverseParam = IMemeverseRegistrar.MemeverseParam({
            name: param.name,
            symbol: param.symbol,
            uri: param.uri,
            desc: param.desc,
            communities: param.communities,
            uniqueId: uint256(keccak256(abi.encodePacked(param.symbol, uint192(1), param.uAsset))),
            endTime: expectedEndTime,
            unlockTime: expectedUnlockTime,
            omnichainIds: param.omnichainIds,
            uAsset: param.uAsset,
            flashGenesis: param.flashGenesis
        });

        vm.expectCall(
            address(registrationCenter),
            abi.encodeWithSelector(
                MockAtLocalRegistrationCenter.quoteSend.selector, param.omnichainIds, abi.encode(expectedMemeverseParam)
            )
        );

        assertEq(registrar.quoteRegister(param, uint128(123 ether)), 77 ether);
    }

    /// @notice Test local registration only center and forwards to launcher.
    function testLocalRegistrationOnlyCenterAndForwardsToLauncher() external {
        IMemeverseRegistrar.MemeverseParam memory param = _memeverseParam();

        vm.expectRevert(IMemeverseRegistrarAtLocal.PermissionDenied.selector);
        registrar.localRegistration(param);

        vm.prank(address(registrationCenter));
        registrar.localRegistration(param);

        assertEq(launcher.lastRegisteredUniqueId(), param.uniqueId);
        assertEq(launcher.lastRegisteredUAsset(), param.uAsset);
        assertEq(launcher.lastRegisteredFlashGenesis(), param.flashGenesis);
        assertEq(launcher.lastExternalInfoUniqueId(), param.uniqueId);
        assertEq(launcher.lastUri(), param.uri);
        assertEq(launcher.lastDesc(), param.desc);
        assertEq(launcher.community(0), "https://memeverse.example");
    }

    /// @notice Test register at center forwards value and set registration center is owner only.
    function testRegisterAtCenterForwardsValueAndSetRegistrationCenterIsOwnerOnly() external {
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();
        registrationCenter.setQuotedFee(1 ether);

        registrar.registerAtCenter{value: 1 ether}(param, uint128(1 ether));
        assertEq(registrationCenter.lastRegistrationValue(), 1 ether);
        assertEq(registrationCenter.lastRegistrationUAsset(), param.uAsset);
        assertEq(registrationCenter.lastRegistrationFlashGenesis(), param.flashGenesis);

        vm.expectRevert(IMemeverseRegistrationCenter.InvalidInput.selector);
        registrar.registerAtCenter{value: 0.9 ether}(param, uint128(1 ether));

        registrar.registerAtCenter{value: 1.1 ether}(param, uint128(1.1 ether));
        assertEq(registrationCenter.lastRegistrationValue(), 1.1 ether);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        registrar.setRegistrationCenter(address(0x9999));

        vm.prank(OWNER);
        vm.expectRevert(IMemeverseRegistrarAtLocal.ZeroAddress.selector);
        registrar.setRegistrationCenter(address(0));

        vm.prank(OWNER);
        registrar.setRegistrationCenter(address(0x9999));
        assertEq(registrar.registrationCenter(), address(0x9999));
    }

    /// @notice Test stale center quotes fail once the configured fee drifts.
    function testRegisterAtCenterRevertsWhenQuotedFeeDrifts() external {
        IMemeverseRegistrationCenter.RegistrationParam memory param = _registrationParam();

        registrationCenter.setQuotedFee(1 ether);
        uint256 quotedFee = registrar.quoteRegister(param, 0);

        registrationCenter.setQuotedFee(2 ether);

        vm.expectRevert(IMemeverseRegistrationCenter.InsufficientLzFee.selector);
        registrar.registerAtCenter{value: quotedFee}(param, uint128(quotedFee));
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
        param.symbol = "MEME";
        param.uri = "ipfs://memeverse";
        param.desc = "Memeverse desc";
        param.communities = new string[](1);
        param.communities[0] = "https://memeverse.example";
        param.durationDays = 3;
        param.omnichainIds = new uint32[](2);
        param.omnichainIds[0] = uint32(block.chainid);
        param.omnichainIds[1] = 101;
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
        param.uniqueId = 1234;
        param.endTime = uint64(block.timestamp + 3 days);
        param.unlockTime = uint64(block.timestamp + 8 days);
        param.omnichainIds = registrationParam.omnichainIds;
        param.uAsset = registrationParam.uAsset;
        param.flashGenesis = registrationParam.flashGenesis;
    }
}
