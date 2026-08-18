// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {MemeverseSwapRouter} from "../../../src/swap/MemeverseSwapRouter.sol";
import {MemeverseUniswapHookLens} from "../../../src/swap/MemeverseUniswapHookLens.sol";
import {MemeverseUniswapHookUpgradeable} from "../../../src/swap/MemeverseUniswapHookUpgradeable.sol";
import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {IMemeverseUniswapHook} from "../../../src/swap/interfaces/IMemeverseUniswapHook.sol";

import {RealisticSwapManagerHarness} from "../../mocks/swap/RealisticSwapMocks.sol";
import {HookStorageHelper} from "../../mocks/swap/HookStorageHelper.sol";

contract UnlockSwapIntegrator is IUnlockCallback {
    using SafeERC20 for IERC20;

    RealisticSwapManagerHarness internal immutable manager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(RealisticSwapManagerHarness manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, address recipient, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        if (delta.amount0() < 0) {
            manager.sync(data.key.currency0);
            IERC20(Currency.unwrap(data.key.currency0))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount0())));
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(data.key.currency1);
            IERC20(Currency.unwrap(data.key.currency1))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount1())));
            manager.settle();
        }
        if (delta.amount0() > 0) {
            manager.take(data.key.currency0, data.recipient, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(data.key.currency1, data.recipient, uint256(int256(delta.amount1())));
        }

        return abi.encode(delta);
    }
}

contract RawTransferSwapIntegrator is IUnlockCallback {
    using SafeERC20 for IERC20;

    RealisticSwapManagerHarness internal immutable manager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(RealisticSwapManagerHarness manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, address recipient, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        if (delta.amount0() < 0) {
            IERC20(Currency.unwrap(data.key.currency0))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            IERC20(Currency.unwrap(data.key.currency1))
                .safeTransferFrom(data.payer, address(manager), uint256(int256(-delta.amount1())));
        }

        return abi.encode(delta);
    }
}

abstract contract RealisticSwapIntegrationBase is Test, HookStorageHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant FEE_GROWTH_Q128 = uint256(1) << 128;
    bytes32 internal constant SWAP_WITNESS_TYPEHASH = keccak256(
        "MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)"
    );
    string internal constant SWAP_WITNESS_TYPE_STRING =
        "MemeverseSwapWitness witness)MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)TokenPermissions(address token,uint256 amount)";

    struct RollbackSnapshot {
        uint256 payer0;
        uint256 payer1;
        uint256 treasury0;
        uint256 treasury1;
        uint256 fee0PerShare;
        uint256 fee1PerShare;
        uint256 weightedVolume0;
        uint256 ewVWAPX18;
        uint160 volAnchorSqrtPriceX96;
        uint24 volDeviationAccumulator;
        uint24 shortImpactPpm;
    }

    RealisticSwapManagerHarness internal manager;
    MemeverseUniswapHookUpgradeable internal hook;
    MemeverseUniswapHookLens internal lens;
    MemeverseSwapRouter internal router;
    UnlockSwapIntegrator internal integrator;
    RawTransferSwapIntegrator internal rawTransferIntegrator;
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal treasury;
    address internal alice;
    PoolKey internal key;
    PoolId internal poolId;

    function _setUpIntegration(IPermit2 permit2_) internal {
        manager = new RealisticSwapManagerHarness();
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_PK);

        MockERC20 tokenA = new MockERC20("Token0", "TK0", 18);
        MockERC20 tokenB = new MockERC20("Token1", "TK1", 18);
        // `token0` and `token1` mean Uniswap currency order here, not deployment order.
        // Proxy deployment changes can move token addresses, so sort once before building the PoolKey.
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);

        // Deploy the real MemeverseUniswapHookUpgradeable behind a CREATE2-mined flag-address proxy so production
        // `_validateProxyHookAddress` and facet bindings are exercised.
        // hookOwner = address(this), treasury = treasury.
        address hookProxy = deployHookAtFlagAddress(IPoolManager(address(manager)), address(this), treasury);
        hook = MemeverseUniswapHookUpgradeable(hookProxy);
        lens = new MemeverseUniswapHookLens(IPoolManager(address(manager)));
        router = new MemeverseSwapRouter(
            IPoolManager(address(manager)), IMemeverseUniswapHook(address(hook)), lens, permit2_
        );
        integrator = new UnlockSwapIntegrator(manager);
        rawTransferIntegrator = new RawTransferSwapIntegrator(manager);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(integrator), type(uint256).max);
        token1.approve(address(integrator), type(uint256).max);
        token0.approve(address(rawTransferIntegrator), type(uint256).max);
        token1.approve(address(rawTransferIntegrator), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        hook.setPoolInitializer(address(this));
        hook.authorizePoolInitialization(key, SQRT_PRICE_1_1);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(address(this));
    }

    function _addLiquidity(address recipient) internal returns (uint128 liquidity) {
        (liquidity,) = hook.addLiquidityCore(
            IMemeverseUniswapHook.AddLiquidityCoreParams({
                currency0: key.currency0,
                currency1: key.currency1,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                to: recipient
            })
        );
    }

    function _matureLaunchWindow() internal {
        vm.warp(block.timestamp + 900);
    }

    function _validExecutionPriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _rollbackSnapshot(address payer) internal view returns (RollbackSnapshot memory snapshot) {
        snapshot.payer0 = token0.balanceOf(payer);
        snapshot.payer1 = token1.balanceOf(payer);
        snapshot.treasury0 = token0.balanceOf(treasury);
        snapshot.treasury1 = token1.balanceOf(treasury);
        (, snapshot.fee0PerShare, snapshot.fee1PerShare) = hook.poolInfo(poolId);
        (
            snapshot.weightedVolume0,,
            snapshot.ewVWAPX18,
            snapshot.volAnchorSqrtPriceX96,,
            snapshot.volDeviationAccumulator,,
            snapshot.shortImpactPpm,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
    }

    function _assertRollback(address payer, RollbackSnapshot memory before_) internal view {
        assertEq(token0.balanceOf(payer), before_.payer0, "payer token0 rollback");
        assertEq(token1.balanceOf(payer), before_.payer1, "payer token1 rollback");
        assertEq(token0.balanceOf(treasury), before_.treasury0, "treasury token0 rollback");
        assertEq(token1.balanceOf(treasury), before_.treasury1, "treasury token1 rollback");

        (, uint256 fee0PerShareAfter, uint256 fee1PerShareAfter) = hook.poolInfo(poolId);
        assertEq(fee0PerShareAfter, before_.fee0PerShare, "fee0 per share rollback");
        assertEq(fee1PerShareAfter, before_.fee1PerShare, "fee1 per share rollback");

        (
            uint256 weightedVolume0After,,
            uint256 ewVWAPX18After,
            uint160 volAnchorSqrtPriceX96After,,
            uint24 volDeviationAccumulatorAfter,,
            uint24 shortImpactPpmAfter,
        ) = lens.poolDynamicFeeState(IMemeverseUniswapHook(address(hook)), poolId);
        assertEq(weightedVolume0After, before_.weightedVolume0, "weightedVolume0 rollback");
        assertEq(ewVWAPX18After, before_.ewVWAPX18, "ewvwap rollback");
        assertEq(volAnchorSqrtPriceX96After, before_.volAnchorSqrtPriceX96, "vol anchor rollback");
        assertEq(volDeviationAccumulatorAfter, before_.volDeviationAccumulator, "vol deviation rollback");
        assertEq(shortImpactPpmAfter, before_.shortImpactPpm, "short impact rollback");
    }

    function _singlePermit(address token, uint256 amount)
        internal
        view
        returns (IMemeverseSwapRouter.Permit2SingleParams memory permitParams)
    {
        permitParams = IMemeverseSwapRouter.Permit2SingleParams({
            permit: ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
                nonce: 1,
                deadline: block.timestamp
            }),
            transferDetails: ISignatureTransfer.SignatureTransferDetails({
                to: address(router), requestedAmount: amount
            }),
            signature: hex"1234"
        });
    }

    function _swapWitness(
        PoolKey memory key_,
        SwapParams memory params,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum,
        uint256 amountInMaximum,
        bytes memory hookData
    ) internal pure returns (bytes32 witness) {
        witness = keccak256(
            abi.encode(
                SWAP_WITNESS_TYPEHASH,
                key_.toId(),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                recipient,
                deadline,
                amountOutMinimum,
                amountInMaximum,
                keccak256(hookData)
            )
        );
    }

    function _expectedLpFeeGrowth(uint256 lpFeeAmount) internal view returns (uint256) {
        (address liquidityToken,,) = hook.poolInfo(poolId);
        uint256 activeSupply = IERC20(liquidityToken).balanceOf(address(this));
        return lpFeeAmount == 0 ? 0 : (lpFeeAmount * FEE_GROWTH_Q128) / activeSupply;
    }
}
