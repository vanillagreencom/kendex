#!/usr/bin/env bash
# Surface: open-terminal provider-pane launch, verification and input.
# Inputs: scripts/open-terminal, scripts/lib, tests/fixtures/lane-host,
# tests/lib/open-terminal-lane-world.sh and its shared helpers.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TMP_ROOT="$(mktemp -d)" || exit 1
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

HOST_STUB="$TEST_DIR/fixtures/lane-host"
CAPS=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb'
cat > "$OT_STUB_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LANE_HOST_STUB_LOG.ssh"
[[ "$1" == -T && "$2" == -o && "$3" == BatchMode=yes && "$4" == -- && $# == 6 ]] || exit 1
[[ -z "$(cat)" ]] || exit 1
[[ -z "${SSH_PANE_CONTROL:-}" ]] || tmux send-keys -t %1 Enter
[[ "${SSH_FAIL:-0}" == 0 ]] || exit "$SSH_FAIL"
exec "$BASH" -c "$6"
SH
cat > "$TMP_ROOT/provider-prefix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command="${1//\/srv\/lane/$LANE_HOST_STUB_DIR/srv/lane}"
exec "$BASH" -c "$command"
SH
cat > "$OT_STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$LANE_HOST_STUB_LOG.started"
SH
chmod +x "$OT_STUB_BIN/ssh" "$OT_STUB_BIN/claude" "$TMP_ROOT/provider-prefix"
export LANE_HOST_STUB_CREATE_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix='"$TMP_ROOT/provider-prefix"
CURRENT="$TMP_ROOT/provider-screen"
READY="$TMP_ROOT/provider-ready"
DELIVERED="$TMP_ROOT/provider-delivered"
printf '\xe2\x9d\xaf\xc2\xa0\n' > "$READY"
printf '/orch start KEN-40\n' > "$DELIVERED"
# The harness consumes these bytes as the retry task, not as display text.
EXPECTED_BRIEF="$TMP_ROOT/expected-brief"
printf '%s' '/orch start KEN-40 This is an unattended orch lane, and nobody reads this pane. Send every question for the overseer with lane-mail ask and block on lane-mail wait for its answer, never as a question in chat. Never end a turn waiting on the person, and end none before a lane-mail ask or notice, or the lane status file, says where the work stands. Send a notice only when the work changed since your last notice, with a new head, PR, verdict, blocker, request or finish. A wait that continues updates the lane status file only. Where you would stop to ask, read lane-mail inbox and continue the workflow.' > "$EXPECTED_BRIEF"
brief_contract() {
  local cmp_rc=0
  cmp -s "$EXPECTED_BRIEF" "$1" || cmp_rc=$?
  assert_eq "$cmp_rc" 0 "$2"
}

local_input_count() { grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$RUN/tmux.log" || true; }
launch_contract() { printf '%s\n' "$OUT" > "$RUN/launch-errors"; assert_eq "rc=$RC local=$(local_input_count)" 'rc=0 local=0' "$1" "$RUN/launch-errors"; }
failed_launch_contract() {
  assert_eq "rc=$RC local=$(local_input_count) stops=$(grep -c '^stop --item KEN-40 --harness claude ' "$RUN/host.log" || true) killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)" "$1" "$2"
}

for row in 'delivered|0|0' 'composer|0|1' 'dialog|2|1'; do
  IFS='|' read -r initial viewer_status needs_send <<< "$row"
  case "$initial" in
    delivered) cp "$DELIVERED" "$CURRENT" ;;
    composer) cp "$READY" "$CURRENT" ;;
    dialog) printf 'Choose theme\n' > "$CURRENT" ;;
  esac
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-$initial;LANE_HOST_STUB_SENT_KEY_FILE=$TMP_ROOT/keys-$initial;LANE_HOST_STUB_AFTER_KEY=$READY;LANE_HOST_STUB_AFTER_FILE=$DELIVERED;LANE_HOST_STUB_VIEWER_STATUS=$viewer_status;LANE_HOST_STUB_VIEWER_LINE=ssh human-viewer;OT_PANE_TEXT=Choose theme" \
    --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
  launch_contract "$initial launch uses the provider with a contradicting local dialog"
  assert_eq "$(grep -c '^/orch start KEN-40' "$RUN/host.log.started" || true)" 1 \
    "$initial provider prefix executes the harness with its rendered brief"
  assert_eq "$(grep -c '^capture --item KEN-40 --history ' "$RUN/host.log" || true)" \
    "$([[ "$needs_send" == 0 ]] && echo 1 || echo 2)" "$initial verification reads provider history"
  assert_eq "$(grep -c '^send --item KEN-40 --file ' "$RUN/host.log" || true)" "$needs_send" \
    "$initial brief goes through provider send"
  [[ "$needs_send" == 0 ]] || brief_contract "$TMP_ROOT/sent-$initial" "$initial retry delivers the complete task bytes"
  assert_eq "$(grep -c '^send --item KEN-40 --key Enter ' "$RUN/host.log" || true)" \
    "$([[ "$initial" == dialog ]] && echo 1 || echo 0)" "$initial nudge goes through provider send"
  assert_eq "$(grep -c '^set-option .* @lane-viewer-command ssh human-viewer$' "$RUN/tmux.log" || true)" \
    "$([[ "$viewer_status" == 0 ]] && echo 1 || echo 0)" "$initial optional viewer command"
  assert_eq "$(grep -c '^capture-pane ' "$RUN/tmux.log" || true)" 0 "$initial reads no local screen"
  assert_eq "$(grep -cE '^new-window .* -d( |$)' "$RUN/tmux.log" || true)" 1 "$initial dormant window stays unselected"
done

cp "$READY" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;OT_PANE_TEXT=Choose theme" \
  --harness claude --lane "$H/.eclaude" --repo o/r --relaunch KEN-40
launch_contract 'relaunch harness wait reads the provider composer'
assert_eq "$(grep -c '^capture --item KEN-40 ' "$RUN/host.log" || true)" 1 'harness wait uses provider viewport'

cp "$READY" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-refused;LANE_HOST_STUB_PROBE_STATUS=7" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
assert_eq "rc=$RC sends=$(grep -c '^send ' "$RUN/host.log" || true) local=$(local_input_count)" \
  'rc=1 sends=0 local=0' 'a failed process read refuses launch input'

for row in 'first|SSH_FAIL=7|0|1|1' 'first|LANE_HOST_STUB_VIEWER_STATUS=7|0|1|1' 'first|LANE_HOST_STUB_CAPTURE_STATUS=7|0|1|1' 'first|LANE_HOST_STUB_CAPTURE_VIEWPORT_STATUS=7|0|1|1' 'relaunch|LANE_HOST_STUB_CAPTURE_VIEWPORT_STATUS=7|0|2|1' 'relaunch|LANE_HOST_STUB_VIEWER_STATUS=7|0|2|1' 'first|LANE_HOST_STUB_VIEWER_STATUS=7|7|1|0'; do
  IFS='|' read -r mode failure stop_status stops killed <<< "$row"
  cp "$READY" "$CURRENT"
  failure_args=()
  [[ "$mode" != relaunch ]] || failure_args+=(--relaunch)
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_STOP_STATUS=$stop_status;LANE_HOST_STUB_CAPTURE_ERROR=provider: capture-unreachable item=KEN-40;$failure" \
    --harness claude --lane "$H/.eclaude" --repo o/r ${failure_args[@]+"${failure_args[@]}"} KEN-40
  failed_launch_contract "rc=1 local=0 stops=$stops killed=$killed" "the $mode failed attempt stops its detached harness: $failure"
  if [[ "$failure" == *CAPTURE* ]]; then
    assert_eq "$(grep -cFx "open-terminal: host-capture-failed operation=capture host=$HOST_STUB item=KEN-40 exit=7" <<<"$OUT" || true)" 1 'provider capture failures keep their operation and exit status'
    assert_eq "$(grep -cFx 'provider: capture-unreachable item=KEN-40' <<<"$OUT" || true)" 1 'provider capture failures retain their cause'
    assert_eq "$(grep -cE '^open-terminal: (tmux-failed|composer-stuck|harness-screen-missing|brief-undelivered) ' <<<"$OUT" || true)" 0 'a failed provider read cannot be diagnosed as a stalled or missing local screen'
  fi
  [[ "$stop_status" == 0 ]] || assert_eq "$(grep -c '^open-terminal: host-stop-failed item=KEN-40 exit=7$' <<<"$OUT" || true)" 1 'failed cleanup reports the stop failure and keeps ownership'
done

cp "$DELIVERED" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;SSH_PANE_CONTROL=1" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
CONTROL_RC=0
( FAIL=0; launch_contract 'control'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: a transport that types into the local pane fails the launch contract'

SHIPPED_OPEN_TERMINAL="$OPEN_TERMINAL"
EMPTY_BRIEF_MUTANT="$(mutant_scripts empty-brief/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/empty-brief/orch"
mutate_file "$EMPTY_BRIEF_MUTANT" 'text "$brief $LAUNCH_UNATTENDED_TEXT"' 'text ""'
OPEN_TERMINAL="$EMPTY_BRIEF_MUTANT"
cp "$READY" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-empty;LANE_HOST_STUB_AFTER_FILE=$DELIVERED" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
CONTROL_RC=0
( FAIL=0; brief_contract "$TMP_ROOT/sent-empty" control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/brief-control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'the retry task assertion rejects an empty text payload'
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
CLEANUP_MUTANT="$(mutant_scripts detached-cleanup/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/detached-cleanup/orch"
mutate_file "$CLEANUP_MUTANT" 'host_pane_stop() {' 'host_pane_stop() { return 0;'
for row in 'relaunch|0|live|stopped|1' 'relaunch|7|live|running|0' 'relaunch|7|control|stopped|1' 'first|0|live|stopped|1' 'first|7|live|absent|0'; do
  IFS='|' read -r mode stop_status code status killed <<< "$row"
  fleet="$TMP_ROOT/cleanup-$mode-$stop_status-$code"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$fleet" "$PWD"
  record="$(jq -cn --arg host "$HOST_STUB" --arg account "$H/.eclaude" '{item:"KEN-40",window:"stub:KEN-40",host:$host,kind:"ssh",harness:"claude",account:$account,mail_root:"/srv/lane",status:"running",launched_at:"2026-10-01T00:00:00Z"}')"
  launch_args=()
  if [[ "$mode" == relaunch ]]; then
    "$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" set oversee lanes "[$record]" >/dev/null
    launch_args+=(--relaunch)
  fi
  printf 'Choose theme\n' > "$CURRENT"
  OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
  [[ "$code" != control ]] || OPEN_TERMINAL="$CLEANUP_MUTANT"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_STOP_STATUS=$stop_status;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-cleanup-$mode-$stop_status-$code" \
    --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" ${launch_args[@]+"${launch_args[@]}"} KEN-40
  got="rc=$RC status=$("$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" get oversee '.lanes[0].status // "absent"') killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)"
  assert_eq "$got" "rc=1 status=$status killed=$killed" "detached $code $mode stop=$stop_status"
  if [[ "$code" == control ]]; then
    CONTROL_RED="$(FAIL=0; assert_eq "$got" 'rc=1 status=running killed=0' control >/dev/null; printf '%s' "$FAIL")"
    assert_eq "$CONTROL_RED" 1 'a failed provider stop cannot be hidden by closing its dormant local window'
  else
    assert_eq "$(grep -c '^stop --item KEN-40 --harness claude ' "$RUN/host.log" || true)" \
      "$([[ "$stop_status" == 0 && "$mode" == relaunch ]] && echo 2 || echo 1)" 'detached cleanup stops each owned attempt through the provider'
  fi
done
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
UNSTOPPED_MUTANT="$(mutant_scripts unstopped-attempt/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/unstopped-attempt/orch"
mutate_file "$UNSTOPPED_MUTANT" 'host_pane_stop || return 1 ;;' 'false && host_pane_stop || return 1 ;;'
OPEN_TERMINAL="$UNSTOPPED_MUTANT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_VIEWER_STATUS=7" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
CONTROL_RC=0
( FAIL=0; failed_launch_contract 'rc=1 local=0 stops=1 killed=1' control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/stop-control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'the failed attempt assertion rejects an owned harness left running'
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

# The record writer is the dependency that fails after launch confirmation.
RECORD_MUTANT="$(mutant_scripts taken-record/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/taken-record/orch"
mutate_file "$RECORD_MUTANT" 'lane_record_write() {' 'lane_record_write() { [[ "${7:-running}" != running ]] || return 1;'
OPEN_TERMINAL="$RECORD_MUTANT"
fleet="$TMP_ROOT/taken-fleet"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$fleet" "$PWD"
cp "$DELIVERED" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" KEN-40
failed_launch_contract 'rc=1 local=0 stops=0 killed=0' 'a confirmed foreground launch survives a later record failure'
mutate_file "$RECORD_MUTANT" '[[ -n "$UNTAKEN_PANE" ]] || return 1' '[[ -n "$UNTAKEN_PANE" ]] || UNTAKEN_PANE="$LAUNCH_PANE"'
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" KEN-40
CONTROL_RC=0
( FAIL=0; failed_launch_contract 'rc=1 local=0 stops=0 killed=0' control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/taken-control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'the taken launch assertion rejects cleanup after a later record failure'

BACKGROUND_MUTANT="$(mutant_scripts background-record/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/background-record/orch"
mutate_file "$BACKGROUND_MUTANT" 'lane_record_write() {' 'lane_record_write() { [[ "${7:-running}" != running ]] || return 1;'
mutate_file "$BACKGROUND_MUTANT" 'launch_prepared() {' $'launch_prepared() {\n  trap '\''printf "%s\\n" "$?" > "$OT_PREP_DONE"'\'' EXIT'
background_contract() {
  assert_eq "status=$("$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" get oversee '.lanes[0].status') stops=$(grep -c '^stop --item KEN-40 ' "$RUN/host.log" || true) killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)" 'status=preparing stops=0 killed=0' "$1"
}
PREPARING_CREATE_LINE="${LANE_HOST_STUB_CREATE_LINE}"$'\tstate=preparing'
for code in live control; do
  OPEN_TERMINAL="$BACKGROUND_MUTANT"
  if [[ "$code" == control ]]; then
    mutate_file "$BACKGROUND_MUTANT" '[[ -n "$UNTAKEN_PANE" ]] || return 1' '[[ -n "$UNTAKEN_PANE" ]] || UNTAKEN_PANE="$LAUNCH_PANE"'
  fi
  fleet="$TMP_ROOT/background-$code"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$fleet" "$PWD"
  done_file="$TMP_ROOT/background-$code.done"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_CREATE_LINE=$PREPARING_CREATE_LINE;OT_PREP_DONE=$done_file" \
    --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" KEN-40
  end=$((SECONDS + 30))
  while [[ ! -s "$done_file" ]] && (( SECONDS < end )); do sleep 0.05; done
  assert_eq "$([[ -s "$done_file" ]] && echo completed || echo missing)" completed 'the owned background job completed before cleanup is judged'
  if [[ "$code" == live ]]; then background_contract 'a confirmed background launch survives a later record failure'
  else
    CONTROL_RC=0
    ( FAIL=0; background_contract control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/background-control.log" 2>&1 || CONTROL_RC=$?
    assert_eq "$CONTROL_RC" 1 'the background assertion rejects stopping a taken launch'
  fi
done
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

# The capture fixture fills the short pool after verification. The next cat
# is refused by the real dispatcher and drives host_launch_pending selection.
SELECTION_PROVIDER="$TMP_ROOT/selection-provider"
cat > "$SELECTION_PROVIDER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
rc=0
"$OT_SELECTION_PROVIDER" "$@" || rc=$?
if [[ "$1" == capture && "$rc" == 0 && "${OT_BUSY_AFTER_CAPTURE:-}" == 1 ]]; then
  mkdir -p "$HOME/.cache/orch/lane-host-slots/short"
  : > "$HOME/.cache/orch/lane-host-slots/short/slot.$OT_SLOT_OWNER"
fi
if [[ "$1" == stop && -n "${OT_POST_STOP_STATE:-}" ]]; then
  printf '%s\n' "$OT_POST_STOP_STATE" > "$LANE_HOST_STUB_HARNESS_STATE_FILE"
fi
exit "$rc"
SH
cat > "$OT_STUB_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$OT_SELECTION_RUNS"
SH
chmod +x "$SELECTION_PROVIDER" "$OT_STUB_BIN/codex"
mutate_file "$TMP_ROOT/provider-prefix" 'exec "$BASH" -c "$command"' 'if [[ -n "${OT_SELECTION_SCRIPTS:-}" ]]; then
  mkdir -p "$LANE_HOST_STUB_DIR/srv/lane/.agents/skills/orch"
  ln -s "$OT_SELECTION_SCRIPTS" "$LANE_HOST_STUB_DIR/srv/lane/.agents/skills/orch/scripts"
fi
exec "$BASH" -c "$command"'
RETAIN_MUTANT="$(mutant_scripts selection-retirement/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/selection-retirement/orch"
mutate_file "$RETAIN_MUTANT" 'host_pane_stop || return 1 ;;' 'host_pane_stop || true ;;'
CONFIRM_MUTANT="$(mutant_scripts selection-confirmation/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/selection-confirmation/orch"
mutate_file "$CONFIRM_MUTANT" 'host_pane_stop || return 1 ;;' ': ;; # host_pane_stop || return 1 ;;'

selection_checkpoint() {
  if [[ "$scope" == fleet ]]; then
    "$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get oversee '[.lanes[] | select(.item == "KEN-40") | .prepare] | first' | jq -Sc .
  else
    "$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get KEN-40 .host_launch | jq -Sc .
  fi
}
selection_contract() {
  local expected_checkpoint="$saved_checkpoint" expected_status=preparing expected_killed=0 state=launch-only killed=0 windows=0
  if [[ -f "$RUN/tmux.log" ]]; then
    killed="$(grep -c '^kill-window ' "$RUN/tmux.log" || true)"
    windows="$(grep -c '^new-window ' "$RUN/tmux.log" || true)"
  fi
  if [[ "$stop_status" == 0 ]]; then expected_checkpoint=null; expected_status=stopped; expected_killed=1; fi
  [[ "$scope" != fleet ]] || state="$("$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get oversee '[.lanes[] | select(.item == "KEN-40") | .status] | first')"
  assert_eq "$(selection_checkpoint)" "$expected_checkpoint" "$1 retains or retires the complete selection checkpoint"
  if [[ "$stop_status" != 0 ]]; then
    local record_key=KEN-40 record_query='.'
    [[ "$scope" != fleet ]] || { record_key=oversee; record_query='.lanes[] | select(.item == "KEN-40")'; }
    assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get "$record_key" "$record_query" | jq -Sc .)" \
      "$(jq -Sc "$record_query" <<< "$saved_record")" "$1 preserves the entire current ownership record"
  fi
  [[ "$scope" != fleet ]] || assert_eq "$state" "$expected_status" "$1 preserves fleet ownership until cleanup confirms exit"
  assert_eq "rc=$RC killed=$killed stops=$(grep -c '^stop --item KEN-40 --harness codex ' "$RUN/host.log" || true) after=$(cat "$provider_state")" \
    "rc=1 killed=$expected_killed stops=1 after=$post_state" "$1 follows confirmed provider stop before retirement"
  assert_eq "$windows" 0 "$1 retries selection without a second harness launch"
  assert_eq "$([[ -e "$RUN/host.log.ssh" ]] && echo 1 || echo 0)" 0 "$1 sends no second detached launch over SSH"
}
# Harness state is AFTER stop. Successful stop + live is unreachable:
# schemas/lane-host.md requires stop to wait for the named processes to exit.
# Those cells use the paired success/gone skip-confirmation controls.
for row in 'ok|0|gone' 'ok|7|live' 'ok|7|gone' 'failed|0|gone' 'failed|7|live' 'failed|7|gone'; do
  IFS='|' read -r read_state stop_status after_state <<< "$row"
  post_state=running
  [[ "$after_state" != gone ]] || post_state=exited
  for scope in fleet launch-only; do
    selection_state="$TMP_ROOT/selection-$read_state-$stop_status-$after_state-$scope"
    mkdir -p "$selection_state"
    if [[ "$scope" == fleet ]]; then ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$selection_state" "$PWD"; fi
    provider_state="$selection_state/provider-state"
    printf 'running\n' > "$provider_state"
    slot_home="$selection_state/home"
    slot_file="$slot_home/.cache/orch/lane-host-slots/short/slot.$$"
    selection_runs="$selection_state/harness-runs"
    selection_env="flags=-m gpt-6-astra -c model_reasoning_effort=high;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$SELECTION_PROVIDER;OT_SELECTION_PROVIDER=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$READY;OT_PANE_TEXT=Choose theme;ORCH_STATE_DIR=$selection_state;HOME=$slot_home;ORCH_LANE_HOST_SHORT_MAX_CALLS=1;ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0;OT_SLOT_OWNER=$$;OT_SELECTION_SCRIPTS=$SCRIPTS_DIR;OT_SELECTION_RUNS=$selection_runs;LANE_HOST_STUB_HARNESS_STATE_FILE=$provider_state"
    selection_args=()
    [[ "$scope" != fleet ]] || selection_args=(--state-dir "$selection_state")
    OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
    run_ot "$selection_env;OT_BUSY_AFTER_CAPTURE=1" --harness codex --lane "$H/.eclaude" --repo o/r --relaunch ${selection_args[@]+"${selection_args[@]}"} KEN-40
    assert_eq "rc=$RC busy=$(grep -c '^lane-host: lane-host-busy .*verb=cat item=KEN-40' <<< "$OUT" || true)" 'rc=0 busy=1' "$scope selection checkpoint comes from a dispatcher refusal"
    saved_checkpoint="$(selection_checkpoint)"
    assert_eq "$(jq -r '[.step,.harness,.relaunch,.pane] | @tsv' <<< "$saved_checkpoint")" $'selection\tcodex\ttrue\t%1' "$scope saves the started selector identity"
    saved_record="$("$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get "$([[ "$scope" == fleet ]] && echo oversee || echo KEN-40)")"
    printf '%s\n' "$saved_record" > "$selection_state/saved-record"
    printf '%s\n' "$selection_env" > "$selection_state/saved-env"
    saved_panes="$RUN/panes"
    printf '%s\n' "$saved_panes" > "$selection_state/saved-panes"
    rm -f -- "${slot_file:?}"
    retry_env="$selection_env;OT_TMUX_PANES=$saved_panes;LANE_HOST_STUB_SELECTION=pending;LANE_HOST_STUB_STOP_STATUS=$stop_status;OT_POST_STOP_STATE=$post_state"
    [[ "$read_state" != failed ]] || retry_env+=";LANE_HOST_STUB_CAT_STATUS=7;LANE_HOST_STUB_CAT_PATH=/srv/lane/tmp/lane-mail/KEN-40/relaunch-selection"
    for code in live control; do
      printf 'running\n' > "$provider_state"
      "$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" update "$([[ "$scope" == fleet ]] && echo oversee || echo KEN-40)" '$record' --argjson record "$saved_record" >/dev/null
      OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
      if [[ "$code" == control ]]; then
        OPEN_TERMINAL="$RETAIN_MUTANT"
        [[ "$stop_status" != 0 ]] || OPEN_TERMINAL="$CONFIRM_MUTANT"
      fi
      run_ot "$retry_env" --harness codex --lane "$H/.eclaude" --repo o/r --relaunch ${selection_args[@]+"${selection_args[@]}"} KEN-40
      if [[ "$code" == live ]]; then
        selection_contract "$scope $row"
        assert_eq "$(grep -c '^open-terminal: relaunch-selection-failed item=KEN-40 operation=' <<< "$OUT" || true)" 1 "$scope $row reports the original selection failure"
        [[ "$stop_status" == 0 ]] || assert_eq "$(grep -c '^open-terminal: host-stop-failed item=KEN-40 exit=7$' <<< "$OUT" || true)" 1 "$scope $row reports unconfirmed stop"
      else
        CONTROL_RC=0
        ( FAIL=0; selection_contract control; [[ "$FAIL" == 0 ]] ) > "$selection_state/control-$code.log" 2>&1 || CONTROL_RC=$?
        assert_eq "$CONTROL_RC" 1 "$scope $row rejects retirement without confirmed cleanup"
      fi
    done
  done
done
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

# Exercise the record dependency, not a stand-in for host_launch_ready.
STATE_SCRIPTS="$(mutant_scripts finalization-state/orch open-terminal)"
orch_fixture_shared_libs "$TMP_ROOT/finalization-state/orch"
cp "$SCRIPTS_DIR/workflow-state" "$STATE_SCRIPTS/workflow-state-real"
rm -- "${STATE_SCRIPTS:?}/workflow-state"
cat > "$STATE_SCRIPTS/workflow-state" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
operation=other record='' prev=''
for arg in "$@"; do
  [[ "$prev" != rec ]] || record="$arg"
  [[ "$arg" != update-report ]] || operation=record
  [[ "$arg" != 'del(.host_launch)' && "$arg" != *'.prepare.line != null'* ]] || operation=checkpoint
  prev="$arg"
done
if [[ "$operation" == record && -n "$record" ]]; then operation="$(jq -r .status <<< "$record")"; fi
if [[ "$operation" == "${OT_STATE_FAIL:-never}" ]]; then
  printf 'workflow-state: fixture-failed operation=%s\n' "$operation" >&2
  exit 7
fi
exec "${0%/*}/workflow-state-real" "$@"
SH
chmod +x "$STATE_SCRIPTS/workflow-state"
STATE_TAKEN_MUTANT="$(mutant_scripts state-taken-control/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/state-taken-control/orch"
rm -- "${STATE_TAKEN_MUTANT%/*}/workflow-state"
cp "$STATE_SCRIPTS/workflow-state" "$STATE_SCRIPTS/workflow-state-real" "${STATE_TAKEN_MUTANT%/*}/"
mutate_file "$STATE_TAKEN_MUTANT" '[[ -n "$UNTAKEN_PANE" ]] || return 1' '[[ -n "$UNTAKEN_PANE" ]] || UNTAKEN_PANE="$LAUNCH_PANE"'
SUCCESS_MUTANT="$(mutant_scripts selection-success-control/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/selection-success-control/orch"
mutate_file "$SUCCESS_MUTANT" 'completed) ;;' 'completed) host_pane_stop || return 1 ;;'
CLOSE_MUTANT="$(mutant_scripts selection-close-control/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/selection-close-control/orch"
mutate_file "$CLOSE_MUTANT" $'tmux_window_close "$UNTAKEN_PANE" "$title" || return 1\n          if [[ "$FLEET" == true ]]; then' $'tmux_window_close "$UNTAKEN_PANE" "$title" || true\n          if [[ "$FLEET" == true ]]; then'
STATE_CLEAR_MUTANT="$(mutant_scripts state-clear-control/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/state-clear-control/orch"
rm -- "${STATE_CLEAR_MUTANT%/*}/workflow-state"
cp "$STATE_SCRIPTS/workflow-state" "$STATE_SCRIPTS/workflow-state-real" "${STATE_CLEAR_MUTANT%/*}/"
mutate_file "$STATE_CLEAR_MUTANT" '"$WORKFLOW_STATE" update "$wt_id" '\''del(.host_launch)'\'' >/dev/null' '"$WORKFLOW_STATE" update "$wt_id" '\''del(.host_launch)'\'' >/dev/null || true'

REPLAY_MUTANT="$(mutant_scripts selection-replay-control/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/selection-replay-control/orch"
mutate_file "$REPLAY_MUTANT" 'if [[ "$host_pending_step" == selection ]]; then' 'if false && [[ "$host_pending_step" == selection ]]; then'

selection_effect_contract() {
  local checkpoint="$saved_checkpoint" status=preparing stops=0 killed=0
  case "$effect" in
    success) checkpoint=null; status=running ;;
    running) ;;
    list-panes) stops=1 ;;
    kill-window) stops=1; killed=1 ;;
    stopped) stops=1; killed=1 ;;
    checkpoint)
      [[ "$scope" != fleet ]] || { status=stopped; stops=1; killed=1; } ;;
  esac
  assert_eq "$RC" "$expected_rc" "$scope $effect returns the dependency outcome"
  assert_eq "$([[ -e "$RUN/host.log.ssh" ]] && echo 1 || echo 0)" 0 "$scope $effect completes the saved launch without another SSH execution"
  assert_eq "$(selection_checkpoint)" "$checkpoint" "$scope $effect keeps the required checkpoint"
  [[ "$scope" != fleet ]] || assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" get oversee '[.lanes[] | select(.item == "KEN-40") | .status] | first')" "$status" "$scope $effect keeps the confirmed fleet state"
  local got_killed=0
  [[ ! -f "$RUN/tmux.log" ]] || got_killed="$(grep -c '^kill-window ' "$RUN/tmux.log" || true)"
  assert_eq "stops=$(grep -c '^stop --item KEN-40 --harness codex ' "$RUN/host.log" || true) killed=$got_killed" "stops=$stops killed=$killed" "$scope $effect does not clean up a taken launch"
}
for scope in fleet launch-only; do
  selection_state="$TMP_ROOT/selection-failed-7-gone-$scope"
  provider_state="$selection_state/provider-state"
  saved_record="$(cat "$selection_state/saved-record")"
  selection_env="$(cat "$selection_state/saved-env")"
  saved_panes="$(cat "$selection_state/saved-panes")"
  saved_checkpoint="$(jq -Sc "$([[ "$scope" == fleet ]] && echo '.lanes[0].prepare' || echo '.host_launch')" <<< "$saved_record")"
  selection_args=()
  [[ "$scope" != fleet ]] || selection_args=(--state-dir "$selection_state")
  for effect in success running list-panes kill-window stopped checkpoint; do
    [[ "$effect" != running && "$effect" != stopped || "$scope" == fleet ]] || continue
    expected_rc=1 effect_selection=pending effect_env=''
    case "$effect" in
      success) expected_rc=0; effect_selection=fresh ;;
      running) effect_selection=fresh; effect_env=';OT_STATE_FAIL=running' ;;
      list-panes|kill-window) effect_env=";OT_TMUX_FAIL=$effect" ;;
      stopped) effect_env=';OT_STATE_FAIL=stopped' ;;
      checkpoint)
        effect_env=';OT_STATE_FAIL=checkpoint'
        [[ "$scope" != launch-only ]] || effect_selection=fresh ;;
    esac
    for code in live control replay; do
      [[ "$code" != replay || "$effect" == success ]] || continue
      # The fleet stopped-write and subsequent checkpoint failure keep their
      # existing record assertions. The table above supplies their stop control.
      [[ "$code" != control || "$effect" != stopped && ! ( "$effect" == checkpoint && "$scope" == fleet ) ]] || continue
      "$SCRIPTS_DIR/workflow-state" --state-dir "$selection_state" update "$([[ "$scope" == fleet ]] && echo oversee || echo KEN-40)" '$record' --argjson record "$saved_record" >/dev/null
      OPEN_TERMINAL="$STATE_SCRIPTS/open-terminal"
      if [[ "$code" == replay ]]; then OPEN_TERMINAL="$REPLAY_MUTANT"
      elif [[ "$code" == control ]]; then
        case "$effect" in
          success) OPEN_TERMINAL="$SUCCESS_MUTANT" ;;
          running) OPEN_TERMINAL="$STATE_TAKEN_MUTANT" ;;
          list-panes|kill-window) OPEN_TERMINAL="$CLOSE_MUTANT" ;;
          checkpoint) OPEN_TERMINAL="$STATE_CLEAR_MUTANT" ;;
        esac
      fi
      run_ot "$selection_env;OT_TMUX_PANES=$saved_panes;LANE_HOST_STUB_SELECTION=$effect_selection;LANE_HOST_STUB_STOP_STATUS=0;OT_POST_STOP_STATE=exited$effect_env" \
        --harness codex --lane "$H/.eclaude" --repo o/r --relaunch ${selection_args[@]+"${selection_args[@]}"} KEN-40
      if [[ "$code" == live ]]; then selection_effect_contract
      else
        CONTROL_RC=0
        ( FAIL=0; selection_effect_contract; [[ "$FAIL" == 0 ]] ) > "$selection_state/effect-$effect.control" 2>&1 || CONTROL_RC=$?
        assert_eq "$CONTROL_RC" 1 "$scope $effect rejects a broken finalization rule"
      fi
    done
  done
done
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
