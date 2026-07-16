#!/usr/bin/env bash
# Ownership Reconciliation (Post-Dispatch) — mechanical hunk-set subtractor.
#
# This is ADVISORY tooling the main session invokes after a dispatched writer
# subagent returns. It partitions the working-tree hunks since BASE into two
# sets by pure set arithmetic against the subagent's self-reported diff:
#   - owned   : worktree hunks whose identity tuple also appears in the
#               reported diff (the subagent authored them)
#   - foreign : worktree hunks absent from the reported diff (a parallel
#               session likely authored them)
# It performs NO ownership judgment. The owned-vs-foreign call belongs to the
# session, which alone has the context of what it and its subagents authored
# (see AGENTS.md "Ownership And Concurrent-Write Guard"). This tool only does
# set subtraction and never blocks: it exits 0 for every reconciliation
# outcome (clean or foreign-detected). Exit 2 covers usage errors and the case
# where the worktree diff against BASE cannot be obtained (git diff failed).
#
# A hunk identity = (path, new_start_line, new_line_count) parsed from the
# unified-diff headers (`diff --git a/<p> b/<p>` sets the path; the new-side
# `@@ ... +<new>[,<newn>] @@` header sets new_start and new_count, default 1).
#
# Usage: ownership-reconcile.sh <BASE> --reported-diff <file> --files <path...>
#   BASE            git ref/commit captured before dispatching the writer
#                   (e.g. $(git stash create || git rev-parse HEAD)).
#   --reported-diff path to the subagent's self-reported `git diff $BASE`
#                   (ground truth of which hunks it authored).
#   --files         one or more repo-relative paths scoping the diff.
#
# Example:
#   ownership-reconcile.sh <BASE> --reported-diff <subagent.diff> --files src/foo.sol
#
# Output: one compact JSON object on stdout:
#   {"base":"<sha>","files":[...],"owned_hunks":[...],"foreign_hunks":[...],
#    "verdict":"clean"|"foreign-detected"}
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: ownership-reconcile.sh <BASE> --reported-diff <file> --files <path...>

Mechanical hunk-set subtractor. Partitions working-tree hunks since BASE into
owned (present in the subagent's reported diff) vs foreign (absent). Advisory
tooling invoked post-dispatch; it does set arithmetic only and never blocks
(exit 0 on all reconciliation outcomes). Ownership judgment stays with the
session per AGENTS.md "Ownership And Concurrent-Write Guard".

Example:
  ownership-reconcile.sh <BASE> --reported-diff <subagent.diff> --files src/foo.sol
EOF
}

# Parse a unified diff from stdin into hunk-identity tuples, one per line:
#   path<TAB>new_start<TAB>new_count
# `diff --git a/<p> b/<p>` sets the current path (the new-side b/ path).
# `@@ -<old>,<oldn> +<new>[,<newn>] @@` emits a tuple using new_start=<new>
# and new_count=<newn> (default 1 when the count is absent). Binary diffs have
# no `@@` headers, so they naturally emit nothing. Repo paths contain no
# spaces, so non-space path matching is sufficient.
parse_hunks() {
    local path=""
    local line
    # Patterns stored in variables (unquoted on the =~ RHS) so spaces and
    # metacharacters are not mangled by shell quoting. diff_re captures the
    # new-side (b/) path; hunk_re captures the new hunk start and count,
    # defaulting the count to 1 when the `,<newn>` part is absent.
    local diff_re='^diff --git a/([^ ]+) b/([^ ]+)$'
    local hunk_re='^@@ -[0-9]+(,[0-9]+)? \+([0-9]+)(,([0-9]+))? @@'
    while IFS= read -r line; do
        if [[ "$line" =~ $diff_re ]]; then
            path="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $hunk_re ]]; then
            local new_start="${BASH_REMATCH[2]}"
            local new_count="${BASH_REMATCH[4]:-1}"
            if [ -n "$path" ]; then
                printf '%s\t%s\t%s\n' "$path" "$new_start" "$new_count"
            fi
        fi
    done
}

# --- argument parsing -------------------------------------------------------

BASE=""
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
            echo "unknown option: $1" >&2
            usage
            exit 2
            ;;
        *)
            if [ -z "$BASE" ]; then
                BASE="$1"
            else
                echo "unexpected positional argument: $1" >&2
                usage
                exit 2
            fi
            shift
            ;;
    esac
done

# --- validation (exit 2 for usage errors only) ------------------------------

if [ -z "$BASE" ]; then
    usage
    exit 2
fi
if [ -z "$reported_diff" ]; then
    usage
    exit 2
fi
if [ "${#files[@]}" -eq 0 ]; then
    usage
    exit 2
fi
if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "bad BASE (not a valid git ref): $BASE" >&2
    usage
    exit 2
fi
if [ ! -s "$reported_diff" ]; then
    echo "reported-diff missing or empty: $reported_diff" >&2
    usage
    exit 2
fi

# --- reconcile --------------------------------------------------------------

# Worktree hunks since BASE, scoped to the requested files. Capture git diff to
# a temp file so its exit status is checked explicitly. Process substitution
# (< <(...)) does not propagate the inner pipeline's status, so a failed
# `git diff` (e.g. corrupt object store) would be silently swallowed and emit a
# false "clean" verdict — the tool's worst failure mode. Fail loud instead.
# Parsing still reads the temp file via process substitution (not command
# substitution), so trailing newlines are preserved and the final hunk header is
# never dropped.
worktree_diff_file="$(mktemp)"
if ! git diff "$BASE" -- "${files[@]}" >"$worktree_diff_file"; then
    rm -f "$worktree_diff_file"
    echo "git diff against BASE ($BASE) failed; cannot reconcile" >&2
    exit 2
fi
mapfile -t worktree_tuples < <(parse_hunks < "$worktree_diff_file")
rm -f "$worktree_diff_file"
mapfile -t reported_tuples < <(parse_hunks < "$reported_diff")

# Reported-diff identity set: key = path<TAB>new_start<TAB>new_count.
declare -A reported_set=()
for t in "${reported_tuples[@]}"; do
    [ -n "$t" ] && reported_set["$t"]=1
done

# Classify each worktree hunk: present in the reported set -> owned, else foreign.
owned_json='[]'
foreign_json='[]'
for t in "${worktree_tuples[@]}"; do
    [ -n "$t" ] || continue
    IFS=$'\t' read -r hpath hstart hcount <<<"$t"
    hunk_obj="$(jq -nc --arg p "$hpath" --argjson s "$hstart" --argjson c "$hcount" \
        '{path:$p,start:$s,lines:$c}')"
    if [ -n "${reported_set[$t]+set}" ]; then
        owned_json="$(jq -nc --argjson a "$owned_json" --argjson h "$hunk_obj" '$a + [$h]')"
    else
        foreign_json="$(jq -nc --argjson a "$foreign_json" --argjson h "$hunk_obj" '$a + [$h]')"
    fi
done

base_sha="$(git rev-parse "$BASE")"
if [ "$(jq 'length' <<<"$foreign_json")" -eq 0 ]; then
    verdict="clean"
else
    verdict="foreign-detected"
fi

files_json="$(jq -nc --args '$ARGS.positional' -- "${files[@]}")"

jq -nc \
    --arg base "$base_sha" \
    --argjson files "$files_json" \
    --argjson owned "$owned_json" \
    --argjson foreign "$foreign_json" \
    --arg verdict "$verdict" \
    '{base:$base, files:$files, owned_hunks:$owned, foreign_hunks:$foreign, verdict:$verdict}'

exit 0
