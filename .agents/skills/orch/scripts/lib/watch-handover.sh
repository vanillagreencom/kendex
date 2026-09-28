# shellcheck shell=bash
#
# The fleet watch handed from a stopped overseer's pane to its successor's.
# Both launchers that replace a live overseer run it: `oversee launch
# --predecessor` and `oversee-succeed` in its succeed mode, each on the
# `verified` step of lib/overseer-launch.sh § ol_succession, before the stop
# that commits the succession. One owner, so neither launcher can leave the
# watch reading a pane the other would have handed on.
#
#   watch_job_launch  a command started through the orch job runner, its
#                     output appended beside the fleet state
#   watch_handover    the running repeat-mode watch named, and a helper
#                     started that restarts it from the successor pane once
#                     the predecessor's session is gone
#
# The helper is `oversee-succeed`'s internal `--watch-restart` run (its header,
# step 6), started through lib/job-unit.sh outside the launcher and anything
# that kills it: the stop ends the harness that ran the launcher when the
# launcher runs in the predecessor's own window, so nothing after the stop can
# be counted on to run.
#
# Neither function prints a keyed line: the caller owns its prefix and its
# words, as lib/overseer-launch.sh's callers do. Every dependency writes its
# stderr to DEP_ERR.
#
# Requires, of a caller that runs its functions: SCRIPT_DIR (the orch scripts
# directory), DEP_ERR (a file), and lib/watch-pid.sh and lib/job-unit.sh
# sourced by the caller. Sourcing it defines names and runs nothing. Sourced,
# never run.

# COMMAND started through the orch job runner as NAME and the UTC second, with
# stdout appended to OUT and stderr to ERR (one path may be both), from the
# current directory: a unit sends its command's output nowhere a caller
# reads, so the redirection is the job's own first step, and the exec leaves
# COMMAND the job's main process, so the job ends when it does. The record is
# the runner file beside STATE. Returns 1 with JOB_UNIT_ERROR_KEY and
# JOB_UNIT_ERROR set where the launch was refused.
watch_job_launch() { # NAME STATE OUT ERR COMMAND...
  local name="$1" state="$2" out="$3" err="$4"
  shift 4
  if ! watch_pid_paths "$state"; then
    JOB_UNIT_ERROR_KEY=state-path JOB_UNIT_ERROR="path=$state"
    return 1
  fi
  job_unit_launch "$name-$(date -u +%Y%m%dT%H%M%SZ)" "$WATCH_RUNNER_FILE" \
    -- sh -c 'out=$1 err=$2; shift 2; exec "$@" >>"$out" 2>>"$err"' sh "$out" "$err" "$@"
}

# The watch serving PREDECESSOR handed to SUCCESSOR: the repeat-mode watch
# recorded beside the fleet state (`workflow-state path oversee`) is named, and
# the helper started as the job watch-handover-<stamp>, handed the successor's
# LANE_VAR and LANE_HOME, its HARNESS and its FLAG words, which the restarted
# watch runs under. Its stdout and stderr go to oversee-watch.err, which the
# next watch start prints.
#
# The outcome is WATCH_HANDOVER_KEY with its fields in WATCH_HANDOVER_FIELDS:
#   0  watch-handover  pid=<the watch handed over> pane=<SUCCESSOR> log=<path>
#                      and the runner line
#   0  watch-absent    path=<fleet state>: no watch runs, so none is restarted
#   1  watch-restart-failed step=state-path, the detail in DEP_ERR, or
#                      step=helper pid=<N> error=<key> and the runner's error:
#                      the old watch keeps serving the gone pane until the
#                      successor's own watch start takes it over
watch_handover() { # PREDECESSOR SUCCESSOR LANE_VAR LANE_HOME HARNESS [FLAG...]
  local state old
  WATCH_HANDOVER_KEY="" WATCH_HANDOVER_FIELDS=()
  if ! state="$("$SCRIPT_DIR/workflow-state" path oversee 2>"$DEP_ERR")"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=state-path)
    return 1
  fi
  if ! watch_pid_live "$state"; then
    WATCH_HANDOVER_KEY=watch-absent WATCH_HANDOVER_FIELDS=("path=$state")
    return 0
  fi
  old="$WATCH_PID"
  if ! watch_job_launch watch-handover "$state" "$WATCH_ERR_FILE" "$WATCH_ERR_FILE" \
      "$SCRIPT_DIR/oversee-succeed" --watch-restart "$state" "$@"; then
    WATCH_HANDOVER_KEY=watch-restart-failed
    WATCH_HANDOVER_FIELDS=(step=helper "pid=$old" "error=$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR")
    return 1
  fi
  WATCH_HANDOVER_KEY=watch-handover
  WATCH_HANDOVER_FIELDS=("pid=$old" "pane=$2" "log=$WATCH_ERR_FILE" "$JOB_UNIT_LINE")
}
