#!/usr/bin/env bash
set -euo pipefail

# check-no-dual-initializable.sh — CI guard for the dual Initializable invariant.
#
# Invariant: a single contract MUST NOT inherit both Initializable families:
#   - custom family: src/common/access/Initializable.sol (slot outrun.storage.Initializable)
#   - OZ family: any .../proxy/utils/Initializable.sol resolved from
#     openzeppelin-contracts-upgradeable, including the nested non-upgradeable copy under
#     its lib/ (slot openzeppelin.storage.Initializable)
#
# Mixing would require explicit `override` of initializer/onlyInitializing to compile and could
# then expose two initialize* entries with independent locks, silently allowing double init;
# the ERC-7201 slots differ, so neither family's lock sees the other's initialization.
#
# Mechanism: AST inheritance-closure assertion over forge build-info artifacts. For every
# ContractDefinition under src/, resolve node.linearizedBaseContracts ids against the run's
# sources and assert the transitive closure never contains both family roots. This is complete
# for transitive inheritance (e.g. `contract Z is Memecoin, UUPSUpgradeable`) and needs no
# name allowlist. See src/common/access/Initializable.sol header for the invariant rationale.
#
# Incremental builds leave multiple build-info runs, each covering only the files compiled in
# that run, so each live src path is checked only in the newest run that covers it (per-path
# newest snapshot): a deleted file and an in-file contract rename/deletion both retire older
# runs' ghost ASTs for that path, leaving no stale check surface.
# src/ or lib/ .sol files, remappings.txt, or foundry.toml newer than the newest artifact mean
# the build-info may be stale, so a serialized forge build runs first (fail-closed: missing
# build-info also triggers a build). Zero live src contracts across all runs is a
# CHECKER-ERROR (fail-closed against schema drift or empty artifacts), never a silent pass.
# --self-test exercises the FAIL / CHECKER-ERROR / ghost-filter (deleted-file and
# in-file-rename) paths offline on synthetic fixtures in a temp dir (no forge, no repo mutation).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

run_walker() {
  python3 - "$@" <<'PYEOF'
import json
import os
import sys

CUSTOM_ROOT = "src/common/access/Initializable.sol"


def is_oz_root(path):
    # openzeppelin-contracts-upgradeable's Initializable resolves through two
    # remapping layouts (direct and the nested non-upgradeable lib/ copy); both
    # back the openzeppelin.storage.Initializable ERC-7201 slot, so any
    # proxy/utils/Initializable.sol path other than the custom root is OZ.
    return path.endswith("proxy/utils/Initializable.sol") and path != CUSTOM_ROOT


run_files = sys.argv[1:]  # newest-first, mirroring the producing `ls -t`

# Pass 1: index of the newest run covering each src path. Historical runs keep
# ghost ASTs for contracts later renamed or deleted within a still-existing
# file, so only the newest coverage of each path is authoritative for that file.
first_run = {}
for i, run_file in enumerate(run_files):
    with open(run_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    sources = data.get("output", {}).get("sources", {})
    for path in sources:
        if not (path.startswith("src/") and path.endswith(".sol")):
            continue
        if path not in first_run:
            first_run[path] = i

violations = []
checker_errors = []
checked = 0

for i, run_file in enumerate(run_files):
    with open(run_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    sources = data.get("output", {}).get("sources", {})
    id2path = {}
    for path, src_info in sources.items():
        for node in src_info.get("ast", {}).get("nodes", []):
            id2path[node["id"]] = path
    for path, src_info in sources.items():
        if not (path.startswith("src/") and path.endswith(".sol")):
            continue
        # Per-path newest snapshot: this path's contracts are checked only in
        # the newest run covering it, so an in-file rename/deletion in a newer
        # run retires older ghost ASTs for the same path.
        # Ghost guard: deleting/renaming a source leaves its AST in historical
        # build-info runs (content-hash artifacts are never pruned); assert live
        # sources only. Paths are repo-root-relative; cwd is the repo root.
        if first_run.get(path) != i or not os.path.exists(path):
            continue
        for node in src_info.get("ast", {}).get("nodes", []):
            if node.get("nodeType") != "ContractDefinition":
                continue
            name = node.get("name")
            checked += 1
            closure = []
            unresolved = False
            for base_id in node.get("linearizedBaseContracts", []):
                base_path = id2path.get(base_id)
                if base_path is None:
                    unresolved = True
                else:
                    closure.append(base_path)
            if unresolved:
                checker_errors.append(
                    "%s:%s: unresolved base id in linearizedBaseContracts (incomplete build-info)"
                    % (path, name)
                )
                continue
            custom_root = next((p for p in closure if p == CUSTOM_ROOT), None)
            oz_root = next((p for p in closure if is_oz_root(p)), None)
            if custom_root and oz_root:
                violations.append(
                    "%s:%s inherits custom %s and OZ %s"
                    % (path, name, custom_root, oz_root)
                )
    # per-run data (`data`, `sources`, `id2path`) goes out of scope here; only
    # `checked` and findings accumulate across runs

if violations:
    for v in violations:
        print("[check-no-dual-initializable] FAIL: %s" % v, file=sys.stderr)
    print("[check-no-dual-initializable] invariant violated — single contract must not inherit both Initializable families.", file=sys.stderr)
    print("  See src/common/access/Initializable.sol header", file=sys.stderr)
if checker_errors:
    for e in checker_errors:
        print("[check-no-dual-initializable] CHECKER-ERROR: %s" % e, file=sys.stderr)
if not checked:
    # Fail-closed: an empty iteration surface (schema drift, empty artifacts, or
    # an empty run list) must not masquerade as a verified pass.
    print("[check-no-dual-initializable] CHECKER-ERROR: no live src contracts found in build-info — schema drift or empty artifacts", file=sys.stderr)
if violations or checker_errors or not checked:
    sys.exit(1)
print("[check-no-dual-initializable] ok — no dual Initializable inheritance found in src/")
PYEOF
}

if [[ "${1:-}" == "--self-test" ]]; then
  (
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    fail() {
      echo "[check-no-dual-initializable] self-test FAILED: $*" >&2
      exit 1
    }

    cd "$tmp"
    mkdir -p src/common/access
    : > src/common/access/Initializable.sol
    : > src/Good.sol
    : > src/Evil.sol
    # src/Renamed.sol exists on disk but its newest snapshot (run2) holds only
    # NewName; run0's OldName is an in-file rename ghost that must not fire.
    # src/Deleted.sol stays absent on purpose: run1 below still references it,
    # simulating a deleted source whose ghost AST lingers in an old build-info run.
    : > src/Renamed.sol

    python3 - "$tmp" <<'GENEOF'
import json
import os
import sys

tmp = sys.argv[1]
custom = "src/common/access/Initializable.sol"
oz = "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol"


def node(nid, name, bases):
    return {
        "id": nid,
        "nodeType": "ContractDefinition",
        "name": name,
        "linearizedBaseContracts": bases,
    }


def source(nodes):
    return {"ast": {"nodes": nodes}}


root = node(1, "Initializable", [1])
good = node(2, "Good", [2, 1])
# Deleted: deleted-source ghost whose closure spans both family roots (custom
# + OZ); (b)'s exit 0 depends on the walker's exists() ghost filter — without
# it Deleted gets checked (unresolved OZ base id in run1) and (b) must FAIL.
deleted = node(3, "Deleted", [3, 1, 5])
evil = node(4, "Evil", [4, 1, 5])
oz_root = node(5, "Initializable", [5])
# run0 (oldest) snapshot of src/Renamed.sol: OldName's closure resolves both
# roots inside run0, so run0 alone would report a real violation, not a
# CHECKER-ERROR. run2 (newest) renames the same file's contract to NewName
# (custom-root-only closure); node ids are per-run, so reuse of id 6 is fine.
old_name = node(6, "OldName", [6, 1, 5])
new_name = node(6, "NewName", [6, 1])

fixtures = {
    "run0.json": {"output": {"sources": {
        custom: source([root]),
        oz: source([oz_root]),
        "src/Renamed.sol": source([old_name]),
    }}},
    "run1.json": {"output": {"sources": {
        custom: source([root]),
        "src/Good.sol": source([good]),
        "src/Deleted.sol": source([deleted]),
    }}},
    "run2.json": {"output": {"sources": {
        custom: source([root]),
        "src/Good.sol": source([good]),
        "src/Evil.sol": source([evil]),
        oz: source([oz_root]),
        "src/Renamed.sol": source([new_name]),
    }}},
    "empty.json": {"output": {"sources": {}}},
}
for name, data in fixtures.items():
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        json.dump(data, f)
GENEOF

    # (a) live dual-family contract -> FAIL on stderr, exit 1 (newest-first)
    rc=0
    run_walker "$tmp/run2.json" "$tmp/run1.json" >"$tmp/a.out" 2>"$tmp/a.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(a) dual-inheritance runs: expected exit 1, got $rc"
    grep -qF "FAIL: src/Evil.sol:Evil" "$tmp/a.err" || fail "(a) expected FAIL for src/Evil.sol:Evil on stderr"

    # (b) stale run only -> ghost Deleted filtered, live Good checked, exit 0 ok
    rc=0
    run_walker "$tmp/run1.json" >"$tmp/b.out" 2>"$tmp/b.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(b) ghost-filtered run: expected exit 0, got $rc: $(cat "$tmp/b.err")"
    grep -qF "[check-no-dual-initializable] ok" "$tmp/b.out" || fail "(b) expected ok line on stdout"

    # (c) zero live src contracts -> CHECKER-ERROR on stderr, exit 1
    rc=0
    run_walker "$tmp/empty.json" >"$tmp/c.out" 2>"$tmp/c.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(c) empty run: expected exit 1, got $rc"
    grep -qF "[check-no-dual-initializable] CHECKER-ERROR" "$tmp/c.err" || fail "(c) expected CHECKER-ERROR on stderr"

    # (d) rename ghost: OldName really violated in run0 and src/Renamed.sol is
    # still live on disk, but run2 (newest) covers the path with NewName only —
    # per-path newest snapshot must check run2's contract set, so the FAIL is
    # Evil alone and OldName never surfaces from the oldest run.
    rc=0
    run_walker "$tmp/run2.json" "$tmp/run1.json" "$tmp/run0.json" >"$tmp/d.out" 2>"$tmp/d.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(d) three-run pass: expected exit 1 (Evil), got $rc"
    grep -qF "FAIL: src/Evil.sol:Evil" "$tmp/d.err" || fail "(d) expected FAIL for src/Evil.sol:Evil on stderr"
    if grep -qF "OldName" "$tmp/d.out" "$tmp/d.err"; then
      fail "(d) rename ghost OldName leaked from the oldest run"
    fi
  )
  echo "[check-no-dual-initializable] self-test ok"
  exit 0
fi

newest="$(ls -t out/build-info/*.json 2>/dev/null | head -n 1 || true)"
# Stale inputs: any src/ or lib/ .sol newer than the newest artifact (lib bumps,
# submodule upgrades), or remappings.txt / foundry.toml newer than it — config
# changes can alter import resolution without touching src/ mtimes.
if [[ -z "$newest" ]] \
  || [[ -n "$(find src lib -name '*.sol' -newer "$newest" -print -quit 2>/dev/null)" ]] \
  || { [[ -f remappings.txt ]] && [[ remappings.txt -nt "$newest" ]]; } \
  || { [[ -f foundry.toml ]] && [[ foundry.toml -nt "$newest" ]]; }; then
  echo "[check-no-dual-initializable] build-info missing or stale — running serialized forge build (may queue)"
  if ! bash script/harness/forge-serialize.sh build; then
    echo "[check-no-dual-initializable] CHECKER-ERROR: serialized forge build failed — see wrapper output above (may be an unrelated forge-lint baseline failure)" >&2
    exit 1
  fi
  newest="$(ls -t out/build-info/*.json 2>/dev/null | head -n 1 || true)"
  if [[ -z "$newest" ]]; then
    echo "[check-no-dual-initializable] FAIL: no build-info artifacts found after forge build" >&2
    exit 1
  fi
fi

mapfile -t build_infos < <(ls -t out/build-info/*.json)

rc=0
run_walker ${build_infos[@]+"${build_infos[@]}"} || rc=$?

exit "$rc"
