#!/usr/bin/env bash
# job-unit.sh — start a long-lived orch job as a transient systemd user unit
# where a user manager answers, under setsid elsewhere, and stop it by what
# its launch recorded. It bounds a job's lifetime, its memory when asked, and
# under a unit the tasks and memory its launching process's own cgroup caps; it
# sets no CPU limit. It holds the manager probe, the unit name, the
# systemd-run launch, the setsid fallback, the attached run, the unit stop and
# the process-group kill for the jobs that use it: dev-validate-run, every job
# references/waiter-launch.md starts (the repeat watch among them), and
# oversee-succeed's watch restart.
# A job with no --cap, one that runs for the session, is a unit only where the
# user manager lingers, since one that does not is stopped, with its units,
# when the user's last login session ends.
# Run it, or source it for the same functions; Bash 3.2.
#
# A unit holds every process the job starts: when the job's main process exits
# or reaches the unit's RuntimeMaxSec, systemd kills every process left in it,
# one that detached into its own session included, SIGTERM first and SIGKILL
# a kill grace later. Under setsid the job leads its own process group and
# calls `end` when it finishes, which tears that group down the same way;
# nothing bounds it, and a job killed before `end`, or a process that
# started its own session, escapes. The unit name shape, the runner lines, the
# unit properties, the stop rule and the orch launches that use their own
# mechanism are references/job-units.md.
#
# Usage:
#   job-unit.sh name NAME PID
#       Print the unit name orch-NAME-PID.
#   job-unit.sh launch NAME RECORD [--cap SECS] [--memory-max MIB] -- ARGV...
#       Start ARGV detached, as the unit orch-NAME-PID where a manager
#       answers (and, with no --cap, lingers), PID being this launch's own
#       process, in this launch's own working directory, environment,
#       user-manager slice and task and memory caps, and print its runner
#       line. RECORD
#       is written whole before each launch attempt, so the job can read how it
#       runs the moment it starts:
#         runner=systemd|setsid
#         unit=UNIT            where runner=systemd
#         line=RUNNER_LINE
#       --cap is the unit's RuntimeMaxSec, from the timeout the caller already
#       has: set above that bound plus the kill grace, so the job's own bound
#       fires first. A job with no timeout, which runs until it is stopped,
#       passes none, and its unit has no RuntimeMaxSec.
#       --memory-max is the unit's MemoryMax in MiB, in place of the
#       MemoryHigh the unit otherwise takes from its caller; no process group
#       holds a memory bound, so a launch that would run under setsid refuses
#       it.
#       A systemd-run that fails after the probe answered falls back to setsid
#       only where the manager has no unit of that name: its call can time out
#       while the manager still starts the unit, which is then the job.
#       Exit 0 launched; 1 RECORD could not be written (record-unwritable); 2
#       no setsid where the fallback needs it (missing-command); 3 usage; 4
#       the job was not started (launch-failed: setsid's exit status, or a
#       unit the manager would not describe); 5 --memory-max where the job
#       would run under setsid (memory-max-unheld, with the runner line).
#   job-unit.sh attach RECORD -- ARGV...
#       Run ARGV attached: a child of this process, in its session, working
#       directory and environment, that leads a process group of its own,
#       with stdin from /dev/null and stdout discarded, and wait for it. For a
#       host whose agent warden kills detached jobs: the job stays inside the
#       calling agent's own process tree. RECORD is written whole before the
#       start, as launch writes it:
#         runner=attached
#         line=runner=attached
#       Nothing bounds the job but its own bound, and a job the caller's
#       harness kills before `end` leaves its group as a setsid job does.
#       The job forks through the github skill's KENDEX_GROUP_LEADER prefix
#       (skills/github/scripts/lib/group-leader.sh), so ARGV names an
#       external program and the host needs perl.
#       Exit 0 the job ran and ended, whatever its own status; 1 RECORD could
#       not be written (record-unwritable), and nothing started; 2 that
#       prefix's lib is not beside this skill (group-leader-missing) or no
#       perl is installed (missing-command), and nothing started; 3 usage.
#   job-unit.sh end RECORD LEADER_PID
#       The job's own last call. Under setsid or attached, tear down the
#       process group LEADER_PID leads, the caller being a member; under a
#       unit, nothing, since the unit's end does the same. Exit 0 done; 2 RECORD could not be
#       read (record-unreadable) or the group could not be killed.
#   job-unit.sh stop UNIT
#       Stop the unit UNIT. Exit 0 it was running and is stopped; 1 the
#       manager has no such unit, so it had ended; 2 anything else, a manager
#       that cannot be reached included.
#   job-unit.sh kill-group PID ARGV_GLOB
#       Tear down the process group PID leads, while PID still runs and its
#       argv matches ARGV_GLOB, so a pid the system reused for anything else is
#       left alone. Exit 0 torn down; 1 left alone; 2 the read or the kill
#       failed.
#
# Every setsid teardown is one: SIGTERM to the group, up to the kill grace for
# its members to exit, then SIGKILL only if any still run. A unit's stop is the
# same SIGTERM and grace.
#   job-unit.sh stop-job RECORD PID ARGV_GLOB
#       Stop the job RECORD describes: its unit by the exact recorded name, or
#       under setsid or attached its group as kill-group does. Exits as those two do, and 2
#       where RECORD could not be read (record-unreadable).
#
# Every failure prints one line, `job-unit: KEY FIELD=VALUE...`, on stderr; a
# unit that had ended and a process left alone are exit 1 and no failure.
# Sourced, each subcommand is the function job_unit_<name with _ for ->, and
# job_unit_read RECORD loads a record into JOB_UNIT_RUNNER, JOB_UNIT_NAME and
# JOB_UNIT_LINE, which launch also sets, job_unit_slice CGROUP_FILE prints
# the user-manager slice launch names for the unit, and job_unit_cgroup_cap
# CGROUP_DIR FILE prints the cap launch copies from that cgroup file, and
# job_unit_pid_is PID ARGV_GLOB judges whether PID still runs that argv: 0 it
# does, 1 it has exited or runs another argv, 2 its argv could not be read
# while it still runs. A failure leaves its KEY in
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

# The cgroup v2 path a process runs in, read from its cgroup file, where that
# path is below this user's user@UID.service. Nothing where the process runs
# outside that manager (a login session scope, a system service) or the file
# holds no cgroup v2 line or cannot be read.
job_unit_cgroup() { # CGROUP_FILE
  local line path
  [[ -r "$1" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == 0::* ]] || continue
    path="${line#0::}"
    [[ "$path" == */user@"$UID".service/* ]] || return 0
    printf '%s' "$path"
    return 0
  done < "$1"
}

# The user-manager slice a process runs in: the innermost `.slice` in the path
# job_unit_cgroup reads from its cgroup file. Nothing where that reads none.
job_unit_slice() { # CGROUP_FILE
  local path part slice="" parts=()
  path="$(job_unit_cgroup "$1")" && [[ -n "$path" ]] || return 0
  IFS=/ read -r -a parts <<<"${path#*/user@"$UID".service/}"
  for part in ${parts[@]+"${parts[@]}"}; do
    [[ "$part" != *.slice ]] || slice="$part"
  done
  printf '%s' "$slice"
}

# A cgroup v2 limit file's value where it is a whole number; nothing where it
# reads `max` (no limit), is absent (a controller the cgroup lacks) or cannot
# be read. systemd refuses `max` as a unit property value.
job_unit_cgroup_cap() { # CGROUP_DIR FILE
  local value
  [[ -r "$1/$2" ]] || return 0
  value="$(< "$1/$2")" || return 0
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
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
    setsid|attached) ;;
    *) return 1 ;;
  esac
}

job_unit_launch() { # NAME RECORD [--cap SECS] [--memory-max MIB] -- ARGV...
  local job="${1:-}" record="${2:-}" probe_err="" launch_err="" linger capped="" memory_max="" load nofile name arg slice cgroup_dir cap
  local unit_props=() unit_env=() unit_argv=()
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  [[ $# -lt 2 ]] || shift 2
  while [[ "${1:-}" == --cap || "${1:-}" == --memory-max ]] && [[ "${2:-}" =~ ^[1-9][0-9]*$ ]]; do
    case "$1" in
      --cap) unit_props+=(-p "RuntimeMaxSec=$2"); capped=yes ;;
      --memory-max) unit_props+=(-p "MemoryMax=${2}M"); memory_max="$2" ;;
    esac
    shift 2
  done
  [[ -n "$job" && -n "$record" && $# -ge 2 && "$1" == -- ]] \
    || { job_unit_fail usage subcommand=launch 3; return; }
  shift
  JOB_UNIT_RUNNER=setsid
  JOB_UNIT_NAME=""
  # A user manager that does not linger is stopped when the user's last
  # login session ends, SSH disconnects included, and every unit in it with
  # it, while tmux and the lanes in the login session run on: a job there
  # would die with no status written. So a job with no --cap, which runs for
  # the session, is a unit only where the manager lingers, and a Linger that
  # cannot be read is no linger. A capped job is bounded anyway and keeps its
  # unit, so nothing it starts outlives it. The probe
  # then starts a unit, since that is the question: `systemctl
  # is-system-running` exits non-zero on a degraded manager that still runs
  # units.
  if ! command -v systemd-run >/dev/null 2>&1; then
    JOB_UNIT_LINE="runner=setsid reason=no-systemd-run"
  elif [[ -z "$capped" ]] && ! linger="$(loginctl show-user "$UID" -p Linger --value </dev/null 2>&1)"; then
    JOB_UNIT_LINE="runner=setsid reason=linger-unread detail=${linger%%$'\n'*}"
  elif [[ -z "$capped" && "$linger" != yes ]]; then
    JOB_UNIT_LINE="runner=setsid reason=no-linger"
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
    # A service ignores SIGPIPE unless told not to, where a process the caller
    # starts takes its default; IgnoreSIGPIPE=no gives the job the caller's.
    # A user unit inherits the manager's environment, working directory and
    # resource limits, not the caller's, so every exported name is handed over
    # (--setenv=NAME takes the value from systemd-run's own environment), the
    # caller's directory is named, and so are the caller's own open-file
    # limits, which a build and test battery exhausts first; the manager caps a
    # value above its own ceiling at that ceiling. They are the caller's
    # numbers, never the runner's. A unit also starts in the manager's default
    # slice, not the caller's: one started from an agent's slice would run
    # outside that slice's limits, where a warden that does not exempt the
    # unit by name reads the job as escaped work; in the caller's slice the job
    # stays inside agents.slice whatever the warden's job-unit pattern is
    # (../../references/job-units.md § Agent warden). So the caller's own
    # slice is named too. In that slice the unit shares the slice's task and
    # memory pool, so it also takes the caller's own cgroup's task cap and
    # memory soft cap, a runaway job then held to what its caller may use;
    # an explicit --memory-max is the unit's memory bound instead.
    if slice="$(job_unit_slice /proc/self/cgroup)" && [[ -n "$slice" ]]; then
      unit_props+=(--slice="$slice")
      cgroup_dir="/sys/fs/cgroup$(job_unit_cgroup /proc/self/cgroup)"
      if cap="$(job_unit_cgroup_cap "$cgroup_dir" pids.max)" && [[ -n "$cap" ]]; then
        unit_props+=(-p "TasksMax=$cap")
      fi
      if [[ -z "$memory_max" ]] && cap="$(job_unit_cgroup_cap "$cgroup_dir" memory.high)" && [[ -n "$cap" ]]; then
        unit_props+=(-p "MemoryHigh=$cap")
      fi
    fi
    for name in $(compgen -e); do unit_env+=("--setenv=$name"); done
    for arg in "$@"; do unit_argv+=("$(job_unit_arg "$arg")"); done
    nofile="$(job_unit_nofile -S):$(job_unit_nofile -H)"
    if launch_err="$(systemd-run --user --quiet --collect --unit="$JOB_UNIT_NAME" \
      --working-directory="$PWD" ${unit_props[@]+"${unit_props[@]}"} \
      -p "TimeoutStopSec=$JOB_UNIT_KILL_GRACE" -p IgnoreSIGPIPE=no \
      -p "LimitNOFILE=$nofile" ${unit_env[@]+"${unit_env[@]}"} \
      -- "${unit_argv[@]}" </dev/null 2>&1 >/dev/null)"; then
      return 0
    fi
    # The call failed after the probe answered. A client-side timeout reports
    # that while the manager may still start the unit, so only a unit the
    # manager has no record of did not start; one it has is the job. The job
    # then still runs, contained as far as a process group reaches, and its
    # record says why.
    if ! load="$(systemctl --user show -p LoadState --value -- "$JOB_UNIT_NAME.service" 2>/dev/null)"; then
      job_unit_fail launch-failed "unit=$JOB_UNIT_NAME.service step=show detail=${launch_err%%$'\n'*}" 4
      return
    fi
    case "$load" in
      not-found) ;;
      loaded) return 0 ;;
      *) job_unit_fail launch-failed "unit=$JOB_UNIT_NAME.service load=$load detail=${launch_err%%$'\n'*}" 4; return ;;
    esac
    command -v setsid >/dev/null 2>&1 || { job_unit_fail missing-command commands=setsid; return; }
    JOB_UNIT_RUNNER=setsid
    JOB_UNIT_NAME=""
    JOB_UNIT_LINE="runner=setsid reason=unit-launch-failed detail=${launch_err%%$'\n'*}"
  fi
  [[ -z "$memory_max" ]] || { job_unit_fail memory-max-unheld "$JOB_UNIT_LINE" 5; return; }
  job_unit_record "$record" || { job_unit_fail record-unwritable "path=$record" 1; return; }
  # setsid -f returns once it has forked; a status here is a fork it could not
  # make or an argv it could not start.
  setsid -f "$@" </dev/null >/dev/null 2>&1 || job_unit_fail launch-failed "status=$?" 4
}

# The job forks through the github skill's KENDEX_GROUP_LEADER prefix: the
# child makes itself a process-group leader before it execs ARGV, and resets
# INT and QUIT to their default, which a non-interactive shell's async job
# would otherwise ignore. Job control would make the same group from the
# parent side, racing the child's exec and printing that race's failure onto
# the caller's stderr; group-leader.sh holds the reasoning. The prefix execs,
# so ARGV names an external program. The lib is reached by the layout every
# install gives, the github skill beside this one, resolved by expansion from
# this file's own path; only this start needs it, so a caller that never
# attaches runs without it.
job_unit_attach() { # RECORD -- ARGV...
  local record="${1:-}" self="${BASH_SOURCE[0]}" lib pid
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  [[ -n "$record" && $# -ge 3 && "$2" == -- ]] \
    || { job_unit_fail usage subcommand=attach 3; return; }
  shift 2
  case "$self" in */*) ;; *) self="./$self" ;; esac
  lib="${self%/*}/../../../github/scripts/lib/group-leader.sh"
  # Bash 3.2 exits a non-interactive shell when source cannot find its file,
  # so the refusal checks for the file before sourcing it.
  # shellcheck source=../../../github/scripts/lib/group-leader.sh
  { [[ -f "$lib" && -r "$lib" ]] && source "$lib"; } || { job_unit_fail group-leader-missing "path=$lib" 2; return; }
  # The prefix runs perl; without it the fork would fail after the record
  # names a started job, and the caller would wait on a job that never ran.
  command -v perl >/dev/null 2>&1 || { job_unit_fail missing-command commands=perl 2; return; }
  JOB_UNIT_RUNNER=attached
  JOB_UNIT_NAME=""
  JOB_UNIT_LINE="runner=attached"
  job_unit_record "$record" || { job_unit_fail record-unwritable "path=$record" 1; return; }
  "${KENDEX_GROUP_LEADER[@]}" "$@" </dev/null >/dev/null &
  pid=$!
  wait "$pid" || :
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

# A saved pid names a job only while it still runs the argv the job was
# started with; a pid the system reused for anything else is not that job.
# An argv that cannot be read is no answer while the pid still runs, so it is
# its own status, never a pid found gone.
job_unit_pid_is() { # PID ARGV_GLOB
  local args
  if ! args="$(ps -ww -o args= -p "$1" 2>/dev/null)"; then
    kill -0 "$1" 2>/dev/null || return 1
    return 2
  fi
  # shellcheck disable=SC2053 # ARGV_GLOB is a pattern by contract
  [[ "$args" == $2 ]] || return 1
}

# Each `|| return 1` line below is a rule under which the group is left alone;
# dev_validate_run.sh holds one planted record and one control per such line.
job_unit_kill_group() { # PID ARGV_GLOB
  local pid="$1" pgid is=0
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  job_unit_pid_is "$pid" "$2" || is=$?
  [[ "$is" != 1 ]] || return 1
  if [[ "$is" == 2 ]] || ! pgid="$(ps -o pgid= -p "$pid" 2>/dev/null)"; then
    kill -0 "$pid" 2>/dev/null || return 1
    job_unit_fail kill-group-failed "pid=$pid step=read"
    return
  fi
  [[ "${pgid// /}" == "$pid" ]] || return 1
  job_unit_teardown "$pid"
}

job_unit_stop_job() { # RECORD PID ARGV_GLOB
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  job_unit_read "$1" || { job_unit_fail record-unreadable "path=$1"; return; }
  case "$JOB_UNIT_RUNNER" in
    systemd) job_unit_stop "$JOB_UNIT_NAME" ;;
    setsid|attached) job_unit_kill_group "$2" "$3" ;;
  esac
}

# How many processes of group PGID are still running, leaving out this process
# and what it forked to ask: the caller of `end` is in the group it signals.
job_unit_group_others() { # PGID
  local table
  table="$(ps -A -o pid= -o ppid= -o pgid=)" || return 1
  awk -v g="$1" -v me="$$" '
    { pid[NR] = $1; ppid[NR] = $2; pg[NR] = $3; if ($2 == me) mine[$1] = 1 }
    END {
      n = 0
      for (i = 1; i <= NR; i++)
        if (pg[i] == g && pid[i] != me && !(pid[i] in mine) && !(ppid[i] in mine)) n++
      print n
    }' <<<"$table"
}

# The one setsid teardown: SIGTERM to group PGID, as a unit's stop sends it, so
# what the group holds runs its traps; up to the kill grace for its members to
# exit; SIGKILL only where one still runs. A group that empties is left
# alone, since its id can be reused. A caller that is a member (MEMBER=member)
# ignores the SIGTERM and is not counted; it is killed only with a SIGKILL
# the rest of the group needed.
job_unit_teardown() { # PGID [MEMBER]
  local n=0 others=""
  [[ "${2:-}" != member ]] || trap '' TERM
  # No group left to signal is a group already torn down.
  kill -TERM -- "-$1" 2>/dev/null || return 0
  while (( n < JOB_UNIT_KILL_GRACE * 5 )); do
    others="$(job_unit_group_others "$1")" || break
    [[ "$others" != 0 ]] || return 0
    sleep 0.2
    n=$((n + 1))
  done
  kill -KILL -- "-$1" 2>/dev/null || ! kill -0 -- "-$1" 2>/dev/null \
    || job_unit_fail kill-group-failed "pid=$1 step=kill"
}

job_unit_end() { # RECORD LEADER_PID
  JOB_UNIT_ERROR="" JOB_UNIT_ERROR_KEY=""
  job_unit_read "$1" || { job_unit_fail record-unreadable "path=$1"; return; }
  case "$JOB_UNIT_RUNNER" in
    systemd) return 0 ;;
    setsid|attached) job_unit_teardown "$2" member ;;
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
    launch) [[ $# -ge 4 ]] || rc=3 ;;
    attach) [[ $# -ge 3 ]] || rc=3 ;;
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
