#!/usr/bin/env bash
set -euo pipefail

# Serialize forge build/compile (and any other forge subcommand run through this
# wrapper) so concurrent invocations can't corrupt the incremental build cache or
# burn the 12-15 min via_ir rebuild budget at the same time.
#
# Usage: bash script/harness/forge-serialize.sh <forge args...>
#   e.g. bash script/harness/forge-serialize.sh build
#        bash script/harness/forge-serialize.sh compile --
#        bash script/harness/forge-serialize.sh build --force
#
# Holds an exclusive flock on ${TMPDIR:-/tmp}/memeverse-forge.lock, then execs
# the real forge under that lock. The lock auto-releases when forge exits or is
# killed; the lock file is harmless if left behind.

lock_dir="${TMPDIR:-/tmp}"
lock_file="$lock_dir/memeverse-forge.lock"

command -v forge >/dev/null 2>&1 || {
    echo "forge-serialize: forge not found in PATH" >&2
    exit 127
}

mkdir -p "$lock_dir"
exec 9>"$lock_file"

if ! flock -n 9; then
    echo "forge-serialize: another forge build/compile is running; waiting on lock $lock_file. This is normal serialization, not a hang — the call proceeds once the prior build finishes." >&2
    # Heartbeat every 60s so callers (including background/polling agents and
    # their users) can see the call is still queued, not frozen. Killed once the
    # lock is acquired so it never overlaps forge's own output.
    (
        exec 9>&-  # 心跳子shell 关闭继承的锁fd: 不持锁文件 ofl, 避免其存活时阻止主进程的锁释放
        elapsed=0
        while true; do
            sleep 60
            elapsed=$((elapsed + 60))
            echo "forge-serialize: still waiting on lock, ${elapsed}s elapsed ..." >&2
        done
    ) &
    heartbeat=$!
    flock 9
    kill "$heartbeat" 2>/dev/null || true
    # 不 wait: 心跳子shell 已 exec 9>&- 不持锁fd, 异步退出由 init 回收;
    # wait 反而有持锁期间被 SIGTERM 未生效的子shell 拖住的风险(持锁死锁)
fi

exec forge "$@"
