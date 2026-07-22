#!/usr/bin/env bash
# Validate the mechanical package, scope, reference, ID, and verdict contract
# for a refinement-reviewer response. This does not prove review depth.
set -euo pipefail

_usage() {
  printf '%s\n' 'usage: validate-refinement-review.sh RESPONSE_JSON REVIEW_PACKAGE CHANGED_FILES_FILE' >&2
}

if [ "$#" -ne 3 ]; then
  _usage
  exit 2
fi

python3 - "$@" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path


class ValidationFailure(Exception):
    pass


def fail(message):
    raise ValidationFailure(message)


def read_bytes(path, label):
    try:
        return Path(path).read_bytes()
    except OSError as error:
        fail(f"cannot read {label} {path}: {error}")


def read_text(path, label):
    try:
        return read_bytes(path, label).decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"{label} {path} is not UTF-8: {error}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"response JSON has duplicate object key: {key}")
        result[key] = value
    return result


def read_json(path):
    try:
        return json.loads(read_text(path, "response JSON"), object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        fail(
            "invalid JSON in response JSON "
            f"{path}: {error.msg} at line {error.lineno}, column {error.colno}"
        )


def canonical_path(value):
    if not isinstance(value, str) or not value or value != value.strip():
        return False
    if value.startswith("/") or "\\" in value or ":" in value:
        return False
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    return all(part and part not in (".", "..") for part in value.split("/"))


def byte_sorted(values):
    return sorted(values, key=lambda value: value.encode("utf-8"))


def path_list(values, label, allow_empty=False):
    if not isinstance(values, list):
        fail(f"{label} must be an array")
    if not values and not allow_empty:
        fail(f"{label} must not be empty")
    for index, value in enumerate(values):
        if not canonical_path(value):
            fail(f"{label}[{index}] is not a canonical repository-relative path: {value!r}")
    if len(set(values)) != len(values):
        fail(f"{label} contains duplicate paths")
    if values != byte_sorted(values):
        fail(f"{label} must be byte-sorted")
    return values


def read_changed_files(path):
    text = read_text(path, "changed-files file")
    if "\r" in text:
        fail("changed-files file must use LF line endings")
    lines = text.splitlines()
    if any(not line for line in lines):
        fail("changed-files file contains an empty path")
    return path_list(lines, "changed_files")


PACKAGE_HEADER = re.compile(rb"\A# Review package\nReview-ID: ([0-9a-f]{64})\n\n")
PACKAGE_PREAMBLE = re.compile(
    r"\ABase: ([0-9a-f]{40}|[0-9a-f]{64})\n"
    r"Head: ([0-9a-f]{40}|[0-9a-f]{64})\n"
    r"Snapshot: ([0-9a-f]{40}|[0-9a-f]{64})\n"
    r"\n## Scope Manifest\n"
    r"Authority: authoritative\n"
    r"(?P<manifest>(?:[^\n]*\n)*)\Z"
)


def parse_package(path):
    package = read_bytes(path, "review package")
    header = PACKAGE_HEADER.match(package)
    if not header:
        fail("review package must begin with the Review-ID header")
    review_id = header.group(1).decode("ascii")
    payload = package[header.end() :]
    if hashlib.sha256(payload).hexdigest() != review_id:
        fail("review package Review-ID does not equal the payload SHA-256")
    try:
        payload_text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"review package payload is not UTF-8: {error}")

    preamble, marker, _diff = payload_text.partition("\n## Diff\n")
    if not marker:
        fail("review package lacks a Diff section")
    match = PACKAGE_PREAMBLE.fullmatch(preamble)
    if not match:
        fail("review package must contain one authoritative Scope Manifest with full Base, Head, and Snapshot IDs")
    manifest = match.group("manifest").splitlines()
    if any(not line for line in manifest):
        fail("review package Scope Manifest contains an empty path")
    return review_id, path_list(manifest, "package Scope Manifest")


def exact_keys(value, expected, label):
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    missing = expected - actual
    extra = actual - expected
    if missing:
        fail(f"{label} is missing fields: {', '.join(sorted(missing))}")
    if extra:
        fail(f"{label} has forbidden fields: {', '.join(sorted(extra))}")


REFERENCE = re.compile(r"^(.+):([1-9][0-9]*)(?:-([1-9][0-9]*))?$")


def reference(value, label, scope=None):
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    match = REFERENCE.fullmatch(value)
    if not match:
        fail(f"{label} must be <path>:<line> or <path>:<start>-<end>: {value!r}")
    path, start_text, end_text = match.groups()
    if not canonical_path(path):
        fail(f"{label} path is not canonical: {path!r}")
    if scope is not None and path not in scope:
        fail(f"{label} path is outside changed_files: {path!r}")
    if end_text is not None and int(end_text) < int(start_text):
        fail(f"{label} range start exceeds end: {value!r}")


def evidence(value, label, scope=None):
    if not isinstance(value, list) or not value:
        fail(f"{label} must be a non-empty reference array")
    for index, item in enumerate(value):
        reference(item, f"{label}[{index}]", scope)


def response_id(value, pattern, label, seen_ids):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        fail(f"{label}.id has invalid format: {value!r}")
    if value in seen_ids:
        fail(f"duplicate response ID: {value}")
    seen_ids.add(value)


def choice(value, allowed, label):
    if not isinstance(value, str) or value not in allowed:
        fail(f"{label} is invalid: {value!r}")
    return value


def nonempty_string(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")


FINDING_KEYS = {
    "id",
    "category",
    "severity",
    "location",
    "title",
    "problem",
    "recommendation",
    "evidence",
    "benefit",
    "behavior_preservation",
    "verification",
    "gas_basis",
}
CANDIDATE_KEYS = {
    "id",
    "category",
    "location",
    "title",
    "hypothesis",
    "required_evidence",
    "evidence",
}
HANDOFF_KEYS = {"id", "type", "location", "reason", "evidence"}
TOP_LEVEL_KEYS = {
    "review_id",
    "reviewed_files",
    "findings",
    "candidates",
    "handoffs",
    "verdict",
    "summary",
}
FINDING_ID = re.compile(r"RR-[0-9]{3}")
CANDIDATE_ID = re.compile(r"RR-C-[0-9]{3}")
HANDOFF_ID = re.compile(r"RR-H-[0-9]{3}")
CATEGORIES = {"simplification", "gas", "combined"}


def validate_findings(items, scope, seen_ids):
    if not isinstance(items, list):
        fail("findings must be an array")
    for index, item in enumerate(items):
        label = f"findings[{index}]"
        exact_keys(item, FINDING_KEYS, label)
        response_id(item["id"], FINDING_ID, label, seen_ids)
        category = choice(item["category"], CATEGORIES, f"{label}.category")
        choice(item["severity"], {"major", "minor", "info"}, f"{label}.severity")
        reference(item["location"], f"{label}.location", scope)
        evidence(item["evidence"], f"{label}.evidence")
        for field in ("title", "problem", "recommendation", "benefit", "behavior_preservation", "verification"):
            nonempty_string(item[field], f"{label}.{field}")
        gas_basis = item["gas_basis"]
        if category == "simplification":
            if gas_basis != "N/A":
                fail(f"{label}.gas_basis must be 'N/A' for a simplification finding")
        elif not isinstance(gas_basis, str) or not re.fullmatch(r"(?:static|measured): \S(?:.*\S)?", gas_basis):
            fail(f"{label}.gas_basis must begin with 'static: ' or 'measured: '")
        elif "benchmark-required" in gas_basis.lower():
            fail(f"{label}.gas_basis must not describe a benchmark-required finding")


def validate_candidates(items, scope, seen_ids):
    if not isinstance(items, list):
        fail("candidates must be an array")
    for index, item in enumerate(items):
        label = f"candidates[{index}]"
        exact_keys(item, CANDIDATE_KEYS, label)
        response_id(item["id"], CANDIDATE_ID, label, seen_ids)
        choice(item["category"], CATEGORIES, f"{label}.category")
        reference(item["location"], f"{label}.location", scope)
        evidence(item["evidence"], f"{label}.evidence")
        for field in ("title", "hypothesis", "required_evidence"):
            nonempty_string(item[field], f"{label}.{field}")


def validate_handoffs(items, scope, seen_ids):
    if not isinstance(items, list):
        fail("handoffs must be an array")
    for index, item in enumerate(items):
        label = f"handoffs[{index}]"
        exact_keys(item, HANDOFF_KEYS, label)
        response_id(item["id"], HANDOFF_ID, label, seen_ids)
        choice(item["type"], {"security", "correctness"}, f"{label}.type")
        reference(item["location"], f"{label}.location", scope)
        evidence(item["evidence"], f"{label}.evidence")
        nonempty_string(item["reason"], f"{label}.reason")


def validate_response(response, review_id, changed_files):
    exact_keys(response, TOP_LEVEL_KEYS, "response")
    if response["review_id"] != review_id:
        fail("response.review_id does not equal the package Review-ID")

    reviewed_files = path_list(response["reviewed_files"], "response.reviewed_files", allow_empty=True)
    scope = set(changed_files)
    if not set(reviewed_files).issubset(scope):
        fail("response.reviewed_files contains a path outside changed_files")

    seen_ids = set()
    validate_findings(response["findings"], scope, seen_ids)
    validate_candidates(response["candidates"], scope, seen_ids)
    validate_handoffs(response["handoffs"], scope, seen_ids)
    nonempty_string(response["summary"], "response.summary")

    verdict = choice(response["verdict"], {"pass", "action-required", "blocked"}, "response.verdict")
    reports_empty = not any((response["findings"], response["candidates"], response["handoffs"]))
    if verdict == "pass":
        if not reports_empty:
            fail("pass requires empty findings, candidates, and handoffs")
        if reviewed_files != changed_files:
            fail("pass requires reviewed_files to exactly equal changed_files")
    elif verdict == "action-required":
        if reports_empty:
            fail("action-required requires a finding, candidate, or handoff")
        if reviewed_files != changed_files:
            fail("action-required requires reviewed_files to exactly equal changed_files")
    elif not reports_empty:
        fail("blocked requires empty findings, candidates, and handoffs")


def main():
    if len(sys.argv) != 4:
        fail("internal argument mismatch")
    response_path, package_path, changed_files_path = sys.argv[1:]
    changed_files = read_changed_files(changed_files_path)
    review_id, manifest = parse_package(package_path)
    if manifest != changed_files:
        fail("package Scope Manifest does not exactly equal changed_files")
    validate_response(read_json(response_path), review_id, changed_files)
    print(f"validated refinement review: {review_id}")


try:
    main()
except ValidationFailure as error:
    print(f"validate-refinement-review: {error}", file=sys.stderr)
    sys.exit(1)
except Exception as error:
    print(f"validate-refinement-review: unexpected validation failure: {error}", file=sys.stderr)
    sys.exit(1)
PY
