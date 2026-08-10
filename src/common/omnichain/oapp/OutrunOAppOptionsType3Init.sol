// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {
    IOAppOptionsType3,
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {OutrunOwnableInit} from "../../access/OutrunOwnableInit.sol";

/**
 * @title OutrunOAppOptionsType3Init (Just for minimal proxy)
 * @dev Abstract contract implementing the IOAppOptionsType3 interface with type 3 options.
 */
abstract contract OutrunOAppOptionsType3Init is IOAppOptionsType3, OutrunOwnableInit {
    struct OAppOptionsType3Storage {
        // @dev The "msgType" should be defined in the child contract.
        mapping(uint32 => mapping(uint16 => bytes)) enforcedOptions;
    }

    uint16 internal constant OPTION_TYPE_3 = 3;

    // keccak256(abi.encode(uint256(keccak256("outrun.layerzerov2.storage.OAppOptionsType3")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OAPP_OPTIONS_TYPE_3_STORAGE_LOCATION =
        0xb8742acedc513ab939c44ee9081fd12ef5e204cfe39a55d50dba0e689496ff00;

    function _getOAppOptionsType3Storage() internal pure returns (OAppOptionsType3Storage storage $) {
        assembly {
            $.slot := OAPP_OPTIONS_TYPE_3_STORAGE_LOCATION
        }
    }

    /**
     * @dev Ownable is not initialized here on purpose. It should be initialized in the child contract to
     * accommodate the different version of Ownable.
     */
    function __OutrunOAppOptionsType3_init() internal onlyInitializing {}

    /// @dev Form-compat stub: mirrors the upstream full/`_unchained` initializer pair convention
    ///      this file ports. Empty and unwired in the production init chain; kept for convention.
    function __OutrunOAppOptionsType3_init_unchained() internal onlyInitializing {}

    /// @notice Exposes enforced type-3 options for a route and message type.
    /// @dev Empty bytes means no enforced options are configured.
    /// @param _eid LayerZero endpoint ID.
    /// @param _msgType OApp-defined message type.
    /// @return options Enforced options blob.
    function enforcedOptions(uint32 _eid, uint16 _msgType) public view returns (bytes memory) {
        OAppOptionsType3Storage storage $ = _getOAppOptionsType3Storage();
        return $.enforcedOptions[_eid][_msgType];
    }

    /// @notice Sets enforced type-3 options in batch.
    /// @dev Callable only by owner; each entry replaces existing value for `(eid,msgType)`.
    /// @param _enforcedOptions Batch of endpoint/message-type option configs.
    function setEnforcedOptions(EnforcedOptionParam[] calldata _enforcedOptions) public virtual onlyOwner {
        OAppOptionsType3Storage storage $ = _getOAppOptionsType3Storage();
        uint256 enforcedOptionsLength = _enforcedOptions.length;
        for (uint256 i = 0; i < enforcedOptionsLength; ++i) {
            // @dev Enforced options are only available for optionType 3, as type 1 and 2 dont support combining.
            _assertOptionsType3(_enforcedOptions[i].options);
            $.enforcedOptions[_enforcedOptions[i].eid][_enforcedOptions[i].msgType] = _enforcedOptions[i].options;
        }

        emit EnforcedOptionSet(_enforcedOptions);
    }

    /**
     * @notice Combines options for a given endpoint and message type.
     * @param _eid The endpoint ID.
     * @param _msgType The OAPP message type.
     * @param _extraOptions Additional options passed by the caller.
     * @return options The combination of caller specified options AND enforced options.
     *
     * @dev If there is an enforced lzReceive option:
     * - {gasLimit: 200k, msg.value: 1 ether} AND a caller supplies a lzReceive option: {gasLimit: 100k, msg.value: 0.5 ether}
     * - The resulting options will be {gasLimit: 300k, msg.value: 1.5 ether} when the message is executed on the remote lzReceive() function.
     * @dev This presence of duplicated options is handled off-chain in the verifier/executor.
     */
    function combineOptions(uint32 _eid, uint16 _msgType, bytes calldata _extraOptions)
        public
        view
        virtual
        returns (bytes memory)
    {
        OAppOptionsType3Storage storage $ = _getOAppOptionsType3Storage();
        bytes memory enforced = $.enforcedOptions[_eid][_msgType];

        // No enforced options, pass whatever the caller supplied, even if it's empty or legacy type 1/2 options.
        if (enforced.length == 0) return _extraOptions;

        // No caller options, return enforced
        if (_extraOptions.length == 0) return enforced;

        // @dev If caller provided _extraOptions, must be type 3 as its the ONLY type that can be combined.
        if (_extraOptions.length >= 2) {
            _assertOptionsType3(_extraOptions);
            // @dev Remove the first 2 bytes containing the type from the _extraOptions and combine with enforced.
            return bytes.concat(enforced, _extraOptions[2:]);
        }

        // No valid set of options was found.
        revert InvalidOptions(_extraOptions);
    }

    /**
     * @dev Internal function to assert that options are of type 3.
     * @param _options The options to be checked.
     */
    function _assertOptionsType3(bytes calldata _options) internal pure virtual {
        // @dev Guard against out-of-bounds calldata slice on empty/short options:
        //      revert a typed error instead of a bare revert.
        if (_options.length < 2) revert InvalidOptions(_options);
        uint16 optionsType = uint16(bytes2(_options[0:2]));
        if (optionsType != OPTION_TYPE_3) revert InvalidOptions(_options);
    }
}
