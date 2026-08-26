# Editing Conventions

Read this file before editing any `.sol` file (all scopes), writing tests or mocks, editing `docs/`, or editing a nested `src/AGENTS.md` / `script/AGENTS.md` / `test/AGENTS.md`.

## Beginner-Readable Code (high priority)

- Optimize for code a beginner can read top to bottom.
- Favor beginner-readable names over protocol jargon, abbreviations, or internal shorthand.
- If a specialized term must stay, explain it at first use in a short local comment.
- Add short implementation comments for non-obvious business logic, invariants, or cross-step reasoning. NatSpec alone is not enough.
- Many tiny single-use helpers make code harder to follow because readers must jump around.
- Extract a helper only when it clearly improves readability, naming, reuse, or testability.
- Inline trivial single-use logic unless extraction clearly improves comprehension.
- Solidity style and best practices for each scope are maintained as nested `AGENTS.md` files whose **single source of truth** is the nested file itself: `src/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md`. The per-scope `.claude/rules/*.md` files (`solidity-contracts.md` for `src/`, `solidity-tests.md` for `test/`, `solidity-scripts.md` for `script/`) are **generated from** those nested files — after editing a nested `AGENTS.md`, regenerate them by running `bash script/harness/sync-agent-docs.sh`.

## Doc-Code Citation Convention

- All documents under `docs/` except the `review/` subdirectory must cite code in `File.sol::function` or `File.sol` form (e.g. `MemeverseLaunchImpl.sol::_deployAndInitializeVerseTokens`).
- Do not write code line numbers in these documents (e.g. `MemeverseLaunchImpl.sol:130-131`): line numbers drift as code evolves and distort doc anchors; function names/symbols are the stable anchors.
- New or modified documents must follow this convention; when reviewing these documents, treat violations as minor-level findings.

## Canonical-Home Restraint

- A passage that names a canonical home ("唯一权威/唯一 canonical 见 X") must not restate the rule body: keep it to at most a 2-sentence summary plus a link to the home. The canonical-home index is `docs/spec/README.md` §2.
- A document must not carry a rule paragraph verbatim identical to one whose home is elsewhere; cross-reference the home instead.
- Exceptions: self-contained invariant entries in `docs/spec/invariants.md` (they carry explicit dedup-relationship notes), runbook content in `docs/operations.md` where operations is itself the declared home, and reference-style guardrails (rule citation plus a non-rewrite declaration) in `docs/SECURITY_AND_APPROVALS.md` §4.

## Test Code Rules

- Test contracts must NOT inherit upgradeable production contracts (those using `Initializable`, proxy patterns, or storage-in-heritage layouts). Use interfaces, abstract contracts, or standalone implementations to simulate dependencies.
- Test contracts MAY inherit non-upgradeable production contracts (plain contracts without initializer logic or proxy storage risks).
- Mock contracts go in `test/mocks/`. Do not co-locate with test files.
- Mock contracts reuse interfaces from `src/`. Define test-only interfaces only when src/ interfaces are insufficient.
- **Exception:** Test contracts may inherit an upgradeable `src/` contract only when it is declared `abstract contract` — either to implement its abstract functions for unit testing, or to expose its internal `pure`/`view` functions. Such harnesses must live in `test/mocks/`.
