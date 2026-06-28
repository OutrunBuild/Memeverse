#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

event_name="${HARNESS_EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"

if [ -z "$event_name" ]; then
    echo "HARNESS_EVENT_NAME or GITHUB_EVENT_NAME is required" >&2
    exit 1
fi

# CI runs the full ci gate over every surface file (--all) on every push/PR,
# regardless of the diff: forge_test_full (full test suite) + forge_build +
# coverage + slither + full fmt/lint/bash/node checks. This is the full
# backstop for the local gate:fast pre-push, which only runs targeted tests.
npm run gate:ci -- --all
