# shellcheck shell=bash
#
# The fleet watch handed from a stopped overseer's pane to its successor's.
# Both overseer launchers run it: `oversee`, on launch and resume, and
# `oversee-succeed`, each on the
# `verified` step of lib/overseer-launch.sh § ol_succession, before the stop
# that commits the succession. One owner, so neither launcher can leave the
# watch reading a pane the other would have handed on.
#
#   watch_job_launch  a command started through the orch job runner, its
#                     output appended beside the fleet state
#   watch_handover    the running repeat-mode watch named, and a helper
#                     started that restarts it from the successor pane once
#                     the predecessor's session is gone; for a predecessor
#                     whose server closed, the watch restarted there, with
#                     leave to replace the live one, before it returns
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
# directory), DEP_ERR (a file), HANDOFF (the brief's path), and lib/watch-pid.sh
# and lib/job-unit.sh sourced by the caller. Sourcing it defines names and runs nothing. Sourced,
# never run.

# COMMAND started through the orch job runner as NAME and the UTC second, with
# stdout appended to OUT and stderr to ERR (one path may be both), from the
# current directory: a unit sends its command's output nowhere a caller
# reads, so the redirection is the job's own first step, and the exec leaves
# COMMAND the job's main process, so the job ends when it does. The record is
# a file of the job's own beside STATE, WATCH_JOB_RECORD, made by exclusive
# creation and handed to COMMAND as OVERSEE_WATCH_JOB_RECORD; never
# oversee-watch.runner itself, the stop route of the watch holding the claim
# (references/watch-delivery.md), which a job that may never claim must not
# take from that watch. The caller moves the record there once its job's watch
# claims, or removes it. Returns 1 with JOB_UNIT_ERROR_KEY and JOB_UNIT_ERROR
# set where the launch was refused, its record removed.
watch_job_launch() { # NAME STATE OUT ERR COMMAND...
  local name="$1" state="$2" out="$3" err="$4"
  shift 4
  WATCH_JOB_RECORD=""
  if ! watch_pid_paths "$state"; then
    JOB_UNIT_ERROR_KEY=state-path JOB_UNIT_ERROR="path=$state"
    return 1
  fi
  if ! WATCH_JOB_RECORD="$(mktemp "$WATCH_RUNNER_FILE.XXXXXX" 2>"$DEP_ERR")"; then
    WATCH_JOB_RECORD=""
    JOB_UNIT_ERROR_KEY=record-unwritable JOB_UNIT_ERROR="path=$WATCH_RUNNER_FILE.XXXXXX"
    return 1
  fi
  if ! job_unit_main launch "$name-$(date -u +%Y%m%dT%H%M%SZ)" "$WATCH_JOB_RECORD" \
      -- sh -c 'out=$1 err=$2; shift 2; exec "$@" >>"$out" 2>>"$err"' sh "$out" "$err" \
      env OVERSEE_WATCH_JOB_RECORD="$WATCH_JOB_RECORD" "$@" >/dev/null 2>"$DEP_ERR"; then
    rm -f -- "$WATCH_JOB_RECORD"
    WATCH_JOB_RECORD=""
    return 1
  fi
}

# The watch serving PREDECESSOR handed to SUCCESSOR: the repeat-mode watch
# recorded beside the fleet state (`workflow-state path oversee`) is named, and
# the helper started as the job watch-handover-<stamp>, handed the successor's
# LANE_VAR and LANE_HOME, its HARNESS and its FLAG words, which the restarted
# watch runs under. Its stdout and stderr go to oversee-watch.err, which the
# next watch start prints. --closed names a successor whose predecessor's
# session closed with its tmux server, PREDECESSOR empty. A later server can
# hand the lost pane's id to another pane or to SUCCESSOR itself, so a
# restarted watch cannot tell a claim on it stale and is refused: --closed
# starts no helper, but replays the claiming watch's command from SUCCESSOR
# with that watch's pid as OVERSEE_WATCH_REPLACE, returning once the replay
# holds its claim. The replay's start stops the watch so named and waits out
# a lane-close it is finishing (`oversee-watch` § watch_claim, the one place a
# live watch is replaced). A stopped watch keeps its log cursor and unread
# events for it as for any successor.
#
# The outcome is WATCH_HANDOVER_KEY with its fields in WATCH_HANDOVER_FIELDS:
#   0  watch-handover  pid=<the watch handed over> pane=<SUCCESSOR> log=<path>
#                      and the runner line
#   0  watch-started  pid=<watch> pane=<SUCCESSOR> log=<path> err=<path>
#                      [stopped=<pid>] and the runner line: a watch is
#                      started where none ran, or where --closed replaced
#                      the live one stopped= names
#   1  watch-restart-failed step=state-path, the detail in DEP_ERR, or
#                      step=helper pid=<N> error=<key> and the runner's error,
#                      or watch_start's: the caller refuses launch before
#                      stopping its pane
watch_handover() { # [--closed] PREDECESSOR SUCCESSOR LANE_VAR LANE_HOME HARNESS [FLAG...]
  local state old fresh=0 closed=0
  if [[ "${1:-}" == --closed ]]; then shift; closed=1; elif [[ -z "$1" ]]; then fresh=1; fi
  WATCH_HANDOVER_KEY="" WATCH_HANDOVER_FIELDS=()
  if ! state="$("$SCRIPT_DIR/workflow-state" path oversee 2>"$DEP_ERR")"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=state-path)
    return 1
  fi
  local live_rc=0
  watch_pid_live "$state" 2>"$DEP_ERR" || live_rc=$?
  case "$live_rc" in
    0) ;;
    1)
      # A fresh reader starts at line one. A successor keeps its cursor
      # and unread events, even when its prior watch has already stopped.
      if (( fresh )) && ! { : > "$WATCH_LOG_FILE" && : > "$WATCH_ERR_FILE"; } 2>"$DEP_ERR"; then
        WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=logs)
        return 1
      fi
      if (( fresh )); then
        watch_start fresh "$state" "${@:2}"; return $?
      fi
      if ! watch_argv_read "$state" 2>"$DEP_ERR"; then
        watch_start fresh "$state" "${@:2}" || return $?
        WATCH_HANDOVER_FIELDS+=("unread=$WATCH_ARGV_FILE")
        return 0
      fi
      watch_start replay "$state" "${@:2}"; return $? ;;
    *) WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=claim); return 1 ;;
  esac
  old="$WATCH_PID"
  # Recovery's repeat loop releases its claim after this launch returns.
  # Capture the complete command before that owner can finish.
  if ! watch_argv_read "$state" 2>"$DEP_ERR"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=argv "pid=$old")
    return 1
  fi
  if (( closed )); then
    watch_start "replace=$old" "$state" "${@:2}" || return 1
    # The runner line stays last: its detail is free text.
    WATCH_HANDOVER_FIELDS=("${WATCH_HANDOVER_FIELDS[@]:0:4}" "stopped=$old" "${WATCH_HANDOVER_FIELDS[@]:4}")
    return 0
  fi
  local cwd="$WATCH_CWD" script="$WATCH_SCRIPT" argv_count="${#WATCH_ARGV[@]}"
  local argv=(${WATCH_ARGV[@]+"${WATCH_ARGV[@]}"})
  if ! watch_job_launch watch-handover "$state" "$WATCH_ERR_FILE" "$WATCH_ERR_FILE" \
      env HANDOFF="$HANDOFF" "$SCRIPT_DIR/oversee-succeed" --watch-restart "$state" "${@:1:5}" \
      "$cwd" "$script" "$argv_count" ${argv[@]+"${argv[@]}"} "${@:6}"; then
    WATCH_HANDOVER_KEY=watch-restart-failed
    WATCH_HANDOVER_FIELDS=(step=helper "pid=$old" "error=$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR")
    return 1
  fi
  WATCH_HANDOVER_KEY=watch-handover
  WATCH_HANDOVER_FIELDS=("pid=$old" "pane=$2" "log=$WATCH_ERR_FILE" "$JOB_UNIT_LINE")
}

# Replay a readable retained command with the new pane's server, account,
# handoff, harness and flags. A stopped watch with no readable command uses
# the workflow default and reports the unread path. replace=PID replays as
# replay does and hands the watch OVERSEE_WATCH_REPLACE=PID, the live watch
# its start may stop and take over. WATCH_HANDOFF_KEEP set keeps the retained
# command's --handoff where it names one, in place of HANDOFF.
# Wait for its claim before reporting success: an accepted job whose command
# exits during initialization, a GitHub authentication refusal among them
# (`oversee-watch` § repeat_watch), has not left a watch running. The wait
# ends on the watch's own outcome: its claim, or its exit, read off the pid
# it adds to its job's record (lib/watch-pid.sh § watch_job_pid_write), so a
# start that refuses is reported as soon as it exits and one still
# authenticating is waited out. Only a job that adds no pid is bounded here:
# WATCH_STOP_SECS, twice that for a replay, whose start can first stop the
# watch it takes over (`oversee-watch` § watch_claim). The job's record
# becomes the runner record once its watch claims, and is removed where it
# never does, so the live watch's stop route stands until it is replaced.
# The claim is the
# started watch's only where its pid differs from the claim live before the
# launch, besides naming origin succession and PANE: a new tmux server can
# hand the replaced watch's pane id to PANE itself, and that watch, started
# here once before, holds a record whose origin and pane both match.
watch_start() { # fresh|replay|replace=PID STATE PANE LANE_VAR LANE_HOME HARNESS [FLAG...]
  local mode="$1" state="$2" pane="$3" var="$4" home="$5" harness="$6" deadline runner rc record live
  shift 6
  local flags=() harness_args=() since="" word skip="" argv=() handoff="$HANDOFF" kept=""
  local cwd="${WATCH_CWD:-}" script="${WATCH_SCRIPT:-}" launch_cwd="$PWD" name=watch-start replace=() prior=""
  [[ $# -eq 0 ]] || flags=(-- "$@")
  [[ -z "$harness" ]] || harness_args=(--harness "$harness")
  case "$mode" in
    fresh)
      # The first lane is the fleet's start; an empty fleet starts now.
      if ! since="$(jq -er '.lanes[0].launched_at // (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "$state" 2>"$DEP_ERR")"; then
        WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=since)
        return 1
      fi
      watch_command_fresh
      cwd="$WATCH_CWD" script="$WATCH_SCRIPT"
      argv=(--repeat 60 --state "$state" --since "$since") ;;
    replay|replace=*)
      name=watch-restart
      [[ "$mode" != replace=* ]] || replace=("OVERSEE_WATCH_REPLACE=${mode#replace=}")
      for word in ${WATCH_ARGV[@]+"${WATCH_ARGV[@]}"}; do
        if [[ -n "$skip" ]]; then
          [[ "$skip" != handoff ]] || kept="$word"
          skip=""
          continue
        fi
        case "$word" in
          --handoff) skip=handoff ;;
          --harness) skip=value ;;
          --handoff=*) kept="${word#--handoff=}" ;;
          *) argv+=("$word") ;;
        esac
      done
      [[ -z "${WATCH_HANDOFF_KEEP:-}" || -z "$kept" ]] || handoff="$kept" ;;
    *) WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=mode); return 1 ;;
  esac
  rc=0
  watch_pid_live "$state" 2>"$DEP_ERR" || rc=$?
  if [[ "$rc" -gt 1 ]]; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=claim)
    return 1
  fi
  [[ "$rc" -ne 0 ]] || prior="$WATCH_PID"
  if ! cd -- "$cwd" 2>"$DEP_ERR"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=start "dir=$cwd")
    return 1
  fi
  rc=0
  if ! watch_job_launch "$name" "$state" "$WATCH_LOG_FILE" "$WATCH_ERR_FILE" \
      env TMUX_PANE="$pane" "$var=$home" OVERSEE_WATCH_ORIGIN=succession ${replace[@]+"${replace[@]}"} \
      "$script" ${argv[@]+"${argv[@]}"} --handoff "$handoff" ${harness_args[@]+"${harness_args[@]}"} ${flags[@]+"${flags[@]}"}; then
    WATCH_HANDOVER_KEY=watch-restart-failed
    WATCH_HANDOVER_FIELDS=(step=start "error=$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR")
    rc=1
  fi
  if ! cd -- "$launch_cwd" 2>>"$DEP_ERR"; then
    WATCH_HANDOVER_KEY=watch-restart-failed WATCH_HANDOVER_FIELDS=(step=directory)
    return 1
  fi
  [[ "$rc" -eq 0 ]] || return 1
  runner="$JOB_UNIT_LINE" record="$WATCH_JOB_RECORD"
  deadline=$((SECONDS + WATCH_STOP_SECS))
  [[ "$mode" == fresh ]] || deadline=$((SECONDS + 2 * WATCH_STOP_SECS))
  while :; do
    rc=0
    watch_pid_live "$state" 2>"$DEP_ERR" || rc=$?
    if [[ "$rc" -eq 0 && "$WATCH_PID" != "$prior" && "$WATCH_ORIGIN" == succession && "$WATCH_PANE" == "$pane" ]]; then
      if ! mv -f -- "$record" "$WATCH_RUNNER_FILE" 2>"$DEP_ERR"; then
        WATCH_HANDOVER_KEY=watch-restart-failed
        WATCH_HANDOVER_FIELDS=(step=runner "pid=$WATCH_PID" "record=$record" "$runner")
        return 1
      fi
      WATCH_HANDOVER_KEY=watch-started
      WATCH_HANDOVER_FIELDS=("pid=$WATCH_PID" "pane=$pane" "log=$WATCH_LOG_FILE" "err=$WATCH_ERR_FILE" "$runner")
      return 0
    fi
    # 0 runs, 1 exited with no claim standing, 2 unknown; a job that has
    # added no pid runs until its bound.
    live=0
    if [[ "$rc" -gt 1 ]] || ! watch_job_pid_read "$record" 2>"$DEP_ERR"; then
      live=2
    elif [[ -n "$WATCH_JOB_PID" ]]; then
      watch_pid_runs "$WATCH_JOB_PID" 2>"$DEP_ERR" || live=$?
    elif [[ "$SECONDS" -ge "$deadline" ]]; then
      live=1
    fi
    if [[ "$live" -ne 0 ]]; then
      rm -f -- "$record"
      WATCH_HANDOVER_KEY=watch-restart-failed
      WATCH_HANDOVER_FIELDS=(step=claim "log=$WATCH_ERR_FILE" "$runner")
      return 1
    fi
    sleep 0.1
  done
}
