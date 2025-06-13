// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/**
 * @dev This contract is just for minimal proxy
 */
abstract contract Initializable {
    error NotInitializing();
    error AlreadyInitialized();

    struct InitializableStorage {
        bool initialized;
        bool initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE_LOCATION = 0x364b90b49cc5a06782669778ce5f4dc79d5c3891ab824b5e713b2409af81a500;

    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE_LOCATION
        }
    }

    // Lock initialization in logic contract
    constructor() {
        _getInitializableStorage().initialized = true;
    }

    modifier initializer() {
        InitializableStorage storage $ = _getInitializableStorage();
        if ($.initialized) {
            revert AlreadyInitialized();
        }

        $.initialized = true;
        $.initializing = true;
        _;
        $.initializing = false;
    }

    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    function _checkInitializing() internal view {
        if (!_getInitializableStorage().initializing) {
            revert NotInitializing();
        }
    }
}
