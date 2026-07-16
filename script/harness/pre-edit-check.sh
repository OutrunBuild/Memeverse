#!/usr/bin/env bash
# Pre-Edit Reminder Hook (PreToolUse: Edit|Write|MultiEdit)
#
# This hook is a REMINDER, not an enforcer. It always exits 0.
# Ownership of working-tree content is decided by the session (the model),
# which has the context to know what it authored. A hook cannot reliably
# attribute working-tree lines to sessions, so it does not block edits.
# See AGENTS.md "Ownership And Concurrent-Write Guard".

set -euo pipefail

input="$(cat || true)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .toolInput.file_path // .file_path // empty' 2>/dev/null || true)"

if [ -z "$file_path" ]; then
    exit 0
fi

# Locate the harness repo root (nearest ancestor with .harness/policy.json).
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

rel="${file_path#$repo_root/}"

# Reminder only (always exit 0, never block). Emit a strict-JSON object on
# stdout so ZCode/Claude Code parse it as a valid PreToolUse hook result and
# inject the reminder into the conversation via `additionalContext`. A bare
# `echo` would break the JSON stdout contract (hook.run.failed) and the
# reminder would never reach the model. The session — which alone has the
# context to know what it authored — decides whether old_string is its own.
reminder="[harness] Editing $rel — confirm every part of old_string is your session's own content or committed (HEAD) content; never revert another session's uncommitted changes. See AGENTS.md \"Ownership And Concurrent-Write Guard\"."
jq -nc --arg ctx "$reminder" '{additionalContext: $ctx}'

exit 0
