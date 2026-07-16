// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ISignatureTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/ISignatureTransfer.sol";

import {LiquidityAmounts} from "../../../src/swap/libraries/LiquidityAmounts.sol";

/// @dev Mock-harness boundary:
/// - This file's Permit2 and manager mocks only cover local plumbing, witness/deadline handling,
///   local revert surface, and deterministic branch coverage used by the Permit2 router tests.
/// - The newer integration tests only cover a narrow exact-input subset under a stricter manager harness.
///   Exact-output, one-for-zero symmetry outside that subset, and broader Permit2 swap economics claims are not
///   proven by these mocks and must not be inferred from them.
contract MockPoolManagerForPermit2RouterTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error ManagerLocked();
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    struct Slot0State {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    bytes internal constant ZERO_BYTES = bytes("");
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint160 internal constant SQRT_PRICE_LOWER_X96 = 4_310_618_292;
    uint160 internal constant SQRT_PRICE_UPPER_X96 = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;

    bool internal unlocked;
    bool internal enforceV4PriceLimitValidation;
    address internal lastUnlockCallbackPayer;
    mapping(bytes32 => bytes32) internal extStorage;
    mapping(PoolId => Slot0State) internal slot0State;
    mapping(PoolId => uint128) internal liquidityState;
    mapping(PoolId => uint256) internal nextExactInputPoolInputAmount;

    /// @notice Seeds mock pool state and calls the hook initialize callback.
    /// @dev Mimics the minimal pool-manager behavior the router expects during bootstrap.
    /// @param key The pool key being initialized.
    /// @param sqrtPriceX96 The starting pool price.
    /// @return tick The mocked initialized tick, always zero.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId poolId = key.toId();
        slot0State[poolId] = Slot0State({sqrtPriceX96: sqrtPriceX96, tick: 0, protocolFee: 0, lpFee: 0});
        liquidityState[poolId] = 1e24;
        _syncPoolStorage(poolId);
        key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
        tick = 0;
    }

    /// @notice Opens the mock unlock window and forwards the callback payload.
    /// @dev Mirrors the pool manager's unlock callback flow used by the router.
    /// @param data The callback payload forwarded to `unlockCallback`.
    /// @return result The callback return data.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        // 生产 CallbackData 已无 payer 字段；router 始终用自身余额 settle，
        // 因此记录 unlock 发起方作为 lastUnlockPayer 的语义代理。
        lastUnlockCallbackPayer = msg.sender;
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function setEnforceV4PriceLimitValidation(bool enabled) external {
        enforceV4PriceLimitValidation = enabled;
    }

    /// @notice Applies a mocked liquidity modification and returns deterministic deltas.
    /// @dev Uses full-range liquidity math to approximate manager deltas for router tests.
    /// @param key The pool key being modified.
    /// @param params The mocked liquidity modification parameters.
    /// @param hookData Unused hook data forwarded by the router test harness.
    /// @return delta The principal amount delta.
    /// @return feesAccrued The mocked fee delta, always zero here.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        hookData;
        if (!unlocked) revert ManagerLocked();
        uint256 amount0Used;
        uint256 amount1Used;

        if (params.liquidityDelta > 0) {
            key.hooks.beforeAddLiquidity(msg.sender, key, params, ZERO_BYTES);
            liquidityState[key.toId()] += uint128(uint256(params.liquidityDelta));
            _syncPoolStorage(key.toId());
            (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
                slot0State[key.toId()].sqrtPriceX96,
                SQRT_PRICE_LOWER_X96,
                SQRT_PRICE_UPPER_X96,
                uint128(uint256(params.liquidityDelta))
            );
            delta = toBalanceDelta(-int128(int256(amount0Used)), -int128(int256(amount1Used)));
            return (delta, feesAccrued);
        }

        liquidityState[key.toId()] -= uint128(uint256(-params.liquidityDelta));
        _syncPoolStorage(key.toId());
        (amount0Used, amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
            slot0State[key.toId()].sqrtPriceX96,
            SQRT_PRICE_LOWER_X96,
            SQRT_PRICE_UPPER_X96,
            uint128(uint256(-params.liquidityDelta))
        );
        delta = toBalanceDelta(int128(int256(amount0Used)), int128(int256(amount1Used)));
    }

    /// @notice Executes a mocked swap against the configured hook callbacks.
    /// @dev Simulates deterministic local Permit2/router branch coverage rather than real execution economics.
    /// @param key The pool key being swapped against.
    /// @param params The swap parameters.
    /// @param hookData Opaque hook payload forwarded through the mock.
    /// @return delta The resulting swap delta after hook adjustments.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        if (!unlocked) revert ManagerLocked();

        PoolId poolId = key.toId();
        bool callSwapHooks = msg.sender != address(key.hooks);
        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        if (callSwapHooks) {
            (, beforeSwapDelta,) = key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }
        int256 amountToSwap = params.amountSpecified + beforeSwapDelta.getSpecifiedDelta();

        if (enforceV4PriceLimitValidation) {
            Slot0State memory state = slot0State[poolId];
            if (params.zeroForOne) {
                if (params.sqrtPriceLimitX96 >= state.sqrtPriceX96) {
                    revert PriceLimitAlreadyExceeded(state.sqrtPriceX96, params.sqrtPriceLimitX96);
                }
                if (params.sqrtPriceLimitX96 <= SQRT_PRICE_LOWER_X96) {
                    revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
                }
            } else {
                if (params.sqrtPriceLimitX96 <= state.sqrtPriceX96) {
                    revert PriceLimitAlreadyExceeded(state.sqrtPriceX96, params.sqrtPriceLimitX96);
                }
                if (params.sqrtPriceLimitX96 >= SQRT_PRICE_UPPER_X96) {
                    revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
                }
            }
        }

        BalanceDelta poolDelta = BalanceDeltaLibrary.ZERO_DELTA;
        if (amountToSwap != 0) {
            if (params.amountSpecified < 0) {
                uint256 inputAmount = uint256(-amountToSwap);
                uint256 configuredInputAmount = nextExactInputPoolInputAmount[poolId];
                if (configuredInputAmount != 0) {
                    inputAmount = configuredInputAmount;
                    delete nextExactInputPoolInputAmount[poolId];
                }
                uint256 outputAmount = inputAmount / 2;
                if (params.zeroForOne) {
                    poolDelta = toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)));
                } else {
                    poolDelta = toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                }
            } else {
                uint256 outputAmount = uint256(amountToSwap);
                uint256 inputAmount = outputAmount * 2;
                if (params.zeroForOne) {
                    poolDelta = toBalanceDelta(-int128(int256(inputAmount)), int128(int256(outputAmount)));
                } else {
                    poolDelta = toBalanceDelta(int128(int256(outputAmount)), -int128(int256(inputAmount)));
                }
            }
        }

        int128 afterSwapUnspecifiedDelta;
        if (callSwapHooks) {
            (, afterSwapUnspecifiedDelta) = key.hooks.afterSwap(msg.sender, key, params, poolDelta, hookData);
        }

        int128 hookDeltaSpecified = beforeSwapDelta.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapDelta.getUnspecifiedDelta() + afterSwapUnspecifiedDelta;
        if (hookDeltaSpecified != 0 || hookDeltaUnspecified != 0) {
            BalanceDelta hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
            delta = poolDelta - hookDelta;
        } else {
            delta = poolDelta;
        }
    }

    /// @notice Transfers out a mocked currency amount from the manager.
    /// @dev Supports both native and ERC20 settlement paths used by router tests.
    /// @param currency The currency to transfer out.
    /// @param to The recipient address.
    /// @param amount The amount to transfer.
    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool success,) = to.call{value: amount}("");
            require(success, "native take");
        } else {
            require(MockERC20(Currency.unwrap(currency)).transfer(to, amount), "erc20 take");
        }
    }

    /// @notice No-op sync entrypoint for the test harness.
    /// @dev Preserves the pool-manager interface shape expected by the router.
    /// @param currency The currency being synced.
    function sync(Currency currency) external pure {
        currency;
    }

    /// @notice Accepts native settlement and returns the supplied amount.
    /// @dev Matches the pool-manager settle interface used by router settlement helpers.
    /// @return amount The received native amount.
    function settle() external payable returns (uint256) {
        return msg.value;
    }

    /// @notice Returns the mock extsload value for a storage slot.
    /// @dev Allows the hook to read mocked pool-manager storage slots.
    /// @param slot The storage slot to read.
    /// @return value The mocked word stored at `slot`.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return extStorage[slot];
    }

    /// @notice Returns the mocked slot0 tuple for a pool.
    /// @dev Exposes price and fee state to the router and hook tests.
    /// @param poolId The pool identifier.
    /// @return sqrtPriceX96 The mocked square-root price.
    /// @return tick The mocked current tick.
    /// @return protocolFee The mocked protocol fee.
    /// @return lpFee The mocked LP fee.
    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0State memory state = slot0State[poolId];
        return (state.sqrtPriceX96, state.tick, state.protocolFee, state.lpFee);
    }

    /// @notice Returns the mocked liquidity value for a pool.
    /// @dev Exposes pool liquidity to the router and hook tests.
    /// @param poolId The pool identifier.
    /// @return liquidity The mocked active liquidity for the pool.
    function getLiquidity(PoolId poolId) external view returns (uint128) {
        return liquidityState[poolId];
    }

    function setNextExactInputPoolInputAmount(PoolId poolId, uint256 inputAmount) external {
        nextExactInputPoolInputAmount[poolId] = inputAmount;
    }

    function lastUnlockPayer() external view returns (address payer) {
        return lastUnlockCallbackPayer;
    }

    function _syncPoolStorage(PoolId poolId) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        Slot0State memory state = slot0State[poolId];
        extStorage[stateSlot] = bytes32(uint256(state.sqrtPriceX96));
        extStorage[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidityState[poolId]));
    }

    /// @notice Accepts native refunds that the router routes back through the manager.
    /// @dev Gives the mock manager a payable fallback to mirror real routing settlement behavior.
    receive() external payable {}
}

/// @notice Trusting Permit2 double that records witness transfer requests without signature checks.
/// @dev Focuses on observability of router-supplied payloads rather than signature validity.
contract MockPermit2ForRouterTest {
    using SafeERC20 for IERC20;

    address public lastOwner;
    address public lastRecipient;
    address public lastToken;
    uint256 public lastRequestedAmount;
    address public lastBatchOwner;
    uint256 public lastBatchLength;
    bytes32 public lastWitness;
    string public lastWitnessTypeString;
    bytes public lastSignature;

    /// @notice Mocks Permit2 single-token witness transfers and records the last request.
    /// @dev This test double trusts the payload and focuses on observability rather than signature checks.
    /// @param permit The signed Permit2 transfer payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The mocked signature bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        lastOwner = owner;
        lastRecipient = transferDetails.to;
        lastToken = permit.permitted.token;
        lastRequestedAmount = transferDetails.requestedAmount;
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastSignature = signature;

        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    /// @notice Mocks Permit2 batch witness transfers and records the last request.
    /// @dev This test double trusts the payload and focuses on observability rather than signature checks.
    /// @param permit The signed Permit2 batch payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The mocked signature bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        lastBatchOwner = owner;
        lastBatchLength = transferDetails.length;
        lastWitness = witness;
        lastWitnessTypeString = witnessTypeString;
        lastSignature = signature;

        for (uint256 i = 0; i < transferDetails.length; ++i) {
            IERC20(permit.permitted[i].token)
                .safeTransferFrom(owner, transferDetails[i].to, transferDetails[i].requestedAmount);
        }
    }
}

/// @notice Signature-verifying Permit2 double enforcing EIP-712 witness transfer semantics.
/// @dev Reproduces Permit2 nonce, deadline, amount, and signer checks for negative-path router tests.
contract SignatureVerifyingPermit2ForRouterTest {
    using SafeERC20 for IERC20;

    error InvalidAmount(uint256 maxAmount);
    error InvalidNonce();
    error InvalidSigner();
    error LengthMismatch();
    error SignatureExpired(uint256 deadline);

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT_SINGLE_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string internal constant PERMIT_BATCH_WITNESS_TYPEHASH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 internal constant EIP712_NAME_HASH = keccak256("Permit2");

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    /// @notice Returns the EIP-712 domain separator used by the mock Permit2 implementation.
    /// @dev The separator binds signatures to the current chain and mock Permit2 address.
    /// @return separator The computed EIP-712 domain separator.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, block.chainid, address(this)));
    }

    /// @notice Verifies and executes a mocked single-token witness transfer.
    /// @dev Enforces nonce, deadline, amount, and EIP-712 signature validity before transfer.
    /// @param permit The signed Permit2 transfer payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The signed permit bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        if (transferDetails.requestedAmount > permit.permitted.amount) revert InvalidAmount(permit.permitted.amount);

        _useUnorderedNonce(owner, permit.nonce);
        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_SINGLE_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount));
        bytes32 dataHash =
            keccak256(abi.encode(typeHash, tokenPermissionsHash, msg.sender, permit.nonce, permit.deadline, witness));
        _verifySignature(signature, owner, dataHash);
        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    /// @notice Verifies and executes a mocked batch witness transfer.
    /// @dev Enforces nonce, deadline, amount, and EIP-712 signature validity before transfer.
    /// @param permit The signed Permit2 batch payload.
    /// @param transferDetails The requested transfer details.
    /// @param owner The signer and funding account.
    /// @param witness The witness hash supplied by the router.
    /// @param witnessTypeString The witness type string supplied by the router.
    /// @param signature The signed permit bytes.
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired(permit.deadline);
        if (permit.permitted.length != transferDetails.length) revert LengthMismatch();

        _useUnorderedNonce(owner, permit.nonce);
        bytes32[] memory tokenPermissionHashes = new bytes32[](permit.permitted.length);
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            if (transferDetails[i].requestedAmount > permit.permitted[i].amount) {
                revert InvalidAmount(permit.permitted[i].amount);
            }
            tokenPermissionHashes[i] = keccak256(
                abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i].token, permit.permitted[i].amount)
            );
        }

        bytes32 typeHash = keccak256(abi.encodePacked(PERMIT_BATCH_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 dataHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(tokenPermissionHashes)),
                msg.sender,
                permit.nonce,
                permit.deadline,
                witness
            )
        );
        _verifySignature(signature, owner, dataHash);

        for (uint256 i = 0; i < transferDetails.length; ++i) {
            IERC20(permit.permitted[i].token)
                .safeTransferFrom(owner, transferDetails[i].to, transferDetails[i].requestedAmount);
        }
    }

    /// @notice Claims a nonce inside the unordered Permit2 nonce bitmap.
    /// @dev Reproduces Permit2's unordered nonce validation so tests can reject duplicates.
    function _useUnorderedNonce(address from, uint256 nonce) private {
        uint256 wordPos = uint248(nonce >> 8);
        uint256 bitPos = uint8(nonce);
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonceBitmap[from][wordPos] ^= bit;
        if (flipped & bit == 0) revert InvalidNonce();
    }

    /// @notice Checks that the caller-supplied signature recovers the expected owner.
    /// @dev Detects invalid lengths or recovery values just like the production Permit2 reference.
    function _verifySignature(bytes calldata signature, address owner, bytes32 dataHash) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
        if (signature.length != 65) revert InvalidSigner();
        (bytes32 r, bytes32 s) = abi.decode(signature, (bytes32, bytes32));
        uint8 v = uint8(signature[64]);
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != owner) revert InvalidSigner();
    }
}
