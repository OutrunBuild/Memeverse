// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IMemeverseSwapRouter} from "../../../src/swap/interfaces/IMemeverseSwapRouter.sol";
import {MemeverseSwapForkBase} from "./MemeverseSwapForkBase.sol";

contract MemeverseSwapForkPermit2Test is MemeverseSwapForkBase {
    IPermit2 internal permit2;
    uint256 internal constant ALICE_PK = 0xA11CE;
    address internal aliceSigner;

    function setUp() public {
        permit2 = IPermit2(V4_PERMIT2);
        _setUpBase(permit2);
        _hook().setProtocolFeeCurrency(key.currency0, true);
        _matureLaunchWindow();

        aliceSigner = vm.addr(ALICE_PK);
        token0.mint(aliceSigner, 1_000 ether);
        vm.startPrank(aliceSigner);
        token0.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function testSwapWithPermit2_PullsAndSwaps() external {
        uint256 amount = 100 ether;

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: _validExecutionPriceLimit(true)
        });

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token0), amount: amount}),
            nonce: 1,
            deadline: block.timestamp
        });
        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({to: address(router), requestedAmount: amount});

        // Witness must match router._swapPermit2Witness EXACTLY: poolId, zeroForOne, amountSpecified,
        // sqrtPriceLimitX96, recipient, deadline, amountOutMinimum, amountInMaximum, hookDataHash.
        bytes32 witness = keccak256(
            abi.encode(
                keccak256(
                    "MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)"
                ),
                key.toId(),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                aliceSigner,
                block.timestamp,
                uint256(0),
                amount,
                keccak256(bytes(""))
            )
        );

        // structHash mirrors PermitHash.hashWithWitness: spender is msg.sender from the Permit2
        // entrypoint's perspective, which is the router (it calls permitWitnessTransferFrom).
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), address(token0), amount));
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                "MemeverseSwapWitness witness)MemeverseSwapWitness(bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline,uint256 amountOutMinimum,uint256 amountInMaximum,bytes32 hookDataHash)TokenPermissions(address token,uint256 amount)"
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, tokenPermissionsHash, address(router), uint256(1), uint256(block.timestamp), witness)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 aliceBefore = token0.balanceOf(aliceSigner);
        // Open a session (principal = this test contract, independent of the pranked Permit2 caller) so the
        // swap passes the hook's session gate.
        _hook().beginAccountSession();
        vm.prank(aliceSigner);
        router.swapWithPermit2(
            IMemeverseSwapRouter.Permit2SingleParams({permit: permit, transferDetails: details, signature: sig}),
            key,
            params,
            aliceSigner,
            block.timestamp,
            0,
            amount,
            ""
        );
        _hook().endAccountSession();
        assertEq(aliceBefore - token0.balanceOf(aliceSigner), amount, "permit2 pulled exact input");
        assertGt(token1.balanceOf(aliceSigner), 0, "alice received output");
    }
}
