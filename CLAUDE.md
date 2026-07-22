@AGENTS.md

## Agent vs Skill Dispatch (Claude Code only)

Names under `.claude/agents/` — `spec-reviewer`, `security-reviewer`, `logic-reviewer`, `refinement-reviewer`, `verifier`, `process-implementer`, `solidity-implementer`, etc. — are **agents**. Dispatch them with the Agent tool (`subagent_type`), never with the Skill tool. Calling an agent via the Skill tool fails with `Unknown skill: <name>`.

The Skill tool is only for registered skills (slash commands / plugin skills). If unsure whether a name is an agent or a skill, check `.claude/agents/` first.
