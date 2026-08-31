# shellcheck shell=bash
#
# Teardown for the suites that drive real `merge-queue-watch launch` calls.
#
# The named failure it prevents: `launch` detaches its supervisor with
# `setsid -f`, outside the suite's session, and the supervisor runs queue-wait
# in a further process group of its own. Nothing the suite waits on owns those
# pids, so a suite that dies mid-run — this box's load reaper kills them
# routinely — leaves live supervisors behind whose fixture tree has been
# deleted under them (KEN-995).
#
# Usage, from a suite that launches supervisors:
#
#   . "$TEST_DIR/lib/merge-queue-reaper.sh"
#   mq_reap_own "$TMP_ROOT"
#   trap 'mq_reap || true; rm -rf "$TMP_ROOT"' EXIT
#   trap 'exit 143' TERM HUP
#   trap 'exit 130' INT
#
# The signal traps are what make the EXIT trap fire on an abort; without them
# bash dies on TERM without running it.
#
# WHAT IT KILLS is decided by argv, not by a name: a process is this suite's
# when one of its arguments is a path under the fixture root it was given.
# Every fixture process carries one — the supervisor its state file, runtime
# and artifact, its queue-wait worker the stub's own path — and no process
# outside this suite can, because `mktemp -d` gives each run its own root. A
# concurrent suite in the same repo, running the same scripts under the same
# names, is invisible to it.

# The fixture root whose processes this suite owns. Absolute, so an argv
# comparison is a prefix test and nothing else.
mq_reap_own() {
  [[ "${1:-}" == /* && -d "$1" ]] || {
    echo "merge-queue-reaper: fixture root must be an existing absolute path (got '${1:-}')" >&2
    return 1
  }
  MQ_REAP_ROOT="$1"
}

# Collect into MQ_REAP_PIDS. Reads /proc without forking, so the collector
# never sees its own helper processes; where /proc is absent it asks ps, which
# also cannot see a fork this function does not make.
mq_reap_collect() {
  local entry pid arg matched
  MQ_REAP_PIDS=()
  if [[ -r /proc/self/cmdline ]]; then
    for entry in /proc/[0-9]*/cmdline; do
      pid="${entry#/proc/}"; pid="${pid%/cmdline}"
      [[ "$pid" != "$$" && "$pid" != "$BASHPID" && -r "$entry" ]] || continue
      matched=false
      while IFS= read -r -d '' arg; do
        [[ "$arg" == "$MQ_REAP_ROOT"/* ]] && { matched=true; break; }
      done < "$entry" || true
      if $matched; then MQ_REAP_PIDS[${#MQ_REAP_PIDS[@]}]="$pid"; fi
    done
    return 0
  fi
  while read -r pid arg; do
    [[ "$pid" != "$$" && "$pid" != "$BASHPID" ]] || continue
    case " $arg " in *" $MQ_REAP_ROOT"/*) MQ_REAP_PIDS[${#MQ_REAP_PIDS[@]}]="$pid" ;; esac
  done < <(ps -e -ww -o pid=,args= 2>/dev/null || true)
}

# TERM first so a supervisor runs its own cleanup — which is what stops its
# worker's process group — then KILL whatever ignored it, then say so if
# anything still stands rather than exiting as though the tree were clear.
mq_reap() {
  local pid i
  [[ -n "${MQ_REAP_ROOT:-}" ]] || return 0
  mq_reap_collect
  for pid in ${MQ_REAP_PIDS+"${MQ_REAP_PIDS[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done
  for ((i=0; i<50; i++)); do
    mq_reap_collect
    [[ ${#MQ_REAP_PIDS[@]} -eq 0 ]] && return 0
    sleep 0.1
  done
  for pid in ${MQ_REAP_PIDS+"${MQ_REAP_PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; done
  for ((i=0; i<20; i++)); do
    mq_reap_collect
    [[ ${#MQ_REAP_PIDS[@]} -eq 0 ]] && return 0
    sleep 0.1
  done
  printf 'merge-queue-reaper: %d fixture process(es) survived teardown under %s: %s\n' \
    "${#MQ_REAP_PIDS[@]}" "$MQ_REAP_ROOT" "${MQ_REAP_PIDS[*]}" >&2
  return 1
}
