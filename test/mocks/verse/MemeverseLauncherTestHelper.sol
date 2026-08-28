// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {StorageSlotPrimitives} from "../StorageSlotPrimitives.sol";
import {IMemeverseLauncher} from "../../../src/verse/interfaces/IMemeverseLauncher.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Standalone white-box accessor for MemeverseLauncherUpgradeable proxy storage.
///         Does not inherit any src/ contract. Reads/writes proxy storage slots via vm.load/vm.store.
///         Your test contract should inherit this helper (`is Test, MemeverseLauncherTestHelper`).
abstract contract MemeverseLauncherTestHelper is StorageSlotPrimitives {
    // Storage layout mirrors MemeverseLauncherStorage (src/verse/MemeverseLauncherUpgradeable.sol:64-95).
    // Slot offsets below correspond to field positions in that struct.
    // Memeverse sub-struct layout: slots 0-3 = string offsets, slot+4 = uAsset|currentStage|flashGenesis (packed),
    //   slots 5-9 = addresses, 10 = endTime|unlockTime, 11 = omnichainIds length.

    bytes32 internal constant LAUNCHER_SLOT = 0xe4d68b4f0bdabf27c869795dba7c9a87fd97b24006928b28f58769be5bd8f500;

    // Struct field slot offsets — each number corresponds to the field position in the struct above
    uint256 internal constant OFF_POLEND = 7;
    uint256 internal constant OFF_POL_SPLITTER = 8;
    uint256 internal constant OFF_POL_TO_IDS = 13;
    uint256 internal constant OFF_MEMECOIN_TO_IDS = 14;
    uint256 internal constant OFF_MEMEVERSES = 15;
    uint256 internal constant OFF_FUND_META_DATAS = 16;
    uint256 internal constant OFF_TOTAL_NORMAL_FUNDS = 17;
    uint256 internal constant OFF_PREORDER_STATES = 18;
    uint256 internal constant OFF_AUX_LIQUIDITIES = 19;
    uint256 internal constant OFF_BOOTSTRAP_CLAIMS = 20;
    uint256 internal constant OFF_TOTAL_NORMAL_YT = 21;
    uint256 internal constant OFF_USER_GENESIS = 23;
    uint256 internal constant OFF_USER_PREORDER = 24;
    uint256 internal constant OFF_NORMAL_FEES = 26;
    uint256 internal constant OFF_PENDING_GOV_FEE = 28;

    // ── Slot computation helpers ──

    /// @dev Slot for mapping(uint256 => T) at struct field offset fieldOffset with key
    function _mappingSlot(uint256 fieldOffset, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(LAUNCHER_SLOT) + fieldOffset)));
    }

    /// @dev Slot for mapping(uint256 => mapping(address => T))
    function _nestedMappingSlot(uint256 fieldOffset, uint256 key1, address key2) internal pure returns (bytes32) {
        return keccak256(abi.encode(key2, _mappingSlot(fieldOffset, key1)));
    }

    /// @dev mapping(address => T) slot
    function _mappingAddrSlot(uint256 fieldOffset, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(LAUNCHER_SLOT) + fieldOffset)));
    }

    // ── Read methods ──

    /// @notice Read preorderStates[verseId] from proxy (mirrors TestBase.getPreorderStateForTest)
    function getPreorderStateForTest(address proxy, uint256 verseId)
        public
        view
        returns (uint256 totalFunds, uint256 settledMemecoin, uint40 settlementTimestamp)
    {
        bytes32 base = _mappingSlot(OFF_PREORDER_STATES, verseId);
        totalFunds = uint256(_loadSlot(proxy, base));
        settledMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(base) + 1)));
        settlementTimestamp = uint40(uint256(_loadSlot(proxy, bytes32(uint256(base) + 2))));
    }

    /// @notice Read claimable preorder memecoin after vesting from proxy
    ///         mirrors MemeverseLauncherUpgradeable.sol:435-465, uses FullMath.mulDiv
    function claimablePreorderMemecoinForTest(address proxy, uint256 verseId, address account)
        public
        view
        returns (uint256 amount)
    {
        // Skip _versIdValidate and currentStage checks — invalid verseId yields totalFunds=0, returns 0

        // — PreorderState storage preorderState = $.preorderStates[verseId] —
        bytes32 preorderBase = _mappingSlot(OFF_PREORDER_STATES, verseId);
        uint256 totalFunds = uint256(_loadSlot(proxy, preorderBase));
        uint256 settledMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(preorderBase) + 1)));
        uint40 settlementTimestamp = uint40(uint256(_loadSlot(proxy, bytes32(uint256(preorderBase) + 2))));

        if (settlementTimestamp == 0) return 0;

        // — PreorderData storage preorderData = $.userPreorderData[verseId][account] —
        bytes32 preorderDataBase = _nestedMappingSlot(OFF_USER_PREORDER, verseId, account);
        uint256 userFunds = uint256(_loadSlot(proxy, preorderDataBase));
        uint256 claimedMemecoin = uint256(_loadSlot(proxy, bytes32(uint256(preorderDataBase) + 1)));

        if (userFunds == 0 || totalFunds == 0) return 0;

        // — Vesting calculation (mirrors MemeverseLauncherUpgradeable.sol:454-465) —
        uint256 purchasedMemecoin = FullMath.mulDiv(settledMemecoin, userFunds, totalFunds);
        if (purchasedMemecoin <= claimedMemecoin) return 0;

        uint256 vestingDuration = uint256(_loadSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + 11)));
        uint256 elapsed = block.timestamp > settlementTimestamp ? block.timestamp - settlementTimestamp : 0;
        if (elapsed >= vestingDuration) {
            return purchasedMemecoin - claimedMemecoin;
        }

        uint256 vested = FullMath.mulDiv(purchasedMemecoin, elapsed, vestingDuration);
        if (vested <= claimedMemecoin) return 0;
        return vested - claimedMemecoin;
    }

    // ── Write methods — simple fields ──

    function setPolendForTest(address proxy, address _polend) internal {
        _writeSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + OFF_POLEND), bytes32(uint256(uint160(_polend))));
    }

    function setPolSplitterForTest(address proxy, address _polSplitter) internal {
        _writeSlot(proxy, bytes32(uint256(LAUNCHER_SLOT) + OFF_POL_SPLITTER), bytes32(uint256(uint160(_polSplitter))));
    }

    function setGenesisFundForTest(address proxy, uint256 verseId, uint256 amount) internal {
        _writeSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_FUNDS, verseId), bytes32(amount));
    }

    function setTotalNormalClaimableYTForTest(address proxy, uint256 verseId, uint256 amount) internal {
        _writeSlot(proxy, _mappingSlot(OFF_TOTAL_NORMAL_YT, verseId), bytes32(amount));
    }

    function setVerseIdByMemecoinForTest(address proxy, address memecoin, uint256 verseId) internal {
        _writeSlot(proxy, _mappingAddrSlot(OFF_MEMECOIN_TO_IDS, memecoin), bytes32(verseId));
    }

    // ── Write methods — struct fields ──

    function setUserGenesisDataForTest(
        address proxy,
        uint256 verseId,
        address account,
        uint256 genesisFund,
        bool isRefunded,
        bool isRedeemed
    ) internal {
        bytes32 base = _nestedMappingSlot(OFF_USER_GENESIS, verseId, account);
        // Packed single slot (per GenesisData): genesisFund uint128 (bytes 0-15) | isRefunded (byte 16) | isRedeemed (byte 17)
        _writeSlot(
            proxy,
            base,
            bytes32(genesisFund | (uint256(isRefunded ? 1 : 0) << 128) | (uint256(isRedeemed ? 1 : 0) << 136))
        );
    }

    function setUserPreorderDataForTest(
        address proxy,
        uint256 verseId,
        address account,
        uint256 funds,
        uint256 claimedMemecoin,
        bool isRefunded
    ) internal {
        bytes32 base = _nestedMappingSlot(OFF_USER_PREORDER, verseId, account);
        _writeSlot(proxy, base, bytes32(funds));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(claimedMemecoin));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(uint256(isRefunded ? 1 : 0)));
    }

    function setPreorderStateForTest(
        address proxy,
        uint256 verseId,
        uint256 totalFunds,
        uint256 settledMemecoin,
        uint40 settlementTimestamp
    ) internal {
        bytes32 base = _mappingSlot(OFF_PREORDER_STATES, verseId);
        _writeSlot(proxy, base, bytes32(totalFunds));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(settledMemecoin));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(uint256(settlementTimestamp)));
    }

    function setAuxiliaryLiquiditiesForTest(
        address proxy,
        uint256 verseId,
        uint256 polUAsset,
        uint256 ptUAsset,
        uint256 ptPol
    ) internal {
        bytes32 base = _mappingSlot(OFF_AUX_LIQUIDITIES, verseId);
        _writeSlot(proxy, base, bytes32(polUAsset));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(ptUAsset));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(ptPol));
    }

    function setBootstrapResidualClaimsForTest(
        address proxy,
        uint256 verseId,
        uint256 normalResidualPOL,
        uint256 normalResidualPT,
        uint256 leveragedResidualPOL,
        uint256 leveragedResidualPT
    ) internal {
        bytes32 base = _mappingSlot(OFF_BOOTSTRAP_CLAIMS, verseId);
        _writeSlot(proxy, base, bytes32(normalResidualPOL));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(normalResidualPT));
        _writeSlot(proxy, bytes32(uint256(base) + 2), bytes32(leveragedResidualPOL));
        _writeSlot(proxy, bytes32(uint256(base) + 3), bytes32(leveragedResidualPT));
    }

    function setNormalFeeStateForTest(address proxy, uint256 verseId, uint256 accUAssetFee, uint256 accPTFee) internal {
        bytes32 base = _mappingSlot(OFF_NORMAL_FEES, verseId);
        _writeSlot(proxy, base, bytes32(accUAssetFee));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(accPTFee));
    }

    function setPendingAuxiliaryGovFeeForTest(address proxy, uint256 verseId, uint256 uFee, uint256 ptFee) internal {
        bytes32 base = _mappingSlot(OFF_PENDING_GOV_FEE, verseId);
        _writeSlot(proxy, base, bytes32(uFee));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(ptFee));
    }

    function setFundMetaDataForTest(address proxy, address uAsset, uint256 minTotalFund, uint256 fundBasedAmount)
        internal
    {
        bytes32 base = _mappingAddrSlot(OFF_FUND_META_DATAS, uAsset);
        _writeSlot(proxy, base, bytes32(minTotalFund));
        _writeSlot(proxy, bytes32(uint256(base) + 1), bytes32(fundBasedAmount));
    }

    /// @notice Set commonly-used fields of Memeverse struct. Complex dynamic fields (name/symbol/uri/desc/omnichainIds)
    ///         are not written field-by-field here; use proxy's initialize() for full setup.
    function setMemeverseForTest(
        address proxy,
        uint256 verseId,
        address uAsset,
        address memecoin,
        address pol,
        address yieldVault,
        address governor,
        address incentivizer,
        uint128 endTime,
        uint128 unlockTime,
        IMemeverseLauncher.Stage currentStage,
        bool flashGenesis
    ) internal {
        bytes32 base = _mappingSlot(OFF_MEMEVERSES, verseId);
        // slot+4 packs uAsset (bytes 0-19), currentStage (byte 20), flashGenesis (byte 21), per the documented layout.
        _writeSlot(
            proxy,
            bytes32(uint256(base) + 4),
            bytes32(
                uint256(uint160(uAsset)) | (uint256(uint8(currentStage)) << 160)
                    | (flashGenesis ? uint256(1) << 168 : 0)
            )
        );
        _writeSlot(proxy, bytes32(uint256(base) + 5), bytes32(uint256(uint160(memecoin))));
        _writeSlot(proxy, bytes32(uint256(base) + 6), bytes32(uint256(uint160(pol))));
        _writeSlot(proxy, bytes32(uint256(base) + 7), bytes32(uint256(uint160(yieldVault))));
        _writeSlot(proxy, bytes32(uint256(base) + 8), bytes32(uint256(uint160(governor))));
        _writeSlot(proxy, bytes32(uint256(base) + 9), bytes32(uint256(uint160(incentivizer))));
        // endTime (uint128) and unlockTime (uint128) are packed into one slot
        _writeSlot(
            proxy,
            bytes32(uint256(base) + 10),
            bytes32(uint256(uint128(endTime)) | (uint256(uint128(unlockTime)) << 128))
        );
    }

    // ── Dynamic array fields ──

    /// @notice Set omnichainIds for a verse. Writes length at the array slot
    ///         and element data at keccak256(slot).
    function setOmnichainIdsForTest(address proxy, uint256 verseId, uint32[] memory chainIds) internal {
        bytes32 base = _mappingSlot(OFF_MEMEVERSES, verseId);
        bytes32 arraySlot = bytes32(uint256(base) + 11);
        // Write length
        _writeSlot(proxy, arraySlot, bytes32(chainIds.length));
        // Write each element
        bytes32 dataSlot = keccak256(abi.encode(arraySlot));
        for (uint256 i = 0; i < chainIds.length; i++) {
            _writeSlot(proxy, bytes32(uint256(dataSlot) + i), bytes32(uint256(chainIds[i])));
        }
    }
}
