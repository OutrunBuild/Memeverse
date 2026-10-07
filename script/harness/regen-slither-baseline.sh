#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper: baseline regeneration lives in slither-baseline.sh regen so the
# finding-key normalization and the slither invocation contract are defined exactly once
# for both the regenerator and the gate's check path.

exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slither-baseline.sh" regen "$@"
