// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {MemecoinDaoGovernorUpgradeable} from "../../src/governance/MemecoinDaoGovernorUpgradeable.sol";
import {IMemecoinDaoGovernor} from "../../src/governance/interfaces/IMemecoinDaoGovernor.sol";
import {GovernanceCycleIncentivizerUpgradeable} from "../../src/governance/GovernanceCycleIncentivizerUpgradeable.sol";
import {MockGovernorVotesToken} from "../mocks/governance/GovernanceMocks.sol";

/// @title GovernorTreasuryAllowanceGuardTest
/// @notice Guards the allowance dimension of generic Governor execution: a registered treasury token may only
///         approve the paired vote token (the yield vault) as spender; any other spender reverts the execution.
contract GovernorTreasuryAllowanceGuardTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);

    MemecoinDaoGovernorUpgradeable internal governor;
    GovernanceCycleIncentivizerUpgradeable internal incentivizer;
    MockGovernorVotesToken internal votesToken;

    /// @notice Set up the real Governor/Incentivizer proxy pair with mutual wiring.
    function setUp() external {
        votesToken = new MockGovernorVotesToken();
        votesToken.setVotes(ALICE, 100 ether);

        // Deploy the incentivizer proxy uninitialized first (its initialize needs the governor address).
        incentivizer = GovernanceCycleIncentivizerUpgradeable(
            address(new UnsafeUninitializedProxy(address(new GovernanceCycleIncentivizerUpgradeable()), bytes("")))
        );

        // Deploy the governor proxy wired to the incentivizer address.
        governor = MemecoinDaoGovernorUpgradeable(
            payable(address(
                    new ERC1967Proxy(
                        address(new MemecoinDaoGovernorUpgradeable()),
                        abi.encodeCall(
                            MemecoinDaoGovernorUpgradeable.initialize,
                            (
                                "Memecoin DAO",
                                IVotes(address(votesToken)),
                                0,
                                5,
                                1 ether,
                                10,
                                address(incentivizer),
                                0,
                                0,
                                1000,
                                6000
                            )
                        )
                    )
                ))
        );

        // Complete the mutual wiring: the incentivizer learns its governor.
        address[] memory initTokens = new address[](0);
        incentivizer.initialize(address(governor), initTokens);
    }

    /// @notice A registered treasury token approving an arbitrary spender reverts the whole execution and leaves
    ///         no allowance behind.
    function test_RevertIf_RegisteredTreasuryTokenApprovesArbitrarySpender() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), abi.encodeCall(IERC20.approve, (ATTACKER, 100 ether)));
        _proposeAndPass(targets, values, calldatas, "approve-arbitrary-spender");

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UnauthorizedTreasuryAllowance.selector, address(treasuryToken), ATTACKER
            )
        );
        governor.execute(targets, values, calldatas, keccak256("approve-arbitrary-spender"));

        // The whole execution reverted, so no allowance was created for the attacker.
        assertEq(treasuryToken.allowance(address(governor), ATTACKER), 0);
    }

    /// @notice Approving the paired vote token stays executable: it is the sanctioned spender behind the yield
    ///         vault deposit path, and the resulting allowance equals the approved amount.
    function test_RegisteredTreasuryTokenApprovesVoteTokenSpender() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), abi.encodeCall(IERC20.approve, (address(votesToken), 77 ether)));
        _proposePassAndExecute(targets, values, calldatas, "approve-vote-token");

        assertEq(treasuryToken.allowance(address(governor), address(votesToken)), 77 ether);
    }

    /// @notice The per-execution balance cap is intact: a direct transfer of the full registered-token balance is
    ///         still reverted by the treasury spend ratio check.
    function test_RevertIf_DirectRegisteredTokenTransferExceedsSpendRatio() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        // The helper funded the governor with the token's full 1000 ether balance; transfer all of it.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), abi.encodeCall(IERC20.transfer, (BOB, 1000 ether)));
        _proposeAndPass(targets, values, calldatas, "direct-transfer-over-ratio");

        // maxTreasurySpendRatio is 1000 bp, so the limit for a 1000 ether balance is 100 ether.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.TreasurySpendExceedsLimit.selector, address(treasuryToken), 1000 ether, 100 ether
            )
        );
        governor.execute(targets, values, calldatas, keccak256("direct-transfer-over-ratio"));

        assertEq(treasuryToken.balanceOf(BOB), 0);
    }

    /// @notice Tokens that were never registered keep the generic relay path: an arbitrary-spender approval on an
    ///         unregistered target executes unchanged.
    function test_UnregisteredTokenApproveArbitrarySpenderExecutes() external {
        MockERC20 outsiderToken = new MockERC20("Outsider Token", "OUT", 18);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(outsiderToken), abi.encodeCall(IERC20.approve, (ATTACKER, 10 ether)));
        _proposePassAndExecute(targets, values, calldatas, "approve-unregistered");

        assertEq(outsiderToken.allowance(address(governor), ATTACKER), 10 ether);
    }

    /// @notice A selector-only approve payload is shorter than a decodable call, so it is not caught by the guard
    ///         and reverts inside the token's own argument decoding instead.
    function test_RevertIf_RegisteredTokenApproveCalldataTruncated() external {
        StrictDecodeToken treasuryToken = new StrictDecodeToken();
        _registerTreasuryToken(address(treasuryToken));
        treasuryToken.mint(address(governor), 1000 ether);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), abi.encodePacked(IERC20.approve.selector));
        _proposeAndPass(targets, values, calldatas, "approve-truncated");

        // 4-byte calldata is below the 68-byte guard threshold, so execution proceeds into the token call and
        // fails there. The distinctive decode error pins the revert origin to the token's own argument check: if
        // the guard ever wrongly intercepted short payloads, the revert would be UnauthorizedTreasuryAllowance.
        vm.expectRevert(StrictDecodeToken.TokenArgumentDecodeFailed.selector);
        governor.execute(targets, values, calldatas, keccak256("approve-truncated"));
    }

    /// @notice A multi-operation proposal mixing an in-ratio treasury transfer with a bad approve reverts the
    ///         whole execution: the earlier benign operation leaves no side effect behind.
    function test_RevertIf_MultiOperationExecutionRollsBackFirstOperation() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _twoCallPayload(
            address(treasuryToken),
            abi.encodeCall(IERC20.transfer, (BOB, 10 ether)),
            address(treasuryToken),
            abi.encodeCall(IERC20.approve, (ATTACKER, 100 ether))
        );
        _proposeAndPass(targets, values, calldatas, "transfer-then-bad-approve");

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UnauthorizedTreasuryAllowance.selector, address(treasuryToken), ATTACKER
            )
        );
        governor.execute(targets, values, calldatas, keccak256("transfer-then-bad-approve"));

        // The whole execution is reverted, so the in-ratio transfer (operation 1) is rolled back with it.
        assertEq(treasuryToken.balanceOf(BOB), 0);
        assertEq(treasuryToken.balanceOf(address(governor)), 1000 ether);
    }

    /// @notice A full 68-byte approve payload is the exact boundary of the short-calldata skip: the guard decodes
    ///         it and still rejects an arbitrary spender.
    function test_RevertIf_RegisteredTokenApproveCalldataExactly68Bytes() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        bytes memory approveCalldata = abi.encodePacked(IERC20.approve.selector, abi.encode(ATTACKER, 1 ether));
        assertEq(approveCalldata.length, 68); // 4-byte selector + two 32-byte args: the minimum decodable approve.

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), approveCalldata);
        _proposeAndPass(targets, values, calldatas, "approve-exactly-68-bytes");

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UnauthorizedTreasuryAllowance.selector, address(treasuryToken), ATTACKER
            )
        );
        governor.execute(targets, values, calldatas, keccak256("approve-exactly-68-bytes"));
    }

    /// @notice The spender whitelist is amount-independent: even a zero-amount approve to an arbitrary spender
    ///         reverts, because the permission granted by the allowance slot is what the guard blocks.
    function test_RevertIf_RegisteredTokenApprovesArbitrarySpenderWithZeroAmount() external {
        MockERC20 treasuryToken = _newRegisteredTreasuryToken();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleCallPayload(address(treasuryToken), abi.encodeCall(IERC20.approve, (ATTACKER, 0)));
        _proposeAndPass(targets, values, calldatas, "approve-zero-amount");

        vm.expectRevert(
            abi.encodeWithSelector(
                IMemecoinDaoGovernor.UnauthorizedTreasuryAllowance.selector, address(treasuryToken), ATTACKER
            )
        );
        governor.execute(targets, values, calldatas, keccak256("approve-zero-amount"));
    }

    /// @notice Deploys a token, registers it as a treasury token through a standalone proposal, and funds the
    ///         governor with it so the registered-token dimension of every guard is exercised.
    function _newRegisteredTreasuryToken() internal returns (MockERC20 token) {
        token = new MockERC20("Treasury Token", "TRY", 18);
        _registerTreasuryToken(address(token));
        token.mint(address(governor), 1000 ether);
    }

    /// @notice Registers an already-deployed token as a treasury token through a standalone proposal; callers
    ///         fund the governor with their own token implementation afterwards.
    function _registerTreasuryToken(address token) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCallPayload(
            address(incentivizer), abi.encodeCall(GovernanceCycleIncentivizerUpgradeable.registerTreasuryToken, (token))
        );
        _proposePassAndExecute(targets, values, calldatas, "register-token");

        assertTrue(incentivizer.isTreasuryToken(1, token));
    }

    /// @notice Creates the proposal and votes it through, leaving execution to the caller.
    function _proposeAndPass(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(ALICE);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
    }

    /// @notice Creates the proposal, votes it through, and executes it.
    function _proposePassAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        _proposeAndPass(targets, values, calldatas, description);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    /// @notice Wraps one call into single-operation proposal payload arrays.
    function _singleCallPayload(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        calldatas[0] = data;
    }

    /// @notice Wraps two calls into a two-operation proposal payload array.
    function _twoCallPayload(address target0, bytes memory data0, address target1, bytes memory data1)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](2);
        values = new uint256[](2);
        calldatas = new bytes[](2);
        targets[0] = target0;
        targets[1] = target1;
        values[0] = 0;
        values[1] = 0;
        calldatas[0] = data0;
        calldatas[1] = data1;
    }
}

/// @title UnsafeUninitializedProxy
/// @notice Test-only ERC1967Proxy that may be deployed without an initializer call. The real Governor and
///         Incentivizer initializers each reference the other's proxy address, so one proxy must be deployed
///         uninitialized first and initialized after the pair is wired.
contract UnsafeUninitializedProxy is ERC1967Proxy {
    /// @param implementation Initial implementation address.
    /// @param data Initializer calldata; may be empty for deferred initialization.
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}

    /// @notice Permit an uninitialized deployment so the paired contract can be wired in a later call.
    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

/// @title StrictDecodeToken
/// @notice Minimal ERC20 fragment whose approve is handled in fallback instead of the dispatch table, mirroring
///         strict-decode tokens: only the exact 68-byte selector-plus-two-args approve shape is accepted, and any
///         other calldata length reverts with a distinctive error, so tests can pin the revert origin to the
///         token's own argument check rather than the governor guard.
contract StrictDecodeToken {
    /// @notice Raised when the approve calldata is not exactly the 68-byte decodable shape.
    error TokenArgumentDecodeFailed();

    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowances;

    /// @notice Test-only faucet for funding the governor treasury.
    /// @param to Recipient of the minted amount.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    /// @param account Account whose balance is read.
    /// @return The account balance.
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    /// @param owner Allowance owner.
    /// @param spender Allowance spender.
    /// @return The owner's allowance granted to the spender.
    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    /// @notice With no approve function declared, every approve-shaped call lands here, so the strict length
    ///         check runs before any argument decoding — a declared approve body could never fire on short
    ///         calldata because the compiler-generated argument decoder reverts first.
    fallback() external {
        if (msg.sig != IERC20.approve.selector || msg.data.length != 68) revert TokenArgumentDecodeFailed();
        (address spender, uint256 amount) = abi.decode(msg.data[4:], (address, uint256));
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        assembly ("memory-safe") {
            mstore(0, true)
            return(0, 32)
        }
    }
}
