// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IMessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/// @dev Attacker-controlled plain ERC20 (no OFT machinery) used by the forged-compose regression suites. Needs
///      the ERC20 surface the staker touches (`allowance`/`approve` via `_safeApprove`), standard
///      `transfer`/`transferFrom` so an attacker vault can pull the delivered fake tokens, and a `mint` to fund
///      the victim's fake balance. Plus the compose entries that call the endpoint's permissionless `sendCompose`
///      — which keys the composeQueue slot by `msg.sender`, exactly like the real OFT's `_lzReceive` →
///      `endpoint.sendCompose` call (MessagingComposer.sol), but with `msg.sender` = this forged token.
///      Single shared definition for StakerExactApproval.t.sol and StakerTokenVaultBinding.t.sol (AGENTS.md:
///      mocks live in test/mocks/, not co-located with test files): a future change to the write-slot semantics
///      touches one file, not two diverging copies.
contract ForgedComposeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    IMessagingComposer public immutable endpoint;

    constructor(address _endpoint) {
        endpoint = IMessagingComposer(_endpoint);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Standard ERC20 semantics: underflows revert (0.8), and a max allowance is never decremented.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @notice Test-only mint (mock convenience, attacker-controlled): funds the victim's fake balance so an
    ///         attacker vault's pull of the delivered token can succeed.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Writes the attacker's own composeQueue slot: `composeQueue[address(this)][to][guid][0] = keccak256(msg)`.
    ///         Real composer: `sendCompose` is permissionless and authenticated by msg.sender ("anyone can send
    ///         compose msg with this function" per the LayerZero doc comment). Forwards the caller's pre-encoded
    ///         frame untouched.
    function queueCompose(address to, bytes32 guid, bytes calldata message) external {
        endpoint.sendCompose(to, guid, 0, message);
    }

    /// @notice Encode-and-queue convenience: builds the full OFT envelope with this token as the compose-from word
    ///         and queues it under this contract's own slot, returning the encoded frame so the caller can drive
    ///         it through `lzCompose`.
    /// @dev The codec's 76-byte prefix is nonce|srcEid|amountLD|composeFrom, so the 4th encode arg must be
    ///      [composeFrom word][composeMsg] exactly like the real OFT's `_lzReceive`; without the composeFrom word
    ///      the staker's `abi.decode(msg[76:], (address, address))` would fail before the deposit branch is reached.
    function queueComposeEncoded(uint32 srcEid, address to, bytes32 guid, bytes calldata composeMsg)
        external
        returns (bytes memory message)
    {
        message = OFTComposeMsgCodec.encode(
            1, srcEid, 1, abi.encodePacked(bytes32(uint256(uint160(address(this)))), composeMsg)
        );
        endpoint.sendCompose(to, guid, 0, message);
    }
}
