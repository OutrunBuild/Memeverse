// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @dev Shared Ownable body for both `OutrunOwnableInit` and
 * `OutrunOwnableUpgradeable`. It owns the ERC7201 storage namespace
 * `outrun.storage.Ownable`, the accessors, the errors and the event, but does
 * NOT inherit any `Initializable`; each family base keeps its own
 * `onlyInitializing`-guarded initializer and delegates the storage write to
 * `__OutrunOwnable_init_unchanged`.
 *
 * Ownership is never renounceable: there is no `renounceOwnership`, and both the
 * initializer and `transferOwnership` revert on the zero address, so `owner()`
 * never returns address(0) after initialization.
 */
abstract contract OutrunOwnable {
    /// @custom:storage-location erc7201:outrun.storage.Ownable
    struct OwnableStorage {
        address _owner;
    }

    // keccak256(abi.encode(uint256(keccak256("outrun.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x7f241041d6960443a72c6e46e3b41069d0f1a8933ddb434b1da86a3f3cba9f00;

    function _getOwnableStorage() private pure returns (OwnableStorage storage $) {
        assembly {
            $.slot := OWNABLE_STORAGE_LOCATION
        }
    }

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Writes the initial owner and emits `OwnershipTransferred`. Carries no
     * initializer guard; each family base wraps this from its own
     * `onlyInitializing`-protected `__OutrunOwnable_init`.
     */
    function __OutrunOwnable_init_unchanged(address initialOwner) internal {
        require(initialOwner != address(0), OwnableInvalidOwner(address(0)));
        OwnableStorage storage $ = _getOwnableStorage();
        $._owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Throws if the sender is not the owner. Virtual so family bases and
     * subclasses can extend the owner-check logic symmetrically.
     */
    function _checkOwner() internal view virtual {
        require(owner() == msg.sender, OwnableUnauthorizedAccount(msg.sender));
    }

    /// @notice Reads the address that currently holds ownership.
    /// @dev The zero address is returned only before initialization; ownership cannot be renounced.
    /// @return ownerAddress Current owner address.
    function owner() public view virtual returns (address) {
        OwnableStorage storage $ = _getOwnableStorage();
        return $._owner;
    }

    /// @notice Transfers ownership to `newOwner`.
    /// @dev Reverts when `newOwner` is the zero address.
    /// @param newOwner Address that will become the next owner.
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), OwnableInvalidOwner(address(0)));
        OwnableStorage storage $ = _getOwnableStorage();
        $._owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}
