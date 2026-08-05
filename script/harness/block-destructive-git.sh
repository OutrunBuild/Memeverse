#!/usr/bin/env bash
# PreToolUse:Bash hard-block hook. The native helper uses a tree-sitter Bash
# AST and recursively inspects static shell wrappers before applying the Git
# family policy. It never executes the inspected command.
set -euo pipefail

fail_closed() {
  printf '%s\n' '{"continue":false,"stopReason":"[harness] destructive-git guard failed closed"}'
  printf '%s\n' "[harness] destructive-git guard failed closed: $1" >&2
  exit 2
}

script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
if [[ "$script_dir" == "$script_path" ]]; then
  script_dir="."
fi
case "$script_dir" in
  .) repo_root="../.." ;;
  script/harness) repo_root="." ;;
  */script/harness) repo_root="${script_dir%/script/harness}" ;;
  *) fail_closed "hook path is outside script/harness" ;;
esac
crate_dir="$script_dir/destructive-git-guard"
manifest="$crate_dir/Cargo.toml"
target_dir="$repo_root/.harness/.runs/destructive-git-guard"
binary="$target_dir/release/destructive-git-guard"

needs_build=0
if [[ ! -x "$binary" ]]; then
  needs_build=1
else
  for source in "$manifest" "$crate_dir/Cargo.lock" "$crate_dir"/src/*.rs; do
    if [[ "$source" -nt "$binary" ]]; then
      needs_build=1
      break
    fi
  done
fi

if [[ "$needs_build" -eq 1 ]]; then
  cargo_bin="$(command -v cargo)" || fail_closed "Rust 1.93 or newer is required"
  CARGO_TARGET_DIR="$target_dir" "$cargo_bin" build \
    --locked \
    --release \
    --quiet \
    --manifest-path "$manifest" \
    || fail_closed "native helper build failed"
fi

[[ -x "$binary" ]] || fail_closed "native helper is unavailable after build"

set +e
"$binary"
status=$?
set -e

case "$status" in
  0|2) exit "$status" ;;
  *) fail_closed "native helper exited with status $status" ;;
esac
