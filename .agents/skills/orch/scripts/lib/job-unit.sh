#!/usr/bin/env bash
# job-unit.sh — start a long-lived orch job as a transient systemd user unit
# where a user manager answers, under setsid elsewhere, and stop it by what its
# launch recorded. It bounds a job's lifetime and nothing else: no memory, CPU
# or task limit. It holds the manager probe, the unit name, the systemd-run
# launch, the setsid fallback, the unit stop and the process-group kill for
# the jobs that use it; dev-validate-run is the first. Run it, or source it for
# the same functions; Bash 3.2.
#
# A unit holds every process the job starts: when the job's main process exits
# or reaches the unit's RuntimeMaxSec, systemd kills every process left in it,
# one that detached into its own session included. Under setsid the job leads
# its own process group and calls `end` when it finishes, which kills that
# group; nothing bounds it, and a job killed before `end`, or a process that
# started its own session, escapes. The unit name shape, the runner lines, the
# unit properties, the stop rule and the orch launches that use their own
# mechanism are references/job-units.md.
#
# Usage:
#   job-unit.sh name NAME PID
#       Print the unit name orch-NAME-PID.
#   job-unit.sh launch NAME RECORD --cap SECS -- ARGV...
#       Start ARGV detached, as the unit orch-NAME-PID where a manager answers,
#       PID being this launch's own process, and print its runner line. RECORD
#       is written whole before each launch attempt, so the job can read how it
#       runs the moment it starts:
#         runner=systemd|setsid
#         unit=UNIT            where runner=systemd
#         line=RUNNER_LINE
#       --cap is the unit's RuntimeMaxSec, from the timeout the caller already
#       has: set above that bound plus the kill grace, so the job's own bound
#       fires first.
#       Exit 0 launched; 1 RECORD could not be written (record-unwritable); 2
#       no setsid where the fallback needs it (missing-command); 3 usage; 4
#       setsid could not start the job (launch-failed, with its exit status).
#   job-unit.sh end RECORD LEADER_PID
#       The job's own last call. Under setsid, kill the process group
#       LEADER_PID leads, the caller included; under a unit, nothing, since the
#       unit's end does it. Exit 0 done; 2 RECORD could not be read
#       (record-unreadable) or the group could not be killed.
#   job-unit.sh stop UNIT
#       Stop the unit UNIT. Exit 0 it was running and is stopped; 1 the
#       manager has no such unit, so it had ended; 2 anything else, a manager
#       that cannot be reached included.
#   job-unit.sh kill-group PID ARGV_GLOB
#       Kill the process group PID leads, while PID still runs and its argv
#       matches ARGV_GLOB, so a pid the system reused for anything else is
#       left alone. Exit 0 killed; 1 left alone; 2 the read or the kill failed.
#   job-unit.sh stop-job RECORD PID ARGV_GLOB
#       Stop the job RECORD describes: its unit by the exact recorded name, or
#       under setsid its group as kill-group does. Exits as those two do, and 2
#       where RECORD could not be read (record-unreadable).
#
# Every failure prints one line, `job-unit: KEY FIELD=VALUE...`, on stderr; a
# unit that had ended and a process left alone are exit 1 and no failure.
# Sourced, each subcommand is the function job_unit_<name with _ for ->, and
# job_unit_read RECORD loads a record into JOB_UNIT_RUNNER, JOB_UNIT_NAME and
# JOB_UNIT_LINE, which launch also sets. A failure leaves its KEY in
# JOB_UNIT_ERROR_KEY and its fields in JOB_UNIT_ERROR.

# The seconds between SIGTERM and SIGKILL, both for what a unit still holds
# when it stops and for a caller's own bound, so the two graces are one number.
JOB_UNIT_KILL_GRACE=10

JOB_UNIT_RUNNER=""
JOB_UNIT_NAME=""
JOB_UNIT_LINE=""
JOB_UNIT_ERROR=""
JOB_UNIT_ERROR_KEY=""

job_unit_fail() { # KEY FIELDS [STATUS]
  JOB_UNIT_ERROR_KEY="$1"
  JOB_UNIT_ERROR="$2"
  return "${3:-2}"
}

# orch-NAME-PID, with anything a unit name cannot carry replaced by `_`.
job_unit_name() { # NAME PID
  printf 'orch-%s-%s' "$1" "$2" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'
}

# An argument as the service manager reads it: it expands ${NAME} in a unit's
# command line, and $$ is its spelling of one literal $.
job_unit_arg() { # VALUE
  printf '%s' "${1//\$/\$\$}"
}

# An open-file limit as systemd spells it.
job_unit_nofile() { # ulimit FLAG
  local n
  n="$(ulimit "$1" -n)" || return 1
  [[ "$n" != unlimited ]] || n=infinity
  printf '%s' "$n"
}

job_unit_record() { # RECORD
  {
    printf 'runner=%s\n' "$JOB_UNIT_RUNNER"
    [[ -z "$JOB_UNIT_NAME" ]] || printf 'unit=%s\n' "$JOB_UNIT_NAME"
    printf 'line=%s\n' "$JOB_UNIT_LINE"
  } > "$1.part" && mv -- "$1.part" "$1"
}

job_unit_read() { # RECORD
  local key value
  JOB_UNIT_RUNNER=""
  JOB_UNIT_NAME=""
  JOB_UNIT_LINE=""
  [[ -f "$1" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      runner) JOB_UNIT_RUNNER="$value" ;;
      unit) JOB_UNIT_NAME="$value" ;;
      line) JOB_UNIT_LINE="$value" ;;
    esac
  done < "$1"
  case "$JOB_UNIT_RUNNER" in
    systemd) [[ -n "$JOB_UNIT_NAME" ]] ;;
    setsid) ;;
    *) return 1 ;;
  esac
}

job_unit_launch() { # NAME RECORD --cap SECS -- ARGV...
  local job="$1" record="$2" cap="${4:-}" probe_err="" launch_err="" nofile name arg
  local unit_env=() unit_argv=()
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  [[ $# -ge 6 && "$3" == --cap && "$5" == -- && "$cap" =~ ^[1-9][0-9]*$ ]] \
    || { job_unit_fail usage subcommand=launch 3; return; }
  shift 5
  JOB_UNIT_RUNNER=setsid
  JOB_UNIT_NAME=""
  # The probe starts a unit, since that is the question: `systemctl
  # is-system-running` exits non-zero on a degraded manager that still runs
  # units.
  if ! command -v systemd-run >/dev/null 2>&1; then
    JOB_UNIT_LINE="runner=setsid reason=no-systemd-run"
  elif probe_err="$(systemd-run --user --quiet --collect true </dev/null 2>&1 >/dev/null)"; then
    JOB_UNIT_RUNNER=systemd
    JOB_UNIT_NAME="$(job_unit_name "$job" "$$")"
    JOB_UNIT_LINE="runner=systemd unit=$JOB_UNIT_NAME"
  else
    JOB_UNIT_LINE="runner=setsid reason=probe-failed detail=${probe_err%%$'\n'*}"
  fi
  [[ "$JOB_UNIT_RUNNER" == systemd ]] || command -v setsid >/dev/null 2>&1 \
    || { job_unit_fail missing-command commands=setsid; return; }

  if [[ "$JOB_UNIT_RUNNER" == systemd ]]; then
    job_unit_record "$record" || { job_unit_fail record-unwritable "path=$record" 1; return; }
    # A user unit inherits the manager's environment and resource limits, not
    # the caller's, so every exported name is handed over (--setenv=NAME takes
    # the value from systemd-run's own environment) and so are the caller's
    # own open-file limits, which a build and test battery exhausts first; the
    # manager caps a value above its own ceiling at that ceiling. They are the
    # caller's numbers, never the runner's.
    for name in $(compgen -e); do unit_env+=("--setenv=$name"); done
    for arg in "$@"; do unit_argv+=("$(job_unit_arg "$arg")"); done
    nofile="$(job_unit_nofile -S):$(job_unit_nofile -H)"
    if launch_err="$(systemd-run --user --quiet --collect --unit="$JOB_UNIT_NAME" \
      -p "RuntimeMaxSec=$cap" -p "TimeoutStopSec=$JOB_UNIT_KILL_GRACE" \
      -p "LimitNOFILE=$nofile" ${unit_env[@]+"${unit_env[@]}"} \
      -- "${unit_argv[@]}" </dev/null 2>&1 >/dev/null)"; then
      return 0
    fi
    # The manager answered the probe and refused the unit. The job still runs,
    # contained as far as a process group reaches, and its record says why.
    command -v setsid >/dev/null 2>&1 || { job_unit_fail missing-command commands=setsid; return; }
    JOB_UNIT_RUNNER=setsid
    JOB_UNIT_NAME=""
    JOB_UNIT_LINE="runner=setsid reason=unit-launch-failed detail=${launch_err%%$'\n'*}"
  fi
  job_unit_record "$record" || { job_unit_fail record-unwritable "path=$record" 1; return; }
  # setsid -f returns once it has forked; a status here is a fork it could not
  # make or an argv it could not start.
  setsid -f "$@" </dev/null >/dev/null 2>&1 || job_unit_fail launch-failed "status=$?" 4
}

job_unit_stop() { # UNIT
  local out load
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  if out="$(systemctl --user stop -- "$1.service" 2>&1)"; then
    return 0
  fi
  if load="$(systemctl --user show -p LoadState --value -- "$1.service" 2>/dev/null)" \
    && [[ "$load" == not-found ]]; then
    return 1
  fi
  job_unit_fail stop-failed "unit=$1.service detail=${out%%$'\n'*}"
}

# Each `|| return 1` line below is a rule under which the group is left alone;
# dev_validate_run.sh holds one planted record and one control per such line.
job_unit_kill_group() { # PID ARGV_GLOB
  local pid="$1" glob="$2" args pgid
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  if ! args="$(ps -ww -o args= -p "$pid" 2>/dev/null)" || ! pgid="$(ps -o pgid= -p "$pid" 2>/dev/null)"; then
    kill -0 "$pid" 2>/dev/null || return 1
    job_unit_fail kill-group-failed "pid=$pid step=read"
    return
  fi
  [[ "${pgid// /}" == "$pid" ]] || return 1
  # shellcheck disable=SC2053 # ARGV_GLOB is a pattern by contract
  [[ "$args" == $glob ]] || return 1
  # The group can end between the read and the signal: a job ends its own.
  kill -KILL -- "-$pid" 2>/dev/null || ! kill -0 -- "-$pid" 2>/dev/null \
    || job_unit_fail kill-group-failed "pid=$pid step=kill"
}

job_unit_stop_job() { # RECORD PID ARGV_GLOB
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  job_unit_read "$1" || { job_unit_fail record-unreadable "path=$1"; return; }
  case "$JOB_UNIT_RUNNER" in
    systemd) job_unit_stop "$JOB_UNIT_NAME" ;;
    setsid) job_unit_kill_group "$2" "$3" ;;
  esac
}

job_unit_end() { # RECORD LEADER_PID
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  job_unit_read "$1" || { job_unit_fail record-unreadable "path=$1"; return; }
  case "$JOB_UNIT_RUNNER" in
    systemd) return 0 ;;
    setsid) kill -KILL -- "-$2" 2>/dev/null || job_unit_fail kill-group-failed "pid=$2 step=kill" ;;
  esac
}

job_unit_main() {
  local cmd="${1:-}" rc=0
  [[ $# -eq 0 ]] || shift
  case "$cmd" in
    -h|--help)
      sed -n '2,/^$/p' < "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0 ;;
    name) [[ $# -eq 2 ]] || rc=3 ;;
    launch) [[ $# -ge 6 ]] || rc=3 ;;
    end) [[ $# -eq 2 ]] || rc=3 ;;
    stop) [[ $# -eq 1 ]] || rc=3 ;;
    kill-group) [[ $# -eq 2 ]] || rc=3 ;;
    stop-job) [[ $# -eq 3 ]] || rc=3 ;;
    *) rc=3 ;;
  esac
  if [[ "$rc" -ne 0 ]]; then
    printf 'job-unit: usage subcommand=%s\n' "${cmd:-none}" >&2
    return 3
  fi
  case "$cmd" in
    name) job_unit_name "$@"; printf '\n' ;;
    *)
      JOB_UNIT_ERROR_KEY=""
      "job_unit_${cmd//-/_}" "$@" || rc=$?
      [[ "$rc" -ne 0 || "$cmd" != launch ]] || printf '%s\n' "$JOB_UNIT_LINE"
      [[ -z "$JOB_UNIT_ERROR_KEY" ]] || printf 'job-unit: %s %s\n' "$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR" >&2 ;;
  esac
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  job_unit_main "$@"
fi
