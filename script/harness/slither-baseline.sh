#!/usr/bin/env bash
set -euo pipefail

# Slither findings baseline manager and the single source of truth for the slither
# finding-key normalization and invocation contract:
#   check — serialized forge build, slither run twice, keep only findings present in
#           both runs (single-run-only findings are forge incremental-build drift
#           noise), and fail on any finding key absent from
#           script/harness/slither-baseline.json (NEW findings only).
#   regen — regenerate script/harness/slither-baseline.json deterministically from
#           the intersection of the two runs' normalized findings.
#
# Finding key: <check>|<location path before "#">|<first description line stripped of
# trailing source-position suffixes such as " (src/X.sol#L1-L2)"; content-addressed so
# line drift does not mass-invalidate the baseline.
#
# check prints exactly one JSON object on stdout in every outcome; human-readable
# progress and diagnostics go to stderr:
#   {"status":"pass"|"new"|"no-findings"|"baseline-missing"|"baseline-invalid"|
#    "build-failed"|"slither-failed"|"invalid-json",
#    "error":"...",                          # failure states only (incl. no-findings)
#    "run":N,                                # failed slither run, slither-failed/invalid-json only
#    "drift":bool,"run1_key_count":N,"run2_key_count":N,
#    "run1_count":N,"run2_count":N,          # raw detector counts, pass/new/no-findings states
#    "stable_count":N,"baseline_count":N,    # pass/new/no-findings states
#    "new_count":N,"new":[...]}              # new state
#   no-findings: both runs produced zero findings while the baseline is non-empty
#   (exit 1) — a suspicious shrink that names the regen acceptance path in .error.
#
# Exit codes (check): 0 = pass; 1 = new findings beyond baseline OR the no-findings
# shrink guard; 2 = fail closed (baseline missing/invalid, serialized build failed,
# slither command failed, or detector JSON invalid). Exit 2 with no stdout object
# means a preflight guard (policy read or tool lookup) failed.
#
# --fail-none only suppresses slither's default "exit non-zero when findings
# exist" behavior (slither 0.11.6 --no-fail-pedantic): a successful analysis
# exits 0 with valid success JSON whether or not findings exist, and a
# zero-finding run reaches the no-findings guard through that normal path.
# run_slither still accepts exit 1 + valid detector JSON as a successful
# zero-finding run as defense-in-depth for slither versions where --fail-none
# reports zero findings as exit 1; without valid JSON, any non-zero exit stays
# a command failure. regen may therefore write an empty baseline: that is an
# explicit acceptance recorded via the baseline diff.
#
# Usage: bash script/harness/slither-baseline.sh {check|regen}

usage() {
    cat >&2 <<'EOF'
Usage: bash script/harness/slither-baseline.sh {check|regen}
  check — exit 0 with a status JSON object when every stable slither finding is
          within the baseline; exit 1 with the NEW findings listed in the object;
          exit 2 (fail closed) when the baseline is missing/invalid, the serialized
          forge build fails, slither fails, or detector JSON is invalid.
  regen — regenerate script/harness/slither-baseline.json from current findings.
EOF
}

die() {
    local exit_code="${2:-1}"
    echo "slither-baseline: ERROR: $1" >&2
    exit "$exit_code"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
policy_file="$repo_root/.harness/policy.json"
baseline_file="$script_dir/slither-baseline.json"

[ -f "$policy_file" ] || die "policy file is missing: $policy_file" 2

slither_exclude_detectors="$(jq -r '.risk_rules.slither_exclude_detectors // ""' "$policy_file")"
slither_filter_paths="$(jq -r '.risk_rules.slither_filter_paths // ""' "$policy_file")"
[ -n "$slither_exclude_detectors" ] || die "risk_rules.slither_exclude_detectors is empty in $policy_file" 2
[ -n "$slither_filter_paths" ] || die "risk_rules.slither_filter_paths is empty in $policy_file" 2

command -v slither >/dev/null 2>&1 || die "slither not found in PATH" 2
command -v jq >/dev/null 2>&1 || die "jq not found in PATH" 2

case "${1:-}" in
    check|regen) mode="$1" ;;
    *) usage; die "unsupported mode: ${1:-<none>}" 2 ;;
esac

mkdir -p "$repo_root/.harness/tmp"
tmp_dir="$(mktemp -d "$repo_root/.harness/tmp/slither-baseline.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT
# SIGTERM/SIGINT bypass EXIT-only traps: run the same cleanup explicitly so a
# killed run does not leak its scratch output files.
trap 'cleanup; trap - EXIT; exit 143' INT TERM

run1_file="$tmp_dir/run1.json"
run2_file="$tmp_dir/run2.json"

# The slither invocation contract, defined exactly once for both modes. The die
# codes are internal failure classifications consumed by check mode: 2 = the
# command itself failed (checked first), 3 = exit code 0 but the output was not
# usable detector JSON.
run_slither() {
    local output_file="$1"
    set +e
    slither src \
        --filter-paths "$slither_filter_paths" \
        --exclude-dependencies \
        --exclude "$slither_exclude_detectors" \
        --json - \
        --json-types detectors \
        --fail-none \
        --disable-color > "$output_file" 2>&1
    local exit_code=$?
    set -e
    if [ "$exit_code" -ne 0 ]; then
        # Defense-in-depth for slither versions where --fail-none reports zero
        # findings as exit 1 with valid detector JSON; any other non-zero exit
        # (including exit 1 with unusable output) is a command failure.
        if [ "$exit_code" -eq 1 ] \
            && jq -e '.success == true and (.results.detectors | type == "array")' "$output_file" >/dev/null 2>&1; then
            return 0
        fi
        die "slither failed with exit code $exit_code (see $output_file)" 2
    fi
    jq -e '.success == true and (.results.detectors | type == "array")' "$output_file" >/dev/null 2>&1 \
        || die "slither did not emit valid detector JSON (see $output_file)" 3
}

# The finding-key normalization, defined exactly once for both modes; both regexes
# strip slither's trailing source-position suffix so key equality is content-based.
normalization_defs='
    def norm_summary:
        (.description // "")
        | split("\n")[0]
        | sub(" \\([^)]*#L?[0-9]+(-L?[0-9]+)?\\)"; "")
        | sub(" \\([^)]*#[0-9]+(-[0-9]+)?\\)"; "");
    def normalize:
        {
            id: (.id // ""),
            check: (.check // ""),
            impact: (.impact // ""),
            confidence: (.confidence // ""),
            location: (.first_markdown_element // ""),
            summary: norm_summary,
            key: (
                (.check // "") + "|" +
                ((.first_markdown_element // "") | split("#")[0]) + "|" +
                norm_summary
            )
        };
'

# check-mode stdout protocol: exactly one JSON object; each failure path reports a
# distinct status so callers can map evidence shapes without parsing stderr. The
# optional run number identifies which of the two slither runs failed.
emit_status() {
    local status="$1"
    local error="$2"
    local run="${3:-}"
    if [ -n "$run" ]; then
        jq -n --arg status "$status" --arg error "$error" --argjson run "$run" \
            '{status: $status, error: $error, run: $run}'
    else
        jq -n --arg status "$status" --arg error "$error" '{status: $status, error: $error}'
    fi
}

# Map a failed check-mode run to a distinct fail-closed status, using the internal
# die code captured through the subshell caller: 2 = the slither command itself
# failed (run_slither checks the exit code first, so a non-zero exit with
# unparseable output still classifies here), 3 = exit code 0 but no usable detector
# JSON. The offending output is echoed to stderr so callers filtering stderr keep
# the diagnostic evidence.
report_run_failure() {
    local run_number="$1"
    local run_file="$2"
    local rc="$3"
    case "$rc" in
        2)
            cat "$run_file" >&2
            emit_status "slither-failed" "slither run $run_number failed (see stderr)" "$run_number"
            ;;
        *)
            head -n 40 "$run_file" >&2
            emit_status "invalid-json" "slither run $run_number did not emit valid detector JSON (see stderr)" "$run_number"
            ;;
    esac
    exit 2
}

if [ "$mode" = "check" ]; then
    comparison_file="$tmp_dir/comparison.json"
    build_log="$tmp_dir/build.log"
    rc=0

    if [ ! -f "$baseline_file" ]; then
        emit_status "baseline-missing" "slither baseline file is missing: $baseline_file"
        exit 2
    fi

    if ! jq -e '.version == 1 and (.findings | type == "array")' "$baseline_file" >/dev/null 2>&1; then
        emit_status "baseline-invalid" "slither baseline file is invalid: $baseline_file"
        exit 2
    fi

    echo "slither-baseline: serialized forge build" >&2
    if ! bash "$script_dir/forge-serialize.sh" build > "$build_log" 2>&1; then
        # Keep the build failure evidence on stderr; the tmp log is removed at exit.
        cat "$build_log" >&2
        emit_status "build-failed" "serialized forge build failed (see stderr)"
        exit 2
    fi

    echo "slither-baseline: slither run 1 of 2" >&2
    ( run_slither "$run1_file" ) || rc=$?
    [ "$rc" -eq 0 ] || report_run_failure 1 "$run1_file" "$rc"
    echo "slither-baseline: slither run 2 of 2" >&2
    ( run_slither "$run2_file" ) || rc=$?
    [ "$rc" -eq 0 ] || report_run_failure 2 "$run2_file" "$rc"

    run1_count="$(jq '.results.detectors | length' "$run1_file")"
    run2_count="$(jq '.results.detectors | length' "$run2_file")"

    if ! jq --slurpfile baseline "$baseline_file" --slurpfile run2 "$run2_file" "$normalization_defs"'
        ($baseline[0].findings | map(.key // .id) | unique) as $baseline_keys
        | ([.results.detectors[] | normalize]) as $run1_normalized
        | ($run1_normalized | map(.key) | unique) as $run1_keys
        | ($run2[0].results.detectors | map(normalize.key) | unique) as $run2_keys
        | ([$run1_normalized[] | select(.key as $key | $run2_keys | index($key))]) as $stable
        | {
            drift: (($run1_keys | length) != ($run2_keys | length) or ($run1_keys - $run2_keys | length) > 0 or ($run2_keys - $run1_keys | length) > 0),
            run1_key_count: ($run1_keys | length),
            run2_key_count: ($run2_keys | length),
            stable_count: ($stable | length),
            new: [
                $stable[]
                | select((.key // .id) as $key | $key == "" or ($baseline_keys | index($key) | not))
            ]
        }
    ' "$run1_file" > "$comparison_file"; then
        emit_status "invalid-json" "failed to compute the baseline comparison (run1: $run1_file, baseline: $baseline_file)"
        exit 2
    fi

    jq -e . "$comparison_file" >/dev/null 2>&1 \
        || { emit_status "invalid-json" "baseline comparison result failed JSON self-check"; exit 2; }

    baseline_count="$(jq '.findings | length' "$baseline_file")"
    new_count="$(jq '.new | length' "$comparison_file")"
    run1_key_count="$(jq '.run1_key_count' "$comparison_file")"
    run2_key_count="$(jq '.run2_key_count' "$comparison_file")"

    # Zero findings on both runs with a non-empty baseline is a suspicious shrink,
    # not a pass: the no-findings guard fires only inside new_count == 0 (new
    # findings keep the highest priority), and requiring BOTH key counts to be
    # zero immunizes the guard against extreme mutually-exclusive drift, which
    # would otherwise masquerade as a legitimate empty result. An empty baseline
    # plus zero findings stays a normal pass.
    if [ "$new_count" -eq 0 ]; then
        if [ "$run1_key_count" -eq 0 ] && [ "$run2_key_count" -eq 0 ] && [ "$baseline_count" -gt 0 ]; then
            status="no-findings"
            exit_code=1
        else
            status="pass"
            exit_code=0
        fi
    else
        status="new"
        exit_code=1
    fi

    error_message=""
    if [ "$status" = "no-findings" ]; then
        error_message="slither produced no findings while the baseline records $baseline_count entries — run script/harness/regen-slither-baseline.sh to accept an empty baseline, or investigate the analysis scope"
    fi

    # The error key exists only in failure states; object addition keeps the
    # key absent (not null) for pass/new while preserving field order. A bare
    # `error: ($error_message | select(...))` would suppress the entire object
    # when the value expression is empty.
    jq --arg status "$status" \
        --arg error_message "$error_message" \
        --argjson baseline_count "$baseline_count" \
        --argjson new_count "$new_count" \
        --argjson run1_count "$run1_count" \
        --argjson run2_count "$run2_count" \
        '{
            status: $status
        } + (if $error_message == "" then {} else {error: $error_message} end) + {
            drift,
            run1_key_count,
            run2_key_count,
            run1_count: $run1_count,
            run2_count: $run2_count,
            stable_count,
            baseline_count: $baseline_count,
            new_count: $new_count,
            new
        }' "$comparison_file"
    exit "$exit_code"
fi

# regen mode
echo "slither-baseline: serialized forge build"
bash "$script_dir/forge-serialize.sh" build > "$tmp_dir/build.log" 2>&1 || die "serialized forge build failed (see $tmp_dir/build.log)"

echo "slither-baseline: slither run 1 of 2"
run_slither "$run1_file"
echo "slither-baseline: slither run 2 of 2"
run_slither "$run2_file"

run1_normalized="$(jq "$normalization_defs"'
    [.results.detectors[] | normalize]
' "$run1_file")"
# run2 keeps only keys, so the full normalize projection and the earlier
# summary+key-only projection yield the same key set.
run2_keys="$(jq "$normalization_defs"'
    [.results.detectors[] | normalize.key] | unique
' "$run2_file")"

# The baseline is consumed as a KEY SET, so deduplicate by key (keep the first
# occurrence per key): a single run may contain multiple detector entries that
# normalize to the same key (e.g. several timestamp findings in one function).
stable_file="$tmp_dir/stable.json"
printf '%s' "$run1_normalized" | jq --argjson run2_keys "$run2_keys" '
    [.[] | select(.key as $key | $run2_keys | index($key))]
    | group_by(.key) | map(.[0])
    | sort_by(.key)
' > "$stable_file"

run1_count="$(jq '.results.detectors | length' "$run1_file")"
run2_count="$(jq '.results.detectors | length' "$run2_file")"
run1_key_count="$(printf '%s' "$run1_normalized" | jq 'map(.key) | unique | length')"
run2_key_count="$(printf '%s' "$run2_keys" | jq 'length')"
intersection_key_count="$(jq 'map(.key) | unique | length' "$stable_file")"
drift_count=$(( run1_key_count + run2_key_count - 2 * intersection_key_count ))

generated_at="$(date -u +%Y-%m-%d)"
candidate_file="$tmp_dir/baseline.json"
jq -n \
    --arg generated_at "$generated_at" \
    --slurpfile findings "$stable_file" \
    '{version: 1, tool: "slither", generated_at: $generated_at, target: "src", findings: $findings[0]}' \
    > "$candidate_file"

# Validations before writing.
python3 -m json.tool "$candidate_file" >/dev/null 2>&1 || jq -e . "$candidate_file" >/dev/null 2>&1 || die "produced baseline failed JSON round-trip"

written_count="$(jq '.findings | length' "$candidate_file")"
written_key_count="$(jq '[.findings[].key] | unique | length' "$candidate_file")"
run1_keys="$(printf '%s' "$run1_normalized" | jq -c 'map(.key) | unique')"
run2_keys_j="$(printf '%s' "$run2_keys" | jq -c '.')"
[ "$written_count" -eq "$intersection_key_count" ] || die "self-check failed: written count ($written_count) != intersection key count ($intersection_key_count)"
[ "$written_key_count" -eq "$intersection_key_count" ] || die "self-check failed: written unique key count ($written_key_count) != intersection key count ($intersection_key_count)"
missing_from_runs="$(jq --argjson findings "$(jq -c '[.findings[].key]' "$candidate_file")" --argjson r1 "$run1_keys" --argjson r2 "$run2_keys_j" -n '$ARGS.named.findings - ($ARGS.named.r1 + $ARGS.named.r2 | unique) | length')"
[ "$missing_from_runs" -eq 0 ] || die "self-check failed: $missing_from_runs written keys not present in both runs' key sets"

printf '\n' >> "$candidate_file"
mv "$candidate_file" "$baseline_file"

echo "slither-baseline: run1=$run1_count detectors ($run1_key_count unique keys), run2=$run2_count detectors ($run2_key_count unique keys)"
echo "slither-baseline: intersection (written)=$written_count findings, drift=$drift_count (symmetric difference of key sets)"
echo "slither-baseline: wrote $written_count findings to $baseline_file"
if [ "$written_count" -eq 0 ]; then
    echo "slither-baseline: accepted an empty findings set (0 findings written) — the baseline diff is the acceptance record"
fi
