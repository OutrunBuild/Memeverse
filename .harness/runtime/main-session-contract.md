# Main Session Contract

## Read Order

1. `AGENTS.md`
2. `.harness/policy.json`
3. this file
4. `docs/TRACEABILITY.md` when you need control-file or artifact locations
5. `docs/VERIFICATION.md` when you need verification profile or verdict rules
6. `script/harness/gate.sh` when you need enforcement details or emitted evidence
7. `.claude/rules/*.md` — Solidity style/best-practices, auto-loaded by `paths:` scope (`src/` / `test/` / `script/`) when editing `.sol` files; consult directly only for cross-scope reference

## Truth Precedence

1. explicit human instruction
2. `.harness/policy.json`
3. `script/harness/gate.sh` results
4. `AGENTS.md` and this file
5. other repository docs

## Main-Session Rules

- `main-orchestrator` stays in the primary session and is never a project agent file.
- Every repository modification must go through `gate.sh --classify-only --planned-files <path> [<path> ...]` before editing.
- Dispatch and review are selected by policy-derived `orchestration_profile`.
- Derive `change_class`, `surface_sensitivity`, `orchestration_profile`, `harness_writer_roles`, `code_writer_roles`, and `code_review_roles` from policy/gate evidence before delegating.
- For `prod-semantic` work, the main session decides whether spec/docs or other harness-control changes are needed before dispatching `harness_writer_roles`, `code_writer_roles`, or `code_review_roles`.
- For `prod-semantic` changes the gate emits `doc_round_required=true` and fills `harness_writer_roles` with `process-implementer`. When `doc_round_required=true`, the main session MUST run the product-doc round first — grep the entire `docs/` tree (both `docs/spec/` and `docs/` root-level product docs), output a per-item update/no-update verdict, dispatch `process-implementer` for the affected `docs/` files, then dispatch `spec-reviewer` — before any code writer. The gate does not compute `affected_docs`; that semantic judgment stays with the main session.
- If the main session decides spec/docs changes are required, complete that spec/doc writing round first and dispatch `spec-reviewer` immediately after the spec/doc changes are ready, before any code writer is dispatched.
- `spec-reviewer` dispatch is a main-session orchestration hook, not a `gate.sh` output field. For `prod-semantic` work the doc round that precedes it is triggered by the gate's `doc_round_required` signal; `spec-reviewer` itself remains a hook, not a routing field. Separately, `requires_human_confirmation` remains a policy signal for spec/doc paths and does not itself decide reviewer dispatch.
- Main session may directly modify files only for `direct` and `direct-review`.
- Main session must not author `delegated`, `full-review`, or `full-subagent` changes except to integrate approved subagent output.
- Do not dispatch writer or reviewer agents for `direct`.
- Use only project agents under `.claude/agents/` or `.codex/agents/` for delegated work.
- Do not bypass `process-implementer`, `spec-reviewer`, or human confirmation for docs/spec changes.
- Production Solidity semantic changes without structural escalation require a main-session Risk Analysis Record before using `direct-review`; otherwise use `full-review`.
- README.md editorial-only direct changes require a Doc Editorial Attestation; otherwise use `delegated`.
- `direct-review` reviewer roles come from `orchestration_review_roles`, not `full_review_matrix`.
- Dispatch consumes resolved `harness_writer_roles`, `code_writer_roles`, and `code_review_roles`.
- For pre-edit routing, invoke `gate.sh --classify-only` with exact planned-file input through `--planned-files`. Planned Solidity files are conservatively classified as semantic because no diff exists yet.
- Ownership of working-tree content is decided by the session (the model), not by a hook. The session's context records what it and its dispatched subagents read and wrote; a PreToolUse hook cannot access that context and cannot attribute working-tree lines to sessions. The `pre-edit-check.sh` hook is a reminder only (always exits 0); it does not block.
- Before each `Edit`/`MultiEdit`, the session must verify that every part of `old_string` is its own content (authored by the session or its subagents) or committed (`HEAD`) content. Working-tree content the session never produced and that is not in `HEAD` is another session's foreign change and must not be reverted or deleted. See AGENTS.md "Ownership And Concurrent-Write Guard".
- Before dispatching a writer subagent, capture `BASE` = `$(git stash create || git rev-parse HEAD)` (non-destructive: returns a commit object without moving anything; anchors all uncommitted content present at dispatch time).
- After a writer subagent returns, reconcile its self-reported `git diff $BASE` against the working tree by running `bash script/harness/ownership-reconcile.sh "$BASE" --reported-diff <subagent.diff> --files <paths...>`. If the verdict is `foreign-detected`, stop and report to the human — never revert foreign hunks. See AGENTS.md "Ownership Reconciliation (Post-Dispatch)".
- For local current-work verification on tracked or intended-to-commit repository changes, invoke `gate.sh` with exact changed-file input through `--changed-files`. If any Solidity file is involved, provide diff evidence without creating persistent repository files:
  - Prefer `GATE_DIFF_BASE=<git-ref>` when a stable base ref exists.
  - If a patch file is required, create it with `mktemp` outside the repository, pass its path through `CHANGE_CLASSIFIER_DIFF_FILE`, and remove it after `gate.sh` exits.
  - Do not create, commit, or leave behind repository files named after `CHANGE_CLASSIFIER_DIFF_FILE`, `GATE_DIFF_BASE`, or related diff-evidence artifacts.
- Ignored/local scratch artifacts are outside repository readiness. Do not use ignored scratch paths as `gate.sh` changed-file input for a repository PASS/BLOCKED verdict. Verify them with artifact-specific checks, report that result separately, and mark repository gate as not applicable.
- If an ignored/local artifact is intended to become a formal deliverable, first move it into a policy-classified tracked path or update policy so the path is classified; then run the matching gate before claiming repository readiness.
- If changed files imply multiple writer roles, route each touched surface to its configured writer; only stop as blocked when policy or gate evidence emits a hard block.
- Completion claims require fresh output from the selected matching `gate.sh` profile.
- If required verification evidence is missing, keep the final verdict blocked or fail instead of projecting pass.
- If Solidity surface or risk is unclear, inspect the related contracts, imports/inheritance, existing tests, and mapped spec documents before classifying. Do not rely on a separate explorer agent for this step.

## Reviewer Dispatch — Diff Handoff

When dispatching a reviewer, choose the diff handoff by size:

- **Multi-file or large diff** (e.g. prod-semantic changes spanning several contracts): run `script/harness/review-package.sh BASE` and pass the printed file path. The diff content never enters the main session's context; the reviewer reads the file once.
- **Single-file small change, already read by the main session**: the diff snippet may be passed inline to save the reviewer a Read.
- **BASE**: the commit recorded before dispatching the implementer (run `git rev-parse HEAD` at that moment). Never `HEAD~1` — it silently truncates a multi-commit task.

Never paste accumulated prior-round summaries into later dispatches — hand the reviewer its diff as a file path and the current findings list only.

## Handling Reviewer needs_cross_check

A reviewer may set `needs_cross_check: true` on a finding it cannot verify from this diff alone (the requirement depends on unchanged code, other files, or other tasks). This does not block the rest of the review. The main session holds the cross-file and cross-task context the reviewer lacks, so it adjudicates each such item: confirm a real gap and route it back to the owning writer for a fix plus re-review, or close it as a non-issue. Never silently drop a `needs_cross_check` item.

## Handling Reviewer needs_fp_check (security)

security-reviewer uses `needs_fp_check: true` (not `needs_cross_check`) when it suspects an exploitable vulnerability but cannot fully trace the call path to confirm exploitability. The main session routes any such finding to the `fp-check` skill for deep verification before acting on it — the security counterpart to needs_cross_check.
