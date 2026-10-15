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
mv "$OT_STUB_BIN/ssh" "$OT_STUB_BIN/ssh-handoff"
cat > "$OT_STUB_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" != *'workflow-state handoff-standing '* ]] || exec "${0%/*}/ssh-handoff" "$@"
printf '%s\n' "$*" > "$LANE_HOST_STUB_LOG.ssh"
[[ "$1" == -T && "$2" == -o && "$3" == BatchMode=yes ]] || exit 1
shift 3
connect_secs=0
if [[ "$1" == -o && "$2" == ConnectTimeout=* ]]; then
  connect_secs="${2#ConnectTimeout=}"; shift 2
fi
[[ "$1" == -- && $# == 3 ]] || exit 1
[[ -z "$(cat)" ]] || exit 1
# A non-answering host leaves SSH blocked until its connection timer expires.
if [[ -n "${SSH_CONNECT_STALL_FILE:-}" ]]; then
  printf '%s\n' "$connect_secs" > "$SSH_CONNECT_STALL_FILE"
  connection_rc=0
  "$SSH_CONNECT_TIMEOUT" 5 perl -e '$SIG{ALRM} = sub { exit 255 }; alarm shift; sleep 60' "$connect_secs" || connection_rc=$?
  printf '%s\n' "$connection_rc" > "$SSH_CONNECT_RESULT_FILE"
  exit "$connection_rc"
fi
[[ -z "${SSH_PANE_CONTROL:-}" ]] || tmux send-keys -t %1 Enter
[[ "${SSH_FAIL:-0}" == 0 ]] || exit "$SSH_FAIL"
exec "$BASH" -c "$3"
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

local_input_count() { if [[ -f "$RUN/tmux.log" ]]; then grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$RUN/tmux.log" || true; else printf 0; fi; }
launch_contract() { printf '%s\n' "$OUT" > "$RUN/launch-errors"; assert_eq "rc=$RC local=$(local_input_count)" 'rc=0 local=0' "$1" "$RUN/launch-errors"; }
failed_launch_contract() {
  assert_eq "rc=$RC local=$(local_input_count) stops=$(grep -c '^stop --item KEN-40 --harness claude ' "$RUN/host.log" || true) killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)" "$1" "$2"
}

seed_prior() { # DIRECTORY STATUS HARNESS [CHECKPOINT]
  prior_state="$1"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$prior_state" "$PWD"
  prior_record="$(jq -cn --arg host "$HOST_STUB" --arg account "$H/.eclaude" --arg status "$2" --arg harness "$3" \
    --arg cwd "$PWD" --argjson checkpoint "${4:-null}" \
    '{item:"KEN-40",tracker:"linear",repo:"o/r",host:$host,kind:"ssh",account:$account,harness:$harness,
      window:"stub:KEN-40",mail_root:"/srv/lane",status:$status,session_id:"saved-session",session_since:"2026-10-01T00:00:00Z",
      launched_at:"2026-10-01T00:00:00Z",model:"claude-opus-5-5",effort:"high",launch:{pane:"%9",server:123,pid:456,start:"prior-start"},
      recovery:{cwd:$cwd,flags:"--model opus --effort high --permission-mode dontAsk",session:"stub",refresh:false},
      retained:{pr:12,note:"keep-complete-record"}} + (if $checkpoint == null then {} else {prepare:$checkpoint} end)')"
  "$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" set oversee lanes "[$prior_record]" >/dev/null
  prior_saved="$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0]' | jq -Sc .)"
}
retained_prior() {
  assert_eq "rc=$RC stops=$(grep -c '^stop ' "$RUN/host.log" || true) started=$([[ -e "$RUN/host.log.ssh" ]] && echo yes || echo no)" \
    'rc=1 stops=0 started=no' "$1 preserves the predecessor process"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0]' | jq -Sc .)" \
    "$prior_saved" "$1 preserves the complete predecessor record"
}
# The connection bound excludes independent launcher setup and cleanup.
BOUND_OPEN_TERMINAL="$OPEN_TERMINAL"
BOUND_MUTANT="$(mutant_scripts connection-bound/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/connection-bound/orch"
mutate_file "$BOUND_MUTANT" '-o "ConnectTimeout=$LANE_SSH_PROMPT_SECS"' ''
BOUND_TIMEOUT="$(command -v timeout || command -v gtimeout)" || exit 1
for row in 'live|255|1|0' 'control|124|0|1'; do
  IFS='|' read -r code expected_connection_rc expected_timer expected_rejection <<< "$row"
  OPEN_TERMINAL="$BOUND_OPEN_TERMINAL"
  [[ "$code" != control ]] || OPEN_TERMINAL="$BOUND_MUTANT"
  run_ot "$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;SSH_CONNECT_STALL_FILE=$TMP_ROOT/ssh-bound-$code.reached;SSH_CONNECT_TIMEOUT=$BOUND_TIMEOUT;SSH_CONNECT_RESULT_FILE=$TMP_ROOT/ssh-bound-$code.result" \
    --launch-flags "${CHOICE#flags=}" --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
  printf '%s\n' "$OUT" > "$TMP_ROOT/ssh-bound-$code.log"
  connection_rc="$(cat "$TMP_ROOT/ssh-bound-$code.result")" || connection_rc=missing
  assert_eq "$connection_rc" "$expected_connection_rc" "$code records the connection dependency result" "$TMP_ROOT/ssh-bound-$code.log"
  CONTROL_RC=0
  ( FAIL=0; assert_eq "$connection_rc" 255 "$code non-answering SSH connection respects the parent deadline"; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/ssh-bound-$code-control.log" 2>&1 || CONTROL_RC=$?
  assert_eq "$CONTROL_RC" "$expected_rejection" "$code connection result assertion rejects a missing connection timer" "$TMP_ROOT/ssh-bound-$code-control.log"
  failed_launch_contract 'rc=1 local=0 stops=1 killed=1' "$code failed connection stops its owned attempt and closes its window"
  assert_eq "$(cat "$TMP_ROOT/ssh-bound-$code.reached")" "$expected_timer" "$code reaches the non-answering SSH connection"
  [[ "$code" != live ]] || assert_file_contains "$TMP_ROOT/ssh-bound-$code.log" \
    'open-terminal: host-exec-failed item=KEN-40' 'the configured connection bound returns host-exec-failed'
done
OPEN_TERMINAL="$BOUND_OPEN_TERMINAL"

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
seed_prior "$fleet" running codex
cp "$DELIVERED" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" --relaunch KEN-40
failed_launch_contract 'rc=1 local=0 stops=0 killed=0' 'a confirmed foreground replacement survives a later record failure'
assert_eq "$(grep -c '^stop --item KEN-40 --harness codex ' "$RUN/host.log" || true)" 1 'the taken replacement retired only its predecessor'
mutate_file "$RECORD_MUTANT" '[[ -n "$UNTAKEN_PANE" ]] || return 1' '[[ -n "$UNTAKEN_PANE" ]] || UNTAKEN_PANE="$LAUNCH_PANE"'
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" --relaunch KEN-40
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


# The replacement uses the existing named window, while the provider owns the
# remote predecessor independently of that window.
mutate_file "$OT_STUB_BIN/tmux" '    [[ " $* " == *'\'' -f '\''* ]] || echo "1" ;;' '    if [[ " $* " == *'\'' -f '\''* && "${OT_PRIOR_WINDOW:-}" == 1 ]]; then
      printf "1 @1\\n"
    elif [[ " $* " != *'\'' -f '\''* ]]; then echo "1"; fi ;;'

PREPARING_CREATE_LINE="${LANE_HOST_STUB_CREATE_LINE}"$'\tstate=preparing'
NATIVE_CHECKPOINT="$(jq -cn --arg host "$HOST_STUB" --arg account "CODEX_HOME=$H/.eclaude" --arg line "$LANE_HOST_STUB_CREATE_LINE" \
  '{status:"preparing",host:$host,account:$account,line:$line,step:"selection",relaunch:true,harness:"codex",command_route:"native",
    model:"gpt-6-astra",effort:"high",pane:"%1",server:"123",session:"stub",since:"2026-10-01T00:00:00Z"}')"
cp "$OT_STUB_BIN/claude" "$OT_STUB_BIN/codex"
CUSTOM_BRIEF="$TMP_ROOT/custom-brief"
printf '%s' 'custom replacement task' > "$CUSTOM_BRIEF"
for row in \
  'native|running|claude||0|1|running' \
  'switch|running|codex||0|1|running' \
  'custom|running|claude||0|1|running' \
  'window|running|codex|OT_TMUX_FAIL=new-window|1|0|retained' \
  'option|running|codex|OT_TMUX_FAIL=set-option|1|0|retained' \
  'marker|running|codex|LANE_HOST_STUB_PUT_STATUS=7|1|0|retained' \
  'readback|running|codex|LANE_HOST_STUB_PUT_BYTES=wrong-marker|1|0|retained' \
  'stop-failed|running|codex|LANE_HOST_STUB_STOP_STATUS=7|1|1|retained' \
  'stop-unconfirmed|running|codex|LANE_HOST_STUB_STOP_OUT=unconfirmed|1|1|retained' \
  'wait-native|running|codex|LANE_HOST_STUB_WAIT_STATUS=7|1|0|retained' \
  'wait-custom|running|claude|LANE_HOST_STUB_WAIT_STATUS=7|1|0|retained' \
  'checkpoint-failed|preparing|codex|LANE_HOST_STUB_PUT_STATUS=7|1|0|retained' \
  'checkpoint-completed|preparing|codex||0|1|running' \
  'park-failed|parked|claude|LANE_HOST_STUB_START_STATUS=7|1|0|retained' \
  'park-unconfirmed|parked|claude|LANE_HOST_STUB_START_OUT=unconfirmed|1|0|retained' \
  'park-started|parked|claude||0|0|running' \
  'retired|stopped|claude||0|0|running' \
  'ssh|running|codex|SSH_FAIL=7|1|2|stopped' \
  'viewer|running|codex|LANE_HOST_STUB_VIEWER_STATUS=7|1|2|stopped' \
  'capture|running|codex|LANE_HOST_STUB_CAPTURE_STATUS=7|1|2|stopped'; do
  IFS='|' read -r label prior harness injection expected_rc stops expected_status <<<"$row"
  checkpoint=null command_env="$CHOICE" extra_args=() preparation="" requested=claude lane_args=(--lane "$H/.eclaude")
  case "$label" in
    checkpoint-*) checkpoint="$NATIVE_CHECKPOINT"; requested=codex ;;
  esac
  case "$label" in
    custom|wait-custom) command_env="cmd=claude --model opus --effort high {brief} $COMPACTION_OFF_ALL"; extra_args=(--brief-file "$CUSTOM_BRIEF") ;;
  esac
  if [[ "$requested" == codex ]]; then
    command_env="cmd=codex -m gpt-6-astra -c model_reasoning_effort=high {brief} $COMPACTION_OFF_ALL"
    extra_args=(--brief-file "$CUSTOM_BRIEF")
  fi
  case "$label" in wait-*) preparation=";LANE_HOST_STUB_CREATE_LINE=$PREPARING_CREATE_LINE" ;; esac
  seed_prior "$TMP_ROOT/relaunch-$label" "$prior" "$harness" "$checkpoint"
  printf 'Working (esc to interrupt)\n' > "$CURRENT"
  run_ot "$command_env;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;OT_PRIOR_WINDOW=1;$injection$preparation" \
    --harness "$requested" ${lane_args[@]+"${lane_args[@]}"} --repo o/r --state-dir "$prior_state" --relaunch ${extra_args[@]+"${extra_args[@]}"} KEN-40
  printf '%s\n' "$OUT" > "$RUN/result.log"
  assert_eq "rc=$RC local=$(local_input_count) stops=$(grep -c '^stop ' "$RUN/host.log" || true)" \
    "rc=$expected_rc local=0 stops=$stops" "$label replacement ownership" "$RUN/result.log"
  if [[ "$expected_status" == retained ]]; then
    if [[ "$stops" == 0 ]]; then retained_prior "$label"
    else
      assert_eq "$([[ -e "$RUN/host.log.ssh" ]] && echo yes || echo no)" no "$label starts no successor after failed stop"
      assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0]' | jq -Sc .)" "$prior_saved" "$label retains the old record and checkpoint"
      assert_file_contains "$RUN/result.log" 'open-terminal: host-stop-failed item=KEN-40' "$label reports stop failure"
    fi
  else
    assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0].status')" "$expected_status" "$label records the launch outcome"
    if [[ "$expected_status" == running ]]; then
      assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0] | [.harness,.prepare] | @json')" "[\"$requested\",null]" "$label completes the requested harness and retires its checkpoint"
    fi
  fi
  if [[ "$stops" != 0 ]]; then
    assert_eq "$(sed -n '/^stop /{p;q;}' "$RUN/host.log")" "stop --item KEN-40 --harness $harness " "$label retires the recorded harness"
    assert_eq "$(awk '/^put / {prepared=1} /^stop / {print prepared+0; exit}' "$RUN/host.log")" 1 "$label prepares the marker before retirement"
  fi
  if [[ "$stops" == 2 ]]; then
    assert_eq "$(sed -n '/^stop /p' "$RUN/host.log" | tail -1)" 'stop --item KEN-40 --harness claude ' "$label cleanup names the requested successor"
  fi
  case "$label" in
    native|switch|custom|checkpoint-completed|park-started|retired)
      assert_eq "$([[ -s "$RUN/host.log.started" ]] && echo yes || echo no)" yes "$label executes the remote successor" ;;
  esac
  case "$label" in
    window|option) assert_file_contains "$RUN/result.log" 'open-terminal: tmux-failed operation=' "$label names the window failure" ;;
    marker|readback|checkpoint-failed) assert_file_contains "$RUN/result.log" 'open-terminal: marker-failed item=KEN-40' "$label reaches marker failure" ;;
    wait-*) assert_file_contains "$RUN/result.log" 'open-terminal: host-prepare-failed item=KEN-40' "$label reaches foreground preparation failure" ;;
  esac
  [[ "$label" != custom ]] || assert_eq "$(sed -n '/custom replacement task/p' "$RUN/host.log.started")" 'custom replacement task' 'the custom successor receives the exact brief'
  [[ "$label" != park-started ]] || assert_eq "$(awk '/^start / {started=1} /^create / {print started+0; exit}' "$RUN/host.log")" 1 'confirmed sandbox start precedes create'
done

STOP_FIRST_MUTANT="$(mutant_scripts stop-first/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/stop-first/orch"
mutate_file "$STOP_FIRST_MUTANT" 'launch_finish() {' 'launch_finish() {
  if [[ "$HOST_PANE" == verb && "$host_command_restart" == pending ]]; then
    host_harness_stop prior || return 1
    host_command_restart=completed
  fi'
OPEN_TERMINAL="$STOP_FIRST_MUTANT"
seed_prior "$TMP_ROOT/stop-first" running codex
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_PUT_STATUS=7;OT_PRIOR_WINDOW=1" \
  --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$prior_state" --relaunch KEN-40
printf '%s\n' "$OUT" > "$RUN/result.log"
assert_eq "$(grep -c '^create ' "$RUN/host.log" || true) $(grep -c '^stop --item KEN-40 --harness codex ' "$RUN/host.log" || true)" '1 1' 'the stop-first control reaches create and prior retirement'
assert_file_contains "$RUN/result.log" 'open-terminal: marker-failed item=KEN-40' 'the stop-first control reaches the same marker failure'
CONTROL_RC=0
( FAIL=0; retained_prior control; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/retained-control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'the retention assertion rejects stop before replacement preparation'
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

# A compatible saved selection finishes the started successor without setup.
for scope in fleet launch-only; do
  prior_state="$TMP_ROOT/selection-$scope"
  selection_args=() key=KEN-40 query=.host_launch
  if [[ "$scope" == fleet ]]; then
    seed_prior "$prior_state" preparing codex "$NATIVE_CHECKPOINT"
    selection_args=(--state-dir "$prior_state"); key=oversee; query='.lanes[0].prepare'
  else
    "$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" init KEN-40 >/dev/null
    "$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" set KEN-40 host_launch "$NATIVE_CHECKPOINT" >/dev/null
  fi
  selection_saved="$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get "$key" "$query" | jq -Sc .)"
  run_ot "flags=-m gpt-6-astra -c model_reasoning_effort=high;$COMPACTION_OFF_ALL;ORCH_STATE_DIR=$prior_state;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_CAT_STATUS=69" \
    --harness codex --lane "$H/.eclaude" --repo o/r --relaunch ${selection_args[@]+"${selection_args[@]}"} KEN-40
  assert_eq "$RC" 0 "$scope busy selection keeps its continuation"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get "$key" "$query" | jq -Sc .)" "$selection_saved" "$scope preserves the complete selection checkpoint"
  assert_eq "$(grep -cE '^(create|wait|put|stop) ' "$RUN/host.log" || true) $([[ -e "$RUN/host.log.ssh" ]] && echo yes || echo no)" '0 no' "$scope busy selection starts and stops no harness"
  run_ot "flags=-m gpt-6-astra -c model_reasoning_effort=high;$COMPACTION_OFF_ALL;ORCH_STATE_DIR=$prior_state;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SELECTION=resume" \
    --harness codex --lane "$H/.eclaude" --repo o/r --relaunch ${selection_args[@]+"${selection_args[@]}"} KEN-40
  launch_contract "$scope saved selection completes"
  assert_eq "$(grep -cE '^(create|wait|put|stop) ' "$RUN/host.log" 2>/dev/null || true) $([[ -e "$RUN/host.log.ssh" ]] && echo yes || echo no) $(if [[ -f "$RUN/tmux.log" ]]; then grep -c '^new-window ' "$RUN/tmux.log" || true; else printf 0; fi)" '0 no 0' "$scope selection does no new setup or launch"
  assert_eq "$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get "$key" "$query // null")" null "$scope retires the completed selection checkpoint"
done

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
# The same dispatcher slot producer must not overwrite a running predecessor.
for step in wait marker; do
  seed_prior "$TMP_ROOT/busy-relaunch-$step" running codex "$NATIVE_CHECKPOINT"
  "$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" update oversee --arg host "$RETRY_PROVIDER" \
    '.lanes[0].host = $host | .lanes[0].prepare.host = $host' >/dev/null
  prior_saved="$("$SCRIPTS_DIR/workflow-state" --state-dir "$prior_state" get oversee '.lanes[0]' | jq -Sc .)"
  retry_home="$prior_state/home"
  retry_slot="$retry_home/.cache/orch/lane-host-slots"
  [[ "$step" == wait ]] || retry_slot+=/short
  retry_slot+="/slot.$$"
  retry_line="$LANE_HOST_STUB_CREATE_LINE"
  [[ "$step" != wait ]] || retry_line="$PREPARING_CREATE_LINE"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;HOME=$retry_home;ORCH_LANE_HOST=$RETRY_PROVIDER;OT_RETRY_PROVIDER=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CREATE_LINE=$retry_line;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;ORCH_LANE_HOST_SHORT_MAX_CALLS=1;ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0;ORCH_LANE_HOST_MAX_CALLS=1;ORCH_LANE_HOST_BUSY_WAIT_SECS=0;OT_BUSY_SLOT=$retry_slot;OT_BLOCK_AFTER_CREATE=1" \
    --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$prior_state" --relaunch KEN-40
  printf '%s\n' "$OUT" > "$RUN/result.log"
  retained_prior "busy $step"
  assert_eq "$(grep -c '^create ' "$RUN/host.log" || true)" 1 "busy $step reaches accepted create"
  assert_file_contains "$RUN/result.log" 'open-terminal: lane-host-busy item=KEN-40' "busy $step refuses for explicit retry"
  rm -f -- "${retry_slot:?}"
done
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
