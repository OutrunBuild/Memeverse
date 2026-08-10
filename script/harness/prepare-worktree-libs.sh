#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_root="$(cd "$script_dir/../.." && pwd -P)"

case "$script_root" in
    */.worktrees/*)
        canonical_root="${script_root%%/.worktrees/*}"
        ;;
    *)
        canonical_root="$script_root"
        ;;
esac

current_root="$(git rev-parse --show-toplevel)"
canonical_lib="$canonical_root/lib"

if [ "$current_root" = "$canonical_root" ]; then
    echo "canonical worktree: lib already local"
    exit 0
fi

case "$current_root" in
    "$canonical_root"/.worktrees/*)
        ;;
    *)
        echo "blocked: current worktree is not under $canonical_root/.worktrees"
        exit 1
        ;;
esac

expected_dependencies=(
    forge-std
    openzeppelin-contracts-upgradeable
    devtools
    LayerZero-v2
    solidity-bytes-utils
    solmate
    v4-periphery
)

prepare_submodule_worktree() {
    local parent_canonical="$1"
    local parent_current="$2"
    local relative_path="$3"
    local canonical_submodule="$parent_canonical/$relative_path"
    local current_submodule="$parent_current/$relative_path"
    local canonical_top
    local expected_commit

    canonical_top="$(git -C "$canonical_submodule" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$canonical_top" != "$canonical_submodule" ]; then
        echo "blocked: missing initialized canonical submodule $canonical_submodule"
        exit 1
    fi

    expected_commit="$(git -C "$parent_current" rev-parse "HEAD:$relative_path")"
    if ! git -C "$canonical_submodule" cat-file -e "$expected_commit^{commit}" 2>/dev/null; then
        echo "blocked: canonical submodule $canonical_submodule does not contain $expected_commit"
        exit 1
    fi

    if [ "$(git -C "$current_submodule" rev-parse --show-toplevel 2>/dev/null || true)" = "$current_submodule" ]; then
        if [ "$(git -C "$current_submodule" rev-parse HEAD)" != "$expected_commit" ]; then
            echo "blocked: $current_submodule is checked out at a different commit"
            exit 1
        fi
    else
        if [ -e "$current_submodule" ] && find "$current_submodule" -mindepth 1 -print -quit | grep -q .; then
            echo "blocked: existing $current_submodule is non-empty; not deleting automatically"
            exit 1
        fi

        git -C "$canonical_submodule" worktree prune
        rm -rf "$current_submodule"
        mkdir -p "$(dirname "$current_submodule")"
        git -C "$canonical_submodule" worktree add --detach "$current_submodule" "$expected_commit" >/dev/null
    fi

    prepare_initialized_nested_submodules "$canonical_submodule" "$current_submodule"
}

prepare_initialized_nested_submodules() {
    local parent_canonical="$1"
    local parent_current="$2"
    local nested_path

    if [ ! -f "$parent_canonical/.gitmodules" ]; then
        return
    fi

    while IFS= read -r nested_path; do
        if [ -z "$nested_path" ]; then
            continue
        fi

        if [ "$(git -C "$parent_canonical/$nested_path" rev-parse --show-toplevel 2>/dev/null || true)" = "$parent_canonical/$nested_path" ]; then
            prepare_submodule_worktree "$parent_canonical" "$parent_current" "$nested_path"
        fi
    done < <(git -C "$parent_canonical" config --file .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}')
}

for dependency in "${expected_dependencies[@]}"; do
    if [ ! -d "$canonical_lib/$dependency" ]; then
        echo "blocked: missing $canonical_lib/$dependency; prepare canonical dependencies first"
        exit 1
    fi
done

dependency_status="$(git -C "$current_root" status --short -- .gitmodules lib)"
if [ -n "$dependency_status" ]; then
    echo "blocked: dependency paths are dirty in this worktree"
    exit 1
fi

for dependency in "${expected_dependencies[@]}"; do
    prepare_submodule_worktree "$canonical_root" "$current_root" "lib/$dependency"
done

echo "prepared worktree submodules from canonical lib"
