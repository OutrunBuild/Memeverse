@AGENTS.md

## Agent vs Skill Dispatch (Claude Code only)

Names under `.claude/agents/` — `spec-reviewer`, `security-reviewer`, `logic-reviewer`, `refinement-reviewer`, `verifier`, `process-implementer`, `solidity-implementer`, etc. — are **agents**. Dispatch them with the Agent tool (`subagent_type`), never with the Skill tool. Calling an agent via the Skill tool fails with `Unknown skill: <name>`.

The Skill tool is only for registered skills (slash commands / plugin skills). If unsure whether a name is an agent or a skill, check `.claude/agents/` first.

## Worktree tooling (Claude Code only)

This project keeps worktrees under `.worktrees/` (see .harness/runtime/forge-build-and-worktree.md "Worktree Dependency Rule"; `script/harness/prepare-worktree-libs.sh` only recognizes `.worktrees/*`). For tasks that edit repo files, do NOT use the Agent tool's `isolation: "worktree"` option or the `EnterWorktree` tool — both place the worktree under `.claude/worktrees/`, which `prepare-worktree-libs.sh` ignores, so the worktree lacks `lib/` and every `forge`/`gate.sh` run fails. When isolation is genuinely needed, create the worktree manually: `git worktree add .worktrees/<name>`.
