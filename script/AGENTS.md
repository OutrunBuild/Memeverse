# Solidity scripts (script/)

Auto-loads when you edit `script/` files. General Solidity style (named imports, ordering, naming) still applies; run `forge fmt`.

## Structure
Split large deploys into focused scripts — `DeployToken.s.sol`, `DeployVault.s.sol` — plus an orchestrator `Deploy.s.sol` whose `run()` instantiates and calls each.

## No hardcoded config or secrets
- Read config from env: `vm.envAddress("ADMIN_ADDRESS")`, `vm.envOr("INITIAL_SUPPLY", uint256(1_000_000 ether))`.
- Keys never in source. Import once: `cast wallet import deployer --interactive`; then deploy with `--account deployer`; mainnet prefers `--ledger`.

## Broadcast & logging
- `vm.startBroadcast()` … `vm.stopBroadcast()` wraps **multiple** transactions; `vm.broadcast()` wraps a **single** call — choose accordingly.
- For multi-step deploys within one script, keep `startBroadcast()` open across all steps (it persists until `stopBroadcast()`). To resume a deployment whose transactions failed or timed out, re-run with `forge script … --resume` (CLI; resubmits from the broadcast log without re-simulating).
- State changes (`new Contract(...)`, sending transactions) must be inside the broadcast region; pure computation/reads can be outside.
- Log results for verification:

```solidity
console.log("Token deployed at:", address(token));
console.log("Chain ID:", block.chainid);
console.log("Deployer:", msg.sender);
```

## Running
- **Simulate before broadcasting**: omitting `--broadcast` is a dry-run/simulate; confirm the trace is correct, then add `--broadcast`.

```bash
# 1) Simulate
forge script script/Deploy.s.sol --rpc-url $RPC_URL
# 2) Real broadcast + verify
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --account deployer --verify
# Hardware signing: use --ledger instead of --account
```

## Key management
| Environment | Key source |
|---|---|
| Local (anvil) | Anvil default keys — publicly known, never on real networks |
| Testnet | Encrypted keystore (`--account <name>`) |
| Mainnet | Hardware wallet (`--ledger`) |

Keep `.env` out of VCS (`.gitignore` lists `.env` / `.env.*`); document required vars in `.env.example` with no real values.

## Comments
Comments and NatSpec MUST be written in English — same rule as `src/AGENTS.md` ("NatSpec").
