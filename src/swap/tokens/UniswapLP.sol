// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Owned} from "solmate/auth/Owned.sol";

import {IMemeverseUniswapHook, PoolId} from "../interfaces/IMemeverseUniswapHook.sol";

/// @notice LP Token For MemeverseUniswapHook
contract UniswapLP is Owned, Initializable {
    error PermitDeadlineExpired(uint256 deadline);
    error InvalidSigner(address recoveredAddress, address owner);
    error ZeroAddressHook();
    error ZeroAddressTransfer();

    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal INITIAL_CHAIN_ID;
    bytes32 internal INITIAL_DOMAIN_SEPARATOR;
    mapping(address => uint256) public nonces;

    PoolId public poolId;
    address public memeverseUniswapHook;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Owned(address(1)) {
        _disableInitializers();
    }

    /// @notice Initializes a pool-specific LP clone.
    /// @dev The hook becomes the token owner so mint/burn permissions stay hook-only. The EIP-712 domain is
    ///      written after clone state is set because permit signatures must bind to the clone's name and address.
    /// @param _name ERC20 name for the LP clone.
    /// @param _symbol ERC20 symbol for the LP clone.
    /// @param _decimals ERC20 decimals for the LP clone.
    /// @param _poolId Hook-managed pool id represented by this LP clone.
    /// @param _memeverseUniswapHook Hook that owns this LP clone and receives transfer snapshot callbacks.
    function initialize(
        string calldata _name,
        string calldata _symbol,
        uint8 _decimals,
        PoolId _poolId,
        address _memeverseUniswapHook
    ) external initializer {
        if (_memeverseUniswapHook == address(0)) revert ZeroAddressHook();
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        poolId = _poolId;
        memeverseUniswapHook = _memeverseUniswapHook;
        owner = _memeverseUniswapHook;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();

        emit OwnershipTransferred(address(0), _memeverseUniswapHook);
    }

    /// @notice Approves `spender` to spend LP tokens on behalf of the caller.
    /// @dev Replaces any existing allowance value.
    /// @param spender Address allowed to spend the caller's LP balance.
    /// @param amount New allowance amount.
    /// @return success Always returns `true` on success.
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    /// @notice Transfers LP tokens from the caller to `to`.
    /// @dev Synchronizes fee snapshots for both accounts before moving balances.
    /// @param to Recipient of the LP tokens.
    /// @param amount Amount of LP tokens to transfer.
    /// @return success Always returns `true` on success.
    function transfer(address to, uint256 amount) public returns (bool) {
        if (to == address(0)) revert ZeroAddressTransfer();
        _beforeTokenTransfer(msg.sender, to);

        balanceOf[msg.sender] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    /// @notice Transfers LP tokens from `from` to `to` using caller allowance.
    /// @dev Synchronizes fee snapshots before moving balances and spends finite allowances.
    /// @param from Account whose LP balance is debited.
    /// @param to Recipient of the LP tokens.
    /// @param amount Amount of LP tokens to transfer.
    /// @return success Always returns `true` on success.
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (to == address(0)) revert ZeroAddressTransfer();
        _beforeTokenTransfer(from, to);

        uint256 allowed = allowance[from][msg.sender];

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /// @notice Mints LP tokens to `account`.
    /// @dev Restricted to the hook owner, which is the hook contract that manages the pool.
    /// @param account Recipient of the LP tokens.
    /// @param amount Amount of LP tokens to mint.
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    /// @notice Burns LP tokens from `account`.
    /// @dev Restricted to the hook owner, which is the hook contract that manages the pool.
    /// @param account Account whose LP tokens are burned.
    /// @param amount Amount of LP tokens to burn.
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    /// @notice Sets allowance through an EIP-2612 signature.
    /// @dev Consumes and increments `owner`'s nonce when the signature is valid and not expired.
    /// @param owner Token owner signing the permit.
    /// @param spender Account being approved.
    /// @param value Allowance granted to `spender`.
    /// @param deadline Signature expiry timestamp.
    /// @param v Signature recovery id.
    /// @param r Signature `r` value.
    /// @param s Signature `s` value.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
    {
        require(deadline >= block.timestamp, PermitDeadlineExpired(deadline));

        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                // solhint-disable-next-line gas-small-strings
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                // solhint-disable-next-line gas-increment-by-one
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, InvalidSigner(recoveredAddress, owner));

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    /// @notice Exposes the EIP-712 domain separator used by `permit`.
    /// @dev Recomputes the separator if the chain id changes after deployment.
    /// @return Active EIP-712 domain separator.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                // solhint-disable-next-line gas-small-strings
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;

        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    function _beforeTokenTransfer(address from, address to) internal {
        // Self-transfer (from == to, non-zero) only needs one snapshot: `updateUserSnapshot` is idempotent per
        // address within a single transaction (SwapFacet zero-growth fast path), so the second call would be a pure no-op.
        if (from != address(0)) IMemeverseUniswapHook(memeverseUniswapHook).updateUserSnapshot(poolId, from);
        if (from != to && to != address(0)) IMemeverseUniswapHook(memeverseUniswapHook).updateUserSnapshot(poolId, to);
    }

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
