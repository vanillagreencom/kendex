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


# Callers preserve positional values for this diagnostic catalog.
file_lock_message() {
  local _message_key="$1"
  shift
  case "$_message_key" in
    lock-timeout)
      printf 'file-lock: lock-timeout lock-file=%s wait-s=%s\n' "$lock_file" "${wait_s}"
      printf '%s\n' "Error: could not acquire $lock_file.d after ${wait_s}s. If no orch process is running, remove it: rm -f '$lock_file.d/owner' && rmdir '$lock_file.d'"
      ;;
  esac
}

ORCH_LOCK_MUTEX_DIR=""

orch_release_lock() { # release a mutex this shell took; a no-op under flock
  if [ -n "$ORCH_LOCK_MUTEX_DIR" ]; then
    rm -f -- "${ORCH_LOCK_MUTEX_DIR:?}/owner" 2>/dev/null || true
    rmdir -- "$ORCH_LOCK_MUTEX_DIR" 2>/dev/null || true
  fi
  ORCH_LOCK_MUTEX_DIR=""
}

# Release a mutex this PROCESS took, from a shell that is not the one that took
# it. Bash runs no trap in a command-substitution subshell when a signal reaps
# it — measured on bash 5.2, where the same trap in a `( )` subshell and at the
# top level both run — so a caller that takes this lock inside `$( )` cannot
# clean up after a ceiling. Its top-level shell can, and arms this for the lock
# paths it drives. The owner mark is how it tells its own mutex from a peer's:
# `$$` is the top-level pid in every subshell of this process, and a mutex some
# other process holds is never touched.
orch_release_owned_lock() { # LOCK_FILE...
  local lock
  for lock in "$@"; do
    [ "$(cat -- "$lock.d/owner" 2>/dev/null || :)" = "$$" ] || continue
    rm -f -- "$lock.d/owner" 2>/dev/null || :
    rmdir -- "$lock.d" 2>/dev/null || :
  done
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
  #
  # EXIT alone is not enough. A shell killed by a signal it does not handle
  # runs no EXIT trap, so a caller reaped by a ceiling — the lane-mail-check
  # hook bounds its account read with one — would leave the mutex behind, and
  # every later writer on that file would wait out its whole timeout and fail.
  # These two arm the same release for the signals such a ceiling sends. A
  # caller that arms its own INT or TERM after this call ends that handler in
  # `exit`, which runs the EXIT trap and reaches the release either way.
  trap 'orch_release_lock; exit 130' INT
  trap 'orch_release_lock; exit 143' TERM
  trap orch_release_lock EXIT
  while ! mkdir -- "$lock_file.d" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$limit" ]; then
      file_lock_message lock-timeout "$@" >&2
      return 1
    fi
    sleep 0.1
  done
  ORCH_LOCK_MUTEX_DIR="$lock_file.d"
  # Which process holds it, for the release a signal leaves to another shell of
  # this same process. A mark that cannot be written costs that release, never
  # the lock: every path that runs a trap still releases through EXIT.
  printf '%s\n' "$$" > "$lock_file.d/owner" 2>/dev/null || true
}
