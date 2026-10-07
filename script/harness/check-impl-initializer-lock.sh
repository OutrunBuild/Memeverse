#!/usr/bin/env bash
set -euo pipefail

# check-impl-initializer-lock.sh — CI guard for the implementation initializer lock invariant.
#
# Background: the repository carries two Initializable families.
#   - custom family: src/common/access/Initializable.sol — its constructor itself
#     disables initializers, so every inheritor is locked the moment it is
#     deployed (structural lock; nothing further to assert here).
#   - OZ family: any .../proxy/utils/Initializable.sol resolved from
#     openzeppelin-contracts-upgradeable, including the nested non-upgradeable
#     copy under its lib/ — that base declares no constructor, so the lock must
#     be set explicitly by an _disableInitializers() call in some constructor on
#     the inheritance chain.
#
# Invariant: every deployable src/ contract (AST ContractDefinition with
# contractKind "contract" and abstract false) whose linearizedBaseContracts
# closure contains the OZ Initializable root, and where any contract in that
# closure declares an external/public initialize entrypoint (a function named
# initialize, or a function of any name carrying an OZ initializer guard
# modifier: initializer / reinitializer), must have at least one constructor
# in the closure whose AST subtree calls
# _disableInitializers; otherwise the deployed implementation is itself an
# unlocked initialize target. Contracts whose closure contains the custom root
# pass via the structural-lock branch. Interfaces, libraries, and abstract
# contracts are not deployable, so the rule does not apply to them.
#
# Mechanism: AST property-style scan over the full build-info tree with no name
# allowlist exemptions. The lock-call test recursively walks each constructor
# node's subtree for a FunctionCall whose expression is either the bare
# identifier _disableInitializers or a MemberAccess named _disableInitializers
# (super._disableInitializers(), Initializable._disableInitializers()), so
# constructors that also require()/emit still match. Guard-modifier
# entrypoint detection resolves ModifierInvocation.modifierName across its AST
# spellings — IdentifierPath (the production shape, whose name string may be
# qualified, e.g. Initializable.initializer) plus Identifier and MemberAccess
# defensively — to one name compared for exact equality against
# initializer / reinitializer, so lookalikes such as onlyInitializing never
# count as guards.
# Closure member inspection needs base contract NODES, not just paths, so each
# run indexes id→path and id→ContractDefinition over all of that run's sources
# (lib/ included); only src/ paths are themselves enumeration targets.
# Incremental builds leave multiple build-info runs, each covering only the files
# compiled in that run, so each live src path is checked only in the newest run
# that covers it (per-path newest snapshot): a deleted file and an in-file
# contract rename/deletion both retire older runs' ghost ASTs for that path,
# leaving no stale check surface. An unresolvable base id or zero live src
# contracts across all runs is a CHECKER-ERROR (fail-closed against schema drift
# or empty artifacts), never a silent pass. src/ or lib/ .sol files,
# remappings.txt, or foundry.toml newer than the newest artifact mean the
# build-info may be stale, so a serialized forge build runs first (fail-closed:
# missing build-info also triggers a build). --self-test exercises the FAIL /
# CHECKER-ERROR / ghost-filter / unresolved-base paths plus every pass branch
# (multi-statement locking constructor, member-access lock form, structural
# custom-root lock, lock provided by a base contract's constructor,
# abstract/interface/library skips, no-initialize skip, guard-modifier
# entrypoints in the production IdentifierPath spelling including a qualified
# dotted guard name, non-guard-modifier entry functions as a negative control)
# and the multi-run per-path newest snapshot (rename-ghost
# retirement plus older-run coverage) offline on synthetic fixtures in a temp
# dir (no forge, no repo mutation).

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
    # back the same constructor-less base, so any proxy/utils/Initializable.sol
    # path other than the custom root is the OZ family.
    return path.endswith("proxy/utils/Initializable.sol") and path != CUSTOM_ROOT


def is_deployable(node):
    # Only plain non-abstract contracts are deployment targets; interfaces,
    # libraries, and abstract contracts are skipped by the rule.
    return node.get("contractKind") == "contract" and not node.get("abstract", False)


def resolve_modifier_name(invocation):
    # ModifierInvocation.modifierName production shape is an IdentifierPath
    # whose name string carries the full spelling — bare `initializer` or a
    # qualified `Initializable.initializer` — so the segment after the last
    # dot is the guard name, exact-equality compared by the caller
    # (lookalikes such as onlyInitializing never match). Identifier and
    # MemberAccess spellings from other solc layouts stay supported
    # defensively.
    name_node = invocation.get("modifierName")
    if not isinstance(name_node, dict):
        return None
    if name_node.get("nodeType") == "IdentifierPath":
        name = name_node.get("name")
        if isinstance(name, str):
            return name.rsplit(".", 1)[-1]
        return None
    if name_node.get("nodeType") == "Identifier":
        return name_node.get("name")
    if name_node.get("nodeType") == "MemberAccess":
        return name_node.get("memberName")
    return None


def declares_initialize(node):
    # initialize entrypoint: a plain external/public function (kind "function",
    # not the constructor/modifier/fallback/receive variants that also use
    # FunctionDefinition) that either is named initialize or carries an OZ
    # initializer guard modifier (initializer / reinitializer) under any
    # function name.
    for member in node.get("nodes", []):
        if not (
            member.get("nodeType") == "FunctionDefinition"
            and member.get("kind") == "function"
            and member.get("visibility") in ("external", "public")
        ):
            continue
        if member.get("name") == "initialize":
            return True
        for modifier in member.get("modifiers", []):
            if (
                isinstance(modifier, dict)
                and modifier.get("nodeType") == "ModifierInvocation"
                and resolve_modifier_name(modifier) in ("initializer", "reinitializer")
            ):
                return True
    return False


def calls_disable_initializers(node):
    # Recursive subtree walk: any FunctionCall whose expression is either the
    # bare identifier _disableInitializers or a member-access form such as
    # super._disableInitializers() / Initializable._disableInitializers()
    # counts, so multi-statement constructors (require() first, events,
    # reverts) still match.
    if isinstance(node, dict):
        if node.get("nodeType") == "FunctionCall":
            expr = node.get("expression")
            if isinstance(expr, dict) and (
                (
                    expr.get("nodeType") == "Identifier"
                    and expr.get("name") == "_disableInitializers"
                )
                or (
                    expr.get("nodeType") == "MemberAccess"
                    and expr.get("memberName") == "_disableInitializers"
                )
            ):
                return True
        return any(calls_disable_initializers(v) for v in node.values())
    if isinstance(node, list):
        return any(calls_disable_initializers(v) for v in node)
    return False


def has_locking_constructor(node):
    # A constructor is a top-level member of a ContractDefinition; the lock call
    # may sit anywhere inside its body subtree.
    for member in node.get("nodes", []):
        if (
            member.get("nodeType") == "FunctionDefinition"
            and member.get("kind") == "constructor"
            and calls_disable_initializers(member)
        ):
            return True
    return False


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
    # Closure member inspection needs base contract nodes (initialize
    # declarations, constructors), not just paths, so id→node is indexed over
    # all of the run's sources (lib/ included, where the bases live).
    id2path = {}
    id2node = {}
    for path, src_info in sources.items():
        for node in src_info.get("ast", {}).get("nodes", []):
            if node.get("nodeType") != "ContractDefinition":
                continue
            id2path[node["id"]] = path
            id2node[node["id"]] = node
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
            # linearizedBaseContracts[0] is the contract itself, so the closure
            # includes self.
            closure = []
            unresolved = False
            for base_id in node.get("linearizedBaseContracts", []):
                base_node = id2node.get(base_id)
                if base_node is None:
                    unresolved = True
                else:
                    closure.append((id2path[base_id], base_node))
            if unresolved:
                checker_errors.append(
                    "%s:%s: unresolved base id in linearizedBaseContracts (incomplete build-info)"
                    % (path, name)
                )
                continue
            if any(p == CUSTOM_ROOT for p, _ in closure):
                # Structural lock: the custom family's base constructor sets the
                # lock itself, so every inheritor is locked at deployment.
                continue
            if not any(is_oz_root(p) for p, _ in closure):
                continue
            if not is_deployable(node):
                continue
            if not any(declares_initialize(bn) for _, bn in closure):
                # No initialize entrypoint anywhere in the closure: nothing to
                # lock.
                continue
            if any(has_locking_constructor(bn) for _, bn in closure):
                continue
            violations.append(
                "%s:%s exposes an initialize entrypoint under the OZ Initializable family but no constructor in its inheritance closure calls _disableInitializers()"
                % (path, name)
            )
    # per-run data (`data`, `sources`, `id2path`, `id2node`) goes out of scope
    # here; only `checked` and findings accumulate across runs

if violations:
    for v in violations:
        print("[check-impl-initializer-lock] FAIL: %s" % v, file=sys.stderr)
    print("[check-impl-initializer-lock] invariant violated — deployable src/ contracts with an OZ-family initialize entrypoint must call _disableInitializers from a constructor in their inheritance closure.", file=sys.stderr)
    print("  The custom family src/common/access/Initializable.sol locks structurally in its base constructor", file=sys.stderr)
if checker_errors:
    for e in checker_errors:
        print("[check-impl-initializer-lock] CHECKER-ERROR: %s" % e, file=sys.stderr)
if not checked:
    # Fail-closed: an empty iteration surface (schema drift, empty artifacts, or
    # an empty run list) must not masquerade as a verified pass.
    print("[check-impl-initializer-lock] CHECKER-ERROR: no live src contracts found in build-info — schema drift or empty artifacts", file=sys.stderr)
if violations or checker_errors or not checked:
    sys.exit(1)
print("[check-impl-initializer-lock] ok — every deployable src/ initialize entrypoint is constructor-locked or structurally locked via the custom family")
PYEOF
}

if [[ "${1:-}" == "--self-test" ]]; then
  (
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    fail() {
      echo "[check-impl-initializer-lock] self-test FAILED: $*" >&2
      exit 1
    }

    cd "$tmp"
    mkdir -p src/common/access
    : > src/common/access/Initializable.sol
    : > src/Victim.sol
    : > src/Guarded.sol
    : > src/CustomKid.sol
    : > src/Leaf.sol
    : > src/LockedBase.sol
    : > src/Skips.sol
    : > src/NoEntry.sol
    : > src/Renamed.sol
    : > src/OnlyOld.sol
    : > src/Unresolved.sol
    : > src/BadGuard.sol
    : > src/GoodGuard.sol
    : > src/GuardedSuper.sol
    : > src/DottedGuard.sol
    : > src/BenignMod.sol
    # src/Deleted.sol stays absent on purpose: run_e.json below still references
    # it, simulating a deleted source whose ghost AST lingers in a build-info run.

    python3 - "$tmp" <<'GENEOF'
import json
import os
import sys

tmp = sys.argv[1]
custom = "src/common/access/Initializable.sol"
oz = "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol"


def contract(nid, name, bases, kind="contract", abstract=False, members=()):
    return {
        "id": nid,
        "nodeType": "ContractDefinition",
        "name": name,
        "contractKind": kind,
        "abstract": abstract,
        "linearizedBaseContracts": bases,
        "nodes": list(members),
    }


def entrypoint(nid, name="initialize", modifier=None):
    # Optional guard modifier (initializer / reinitializer, or a qualified
    # spelling whose tail resolves to one) makes a function of any name an
    # initialize entrypoint. modifierName uses the production IdentifierPath
    # shape whose name string may be dotted; modifier ids are synthetic
    # offsets (nid + 100) since the walker only indexes contract ids.
    node = {
        "id": nid,
        "nodeType": "FunctionDefinition",
        "kind": "function",
        "name": name,
        "visibility": "external",
        "body": {"statements": []},
    }
    if modifier is not None:
        node["modifiers"] = [{
            "id": nid + 100,
            "nodeType": "ModifierInvocation",
            "modifierName": {"nodeType": "IdentifierPath", "name": modifier},
        }]
    return node


def ctor(nid, lock, require_first=False, member_lock=False):
    statements = []
    if require_first:
        statements.append({
            "nodeType": "ExpressionStatement",
            "expression": {
                "nodeType": "FunctionCall",
                "expression": {"nodeType": "Identifier", "name": "require"},
            },
        })
    if lock:
        if member_lock:
            # super._disableInitializers() shape: MemberAccess callee.
            callee = {
                "nodeType": "MemberAccess",
                "memberName": "_disableInitializers",
                "expression": {"nodeType": "Identifier", "name": "super"},
            }
        else:
            callee = {"nodeType": "Identifier", "name": "_disableInitializers"}
        statements.append({
            "nodeType": "ExpressionStatement",
            "expression": {"nodeType": "FunctionCall", "expression": callee},
        })
    return {
        "id": nid,
        "nodeType": "FunctionDefinition",
        "kind": "constructor",
        "name": "",
        "visibility": "public",
        "body": {"statements": statements},
    }


def source(nodes):
    return {"ast": {"nodes": nodes}}


root = contract(1, "Initializable", [1])
oz_root = contract(5, "Initializable", [5])
# (a) deployable, OZ-family closure, initialize declared, no locking
# constructor anywhere in the closure -> must FAIL.
victim = contract(10, "Victim", [10, 5], members=[entrypoint(11)])
# (b) same shape, but its own constructor requires first and then calls
# _disableInitializers: the recursive subtree walk must survive the extra
# statement.
guarded = contract(12, "Guarded", [12, 5], members=[entrypoint(13), ctor(14, True, require_first=True)])
# (c) custom-family closure: locked structurally by the base constructor, no
# constructor of its own.
custom_kid = contract(15, "CustomKid", [15, 1], members=[entrypoint(16)])
# (d) the lock comes from a base contract's constructor; the leaf itself has no
# constructor (shared locked-base mixin shape).
locked_base = contract(17, "LockedBase", [17, 5], members=[ctor(18, True)])
leaf = contract(19, "Leaf", [19, 17, 5], members=[entrypoint(20)])
# (g) non-deployable shapes: abstract contract, interface, library — each
# declares initialize with no lock and must be skipped.
abstract_kid = contract(21, "AbstractKid", [21, 5], abstract=True, members=[entrypoint(22)])
iface = contract(23, "IFace", [23], kind="interface", members=[entrypoint(24)])
lib = contract(25, "Lib", [25], kind="library", members=[entrypoint(26)])
# (h) deployable under the OZ family but the closure declares no initialize:
# no entrypoint to lock.
no_entry = contract(27, "NoEntry", [27, 5])
# (e) deleted-source ghost: would FAIL if checked; the walker's exists() ghost
# filter must retire it, and live Guarded keeps the run non-empty.
ghost = contract(30, "Ghost", [30, 5], members=[entrypoint(31)])
# (i) multi-run rename ghost: OldGhost really violated in the older run and
# src/Renamed.sol stays live, but the newer run covers the same path with the
# locked CleanKid — the per-path newest snapshot must retire OldGhost. OnlyOld
# is covered by the older run alone and must still FAIL through the multi-run
# call, proving paths beyond the newest run's file set stay checked.
old_ghost = contract(40, "OldGhost", [40, 5], members=[entrypoint(41)])
clean_kid = contract(42, "CleanKid", [42, 5], members=[entrypoint(43), ctor(44, True)])
only_old = contract(45, "OnlyOld", [45, 5], members=[entrypoint(46)])
# (j) base id 999 appears in no source of the run -> fail-closed CHECKER-ERROR.
unresolved = contract(47, "Unresolved", [47, 999], members=[entrypoint(48)])
# (k) guard-modifier entrypoint: an external/public setUp guarded by the OZ
# initializer modifier is an initialize surface whatever its name — unlocked
# must FAIL, locked must pass.
bad_guard = contract(50, "BadGuard", [50, 5], members=[entrypoint(51, name="setUp", modifier="initializer")])
good_guard = contract(53, "GoodGuard", [53, 5], members=[entrypoint(54, name="setUp", modifier="initializer"), ctor(55, True)])
# (l) member-access lock form: super._disableInitializers() must satisfy the
# lock requirement.
guarded_super = contract(57, "GuardedSuper", [57, 5], members=[entrypoint(58), ctor(59, True, member_lock=True)])
# (m) qualified guard name: the production IdentifierPath spelling carries the
# full dotted name Initializable.initializer; its tail segment must resolve to
# the guard, so the unlocked contract must FAIL.
dotted_guard = contract(60, "DottedGuard", [60, 5], members=[entrypoint(61, name="setUp", modifier="Initializable.initializer")])
# (n) non-guard modifiers: onlyInitializing is an OZ-family lookalike and
# onlyOwner an unrelated guard; neither makes an initialize entrypoint, so
# this unlocked closure must stay ok.
benign_mod = contract(62, "BenignMod", [62, 5], members=[
    entrypoint(63, name="configure", modifier="onlyInitializing"),
    entrypoint(64, name="transferOwnership", modifier="onlyOwner"),
])

fixtures = {
    "run_a.json": {"output": {"sources": {
        custom: source([root]),
        oz: source([oz_root]),
        "src/Victim.sol": source([victim]),
    }}},
    "run_b.json": {"output": {"sources": {
        custom: source([root]),
        oz: source([oz_root]),
        "src/Guarded.sol": source([guarded]),
    }}},
    "run_c.json": {"output": {"sources": {
        custom: source([root]),
        "src/CustomKid.sol": source([custom_kid]),
    }}},
    "run_d.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/LockedBase.sol": source([locked_base]),
        "src/Leaf.sol": source([leaf]),
    }}},
    "run_e.json": {"output": {"sources": {
        custom: source([root]),
        oz: source([oz_root]),
        "src/Guarded.sol": source([guarded]),
        "src/Deleted.sol": source([ghost]),
    }}},
    "run_g.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/Skips.sol": source([abstract_kid, iface, lib]),
    }}},
    "run_h.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/NoEntry.sol": source([no_entry]),
    }}},
    "run_i_old.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/Renamed.sol": source([old_ghost]),
    }}},
    "run_i_new.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/Renamed.sol": source([clean_kid]),
    }}},
    "run_i2_old.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/OnlyOld.sol": source([only_old]),
    }}},
    "run_i2_new.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/Renamed.sol": source([clean_kid]),
    }}},
    "run_j.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/Unresolved.sol": source([unresolved]),
    }}},
    "run_k_bad.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/BadGuard.sol": source([bad_guard]),
    }}},
    "run_k_good.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/GoodGuard.sol": source([good_guard]),
    }}},
    "run_l.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/GuardedSuper.sol": source([guarded_super]),
    }}},
    "run_m.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/DottedGuard.sol": source([dotted_guard]),
    }}},
    "run_n.json": {"output": {"sources": {
        oz: source([oz_root]),
        "src/BenignMod.sol": source([benign_mod]),
    }}},
    "empty.json": {"output": {"sources": {}}},
}
for name, data in fixtures.items():
    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
        json.dump(data, f)
GENEOF

    # (a) deployable OZ-family initialize with no lock -> FAIL on stderr, exit 1
    rc=0
    run_walker "$tmp/run_a.json" >"$tmp/a.out" 2>"$tmp/a.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(a) unlocked implementation: expected exit 1, got $rc"
    grep -qF "FAIL: src/Victim.sol:Victim" "$tmp/a.err" || fail "(a) expected FAIL for src/Victim.sol:Victim on stderr"

    # (b) multi-statement locking constructor (require + _disableInitializers) -> ok
    rc=0
    run_walker "$tmp/run_b.json" >"$tmp/b.out" 2>"$tmp/b.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(b) guarded implementation: expected exit 0, got $rc: $(cat "$tmp/b.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/b.out" || fail "(b) expected ok line on stdout"

    # (c) custom-family closure -> structural lock, ok
    rc=0
    run_walker "$tmp/run_c.json" >"$tmp/c.out" 2>"$tmp/c.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(c) custom-family closure: expected exit 0, got $rc: $(cat "$tmp/c.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/c.out" || fail "(c) expected ok line on stdout"

    # (d) lock provided by a base contract's constructor (leaf has none) -> ok
    rc=0
    run_walker "$tmp/run_d.json" >"$tmp/d.out" 2>"$tmp/d.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(d) locked base: expected exit 0, got $rc: $(cat "$tmp/d.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/d.out" || fail "(d) expected ok line on stdout"

    # (e) deleted-source ghost filtered by exists(); live Guarded keeps the run
    # non-empty -> ok, and Ghost never surfaces.
    rc=0
    run_walker "$tmp/run_e.json" >"$tmp/e.out" 2>"$tmp/e.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(e) ghost-filtered run: expected exit 0, got $rc: $(cat "$tmp/e.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/e.out" || fail "(e) expected ok line on stdout"
    if grep -qF "Ghost" "$tmp/e.out" "$tmp/e.err"; then
      fail "(e) deleted-source ghost Ghost leaked into results"
    fi

    # (f) zero live src contracts -> CHECKER-ERROR on stderr, exit 1
    rc=0
    run_walker "$tmp/empty.json" >"$tmp/f.out" 2>"$tmp/f.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(f) empty run: expected exit 1, got $rc"
    grep -qF "[check-impl-initializer-lock] CHECKER-ERROR" "$tmp/f.err" || fail "(f) expected CHECKER-ERROR on stderr"

    # (g) abstract contract / interface / library violators -> not deployable, ok
    rc=0
    run_walker "$tmp/run_g.json" >"$tmp/g.out" 2>"$tmp/g.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(g) non-deployable skips: expected exit 0, got $rc: $(cat "$tmp/g.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/g.out" || fail "(g) expected ok line on stdout"

    # (h) OZ-family closure without any initialize declaration -> nothing to lock, ok
    rc=0
    run_walker "$tmp/run_h.json" >"$tmp/h.out" 2>"$tmp/h.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(h) no-entrypoint skip: expected exit 0, got $rc: $(cat "$tmp/h.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/h.out" || fail "(h) expected ok line on stdout"

    # (i) multi-run rename ghost: OldGhost really violated in the older run but
    # the newer run covers the same live path with the locked CleanKid -> ok,
    # and OldGhost never surfaces from the older run.
    rc=0
    run_walker "$tmp/run_i_new.json" "$tmp/run_i_old.json" >"$tmp/i.out" 2>"$tmp/i.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(i) rename-ghost retirement: expected exit 0, got $rc: $(cat "$tmp/i.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/i.out" || fail "(i) expected ok line on stdout"
    if grep -qF "OldGhost" "$tmp/i.out" "$tmp/i.err"; then
      fail "(i) rename ghost OldGhost leaked from the older run"
    fi

    # (i, reverse) a violator covered only by the older run still FAILs through
    # the multi-run call: the newest snapshot keeps checking paths beyond the
    # newest run's file set.
    rc=0
    run_walker "$tmp/run_i2_new.json" "$tmp/run_i2_old.json" >"$tmp/i2.out" 2>"$tmp/i2.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(i) older-run coverage: expected exit 1, got $rc"
    grep -qF "FAIL: src/OnlyOld.sol:OnlyOld" "$tmp/i2.err" || fail "(i) expected FAIL for src/OnlyOld.sol:OnlyOld on stderr"

    # (j) base id missing from every source of the run -> CHECKER-ERROR, exit 1
    rc=0
    run_walker "$tmp/run_j.json" >"$tmp/j.out" 2>"$tmp/j.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(j) unresolved base: expected exit 1, got $rc"
    grep -qF "[check-impl-initializer-lock] CHECKER-ERROR" "$tmp/j.err" || fail "(j) expected CHECKER-ERROR on stderr"
    grep -qF "src/Unresolved.sol:Unresolved" "$tmp/j.err" || fail "(j) expected unresolved-base detail on stderr"

    # (k) guard-modifier entrypoint named setUp: no lock -> FAIL; with a locking
    # constructor -> ok.
    rc=0
    run_walker "$tmp/run_k_bad.json" >"$tmp/k_bad.out" 2>"$tmp/k_bad.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(k) unlocked guard-modifier entrypoint: expected exit 1, got $rc"
    grep -qF "FAIL: src/BadGuard.sol:BadGuard" "$tmp/k_bad.err" || fail "(k) expected FAIL for src/BadGuard.sol:BadGuard on stderr"

    rc=0
    run_walker "$tmp/run_k_good.json" >"$tmp/k_good.out" 2>"$tmp/k_good.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(k) locked guard-modifier entrypoint: expected exit 0, got $rc: $(cat "$tmp/k_good.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/k_good.out" || fail "(k) expected ok line on stdout"

    # (l) member-access lock call super._disableInitializers() -> ok
    rc=0
    run_walker "$tmp/run_l.json" >"$tmp/l.out" 2>"$tmp/l.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(l) member-access lock: expected exit 0, got $rc: $(cat "$tmp/l.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/l.out" || fail "(l) expected ok line on stdout"

    # (m) qualified guard name Initializable.initializer in the production
    # IdentifierPath spelling: the tail segment resolves to the guard, no lock
    # -> FAIL.
    rc=0
    run_walker "$tmp/run_m.json" >"$tmp/m.out" 2>"$tmp/m.err" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "(m) dotted guard name: expected exit 1, got $rc"
    grep -qF "FAIL: src/DottedGuard.sol:DottedGuard" "$tmp/m.err" || fail "(m) expected FAIL for src/DottedGuard.sol:DottedGuard on stderr"

    # (n) non-guard modifiers (onlyInitializing lookalike, onlyOwner) on
    # external entry functions do not create an initialize entrypoint: the
    # unlocked closure stays ok.
    rc=0
    run_walker "$tmp/run_n.json" >"$tmp/n.out" 2>"$tmp/n.err" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "(n) non-guard modifier control: expected exit 0, got $rc: $(cat "$tmp/n.err")"
    grep -qF "[check-impl-initializer-lock] ok" "$tmp/n.out" || fail "(n) expected ok line on stdout"
  )
  echo "[check-impl-initializer-lock] self-test ok"
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
  echo "[check-impl-initializer-lock] build-info missing or stale — running serialized forge build (may queue)"
  if ! bash script/harness/forge-serialize.sh build; then
    echo "[check-impl-initializer-lock] CHECKER-ERROR: serialized forge build failed — see wrapper output above (may be an unrelated forge-lint baseline failure)" >&2
    exit 1
  fi
  newest="$(ls -t out/build-info/*.json 2>/dev/null | head -n 1 || true)"
  if [[ -z "$newest" ]]; then
    echo "[check-impl-initializer-lock] FAIL: no build-info artifacts found after forge build" >&2
    exit 1
  fi
fi

mapfile -t build_infos < <(ls -t out/build-info/*.json)

rc=0
run_walker ${build_infos[@]+"${build_infos[@]}"} || rc=$?

exit "$rc"
