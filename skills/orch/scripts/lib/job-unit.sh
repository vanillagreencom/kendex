#!/usr/bin/env bash
# job-unit.sh — start a long-lived orch job so no process it starts outlives
# it, and stop one by what its launch recorded. The one owner of the manager
# probe, the unit name, the systemd-run launch and its properties, the setsid
# fallback, the unit stop and the process-group kill. Run it, or source it for
# the same functions; Bash 3.2.
#
# Where a systemd user manager starts a transient unit, the job runs as one:
# when its main process exits systemd kills every process left in the unit,
# one that detached into its own session included. Elsewhere it runs under
# setsid as the leader of its own process group, and calls `end` before it
# exits, which kills that group; a process that started its own session
# escapes it. The unit name shape, the runner lines, the unit properties and
# the stop rule are references/job-units.md.
#
# Usage:
#   job-unit.sh check
#       Print the bounds table, one line per class:
#         class=CLASS tasks-max=N runtime-max-sec=caller kill-grace-sec=N
#       runtime-max-sec=caller is the rule that the launch's --cap is the
#       unit's RuntimeMaxSec.
#   job-unit.sh name CLASS NAME PID
#       Print the unit name orch-CLASS-NAME-PID.
#   job-unit.sh launch CLASS NAME RECORD --cap SECS -- ARGV...
#       Start ARGV detached, as the unit orch-CLASS-NAME-PID where a manager
#       answers, PID being this launch's own process, and print its runner
#       line. CLASS is a row of the bounds table. RECORD is written whole
#       before each launch attempt, so the job can read how it runs the moment
#       it starts:
#         runner=systemd|setsid
#         unit=NAME            where runner=systemd
#         line=RUNNER_LINE
#       --cap is the RuntimeMaxSec of a class whose row says caller: the
#       caller sets it above its own bound plus the kill grace, so the job's
#       own bound fires first.
#       Exit 0 launched; 1 RECORD could not be written; 2 no setsid where the
#       fallback needs it; 3 usage, an unknown class included.
#   job-unit.sh end RECORD LEADER_PID
#       The job's own last call. Under setsid, kill the process group
#       LEADER_PID leads, the caller included; under a unit, nothing, since the
#       unit's end does it. Exit 0 done; 2 the group could not be killed.
#   job-unit.sh stop NAME
#       Stop the unit NAME. Exit 0 it was running and is stopped; 1 the
#       manager has no such unit, so it had ended; 2 anything else, a manager
#       that cannot be reached included.
#   job-unit.sh kill-group PID ARGV_GLOB
#       Kill the process group PID leads, while PID still runs and its argv
#       matches ARGV_GLOB, so a pid the system reused for anything else is
#       left alone. Exit 0 killed; 1 left alone; 2 the read or the kill failed.
#   job-unit.sh stop-job RECORD PID ARGV_GLOB
#       Stop the job RECORD describes: its unit by the exact recorded name, or
#       under setsid its group as kill-group does. Exits as those two do.
#
# A failure prints one line, `job-unit: KEY FIELD=VALUE...`, on stderr.
# Sourced, each subcommand is the function job_unit_<name with _ for ->, and
# job_unit_read RECORD loads a record into JOB_UNIT_RUNNER, JOB_UNIT_NAME and
# JOB_UNIT_LINE, which launch also sets. A status-2 failure leaves its KEY in
# JOB_UNIT_ERROR_KEY and its fields in JOB_UNIT_ERROR.

# The bounds table, one row per class: CLASS TASKS_MAX RUNTIME_MAX_SEC.
# TasksMax counts processes and threads together, so a runaway fork stops at
# the unit rather than exhausting the host's own limit. RuntimeMaxSec `caller`
# is the launch's --cap: validate's own bound is DEV_VALIDATE_TIMEOUT_SECS, a
# setting, so no constant stays above every value of it. No memory cap: one
# under 1G has frozen hosts, which is why kendex.settings.toml
# COMMAND_SAFETY_DENY_PATTERN refuses one.
JOB_UNIT_TABLE='validate 4096 caller'
# The seconds between SIGTERM and SIGKILL, both for what a unit still holds
# when it stops and for a caller's own bound, so the two graces are one number.
JOB_UNIT_KILL_GRACE=10

JOB_UNIT_RUNNER=""
JOB_UNIT_NAME=""
JOB_UNIT_LINE=""
JOB_UNIT_ERROR=""
JOB_UNIT_ERROR_KEY=""

job_unit_fail() { # KEY FIELDS
  JOB_UNIT_ERROR_KEY="$1"
  JOB_UNIT_ERROR="$2"
  return 2
}

# orch-CLASS-NAME-PID, with anything a unit name cannot carry replaced by `_`.
job_unit_name() { # CLASS NAME PID
  printf 'orch-%s-%s-%s' "$1" "$2" "$3" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'
}

# The row for CLASS, into JOB_UNIT_TASKS_MAX and JOB_UNIT_RUNTIME_MAX.
JOB_UNIT_TASKS_MAX=""
JOB_UNIT_RUNTIME_MAX=""
job_unit_bounds() { # CLASS
  local class tasks runtime
  while read -r class tasks runtime; do
    [[ "$class" == "$1" ]] || continue
    JOB_UNIT_TASKS_MAX="$tasks"
    JOB_UNIT_RUNTIME_MAX="$runtime"
    return 0
  done <<<"$JOB_UNIT_TABLE"
  return 1
}

job_unit_check() {
  local class tasks runtime
  while read -r class tasks runtime; do
    printf 'class=%s tasks-max=%s runtime-max-sec=%s kill-grace-sec=%s\n' \
      "$class" "$tasks" "$runtime" "$JOB_UNIT_KILL_GRACE"
  done <<<"$JOB_UNIT_TABLE"
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

job_unit_launch() { # CLASS NAME RECORD --cap SECS -- ARGV...
  local class="$1" job="$2" record="$3" cap="${5:-}" probe_err="" launch_err="" nofile name arg
  local unit_env=() unit_argv=()
  [[ $# -ge 7 && "$4" == --cap && "$6" == -- && "$cap" =~ ^[1-9][0-9]*$ ]] || return 3
  job_unit_bounds "$class" || return 3
  [[ "$JOB_UNIT_RUNTIME_MAX" == caller ]] || return 3
  shift 6
  JOB_UNIT_RUNNER=setsid
  JOB_UNIT_NAME=""
  # The probe starts a unit, since that is the question: `systemctl
  # is-system-running` exits non-zero on a degraded manager that still runs
  # units.
  if ! command -v systemd-run >/dev/null 2>&1; then
    JOB_UNIT_LINE="runner=setsid reason=no-systemd-run"
  elif probe_err="$(systemd-run --user --quiet --collect true </dev/null 2>&1 >/dev/null)"; then
    JOB_UNIT_RUNNER=systemd
    JOB_UNIT_NAME="$(job_unit_name "$class" "$job" "$$")"
    JOB_UNIT_LINE="runner=systemd unit=$JOB_UNIT_NAME"
  else
    JOB_UNIT_LINE="runner=setsid reason=probe-failed detail=${probe_err%%$'\n'*}"
  fi
  [[ "$JOB_UNIT_RUNNER" == systemd ]] || command -v setsid >/dev/null 2>&1 || return 2

  if [[ "$JOB_UNIT_RUNNER" == systemd ]]; then
    job_unit_record "$record" || return 1
    # A user unit inherits the manager's environment and resource limits, not
    # the caller's, so every exported name is handed over (--setenv=NAME takes
    # the value from systemd-run's own environment) and so are the open-file
    # limits, which a build and test battery exhausts first; the manager caps
    # a value above its own ceiling at that ceiling.
    for name in $(compgen -e); do unit_env+=("--setenv=$name"); done
    for arg in "$@"; do unit_argv+=("$(job_unit_arg "$arg")"); done
    nofile="$(job_unit_nofile -S):$(job_unit_nofile -H)"
    if launch_err="$(systemd-run --user --quiet --collect --unit="$JOB_UNIT_NAME" \
      -p "TasksMax=$JOB_UNIT_TASKS_MAX" -p "RuntimeMaxSec=$cap" -p "TimeoutStopSec=$JOB_UNIT_KILL_GRACE" \
      -p "LimitNOFILE=$nofile" ${unit_env[@]+"${unit_env[@]}"} \
      -- "${unit_argv[@]}" </dev/null 2>&1 >/dev/null)"; then
      return 0
    fi
    # The manager answered the probe and refused the unit. The job still runs,
    # contained as far as a process group reaches, and its record says why.
    command -v setsid >/dev/null 2>&1 || return 2
    JOB_UNIT_RUNNER=setsid
    JOB_UNIT_NAME=""
    JOB_UNIT_LINE="runner=setsid reason=unit-launch-failed detail=${launch_err%%$'\n'*}"
  fi
  job_unit_record "$record" || return 1
  setsid -f "$@" </dev/null >/dev/null 2>&1
}

job_unit_stop() { # NAME
  local out load
  JOB_UNIT_ERROR=""
  if out="$(systemctl --user stop -- "$1.service" 2>&1)"; then
    return 0
  fi
  if load="$(systemctl --user show -p LoadState --value -- "$1.service" 2>/dev/null)" \
    && [[ "$load" == not-found ]]; then
    return 1
  fi
  job_unit_fail stop-failed "unit=$1.service detail=${out%%$'\n'*}"
}

job_unit_kill_group() { # PID ARGV_GLOB
  local pid="$1" glob="$2" args pgid
  JOB_UNIT_ERROR=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if ! args="$(ps -ww -o args= -p "$pid")" || ! pgid="$(ps -o pgid= -p "$pid")"; then
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
  JOB_UNIT_ERROR=""
  job_unit_read "$1" || { job_unit_fail record-unreadable "path=$1"; return; }
  case "$JOB_UNIT_RUNNER" in
    systemd) job_unit_stop "$JOB_UNIT_NAME" ;;
    setsid) job_unit_kill_group "$2" "$3" ;;
  esac
}

job_unit_end() { # RECORD LEADER_PID
  JOB_UNIT_ERROR=""
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
    check) [[ $# -eq 0 ]] || rc=3 ;;
    name) [[ $# -eq 3 ]] || rc=3 ;;
    launch) [[ $# -ge 7 ]] || rc=3 ;;
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
    check) job_unit_check ;;
    name) job_unit_name "$@"; printf '\n' ;;
    launch)
      job_unit_launch "$@" || rc=$?
      case "$rc" in
        0) printf '%s\n' "$JOB_UNIT_LINE" ;;
        1) printf 'job-unit: record-unwritable path=%s\n' "$3" >&2 ;;
        2) printf 'job-unit: missing-command commands=setsid\n' >&2 ;;
        *) printf 'job-unit: usage subcommand=launch\n' >&2 ;;
      esac ;;
    *)
      "job_unit_${cmd//-/_}" "$@" || rc=$?
      [[ "$rc" -ne 2 ]] || printf 'job-unit: %s %s\n' "$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR" >&2 ;;
  esac
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  job_unit_main "$@"
fi
