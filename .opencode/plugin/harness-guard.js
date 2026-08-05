import { spawnSync } from "node:child_process"
import { join } from "node:path"

function unwrap(command) {
  let tokens = command.trim().split(/\s+/)
  while (tokens.length) {
    const head = tokens[0].split("/").pop()
    if (head === "sudo" || head === "env") {
      tokens = tokens.slice(1)
      continue
    }
    break
  }
  return tokens
}

function commandName(tokens) {
  if (!tokens.length) return null
  let name = tokens[0]
  if (name.startsWith("\\")) name = name.slice(1)
  if (name.includes("/")) name = name.split("/").pop()
  return name
}

function gitSubcommand(tokens) {
  if (!tokens.length || !tokens[0].startsWith("git")) return null
  let i = 1
  while (i < tokens.length) {
    const t = tokens[i]
    if (t === "-C" || t === "-c" || t === "-e" || t === "--exec" || t === "--namespace") {
      i += 2
      continue
    }
    if (t.startsWith("-")) {
      i += 1
      continue
    }
    return t
  }
  return null
}

export default async function harnessGuard({ directory }) {
  const script = join(directory, "script/harness/block-destructive-git.sh")

  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const command = output.args?.command
      if (typeof command !== "string" || !command.trim()) return

      const tokens = unwrap(command)
      const name = commandName(tokens)
      if (name === "rm") {
        throw new Error(`[harness] 禁止直接执行 rm: ${command}`)
      }
      if (name === "git-push" || (name === "git" && gitSubcommand(tokens) === "push")) {
        throw new Error(`[harness] 禁止直接执行 git push: ${command}`)
      }

      const res = spawnSync("bash", [script], {
        input: JSON.stringify({ tool_input: { command } }),
        encoding: "utf8",
        timeout: 15000
      })
      if (res.status === 2) {
        const parsed = JSON.parse(res.stdout || "{}")
        throw new Error(parsed.stopReason || "[harness] 破坏性 git 命令被拦截")
      }
    }
  }
}
