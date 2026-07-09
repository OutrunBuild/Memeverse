#!/usr/bin/env bash
set -euo pipefail

input="$(cat || true)"
# file_path lives under .tool_input.file_path in both Claude Code and ZCode
# PreToolUse stdin JSON; fall back to the top-level field for older shapes.
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null || true)"

if [ -z "$file_path" ]; then
    exit 0
fi

repo_root=""
dir="$(cd "$(dirname "$file_path")" 2>/dev/null && pwd 2>/dev/null || echo "/")"
while [ "$dir" != "/" ]; do
    if [ -f "$dir/.harness/policy.json" ]; then
        repo_root="$dir"
        break
    fi
    dir="$(dirname "$dir")"
done

if [ -z "$repo_root" ]; then
    exit 0
fi

echo "[harness] This repo has .harness/policy.json. Before repository edits, run gate.sh --classify-only --planned-files with the exact planned-file set. Follow emitted orchestration_profile and phase fields. Main session may edit direct/direct-review. delegated/full-review/full-subagent must use configured writers/reviewers."
exit 0
