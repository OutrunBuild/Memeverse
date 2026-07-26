#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: capture-ownership-baseline.sh <snapshot-dir> --files <path...>

Capture the tracked Git worktree base plus private copies of requested
untracked or ignored regular files and symlinks. The caller must create an
empty snapshot directory before invoking this command.
EOF
}

fail() {
    echo "capture-ownership-baseline: $*" >&2
    exit 2
}

canonicalize_path() {
    local input="$1"
    local remaining component
    local -a components=()

    [ -n "$input" ] && [[ "$input" != /* ]] || return 1
    remaining="$input"
    while [ -n "$remaining" ]; do
        component="${remaining%%/*}"
        if [[ "$remaining" == */* ]]; then
            remaining="${remaining#*/}"
        else
            remaining=""
        fi

        case "$component" in
            ''|.)
                ;;
            ..)
                [ "${#components[@]}" -gt 0 ] || return 1
                components=("${components[@]:0:${#components[@]} - 1}")
                ;;
            *)
                components+=("$component")
                ;;
        esac
    done

    [ "${#components[@]}" -gt 0 ] || return 1
    CANONICAL_PATH="${components[0]}"
    local index
    for ((index = 1; index < ${#components[@]}; index++)); do
        CANONICAL_PATH+="/${components[index]}"
    done
}

path_type() {
    local path="$1"

    if [ -L "$path" ]; then
        printf '%s\n' symlink
    elif [ -f "$path" ]; then
        printf '%s\n' regular
    elif [ -e "$path" ]; then
        return 1
    else
        printf '%s\n' absent
    fi
}

content_hash() {
    local path="$1"
    local type="$2"

    case "$type" in
        regular)
            sha256sum -- "$path" | awk '{print $1}'
            ;;
        symlink)
            readlink -z -- "$path" | head -c -1 | sha256sum | awk '{print $1}'
            ;;
        *)
            return 1
            ;;
    esac
}

snapshot_dir=""
files=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --files)
            shift
            [ "$#" -gt 0 ] || { usage; exit 2; }
            while [ "$#" -gt 0 ] && [[ "$1" != --* ]]; do
                files+=("$1")
                shift
            done
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            if [ -z "$snapshot_dir" ]; then
                snapshot_dir="$1"
            else
                fail "unexpected positional argument: $1"
            fi
            shift
            ;;
    esac
done

[ -n "$snapshot_dir" ] || { usage; exit 2; }
[ "${#files[@]}" -gt 0 ] || { usage; exit 2; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fail "must run inside a Git worktree"
[ -d "$snapshot_dir" ] || fail "snapshot directory does not exist: $snapshot_dir"
snapshot_dir="$(cd -- "$snapshot_dir" && pwd -P)" \
    || fail "cannot resolve snapshot directory: $snapshot_dir"

shopt -s dotglob nullglob
snapshot_entries=("$snapshot_dir"/*)
shopt -u dotglob nullglob
[ "${#snapshot_entries[@]}" -eq 0 ] \
    || fail "snapshot directory must be empty: $snapshot_dir"

declare -A seen_paths=()
canonical_paths=()
for file in "${files[@]}"; do
    canonicalize_path "$file" || fail "path must be repository-relative: $file"
    canonical="$CANONICAL_PATH"
    if [ -n "${seen_paths["$canonical"]+set}" ]; then
        fail "duplicate canonical path: $canonical"
    fi
    seen_paths["$canonical"]=1
    canonical_paths+=("$canonical")
done
mapfile -d '' -t files < <(printf '%s\0' "${canonical_paths[@]}" | LC_ALL=C sort -z)

cd "$repo_root"
for file in "${files[@]}"; do
    if [[ "$file" == */* ]]; then
        parent="${file%/*}"
    else
        parent="."
    fi
    resolved_parent="$(realpath -m -- "$repo_root/$parent")" \
        || fail "cannot resolve parent for path: $file"
    case "$resolved_parent" in
        "$repo_root"|"$repo_root"/*)
            ;;
        *)
            fail "path escapes repository through a symlinked parent: $file"
            ;;
    esac
done

if ! tracked_base="$(git stash create)"; then
    fail "git stash create failed"
fi
if [ -z "$tracked_base" ]; then
    tracked_base="$(git rev-parse --verify HEAD 2>/dev/null)" \
        || fail "cannot resolve HEAD fallback for tracked base"
else
    git rev-parse --verify --quiet "$tracked_base^{commit}" >/dev/null \
        || fail "git stash create returned an invalid tracked base"
fi
printf '%s\n' "$tracked_base" >"$snapshot_dir/tracked-base"

manifest_files='[]'
for file in "${files[@]}"; do
    current_path="$repo_root/$file"
    if git cat-file -e "$tracked_base:$file" 2>/dev/null; then
        state=tracked
    elif [ -e "$current_path" ] || [ -L "$current_path" ]; then
        state=untracked-present
    else
        state=absent
    fi

    if [ "$state" = tracked ] || [ "$state" = absent ]; then
        entry="$(jq -nc --arg path "$file" --arg state "$state" \
            '{path:$path,state:$state}')"
    else
        type="$(path_type "$current_path")" \
            || fail "only regular files and symlinks are supported: $file"
        [ "$type" != absent ] || fail "path disappeared while capturing: $file"
        mode="$(stat -c '%a' -- "$current_path")" \
            || fail "cannot read mode: $file"
        hash="$(content_hash "$current_path" "$type")" \
            || fail "cannot hash content: $file"
        entry="$(jq -nc \
            --arg path "$file" \
            --arg state "$state" \
            --arg type "$type" \
            --arg mode "$mode" \
            --arg content_hash "$hash" \
            '{path:$path,state:$state,type:$type,mode:$mode,content_hash:$content_hash}')"

        if [ "$state" = untracked-present ]; then
            destination="$snapshot_dir/untracked/$file"
            mkdir -p -- "$(dirname -- "$destination")"
            cp -a -- "$current_path" "$destination" \
                || fail "cannot copy untracked baseline: $file"
        fi
    fi
    manifest_files="$(jq -nc --argjson files "$manifest_files" --argjson entry "$entry" \
        '$files + [$entry]')"
done

jq -nc \
    --arg tracked_base "$tracked_base" \
    --argjson files "$manifest_files" \
    '{tracked_base:$tracked_base,files:$files}' >"$snapshot_dir/manifest.json"
