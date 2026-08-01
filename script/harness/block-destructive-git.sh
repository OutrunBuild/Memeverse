#!/usr/bin/env bash
# PreToolUse:Bash hard-block hook (NOT a reminder). It denies destructive git
# invocations issued directly by the agent through the top-level Bash tool, and
# lets safe/read-only forms pass. One unified guard for the whole family of
# commands that can discard uncommitted work-tree content:
#
#   git stash   push / pop / apply / drop / clear / save / branch / store
#   git checkout -- <path> | <commit> -- <path> | -p / --patch
#   git restore [<path>]            (any form except -h / --help)
#   git reset   --hard / --keep / --merge
#   git clean   -f / -d / -x / -X / --force
#   git rm      <path> (except --cached / -n / --dry-run)
#   git switch  -C / --force-create
#
# This is the single source of truth, replacing the earlier split pair
# block-destructive-git-stash.sh + block-destructive-git-checkout.sh.
#
# This does NOT affect the same commands run by harness subprocesses (e.g.
# review-package.sh): those run as children of the harness scripts and never
# traverse this hook, so non-destructive `git stash create` operations keep working.
set -euo pipefail

# Emit a jq-independent hard block when the hook cannot safely inspect input.
fail_closed() {
  printf '%s\n' '{"continue":false,"stopReason":"[harness] destructive-git guard failed closed"}'
  printf '%s\n' '[harness] destructive-git guard failed closed: unable to inspect command safely' >&2
  exit 2
}

# Emit a hard block: {continue:false} on stdout (Claude Code / ZCode block
# contract), the human reason on stderr, then exit 2 (ZCode deny contract;
# also the code-2 path Claude Code falls back to via stderr).
emit_block() {
  local segment="$1"
  local reason
  reason="[harness] 禁止直接执行破坏性 git 命令(${segment})。它们会丢弃工作树未暂存改动（无法通过 reflog 找回）。被禁:\`git stash\`/\`push\`/\`pop\`/\`apply\`/\`drop\`/\`clear\`/\`save\`/\`branch\`/\`store\`(改写工作树或 stash 栈)、\`git checkout -- <path>\`/\`git checkout <commit> -- <path>\`(用 index/历史覆盖工作区文件)、\`git checkout -p\`/\`--patch\`(交互式选择丢弃)、\`git restore\`(设计目的即覆盖工作区文件)、\`git reset --hard\`/\`--keep\`/\`--merge\`(强制重置工作区+index)、\`git clean -fd\`/\`-x\`/\`-d\`(删除未跟踪文件)、\`git rm <path>\`(删工作区文件,除 \`--cached\`/\`-n\`)、\`git switch -C\`/\`--force-create\`(强制重建分支丢 commits)。放行只读/安全形式:\`git stash list\`/\`show\`/\`create\`(create 不动工作区与 stash 栈,仅输出 commit hash)、\`git checkout <branch>\`/\`-b\`/\`-B\`/\`<tag>\`/\`<commit>\`(切分支/分离 HEAD)、\`git reset --soft\`/\`--mixed\`/裸 \`git reset\`(不动工作区)、\`git clean -n\`(dry-run)/\`-h\`、\`git rm --cached\`/\`-n\`(不删工作区文件)、\`git switch <branch>\`/\`-c\`(切/建分支不丢 commits)。注:\`git checkout <path>\`(无 \`--\`)因与分支名歧义被保守放行。harness 内部脚本若需这些操作应在子进程执行(不经此 hook)。"
  jq -n --arg stopReason "$reason" '{continue: false, stopReason: $stopReason}' || fail_closed
  printf '%s\n' "$reason" >&2
  exit 2
}

# Split $1 (a command's argument tail) into an array named $2, one token per
# whitespace-delimited word. Uses `read -ra` so flag clusters like `-fd` stay
# intact and there is no pathname globbing. `read` returns the line even when
# it lacks a trailing newline (unlike the `tr ... | while read` idiom, which
# silently drops a final newlineless token), so bare forms such as
# `git reset --hard` (tail = `--hard`) tokenize correctly.
tokenize() {
  local _in="$1" _out="$2"
  local _arr=()
  read -ra _arr <<<"$_in"
  # shellcheck disable=SC2229  # intentional: caller names the target array
  printf -v "$_out" '%s' ""
  eval "$_out=(\"\${_arr[@]}\")"
}

# 1. Read the PreToolUse payload from stdin.
hook_json=$(cat) || fail_closed

# 2. Extract the command string. Try both key spellings: ZCode uses
#    .tool_input.command, Claude Code may use .toolInput.command.
command_str=$(jq -r '(.tool_input.command // .toolInput.command // null) | if type == "string" then . else error("command must be a string") end' <<<"$hook_json" 2>/dev/null) || fail_closed
[[ -n "$command_str" ]] || fail_closed

# 3. Split compound commands on shell operators so a destructive command
#    cannot hide behind `echo hi && git reset --hard`. This is best-effort
#    segmentation: it does NOT parse shell quoting, so an operator inside a
#    quoted argument is not split. That is an extreme bypass accepted as
#    residual risk; the common chaining cases (&&, ||, ;, |, newline) are
#    covered. Order matters: strip two-char operators (&&, ||) before the
#    single-char | so || is not split into two stray pipes.
segments=$(printf '%s' "$command_str" \
  | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g') || fail_closed

while IFS= read -r raw_seg; do
  # Trim leading/trailing whitespace (POSIX parameter-expansion idiom).
  lead="${raw_seg%%[![:space:]]*}"
  seg="${raw_seg#"$lead"}"
  trail="${seg##*[![:space:]]}"
  seg="${seg%"$trail"}"
  [[ -n "$seg" ]] || continue

  # 4. Peel optional command prefixes (sudo; rtk token-optimized CLI proxy).
  while [[ "$seg" == "sudo "* || "$seg" == "rtk "* ]]; do
    case "$seg" in
      "sudo "*) seg="${seg#sudo }" ;;
      "rtk "*)  seg="${seg#rtk }"  ;;
    esac
    lead="${seg%%[![:space:]]*}"; seg="${seg#"$lead"}"
  done

  # 5. Tokenize the whole segment on IFS (spaces/tabs/newlines) so that
  #    multi-space / tab separators between `git` and its subcommand cannot
  #    bypass the prefix match. `read -ra` collapses runs of IFS whitespace,
  #    which a literal `[[ "$seg" == "git stash "* ]]` does not. This is the
  #    P0 fix: `git<tab>stash` and `git  stash` (double space) used to slip
  #    through because the single-space prefix did not match.
  toks=(); tokenize "$seg" toks

  # Support the dashed alias form `git-stash`/`git-checkout`/... which git
  # treats as equivalent to `git stash`/`git checkout`/.... In that form toks[0]
  # is `git-<subcommand>` itself; normalize it so the family checks below see
  # `git` + subcommand just like the spaced form. Only the families this hook
  # guards are normalized; any other `git-<x>` falls through to the plain `git`
  # check below.
  case "${toks[0]:-}" in
    git-stash|git-checkout|git-restore|git-reset|git-clean|git-rm|git-switch)
      sub="${toks[0]#git-}"        # subcommand name (stash/checkout/...)
      toks[0]="git"                # normalize: pretend the user wrote `git <sub>`
      # Insert the subcommand as toks[1] so the positional logic below (which
      # expects toks[0]=git, toks[1..]=options/subcommand) works unchanged.
      toks=("${toks[0]}" "$sub" "${toks[@]:1}")
      ;;
  esac

  # Not a git invocation at all -> nothing for this hook to check.
  [[ "${toks[0]:-}" == "git" ]] || continue

  # 6. Walk past the leading `git` and any global git options (-C <dir>,
  #    -c <key=val>, --git-dir=, --work-tree=, --no-pager, -P, --namespace=,
  #    etc.) that git accepts between `git` and the subcommand. These options
  #    are themselves non-destructive, but skipping them is what lets us still
  #    catch `git -C /tmp stash` (the -C points stash at another repo but the
  #    stash subcommand is still destructive). This is the P2 fix.
  #    A global option that takes a value in the NEXT token (-C <dir>, -c <kv>,
  #    -e, --exec) consumes that next token so it is not mistaken for the
  #    subcommand. -C/-c/--exec/--namespace each take one following arg.
  i=1
  while [ "$i" -lt "${#toks[@]}" ]; do
    t="${toks[$i]}"
    case "$t" in
      -C|-c|-e|--exec|--namespace) i=$((i+2)) ;;  # option + its value arg
      --exec=*|--namespace=*)      i=$((i+1)) ;;  # value glued with =
      -*)                          i=$((i+1)) ;;  # any other flag (--no-pager, -P, -p pagination, --bare, ...)
      *)                           break ;;        # first non-option token = subcommand
    esac
  done
  sub="${toks[$i]:-}"   # the git subcommand token (or empty if none)

  # ---- git stash -----------------------------------------------------------
  # Bare `git stash` == `git stash push`. Block mutating subcommands that
  # rewrite the worktree or the stash ref stack (push / pop / apply / drop /
  # clear / save / branch / store). Read-only / non-destructive subcommands
  # (list / show / create) -> allow:
  #   - list / show: pure read.
  #   - create: builds a stash commit object and prints its hash, but writes no
  #     ref and leaves both the worktree and the stash stack untouched (verified
  #     empirically: working-tree changes remain, `git stash list` stays empty).
  #     The optional <message> arg only labels that commit; it does not land the
  #     object onto the ref stack. Harness scripts use `create` as a
  #     non-destructive primitive.
  if [[ "$sub" == "stash" ]]; then
    # The stash subcommand is the token AFTER `sub` (toks[i] == "stash"); peek
    # at the next token for the actual stash sub-subcommand (push/pop/...).
    stashsub="${toks[$((i+1))]:-}"
    case "$stashsub" in
      ""|push|pop|apply|drop|clear|save|branch|store)
        emit_block "$seg"
        ;;
      list|show|create)
        continue
        ;;
      *)
        # Unknown subcommand: conservative allow. A false-negative here only
        # lets an obscure subcommand through, whereas a false-positive would
        # break legitimate git usage; unknown stash subcommands are mostly
        # read-only or git itself rejects them.
        continue
        ;;
    esac
  fi

  # ---- git checkout --------------------------------------------------------
  # Destructive checkout is detected by a bare `--` separator token anywhere in
  # the args after the subcommand (covers `git checkout -- <path>`,
  # `git checkout -- .`, `git checkout <commit> -- <path>`), or by `-p` /
  # `--patch` (interactive discard). NOTE: `git checkout <path>` WITHOUT `--`
  # is conservatively ALLOWED because it is ambiguous with a branch name of the
  # same spelling; the `--` form is the unambiguous file-overwrite intent.
  if [[ "$sub" == "checkout" ]]; then
    destructive=0
    j=$((i+1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      case "${toks[$j]}" in
        --|-p|--patch) destructive=1; break ;;
      esac
      j=$((j+1))
    done
    [[ "$destructive" -eq 0 ]] || emit_block "$seg"
    continue
  fi

  # ---- git restore ---------------------------------------------------------
  # `git restore` exists only to overwrite worktree (and optionally index)
  # files, so every invocation is destructive except help output (`-h` /
  # `--help`). This covers `git restore <path>`, `git restore --staged`,
  # `git restore --worktree`, `git restore --source=<commit>`, etc.
  if [[ "$sub" == "restore" ]]; then
    case "${toks[$((i+1))]:-}" in
      -h|--help) continue ;;
      *)         emit_block "$seg" ;;
    esac
    continue
  fi

  # ---- git reset -----------------------------------------------------------
  # Block only the modes that rewrite the worktree: --hard / --keep / --merge.
  # --soft / --mixed (the default) / bare `git reset` only move HEAD and/or
  # the index and leave worktree content intact, so they are ALLOWED.
  if [[ "$sub" == "reset" ]]; then
    destructive=0
    j=$((i+1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      case "${toks[$j]}" in
        --hard|--hard=*|--keep|--keep=*|--merge|--merge=*) destructive=1; break ;;
      esac
      j=$((j+1))
    done
    [[ "$destructive" -eq 0 ]] || emit_block "$seg"
    continue
  fi

  # ---- git clean -----------------------------------------------------------
  # Block delete-bearing flags: -f, -d, -x, -X, --force (singly or combined
  # into a short cluster like `-fd`, `-xf`). Allow only non-destructive forms:
  # `-n` (dry-run), `-h`/`--help`, and bare `git clean` (git refuses to delete
  # anything without -f). NOTE: `-n` combined with a delete flag (e.g.
  # `git clean -fdn`) is still BLOCKED, conservatively; run `-n` alone for a
  # dry-run. Long options other than --force are ALLOWED (this is the P1 fix:
  # `--dry-run` used to be mis-blocked because `cluster="${tok#-}"` left a
  # leading `-`, so `-dry-run` matched `*[fdxX]*` via the `d`).
  if [[ "$sub" == "clean" ]]; then
    destructive=0
    j=$((i+1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      tok="${toks[$j]}"
      case "$tok" in
        --force|--force=*) destructive=1; break ;;
        --*)              ;;  # any other long option (e.g. --dry-run) -> safe, skip
        -)
          ;;  # bare dash, not a flag cluster
        -*)
          cluster="${tok#-}"
          if [[ "$cluster" == *[fdxX]* ]]; then destructive=1; break; fi ;;
      esac
      j=$((j+1))
    done
    [[ "$destructive" -eq 0 ]] || emit_block "$seg"
    continue
  fi

  # ---- git rm --------------------------------------------------------------
  # `git rm <path>` removes the file from both the worktree AND the index, so
  # every rm that actually targets the worktree is destructive. The only safe
  # form is `git rm --cached <path>` (unstage only, keep the worktree file) and
  # `--dry-run`/`-n` (preview). Block all rm invocations EXCEPT those carrying
  # --cached (with or without a value) or -n/--dry-run. This covers `git rm`,
  # `git rm -r`, `git rm -f`, `git rm -rf`, etc. A bare `git rm` with no path is
  # also blocked: git itself errors out, but blocking here makes the intent
  # explicit and prevents `git rm -f` from sneaking through a no-path framing.
  if [[ "$sub" == "rm" ]]; then
    safe=0
    j=$((i+1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      case "${toks[$j]}" in
        --cached|--cached=*) safe=1; break ;;  # unstage-only: keep worktree file
        -n|--dry-run)        safe=1; break ;;  # preview only
      esac
      j=$((j+1))
    done
    [[ "$safe" -eq 0 ]] && emit_block "$seg"
    continue
  fi

  # ---- git switch ----------------------------------------------------------
  # `git switch <branch>` / `-c <branch>` (create-and-switch) are safe: they do
  # not discard already-committed content. `git switch -C <branch>` /
  # `--force-create` RESET the target branch to the current HEAD, discarding any
  # commits that branch had -> destructive. Block only the force-create forms.
  if [[ "$sub" == "switch" ]]; then
    destructive=0
    j=$((i+1))
    while [ "$j" -lt "${#toks[@]}" ]; do
      case "${toks[$j]}" in
        -C|--force-create|--force-create=*) destructive=1; break ;;
      esac
      j=$((j+1))
    done
    [[ "$destructive" -eq 0 ]] || emit_block "$seg"
    continue
  fi
done <<<"$segments"

# 7. No destructive segment matched -> allow.
exit 0
