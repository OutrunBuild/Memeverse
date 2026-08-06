import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// opencode-side destructive-git guard. Uses the GLOBAL guard installation
// (~/.local/share/destructive-git-guard/) shared with the Claude Code global
// hook, the ZCode global config, and the Pi global extension — the repo no
// longer carries its own copy of the guard.
//
// The global script no-ops outside harness repos (it walks up from $PWD
// looking for .harness/policy.json), so `cwd: directory` keeps the walk
// anchored at the repo root. If the global install is missing (e.g. another
// machine), the plugin degrades to a no-op instead of bricking every bash
// command.
export default async function harnessGuard({ directory }) {
  const script = join(homedir(), ".local/share/destructive-git-guard/block-destructive-git.sh")

  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const command = output.args?.command
      if (typeof command !== "string" || !command.trim()) return
      if (!existsSync(script)) return

      const res = spawnSync("bash", [script], {
        input: JSON.stringify({ tool_input: { command } }),
        encoding: "utf8",
        timeout: 120000,
        cwd: directory
      })
      if (res.error) {
        throw new Error("[harness] destructive-git guard failed closed: " + res.error.message)
      }
      if (res.status !== 0) {
        let reason = "[harness] destructive-git guard failed closed"
        try {
          reason = JSON.parse(res.stdout || "{}").stopReason || reason
        } catch {
          // An invalid response is still a hard block.
        }
        throw new Error(reason)
      }
    }
  }
}
