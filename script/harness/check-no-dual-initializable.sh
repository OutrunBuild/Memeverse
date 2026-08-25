#!/usr/bin/env bash
set -euo pipefail

# check-no-dual-initializable.sh — CI guard for the dual Initializable invariant.
#
# Invariant: a single contract MUST NOT inherit both Initializable families:
#   - custom family: src/common/access/Initializable.sol (slot outrun.storage.Initializable)
#     exposed via OutrunOwnableInit / OutrunERC20Init / OutrunOFTInit / OutrunEIP712Init /
#     OutrunNoncesInit / OutrunOAppCoreInit / OutrunOAppOptionsType3Init / OutrunOAppPreCrimeSimulatorInit
#   - OZ family: @openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol
#     (slot openzeppelin.storage.Initializable) exposed via OutrunOwnableUpgradeable / OAppUpgradeable
#
# Mixing would require explicit `override` of initializer/onlyInitializing to compile and could
# then expose two initialize* entries with independent locks, silently allowing double init.
# Current repo has no mixing; this script enforces the invariant.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

allowlist=(
  "src/common/access/Initializable.sol"
  "src/common/access/OutrunOwnableInit.sol"
  "src/common/access/OutrunOwnableUpgradeable.sol"
  "src/common/access/OutrunOwnable.sol"
)

is_allowlisted() {
  local f="$1"
  for a in "${allowlist[@]}"; do
    if [[ "$f" == "$a" ]]; then
      return 0
    fi
  done
  return 1
}

# Only check inheritance/code lines, not import lines (which contain file paths like OutrunERC20Init.sol for IERC20).
# This avoids false positives where a UUPS contract imports an interface from a custom file.
custom_pattern='OutrunOwnableInit|OutrunERC20Init|OutrunOFTInit|OutrunEIP712Init|OutrunNoncesInit|OutrunOAppCoreInit|OutrunOAppOptionsType3Init|OutrunOAppPreCrimeSimulatorInit'
oz_pattern='OutrunOwnableUpgradeable|OAppUpgradeable'

fail=0
while IFS= read -r -d '' file; do
  if is_allowlisted "$file"; then
    continue
  fi
  # Strip import lines to avoid path-string false positives
  body="$(grep -v '^[[:space:]]*import' "$file" || true)"
  has_custom=0
  has_oz=0
  if echo "$body" | grep -Eq "$custom_pattern"; then
    has_custom=1
  fi
  if echo "$body" | grep -Eq "$oz_pattern"; then
    has_oz=1
  fi
  # Also check direct imports of the two Initializable files themselves (rare, but covers raw Initializable mix)
  if grep -q 'src/common/access/Initializable\.sol' "$file" && grep -q '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable\.sol' "$file"; then
    has_custom=1
    has_oz=1
  fi
  if [[ $has_custom -eq 1 && $has_oz -eq 1 ]]; then
    echo "[check-no-dual-initializable] FAIL: $file mixes custom and OZ Initializable families" >&2
    echo "  custom: $(echo "$body" | grep -Eo "$custom_pattern" | head -n 5 | paste -sd ',' -)" >&2
    echo "  oz: $(echo "$body" | grep -Eo "$oz_pattern" | head -n 5 | paste -sd ',' -)" >&2
    fail=1
  fi
done < <(find src -type f -name '*.sol' -print0)

if [[ $fail -eq 1 ]]; then
  echo "[check-no-dual-initializable] invariant violated — single contract must not inherit both Initializable families." >&2
  echo "  See src/common/access/Initializable.sol header" >&2
  exit 1
fi

echo "[check-no-dual-initializable] ok — no dual Initializable inheritance found in src/"
