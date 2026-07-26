#!/usr/bin/env bash
# Ownership reconciliation compares a writer's complete snapshot-to-current
# diff with a fresh rendering. It reports evidence; the session owns judgment.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: ownership-reconcile.sh <snapshot-dir> --reported-diff <file> --files <path...>

Render the current complete ownership diff from <snapshot-dir> and compare it
byte-for-byte with the writer's reported diff. An empty reported diff is valid.
EOF
}

fail() {
    echo "ownership-reconcile: $*" >&2
    exit 2
}

snapshot_dir=""
reported_diff=""
files=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reported-diff)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            reported_diff="$2"
            shift 2
            ;;
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
[ -n "$reported_diff" ] || { usage; exit 2; }
[ "${#files[@]}" -gt 0 ] || { usage; exit 2; }
[ -d "$snapshot_dir" ] || fail "snapshot directory does not exist: $snapshot_dir"
[ -f "$reported_diff" ] || fail "reported diff does not exist: $reported_diff"
snapshot_dir="$(cd -- "$snapshot_dir" && pwd -P)" \
    || fail "cannot resolve snapshot directory: $snapshot_dir"

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
render_script="$script_dir/render-ownership-diff.sh"
[ -f "$render_script" ] || fail "render helper does not exist: $render_script"

actual_diff="$(mktemp)"
trap 'rm -f "$actual_diff"' EXIT
if ! bash "$render_script" "$snapshot_dir" --files "${files[@]}" >"$actual_diff"; then
    fail "could not render the current ownership diff"
fi

[ -f "$snapshot_dir/tracked-base" ] || fail "missing tracked-base in snapshot"
tracked_base="$(<"$snapshot_dir/tracked-base")"
[ -n "$tracked_base" ] || fail "empty tracked-base in snapshot"
if ! tracked_base="$(git rev-parse --verify --quiet "$tracked_base^{commit}")"; then
    fail "invalid tracked-base in snapshot"
fi
if ! files_json="$(jq -ce '[.files[].path]' "$snapshot_dir/manifest.json")"; then
    fail "cannot read files from snapshot manifest"
fi
if ! reported_sha256="$(sha256sum -- "$reported_diff" | awk '{print $1}')"; then
    fail "cannot hash reported diff"
fi
if ! actual_sha256="$(sha256sum -- "$actual_diff" | awk '{print $1}')"; then
    fail "cannot hash actual diff"
fi

if cmp -s -- "$reported_diff" "$actual_diff"; then
    verdict=clean
else
    status=$?
    [ "$status" -eq 1 ] || fail "cannot compare reported and actual diffs"
    verdict=foreign-detected
fi

jq -nc \
    --arg tracked_base "$tracked_base" \
    --argjson files "$files_json" \
    --arg reported_sha256 "$reported_sha256" \
    --arg actual_sha256 "$actual_sha256" \
    --arg verdict "$verdict" \
    '{tracked_base:$tracked_base,files:$files,reported_sha256:$reported_sha256,actual_sha256:$actual_sha256,verdict:$verdict}'
