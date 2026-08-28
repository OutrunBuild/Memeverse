# Memeverse Traceability

- Machine truth: .harness/policy.json
- Session contract: .harness/runtime/main-session-contract.md
- Forge build and worktree rules: .harness/runtime/forge-build-and-worktree.md
- Editing conventions: .harness/runtime/editing-conventions.md
- New `.harness/runtime/` files must be registered in this list in the same change that creates them
- Policy schema: .harness/schemas/policy.schema.json
- Claude agents: .claude/agents/*
- Codex agents: .codex/agents/*
- ZCode agents: .zcode/agents/* (workspace-scoped, version-controlled)
- Pi agents: .pi/agents/* (project-scoped, version-controlled)
- Pi permission system: .pi/extensions/pi-permission-system/config.json (project-scoped, version-controlled)
- Pi Claude-rules loader: .pi/extensions/claude-rules.ts (project-scoped, version-controlled)
- ZCode hooks: ~/.zcode/cli/config.json (user-scope, machine-local, NOT version-controlled)
- Enforcement entrypoint: script/harness/gate.sh
- Scope-rule generator: script/harness/sync-agent-docs.sh (regenerates `.claude/rules/solidity-*.md` from the nested `src/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md`; `--check` verifies no drift)
- Generated scope rules: `.claude/rules/solidity-contracts.md` (from `src/AGENTS.md`), `.claude/rules/solidity-scripts.md` (from `script/AGENTS.md`), `.claude/rules/solidity-tests.md` (from `test/AGENTS.md`)
- CI gate entrypoint: script/harness/ci-gate-entrypoint.sh

Mixed `harness_control` + Solidity changed-file sets are legal. The gate reports phase fields for `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.

Gate signal semantics (`doc_round_required`, `requires_spec_authorization_evidence`, classification-precedes-dispatch) are defined in `.harness/runtime/main-session-contract.md` and `docs/VERIFICATION.md`; this file only registers control-file and artifact locations.
