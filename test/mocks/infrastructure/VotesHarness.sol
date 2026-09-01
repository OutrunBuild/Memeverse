// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {OutrunERC20VotesInit} from "../../../src/common/token/extensions/governance/OutrunERC20VotesInit.sol";

contract VotesHarness is OutrunERC20VotesInit {
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice Initialize.
    /// @param name_ See implementation.
    /// @param symbol_ See implementation.
    function initialize(string memory name_, string memory symbol_) external initializer {
        __OutrunERC20_init(name_, symbol_);
        __OutrunEIP712_init(name_, "1");
        __OutrunVotes_init();
        __OutrunERC20Votes_init();
    }

    /// @notice Mint test.
    /// @param to See implementation.
    /// @param amount See implementation.
    function mintTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Exposes the EIP-712 domain separator so tests can anchor it to a literal baseline.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Delegation digest.
    /// @param delegatee See implementation.
    /// @param nonce See implementation.
    /// @param expiry See implementation.
    /// @return See implementation.
    function delegationDigest(address delegatee, uint256 nonce, uint256 expiry) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)));
    }
}

contract CappedVotesHarness is VotesHarness {
    function _maxSupply() internal pure override returns (uint256) {
        return 10 ether;
    }
}

/// @title BlockNumberClockVotesHarness
/// @notice Votes harness whose governance clock runs in the block-number domain.
/// @dev Overrides only `clock()` so the inherited base `CLOCK_MODE()` consistency guard sees a clock that no
///      longer matches its timestamp expectation; used to pin that guard's revert behavior.
contract BlockNumberClockVotesHarness is VotesHarness {
    /// @notice Read the governance clock from the block-number domain.
    /// @return Current block number cast into the ERC-6372 clock domain.
    function clock() public view override returns (uint48) {
        return Time.blockNumber();
    }
}
