# shellcheck shell=bash
#
# The fleet watch handed from a stopped overseer's pane to its successor's.
# Both overseer launchers run it: `oversee launch` and `oversee-succeed`,
# each on the
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
# directory), DEP_ERR (a file), HANDOFF (the brief's path), and lib/watch-pid.sh and lib/job-unit.sh
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
  job_unit_main launch "$name-$(date -u +%Y%m%dT%H%M%SZ)" "$WATCH_RUNNER_FILE" \
    -- sh -c 'out=$1 err=$2; shift 2; exec "$@" >>"$out" 2>>"$err"' sh "$out" "$err" "$@" \
    >/dev/null 2>"$DEP_ERR"
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
#   0  watch-started  pid=<watch> pane=<SUCCESSOR> log=<path> err=<path>
#                      and the runner line: no watch ran, so one is started
#   1  watch-restart-failed step=state-path, the detail in DEP_ERR, or
#                      step=helper pid=<N> error=<key> and the runner's error:
#                      the caller refuses launch before stopping its pane
watch_handover() { # PREDECESSOR SUCCESSOR LANE_VAR LANE_HOME HARNESS [FLAG...]
  local state old
  WATCH_HANDOVER_KEY="" WATCH_HANDOVER_FIELDS=()
  if ! state="$("$SCRIPT_DIR/workflow-state" path oversee 2>"$DEP_ERR")"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=state-path)
    return 1
  fi
  local live_rc=0
  watch_pid_live "$state" 2>"$DEP_ERR" || live_rc=$?
  case "$live_rc" in
    0) ;;
    1) watch_start "$state" "${@:2}"; return $? ;;
    *) WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=claim); return 1 ;;
  esac
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

# A first launch has no watch command to replay. Start the fleet reader with
# the workflow's repeat cadence, using the new pane's server and account.
# Wait for its claim before reporting success: an accepted job whose command
# exits during initialization has not left a watch running.
watch_start() { # STATE PANE LANE_VAR LANE_HOME HARNESS [FLAG...]
  local state="$1" pane="$2" var="$3" home="$4" harness="$5" deadline runner rc
  shift 5
  local flags=() harness_args=()
  [[ $# -eq 0 ]] || flags=(-- "$@")
  [[ -z "$harness" ]] || harness_args=(--harness "$harness")
  if ! watch_job_launch watch-start "$state" "$WATCH_LOG_FILE" "$WATCH_ERR_FILE" \
      env TMUX_PANE="$pane" "$var=$home" OVERSEE_WATCH_ORIGIN=succession \
      "$SCRIPT_DIR/oversee-watch" --repeat 60 --state "$state" --handoff "$HANDOFF" ${harness_args[@]+"${harness_args[@]}"} ${flags[@]+"${flags[@]}"}; then
    WATCH_HANDOVER_KEY=watch-restart-failed
    WATCH_HANDOVER_FIELDS=(step=start "error=$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR")
    return 1
  fi
  runner="$JOB_UNIT_LINE"
  deadline=$((SECONDS + WATCH_STOP_SECS))
  while :; do
    rc=0
    watch_pid_live "$state" 2>"$DEP_ERR" || rc=$?
    if [[ "$rc" -eq 0 && "$WATCH_PANE" == "$pane" ]]; then
      WATCH_HANDOVER_KEY=watch-started
      WATCH_HANDOVER_FIELDS=("pid=$WATCH_PID" "pane=$pane" "log=$WATCH_LOG_FILE" "err=$WATCH_ERR_FILE" "$runner")
      return 0
    fi
    if [[ "$rc" -gt 1 || "$SECONDS" -ge "$deadline" ]]; then
      WATCH_HANDOVER_KEY=watch-restart-failed
      WATCH_HANDOVER_FIELDS=(step=claim "log=$WATCH_ERR_FILE" "$runner")
      return 1
    fi
    sleep 0.1
  done
}
