// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StorageSlotPrimitives} from "../StorageSlotPrimitives.sol";
import {IPOLend} from "../../../src/polend/interfaces/IPOLend.sol";

/// @notice Standalone white-box accessor for POLend proxy storage.
///         Does not inherit any src/ contract. Reads/writes proxy storage slots via vm.load/vm.store,
///         replicating the storage writes previously performed by the test-only POLendHarness.
///         Your test contract should inherit this helper (`is Test, POLendStorageHelper`).
abstract contract POLendStorageHelper is StorageSlotPrimitives {
    // erc7201:outrun.storage.POLend namespace location (src/polend/POLend.sol:44-45).
    bytes32 internal constant POLEND_SLOT = 0x04e0fabb81205fd4104b820a75487a0508fe84f0bc41932b7a41622326d3af00;

    // Struct field slot offsets in POLendStorage (src/polend/POLend.sol:37-53).
    uint256 internal constant OFF_CREDIT_INTEREST_PAID = 5; // mapping(uint256 => mapping(address => uint256))
    uint256 internal constant OFF_CREDIT_FACTORY = 6; // address
    uint256 internal constant OFF_LEND_MARKETS = 7; // mapping(uint256 => LendMarket)
    uint256 internal constant OFF_LEVERAGED_INTEREST_PAID = 8; // mapping(uint256 => mapping(address => uint256))
    uint256 internal constant OFF_RESIDUAL_STATES = 9; // mapping(uint256 => ResidualState)
    uint256 internal constant OFF_GLOBAL_DEBT_BY_UASSET = 10; // mapping(address => uint256)
    uint256 internal constant OFF_SETTLEMENT_DUST_STATES = 11; // mapping(address => SettlementDustState)

    // LendMarket sub-field offsets (src/polend/interfaces/IPOLend.sol:13-22).
    // Order: uAsset, yt, interestRate, totalLeveragedInterest, totalCreditInterest, totalLeveragedYT, state(uint8).
    uint256 internal constant OFF_LM_U_ASSET = 0;
    uint256 internal constant OFF_LM_YT = 1;
    uint256 internal constant OFF_LM_TOTAL_INTEREST = 3;
    uint256 internal constant OFF_LM_TOTAL_CREDIT_INTEREST = 4;
    uint256 internal constant OFF_LM_TOTAL_YT = 5;
    uint256 internal constant OFF_LM_STATE = 6;
    // `creditToken` packs into the same slot as `state` (slot 6): state occupies byte 0,
    // creditToken occupies bytes 1-20 (bits 8-167).
    uint256 internal constant OFF_LM_CREDIT_TOKEN = 6;

    // ── Slot computation helpers ──

    /// @dev Slot for mapping(uint256 => T) at struct field offset `fieldOffset` with key.
    function _mappingSlot(uint256 fieldOffset, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(POLEND_SLOT) + fieldOffset)));
    }

    /// @dev Slot for mapping(uint256 => mapping(address => T)).
    function _nestedMappingSlot(uint256 fieldOffset, uint256 key1, address key2) internal pure returns (bytes32) {
        return keccak256(abi.encode(key2, _mappingSlot(fieldOffset, key1)));
    }

    /// @dev Slot for mapping(address => T).
    function _mappingAddrSlot(uint256 fieldOffset, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(POLEND_SLOT) + fieldOffset)));
    }

    // ── Seed methods (mirror POLendHarness, field-by-field equivalent) ──

    /// @notice Write $.leveragedInterestPaid[verseId][account] = interestPaid.
    function seedLeveragedPositionForTest(address proxy, uint256 verseId, address account, uint256 interestPaid)
        internal
    {
        _writeSlot(proxy, _nestedMappingSlot(OFF_LEVERAGED_INTEREST_PAID, verseId, account), bytes32(interestPaid));
    }

    /// @notice Write $.creditInterestPaid[verseId][account] = interestPaid (credit-factory path).
    function seedCreditPositionForTest(address proxy, uint256 verseId, address account, uint256 interestPaid) internal {
        _writeSlot(proxy, _nestedMappingSlot(OFF_CREDIT_INTEREST_PAID, verseId, account), bytes32(interestPaid));
    }

    /// @notice Set $.lendMarkets[verseId].state = Refund.
    function setRefundStateForTest(address proxy, uint256 verseId) internal {
        bytes32 base = _mappingSlot(OFF_LEND_MARKETS, verseId);
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_STATE), bytes32(uint256(uint8(IPOLend.MarketState.Refund))));
    }

    /// @notice Set $.lendMarkets[verseId].state = Locked and totalLeveragedYT = totalLeveragedYT.
    function setLockedStateForTest(address proxy, uint256 verseId, uint256 totalLeveragedYT) internal {
        bytes32 base = _mappingSlot(OFF_LEND_MARKETS, verseId);
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_TOTAL_YT), bytes32(totalLeveragedYT));
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_STATE), bytes32(uint256(uint8(IPOLend.MarketState.Locked))));
    }

    /// @notice Write $.residualStates[verseId] = {residualUAsset, residualMemecoin},
    ///         $.lendMarkets[verseId].totalLeveragedInterest = totalLeveragedInterest,
    ///         and $.lendMarkets[verseId].state = Settled.
    function seedResidualForTest(
        address proxy,
        uint256 verseId,
        uint256 residualUAsset,
        uint256 residualMemecoin,
        uint256 totalLeveragedInterest
    ) internal {
        bytes32 residualBase = _mappingSlot(OFF_RESIDUAL_STATES, verseId);
        _writeSlot(proxy, residualBase, bytes32(residualUAsset));
        _writeSlot(proxy, bytes32(uint256(residualBase) + 1), bytes32(residualMemecoin));

        bytes32 marketBase = _mappingSlot(OFF_LEND_MARKETS, verseId);
        _writeSlot(proxy, bytes32(uint256(marketBase) + OFF_LM_TOTAL_INTEREST), bytes32(totalLeveragedInterest));
        _writeSlot(
            proxy, bytes32(uint256(marketBase) + OFF_LM_STATE), bytes32(uint256(uint8(IPOLend.MarketState.Settled)))
        );
    }

    /// @notice Set $.lendMarkets[verseId].yt = yt and totalLeveragedInterest = totalLeveragedInterest.
    function seedMarketForTest(address proxy, uint256 verseId, address yt, uint256 totalLeveragedInterest) internal {
        bytes32 base = _mappingSlot(OFF_LEND_MARKETS, verseId);
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_YT), bytes32(uint256(uint160(yt))));
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_TOTAL_INTEREST), bytes32(totalLeveragedInterest));
    }

    /// @notice Set $.lendMarkets[verseId].uAsset = uAsset (used when overriding the launcher-sourced uAsset).
    function seedMarketUAssetForTest(address proxy, uint256 verseId, address uAsset) internal {
        bytes32 base = _mappingSlot(OFF_LEND_MARKETS, verseId);
        _writeSlot(proxy, bytes32(uint256(base) + OFF_LM_U_ASSET), bytes32(uint256(uint160(uAsset))));
    }

    /// @notice Write $.lendMarkets[verseId].creditToken = creditToken.
    /// @dev    `creditToken` shares slot 6 with `state` (state byte 0, creditToken bytes 1-20), so this
    ///         read-modify-writes the slot: it clears bits 8-167 and writes `creditToken` there while
    ///         preserving the market `state` byte set by `setRefundStateForTest`. Tests that seed a
    ///         credit position directly via `seedCreditPositionForTest` bypass `leveragedGenesisWithCredit`,
    ///         which is the only production path that caches `market.creditToken`; without this seed,
    ///         `claimRefund` / `finalizeLeveragedGenesis` revert `NoCreditForUAsset` when they read the
    ///         still-zero cached token. Must be called AFTER `setRefundStateForTest`, which overwrites the
    ///         whole slot with the state byte.
    function seedMarketCreditTokenForTest(address proxy, uint256 verseId, address creditToken) internal {
        bytes32 slot = bytes32(uint256(_mappingSlot(OFF_LEND_MARKETS, verseId)) + OFF_LM_CREDIT_TOKEN);
        // Clear the 20-byte creditToken field (bits 8-167); keep byte 0 (state) and any higher bits intact.
        uint256 cleared = uint256(_loadSlot(proxy, slot)) & ~(uint256(type(uint160).max) << 8);
        _writeSlot(proxy, slot, bytes32(cleared | (uint256(uint160(creditToken)) << 8)));
    }

    /// @notice Set $.globalDebtByUAsset[uAsset] = amount.
    function seedGlobalDebtForTest(address proxy, address uAsset, uint256 amount) internal {
        _writeSlot(proxy, _mappingAddrSlot(OFF_GLOBAL_DEBT_BY_UASSET, uAsset), bytes32(amount));
    }

    /// @notice Set $.settlementDustStates[uAsset] = {reserve, maxReserve} packed in one slot.
    function seedSettlementDustStateForTest(address proxy, address uAsset, uint128 reserve, uint128 maxReserve)
        internal
    {
        bytes32 packed = bytes32(uint256(reserve) | (uint256(maxReserve) << 128));
        _writeSlot(proxy, _mappingAddrSlot(OFF_SETTLEMENT_DUST_STATES, uAsset), packed);
    }
}
