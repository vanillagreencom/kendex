# shellcheck shell=bash
# job-unit.sh — start a long-lived orch job so no process it starts outlives
# it, and stop one by the unit name it was recorded under. Sourced; Bash 3.2.
#
# Where a systemd user manager starts a transient unit, the job runs as one:
# when its main process exits systemd kills every process left in the unit,
# one that detached into its own session included. Elsewhere it runs under
# setsid in its own process group, and containment is the job's to finish: it
# kills that group before it exits, and a process that started its own session
# escapes it. The unit name shape, the runner line and the stop rule are
# references/job-units.md.
#
# job_unit_launch KIND ID STAMP CAP_SECS RECORD -- ARGV...
#   Starts ARGV detached, as the unit KIND-ID-STAMP where a manager answers.
#   Before each launch attempt RECORD is written whole, so the job can read how
#   it runs the moment it starts:
#     runner=systemd|setsid
#     unit=NAME            where runner=systemd
#     line=RUNNER_LINE     one of the lines references/job-units.md lists
#   CAP_SECS is the unit's RuntimeMaxSec, a backstop the caller sets above its
#   own bound plus JOB_UNIT_KILL_GRACE, so the job's own bound fires first.
#   Sets JOB_UNIT_RUNNER, JOB_UNIT_NAME (empty under setsid) and JOB_UNIT_LINE.
#   Status 0 launched; 1 RECORD could not be written; 2 no setsid where the
#   fallback needs it; 3 called without `--` and an ARGV.
#
# job_unit_stop NAME
#   Stops the unit NAME (without .service). Status 0 it was running and is
#   stopped; 1 the manager has no such unit, so it already ended; 2 anything
#   else, with systemctl's first line of stderr in JOB_UNIT_ERROR. A manager
#   that cannot be reached is 2, never a unit found stopped.

# Processes and threads together, so a runaway fork stops at the unit rather
# than exhausting the host's own limit. No memory cap: one under 1G has frozen
# hosts, which is why kendex.settings.toml COMMAND_SAFETY_DENY_PATTERN refuses
# one.
JOB_UNIT_TASKS_MAX=4096
# The seconds between SIGTERM and SIGKILL, both for what a unit still holds
# when it stops and for a caller's own bound, so the two graces are one number.
JOB_UNIT_KILL_GRACE=10

JOB_UNIT_RUNNER=""
JOB_UNIT_NAME=""
JOB_UNIT_LINE=""
JOB_UNIT_ERROR=""

# KIND-ID-STAMP, each component with anything a unit name cannot carry
# replaced by `_`.
job_unit_name() { # KIND ID STAMP
  printf '%s-%s-%s' "$1" "$2" "$3" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'
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

job_unit_launch() { # KIND ID STAMP CAP_SECS RECORD -- ARGV...
  local kind="$1" id="$2" stamp="$3" cap="$4" record="$5" probe_err="" launch_err="" nofile name arg
  local unit_env=() unit_argv=()
  [[ $# -ge 7 && "$6" == -- ]] || return 3
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
    JOB_UNIT_NAME="$(job_unit_name "$kind" "$id" "$stamp")"
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
  JOB_UNIT_ERROR="${out%%$'\n'*}"
  return 2
}
