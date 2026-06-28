#!/usr/bin/env bash
set -euo pipefail

hook_json=$(cat)
isolation=$(jq -r '.tool_input.isolation // empty' <<<"$hook_json")

if [[ "$isolation" == "worktree" ]]; then
  jq -n \
    --arg stopReason 'MemeverseV2 禁止 Agent(isolation:"worktree")，因为 Claude Code 会自动创建 .claude/worktrees/*。如需隔离写入，请先手动创建 git worktree 到 .worktrees/<name>，再让 subagent cd 到该绝对路径；只读 Agent 不要设置 isolation。' \
    '{continue: false, stopReason: $stopReason}'
fi
