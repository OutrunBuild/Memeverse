// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {HookStorageHelper} from "../mocks/swap/HookStorageHelper.sol";

/// @title HookStorageLayoutTest
/// @notice Regression guard for F-0009: ERC-7201 namespace literal repetition across diamond hosts.
/// @dev The hook and its three delegatecall facets MUST share `layout at erc7201("outrun.storage.MemeverseUniswapHook")`.
///      solc only checks layout conflicts within a single inheritance graph and `layout at` only accepts a
///      literal, so repetition is language-forced and a typo compiles to an orphan slot (silent zero-read/
///      orphan-write, not ledger corruption). This file pins the invariant at two layers:
///        1. Slot derivation: the ERC-7201 formula for the namespace must equal the hardened `HOOK_SLOT`.
///        2. Source literal: all four production hosts carry the exact literal, FacetGuard carries none.
///      CI fails immediately if a facet is added/replaced with a misspelled namespace. The functional
///      delegatecall sharing itself is exercised by the existing diamond integration suites via
///      `HookStorageHelper.HOOK_SLOT` direct `vm.load`/`vm.store` helpers.
contract HookStorageLayoutTest is Test, HookStorageHelper {
    string internal constant EXPECTED_NAMESPACE = "outrun.storage.MemeverseUniswapHook";
    string internal constant EXPECTED_LAYOUT = "layout at erc7201(\"outrun.storage.MemeverseUniswapHook\")";

    /// @notice The ERC-7201 slot for the namespace must equal the hardened constant used by all helpers.
    function test_ERC7201SlotDerivationMatchesConst() external pure {
        bytes32 derived = _erc7201Slot(EXPECTED_NAMESPACE);
        assertEq(derived, HOOK_SLOT, "HOOK_SLOT must match ERC-7201 derivation");
        // Canonical value pinned in HookStorageHelper.sol:41
        assertEq(
            HOOK_SLOT,
            bytes32(0x9f27a56b97c42ac08d93ff5a852851d11eb052b06dc4c041fc6bfa4414f7e000),
            "canonical HOOK_SLOT mismatch"
        );
    }

    /// @notice All four production hosts must declare the exact layout literal exactly once.
    function test_LayoutLiteralConsistentAcrossHosts() external view {
        string[4] memory hosts = [
            "src/swap/MemeverseUniswapHookUpgradeable.sol",
            "src/swap/SwapFacet.sol",
            "src/swap/SettlementFacet.sol",
            "src/swap/DynamicFeeFacet.sol"
        ];
        for (uint256 i = 0; i < hosts.length; ++i) {
            string memory content = vm.readFile(hosts[i]);
            assertTrue(_contains(content, EXPECTED_LAYOUT), string.concat("missing layout: ", hosts[i]));
            uint256 count = _countOccurrences(content, EXPECTED_LAYOUT);
            assertEq(count, 1, string.concat("layout count !=1 in: ", hosts[i]));
        }
    }

    /// @notice FacetGuard holds the storage anchor but must NOT declare its own layout (it relies on inheritors).
    function test_FacetGuardDoesNotDeclareLayout() external view {
        string memory content = vm.readFile("src/swap/FacetGuard.sol");
        assertTrue(_contains(content, EXPECTED_NAMESPACE), "FacetGuard must reference namespace in NatSpec");
        assertTrue(_contains(content, "MUST declare `layout at erc7201"), "FacetGuard MUST NatSpec missing");
        // Must not have a code-level `layout at` declaration — otherwise its anchor would shadow at slot 0.
        // Count comment-stripped occurrences: the NatSpec mandate asserted above legitimately mentions
        // `layout at erc7201`, so a raw substring count could never reach zero.
        assertEq(_countCodeOccurrences(content, "layout at erc7201"), 0, "FacetGuard must not declare layout");
    }

    /// @notice ERC-7201 slot derivation: keccak256(abi.encode(uint256(keccak256(abi.encode(bytes32(uint256(keccak256(bytes(ns)))-1))) & ~0xff))
    function _erc7201Slot(string memory ns) internal pure returns (bytes32 slot) {
        bytes32 namespaceHash = keccak256(bytes(ns));
        // `bytes32(uint256(hash) - 1)` then abi.encode as per EIP-7201
        bytes32 inner = keccak256(abi.encode(bytes32(uint256(namespaceHash) - 1)));
        slot = bytes32(uint256(inner) & ~uint256(0xff));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return _countOccurrences(haystack, needle) > 0;
    }

    function _countOccurrences(string memory haystack, string memory needle) internal pure returns (uint256) {
        return _countInRange(bytes(haystack), bytes(needle), 0, bytes(haystack).length);
    }

    /// @dev Counts needle occurrences outside comment lines, so NatSpec mentions of a code pattern
    ///      are not mistaken for the pattern itself. A line is a comment when its first non-whitespace
    ///      characters are `//`.
    function _countCodeOccurrences(string memory haystack, string memory needle) internal pure returns (uint256 count) {
        bytes memory h = bytes(haystack);
        uint256 lineStart = 0;
        for (uint256 i = 0; i <= h.length; ++i) {
            // End of input acts as the final line boundary.
            if (i == h.length || h[i] == "\n") {
                if (!_isCommentLine(h, lineStart, i)) {
                    count += _countInRange(h, bytes(needle), lineStart, i);
                }
                lineStart = i + 1;
            }
        }
    }

    /// @dev True when h[start:end) begins (after whitespace) with `//`.
    function _isCommentLine(bytes memory h, uint256 start, uint256 end) internal pure returns (bool) {
        uint256 i = start;
        while (i < end && (h[i] == " " || h[i] == "\t" || h[i] == "\r")) {
            ++i;
        }
        return i + 1 < end && h[i] == "/" && h[i + 1] == "/";
    }

    /// @dev Non-overlapping substring count of n inside h[start:end).
    function _countInRange(bytes memory h, bytes memory n, uint256 start, uint256 end)
        internal
        pure
        returns (uint256 count)
    {
        if (n.length == 0 || end < start || end - start < n.length) return 0;
        for (uint256 i = start; i + n.length <= end; ++i) {
            bool isMatch = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                count++;
                i += n.length - 1; // skip past this match (non-overlapping)
            }
        }
    }
}
