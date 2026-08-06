/**
 * Claude Rules Loader with path-scoped auto-loading
 * (port of Claude Code's `.claude/rules` `paths:` frontmatter behavior)
 *
 * - Scans the project's `.claude/rules/*.md` and parses each file's `paths:`
 *   frontmatter (e.g. `src/**\/*.sol`), like Claude Code does.
 * - Lists all rules in the system prompt so the agent knows they exist.
 * - On the `context` event (fired before every LLM call) scans the most recent
 *   tool calls for a file path matching a rule's glob, and injects that rule's
 *   content into the messages — the Pi equivalent of Claude Code's
 *   "auto-loads when you edit src/ contracts".
 *
 * Rule files themselves stay in the repo at `.claude/rules/` — a single source
 * of truth shared with Claude Code / Codex. This extension only loads them.
 *
 * Install: copy to <cwd>/.pi/extensions/ (project) — or the project's rules
 * loader. Reload with /reload or restart pi.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface RuleEntry {
	/** Rule file name, e.g. `solidity-contracts.md`. */
	file: string;
	/** `paths:` frontmatter globs, e.g. `["src/**\/*.sol"]`. */
	paths: string[];
	/** Rule file content with frontmatter stripped. */
	content: string;
}

/** Recursively find all .md files in a directory. */
function findMarkdownFiles(dir: string, basePath: string = ""): string[] {
	const results: string[] = [];
	if (!fs.existsSync(dir)) return results;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const relativePath = basePath ? `${basePath}/${entry.name}` : entry.name;
		if (entry.isDirectory()) {
			results.push(...findMarkdownFiles(path.join(dir, entry.name), relativePath));
		} else if (entry.isFile() && entry.name.endsWith(".md")) {
			results.push(relativePath);
		}
	}
	return results;
}

/** Parse the `paths:` list from a rule file's YAML frontmatter. */
function parsePaths(content: string): string[] {
	const fm = content.match(/^---\n([\s\S]*?)\n---/);
	if (!fm) return [];
	const block = fm[1].match(/^paths:\n((?:\s*-\s*.+\n?)+)/m);
	if (!block) return [];
	return block[1]
		.split("\n")
		.map((l) => l.trim().replace(/^-\s*/, "").replace(/^["']|["']$/g, ""))
		.filter(Boolean);
}

/** Strip the frontmatter block from a rule file, keeping the body. */
function stripFrontmatter(content: string): string {
	return content.replace(/^---\n[\s\S]*?\n---\n?/, "");
}

/**
 * Convert a glob to a RegExp. `**` and `*` cross directory boundaries (Claude
 * Code path semantics); `?` matches exactly one non-separator character.
 */
function globToRegExp(glob: string): RegExp {
	let out = "";
	for (let i = 0; i < glob.length; i++) {
		const c = glob[i];
		if (c === "*") {
			if (glob[i + 1] === "*") {
				out += ".*";
				i++;
			} else {
				out += "[^/]*";
			}
		} else if (c === "?") {
			out += "[^/]";
		} else {
			out += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
		}
	}
	return new RegExp(`^${out}$`);
}

export default function claudeRulesExtension(pi: ExtensionAPI) {
	let rules: RuleEntry[] = [];
	/** Rule files already injected this session (one injection per rule). */
	const injected = new Set<string>();

	pi.on("session_start", async (_event, ctx) => {
		try {
			const dir = path.join(ctx.cwd, ".claude", "rules");
			rules = findMarkdownFiles(dir).map((f) => {
				const raw = fs.readFileSync(path.join(dir, f), "utf8");
				return { file: f, paths: parsePaths(raw), content: stripFrontmatter(raw) };
			});
			injected.clear();
			if (rules.length > 0) {
				ctx.ui.notify(`Loaded ${rules.length} rule(s) from .claude/rules/`, "info");
			}
		} catch {
			rules = [];
		}
	});

	// List available rules in the system prompt so the agent can read them on demand.
	pi.on("before_agent_start", async (event) => {
		if (rules.length === 0) return;
		const list = rules
			.map((r) => `- .claude/rules/${r.file}${r.paths.length ? ` (auto-load paths: ${r.paths.join(", ")})` : ""}`)
			.join("\n");
		return {
			systemPrompt:
				event.systemPrompt +
				`

## Project Rules

The following project rules are available in .claude/rules/:

${list}

Rules with path patterns auto-load into context after a tool call touches a matching file. Rules without path patterns are loaded on demand with the read tool.
`,
		};
	});

	// Path-scoped auto-loading: before each LLM call, if the most recent tool
	// call touched a file matching a rule's paths glob, inject that rule.
	pi.on("context", (event, ctx) => {
		if (rules.length === 0) return;

		try {
			// Find the most recent tool call that referenced a file path.
			let lastPath: string | undefined;
			for (const msg of event.messages) {
				if (msg.role !== "assistant") continue;
				for (const content of msg.content) {
					if (content.type !== "toolCall") continue;
					const args = (content.arguments ?? {}) as Record<string, unknown>;
					const p =
						typeof args.path === "string" ? args.path :
						typeof args.filePath === "string" ? args.filePath :
						typeof args.file === "string" ? args.file :
						typeof args.directory === "string" ? args.directory :
						undefined;
					if (p) lastPath = p;
				}
			}
			if (!lastPath) return;

			// Normalize to candidates: raw path + cwd-relative form.
			const candidates = [lastPath];
			if (lastPath.startsWith(ctx.cwd)) {
				candidates.push(lastPath.slice(ctx.cwd.length).replace(/^[/\\]/, ""));
			}

			for (const rule of rules) {
				if (injected.has(rule.file)) continue;
				const match = rule.paths.some((glob) => {
					const re = globToRegExp(glob);
					return candidates.some((c) => re.test(c));
				});
				if (!match) continue;

				injected.add(rule.file);
				const message = {
					role: "user" as const,
					content: `[Auto-loaded project rule: .claude/rules/${rule.file} (matches ${lastPath})]\n\n${rule.content}`,
					timestamp: Date.now(),
				};
				return { messages: [...event.messages, message] };
			}
		} catch {
			// Never break the agent loop on a rules-loader error.
		}
	});
}
