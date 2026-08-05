#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_classify() {
    local name="$1"
    local changed_files="$2"
    local diff_file="${3-}"
    local expected_status="${4-0}"
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    set +e
    if [ -n "$diff_file" ]; then
        RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
            bash script/harness/gate.sh --classify-only --changed-files "${changed_file_args[@]}" >"$stdout"
        status=$?
    else
        RUN_RECORD_PATH="$record" \
            bash script/harness/gate.sh --classify-only --changed-files "${changed_file_args[@]}" >"$stdout"
        status=$?
    fi
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_with_changed_args() {
    local name="$1"
    shift
    local expected_status="${1-0}"
    shift
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local status

    set +e
    RUN_RECORD_PATH="$record" \
        bash script/harness/gate.sh --classify-only "$@" >"$stdout"
    status=$?
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_from_subdir() {
    local name="$1"
    local subdir="$2"
    local expected_status="${3-0}"
    shift 3
    local record="$tmp_dir/$name.record.json"
    local stdout="$tmp_dir/$name.stdout"
    local stderr="$tmp_dir/$name.stderr"
    local status

    set +e
    (
        cd "$subdir"
        RUN_RECORD_PATH="$record" \
            bash ../script/harness/gate.sh --classify-only --changed-files "$@" >"$stdout" 2>"$stderr"
    )
    status=$?
    set -e

    if [ "$status" -ne "$expected_status" ]; then
        echo "expected classify status $expected_status for $name, got $status" >&2
        return 1
    fi

    jq -e . "$record" >/dev/null
    jq -e . "$stdout" >/dev/null
    printf '%s\n' "$record"
}

run_classify_capture() {
    local name="$1"
    shift
    local stdout="$tmp_dir/$name.stdout"
    local stderr="$tmp_dir/$name.stderr"
    local status

    set +e
    bash script/harness/gate.sh --classify-only --changed-files "$@" >"$stdout" 2>"$stderr"
    status=$?
    set -e

    printf '%s\n%s\n%s\n' "$status" "$stdout" "$stderr"
}

materialize_test_mapping_tests() {
    local policy_file="$1"
    local repo="$2"
    local test_path

    while IFS= read -r test_path; do
        mkdir -p "$repo/$(dirname "$test_path")"
        : >"$repo/$test_path"
    done < <(jq -r '
        [
          .test_mapping[]?.tests[]?,
          .test_mapping[]?.rules[]?.change_tests[]?,
          .test_mapping[]?.rules[]?.evidence_tests[]?
        ] | unique[]
    ' "$policy_file")
}

run_default_classify_in_scratch_repo() {
    local name="$1"
    local dirty_file="$2"
    local repo="$tmp_dir/$name.repo"
    local record="$tmp_dir/$name.record.json"

    mkdir -p "$repo/script/harness" "$repo/.harness"
    cp script/harness/gate.sh "$repo/script/harness/gate.sh"
    cp -R .harness/policy.json .harness/schemas "$repo/.harness/"
    materialize_test_mapping_tests "$repo/.harness/policy.json" "$repo"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.invalid
        git config user.name "Harness Test"
        git add .
        git commit -q -m baseline
        mkdir -p "$(dirname "$dirty_file")"
        printf 'dirty\n' >"$dirty_file"
        RUN_RECORD_PATH="$record" bash script/harness/gate.sh --classify-only >/dev/null
    )

    jq -e . "$record" >/dev/null
    printf '%s\n' "$record"
}

# Shared setup for test_mapping rejection tests: copy gate + policy + test files
# into a fresh scratch repo, inject one bad reference, run classify, return stderr.
# Args: <case-name> <policy-mutation-jq-filter> <injected-test-path>
# Side effects: writes $tmp_dir/<case-name>.stderr; echoes the case-name on success.
run_test_mapping_rejection_case() {
    local case_name="$1"
    local mutation_filter="$2"
    local injected_test="$3"
    local repo="$tmp_dir/$case_name.repo"
    local stderr="$tmp_dir/$case_name.stderr"
    local policy="$repo/.harness/policy.json"
    local status

    mkdir -p "$repo/script/harness" "$repo/.harness"
    cp script/harness/gate.sh "$repo/script/harness/gate.sh"
    cp -R .harness/policy.json .harness/schemas "$repo/.harness/"
    materialize_test_mapping_tests "$policy" "$repo"
    jq --arg test "$injected_test" "$mutation_filter" "$policy" >"$policy.tmp"
    mv "$policy.tmp" "$policy"

    (
        cd "$repo"
        git init -q
        git config user.email test@example.invalid
        git config user.name "Harness Test"
        git add .
        git commit -q -m baseline
        printf 'dirty\n' >README.md
    )

    set +e
    (
        cd "$repo"
        bash script/harness/gate.sh --classify-only
    ) >/dev/null 2>"$stderr"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        echo "$case_name: invalid test_mapping reference was accepted" >&2
        return 1
    }
    grep -Fq "\"path\":\"$injected_test\"" "$stderr" || {
        echo "$case_name: injected test path missing from gate error output" >&2
        return 1
    }
    printf '%s\n' "$case_name"
}

# Table-driven coverage of validate_test_mapping_references (gate.sh).
# The validator checks three reference sources (mapping.tests, rules[].change_tests,
# rules[].evidence_tests) and two rejection branches (format, existence). Each row
# pins one (source x branch) cell so deleting the matching validator branch turns
# this test red.
#
# Row 4 is a STRONG sentinel: its path contains "/../" but still resolves (via
# bash [ -f ]) to an existing repo file. If the format branch is removed, the
# existence check passes and gate silently accepts the non-canonical path -- a
# real acceptance escape, not just a changed reason string. A weak sentinel
# (e.g. a glob "test/swap/*.t.sol") would only drop from format to "missing" and
# still be rejected, so it cannot detect format-branch removal.
assert_invalid_test_mapping_references_are_rejected() {
    local missing_test="test/swap/MissingMappingTest.t.sol"
    local rule_pointer='/test_mapping/memeverse/rules/'
    local tests_pointer='/test_mapping/memeverse/tests/'
    local fmt_reason='must be a concrete repository test path ending in .t.sol'
    local missing_reason='file does not exist'
    local case_stderr
    local pointer

    # Row 1: source = change_tests, branch = existence.
    pointer="$rule_pointer$(jq -r '
        .test_mapping.memeverse.rules | to_entries[]
        | select(.value.id == "swap-dynamic-fee-facet") | .key
    ' .harness/policy.json)/change_tests/0"
    case_stderr="$tmp_dir/change-tests-missing.stderr"
    run_test_mapping_rejection_case change-tests-missing \
        '(.test_mapping.memeverse.rules[]
          | select(.id == "swap-dynamic-fee-facet")
          | .change_tests[0]) = $test' \
        "$missing_test" >/dev/null
    grep -Fq "\"pointer\":\"$pointer\"" "$case_stderr"
    grep -Fq "\"reason\":\"$missing_reason\"" "$case_stderr"

    # Row 2: source = evidence_tests, branch = existence.
    pointer="$rule_pointer$(jq -r '
        .test_mapping.memeverse.rules | to_entries[]
        | select(.value.id == "swap-dynamic-fee-facet") | .key
    ' .harness/policy.json)/evidence_tests/0"
    case_stderr="$tmp_dir/evidence-tests-missing.stderr"
    run_test_mapping_rejection_case evidence-tests-missing \
        '(.test_mapping.memeverse.rules[]
          | select(.id == "swap-dynamic-fee-facet")
          | .evidence_tests[0]) = $test' \
        "$missing_test" >/dev/null
    grep -Fq "\"pointer\":\"$pointer\"" "$case_stderr"
    grep -Fq "\"reason\":\"$missing_reason\"" "$case_stderr"

    # Row 3: source = mapping.tests, branch = existence.
    # Production policy has no top-level tests array, so this also exercises the
    # validator's $mapping.tests traversal branch that real data never reaches.
    pointer="${tests_pointer}0"
    case_stderr="$tmp_dir/tests-missing.stderr"
    run_test_mapping_rejection_case tests-missing \
        '.test_mapping.memeverse.tests = [$test]' \
        "$missing_test" >/dev/null
    grep -Fq "\"pointer\":\"$pointer\"" "$case_stderr"
    grep -Fq "\"reason\":\"$missing_reason\"" "$case_stderr"

    # Row 4: source = change_tests, branch = format (strong sentinel).
    pointer="$rule_pointer$(jq -r '
        .test_mapping.memeverse.rules | to_entries[]
        | select(.value.id == "swap-dynamic-fee-facet") | .key
    ' .harness/policy.json)/change_tests/0"
    case_stderr="$tmp_dir/change-tests-format.stderr"
    run_test_mapping_rejection_case change-tests-format \
        '(.test_mapping.memeverse.rules[]
          | select(.id == "swap-dynamic-fee-facet")
          | .change_tests[0]) = $test' \
        'test/swap/../swap/FeeMath.t.sol' >/dev/null
    grep -Fq "\"pointer\":\"$pointer\"" "$case_stderr"
    grep -Fq "\"reason\":\"$fmt_reason\"" "$case_stderr"
}

assert_delegated_review_rules_are_rejected_and_removed() {
    local repo="$tmp_dir/delegated-review-rules.repo"
    local stderr="$tmp_dir/delegated-review-rules.stderr"
    local policy="$repo/.harness/policy.json"
    local status

    mkdir -p "$repo/script/harness" "$repo/.harness"
    cp script/harness/gate.sh "$repo/script/harness/gate.sh"
    cp -R .harness/policy.json .harness/schemas "$repo/.harness/"
    materialize_test_mapping_tests "$policy" "$repo"
    jq '.delegated_review_rules = []' \
        "$policy" >"$policy.tmp" && mv "$policy.tmp" "$policy"

    (
        cd "$repo"
        git init -q
        git config user.email test@example.invalid
        git config user.name "Harness Test"
        git add .
        git commit -q -m baseline
        printf 'dirty\n' >README.md
    )

    set +e
    (
        cd "$repo"
        bash script/harness/gate.sh --classify-only
    ) >/dev/null 2>"$stderr"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        echo "delegated_review_rules top-level field was accepted" >&2
        return 1
    }
    grep -Fqx '[gate] ERROR: policy schema validation failed' "$stderr"

    for production_file in \
        .harness/policy.json \
        .harness/schemas/policy.schema.json \
        script/harness/gate.sh; do
        if grep -Fq 'delegated_review_rules' "$production_file"; then
            echo "delegated_review_rules remains in $production_file" >&2
            return 1
        fi
    done
    if grep -Fq 'delegatedReviewRule' .harness/schemas/policy.schema.json; then
        echo 'delegatedReviewRule remains in policy schema' >&2
        return 1
    fi
}

# CI-002 regression: shared fee/facet source files consumed by multiple facets
# must be registered in each consuming rule's paths, so a standalone change to
# any shared file selects the consumer suites (settlement reentrancy / dynamic
# fee revert propagation) in the fast gate, not just swap-facet. gate.sh matches
# rules by path then unions the rule's tests; it does not expand Solidity
# imports or inheritance, so a shared file only in swap-facet.paths silently
# drops the consumer suites from targeted_tests.
assert_shared_facet_paths_map_to_consumers() {
    # SettlementFacet inherits MemeverseSwapFeeBase (which is FacetGuard) and
    # imports SwapFeeMath / SwapGuardMath; its external fns are gated by the
    # FacetGuard onlyViaRouter modifier. All four shared files must map here so
    # a standalone change to any selects the settlement reentrancy / same-pool /
    # sequential suites.
    local settlement_paths
    settlement_paths="$(jq -r '.test_mapping.memeverse.rules[]
        | select(.id == "swap-settlement-facet") | .paths[]' .harness/policy.json)"
    grep -Fqx "src/swap/MemeverseSwapFeeBase.sol" <<<"$settlement_paths"
    grep -Fqx "src/swap/libraries/SwapFeeMath.sol" <<<"$settlement_paths"
    grep -Fqx "src/swap/libraries/SwapGuardMath.sol" <<<"$settlement_paths"
    grep -Fqx "src/swap/FacetGuard.sol" <<<"$settlement_paths"

    # DynamicFeeFacet inherits FacetGuard (its dispatch guard); the
    # facet-to-facet delegatecall seam (_delegatecallDynamicFeeFacet) that the
    # revert-propagation suites exercise lives in MemeverseSwapFeeBase; and the
    # public-swap revert path executes SwapFeeMath / SwapGuardMath before the
    # delegatecall, so mapping them here is the symmetric defensive coverage.
    local dynamic_fee_paths
    dynamic_fee_paths="$(jq -r '.test_mapping.memeverse.rules[]
        | select(.id == "swap-dynamic-fee-facet") | .paths[]' .harness/policy.json)"
    grep -Fqx "src/swap/FacetGuard.sol" <<<"$dynamic_fee_paths"
    grep -Fqx "src/swap/MemeverseSwapFeeBase.sol" <<<"$dynamic_fee_paths"
    grep -Fqx "src/swap/libraries/SwapFeeMath.sol" <<<"$dynamic_fee_paths"
    grep -Fqx "src/swap/libraries/SwapGuardMath.sol" <<<"$dynamic_fee_paths"
}

write_changed_files() {
    local name="$1"
    shift
    local file="$tmp_dir/$name.changed"
    printf '%s\n' "$@" >"$file"
    printf '%s\n' "$file"
}

write_diff() {
    local name="$1"
    local path="$2"
    local removed="$3"
    local added="$4"
    local file="$tmp_dir/$name.diff"
    cat >"$file" <<EOF
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1 +1 @@
-$removed
+$added
EOF
    printf '%s\n' "$file"
}

write_multi_diff() {
    local name="$1"
    shift
    local file="$tmp_dir/$name.diff"
    : >"$file"

    while [ "$#" -gt 0 ]; do
        local path="$1"
        local removed="$2"
        local added="$3"
        shift 3
        cat >>"$file" <<EOF
diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1 +1 @@
-$removed
+$added
EOF
    done

    printf '%s\n' "$file"
}

run_ci_entrypoint_capture() {
    local name="$1"
    local event_name="$2"
    local fake_bin="$tmp_dir/$name.bin"
    local capture_dir="$tmp_dir/$name.capture"
    local runner_temp="$tmp_dir/$name.runner"

    mkdir -p "$fake_bin" "$capture_dir" "$runner_temp"

    cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_dir="${HARNESS_CAPTURE_DIR:?}"
printf '%s\n' "$@" >"$capture_dir/argv"
printf '%s' "${CHANGE_CLASSIFIER_DIFF_FILE:-}" >"$capture_dir/diff_path"

capture_changed_files=0
: >"$capture_dir/changed_files_args"
for arg in "$@"; do
    if [ "$capture_changed_files" -eq 1 ]; then
        if [[ "$arg" == --* ]]; then
            break
        fi
        printf '%s\n' "$arg" >>"$capture_dir/changed_files_args"
        continue
    fi
    if [ "$arg" = "--changed-files" ]; then
        capture_changed_files=1
    fi
done

if [ -n "${CHANGE_CLASSIFIER_DIFF_FILE:-}" ] && [ -f "${CHANGE_CLASSIFIER_DIFF_FILE}" ]; then
    cp "${CHANGE_CLASSIFIER_DIFF_FILE}" "$capture_dir/diff_file"
fi
EOF
    chmod +x "$fake_bin/npm"

    HARNESS_CAPTURE_DIR="$capture_dir" \
    HARNESS_EVENT_NAME="$event_name" \
    RUNNER_TEMP="$runner_temp" \
    PATH="$fake_bin:$PATH" \
    bash script/harness/ci-gate-entrypoint.sh

    printf '%s\n' "$capture_dir"
}

assert_ci_workflow_expressions() {
    python3 - <<'PY'
import yaml

with open(".github/workflows/test.yml", "r", encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)

steps = workflow["jobs"]["check"]["steps"]
run_gate_step = next(step for step in steps if step.get("name") == "Run gate:ci")
env = run_gate_step["env"]

assert env["HARNESS_EVENT_NAME"] == "${{ github.event_name }}"
assert env["RUN_RECORD_PATH"] == "${{ runner.temp }}/memeversev2-gate-ci.json"
assert run_gate_step["run"] == "bash script/harness/ci-gate-entrypoint.sh"
PY
}

run_gate_full_capture() {
    local name="$1"
    local changed_files="$2"
    local diff_file="$3"
    local fake_bin="$tmp_dir/$name.bin"
    local stdout="$tmp_dir/$name.stdout"
    local record="$tmp_dir/$name.record.json"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    mkdir -p "$fake_bin"

    cat >"$fake_bin/forge" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/forge"

    cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/npm"

    cat >"$fake_bin/slither" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "success": true,
  "results": {
    "detectors": [
      {
        "check": "reentrancy-eth",
        "impact": "High",
        "confidence": "High",
        "first_markdown_element": "src/verse/MemeverseLauncher.sol#L1-L4",
        "description": "New detector finding"
      }
    ]
  }
}
JSON
exit 0
EOF
    chmod +x "$fake_bin/slither"

    set +e
    PATH="$fake_bin:$PATH" RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
        bash script/harness/gate.sh --profile full --changed-files "${changed_file_args[@]}" >"$stdout" 2>&1
    status=$?
    set -e

    printf '%s\n%s\n%s\n' "$status" "$record" "$stdout"
}

run_gate_fast_capture() {
    local name="$1"
    local changed_files="$2"
    local diff_file="$3"
    local fake_bin="$tmp_dir/$name.bin"
    local stdout="$tmp_dir/$name.stdout"
    local record="$tmp_dir/$name.record.json"
    local capture_dir="$tmp_dir/$name.capture"
    local status
    local -a changed_file_args=()

    mapfile -t changed_file_args <"$changed_files"

    mkdir -p "$fake_bin" "$capture_dir"

    cat >"$fake_bin/forge" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_dir="${HARNESS_CAPTURE_DIR:?}"
printf '%s\n' "$*" >>"$capture_dir/forge_calls"

if [ "${1-}" = "fmt" ] || [ "${1-}" = "build" ]; then
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--list" ] && [ "${3-}" = "--match-path" ]; then
    case "${4-}" in
        test/polend/POLSplitter.t.sol)
            cat <<'LIST'
test/polend/POLSplitter.t.sol
  POLSplitterTest
    testNarrowGetters_ReturnStoredAddresses
LIST
            ;;
        test/polend/POLend.t.sol)
            cat <<'LIST'
test/polend/POLend.t.sol
  POLendTest
    testClaimResidual_MarksCallerAndTransfersToRecipient
LIST
            ;;
        *)
            echo "unexpected list path: ${4-}" >&2
            exit 1
            ;;
    esac
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--list" ] && [ "${3-}" = "--match-contract" ]; then
    cat <<'LIST'
test/polend/POLSplitter.t.sol
  POLSplitterTest
    testNarrowGetters_ReturnStoredAddresses
test/polend/POLend.t.sol
  POLendTest
    testClaimResidual_MarksCallerAndTransfersToRecipient
LIST
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--match-contract" ]; then
    exit 0
fi

if [ "${1-}" = "test" ] && [ "${2-}" = "--match-path" ]; then
    exit 0
fi

echo "unexpected forge invocation: $*" >&2
exit 1
EOF
    chmod +x "$fake_bin/forge"

    cat >"$fake_bin/npx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/npx"

    set +e
    PATH="$fake_bin:$PATH" HARNESS_CAPTURE_DIR="$capture_dir" RUN_RECORD_PATH="$record" CHANGE_CLASSIFIER_DIFF_FILE="$diff_file" \
        bash script/harness/gate.sh --profile fast --changed-files "${changed_file_args[@]}" >"$stdout" 2>&1
    status=$?
    set -e

    printf '%s\n%s\n%s\n%s\n' "$status" "$record" "$stdout" "$capture_dir"
}

assert_no_removed_fields() {
    local record="$1"
    jq -e '
      (has("requires_human_confirmation") | not) and
      has("requires_spec_authorization_evidence") and
      (has("risk_tier") | not) and
      (has("high-risk") | not) and
      (has("high_risk_paths") | not) and
      (has("high_risk_tokens") | not) and
      (has("high_risk_reasons") | not) and
      (has("review_matrix") | not) and
      (has("review_triggers") | not) and
      (has("doc_writer_roles") | not) and
      (has("selected_writer_roles") | not) and
      (has("writer_role") | not) and
      (has("selected_review_roles") | not) and
      (has("selected_review_roles_source") | not) and
      (has("pre_code_review_roles") | not) and
      (has("pre_code_review_roles_source") | not) and
      (has("post_code_review_roles") | not) and
      (has("post_code_review_roles_source") | not)
    ' "$record" >/dev/null
}

# The destructive-Git PreToolUse hook must deny when it cannot inspect a
# request. Each case gives the hook a fresh PATH containing only the tools it
# needs, so missing-reader/parser/splitter behavior cannot inherit host tools.
make_destructive_git_guard_path() {
    local case_name="$1"
    local bin="$tmp_dir/destructive-git-guard-$case_name.bin"

    mkdir -p "$bin"
    printf '%s\n' "$bin"
}

link_destructive_git_guard_tool() {
    local bin="$1"
    local tool="$2"
    local tool_path

    tool_path="$(command -v "$tool")"
    [ -n "$tool_path" ] || {
        echo "destructive-git guard test requires $tool" >&2
        return 1
    }
    ln -s "$tool_path" "$bin/$tool"
}

run_destructive_git_guard() {
    local guard="$1"
    local bash_bin="$2"
    local bin="$3"
    local case_name="$4"
    local payload="$5"
    local status

    set +e
    PATH="$bin" "$bash_bin" "$guard" <<<"$payload" \
        >"$tmp_dir/destructive-git-guard-$case_name.stdout" \
        2>"$tmp_dir/destructive-git-guard-$case_name.stderr"
    status=$?
    set -e

    printf '%s\n' "$status"
}

assert_destructive_git_guard_fails_closed() {
    local guard="$repo_root/script/harness/block-destructive-git.sh"
    local bash_bin
    local ordinary_bin
    local stash_create_bin
    local no_jq_bin
    local malformed_json_bin
    local status
    local payload='{"tool_input":{"command":"git reset --hard"}}'
    local non_string_case
    local non_string_label
    local non_string_payload
    local destructive_case
    local destructive_label
    local destructive_payload
    local allow_case
    local allow_label
    local allow_payload
    local malformed_case
    local malformed_label
    local malformed_payload
    local large_argument
    local large_command
    local large_payload
    local cache_root_fixture
    local cache_root_binary
    local started_ns
    local finished_ns
    local elapsed_ms

    bash_bin="$(command -v bash)"
    [ -x "$bash_bin" ] || {
        echo "destructive-git guard test requires bash" >&2
        return 1
    }

    # Build the cached native helper with the real PATH before dependency-
    # isolation cases replace PATH with a deliberately sparse directory.
    set +e
    "$bash_bin" "$guard" <<<'{"tool_input":{"command":"git status"}}' \
        >"$tmp_dir/destructive-git-guard-warm.stdout" \
        2>"$tmp_dir/destructive-git-guard-warm.stderr"
    status=$?
    set -e
    [ "$status" -eq 0 ] || { echo "native guard warmup: expected exit 0, got $status" >&2; return 1; }

    cache_root_fixture="$tmp_dir/destructive-git-cache-root"
    cache_root_binary="$cache_root_fixture/.harness/.runs/destructive-git-guard/release/destructive-git-guard"
    mkdir -p \
        "$cache_root_fixture/script/harness/destructive-git-guard/src" \
        "${cache_root_binary%/*}"
    cp "$guard" "$cache_root_fixture/script/harness/block-destructive-git.sh"
    : >"$cache_root_fixture/script/harness/destructive-git-guard/Cargo.toml"
    : >"$cache_root_fixture/script/harness/destructive-git-guard/Cargo.lock"
    : >"$cache_root_fixture/script/harness/destructive-git-guard/src/lib.rs"
    cat >"$cache_root_binary" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$cache_root_binary"
    set +e
    (
        cd "$cache_root_fixture/script/harness"
        "$bash_bin" ./block-destructive-git.sh <<<'{"tool_input":{"command":"git status"}}'
    ) >"$tmp_dir/destructive-git-cache-root.stdout" 2>"$tmp_dir/destructive-git-cache-root.stderr"
    status=$?
    set -e
    [ "$status" -eq 0 ] || { echo "cache root from script directory: expected exit 0, got $status" >&2; return 1; }
    [ ! -e "$cache_root_fixture/script/harness/.harness" ] \
        || { echo "cache root from script directory: created nested .harness" >&2; return 1; }

    ordinary_bin="$(make_destructive_git_guard_path ordinary)"
    link_destructive_git_guard_tool "$ordinary_bin" cat
    link_destructive_git_guard_tool "$ordinary_bin" jq
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" ordinary "$payload")"
    [ "$status" -eq 2 ] || { echo "ordinary destructive git: expected exit 2, got $status" >&2; return 1; }
    grep -Eq '"continue"[[:space:]]*:[[:space:]]*false' "$tmp_dir/destructive-git-guard-ordinary.stdout" \
        || { echo "ordinary destructive git: missing block result" >&2; return 1; }

    for non_string_case in \
        'missing command:{"tool_input":{}}' \
        'null command:{"tool_input":{"command":null}}' \
        'boolean command:{"tool_input":{"command":true}}' \
        'numeric command:{"tool_input":{"command":0}}' \
        'array command:{"tool_input":{"command":[]}}' \
        'object command:{"tool_input":{"command":{}}}'; do
        non_string_label="${non_string_case%%:*}"
        non_string_payload="${non_string_case#*:}"
        status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" "$non_string_label" "$non_string_payload")"
        [ "$status" -eq 2 ] || { echo "$non_string_label: expected exit 2, got $status" >&2; return 1; }
        grep -Fq '[harness] destructive-git guard failed closed' "$tmp_dir/destructive-git-guard-$non_string_label.stderr" \
            || { echo "$non_string_label: missing fail-closed diagnostic" >&2; return 1; }
    done

    stash_create_bin="$(make_destructive_git_guard_path stash-create)"
    link_destructive_git_guard_tool "$stash_create_bin" cat
    link_destructive_git_guard_tool "$stash_create_bin" jq
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$stash_create_bin" stash-create \
        '{"tool_input":{"command":"git stash create"}}')"
    [ "$status" -eq 0 ] || { echo "git stash create: expected exit 0, got $status" >&2; return 1; }

    no_jq_bin="$(make_destructive_git_guard_path no-jq)"
    link_destructive_git_guard_tool "$no_jq_bin" cat
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$no_jq_bin" no-jq "$payload")"
    [ "$status" -eq 2 ] || { echo "missing jq: expected exit 2, got $status" >&2; return 1; }
    grep -Eq '"continue"[[:space:]]*:[[:space:]]*false' "$tmp_dir/destructive-git-guard-no-jq.stdout" \
        || { echo "missing jq: native helper did not block destructive git" >&2; return 1; }

    malformed_json_bin="$(make_destructive_git_guard_path malformed-json)"
    link_destructive_git_guard_tool "$malformed_json_bin" cat
    link_destructive_git_guard_tool "$malformed_json_bin" jq
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$malformed_json_bin" malformed-json \
        '{"tool_input":{"command":')"
    [ "$status" -eq 2 ] || { echo "malformed JSON: expected exit 2, got $status" >&2; return 1; }
    grep -Fq '[harness] destructive-git guard failed closed' "$tmp_dir/destructive-git-guard-malformed-json.stderr" \
        || { echo "malformed JSON: missing fail-closed diagnostic" >&2; return 1; }

    # The old text splitter lost quote boundaries before shell wrappers were
    # inspected. The AST guard must recurse into executable wrapper scripts,
    # while keeping heredoc data and quoted literals non-executable.
    for destructive_case in \
        'shell-stdin-bash:{"tool_input":{"command":"bash <<'\''EOF'\''\ngit restore -- target\nEOF"}}' \
        'shell-stdin-sh:{"tool_input":{"command":"sh <<'\''EOF'\''\ngit reset --hard HEAD\nEOF"}}' \
        'shell-stdin-rtk-bash:{"tool_input":{"command":"rtk bash <<'\''EOF'\''\ngit restore -- target\nEOF"}}' \
        'wrapped-semicolon-squote:{"tool_input":{"command":"bash -c '\''git restore -- target; true'\''"}}' \
        'wrapped-semicolon-dquote:{"tool_input":{"command":"bash -c \"git restore -- target; true\""}}' \
        'wrapped-and:{"tool_input":{"command":"bash -c '\''git restore -- target && true'\''"}}' \
        'wrapped-or:{"tool_input":{"command":"bash -c '\''git restore -- target || true'\''"}}' \
        'wrapped-pipe:{"tool_input":{"command":"bash -c '\''git restore -- target | cat'\''"}}' \
        'wrapped-newline:{"tool_input":{"command":"bash -c '\''git restore -- target\ntrue'\''"}}' \
        'wrapped-trailing-argv0:{"tool_input":{"command":"bash -c '\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-login-shell:{"tool_input":{"command":"bash -lc '\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-double-space:{"tool_input":{"command":"bash  -c '\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-tab-space:{"tool_input":{"command":"bash\t-c\t'\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-path:{"tool_input":{"command":"/bin/bash -c '\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-env:{"tool_input":{"command":"env bash -c '\''git restore -- target; true'\'' sentinel"}}' \
        'wrapped-bash-plus-x:{"tool_input":{"command":"bash +x -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-plus-xc:{"tool_input":{"command":"bash +xc '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-cluster-O:{"tool_input":{"command":"bash -xO extglob -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-cluster-o:{"tool_input":{"command":"bash +xo posix -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-plus-o:{"tool_input":{"command":"bash +O extglob -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-pipefail:{"tool_input":{"command":"bash -o pipefail -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-extglob:{"tool_input":{"command":"bash -O extglob -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-rcfile:{"tool_input":{"command":"bash --rcfile /dev/null -c '\''git restore -- target; true'\''"}}' \
        'wrapped-bash-c-double-dash:{"tool_input":{"command":"bash -c -- \"git restore -- target\""}}' \
        'wrapped-bash-Oc:{"tool_input":{"command":"bash -Oc extglob \"git restore -- target\""}}' \
        'wrapped-bash-cO-separated:{"tool_input":{"command":"bash -cO extglob '\''git restore -- target'\''"}}' \
        'wrapped-bash-co-separated:{"tool_input":{"command":"bash -co pipefail '\''git restore -- target'\''"}}' \
        'wrapped-bash-c-space-O:{"tool_input":{"command":"bash -c -O extglob '\''git restore -- target'\''"}}' \
        'wrapped-bash-c-space-o:{"tool_input":{"command":"bash -c -o pipefail '\''git restore -- target'\''"}}' \
        'wrapped-trap-static:{"tool_input":{"command":"trap '\''git restore -- target'\'' EXIT"}}' \
        'wrapped-trap-dynamic:{"tool_input":{"command":"trap \"$ACTION\" EXIT"}}' \
        'wrapped-trap-double-dash-dynamic:{"tool_input":{"command":"trap -- \"$ACTION\" EXIT"}}' \
        'wrapped-stash-update:{"tool_input":{"command":"git stash -u"}}' \
        'wrapped-clean-config:{"tool_input":{"command":"git -c clean.requireForce=false clean"}}' \
        'wrapped-clean-config-zero:{"tool_input":{"command":"git -c clean.requireForce=0 clean"}}' \
        'wrapped-checkout-force:{"tool_input":{"command":"git checkout -f branch"}}' \
        'wrapped-checkout-ours:{"tool_input":{"command":"git checkout --ours target"}}' \
        'wrapped-checkout-path-mode:{"tool_input":{"command":"git checkout HEAD target"}}' \
        'wrapped-switch-discard:{"tool_input":{"command":"git switch --discard-changes branch"}}' \
        'wrapped-global-git-dir:{"tool_input":{"command":"git --git-dir .git restore -- target"}}' \
        'wrapped-global-work-tree:{"tool_input":{"command":"git --work-tree=. restore -- target"}}' \
        'wrapped-global-git-dir-attached:{"tool_input":{"command":"git --git-dir=.git restore -- target"}}' \
        'wrapped-global-exec-path:{"tool_input":{"command":"git -e /tmp restore -- target"}}' \
        'wrapped-global-unknown:{"tool_input":{"command":"git --unknown-global-option restore -- target"}}' \
        'wrapped-global-after-boundary:{"tool_input":{"command":"git -- --git-dir .git restore -- target"}}' \
        'wrapped-alias-config:{"tool_input":{"command":"git -c alias.wipe=\"restore --\" wipe target"}}' \
        'wrapped-config-env-alias:{"tool_input":{"command":"ALIAS_VALUE='\''restore --'\'' git --config-env=alias.wipe=ALIAS_VALUE wipe target"}}' \
        'wrapped-implicit-xargs-input:{"tool_input":{"command":"xargs git"}}' \
        'wrapped-xargs-arg-file:{"tool_input":{"command":"xargs -a args.txt git"}}' \
        'wrapped-runtime-xargs:{"tool_input":{"command":"printf \"%s\\n\" restore | xargs git"}}' \
        'wrapped-runtime-xargs-env:{"tool_input":{"command":"printf \"%s\\n\" git | xargs env git"}}' \
        'wrapped-runtime-xargs-rtk:{"tool_input":{"command":"printf \"%s\\n\" restore | xargs rtk git"}}' \
        'wrapped-runtime-xargs-env-rtk:{"tool_input":{"command":"printf \"%s\\n\" restore | xargs env rtk git"}}' \
        'wrapped-runtime-xargs-git-branch:{"tool_input":{"command":"printf \"%s\\n\" '\''-D main'\'' | xargs git branch"}}' \
        'wrapped-env-cluster:{"tool_input":{"command":"env -iu FOO git restore -- target"}}' \
        'wrapped-xargs-cluster:{"tool_input":{"command":"xargs -rn 1 git restore -- target <<< value"}}' \
        'wrapped-time-format:{"tool_input":{"command":"/usr/bin/time -f marker git restore -- target"}}' \
        'wrapped-time-long-format:{"tool_input":{"command":"/usr/bin/time --format marker git restore -- target"}}' \
        'wrapped-inherited-shell-stdin:{"tool_input":{"command":"printf \"%s\\n\" \"git restore -- target\" | bash -c \"bash\""}}' \
        'clean-option-boundary:{"tool_input":{"command":"git clean -f -- -n"}}' \
        'rm-option-boundary:{"tool_input":{"command":"git rm -- --cached"}}' \
        'rm-pathspec-operand:{"tool_input":{"command":"git rm --pathspec-from-file --cached"}}' \
        'wrapped-runtime-xargs-herestring:{"tool_input":{"command":"xargs git <<< restore"}}' \
        'wrapped-env-double-dash:{"tool_input":{"command":"env -- bash -c '\''git restore -- target; true'\''"}}' \
        'wrapped-env-path:{"tool_input":{"command":"/usr/bin/env bash -c '\''git restore -- target; true'\''"}}' \
        'wrapped-command-double-dash:{"tool_input":{"command":"command -- bash -c '\''git restore -- target; true'\''"}}' \
        'wrapped-ansi-c-quote:{"tool_input":{"command":"bash -c $'\''git restore -- target; true'\''"}}' \
        'wrapped-ansi-c-command:{"tool_input":{"command":"bash -c $'\''\x67it restore -- target; true'\''"}}' \
        'wrapped-subshell:{"tool_input":{"command":"bash -c '\''(git restore -- target)'\''"}}' \
        'wrapped-brace:{"tool_input":{"command":"bash -c '\''{ git restore -- target; }'\''"}}' \
        'wrapped-if:{"tool_input":{"command":"bash -c '\''if true; then git restore -- target; fi'\''"}}' \
        'wrapped-negation:{"tool_input":{"command":"bash -c '\''! git restore -- target'\''"}}' \
        'leading-redirection:{"tool_input":{"command":">/dev/null bash -c '\''git restore -- target'\''"}}' \
        'here-string:{"tool_input":{"command":"bash <<< '\''git restore -- target'\''"}}' \
        'file-stdin:{"tool_input":{"command":"bash < script/example.sh"}}' \
        'env-opaque-split-string:{"tool_input":{"command":"env -iS '\''bash -c \"git restore -- target\"'\''"}}' \
        'source-file:{"tool_input":{"command":"source script/example.sh"}}' \
        'watch-wrapper:{"tool_input":{"command":"watch '\''git restore -- target'\''"}}' \
        'xargs-input-command:{"tool_input":{"command":"xargs -n1 git restore -- target"}}' \
        'comment-newline:{"tool_input":{"command":"echo ok # comment\ngit restore -- target"}}' \
        'escaped-space-comment-lookalike:{"tool_input":{"command":"echo foo\\ #bar; git restore -- target"}}' \
        'rtk-wrapped:{"tool_input":{"command":"rtk bash -c \"git reset --hard HEAD; echo ok\""}}' \
        'rtk-proxy-wrapped:{"tool_input":{"command":"rtk proxy bash -c '\''git restore -- target; true'\''"}}' \
        'rtk-run-wrapped:{"tool_input":{"command":"rtk run bash -c '\''git restore -- target; true'\''"}}' \
        'rtk-err-wrapped:{"tool_input":{"command":"rtk err bash -c '\''git restore -- target; true'\''"}}' \
        'rtk-summary-wrapped:{"tool_input":{"command":"rtk summary bash -c '\''git restore -- target; true'\''"}}' \
        'rtk-test-wrapped:{"tool_input":{"command":"rtk test bash -c '\''git restore -- target; true'\''"}}' \
        'rtk-verbose-proxy-wrapped:{"tool_input":{"command":"rtk -v proxy bash -c '\''git restore -- target; true'\''"}}' \
        'wrapped-coproc-wait:{"tool_input":{"command":"bash -c '\''coproc git restore -- target; wait'\''"}}' \
        'wrapped-coproc-and:{"tool_input":{"command":"bash -c '\''coproc git restore -- target && true'\''"}}' \
        'wrapped-coproc-or:{"tool_input":{"command":"bash -c '\''coproc git restore -- target || true'\''"}}' \
        'wrapped-coproc-pipe:{"tool_input":{"command":"bash -c '\''coproc git restore -- target | cat'\''"}}' \
        'recursive-wrapped:{"tool_input":{"command":"rtk bash -c '\''sh -c "git restore -- target; true"'\'' sentinel"}}' \
        'compound-wrapped:{"tool_input":{"command":"echo ok && bash -c '\''git restore -- target; true'\''"}}'; do
        destructive_label="${destructive_case%%:*}"
        destructive_payload="${destructive_case#*:}"
        status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" "$destructive_label" "$destructive_payload")"
        [ "$status" -eq 2 ] || { echo "$destructive_label: expected exit 2, got $status" >&2; return 1; }
        grep -Eq '"continue"[[:space:]]*:[[:space:]]*false' "$tmp_dir/destructive-git-guard-$destructive_label.stdout" \
            || { echo "$destructive_label: missing block result" >&2; return 1; }
    done

    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" toolInput-alias \
        '{"toolInput":{"command":"git restore -- target"}}')"
    [ "$status" -eq 2 ] || { echo "toolInput alias: expected exit 2, got $status" >&2; return 1; }
    grep -Eq '"continue"[[:space:]]*:[[:space:]]*false' "$tmp_dir/destructive-git-guard-toolInput-alias.stdout" \
        || { echo "toolInput alias: missing block result" >&2; return 1; }

    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" duplicate-safe-input \
        '{"tool_input":{"command":"git status"},"tool_input":{"command":"git status"}}')"
    [ "$status" -eq 0 ] || { echo "duplicate safe input: expected exit 0, got $status" >&2; return 1; }

    for destructive_case in \
        'duplicate-input-destructive-last:{"tool_input":{"command":"git status"},"tool_input":{"command":"git restore -- target"}}' \
        'duplicate-input-destructive-first:{"tool_input":{"command":"git restore -- target"},"toolInput":{"command":"git status"}}' \
        'duplicate-command-destructive-last:{"tool_input":{"command":"git status","command":"git restore -- target"}}'; do
        destructive_label="${destructive_case%%:*}"
        destructive_payload="${destructive_case#*:}"
        status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" "$destructive_label" "$destructive_payload")"
        [ "$status" -eq 2 ] || { echo "$destructive_label: expected exit 2, got $status" >&2; return 1; }
        grep -Eq '"continue"[[:space:]]*:[[:space:]]*false' "$tmp_dir/destructive-git-guard-$destructive_label.stdout" \
            || { echo "$destructive_label: missing block result" >&2; return 1; }
    done

    cat >"$tmp_dir/harness-guard-plugin-test.mjs" <<'NODE'
import { pathToFileURL } from "node:url"

const { default: guard } = await import(
    pathToFileURL(process.env.HARNESS_GUARD_PLUGIN).href
)

const hooks = await guard({ directory: process.env.HARNESS_GUARD_REPO })
const before = hooks["tool.execute.before"]

async function expect(command, blocked) {
    let threw = false
    try {
        await before({ tool: "bash" }, { args: { command } })
    } catch {
        threw = true
    }
    if (threw !== blocked) {
        throw new Error((blocked ? "expected block: " : "expected allow: ") + command)
    }
}

for (const command of [
    "git push origin main",
    "/usr/bin/git push origin main",
    "'git' push origin main",
    "git -C . push",
    "bash -c 'git push origin main'",
    "rtk bash -c 'git push origin main'",
    "printf x | xargs git push",
    "echo ok; git push",
]) {
    await expect(command, true)
}

for (const command of [
    "rm -rf target",
    "/bin/rm -rf target",
    "env rm -rf target",
    "bash -c 'rm -rf target'",
    "git status",
    "command -v git restore",
    "trap -p EXIT",
    "xargs git status",
    "FOO=bar",
]) {
    await expect(command, false)
}
NODE
    HARNESS_GUARD_REPO="$repo_root" \
        HARNESS_GUARD_PLUGIN="$repo_root/.opencode/plugin/harness-guard.js" \
        node "$tmp_dir/harness-guard-plugin-test.mjs"

    for allow_case in \
        'wrapped-safe-command:{"tool_input":{"command":"bash -c '\''git status; true'\''"}}' \
        'wrapped-safe-variable:{"tool_input":{"command":"bash -c '\''printf \"%s\\n\" \"$HOME\"; true'\''"}}' \
        'shell-stdin-safe-bash:{"tool_input":{"command":"bash <<'\''EOF'\''\ngit status\nEOF"}}' \
        'data-heredoc-cat:{"tool_input":{"command":"cat <<'\''EOF'\''\ngit restore -- target\nEOF"}}' \
        'shell-c-heredoc-data:{"tool_input":{"command":"bash -c '\''cat >/dev/null'\'' <<'\''EOF'\''\ngit restore -- target\nEOF"}}' \
        'shell-script-heredoc-data:{"tool_input":{"command":"bash script/example.sh <<'\''EOF'\''\ngit reset --hard HEAD\nEOF"}}' \
        'safe-heredoc-apostrophe:{"tool_input":{"command":"cat <<'\''EOF'\''\nit'\''s safe\nEOF"}}' \
        'safe-heredoc-double-quote:{"tool_input":{"command":"cat <<'\''EOF'\''\n\"unterminated body quote\nEOF"}}' \
        'safe-variable:{"tool_input":{"command":"printf \"%s\\n\" \"$HOME\""}}' \
        'safe-command-substitution:{"tool_input":{"command":"printf \"%s\\n\" \"$(pwd)\""}}' \
        'safe-xargs-static:{"tool_input":{"command":"xargs git status"}}' \
        'safe-runtime-xargs-static:{"tool_input":{"command":"printf \"%s\\n\" restore | xargs git status"}}' \
        'safe-runtime-xargs-herestring:{"tool_input":{"command":"xargs git status <<< restore"}}' \
        'safe-xargs-env-static:{"tool_input":{"command":"xargs env git status"}}' \
        'safe-xargs-rtk-static:{"tool_input":{"command":"xargs rtk git status"}}' \
        'safe-watch-static:{"tool_input":{"command":"watch git status"}}' \
        'safe-env-static:{"tool_input":{"command":"env git status -S"}}' \
        'safe-bash-plus-x:{"tool_input":{"command":"bash +x -c '\''git status'\''"}}' \
        'safe-bash-official-options:{"tool_input":{"command":"bash -p -c '\''git status'\''"}}' \
        'safe-checkout-create:{"tool_input":{"command":"git checkout -b feature main"}}' \
        'safe-clean-clustered-dry-run:{"tool_input":{"command":"git clean -nfdx"}}' \
        'safe-rm-cached-recursive:{"tool_input":{"command":"git rm --cached -r target"}}' \
        'safe-cat-here-string:{"tool_input":{"command":"cat <<< '\''git restore -- target'\''"}}' \
        'safe-rtk-version:{"tool_input":{"command":"rtk --version"}}' \
        'safe-rtk-help:{"tool_input":{"command":"rtk --help"}}' \
        'safe-rtk-verbose-version:{"tool_input":{"command":"rtk -v --version"}}' \
        'safe-rtk-run-help:{"tool_input":{"command":"rtk run --help"}}' \
        'safe-rtk-proxy-help:{"tool_input":{"command":"rtk proxy -h"}}' \
        'safe-rtk-err-help:{"tool_input":{"command":"rtk err --help"}}' \
        'safe-rtk-summary-help:{"tool_input":{"command":"rtk summary --help"}}' \
        'safe-rtk-test-help:{"tool_input":{"command":"rtk test --help"}}' \
        'safe-rtk-summary-command:{"tool_input":{"command":"rtk summary git status"}}' \
        'safe-rtk-test-command:{"tool_input":{"command":"rtk test git status"}}' \
        'safe-grouping:{"tool_input":{"command":"(git status)"}}' \
        'safe-conditional:{"tool_input":{"command":"if true; then git status; fi"}}' \
        'safe-shell-script:{"tool_input":{"command":"bash script/example.sh"}}' \
        'safe-command-option:{"tool_input":{"command":"command -v git"}}' \
        'safe-command-option-args:{"tool_input":{"command":"command -v git restore"}}' \
        'safe-command-query:{"tool_input":{"command":"command -V git restore"}}' \
        'safe-command-clustered-query:{"tool_input":{"command":"command -pv git restore"}}' \
        'safe-command-clustered-query-upper:{"tool_input":{"command":"command -pV git restore"}}' \
        'safe-env-cluster:{"tool_input":{"command":"env -iu FOO git status"}}' \
        'safe-xargs-cluster:{"tool_input":{"command":"xargs -rn 1 git status <<< value"}}' \
        'safe-time-format:{"tool_input":{"command":"/usr/bin/time -f marker git status"}}' \
        'safe-clean-option-boundary:{"tool_input":{"command":"git clean -n -- --no-dry-run"}}' \
        'safe-rm-option-boundary:{"tool_input":{"command":"git rm -n -- --no-dry-run"}}' \
        'safe-reset-path:{"tool_input":{"command":"git reset -- target"}}' \
        'safe-reset-patch:{"tool_input":{"command":"git reset -p"}}' \
        'safe-reset-intent-to-add:{"tool_input":{"command":"git reset -N target"}}' \
        'safe-trap-query:{"tool_input":{"command":"trap -p EXIT"}}' \
        'safe-trap-clear:{"tool_input":{"command":"trap - EXIT"}}' \
        'safe-git-config:{"tool_input":{"command":"git -c core.quotePath=false status"}}' \
        'safe-assignment-only:{"tool_input":{"command":"FOO=bar"}}' \
        'safe-multiple-assignments:{"tool_input":{"command":"FOO=bar BAZ=qux"}}' \
        'safe-substitution-assignment:{"tool_input":{"command":"FOO=$(pwd)"}}' \
        'quoted-assignment-command-name:{"tool_input":{"command":"'\''FOO=bar'\''"}}' \
        'leading-redirection-quoted-command:{"tool_input":{"command":">/dev/null '\''FOO=bar'\'' git restore -- target"}}' \
        'quoted-literal-restore:{"tool_input":{"command":"echo '\''git restore -- target'\''"}}' \
        'comment-apostrophe:{"tool_input":{"command":"echo ok # don'\''t"}}' \
        'quoted-literal-operator:{"tool_input":{"command":"echo '\''a && b'\''"}}' \
        'safe-double-quoted-backslash:{"tool_input":{"command":"printf \"%s\\n\" \"foo\\q\""}}' \
        'safe-parameter-literal:{"tool_input":{"command":"printf \"%s\\n\" \"${value:-&git restore}\""}}'; do
        allow_label="${allow_case%%:*}"
        allow_payload="${allow_case#*:}"
        status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" "$allow_label" "$allow_payload")"
        [ "$status" -eq 0 ] || { echo "$allow_label: expected exit 0, got $status" >&2; return 1; }
    done

    local safe_ansi_command
    local safe_ansi_payload
    safe_ansi_command="printf '%s\\n' \$'don\\'t'"
    safe_ansi_payload="$(jq -cn --arg command "$safe_ansi_command" '{tool_input:{command:$command}}')"
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" safe-ansi-apostrophe "$safe_ansi_payload")"
    [ "$status" -eq 0 ] || { echo "safe-ansi-apostrophe: expected exit 0, got $status" >&2; return 1; }

    for malformed_case in \
        'unclosed-squote:{"tool_input":{"command":"bash -c '\''git restore -- target"}}' \
        'unclosed-dquote:{"tool_input":{"command":"bash -c \"git restore -- target"}}' \
        'trailing-backslash:{"tool_input":{"command":"git restore -- target \\"}}' \
        'unbalanced-inner:{"tool_input":{"command":"bash -c \"echo '\''hi\""}}'; do
        malformed_label="${malformed_case%%:*}"
        malformed_payload="${malformed_case#*:}"
        status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" "$malformed_label" "$malformed_payload")"
        [ "$status" -eq 2 ] || { echo "$malformed_label: expected exit 2, got $status" >&2; return 1; }
        grep -Fq '[harness] destructive-git guard failed closed' "$tmp_dir/destructive-git-guard-$malformed_label.stderr" \
            || { echo "$malformed_label: missing fail-closed diagnostic" >&2; return 1; }
    done

    printf -v large_argument '%*s' 10240 ''
    large_argument="${large_argument// /x}"
    large_command="printf '%s\\n' '$large_argument'"
    large_payload="$(jq -cn --arg command "$large_command" '{tool_input:{command:$command}}')"

    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" large-warm "$large_payload")"
    [ "$status" -eq 0 ] || { echo "10KB warmup: expected exit 0, got $status" >&2; return 1; }
    started_ns="$(date +%s%N)"
    status="$(run_destructive_git_guard "$guard" "$bash_bin" "$ordinary_bin" large-timed "$large_payload")"
    finished_ns="$(date +%s%N)"
    [ "$status" -eq 0 ] || { echo "10KB command: expected exit 0, got $status" >&2; return 1; }
    elapsed_ms=$(((finished_ns - started_ns) / 1000000))
    [ "$elapsed_ms" -le 500 ] \
        || { echo "10KB command: expected <=500ms, got ${elapsed_ms}ms" >&2; return 1; }
}

if [ "${ORCHESTRATION_TEST_FOCUS-}" = "destructive-git-guard" ]; then
    assert_destructive_git_guard_fails_closed
    echo "destructive-git guard regression tests passed"
    exit 0
fi

docs_changed="$(write_changed_files docs docs/foo.md)"
docs_record="$(run_classify docs "$docs_changed")"
jq -e '
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == [] and
  .doc_round_required == false and
  .requires_spec_authorization_evidence == false
' "$docs_record" >/dev/null
assert_no_removed_fields "$docs_record"

readme_changed="$(write_changed_files readme README.md)"
readme_record="$(run_classify readme "$readme_changed")"
jq -e '
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .candidate_orchestration_profile == "direct" and
  .requires_doc_editorial_attestation == true and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == [] and
  .doc_round_required == false
' "$readme_record" >/dev/null
assert_no_removed_fields "$readme_record"

spec_changed="$(write_changed_files spec docs/superpowers/specs/foo.md)"
spec_record="$(run_classify spec "$spec_changed")"
jq -e '
  .orchestration_profile == "delegated" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == [] and
  .code_review_roles == [] and
  .requires_spec_authorization_evidence == true and
  .doc_round_required == false
' "$spec_record" >/dev/null
assert_no_removed_fields "$spec_record"

test_changed="$(write_changed_files testsol test/verse/MemeverseLauncherConfig.t.sol)"
test_diff="$(write_diff testsol test/verse/MemeverseLauncherConfig.t.sol 'uint256 oldValue = 1;' 'uint256 newValue = 2;')"
test_record="$(run_classify testsol "$test_changed" "$test_diff")"
jq -e '
  .change_class == "test-semantic" and
  .orchestration_profile == "direct-review" and
  .harness_writer_roles == [] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  .code_review_roles == ["logic-reviewer"] and
  .doc_round_required == false
' "$test_record" >/dev/null
assert_no_removed_fields "$test_record"

src_changed="$(write_changed_files srcsol src/verse/MemeverseLauncher.sol)"
src_diff="$(write_diff srcsol src/verse/MemeverseLauncher.sol 'uint256 oldAmount = amount;' 'uint256 newAmount = amount + 1;')"
src_record="$(run_classify srcsol "$src_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  .doc_round_required == true and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"]
' "$src_record" >/dev/null
assert_no_removed_fields "$src_record"

planned_src_record="$(run_classify_with_changed_args plannedsrc 0 --planned-files src/verse/MemeverseLauncher.sol)"
jq -e '
  .changed_files == ["src/verse/MemeverseLauncher.sol"] and
  .file_input_mode == "planned-files" and
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  .doc_round_required == true and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification"))
' "$planned_src_record" >/dev/null
assert_no_removed_fields "$planned_src_record"

planned_test_record="$(run_classify_with_changed_args plannedtest 0 --planned-files test/verse/MemeverseLauncherConfig.t.sol)"
jq -e '
  .changed_files == ["test/verse/MemeverseLauncherConfig.t.sol"] and
  .file_input_mode == "planned-files" and
  .change_class == "test-semantic" and
  .orchestration_profile == "direct-review" and
  .harness_writer_roles == [] and
  .code_writer_roles == ["solidity-implementer"] and
  .code_review_roles == ["logic-reviewer"] and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification")) and
  .doc_round_required == false
' "$planned_test_record" >/dev/null
assert_no_removed_fields "$planned_test_record"

planned_spec_record="$(run_classify_with_changed_args plannedspec 0 --planned-files docs/spec/foo.md)"
jq -e '
  .changed_files == ["docs/spec/foo.md"] and
  .file_input_mode == "planned-files" and
  .requires_spec_authorization_evidence == true
' "$planned_spec_record" >/dev/null
assert_no_removed_fields "$planned_spec_record"

planned_non_spec_record="$(run_classify_with_changed_args plannednonspec 0 --planned-files docs/foo.md)"
jq -e '
  .changed_files == ["docs/foo.md"] and
  .file_input_mode == "planned-files" and
  .requires_spec_authorization_evidence == false
' "$planned_non_spec_record" >/dev/null
assert_no_removed_fields "$planned_non_spec_record"

planned_mixed_spec_record="$(run_classify_with_changed_args plannedmixedspec 0 --planned-files src/verse/MemeverseLauncher.sol docs/spec/verse/state-machines.md)"
jq -e '
  .changed_files == ["src/verse/MemeverseLauncher.sol", "docs/spec/verse/state-machines.md"] and
  .file_input_mode == "planned-files" and
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  .doc_round_required == true and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .requires_spec_authorization_evidence == true and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification"))
' "$planned_mixed_spec_record" >/dev/null
assert_no_removed_fields "$planned_mixed_spec_record"

planned_mixed_non_spec_record="$(run_classify_with_changed_args plannedmixednonspec 0 --planned-files src/verse/MemeverseLauncher.sol docs/TRACEABILITY.md)"
jq -e '
  .changed_files == ["src/verse/MemeverseLauncher.sol", "docs/TRACEABILITY.md"] and
  .file_input_mode == "planned-files" and
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  .doc_round_required == true and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .requires_spec_authorization_evidence == false and
  (.residual_risks[] | select(.rule_id == "planned-solidity-classification"))
' "$planned_mixed_non_spec_record" >/dev/null
assert_no_removed_fields "$planned_mixed_non_spec_record"

mixed_changed="$(write_changed_files mixed src/verse/MemeverseLauncher.sol docs/spec/verse/state-machines.md)"
mixed_record="$(run_classify mixed "$mixed_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .doc_round_required == true and
  .requires_spec_authorization_evidence == true
' "$mixed_record" >/dev/null
assert_no_removed_fields "$mixed_record"

mixed_non_spec_changed="$(write_changed_files mixednonspec src/verse/MemeverseLauncher.sol docs/TRACEABILITY.md)"
mixed_non_spec_record="$(run_classify mixednonspec "$mixed_non_spec_changed" "$src_diff")"
jq -e '
  .change_class == "prod-semantic" and
  .orchestration_profile == "full-review" and
  .harness_writer_roles == ["process-implementer"] and
  (has("spec_review_required") | not) and
  .code_writer_roles == ["solidity-implementer"] and
  (.code_review_roles | sort) == ["logic-reviewer", "refinement-reviewer", "security-reviewer"] and
  .doc_round_required == true and
  .requires_spec_authorization_evidence == false
' "$mixed_non_spec_record" >/dev/null
assert_no_removed_fields "$mixed_non_spec_record"

single_direct_record="$(run_classify_with_changed_args singledirect 0 --changed-files script/harness/gate.sh)"
jq -e '
  .changed_files == ["script/harness/gate.sh"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated" and
  .final_verdict == "classified" and
  .doc_round_required == false
' "$single_direct_record" >/dev/null
assert_no_removed_fields "$single_direct_record"

multi_direct_record="$(run_classify_with_changed_args multidirect 0 --changed-files script/harness/gate.sh script/harness/test-orchestration.sh)"
jq -e '
  .changed_files == ["script/harness/gate.sh", "script/harness/test-orchestration.sh"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated"
' "$multi_direct_record" >/dev/null
assert_no_removed_fields "$multi_direct_record"

subdir_repo_relative_record="$(run_classify_from_subdir subdirrepo docs 1 src/verse/MemeverseLauncher.sol)"
jq -e '
  .changed_files == ["src/verse/MemeverseLauncher.sol"] and
  .surfaces == "solidity_prod" and
  .change_class == "blocked" and
  .final_verdict == "blocked" and
  .semantic_prod_files == [] and
  .non_semantic_prod_files == [] and
  (.blocking_findings[] | select(.rule_id == "semantic-classification-requires-diff"))
' "$subdir_repo_relative_record" >/dev/null
assert_no_removed_fields "$subdir_repo_relative_record"

absolute_inside_record="$(run_classify_with_changed_args absinside 1 --changed-files "$repo_root/src/verse/MemeverseLauncher.sol")"
jq -e '
  .changed_files == ["src/verse/MemeverseLauncher.sol"] and
  .surfaces == "solidity_prod" and
  .change_class == "blocked" and
  .semantic_prod_files == [] and
  .non_semantic_prod_files == [] and
  .final_verdict == "blocked"
' "$absolute_inside_record" >/dev/null
assert_no_removed_fields "$absolute_inside_record"

mapfile -t absolute_outside_run < <(run_classify_capture absoutside /tmp/memeverse-outside.sol)
[ "${absolute_outside_run[0]}" -eq 1 ]
grep -Fqx "[gate] ERROR: --changed-files path must be inside repo root: /tmp/memeverse-outside.sol" "${absolute_outside_run[2]}"

pure_unknown_changed="$(write_changed_files pureunknown notes.txt)"
pure_unknown_record="$(run_classify pureunknown "$pure_unknown_changed" "" 1)"
jq -e '
  .change_class == "no-op" and
  .orchestration_profile == "blocked" and
  .final_verdict == "blocked" and
  (.blocking_findings[] | select(.rule_id == "unclassified-paths"))
' "$pure_unknown_record" >/dev/null
assert_no_removed_fields "$pure_unknown_record"

default_record="$(run_default_classify_in_scratch_repo default README.md)"
jq -e '
  .changed_files == ["README.md"] and
  .change_class == "non-semantic" and
  .orchestration_profile == "delegated"
' "$default_record" >/dev/null
assert_no_removed_fields "$default_record"

assert_invalid_test_mapping_references_are_rejected
assert_delegated_review_rules_are_rejected_and_removed
assert_shared_facet_paths_map_to_consumers
assert_destructive_git_guard_fails_closed

assert_ci_workflow_expressions

zero_base_capture="$(run_ci_entrypoint_capture zero-base workflow_dispatch)"
grep -qx -- "run" "$zero_base_capture/argv"
grep -qx -- "gate:ci" "$zero_base_capture/argv"
grep -qx -- "--" "$zero_base_capture/argv"
grep -qx -- "--all" "$zero_base_capture/argv"
if grep -qx -- "--changed-files" "$zero_base_capture/argv"; then
    echo "zero-base CI path should not pass --changed-files" >&2
    exit 1
fi
[ ! -s "$zero_base_capture/diff_path" ]
[ ! -f "$zero_base_capture/changed_files" ]

diff_capture="$(run_ci_entrypoint_capture diff-based push)"
grep -qx -- "run" "$diff_capture/argv"
grep -qx -- "gate:ci" "$diff_capture/argv"
grep -qx -- "--" "$diff_capture/argv"
grep -qx -- "--all" "$diff_capture/argv"
if grep -qx -- "--changed-files" "$diff_capture/argv"; then
    echo "CI entrypoint must not pass --changed-files (it always runs --all)" >&2
    exit 1
fi
[ ! -s "$diff_capture/diff_path" ]

slither_changed="$(write_changed_files slither src/verse/MemeverseLauncher.sol)"
slither_diff="$(write_diff slither src/verse/MemeverseLauncher.sol 'uint256 oldAmount = amount;' 'uint256 newAmount = amount + 1;')"
mapfile -t slither_run < <(run_gate_full_capture slither "$slither_changed" "$slither_diff")
slither_status="${slither_run[0]}"
slither_record="${slither_run[1]}"
slither_stdout="${slither_run[2]}"
[ "$slither_status" -ne 0 ]
jq -e '
  .final_verdict == "fail" and
  .command_results.slither_when_required.status == "failed" and
  (.blocking_findings[] | select(.rule_id == "slither_when_required"))
' "$slither_record" >/dev/null
grep -Fq "new slither finding" "$slither_stdout"

if grep -Fq "review roles are the union" docs/TRACEABILITY.md; then
    echo "TRACEABILITY still contains old review union wording" >&2
    exit 1
fi
if grep -Fq "writer may be \`mixed\`" docs/TRACEABILITY.md; then
    echo "TRACEABILITY still contains old mixed writer wording" >&2
    exit 1
fi
grep -Fq 'The gate reports phase fields for `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.' docs/TRACEABILITY.md

contract_changed="$(write_changed_files contract-fast test/polend/POLSplitter.t.sol test/polend/POLend.t.sol)"
contract_diff="$(write_multi_diff contract-fast \
  test/polend/POLSplitter.t.sol 'function oldSplitter() external {}' 'function newSplitter() external {}' \
  test/polend/POLend.t.sol 'function oldPOLend() external {}' 'function newPOLend() external {}')"
mapfile -t contract_fast_run < <(run_gate_fast_capture contract-fast "$contract_changed" "$contract_diff")
contract_fast_status="${contract_fast_run[0]}"
contract_fast_record="${contract_fast_run[1]}"
contract_fast_stdout="${contract_fast_run[2]}"
contract_fast_capture="${contract_fast_run[3]}"
[ "$contract_fast_status" -eq 0 ]
jq -e '
  .final_verdict == "pass" and
  .command_results.targeted_tests.status == "passed" and
  (.commands_run.targeted_tests.command | contains("--match-contract"))
' "$contract_fast_record" >/dev/null
grep -Fqx "test --list --match-path test/polend/POLSplitter.t.sol" "$contract_fast_capture/forge_calls"
grep -Fqx "test --list --match-path test/polend/POLend.t.sol" "$contract_fast_capture/forge_calls"
grep -Eq '^test --match-contract ' "$contract_fast_capture/forge_calls"
if grep -Eq '^test --match-path ' "$contract_fast_capture/forge_calls"; then
    echo "fast targeted tests should execute through --match-contract when validation succeeds" >&2
    exit 1
fi

echo "orchestration tests passed"
