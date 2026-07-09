#!/usr/bin/env bash
set -euo pipefail

hook_json=$(cat)
isolation=$(jq -r '.tool_input.isolation // empty' <<<"$hook_json")

if [[ "$isolation" == "worktree" ]]; then
  reason='MemeverseV2 禁止 Agent(isolation:"worktree")，因为各 AI 编码工具（Claude Code 等）会自动创建工具专属的隔离 worktree 目录（如 .claude/worktrees/*）。如需隔离写入，请先手动 git worktree add 到 .worktrees/<name>，再让 subagent cd 到该绝对路径；只读 Agent 不要设置 isolation。'
  # stdout: Claude Code reads {continue:false, stopReason} as a block.
  jq -n --arg stopReason "$reason" '{continue: false, stopReason: $stopReason}'
  # stderr + exit 2: ZCode's PreToolUse block contract (exit 2 = deny); also
  # gives Claude Code a fallback reason when it reads stderr on a code-2 exit.
  printf '%s\n' "$reason" >&2
  exit 2
fi
