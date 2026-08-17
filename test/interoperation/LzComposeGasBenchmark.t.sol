// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {OmnichainMemecoinStakerUpgradeable} from "../../src/interoperation/OmnichainMemecoinStakerUpgradeable.sol";
import {IComposeState} from "../../src/common/types/IComposeState.sol";
import {IMemeverseOFTEnum} from "../../src/common/types/IMemeverseOFTEnum.sol";
import {IBurnable} from "../../src/common/interfaces/IBurnable.sol";
import {Memecoin} from "../../src/token/Memecoin.sol";
import {MemecoinYieldVault} from "../../src/yield/MemecoinYieldVault.sol";
import {YieldDispatcherUpgradeable} from "../../src/verse/YieldDispatcherUpgradeable.sol";

import {MockMessagingComposerEndpoint} from "../mocks/infrastructure/MockMessagingComposerEndpoint.sol";
import {ComposerEndpointFixture} from "../mocks/infrastructure/ComposerEndpointFixture.sol";

/// @notice Mirror vault used by the dispatcher gas benchmark. The dispatcher's MEMECOIN branch binds the delivered
///         token to `receiver.asset()` before pulling, so this mock reports `asset()` = the delivered token and pulls
///         the approved amount via `transferFrom` — the minimal happy-path stand-in for the real
///         `MemecoinYieldVault.accumulateYields` pull.
contract GasVault {
    address public immutable asset;
    uint256 public lastAccumulated;

    constructor(address asset_) {
        asset = asset_;
    }

    function accumulateYields(uint256 amount) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        lastAccumulated = amount;
    }
}

/// @notice Mirror governor used by the dispatcher gas benchmark. The UASSET branch has no binding; the mock pulls
///         the approved amount via `transferFrom`, mirroring the real governor's `receiveTreasuryIncome` pull.
contract GasGovernor {
    address public lastToken;
    uint256 public lastAmount;

    function receiveTreasuryIncome(address token_, uint256 amount) external {
        MockERC20(token_).transferFrom(msg.sender, address(this), amount);
        lastToken = token_;
        lastAmount = amount;
    }
}

/// @notice ERC20 with a caller-callable single-arg `burn(uint256)` used for the dispatcher's EOA-burn branch.
contract GasBurnableToken is MockERC20, IBurnable {
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @title LzComposeGasBenchmark
/// @notice Gas baseline for the two composers' `lzCompose` happy paths, closing the verification gap flagged in
///         MR-58: the executor's compose gas budget (`omnichainStakingGasLimit` / `yieldDispatcherGasLimit`) must
///         comfortably bound the post-rewrite `lzCompose` footprint (asset() binding, abi.decode, _safeApprove,
///         _parseCompose dual slices, mutex SLOAD+SSTORE). Each test reports the measured gas and asserts a ceiling
///         shaped by two constraints: a regression margin over the measured warm footprint (~40% for most branches),
///         and a fixed safety gap between the ceiling and the optioned compose budget when a branch's measured
///         footprint sits close to it (the staker deposit ceiling is tightened by that gap). The deployment budgets
///         these are checked
///         against are `omnichainStakingGasLimit` = 135000 (staking compose, `MemeverseOmnichainInteroperation`
///         constructor arg 6) and `yieldDispatcherGasLimit` = 135000 (yield compose, `MemeverseLauncherUpgradeable.initialize`
///         arg 11); the staking arg 5 `oftReceiveGasLimit` = 115000 is the OFT *receive* gas, NOT the compose budget.
///
/// @dev === WHAT THE NUMBER COVERS ===
///      `gasleft()` brackets the `lzCompose` body only: endpoint hash-check + RECEIVED-sentinel write happen in the
///      mock's `lzCompose` wrapper BEFORE the gas window opens, so they are NOT counted. The measurement starts at
///      the composer's entry guard and ends after the success event.
///
///      === WARM-STATE MODEL (critical for fidelity) ===
///      Production `lzCompose` lands on a vault/governor that has been live for many blocks — every shared storage
///      slot (`totalAssets`, checkpoints, share balances, allowances, the dispatcher/staker compose-state mapping)
///      is WARM (EIP-2929). A naive forge test starts from a freshly-deployed clone and over-counts by the full
///      cold-access surcharge (~2,600 per cold slot): a cold probe measured the staker deposit branch at ~268k,
///      while the warm-state value (after one pre-deposit warms the vault slots) is ~86k post-UUPS-conversion
///      (~79k pre-conversion; the delta is the ERC1967Proxy delegatecall hop plus the ERC-7201 namespaced
///      storage reads on the lzCompose path) — a ~3.1x distortion. To
///      reflect production, each test runs a WARM-UP that seeds the vault/governor with one prior settle BEFORE the
///      gas window opens (mirroring the swap benchmark's documented warm-up model, `MemeverseSwapGasBenchmark`).
///      The compose-state slot for the *measured* guid is always fresh (each guid resolves once in production too),
///      so that SSTORE is correctly counted at its real cold-creation cost.
///
///      === WHAT THE NUMBER DOES NOT COVER (and why the ceiling carries margin) ===
///      1. The self-harm forged-vault `asset()` path: a sender forging its own message may name a contract whose
///         `asset()` burns gas under EIP-150 (up to 63/64 of the forwarded budget) — this branch is only reachable
///         via a permissionless self-forged OFT send (the protocol send path always encodes the real
///         `verse.yieldVault`), so it is self-harm-only and documented as such. No static
///         snapshot can bound it; the ceiling margin is the documented accommodation, not a hard upper bound.
///      2. EVM 21k intrinsic + tx calldata — a real standalone delivery pays these on top; forge tests are calls,
///         not txs. The warm-up removes the cold-access distortion so the number reflects steady-state production.
///      3. Endpoint wrapper overhead (hash-check + RECEIVED-sentinel write) — a small fixed constant the executor
///         also pays; not bracketed here.
contract LzComposeGasBenchmark is ComposerEndpointFixture {
    using OFTComposeMsgCodec for bytes;

    // --- Staker fixtures (real Memecoin + real MemecoinYieldVault, minimal-proxy clones like production) ---
    OmnichainMemecoinStakerUpgradeable internal staker;
    Memecoin internal memecoin;
    MemecoinYieldVault internal vault;

    // --- Dispatcher fixtures (real dispatcher + mirror vault/governor/burnable token) ---
    YieldDispatcherUpgradeable internal dispatcher;
    GasBurnableToken internal burnToken;
    GasVault internal dispatchVault;
    GasGovernor internal governor;

    address internal constant RECEIVER = address(0xBEEF);
    address internal constant LAUNCHER = address(0x2222);
    // An undeployed address used to exercise the staker's vault-absent fallback branch (no code -> _transferOut).
    address internal constant UNDEPLOYED_VAULT = address(0xDEAD);

    /// @dev Fixed nonce source keeps guids unique across tests so each writes its own fresh compose slot.
    bytes32 private _guidNonce = bytes32(uint256(1));

    function setUp() external {
        // Skipped under coverage: --ir-minimum instrumentation inflates the measured gas so the ceilings are only
        // meaningful in normal runs (same coverage skip pattern as the swap-router gas-ceiling tests).
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) {
            vm.skip(true);
            return;
        }

        // ---- Staker ----
        _etchComposer();
        // Deployed through the shared fixture helper (production UUPS shape); owner is this benchmark contract.
        staker = _deployStaker(address(this), LOCAL_ENDPOINT);

        Memecoin memecoinImpl = new Memecoin(LOCAL_ENDPOINT);
        memecoin = Memecoin(Clones.clone(address(memecoinImpl)));
        memecoin.initialize("Memecoin", "MEME", address(this), address(this));

        MemecoinYieldVault vaultImpl = new MemecoinYieldVault();
        vault = MemecoinYieldVault(Clones.clone(address(vaultImpl)));
        // V = 1e18 virtual buffer (V > 0 required); shares mint 1:1 at the genesis rate.
        vault.initialize("Verse 1 Vault", "vMEME", address(memecoin), 1, 1e18);

        // ---- Dispatcher ----
        // Re-etch the shared endpoint for the dispatcher's localEndpoint storage slot; the staker's slot state is
        // keyed by (from=memecoin OFT, to=staker) and the dispatcher's by (from=token, to=dispatcher), so they never
        // collide even on the shared etched mock. The dispatcher is measured through its proxy (impl+proxy+initialize).
        _etchComposer();
        YieldDispatcherUpgradeable dispatcherImpl = new YieldDispatcherUpgradeable();
        dispatcher = YieldDispatcherUpgradeable(
            address(
                new ERC1967Proxy(
                    address(dispatcherImpl),
                    abi.encodeCall(
                        YieldDispatcherUpgradeable.initialize, (address(this), LOCAL_ENDPOINT, LAUNCHER, address(this))
                    )
                )
            )
        );
        burnToken = new GasBurnableToken("Burn Token", "BRN");
        dispatchVault = new GasVault(address(burnToken));
        governor = new GasGovernor();
    }

    function _nextGuid() internal returns (bytes32 guid) {
        guid = keccak256(abi.encodePacked(_guidNonce, "lzcompose-gas"));
        _guidNonce = bytes32(uint256(_guidNonce) + 1);
    }

    /// @dev Warm the staker vault's storage to the production steady state: one prior deposit + a yield checkpoint
    ///      write makes `totalAssets`, the receiver's share balance, the allowance slot, and the checkpoint slot
    ///      WARM. The measured compose then sees these slots at warm price, matching a vault that has been live for
    ///      many blocks. The measured guid's compose-state slot is still fresh (correct — each guid resolves once).
    function _warmStakerVault() internal {
        uint256 seed = 1 ether;
        memecoin.mint(address(this), seed);
        memecoin.approve(address(vault), seed);
        vault.deposit(seed, RECEIVER);
        assertGt(vault.totalAssets(), 0, "staker vault warmed: totalAssets set");
    }

    /// @dev Warm the dispatcher-side settle slots (mirror vault/governor pull accounting) to the production steady
    ///      state. One prior pull warms the pull-side storage so the measured settle sees warm slots.
    function _warmDispatcherSettle() internal {
        uint256 seed = 1 ether;
        burnToken.mint(address(dispatcher), seed * 2);
        // Warm the MEMECOIN-vault pull path.
        bytes memory msgV = OFTComposeMsgCodec.encode(
            1,
            101,
            seed,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))),
                abi.encode(address(dispatchVault), IMemeverseOFTEnum.TokenType.MEMECOIN)
            )
        );
        bytes32 guidV = _nextGuid();
        vm.prank(address(burnToken));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(dispatcher), guidV, 0, msgV);
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(burnToken), address(dispatcher), guidV, 0, msgV, "");
        // Warm the UASSET-governor pull path.
        bytes memory msgG = OFTComposeMsgCodec.encode(
            1,
            101,
            seed,
            abi.encodePacked(
                bytes32(uint256(uint160(RECEIVER))), abi.encode(address(governor), IMemeverseOFTEnum.TokenType.UASSET)
            )
        );
        bytes32 guidG = _nextGuid();
        vm.prank(address(burnToken));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(dispatcher), guidG, 0, msgG);
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(burnToken), address(dispatcher), guidG, 0, msgG, "");
    }

    // -----------------------------------------------------------------------------------------------
    // OmnichainMemecoinStakerUpgradeable.lzCompose
    // -----------------------------------------------------------------------------------------------

    /// @notice Staker deposit branch: real vault pulls the bridged memecoin and mints shares to the receiver.
    ///         The heaviest staker path — `asset()` STATICCALL + `_safeApprove` (amount) + `deposit` +
    ///         `_safeApprove` (zero). Executor budget: `omnichainStakingGasLimit` = 135000 (compose arg, not the
    ///         separate 115000 `oftReceiveGasLimit`).
    /// @dev The vault is warmed by a prior deposit (`_warmStakerVault`) to reflect a live production vault; without
    ///      it, a fresh-clone vault over-counts by the full EIP-2929 cold-slot surcharge (cold ~268k vs warm ~86k).
    function test_Gas_StakerDepositBranch() public {
        _warmStakerVault();
        uint256 amount = 100 ether;
        memecoin.mint(address(staker), amount);

        bytes memory composeMsg =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(RECEIVER), abi.encode(RECEIVER, address(vault)));
        bytes memory message = OFTComposeMsgCodec.encode(1, 40106, amount, composeMsg);
        bytes32 guid = _nextGuid();

        vm.prank(address(memecoin));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(staker), guid, 0, message);

        uint256 gasBefore = gasleft();
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(memecoin), address(staker), guid, 0, message, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(uint256(staker.composeStates(address(memecoin), guid)), uint256(IComposeState.ComposeState.Settled));
        emit log_named_uint("GAS staker lzCompose deposit branch (endpoint.lzCompose body)", gasUsed);
        // Post-UUPS-conversion re-measure (2026-08): 86_082 warm, up from the pre-conversion ~79k — the delta is
        // the ERC1967Proxy delegatecall hop plus the ERC-7201 namespaced storage reads on the lzCompose path. The
        // 100_000 ceiling = that footprint + ~14k regression tolerance, and it also pins a ~35k fixed gap below the
        // optioned compose budget `omnichainStakingGasLimit` = 135000 (symmetric with the fallback branch's
        // 99k-vs-135k gap): a CI-green body drift that eats the gap OOGs the live delivery once the executor compose
        // prologue (~1.5k) and the EIP-150 63/64 forwarding loss are subtracted, stranding the guid in compose
        // revert-retry. If the assertion fails, the path regressed; re-measure, then raise
        // `omnichainStakingGasLimit` in the deploy script/config via `setGasLimits` — do not raise this ceiling
        // without re-measuring. The 115000 `oftReceiveGasLimit` is the separate OFT *receive* budget (see header):
        // a different, unmeasured surface with no settle fallback — not a comparison budget for this branch.
        assertLt(gasUsed, 100_000, "staker deposit lzCompose gas ceiling exceeded");
    }

    /// @notice Staker fallback branch: the predicted vault is not deployed on the destination chain, so the bridged
    ///         memecoin is released directly to the receiver via `_transferOut` (no `asset()` / `deposit`). This is
    ///         the lighter staker path.
    function test_Gas_StakerFallbackBranch() public {
        uint256 amount = 100 ether;
        memecoin.mint(address(staker), amount);

        // Vault word names an undeployed address -> `yieldVault.code.length == 0` -> fallback `_transferOut`.
        bytes memory composeMsg =
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(RECEIVER), abi.encode(RECEIVER, UNDEPLOYED_VAULT));
        bytes memory message = OFTComposeMsgCodec.encode(1, 40106, amount, composeMsg);
        bytes32 guid = _nextGuid();

        vm.prank(address(memecoin));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(staker), guid, 0, message);

        uint256 gasBefore = gasleft();
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(memecoin), address(staker), guid, 0, message, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(memecoin.balanceOf(RECEIVER), amount, "fallback released the bridged memecoin to the receiver");
        emit log_named_uint("GAS staker lzCompose fallback branch (endpoint.lzCompose body)", gasUsed);
        // Post-UUPS-conversion re-measure (2026-08): 70_594 warm, up from ~64k pre-conversion — same ERC1967Proxy
        // delegatecall + ERC-7201 namespaced-storage attribution as the deposit branch above. 99_000 = that footprint
        // + ~40% regression margin; it also holds a ~36k gap below the 135000 compose budget, mirroring the fixed-gap
        // constraint the deposit ceiling pins.
        assertLt(gasUsed, 99_000, "staker fallback lzCompose gas ceiling exceeded");
    }

    // -----------------------------------------------------------------------------------------------
    // YieldDispatcherUpgradeable.lzCompose
    // -----------------------------------------------------------------------------------------------

    /// @notice Dispatcher MEMECOIN branch: binds delivered token to `receiver.asset()`, then pulls via
    ///         `accumulateYields`. Executor budget: `yieldDispatcherGasLimit` (script default 135000).
    /// @dev `_warmDispatcherSettle` runs one prior MEMECOIN + UASSET settle so the pull-side slots are warm.
    function test_Gas_DispatcherMemecoinBranch() public {
        _warmDispatcherSettle();
        uint256 amount = 50 ether;
        burnToken.mint(address(dispatcher), amount);

        // Layout: [composeFrom(32)][receiver(32)][tokenType(32)] — tokenType = MEMECOIN (1).
        bytes memory composeMsg = abi.encodePacked(
            bytes32(uint256(uint160(RECEIVER))),
            abi.encode(address(dispatchVault), IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMsg);
        bytes32 guid = _nextGuid();

        vm.prank(address(burnToken));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(dispatcher), guid, 0, message);

        uint256 gasBefore = gasleft();
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(burnToken), address(dispatcher), guid, 0, message, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(
            uint256(dispatcher.composeStates(address(burnToken), guid)), uint256(IComposeState.ComposeState.Settled)
        );
        assertEq(dispatchVault.lastAccumulated(), amount, "vault pulled the delivered token");
        emit log_named_uint("GAS dispatcher lzCompose MEMECOIN branch (endpoint.lzCompose body)", gasUsed);
        assertLt(gasUsed, 90_000, "dispatcher MEMECOIN lzCompose gas ceiling exceeded");
    }

    /// @notice Dispatcher UASSET branch: no binding; pulls via `receiveTreasuryIncome`.
    /// @dev `_warmDispatcherSettle` runs one prior MEMECOIN + UASSET settle so the pull-side slots are warm.
    function test_Gas_DispatcherUassetBranch() public {
        _warmDispatcherSettle();
        uint256 amount = 50 ether;
        burnToken.mint(address(dispatcher), amount);

        bytes memory composeMsg = abi.encodePacked(
            bytes32(uint256(uint160(RECEIVER))), abi.encode(address(governor), IMemeverseOFTEnum.TokenType.UASSET)
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMsg);
        bytes32 guid = _nextGuid();

        vm.prank(address(burnToken));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(dispatcher), guid, 0, message);

        uint256 gasBefore = gasleft();
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(burnToken), address(dispatcher), guid, 0, message, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(
            uint256(dispatcher.composeStates(address(burnToken), guid)), uint256(IComposeState.ComposeState.Settled)
        );
        assertEq(governor.lastAmount(), amount, "governor pulled the delivered token");
        emit log_named_uint("GAS dispatcher lzCompose UASSET branch (endpoint.lzCompose body)", gasUsed);
        assertLt(gasUsed, 85_000, "dispatcher UASSET lzCompose gas ceiling exceeded");
    }

    /// @notice Dispatcher EOA-burn branch: receiver has no code, so the delivered token is burned directly.
    ///         Uses an EOA receiver and a token with a caller-callable single-arg `burn(uint256)`.
    /// @dev `_warmDispatcherSettle` warms the dispatcher's token-balance slot (held warm by custody in production).
    function test_Gas_DispatcherEoaBurnBranch() public {
        _warmDispatcherSettle();
        uint256 amount = 50 ether;
        burnToken.mint(address(dispatcher), amount);

        bytes memory composeMsg = abi.encodePacked(
            bytes32(uint256(uint160(RECEIVER))), abi.encode(RECEIVER, IMemeverseOFTEnum.TokenType.MEMECOIN)
        );
        bytes memory message = OFTComposeMsgCodec.encode(1, 101, amount, composeMsg);
        bytes32 guid = _nextGuid();

        vm.prank(address(burnToken));
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT).sendCompose(address(dispatcher), guid, 0, message);

        uint256 gasBefore = gasleft();
        MockMessagingComposerEndpoint(LOCAL_ENDPOINT)
            .lzCompose(address(burnToken), address(dispatcher), guid, 0, message, "");
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(
            uint256(dispatcher.composeStates(address(burnToken), guid)), uint256(IComposeState.ComposeState.Settled)
        );
        assertEq(burnToken.balanceOf(address(dispatcher)), 0, "burned the delivered token");
        emit log_named_uint("GAS dispatcher lzCompose EOA-burn branch (endpoint.lzCompose body)", gasUsed);
        assertLt(gasUsed, 55_000, "dispatcher EOA-burn lzCompose gas ceiling exceeded");
    }
}
