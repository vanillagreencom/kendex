# shellcheck shell=bash
# The per-home bound on concurrent lane-host provider calls.
#
# A provider call is a process of its own, and a real provider is a Python
# program of about 100 MB: a watch pass reading twenty hosted mailboxes, a lane
# launch and a close, all on one control machine, put tens of them in flight at
# once and hold its CPU at the cap. scripts/lane-host is the one place every
# orch caller reaches a provider through, so it takes a slot here before it runs
# the provider and gives it back when it exits; no caller takes one itself.
#
# One slot directory per home, never per repository: every overseer and every
# checkout the user runs on the machine shares the machine, so they share the
# count. $HOME alone names it, because XDG_RUNTIME_DIR is set in a login
# session and absent in a systemd unit or a cron job of the same user, and two
# spellings would be two counts. A slot is a file named for the dispatcher's
# pid; the pids are one user's, so `kill -0` answers for each of them. A slot
# whose process is gone, a dispatcher killed before its EXIT trap ran, is
# reclaimed by the next take. A reused pid holds its slot until that process
# exits.
#
# Sourced, never executed, after lib/file-lock.sh. Bash 3.2-safe, like its
# callers. A caller that only branches on a refusal sources it for
# LANE_HOST_BUSY_EXIT and calls nothing.

# The dispatcher's own exit status for a call refused at the cap, after the
# wait. No provider verb exits with it (schemas/lane-host.md), so a caller
# tells a busy dispatcher from a failed host by the status alone.
LANE_HOST_BUSY_EXIT=69

# The slot file this shell holds, empty when it holds none.
LANE_HOST_SLOT=""

lane_host_slot_message() { # KEY FIELD=VALUE...
  local key="$1"
  shift
  printf 'lane-host: %s' "$key"
  printf ' %s' "$@"
  printf '\n'
  case "$key" in
    lane-host-busy) printf '%s\n' 'Every provider slot on this home stayed taken for ORCH_LANE_HOST_BUSY_WAIT_SECS, so the call did not run. Nothing was read or written; run it again.' ;;
    setting-invalid) printf '%s\n' 'ORCH_LANE_HOST_MAX_CALLS takes a whole number of at least 1 and ORCH_LANE_HOST_BUSY_WAIT_SECS a whole number of seconds, neither with a leading zero.' ;;
    slot-failed) printf '%s\n' 'The slot directory or its lock could not be written, so the call is not admitted rather than run unbounded.' ;;
  esac
}

# Under DIR's lock: reclaim the slots whose process is gone, count the rest into
# LANE_HOST_SLOT_COUNT, and take one for this shell when that count is under
# CAP. 0 taken, 1 at the cap, 2 the lock or a slot write failed.
LANE_HOST_SLOT_COUNT=0
lane_host_slot_try() { # DIR CAP
  local dir="$1" cap="$2" slot count=0 rc=1
  exec 8>>"$dir/.lock" || return 2
  if ! orch_take_lock 8 "$dir/.lock" 10; then
    exec 8>&-
    return 2
  fi
  for slot in "$dir"/slot.*; do
    [ -e "$slot" ] || continue
    if kill -0 "${slot##*/slot.}" 2>/dev/null; then
      count=$((count + 1))
    else
      # A slot that will not go is still counted: under-counting admits past
      # the cap.
      rm -f -- "$slot" 2>/dev/null || count=$((count + 1))
    fi
  done
  LANE_HOST_SLOT_COUNT="$count"
  if [ "$count" -lt "$cap" ]; then
    if : >"$dir/slot.$$"; then
      LANE_HOST_SLOT="$dir/slot.$$"
      rc=0
    else
      rc=2
    fi
  fi
  # Closed before the provider runs, so the provider inherits no descriptor on
  # the lock; the mutex arm's signal handlers go with the mutex.
  exec 8>&-
  orch_release_lock
  trap - INT TERM
  return "$rc"
}

# Take a slot for VERB, waiting up to ORCH_LANE_HOST_BUSY_WAIT_SECS for one to
# free. A refusal prints its keyed line and returns LANE_HOST_BUSY_EXIT; a
# setting or slot failure returns 2. The caller releases with
# lane_host_slot_release, from its EXIT trap.
lane_host_slot_take() { # VERB ARGS...
  local verb="$1" item=- prev="" arg cap wait_s dir deadline rc
  cap="${ORCH_LANE_HOST_MAX_CALLS:-4}"
  wait_s="${ORCH_LANE_HOST_BUSY_WAIT_SECS:-30}"
  case "$cap" in
    '' | *[!0-9]* | 0*) lane_host_slot_message setting-invalid name=ORCH_LANE_HOST_MAX_CALLS "value=$cap" >&2; return 2 ;;
  esac
  case "$wait_s" in
    '' | *[!0-9]* | 0?*) lane_host_slot_message setting-invalid name=ORCH_LANE_HOST_BUSY_WAIT_SECS "value=$wait_s" >&2; return 2 ;;
  esac
  shift
  for arg in "$@"; do
    [ "$prev" != --item ] || item="$arg"
    prev="$arg"
  done
  dir="$HOME/.cache/orch/lane-host-slots"
  mkdir -p -- "$dir" || { lane_host_slot_message slot-failed "path=$dir" >&2; return 2; }
  deadline=$((SECONDS + wait_s))
  while :; do
    rc=0
    lane_host_slot_try "$dir" "$cap" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) lane_host_slot_message slot-failed "path=$dir" >&2; return 2 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.2
  done
  lane_host_slot_message lane-host-busy "count=$LANE_HOST_SLOT_COUNT" "cap=$cap" "verb=$verb" "item=$item" >&2
  return "$LANE_HOST_BUSY_EXIT"
}

lane_host_slot_release() {
  [ -z "$LANE_HOST_SLOT" ] || rm -f -- "$LANE_HOST_SLOT"
  LANE_HOST_SLOT=""
}
