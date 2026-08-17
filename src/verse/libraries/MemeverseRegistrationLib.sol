// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @title MemeverseRegistrationLib
/// @notice Shared constants and pure helpers for the Memeverse registration subtree:
///         `MemeverseRegistrarAtLocal` (deploy path) and `MemeverseRegistrationCenterUpgradeable` (center chain).
/// @dev The two consumers share NO ancestor (RegistrarAtLocal inherits `MemeverseRegistrarAbstract`;
///      RegistrationCenter inherits the upgradeable OApp base), so this library is the only mechanism to keep their identical
///      lockup-duration constants and omnichain-id dedup logic from drifting. Functions are `internal` and
///      compile inline into each caller, so there is no storage/external-read concern.
library MemeverseRegistrationLib {
    /// @dev Fixed liquidity-lockup duration added to a verse's genesis end time to derive its unlock time.
    ///      Single source of truth for the registration subtree so both consumers compute the same unlock.
    uint256 internal constant FIXED_LOCKUP_DURATION = 365 days;

    /// @dev Upper bound on a verse's raw genesis end time. Leaves room for the downstream
    ///      `endTime + FIXED_LOCKUP_DURATION` (cast to uint64) without overflow.
    uint256 internal constant MAX_END_TIME = type(uint64).max - FIXED_LOCKUP_DURATION;

    /// @notice Removes duplicate chain ids from `input`, preserving first-seen order.
    /// @dev O(n²) temp-array dedup followed by a trimmed copy into a tightly sized result. `input` is
    ///      `memory` so both call sites can use the same signature: the registrar passes its `calldata`
    ///      `param.omnichainIds` (implicit calldata-to-memory copy at the call site), while the center
    ///      passes its already-`memory` array. Returns a fresh array; the caller reassigns it.
    /// @param input Omnichain ids to deduplicate (may contain duplicates).
    /// @return uniqueValues Order-preserved, duplicate-free copy of `input`.
    function deduplicate(uint32[] memory input) internal pure returns (uint32[] memory uniqueValues) {
        uint256 inputLength = input.length;
        if (inputLength == 0) return new uint32[](0);

        uint32[] memory temp = new uint32[](inputLength);
        uint256 uniqueCount;

        for (uint256 i = 0; i < inputLength;) {
            bool found;
            for (uint256 j = 0; j < uniqueCount;) {
                if (temp[j] == input[i]) {
                    found = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!found) {
                temp[uniqueCount] = input[i];
                unchecked {
                    ++uniqueCount;
                }
            }
            unchecked {
                ++i;
            }
        }

        uniqueValues = new uint32[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount;) {
            uniqueValues[i] = temp[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Derives the canonical verse id from a registration's symbol, nonce, and fundraising token.
    /// @dev Single source of truth for the registration subtree so the center-chain write
    ///      (`MemeverseRegistrationCenterUpgradeable.registration`) and the local pre-quote
    ///      (`MemeverseRegistrarAtLocal.quoteRegister`) compute the same id. `nonce` is the post-increment
    ///      value (i.e. `currentNonce + 1`); both call sites pass the same value they used to inline.
    ///      Compiles inline into each caller, so there is no storage/external-read concern.
    function deriveUniqueId(string memory symbol, uint192 nonce, address uAsset) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(symbol, nonce, uAsset)));
    }
}
