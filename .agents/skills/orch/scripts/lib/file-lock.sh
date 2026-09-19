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
      printf '%s\n' "Error: could not acquire $lock_file.d after ${wait_s}s. If no orch process is running, remove it: rmdir '$lock_file.d'"
      ;;
  esac
}

ORCH_LOCK_MUTEX_DIR=""

orch_release_lock() { # release a mutex this shell took; a no-op under flock
  [ -z "$ORCH_LOCK_MUTEX_DIR" ] || rmdir -- "$ORCH_LOCK_MUTEX_DIR" 2>/dev/null || true
  ORCH_LOCK_MUTEX_DIR=""
}

# The disposition a held mutex must never leave: the release, then an exit
# status naming the signal, which runs the EXIT trap too. It lives here because
# `trap -` restores the DEFAULT disposition and not this one, so a caller that
# replaces these handlers for a window of its own has no way back except to say
# what they were. Saying it a second time at that caller is how the two
# spellings drift apart.
orch_arm_lock_signals() {
  trap 'orch_release_lock; exit 130' INT
  trap 'orch_release_lock; exit 143' TERM
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
  # EXIT and the two signals a ceiling sends, because this lock is taken inside
  # a command substitution as well as at a top level: `lanes` renews a token
  # there, and the lane-mail-check hook bounds that call at 20 seconds. Bash
  # runs both the handler armed here and the EXIT trap below in such a subshell
  # when the ceiling's signal reaps it, and the handler ends in `exit` so the
  # release is the same one on either path rather than resting on bash's own
  # handling of an untrapped signal. A caller that arms its own INT or TERM
  # after this call ends that handler in `exit`, which runs the EXIT trap and
  # reaches the release either way, and puts these back with
  # `orch_arm_lock_signals` rather than clearing them with `trap -`: the
  # default disposition kills the shell with no trap at all, the EXIT trap
  # included, and the mutex outlives it.
  orch_arm_lock_signals
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
}
