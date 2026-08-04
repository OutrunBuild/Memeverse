// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import {IOFTCompose} from "../../src/common/omnichain/oft/IOFTCompose.sol";
import {IBurnable} from "../../src/common/interfaces/IBurnable.sol";
import {YieldDispatcher} from "../../src/verse/YieldDispatcher.sol";
import {IYieldDispatcher} from "../../src/verse/interfaces/IYieldDispatcher.sol";
import {IMemeverseOFTEnum} from "../../src/common/types/IMemeverseOFTEnum.sol";

contract MockDispatcherComposeToken is MockERC20, IOFTCompose, IBurnable {
    mapping(bytes32 guid => bool executed) internal executedStatus;
    bytes32 public lastNotifiedGuid;
    uint256 public lastBurnAmount;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    /// @notice Get compose tx executed status.
    /// @param guid See implementation.
    /// @return See implementation.
    function getComposeTxExecutedStatus(bytes32 guid) external view returns (bool) {
        return executedStatus[guid];
    }

    /// @notice Notify compose executed.
    /// @param guid See implementation.
    function notifyComposeExecuted(bytes32 guid) external {
        executedStatus[guid] = true;
        lastNotifiedGuid = guid;
    }

    /// @notice Withdraw if not executed.
    /// @param guid See implementation.
    /// @param account See implementation.
    /// @return See implementation.
    function withdrawIfNotExecuted(bytes32 guid, address account) external pure returns (uint256) {
        guid;
        account;
        revert("unused");
    }

    /// @notice Burn.
    /// @param amount See implementation.
    function burn(uint256 amount) external {
        lastBurnAmount = amount;
        _burn(msg.sender, amount);
    }

    /// @notice Set executed.
    /// @param guid See implementation.
    /// @param executed See implementation.
    function setExecuted(bytes32 guid, bool executed) external {
        executedStatus[guid] = executed;
    }
}

contract MockDispatcherYieldVault {
    uint256 public lastAccumulatedAmount;

    /// @notice Accumulate yields.
    /// @param amount See implementation.
    function accumulateYields(uint256 amount) external {
        lastAccumulatedAmount = amount;
    }
}

contract MockDispatcherGovernor {
    address public lastToken;
    uint256 public lastAmount;

    /// @notice Receive treasury income.
    /// @param token See implementation.
    /// @param amount See implementation.
    function receiveTreasuryIncome(address token, uint256 amount) external {
        lastToken = token;
        lastAmount = amount;
    }
}

contract YieldDispatcherTest is Test {
    using OFTComposeMsgCodec for bytes;

    address internal constant OWNER = address(0xABCD);
    address internal constant LOCAL_ENDPOINT = address(0x1111);
    address internal constant LAUNCHER = address(0x2222);
    address internal constant ALICE = address(0xA11CE);

    YieldDispatcher internal dispatcher;
    MockDispatcherComposeToken internal token;
    MockDispatcherYieldVault internal yieldVault;
    MockDispatcherGovernor internal governor;

    /// @notice Set up.
    function setUp() external {
        dispatcher = new YieldDispatcher(OWNER, LOCAL_ENDPOINT, LAUNCHER);
        token = new MockDispatcherComposeToken("Compose Token", "CMP");
        yieldVault = new MockDispatcherYieldVault();
        governor = new MockDispatcherGovernor();
    }

    /// @notice Test lz compose rejects unauthorized caller.
    function testLzComposeRejectsUnauthorizedCaller() external {
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.lzCompose(address(token), bytes32(0), "", address(0), "");
    }

    /// @notice Test lz compose rejects the launcher now that the compose entry is endpoint-only.
    function testLzComposeRejectsLauncherCaller() external {
        bytes memory message = abi.encode(ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, 1 ether);
        vm.prank(LAUNCHER);
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.lzCompose(address(token), bytes32("launcher-guid"), message, address(0), "");
    }

    /// @notice Test same-chain path rejects any caller other than the launcher.
    function testDistributeSameChainRejectsNonLauncherCaller() external {
        vm.expectRevert(IYieldDispatcher.PermissionDenied.selector);
        dispatcher.distributeSameChain(address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, 1 ether);
    }

    /// @notice Test same-chain path rejects an out-of-range token type instead of silently no-oping.
    function testDistributeSameChainRevertsOnInvalidTokenType() external {
        // Out-of-range tokenType (uint8 = 2; enum only defines UASSET=0/MEMECOIN=1). Hand-build
        // calldata to bypass the compile-time enum bounds check. Solidity's ABI decoder rejects
        // out-of-range enum values before _settle runs; _settle's `else revert InvalidTokenType()`
        // is a defense-in-depth backstop in case the decoder ever lets one through. Either way the
        // call must fail rather than silently succeed and strand funds.
        bytes memory callData = bytes.concat(
            IYieldDispatcher.distributeSameChain.selector, abi.encode(address(token), ALICE, uint8(2), uint256(1 ether))
        );

        vm.prank(LAUNCHER);
        (bool ok,) = address(dispatcher).call(callData);

        assertFalse(ok, "out-of-range tokenType must not silently succeed");
    }

    /// @notice Test same-chain path burns memecoin for eoa receiver.
    function testDistributeSameChainBurnsMemecoinForEoaReceiver() external {
        uint256 amount = 5 ether;
        token.mint(address(dispatcher), amount);

        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(address(token), ALICE, IMemeverseOFTEnum.TokenType.MEMECOIN, amount);

        assertEq(token.lastBurnAmount(), amount);
        assertEq(token.balanceOf(address(dispatcher)), 0);
    }

    /// @notice Test same-chain path approves exactly the amount and calls receivers.
    function testDistributeSameChainApprovesExactAmountAndCallsReceivers() external {
        uint256 memeAmount = 7 ether;
        uint256 uAssetAmount = 11 ether;
        token.mint(address(dispatcher), memeAmount + uAssetAmount);

        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(
            address(token), address(yieldVault), IMemeverseOFTEnum.TokenType.MEMECOIN, memeAmount
        );
        assertEq(yieldVault.lastAccumulatedAmount(), memeAmount);
        assertEq(token.allowance(address(dispatcher), address(yieldVault)), memeAmount);

        vm.prank(LAUNCHER);
        dispatcher.distributeSameChain(
            address(token), address(governor), IMemeverseOFTEnum.TokenType.UASSET, uAssetAmount
        );
        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), uAssetAmount);
        assertEq(token.allowance(address(dispatcher), address(governor)), uAssetAmount);
    }

    /// @notice Test local endpoint path rejects already executed compose.
    function testLocalEndpointPathRejectsAlreadyExecutedCompose() external {
        bytes32 guid = bytes32("done");
        token.setExecuted(guid, true);
        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), abi.encode(address(governor), IMemeverseOFTEnum.TokenType.UASSET)
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, 1 ether, composeMessage);

        vm.prank(LOCAL_ENDPOINT);
        vm.expectRevert(IYieldDispatcher.AlreadyExecuted.selector);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");
    }

    /// @notice Test local endpoint path marks compose executed and routes funds.
    function testLocalEndpointPathMarksComposeExecutedAndRoutesFunds() external {
        bytes32 guid = bytes32("new");
        uint256 amount = 9 ether;
        token.mint(address(dispatcher), amount);

        bytes memory composeMessage = abi.encodePacked(
            bytes32(uint256(uint160(ALICE))), abi.encode(address(governor), IMemeverseOFTEnum.TokenType.UASSET)
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMessage);

        vm.prank(LOCAL_ENDPOINT);
        dispatcher.lzCompose(address(token), guid, message, address(0), "");

        assertEq(token.lastNotifiedGuid(), guid);
        assertTrue(token.getComposeTxExecutedStatus(guid));
        assertEq(governor.lastToken(), address(token));
        assertEq(governor.lastAmount(), amount);
    }
}
