# MemeverseV2

Foundry-only workspace.

Project commands:

- `npm run lint`
- `npm run build`
- `npm run test`
- `npm run gas:report`

Harness commands:

- `npm run gate:fast` - rapid local feedback: fmt, lint, build, and changed/mapped tests
- `npm run gate` - default local gate, same as `gate:fast`
- `npm run gate:full` - release-like local gate
- `npm run gate:ci` - CI gate; CI must pass explicit changed-file input

`script/harness/gate.sh --classify-only` emits policy-derived orchestration fields without running verification commands.

## How The Gate Works

1. **Classify surfaces** - every changed file is matched against `.harness/policy.json`.
2. **Classify change class** - Solidity diffs are parsed for semantic changes while ignoring comments, whitespace, and punctuation-only lines.
3. **Select orchestration** - gate emits `orchestration_profile`, `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.
4. **Run verification** - normal gate profiles run commands selected by profile and changed-file scope.
5. **Emit run record** - when `RUN_RECORD_PATH` is set, the gate writes classification, orchestration, command results, and final verdict.

Change classes: `no-op` | `non-semantic` | `test-semantic` | `prod-semantic`.

Orchestration profiles:

| Profile | Meaning |
|---|---|
| `direct` | main session edits; no writer/reviewer dispatch |
| `direct-review` | main session edits; selected reviewers run |
| `delegated` | policy-selected writer handles docs/process/control changes |
| `full-review` | policy-selected writer plus full review matrix |
| `full-subagent` | full review plus independent verifier |
| `blocked` | stop before editing |
| `no-op` | no classified changes |

Production Solidity semantic changes never downgrade by static allowlist and never escalate by static keyword denylist alone. Small localized production Solidity changes may use `direct-review` only after a main-session Risk Analysis Record. If analysis is incomplete or uncertain, use at least `full-review`.

## Verification Commands

| Command | fast | full / ci | Condition |
|---|---|---|---|
| `forge fmt --check` | yes | yes | changed Solidity files |
| `npx solhint` | yes | yes | changed Solidity files |
| `forge build` | yes | yes | always |
| `forge test --match-path` | yes | no | changed/mapped targeted tests |
| `forge test -vvv` | no | yes | full / ci |
| `forge coverage` | no | yes | `change_class=prod-semantic` and `surface_sensitivity=sensitive` |
| `slither` | no | yes | same as coverage, only when changed production Solidity includes `src/**/*.sol` |
| `bash -n` | yes | yes | changed shell files |
| `node --check` | yes | yes | changed JavaScript files |
| `npm ci` | yes | yes | package manifest or lockfile changed |

## Test Mapping

When production Solidity changes, `gate:fast` resolves targeted tests from `policy.json -> test_mapping`. Each rule maps source paths to `change_tests` and `evidence_tests`.

## Git Hooks

`.githooks/` calls the same gate entrypoints when enabled with `core.hooksPath=.githooks`.

## Multi-tool Support (Claude Code / Codex / ZCode)

The repository's harness (policy, gate, reviewer/implementer roles) works across Claude Code, Codex, and ZCode. Each tool loads the shared pieces differently:

| Piece | Claude Code | Codex | ZCode |
|---|---|---|---|
| Instructions | `AGENTS.md` + `CLAUDE.md` | `AGENTS.md` (native) | `AGENTS.md` (native) |
| Subagents | `.claude/agents/*.md` (workspace) | `.codex/agents/*.toml` (workspace) | `.zcode/agents/*.md` (workspace) |
| Hooks | `.claude/settings.json` (PreToolUse) | — | `.zcode/config.json` (`hooks.events`, needs `enabled:true`) |
| Permissions | `.claude/settings.json` allow/deny | — | client permission mode + hooks (no workspace allow/deny file) |

The seven roles (`solidity-implementer`, `process-implementer`, `spec-reviewer`, `logic-reviewer`, `security-reviewer`, `refinement-reviewer`, `verifier`) are kept in three hand-maintained copies. When you change a role, update all three.

ZCode discovers workspace-scoped subagents from `.zcode/agents/` directly (no install step). The `.zcode/agents/` and `.zcode/config.json` files are version-controlled, so `git worktree add` and fresh clones carry them automatically. ZCode also reads user-scoped agents from `~/.zcode/agents/`, but only in the desktop runtime; this repo relies on the workspace scope, which works everywhere.

Hook differences: Claude Code's `EnterWorktree` block has no ZCode equivalent (ZCode supports seven events and `EnterWorktree` is not among them). The `Agent` `isolation:"worktree"` block is effective in Claude Code, where the `Agent` tool has an `isolation` parameter; ZCode's `Agent` tool has no such parameter, so there is nothing to block there, and Codex has no hook mechanism. The shared `block-agent-worktree-isolation.sh` script uses `exit 2` so it blocks correctly under both the Claude Code and ZCode PreToolUse contracts.
