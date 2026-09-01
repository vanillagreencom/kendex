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
#   trap mq_reap_teardown EXIT
#   trap 'exit 143' TERM HUP
#   trap 'exit 130' INT
#
# The signal traps turn an abort into an ordinary exit, so the teardown below
# decides the suite's result. The EXIT trap runs on TERM without them too, but
# bash re-raises the signal over whatever the teardown returns: a teardown
# asking for 7 leaves 7 with the traps and 143 without. So a tree the reap
# could not clear reaches the runner as the same 143 every abort gives — a
# failure, but indistinguishable from the abort itself. A tree this could not clear FAILS the
# suite — the survivors are the very condition these suites exist to catch, so
# discarding the reap's status would leave the containment failure invisible
# to every runner above.
#
# WHAT IT KILLS is decided by argv, not by a name: a process is this suite's
# when one of its arguments is a path under the fixture root it was given.
# Every fixture process carries one — the supervisor its state file, runtime
# and artifact, its queue-wait worker the stub's own path — and no process
# outside this suite can, because `mktemp -d` gives each run its own root. A
# concurrent suite in the same repo, running the same scripts under the same
# names, is invisible to it.

# The fixture root whose processes this suite owns, checked here for the
# typo a later reap could only report as an empty tree.
mq_reap_own() {
  [[ "${1:-}" == /* && -d "$1" ]] || {
    echo "merge-queue-reaper: fixture root must be an existing absolute path (got '${1:-}')" >&2
    return 1
  }
  MQ_REAP_ROOT="$1"
}

# Collect into MQ_REAP_PIDS every process whose argv names a path under $1.
#
# The /proc walk runs on builtins alone, so the collector starts nothing its
# own scan could see. The ps fallback does fork — for ps, and for the command
# substitution around it — but the listing is captured BEFORE the scan, and
# neither those forks' argv nor the scanning shell's carries the fixture root,
# so nothing this function starts can match. A suite whose own script lived
# under its fixture root would break that; the root is a mktemp directory the
# suite fills, never the tree the suite is read from.
#
# BASHPID is Bash 4.0+, and bare under `set -u` it is fatal on the 3.2 macOS
# ships — in an EXIT trap, fatal before the reap and before the cleanup after
# it. Guarded, it collapses to $$ there, which is correct: $$ alone already
# excludes the only shell that calls this.
#
# MQ_REAP_FORCE_PS=1 takes the fallback on a host that has /proc, so the
# branch every macOS run depends on is exercised where the suites actually
# run — merge-queue-watch reaches for its own identity fallback the same way.
mq_reap_collect() {
  local root="$1" entry pid arg matched listing
  MQ_REAP_PIDS=()
  if [[ -r /proc/self/cmdline && "${MQ_REAP_FORCE_PS:-0}" != 1 ]]; then
    for entry in /proc/[0-9]*/cmdline; do
      pid="${entry#/proc/}"; pid="${pid%/cmdline}"
      [[ "$pid" != "$$" && "$pid" != "${BASHPID:-$$}" && -r "$entry" ]] || continue
      matched=false
      while IFS= read -r -d '' arg; do
        [[ "$arg" == "$root"/* ]] && { matched=true; break; }
      done < "$entry" || true
      if $matched; then MQ_REAP_PIDS[${#MQ_REAP_PIDS[@]}]="$pid"; fi
    done
    return 0
  fi
  # A census that could not run is not a tree with nothing in it. Saying so is
  # the difference between a reap that found nothing and a reap that could not
  # look, and the caller's exit status now rides on which it was.
  listing=$(ps -e -ww -o pid=,args= 2>/dev/null) || {
    echo "merge-queue-reaper: ps could not enumerate processes; the tree under $root was never judged" >&2
    return 1
  }
  while read -r pid arg; do
    [[ -n "$pid" && "$pid" != "$$" && "$pid" != "${BASHPID:-$$}" ]] || continue
    case " $arg " in *" $root"/*) MQ_REAP_PIDS[${#MQ_REAP_PIDS[@]}]="$pid" ;; esac
  done <<< "$listing"
}

# mq_reap [ROOT] — clear ROOT's fixture processes, defaulting to the root
# mq_reap_own recorded. TERM first so a supervisor runs its own cleanup, which
# is what stops its worker's process group; then KILL what ignored it, on a
# census taken in that same instant rather than one taken before a sleep;
# then say what still stands rather than returning as though the tree were
# clear.
mq_reap() {
  local root="${1:-${MQ_REAP_ROOT:-}}" pid i
  [[ "$root" == /* ]] || {
    echo "merge-queue-reaper: reap needs an absolute fixture root (got '$root')" >&2
    return 1
  }
  # Every census is a chance to fail unjudged, wait loops included, so each one
  # carries its own status out rather than only the first.
  mq_reap_collect "$root" || return 1
  for pid in ${MQ_REAP_PIDS+"${MQ_REAP_PIDS[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done
  for ((i=0; i<50; i++)); do
    mq_reap_collect "$root" || return 1
    [[ ${#MQ_REAP_PIDS[@]} -eq 0 ]] && return 0
    sleep 0.1
  done
  mq_reap_collect "$root" || return 1
  for pid in ${MQ_REAP_PIDS+"${MQ_REAP_PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; done
  for ((i=0; i<20; i++)); do
    mq_reap_collect "$root" || return 1
    [[ ${#MQ_REAP_PIDS[@]} -eq 0 ]] && return 0
    sleep 0.1
  done
  printf 'merge-queue-reaper: %d fixture process(es) survived teardown under %s: %s\n' \
    "${#MQ_REAP_PIDS[@]}" "$root" "${MQ_REAP_PIDS[*]}" >&2
  return 1
}

# The EXIT trap itself: reap, remove the fixture root, and carry the suite's
# own status out unless the reap failed, which is a failure of its own.
mq_reap_teardown() {
  local rc=$?
  mq_reap || rc=1
  rm -rf -- "${MQ_REAP_ROOT:?}"
  exit "$rc"
}
