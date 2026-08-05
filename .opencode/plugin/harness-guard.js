import { spawnSync } from "node:child_process"
import { join } from "node:path"

export default async function harnessGuard({ directory }) {
  const script = join(directory, "script/harness/block-destructive-git.sh")

  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const command = output.args?.command
      if (typeof command !== "string" || !command.trim()) return

      const res = spawnSync("bash", [script], {
        input: JSON.stringify({ tool_input: { command } }),
        encoding: "utf8",
        timeout: 120000
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
