#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: render-ownership-diff.sh <snapshot-dir> --files <path...>

Render the deterministic complete diff from an ownership snapshot to the
current worktree. Standard output contains only the diff.
EOF
}

fail() {
    echo "render-ownership-diff: $*" >&2
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
[ -f "$snapshot_dir/tracked-base" ] || fail "missing tracked-base in snapshot"
[ -f "$snapshot_dir/manifest.json" ] || fail "missing manifest.json in snapshot"

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

jq -e '
  type == "object" and
  (.tracked_base | type == "string") and
  (.files | type == "array") and
  ([.files[].path] as $paths | ($paths | length) == ($paths | unique | length))
' "$snapshot_dir/manifest.json" >/dev/null \
    || fail "invalid snapshot manifest"
mapfile -d '' -t manifest_files < <(jq -jr '.files[] | (.path, "\u0000")' "$snapshot_dir/manifest.json")
[ "${#manifest_files[@]}" -eq "${#files[@]}" ] \
    || fail "requested files do not match the snapshot manifest"
for index in "${!files[@]}"; do
    [ "${files[index]}" = "${manifest_files[index]}" ] \
        || fail "requested files do not match the snapshot manifest"
done

tracked_base="$(<"$snapshot_dir/tracked-base")"
[ -n "$tracked_base" ] || fail "empty tracked-base in snapshot"
git rev-parse --verify --quiet "$tracked_base^{commit}" >/dev/null \
    || fail "invalid tracked-base in snapshot"

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

output_file="$(mktemp)"
render_root="$(mktemp -d)"
trap 'rm -f "$output_file"; rm -rf "$render_root"' EXIT

run_git_diff() {
    local status

    if git diff "$@" >>"$output_file"; then
        return 0
    else
        status=$?
        [ "$status" -eq 1 ] && return 0
        return "$status"
    fi
}

run_no_index_diff() {
    local file="$1"
    local baseline_path="$2"
    local current_path="$3"
    local left_path="$render_root/a/$file"
    local right_path="$render_root/b/$file"
    local diff_left
    local diff_right
    local pair_output
    local first_line
    local status

    if [ "$baseline_path" != /dev/null ]; then
        mkdir -p -- "$(dirname -- "$left_path")"
        cp -a -- "$baseline_path" "$left_path" \
            || return 2
        diff_left="a/$file"
    else
        diff_left=/dev/null
    fi
    if [ "$current_path" != /dev/null ]; then
        mkdir -p -- "$(dirname -- "$right_path")"
        cp -a -- "$current_path" "$right_path" \
            || return 2
        diff_right="b/$file"
    else
        diff_right=/dev/null
    fi

    pair_output="$(mktemp)"
    if (
        cd "$render_root"
        git diff \
            --no-index --no-ext-diff --no-textconv --no-renames --binary --full-index --no-color \
            --diff-algorithm=myers --no-indent-heuristic --no-prefix \
            -- "$diff_left" "$diff_right" >"$pair_output"
    ); then
        status=0
    else
        status=$?
    fi
    if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
        rm -f "$pair_output"
        return "$status"
    fi

    if [ "$diff_left" = /dev/null ] || [ "$diff_right" = /dev/null ]; then
        IFS= read -r first_line <"$pair_output" || {
            rm -f "$pair_output"
            return 2
        }
        case "$first_line" in
            'diff --git '*)
                printf 'diff --git a/%s b/%s\n' "$file" "$file" >>"$output_file"
                tail -n +2 "$pair_output" >>"$output_file"
                ;;
            *)
                rm -f "$pair_output"
                return 2
                ;;
        esac
    else
        cat "$pair_output" >>"$output_file"
    fi
    rm -f "$pair_output"
}

for file in "${files[@]}"; do
    state="$(jq -er --arg path "$file" \
        '.files[] | select(.path == $path) | .state' "$snapshot_dir/manifest.json")" \
        || fail "missing or invalid manifest state for: $file"
    current_path="$repo_root/$file"

    case "$state" in
        tracked)
            current_type="$(path_type "$current_path")" \
                || fail "only regular files and symlinks are supported: $file"
            if [ "$current_type" = absent ] || [ "$current_type" = regular ] || [ "$current_type" = symlink ]; then
                run_git_diff \
                    --no-ext-diff --no-textconv --no-renames --binary --full-index --no-color \
                    --diff-algorithm=myers --no-indent-heuristic --src-prefix=a/ --dst-prefix=b/ \
                    "$tracked_base" -- "$file" \
                    || fail "git diff failed for tracked path: $file"
            fi
            ;;
        untracked-present)
            baseline_path="$snapshot_dir/untracked/$file"
            baseline_type="$(path_type "$baseline_path")" \
                || fail "unsupported private baseline type: $file"
            [ "$baseline_type" != absent ] \
                || fail "missing private baseline: $file"
            current_type="$(path_type "$current_path")" \
                || fail "only regular files and symlinks are supported: $file"
            if [ "$current_type" = absent ]; then
                current_path=/dev/null
            fi
            run_no_index_diff "$file" "$baseline_path" "$current_path" \
                || fail "git diff failed for untracked path: $file"
            ;;
        absent)
            current_type="$(path_type "$current_path")" \
                || fail "only regular files and symlinks are supported: $file"
            if [ "$current_type" != absent ]; then
                run_no_index_diff "$file" /dev/null "$current_path" \
                    || fail "git diff failed for newly present path: $file"
            fi
            ;;
        *)
            fail "invalid manifest state for: $file"
            ;;
    esac
done

cat "$output_file"
