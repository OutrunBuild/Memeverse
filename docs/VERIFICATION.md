# MemeverseV2 Verification

- Verification entrypoint: `script/harness/gate.sh`
- Pre-edit classification entrypoint: `bash script/harness/gate.sh --classify-only --planned-files <path> [<path> ...]`
- Changed-file classification or verification entrypoint: `bash script/harness/gate.sh --changed-files <path> [<path> ...]`
- Default local profile: `npm run gate` (`fast`)
- Fast local profile: `npm run gate:fast`
- Full local profile: `npm run gate:full`
- CI profile: `npm run gate:ci`
- CI entrypoint wrapper: `bash script/harness/ci-gate-entrypoint.sh`

`fast` is the default local verdict for current work. Use `full`, `ci`, release, or merge-equivalent verification only when explicitly requested or running in that context.

Gate output controls:

- `--quiet`: suppresses successful `pass`, `no-op`, or `classified` text stdout. Failures and blocked verdicts still print an error summary.
- `--log-level error|warn|info|debug`: defaults to `info`. `error` prints only error-oriented output, `warn` prints warnings/errors without success summaries, and `debug` includes the structured gate record in text mode.
- `--output text|json`: defaults to JSON for `--classify-only` and text for normal verification. `json` prints the structured classification or final record to stdout and takes precedence over `--quiet`.

`--planned-files` accepts one or more repo-relative paths and can only be used with `--classify-only`. Use it before edits to classify the intended file set for routing. Planned Solidity files do not require diff evidence and are conservatively classified as semantic.

Ownership of working-tree content is decided by the session (the model), not by a hook: the session's context records what it and its dispatched subagents read and wrote, and a PreToolUse hook cannot access that context. `script/harness/pre-edit-check.sh` is a reminder only — it emits a strict-JSON `additionalContext` notice on stdout and always exits 0; it never blocks. Before each `Edit`/`MultiEdit`, the session must verify that every part of `old_string` is its own content (authored by the session or its subagents) or committed (`HEAD`) content; working-tree content the session never produced and that is not in `HEAD` is another session's foreign change and must not be reverted. See AGENTS.md "Ownership And Concurrent-Write Guard".

`--changed-files` accepts one or more repo-relative paths. Use it after edits or in CI for real changed-file verification. Every positional argument after `--changed-files` is treated as a changed file until the next option.

Local current-work verification must use exact changed-file input. Solidity changed-files mode requires diff evidence via `CHANGE_CLASSIFIER_DIFF_FILE` or `GATE_DIFF_BASE`; without it, semantic classification is blocked.

Gate verifies classification and command outcomes. For `prod-semantic` changes the gate emits `doc_round_required` to trigger the main session's product-doc round (grep `docs/` + per-doc update/no-update + dispatch doc writers and `spec-reviewer` before code writers), but the specific `affected_docs` set is still decided by the main session's `docs/` grep, not computed by the gate.

For `fast` verification, `targeted_tests` starts from the exact file set selected by `test_mapping`. The gate builds a regex from `forge test --list --match-path <file>` results and runs one `forge test --match-contract <regex>` command only when `forge test --list --match-contract <regex>` resolves to the same test-contract set. If extraction or validation fails, the gate runs `forge test --match-path <file>` for each selected file.

CI runs the full gate over every surface file regardless of the diff: `script/harness/ci-gate-entrypoint.sh` invokes `gate:ci -- --all` on every push, PR, and `workflow_dispatch`. This is the full backstop for the local `gate:fast` pre-push (which only runs targeted tests): it runs the full test suite (`forge_test_full`), build, coverage, slither, and all fmt/lint/bash/node checks.

Diff evidence must not be created as persistent repository files. Prefer `GATE_DIFF_BASE=<git-ref>`; when `CHANGE_CLASSIFIER_DIFF_FILE` is needed, point it at a `mktemp` file outside the repository and remove it after `gate.sh` exits.

`full` and `ci` command gates:

| Command | Condition |
|---|---|
| `forge coverage` | `change_class=prod-semantic` and `surface_sensitivity=sensitive` |
| `slither` | same as coverage, only when changed production Solidity includes `src/**/*.sol` |

`full-subagent` is an orchestration profile, not a gate profile. It means an independent verifier is required; the verifier runs the selected `fast`, `full`, or `ci` profile.

Completion or pass claims require fresh output from the exact gate profile used for the verdict. Harness-only and docs-only changes still require a fresh gate verdict before claiming completion.
