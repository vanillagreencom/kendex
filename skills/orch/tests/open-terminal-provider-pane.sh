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
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-refused;LANE_HOST_STUB_PROBE_STATUS=7" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
assert_eq "rc=$RC sends=$(grep -c '^send ' "$RUN/host.log" || true) local=$(local_input_count)" \
  'rc=1 sends=0 local=0' 'a failed process read refuses launch input'

for row in 'first|SSH_FAIL=7|0|1|1' 'first|LANE_HOST_STUB_VIEWER_STATUS=7|0|1|1' 'first|LANE_HOST_STUB_CAPTURE_STATUS=7|0|1|1' 'first|LANE_HOST_STUB_CAPTURE_VIEWPORT_STATUS=7|0|1|1' 'first|LANE_HOST_STUB_VIEWER_STATUS=7|7|1|0'; do
  IFS='|' read -r mode failure stop_status stops killed <<< "$row"
  cp "$READY" "$CURRENT"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_STOP_STATUS=$stop_status;LANE_HOST_STUB_CAPTURE_ERROR=provider: capture-unreachable item=KEN-40;$failure" \
    --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
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
for row in 'first|7|control|stopped|1' 'first|0|live|stopped|1' 'first|7|live|absent|0'; do
  IFS='|' read -r mode stop_status code status killed <<< "$row"
  fleet="$TMP_ROOT/cleanup-$mode-$stop_status-$code"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$fleet" "$PWD"
  printf 'Choose theme\n' > "$CURRENT"
  OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
  [[ "$code" != control ]] || OPEN_TERMINAL="$CLEANUP_MUTANT"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_STOP_STATUS=$stop_status;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-cleanup-$mode-$stop_status-$code" \
    --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" KEN-40
  got="rc=$RC status=$("$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" get oversee '.lanes[0].status // "absent"') killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)"
  assert_eq "$got" "rc=1 status=$status killed=$killed" "detached $code $mode stop=$stop_status"
  if [[ "$code" == control ]]; then
    CONTROL_RED="$(FAIL=0; assert_eq "$got" 'rc=1 status=absent killed=0' control >/dev/null; printf '%s' "$FAIL")"
    assert_eq "$CONTROL_RED" 1 'a failed provider stop cannot be hidden by closing its dormant local window'
  else
    assert_eq "$(grep -c '^stop --item KEN-40 --harness claude ' "$RUN/host.log" || true)" \
      1 'detached cleanup stops each owned attempt through the provider'
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
    mutate_file "$BACKGROUND_MUTANT" '[[ "${HOST_PANE:-local}" != verb || "${HOST_PANE_LAUNCH:-unstarted}" != owned || -n "$UNTAKEN_PANE" ]] || return 1' 'false || true'
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


# --relaunch is an admitted recovery command, but provider-pane recovery is
# deferred before create, prior stop, parked start or window replacement.
# A saved lane window is the real list-windows producer for replacement.
mutate_file "$OT_STUB_BIN/tmux" '    [[ " $* " == *'\'' -f '\''* ]] || echo "1" ;;' '    if [[ " $* " == *'\'' -f '\''* && "${OT_PRIOR_WINDOW:-}" == 1 ]]; then
      printf "1 @1\\n"
    elif [[ " $* " != *'\'' -f '\''* ]]; then echo "1"; fi ;;'
CUT_MUTANT="$(mutant_scripts deferred-relaunch/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/deferred-relaunch/orch"
mutate_file "$CUT_MUTANT" 'if [[ "$HOST_PANE" == verb && "$RELAUNCH" == true ]]; then' 'if false && [[ "$HOST_PANE" == verb && "$RELAUNCH" == true ]]; then'
cut_contract() {
  local provider_ops=0 window_ops=0
  # The fixtures create each trace only when that tool is invoked.
  [[ ! -f "$RUN/host.log" ]] || provider_ops="$(grep -cE '^(create|start|stop|capture|send) ' "$RUN/host.log" || true)"
  [[ ! -f "$RUN/tmux.log" ]] || window_ops="$(grep -cE '^(new-window|kill-window|set-option|load-buffer|paste-buffer|send-keys) ' "$RUN/tmux.log" || true)"
  assert_eq "$RC" 1 "$1 refuses automatic provider relaunch"
  assert_eq "$(grep -cFx "open-terminal: host-relaunch-deferred host=$HOST_STUB pane=verb follow-up=KEN-3996" <<< "$OUT" || true)" 1 "$1 names the deferred recovery owner"
  assert_eq "$provider_ops" 0 "$1 changes no provider harness or pane"
  assert_eq "$window_ops" 0 "$1 preserves the existing window"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" get "$cut_key" | jq -Sc .)" "$cut_saved" "$1 preserves the entire saved record"
}
for row in 'fleet|running|none|0' 'fleet|running|new-window|0' 'fleet|preparing|set-option|0' 'fleet|parked|none|7' 'launch-only|selection|none|0'; do
  IFS='|' read -r scope prior operation stop_status <<< "$row"
  cut_state="$TMP_ROOT/cut-$scope-$prior-$operation"
  cut_args=()
  if [[ "$scope" == fleet ]]; then
    ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$cut_state" "$PWD"
    cut_key=oversee; cut_args=(--state-dir "$cut_state")
    cut_record="$(jq -cn --arg host "$HOST_STUB" --arg account "$H/.eclaude" --arg status "$prior" --arg line "$LANE_HOST_STUB_CREATE_LINE" '{item:"KEN-40",host:$host,kind:"ssh",account:$account,harness:"claude",window:"stub:KEN-40",mail_root:"/srv/lane",status:$status,session_id:"saved-session",model:"opus",effort:"high"} + (if $status == "preparing" then {prepare:{host:$host,line:$line,step:"marker",relaunch:true,account:("CLAUDE_CONFIG_DIR="+$account),harness:"claude",since:"2026-10-01T00:00:00Z"}} else {} end)')"
    "$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" set oversee lanes "[$cut_record]" >/dev/null
  else
    cut_key=KEN-40
    "$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" init KEN-40 >/dev/null
    "$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" set KEN-40 host_launch "$(jq -cn --arg host "$HOST_STUB" --arg account "CLAUDE_CONFIG_DIR=$H/.eclaude" --arg line "$LANE_HOST_STUB_CREATE_LINE" '{status:"preparing",host:$host,account:$account,line:$line,step:"selection",relaunch:true,harness:"codex",model:"gpt-6-astra",effort:"high",pane:"%1",server:"saved-server",session:"stub",since:"2026-10-01T00:00:00Z"}')" >/dev/null
  fi
  cut_saved="$("$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" get "$cut_key" | jq -Sc .)"
  OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_STATE_DIR=$cut_state;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$READY;LANE_HOST_STUB_STOP_STATUS=$stop_status;OT_TMUX_FAIL=$operation;OT_PRIOR_WINDOW=1" \
    --harness claude --lane "$H/.eclaude" --repo o/r --relaunch ${cut_args[@]+"${cut_args[@]}"} KEN-40
  cut_contract "$row"
done
# The existing selection checkpoint has its real relaunch=true producer.
# For the mutation control, use the ordinary running row with no checkpoint,
# so removing the refusal reaches actual replacement window setup.
cut_state="$TMP_ROOT/cut-control"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$cut_state" "$PWD"
cut_key=oversee
"$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" set oversee lanes "$(jq -cn --arg host "$HOST_STUB" '{item:"KEN-40",host:$host,harness:"claude",status:"running",window:"stub:KEN-40"} | [. ]')" >/dev/null
cut_saved="$("$SCRIPTS_DIR/workflow-state" --state-dir "$cut_state" get oversee | jq -Sc .)"
OPEN_TERMINAL="$CUT_MUTANT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$READY;OT_PRIOR_WINDOW=1" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$cut_state" --relaunch KEN-40
assert_eq "$(grep -c '^new-window -k ' "$RUN/tmux.log" || true)" 1 'the cut mutant reaches replacement window setup'
CONTROL_RC=0
( FAIL=0; cut_contract control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/cut-control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'the same refusal contract rejects automatic provider relaunch'
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

# Fresh create responses can be saved before wait or marker completion.
# This wrapper uses the real dispatcher's occupied pool slot producer.
RETRY_PROVIDER="$TMP_ROOT/retry-provider"
cat > "$RETRY_PROVIDER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
rc=0
"$OT_RETRY_PROVIDER" "$@" || rc=$?
if [[ "$1" == create && "$rc" == 0 && "${OT_BLOCK_AFTER_CREATE:-}" == 1 ]]; then
  mkdir -p "${OT_BUSY_SLOT%/*}"
  : > "$OT_BUSY_SLOT"
fi
exit "$rc"
SH
chmod +x "$RETRY_PROVIDER"
for row in 'launch-only|wait|preparing' 'launch-only|marker|ready' 'fleet|marker|ready'; do
  IFS='|' read -r scope step state <<< "$row"
  retry_state="$TMP_ROOT/fresh-$scope-$step"
  retry_args=(); retry_key=KEN-40; retry_query=.host_launch
  if [[ "$scope" == fleet ]]; then
    ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$retry_state" "$PWD"
    retry_args=(--state-dir "$retry_state"); retry_key=oversee; retry_query='.lanes[0].prepare'
  fi
  retry_home="$retry_state/home"
  retry_slot="$retry_home/.cache/orch/lane-host-slots"
  [[ "$step" == wait ]] || retry_slot+=/short
  retry_slot+="/slot.$$"
  retry_line="$LANE_HOST_STUB_CREATE_LINE"
  [[ "$state" != preparing ]] || retry_line+=$'	state=preparing'
  retry_env="$CHOICE;$COMPACTION_OFF_ALL;ORCH_STATE_DIR=$retry_state;HOME=$retry_home;ORCH_LANE_HOST=$RETRY_PROVIDER;OT_RETRY_PROVIDER=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CREATE_LINE=$retry_line;LANE_HOST_STUB_CAPTURE_FILE=$DELIVERED;ORCH_LANE_HOST_SHORT_MAX_CALLS=1;ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0;ORCH_LANE_HOST_MAX_CALLS=1;ORCH_LANE_HOST_BUSY_WAIT_SECS=0;OT_BUSY_SLOT=$retry_slot"
  run_ot "$retry_env;OT_BLOCK_AFTER_CREATE=1" --harness claude --lane "$H/.eclaude" --repo o/r ${retry_args[@]+"${retry_args[@]}"} KEN-40
  assert_eq "$RC" 0 "$row saves an accepted fresh launch after dispatcher refusal"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$retry_state" get "$retry_key" "$retry_query" | jq -r '[.step,.relaunch] | @tsv')" "$step"$'	false' "$row retains its fresh checkpoint producer"
  rm -f -- "${retry_slot:?}"
  run_ot "$retry_env" --harness claude --lane "$H/.eclaude" --repo o/r ${retry_args[@]+"${retry_args[@]}"} KEN-40
  launch_contract "$row completes the fresh checkpoint"
  assert_eq "$(grep -c '^create ' "$RUN/host.log" || true)" 0 "$row reuses its accepted sandbox"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$retry_state" get "$retry_key" "$retry_query // null")" null "$row retires its completed checkpoint"
done
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
