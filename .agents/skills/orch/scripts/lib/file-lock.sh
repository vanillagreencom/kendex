# shellcheck shell=bash
# One exclusive lock for the orch scripts that serialize writers on a file.
#
# flock(1) is taken where it exists, because the kernel releases it however
# the holder dies. Stock macOS ships none — it is util-linux, which macOS is
# not — and these writers must not run unguarded there: two `workflow-state
# set` calls racing on one state file both read, both write, and the later
# write drops the earlier transition. So a mkdir mutex carries the lock where
# flock is absent; mkdir is atomic on POSIX filesystems, so exactly one
# contender creates the directory.
#
# The two mechanisms do not lock each other out, so this ASSUMES every writer
# of a given file on a host resolves the same one. That is the assumption
# skills/worktree/scripts/worktree-session-guard already makes for its own
# lock, and it holds for the same reason: these files are per-repository and
# per-host, and a host has one PATH resolution of flock.
#
# Sourced, never executed. Bash 3.2-safe, like its callers.

ORCH_LOCK_MUTEX_DIR=""

orch_release_lock() { # release a mutex this shell took; a no-op under flock
  [ -z "$ORCH_LOCK_MUTEX_DIR" ] || rmdir -- "$ORCH_LOCK_MUTEX_DIR" 2>/dev/null || true
  ORCH_LOCK_MUTEX_DIR=""
}

# FD is already open on LOCK_FILE at the caller's redirection, which is what
# flock locks; the mutex arm ignores it and locks the path. Failure to take
# the lock is a non-zero return the caller reports — never an unguarded write.
orch_take_lock() { # FD LOCK_FILE WAIT_SECONDS
  local fd="$1" lock_file="$2" wait_s="$3" tries=0 limit
  if command -v flock >/dev/null 2>&1; then
    flock -w "$wait_s" "$fd"
    return
  fi
  limit=$((wait_s * 10))
  # Armed before the loop, never after it wins: recording the directory before
  # mkdir would let a losing contender rmdir the winner's mutex, and arming
  # after the win leaves a signal in that window holding the lock for good.
  # orch_release_lock is a no-op while ORCH_LOCK_MUTEX_DIR is empty.
  trap orch_release_lock EXIT
  while ! mkdir -- "$lock_file.d" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$limit" ]; then
      echo "Error: could not acquire $lock_file.d after ${wait_s}s. If no orch process is running, remove it: rmdir '$lock_file.d'" >&2
      return 1
    fi
    sleep 0.1
  done
  ORCH_LOCK_MUTEX_DIR="$lock_file.d"
}
